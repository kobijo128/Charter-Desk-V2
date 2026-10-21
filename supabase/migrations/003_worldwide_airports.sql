-- 003: worldwide airports, runway lengths and smarter request generation.
-- After running this, load the airport list (see README: "Loading the worldwide airports").

alter table public.airports add column if not exists size text not null default 'medium';
alter table public.airports add column if not exists rwy_ft int not null default 6000;
alter table public.airports add column if not exists paved boolean not null default true;
alter table public.airports add column if not exists scheduled boolean not null default false;
create index if not exists airports_active on public.airports(active) where active;

alter table public.aircraft_types add column if not exists min_rwy_ft int not null default 4000;
update public.aircraft_types set min_rwy_ft = case code
  when 'SF50' then 3300 when 'PC12' then 2600 when 'B350' then 3300 when 'E55P' then 3600 when 'C25C' then 3500
  when 'C68A' then 4000 when 'CL35' then 4900 when 'F2TH' then 4800 when 'GLF6' then 6000 when 'GL7T' then 5800 else min_rwy_ft end;

-- runways long enough at both ends
create or replace function public.rwy_ok(p_from text, p_to text, p_min int)
returns boolean language sql stable set search_path = public as $$
  select coalesce((select bool_and(rwy_ft >= p_min) from airports where icao in (p_from, p_to)), false)
$$;

-- bulk upsert from [[icao,name,city,country,lat,lon,size,rwy_ft,paved,scheduled], ...]
-- curated airports keep their names and demand tags
create or replace function public.import_airports(p_rows jsonb)
returns int language plpgsql set search_path = public as $$
declare n int;
begin
  insert into airports(icao, name, city, country, lat, lon, size, rwy_ft, paved, scheduled, tags, active)
  select r->>0, r->>1, r->>2, coalesce(r->>3,''), (r->>4)::float8, (r->>5)::float8, coalesce(r->>6,'medium'),
         coalesce((r->>7)::int, 6000), coalesce((r->>8)::boolean, true), coalesce((r->>9)::boolean, false),
         case when r->>6 = 'large' then '{biz}'::text[]
              when r->>6 = 'medium' and coalesce((r->>9)::boolean,false) then '{leisure}'::text[]
              else '{}'::text[] end,
         true
    from jsonb_array_elements(p_rows) r
   where (r->>0) ~ '^[A-Z0-9]{3,4}$'
  on conflict (icao) do update set lat = excluded.lat, lon = excluded.lon, size = excluded.size,
    rwy_ft = excluded.rwy_ft, paved = excluded.paved, scheduled = excluded.scheduled;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.admin_import_airports(p_rows jsonb)
returns int language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  return import_airports(p_rows);
end $$;

-- demand weight: airport size, its own local time of day, season
drop function if exists public.ap_weight(text[],int,int);
create or replace function public.ap_weight(p_tags text[], p_size text, p_lon float8, p_month int)
returns float8 language plpgsql stable set search_path = public as $$
declare w float8; h int;
begin
  h := ((extract(hour from now() at time zone 'UTC')::int + round(p_lon / 15)::int) % 24 + 24) % 24;
  w := case p_size when 'large' then 3 when 'medium' then 1 else 0.35 end;
  if 'biz' = any(p_tags) then w := w * case when h between 5 and 11 then 3 when h < 17 then 1.6 else 0.8 end; end if;
  if 'leisure' = any(p_tags) then w := w * case when h >= 15 or h < 2 then 2.6 when h >= 11 then 1.7 else 0.9 end; end if;
  if 'ski' = any(p_tags) then w := w * case when p_month >= 12 or p_month <= 3 then 3 else 0.35 end; end if;
  if 'long' = any(p_tags) then w := w * 0.5; end if;
  if h between 1 and 5 then w := w * 0.3; end if;  -- quiet overnight wherever the airport is
  return greatest(w, 0.005);
end $$;

drop function if exists public.gen_route(text,int,int);
create or replace function public.gen_route(p_near text, p_max_nm int, p_max_pax int, p_min_rwy int default null)
returns public.route_pick language plpgsql volatile set search_path = public as $$
declare
  r public.route_pick; f public.airports; t public.airports; c public.clients; m int; lead numeric; near_dest boolean;
begin
  m := extract(month from now());
  for i in 1..40 loop
    f := null; t := null;
    if p_near is not null and random() < 0.75 then
      if random() < 0.35 then
        select * into f from airports where icao = p_near and (p_min_rwy is null or rwy_ft >= p_min_rwy);
      end if;
      if f.icao is null then
        select a.* into f from airports a, airports n
         where n.icao = p_near and a.icao <> p_near and a.active and (p_min_rwy is null or a.rwy_ft >= p_min_rwy)
           and a.lat between n.lat - 11 and n.lat + 11
           and nm(a.lat,a.lon,n.lat,n.lon) < 650
         order by -ln(random()) / ap_weight(a.tags, a.size, a.lon, m) limit 1;
      end if;
    end if;
    if f.icao is null then
      select * into f from airports where active and (p_min_rwy is null or rwy_ft >= p_min_rwy)
       order by -ln(random()) / ap_weight(tags, size, lon, m) limit 1;
    end if;
    if f.icao is null then return null; end if;
    -- most trips stay regional; some go long
    near_dest := random() < 0.7;
    select * into t from airports a
     where a.active and a.icao <> f.icao and (p_min_rwy is null or a.rwy_ft >= p_min_rwy)
       and (not near_dest or (a.lat between f.lat - 25 and f.lat + 25 and nm(a.lat,a.lon,f.lat,f.lon) < least(1500, coalesce(p_max_nm, 1500))))
     order by -ln(random()) / ap_weight(a.tags, a.size, a.lon, m) limit 1;
    continue when t.icao is null;
    r.dist := nm(f.lat,f.lon,t.lat,t.lon);
    continue when r.dist < 90;
    continue when p_max_nm is not null and r.dist > p_max_nm;
    continue when p_max_nm is null and r.dist > 4000 and random() < 0.6;
    select * into c from clients order by random() limit 1;
    r.pax := c.pax_lo + floor(random()*(c.pax_hi - c.pax_lo + 1))::int;
    if p_max_pax is not null then r.pax := least(r.pax, p_max_pax); end if;
    r.from_icao := f.icao; r.to_icao := t.icao; r.client := c.name; r.cat := c.cat;
    r.budget_mul := c.bud_lo + random()*(c.bud_hi - c.bud_lo);
    lead := case when c.cat = 'urgent' then 1.5 + random()*3.5 else 3 + random()*31 end;
    r.dep_at := to_timestamp(ceil(extract(epoch from now() + lead * interval '1 hour') / 900) * 900);
    return r;
  end loop;
  return null;
end $$;

-- with airports worldwide, most new requests start near where pilots' aircraft are
create or replace function public.maintain()
returns void language plpgsql as $$
declare s public.va_settings; rq record; tgt int; open_n int; active_n int; near text; tr record; h int; gap interval;
begin
  if not pg_try_advisory_xact_lock(424242) then return; end if;
  select * into s from public.va_settings;

  for rq in select id from public.requests where status = 'deciding' and decide_at <= now() loop
    perform public.resolve_request(rq.id);
  end loop;

  update public.requests set status = 'expired' where status = 'open' and expires_at < now();
  delete from public.requests where status in ('expired','unawarded','awarded') and created_at < now() - interval '2 days';
  delete from public.positions where updated_at < now() - interval '10 minutes';

  -- bookings never flown: the client books someone else 48h after the planned departure
  for tr in select * from public.trips where kind = 'charter' and status = 'booked' and dep_at < now() - interval '48 hours' loop
    update public.trips set status = 'cancelled' where id = tr.id;
    update public.pilots set rep = greatest(0, rep - 3) where id = tr.pilot_id;
    perform public.add_ledger(tr.pilot_id, format('%s %s–%s lapsed unflown; client rebooked elsewhere', tr.flt, tr.from_icao, tr.to_icao), 0);
    perform public.rebuild_ferries(tr.aircraft_id);
  end loop;

  select count(*) into active_n from public.pilots where last_seen > now() - interval '15 minutes';
  tgt := least(60, s.market_base + 5 * active_n);
  select count(*) into open_n from public.requests where status in ('open','deciding');
  h := extract(hour from now() at time zone s.timezone);
  gap := case when h < 6 then interval '60 seconds' else interval '18 seconds' end;

  if open_n < tgt and (now() - s.last_spawn > gap or open_n < tgt / 2) then
    for i in 1..greatest(1, least(tgt - open_n, case when open_n < tgt/2 then tgt - open_n else 1 end)) loop
      near := null;
      if random() < 0.85 then
        select public.future_loc(f.id) into near from public.fleet f join public.pilots p on p.id = f.pilot_id
         where p.last_seen > now() - interval '15 minutes' order by random() limit 1;
      end if;
      perform public.spawn_request(near, null, null);
    end loop;
    update public.va_settings set last_spawn = now();
  end if;
  update public.va_settings set last_maint = now();
end $$;

-- spawn_request keeps its signature; it now uses the 4-argument gen_route
create or replace function public.spawn_request(p_near text, p_max_nm int, p_max_pax int)
returns bigint language plpgsql volatile set search_path = public as $$
declare r public.route_pick; rid bigint;
begin
  r := gen_route(p_near, p_max_nm, p_max_pax, null);
  if r.from_icao is null then return null; end if;
  insert into requests(from_icao,to_icao,dist,pax,client,cat,npc,dep_at,expires_at)
  values (r.from_icao, r.to_icao, r.dist, r.pax, r.client, r.cat, 2 + floor(random()*5)::int, r.dep_at,
          least(now() + (14 + random()*36) * interval '1 minute', r.dep_at - interval '1 hour'))
  returning id into rid;
  insert into request_secrets(request_id, budget_mul) values (rid, r.budget_mul);
  return rid;
end $$;

create or replace function public.poll()
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := me(); p pilots; c record; ac record; r route_pick; fair numeric; ev jsonb;
begin
  update pilots set last_seen = now() where id = u returning * into p;
  perform maintain();

  for c in select * from calls where pilot_id = u and status = 'ringing' and expires_at < now() loop
    update calls set status = 'missed' where id = c.id;
    perform schedule_call(u);
  end loop;

  if not exists (select 1 from calls where pilot_id = u and status = 'ringing') and p.next_call_at <= now() then
    select f.id, f.type_code, t.* into ac from fleet f join aircraft_types t on t.code = f.type_code
     where f.pilot_id = u order by random() limit 1;
    if ac.id is not null then
      r := gen_route(future_loc(ac.id), floor(ac.range_nm*0.9)::int, ac.seats, ac.min_rwy_ft);
      if r.from_icao is not null then
        fair := ac.rate * block_h(ac.ktas, r.dist)
              + 0.55 * ac.rate * block_h(ac.ktas, coalesce(nullif(ap_nm(future_loc(ac.id), r.from_icao),0),0));
        insert into calls(pilot_id, caller, client, line, from_icao, to_icao, dist, pax, dep_at, offer, expires_at)
        values (u,
          (array['Helen Marchetti','Rupert Ashdown','Camille Duret','Tomás Iglesias','Priya Raman','Oskar Lindqvist','Fiona Kerrigan',
                 'Marcus Delacroix','Ines Vallart','Jonah Whitcombe','Sofia Brandt','Laurent Pichon','Ade Okafor','Greta Hollis'])[1+floor(random()*14)::int],
          r.client, floor(random()*4)::int, r.from_icao, r.to_icao, r.dist, r.pax, r.dep_at,
          (round(fair * (1.15 + random()*0.30) / 500) * 500)::int, now() + interval '90 seconds');
      end if;
    end if;
    perform schedule_call(u);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('won', b.status = 'won', 'route', rq.from_icao || ' → ' || rq.to_icao,
           'amount', b.amount, 'note', b.note, 'client', rq.client) order by b.id), '[]')
    into ev
    from bids b join requests rq on rq.id = b.request_id
   where b.pilot_id = u and b.status <> 'pending' and not b.notified;
  update bids set notified = true where pilot_id = u and status <> 'pending' and not notified;
  return jsonb_build_object('events', ev, 'now', now());
end $$;

create or replace function public.place_bid(p_request bigint, p_aircraft uuid, p_amount int)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare u uuid := me(); p pilots; rq requests; f fleet; ty aircraft_types; loc text; repo int; basis numeric; wait int;
begin
  select * into p from pilots where id = u;
  select * into rq from requests where id = p_request for update;
  if rq.id is null or rq.status not in ('open','deciding') then raise exception 'That request has closed.'; end if;
  if rq.decide_at is not null and rq.decide_at <= now() then raise exception 'The broker is already deciding.'; end if;
  select * into f from fleet where id = p_aircraft and pilot_id = u;
  if f.id is null then raise exception 'That aircraft is not in your fleet.'; end if;
  select * into ty from aircraft_types where code = f.type_code;
  if rq.pax > ty.seats then raise exception 'Not enough seats.'; end if;
  if rq.dist > ty.range_nm * 0.92 then raise exception 'Beyond this aircraft''s range.'; end if;
  if not rwy_ok(rq.from_icao, rq.to_icao, ty.min_rwy_ft) then raise exception 'A runway on this route is too short for the %.', ty.name; end if;
  wait := (array[30,22,15,10])[1 + least(3, coalesce((p.upgrades->>'fast')::int,0))];
  if rq.decide_at is null and rq.expires_at < now() + wait * interval '1 second' then raise exception 'That request is closing too soon to quote.'; end if;
  loc := future_loc(f.id);
  repo := case when loc = rq.from_icao then 0 else ap_nm(loc, rq.from_icao) end;
  basis := ty.rate * block_h(ty.ktas, rq.dist);
  if p_amount < 100 or p_amount > basis * 10 then raise exception 'Enter a realistic price.'; end if;
  insert into bids(request_id, pilot_id, aircraft_id, amount, basis, repo_nm) values (p_request, u, f.id, p_amount, basis, repo);
  update requests set player_bids = player_bids + 1,
         decide_at = coalesce(decide_at, now() + wait * interval '1 second'), status = 'deciding'
   where id = p_request returning decide_at into rq.decide_at;
  return rq.decide_at;
exception when unique_violation then raise exception 'You already quoted on this request.';
end $$;

create or replace function public.accept_call(p_call bigint, p_aircraft uuid)
returns bigint language plpgsql security definer set search_path = public as $$
declare u uuid := me(); c calls; f fleet; ty aircraft_types; tid bigint;
begin
  select * into c from calls where id = p_call and pilot_id = u for update;
  if c.id is null or c.status <> 'ringing' or c.expires_at < now() then raise exception 'The caller has hung up.'; end if;
  select * into f from fleet where id = p_aircraft and pilot_id = u;
  select * into ty from aircraft_types where code = f.type_code;
  if f.id is null or c.pax > ty.seats or c.dist > ty.range_nm * 0.92 or not rwy_ok(c.from_icao, c.to_icao, ty.min_rwy_ft) then
    raise exception 'That aircraft can''t fly this job.'; end if;
  update calls set status = 'accepted' where id = c.id;
  tid := book_trip(u, f.id, c.from_icao, c.to_icao, c.dist, c.pax, c.client, c.caller, c.dep_at, c.offer, 'call');
  perform add_ledger(u, format('Phone booking from %s: %s–%s for $%s', c.caller, c.from_icao, c.to_icao, to_char(c.offer,'FM999,999,999')), 0);
  perform schedule_call(u);
  return tid;
end $$;

revoke execute on function public.rwy_ok(text,text,int) from public, anon, authenticated;
revoke execute on function public.import_airports(jsonb) from public, anon, authenticated;
revoke execute on function public.ap_weight(text[],text,float8,int) from public, anon, authenticated;
revoke execute on function public.gen_route(text,int,int,int) from public, anon, authenticated;
revoke execute on function public.spawn_request(text,int,int) from public, anon, authenticated;
revoke execute on function public.admin_import_airports(jsonb) from public, anon;
grant execute on function public.admin_import_airports(jsonb) to authenticated;
