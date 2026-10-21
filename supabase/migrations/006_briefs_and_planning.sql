-- 006: client briefs, customs declarations, flight planning (SimBrief OFP) and fuel on board.
-- Safe to run more than once.

alter table public.trips add column if not exists brief jsonb;
alter table public.trips add column if not exists customs_needed boolean;
alter table public.trips add column if not exists customs_sent_at timestamptz;
alter table public.trips add column if not exists extra_fuel_min int;
alter table public.trips add column if not exists ofp jsonb;
alter table public.pilots add column if not exists simbrief_user text;
alter table public.fleet add column if not exists fuel_lb numeric;
alter table public.pireps add column if not exists fuel_on_block_lb numeric;
alter table public.pireps add column if not exists customs_fine int;

-- the client's (or their representative's) brief for a charter
create or replace function public.gen_brief(p_client text, p_pax int, p_dist int)
returns jsonb language plpgsql volatile set search_path = public as $$
declare who text; meal text; drinks text; diet text[] := '{}'; extras text[] := '{}'; n int; pick text; tone text;
  first text[] := array['Sarah','Tom','Claire','Marcus','Elena','James','Nadia','Oliver','Grace','Luca','Hannah','Rafael'];
  last  text[] := array['Lowe','Bennett','Dubois','Hale','Rossi','Whitford','Varga','Kerr','Moreno','Ashby','Laine','Okafor'];
  diets text[] := array['one vegetarian','one vegan','one gluten-free','a severe nut allergy (no nuts on board at all, please)','halal meals for two','one dairy-free','kosher meals for everyone','one pescatarian'];
  bits  text[] := array['a birthday cake with candles and a few balloons','champagne on ice for take-off','the Financial Times and Wall Street Journal','a small dog travelling in the cabin','four sets of golf clubs in the hold','ski equipment for the whole party','a child seat for a two-year-old','wheelchair assistance at both ends','reliable Wi-Fi: there is a call at 30 minutes after take-off','a quiet cabin, please: the principal will sleep','fresh flowers in the cabin','a car to meet the aircraft on arrival','extra blankets, they feel the cold','a bottle of Krug for the return','a cheese board instead of dessert','sparkling water only, no ice','an anniversary card on each seat','a guitar case that must travel in the cabin'];
begin
  who := first[1 + floor(random()*12)::int] || ' ' || last[1 + floor(random()*12)::int];
  who := who || case
    when p_client in ('Family office','Hedge fund','Tech founder','Private client') then ', PA to the principal'
    when p_client in ('Law firm partners','Board meeting') then ', executive assistant'
    when p_client = 'Film production' then ', production coordinator'
    when p_client in ('Football club','Motorsport team') then ', team operations'
    when p_client in ('Medical transfer','Urgent repatriation') then ', assistance company'
    when p_client = 'Wedding party' then ', wedding planner'
    when p_client = 'Yacht crew change' then ', yacht management office'
    when p_client = 'Touring musician' then ', tour manager'
    else ', for the client' end;
  meal := case when p_dist < 250 then 'light snacks and pastries'
               when p_dist < 700 then 'a cold lunch: sandwiches, salad and fruit'
               when p_dist < 1500 then 'a hot meal with a choice of fish or chicken'
               else 'full catering: breakfast, a hot main and afternoon tea' end;
  drinks := (array['coffee, tea and still water','fresh juice, coffee and sparkling water','a selection of soft drinks and two bottles of white wine','gin and tonic, beers and soft drinks','coffee, tea and a bottle of champagne'])[1 + floor(random()*5)::int];
  if p_client in ('Medical transfer','Urgent repatriation') then
    meal := 'nothing elaborate: water and simple snacks';
    drinks := 'still water';
    extras := array[(array['stretcher fitted and a flight nurse travelling','oxygen available on request','a quiet cabin and dimmed lights for the patient'])[1 + floor(random()*3)::int]];
  else
    n := floor(random()*3)::int;
    for i in 1..n loop pick := diets[1 + floor(random()*8)::int]; if not pick = any(diet) then diet := diet || pick; end if; end loop;
    n := 1 + floor(random()*2)::int;
    for i in 1..n loop pick := bits[1 + floor(random()*18)::int]; if not pick = any(extras) then extras := extras || pick; end if; end loop;
  end if;
  tone := (array['Thanks so much for taking this on.','Grateful if you could confirm all of this before departure.','They are regular clients, so please make it special.','Please call me if anything changes.'])[1 + floor(random()*4)::int];
  return jsonb_build_object('from', who, 'pax', p_pax, 'catering', meal, 'drinks', drinks, 'dietary', to_jsonb(diet), 'requests', to_jsonb(extras), 'signoff', tone);
end $$;

-- every new trip: customs needed when the countries differ; charters get a client brief
create or replace function public.trip_defaults()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.customs_needed is null then
    new.customs_needed := coalesce((select a.country <> b.country from airports a, airports b where a.icao = new.from_icao and b.icao = new.to_icao), false);
  end if;
  if new.kind = 'charter' and new.brief is null then
    new.brief := gen_brief(coalesce(new.client, 'Private client'), new.pax, new.dist);
  end if;
  return new;
end $$;
drop trigger if exists trips_defaults on public.trips;
create trigger trips_defaults before insert on public.trips for each row execute function public.trip_defaults();

-- existing open trips get the same treatment
update public.trips t set customs_needed = coalesce((select a.country <> b.country from public.airports a, public.airports b where a.icao = t.from_icao and b.icao = t.to_icao), false)
 where customs_needed is null;
update public.trips set brief = public.gen_brief(coalesce(client, 'Private client'), pax, dist) where kind = 'charter' and brief is null and status in ('booked','flying');

create or replace function public.submit_customs(p_trip bigint)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare u uuid := me(); t trips;
begin
  select * into t from trips where id = p_trip and pilot_id = u for update;
  if t.id is null or t.status not in ('booked','flying') then raise exception 'That trip can''t be changed now.'; end if;
  if not t.customs_needed then raise exception 'This is a domestic flight; no customs declaration is needed.'; end if;
  update trips set customs_sent_at = coalesce(customs_sent_at, now()) where id = t.id returning customs_sent_at into t.customs_sent_at;
  return t.customs_sent_at;
end $$;

create or replace function public.set_simbrief(p_user text)
returns void language plpgsql security definer set search_path = public as $$
declare v text := nullif(trim(coalesce(p_user,'')), '');
begin
  if v is not null and v !~ '^[A-Za-z0-9_.\-]{2,40}$' then raise exception 'That doesn''t look like a SimBrief username.'; end if;
  update pilots set simbrief_user = v where id = me();
end $$;

-- store the plan the pilot generated in SimBrief against the trip
create or replace function public.save_ofp(p_trip bigint, p_ofp jsonb, p_extra_min int)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := me(); t trips;
begin
  select * into t from trips where id = p_trip and pilot_id = u for update;
  if t.id is null or t.status not in ('booked','flying') then raise exception 'That trip can''t be changed now.'; end if;
  if p_ofp is not null then
    if upper(coalesce(p_ofp->>'orig','')) <> t.from_icao or upper(coalesce(p_ofp->>'dest','')) <> t.to_icao then
      raise exception 'Your latest SimBrief plan is %–%, not %–%. Generate it for this trip first.', p_ofp->>'orig', p_ofp->>'dest', t.from_icao, t.to_icao; end if;
    if length(p_ofp::text) > 20000 then raise exception 'That plan is too large to save.'; end if;
  end if;
  update trips set ofp = case when p_ofp is null then ofp else p_ofp || jsonb_build_object('saved_at', now()) end,
         extra_fuel_min = greatest(0, least(240, coalesce(p_extra_min, extra_fuel_min, 0)))
   where id = t.id;
end $$;


create or replace function public.settle(p_pirep bigint)
returns void language plpgsql set search_path = public as $$
declare
  pr public.pireps; tr public.trips; p public.pilots; ty public.aircraft_types;
  op numeric; v_cost numeric; v_rev int; v_tip int := 0; v_rep numeric := 0; est numeric; note text := ''; v_fine int := 0;
begin
  select * into pr from public.pireps where id = p_pirep for update;
  select * into tr from public.trips where id = pr.trip_id;
  select * into p from public.pilots where id = pr.pilot_id for update;
  select ty2.* into ty from public.fleet f join public.aircraft_types ty2 on ty2.code = f.type_code where f.id = tr.aircraft_id;
  op := public.op_rate(ty.rate, p.upgrades) * pr.block_h;

  if tr.kind = 'ferry' then
    v_rev := 0;
    v_cost := op * (1 - 0.25 * coalesce((p.upgrades->>'empty')::int,0));
    if pr.landing_fpm > 600 then v_cost := v_cost + ty.rate * 2; v_rep := -2; note := 'Hard-landing inspection. '; end if;
  else
    v_rev := tr.price; v_cost := op; v_rep := 1;
    if pr.landing_fpm is not null then
      if pr.landing_fpm <= 150 then v_tip := round(tr.price * 0.05); v_rep := 3; note := 'Butter landing, client tipped 5%. ';
      elsif pr.landing_fpm <= 300 then v_rep := 1.5;
      elsif pr.landing_fpm <= 500 then v_rep := -1; note := 'Firm landing. ';
      else v_rep := -4; v_cost := v_cost + ty.rate * 2; note := 'Hard landing: complaint and inspection. ';
      end if;
    end if;
    if pr.bounces > 0 then v_rep := v_rep - 0.5 * pr.bounces; end if;
    if tr.dep_at is not null and abs(extract(epoch from pr.block_off - tr.dep_at)) <= 1800 then
      v_rep := v_rep + 1; v_tip := v_tip + round(tr.price * 0.03); note := note || 'On time. ';
    end if;
    est := public.block_h(ty.ktas, tr.dist);
    if pr.block_h > est * 1.3 + 0.25 then v_rep := v_rep - 2; note := note || 'Well over the quoted time. '; end if;
  end if;
  if v_rep > 0 then v_rep := v_rep * (1 + 0.25 * coalesce((p.upgrades->>'pr')::int,0)); end if;
  -- international legs need a customs declaration filed before block off
  if coalesce(tr.customs_needed, false) and (tr.customs_sent_at is null or tr.customs_sent_at > pr.block_off + interval '5 minutes') then
    v_fine := 2500; v_cost := v_cost + v_fine; v_rep := v_rep - 1;
    note := note || 'Customs fine: no declaration filed before departure. ';
  end if;

  update public.pireps set status = 'accepted', revenue = v_rev + v_tip, cost = round(v_cost), tip = v_tip,
         net = v_rev + v_tip - round(v_cost), rep_delta = v_rep, customs_fine = nullif(v_fine, 0),
         review_note = coalesce(nullif(review_note,''), trim(note))
   where id = p_pirep;
  update public.pilots set cash = cash + v_rev + v_tip - round(v_cost), rep = least(100, greatest(0, rep + v_rep)) where id = p.id;
  update public.fleet set hours = hours + pr.block_h where id = tr.aircraft_id;
  update public.trips set status = 'accepted' where id = tr.id;
  perform public.add_ledger(p.id, format('%s %s–%s: revenue $%s, operating cost $%s%s', tr.flt, tr.from_icao, tr.to_icao,
          to_char(v_rev + v_tip,'FM999,999,990'), to_char(round(v_cost - v_fine),'FM999,999,990'),
          case when v_fine > 0 then format(', customs fine $%s', to_char(v_fine,'FM999,999')) else '' end), (v_rev + v_tip - round(v_cost))::bigint);
end $$;

create or replace function public.tracker_file(p_key text, p_trip bigint, d jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  u uuid := tracker_pilot(p_key); t trips; ty aircraft_types; a airports; b airports; s va_settings;
  bo timestamptz; bn timestamptz; tko timestamptz; ldg timestamptz; bh numeric; airh numeric;
  dep_nm int; arr_nm int; type_ok boolean; speed_ok boolean; ok boolean; arr text; chk jsonb; pid bigint; title text; res jsonb;
begin
  select * into t from trips where id = p_trip and pilot_id = u for update;
  if t.id is null or t.status <> 'flying' then raise exception 'That booking is not in progress.'; end if;
  select * into s from va_settings;
  select ty2.* into ty from fleet f join aircraft_types ty2 on ty2.code = f.type_code where f.id = t.aircraft_id;
  select * into a from airports where icao = t.from_icao;
  select * into b from airports where icao = t.to_icao;

  bo := (d->>'block_off')::timestamptz; bn := (d->>'block_on')::timestamptz;
  tko := nullif(d->>'takeoff','')::timestamptz; ldg := nullif(d->>'landing','')::timestamptz;
  if bo is null or bn is null or bn <= bo then raise exception 'Block times are missing or out of order.'; end if;
  bh := round(extract(epoch from bn - bo) / 3600.0, 2);
  airh := case when tko is not null and ldg is not null then round(extract(epoch from ldg - tko)/3600.0, 2) end;
  title := left(coalesce(d->>'aircraft_title',''), 120);

  dep_nm := nm((d->>'dep_lat')::float8, (d->>'dep_lon')::float8, a.lat, a.lon);
  arr_nm := nm((d->>'arr_lat')::float8, (d->>'arr_lon')::float8, b.lat, b.lon);
  type_ok := cardinality(ty.sim_match) = 0 or exists (select 1 from unnest(ty.sim_match) w where lower(title) like '%' || lower(w) || '%');
  -- a jet cannot cover the distance faster than ~1.35x its cruise speed: catches sim-rate acceleration
  speed_ok := airh is null or airh = 0 or t.dist / airh <= ty.ktas * 1.35;
  chk := jsonb_build_object(
    'departure', jsonb_build_object('ok', dep_nm <= 3, 'nm', dep_nm),
    'arrival',   jsonb_build_object('ok', arr_nm <= 3, 'nm', arr_nm),
    'aircraft',  jsonb_build_object('ok', type_ok, 'title', title),
    'speed',     jsonb_build_object('ok', speed_ok),
    'crash',     jsonb_build_object('ok', not coalesce((d->>'crashed')::boolean, false)),
    'slew',      jsonb_build_object('ok', not coalesce((d->>'slew')::boolean, false)),
    'sim_rate',  jsonb_build_object('ok', coalesce((d->>'max_sim_rate')::numeric, 1) <= 1.01, 'max', coalesce((d->>'max_sim_rate')::numeric, 1)),
    'overspeed', jsonb_build_object('ok', coalesce((d->>'overspeed_s')::int, 0) < 60, 'seconds', coalesce((d->>'overspeed_s')::int, 0)));
  select bool_and((v->>'ok')::boolean) into ok from jsonb_each(chk) e(k, v);

  if arr_nm <= 3 then arr := b.icao;
  else select icao into arr from airports order by nm((d->>'arr_lat')::float8, (d->>'arr_lon')::float8, lat, lon) limit 1; end if;

  insert into pireps(trip_id, pilot_id, aircraft_id, sim, aircraft_title, tracker_ver, block_off, takeoff, landing, block_on,
                     block_h, air_h, fuel_used_lb, landing_fpm, landing_g, bounces, arr_icao, dist_flown, checks, path)
  values (t.id, u, t.aircraft_id, left(d->>'sim', 40), title, left(d->>'tracker_ver', 20), bo, tko, ldg, bn,
          bh, airh, (d->>'fuel_used_lb')::numeric, abs((d->>'landing_fpm')::numeric)::int, (d->>'landing_g')::numeric,
          coalesce((d->>'bounces')::int, 0), arr, (d->>'dist_flown')::numeric::int, chk,
          coalesce(case when jsonb_typeof(d->'path') = 'array' and jsonb_array_length(d->'path') <= 4000 then d->'path' end, '[]'))
  returning id into pid;

  update trips set status = 'filed' where id = t.id;
  update fleet set loc = arr, fuel_lb = coalesce(nullif(d->>'fuel_on_block_lb','')::numeric, fuel_lb) where id = t.aircraft_id;
  update pireps set fuel_on_block_lb = nullif(d->>'fuel_on_block_lb','')::numeric where id = pid;
  delete from positions where pilot_id = u;
  if arr <> t.to_icao then perform rebuild_ferries(t.aircraft_id); end if;

  if ok and s.auto_accept then perform settle(pid); end if;
  select jsonb_build_object('pirep', id, 'status', status, 'net', net, 'rep_delta', rep_delta, 'checks', checks, 'note', review_note)
    into res from pireps where id = pid;
  return res;
end $$;

create or replace function public.tracker_session(p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := tracker_pilot(p_key); res jsonb;
begin
  update pilots set last_seen = now() where id = u;
  select jsonb_build_object(
    'pilot', (select jsonb_build_object('callsign', callsign, 'name', name, 'company', company) from pilots where id = u),
    'trips', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', t.id, 'flt', t.flt, 'kind', t.kind, 'status', t.status,
        'from', t.from_icao, 'to', t.to_icao, 'dist', t.dist, 'pax', t.pax, 'dep_at', t.dep_at,
        'from_lat', a.lat, 'from_lon', a.lon, 'to_lat', b.lat, 'to_lon', b.lon,
        'reg', f.reg, 'type', f.type_code, 'type_name', ty.name, 'sim_match', ty.sim_match,
        'customs_needed', coalesce(t.customs_needed, false), 'customs_sent', t.customs_sent_at is not null,
        'brief', t.brief, 'ofp', t.ofp) order by t.dep_at nulls first)
      from trips t
      join fleet f on f.id = t.aircraft_id
      join aircraft_types ty on ty.code = f.type_code
      join airports a on a.icao = t.from_icao
      join airports b on b.icao = t.to_icao
      where t.pilot_id = u and t.status in ('booked','flying')
        and t.seq = (select min(seq) from trips t2 where t2.aircraft_id = t.aircraft_id and t2.status in ('booked','flying'))
    ), '[]')) into res;
  return res;
end $$;

revoke execute on function public.gen_brief(text,int,int) from public, anon, authenticated;
revoke execute on function public.trip_defaults() from public, anon, authenticated;
revoke execute on function public.settle(bigint) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['submit_customs(bigint)','set_simbrief(text)','save_ofp(bigint,jsonb,int)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
