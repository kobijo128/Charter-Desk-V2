-- 008: realistic departure times (operating hours, "go now" jobs), positioning legs shown as arrive-by,
-- catering that matches the aircraft's galley, and special requests that fit the trip.
-- Safe to run more than once.

-- departure time for a new job: 40% go now (about an hour away), the rest later today or tomorrow,
-- always within 06:00–22:30 local time at the departure airport
create or replace function public.pick_dep(p_lon float8, p_cat text)
returns timestamptz language plpgsql volatile set search_path = public as $$
declare r float8 := random(); lead numeric; dep timestamptz; off int; lh numeric;
begin
  lead := case when p_cat = 'urgent' or r < 0.4 then 0.85 + random() * 1.0
               when r < 0.75 then 3 + random() * 11
               else 14 + random() * 26 end;
  dep := now() + lead * interval '1 hour';
  off := round(p_lon / 15)::int;
  lh := extract(hour from (dep at time zone 'UTC')) + off + extract(minute from (dep at time zone 'UTC')) / 60.0;
  lh := ((lh::numeric % 24) + 24) % 24;
  if lh < 6 then dep := dep + (6 - lh + random() * 2) * interval '1 hour';
  elsif lh > 22.5 then dep := dep + (24 - lh + 6.5 + random() * 2.5) * interval '1 hour';
  end if;
  return to_timestamp(ceil(extract(epoch from dep) / 300) * 300);
end $$;

create or replace function public.galley_of(p_category text, p_code text)
returns text language sql immutable set search_path = public as $$
  select case when p_category in ('piston') then 'none'
              when p_category in ('turboprop','light') then 'cold'
              when p_category = 'mid' then 'warm'
              else 'full' end
$$;

-- a brief that suits the aircraft and the destination
create or replace function public.gen_brief2(p_client text, p_pax int, p_dist int, p_galley text, p_dest_tags text[], p_dest text)
returns jsonb language plpgsql volatile set search_path = public as $$
declare who text; meal text; drinks text; diet text[] := '{}'; extras text[] := '{}'; pool text[]; n int; pick text; tone text; g text := coalesce(p_galley, 'cold');
  first text[] := array['Sarah','Tom','Claire','Marcus','Elena','James','Nadia','Oliver','Grace','Luca','Hannah','Rafael'];
  last  text[] := array['Lowe','Bennett','Dubois','Hale','Rossi','Whitford','Varga','Kerr','Moreno','Ashby','Laine','Okafor'];
  diets text[] := array['one vegetarian','one vegan','one gluten-free','a severe nut allergy (no nuts on board at all, please)','halal meals for two','one dairy-free','one pescatarian'];
begin
  who := first[1 + floor(random()*12)::int] || ' ' || last[1 + floor(random()*12)::int] || case
    when p_client in ('Family office','Hedge fund','Tech founder','Private client') then ', PA to the principal'
    when p_client in ('Law firm partners','Board meeting') then ', executive assistant'
    when p_client = 'Film production' then ', production coordinator'
    when p_client in ('Football club','Motorsport team') then ', team operations'
    when p_client in ('Medical transfer','Urgent repatriation') then ', assistance company'
    when p_client = 'Wedding party' then ', wedding planner'
    when p_client = 'Yacht crew change' then ', yacht management office'
    when p_client = 'Touring musician' then ', tour manager'
    when p_client = 'Ski chalet guests' then ', chalet company'
    when p_client = 'Golf weekend' then ', for the group'
    else ', for the client' end;

  -- catering is limited by the galley: small aircraft can't heat food
  meal := case g
    when 'none' then 'bottled water and a few snacks; there''s no cabin service on this aircraft'
    when 'cold' then case when p_dist < 300 then 'pastries and fruit' when p_dist < 900 then 'a cold platter: sandwiches, salad and fruit' else 'a substantial cold platter: sushi, salads, cheese and fruit' end
    when 'warm' then case when p_dist < 300 then 'pastries and fruit' when p_dist < 900 then 'warmed breakfast rolls or a light warm snack' else 'a warmed main from the oven: chicken or salmon, with salad' end
    else case when p_dist < 300 then 'canapés and fresh fruit' when p_dist < 1200 then 'a hot three-course meal plated on board' else 'full service: breakfast, a hot main from the galley and afternoon tea' end end;
  drinks := case g when 'none' then 'still water'
    else (array['coffee, tea and still water','fresh juice, coffee and sparkling water','soft drinks and two bottles of white wine','gin and tonic, beers and soft drinks','coffee, tea and a bottle of champagne'])[1 + floor(random()*5)::int] end;
  if g in ('cold','warm') and random() < 0.5 then drinks := drinks || ' (thermos coffee is fine)'; end if;

  if p_client in ('Medical transfer','Urgent repatriation') then
    meal := 'nothing elaborate: water and simple snacks'; drinks := 'still water';
    extras := array[(array['stretcher fitted and a flight nurse travelling','oxygen available on request','a quiet cabin and dimmed lights for the patient'])[1 + floor(random()*3)::int]];
  else
    n := floor(random()*3)::int;
    for i in 1..n loop pick := diets[1 + floor(random()*7)::int]; if not pick = any(diet) then diet := diet || pick; end if; end loop;
    pool := array['the Financial Times and Wall Street Journal','a small dog travelling in the cabin','a child seat for a two-year-old',
                  'wheelchair assistance at both ends','a quiet cabin, please: the principal will sleep','a car to meet the aircraft on arrival',
                  'extra blankets, they feel the cold','sparkling water only, no ice','an extra bag that must travel in the cabin'];
    if g <> 'none' then pool := pool || array['champagne on ice for take-off','fresh flowers in the cabin','a birthday cake with candles (no lit candles in flight, of course)']; end if;
    if g in ('warm','full') then pool := pool || array['reliable Wi-Fi: there is a call 30 minutes after take-off','a cheese board instead of dessert']; end if;
    if 'ski' = any(coalesce(p_dest_tags,'{}')) or p_client = 'Ski chalet guests' then pool := pool || array['ski equipment for the whole party in the hold','boot bags and helmets in the hold']; end if;
    if p_client = 'Golf weekend' or 'leisure' = any(coalesce(p_dest_tags,'{}')) then pool := pool || array['four sets of golf clubs in the hold','beach bags and a pushchair']; end if;
    if p_client = 'Wedding party' then pool := pool || array['a garment bag with the wedding dress, hung flat in the cabin','an anniversary card on each seat']; end if;
    if p_client = 'Touring musician' then pool := pool || array['a guitar case that must travel in the cabin']; end if;
    n := 1 + floor(random()*2)::int;
    for i in 1..n loop pick := pool[1 + floor(random()*array_length(pool,1))::int]; if not pick = any(extras) then extras := extras || pick; end if; end loop;
  end if;
  tone := (array['Thanks so much for taking this on.','Grateful if you could confirm all of this before departure.','They are regular clients, so please make it special.','Please call me if anything changes.'])[1 + floor(random()*4)::int];
  return jsonb_build_object('from', who, 'pax', p_pax, 'catering', meal, 'drinks', drinks, 'dietary', to_jsonb(diet), 'requests', to_jsonb(extras), 'signoff', tone, 'galley', g);
end $$;

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
    r.dep_at := pick_dep(f.lon, c.cat);
    return r;
  end loop;
  return null;
end $$;

create or replace function public.spawn_request(p_near text, p_max_nm int, p_max_pax int)
returns bigint language plpgsql volatile set search_path = public as $$
declare r public.route_pick; rid bigint;
begin
  r := gen_route(p_near, p_max_nm, p_max_pax, null);
  if r.from_icao is null then return null; end if;
  insert into requests(from_icao,to_icao,dist,pax,client,cat,npc,dep_at,expires_at)
  values (r.from_icao, r.to_icao, r.dist, r.pax, r.client, r.cat, 2 + floor(random()*5)::int, r.dep_at,
          least(now() + (14 + random()*26) * interval '1 minute', r.dep_at - interval '20 minutes'))
  returning id into rid;
  insert into request_secrets(request_id, budget_mul) values (rid, r.budget_mul);
  return rid;
end $$;

create or replace function public.rebuild_ferries(p_ac uuid)
returns void language plpgsql set search_path = public as $$
declare loc text; n int := 0; t record; ac public.fleet;
begin
  select * into ac from public.fleet where id = p_ac;
  loc := ac.loc;
  delete from public.trips where aircraft_id = p_ac and kind = 'ferry' and status = 'booked';
  for t in select * from public.trips where aircraft_id = p_ac and status in ('flying','booked') order by seq, id loop
    if t.status = 'flying' then
      n := n + 1; update public.trips set seq = n where id = t.id; loc := t.to_icao; continue;
    end if;
    if t.from_icao <> loc then
      n := n + 1;
      insert into public.trips(pilot_id, aircraft_id, kind, flt, from_icao, to_icao, dist, source, seq, dep_at)
      values (ac.pilot_id, p_ac, 'ferry', public.flt_no(ac.pilot_id, true), loc, t.from_icao,
              public.ap_nm(loc, t.from_icao), 'ferry', n, t.dep_at - interval '45 minutes');
    end if;
    n := n + 1; update public.trips set seq = n where id = t.id; loc := t.to_icao;
  end loop;
end $$;

create or replace function public.trip_defaults()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.customs_needed is null then
    new.customs_needed := coalesce((select a.country <> b.country from airports a, airports b where a.icao = new.from_icao and b.icao = new.to_icao), false);
  end if;
  if new.kind = 'charter' and new.brief is null then
    new.brief := gen_brief2(coalesce(new.client, 'Private client'), new.pax, new.dist,
                            (select galley_of(t.category, t.code) from fleet f join aircraft_types t on t.code = f.type_code where f.id = new.aircraft_id),
                            (select tags from airports where icao = new.to_icao), new.to_icao);
  end if;
  return new;
end $$;

-- bring what's already booked into line: new briefs, positioning legs re-timed
update public.trips t set brief = public.gen_brief2(coalesce(t.client,'Private client'), t.pax, t.dist,
       (select public.galley_of(ty.category, ty.code) from public.fleet f join public.aircraft_types ty on ty.code = f.type_code where f.id = t.aircraft_id),
       (select tags from public.airports where icao = t.to_icao), t.to_icao)
 where t.kind = 'charter' and t.status = 'booked';
update public.trips t set dep_at = (select c.dep_at - interval '45 minutes' from public.trips c
                                     where c.aircraft_id = t.aircraft_id and c.seq = t.seq + 1 and c.status = 'booked')
 where t.kind = 'ferry' and t.status = 'booked'
   and exists (select 1 from public.trips c where c.aircraft_id = t.aircraft_id and c.seq = t.seq + 1 and c.status = 'booked');
-- open requests at night get realistic times too
update public.requests r set dep_at = public.pick_dep((select lon from public.airports where icao = r.from_icao), r.cat)
 where r.status = 'open';
update public.requests set expires_at = least(expires_at, dep_at - interval '20 minutes') where status = 'open';

revoke execute on function public.pick_dep(float8,text) from public, anon, authenticated;
revoke execute on function public.galley_of(text,text) from public, anon, authenticated;
revoke execute on function public.gen_brief2(text,int,int,text,text[],text) from public, anon, authenticated;
revoke execute on function public.rebuild_ferries(uuid) from public, anon, authenticated;
