-- 011: richer flight reports. Runway data for touchdown analysis (runway used, centreline accuracy,
-- touchdown distance), landing and comfort scores, and points for pilots. Safe to run more than once.

-- runways from OurAirports (public domain); staff load them from the Staff page
create table if not exists public.runways (
  icao       text not null,
  le_ident   text not null,
  he_ident   text not null,
  le_lat     float8 not null, le_lon float8 not null,
  he_lat     float8 not null, he_lon float8 not null,
  le_disp_ft int not null default 0,
  he_disp_ft int not null default 0,
  length_ft  int,
  width_ft   int,
  surface    text,
  primary key (icao, le_ident, he_ident)
);
alter table public.runways enable row level security;
drop policy if exists read_all on public.runways;
create policy read_all on public.runways for select using (true);
grant select on public.runways to anon, authenticated;

alter table public.pireps add column if not exists stats jsonb not null default '{}';
alter table public.pireps add column if not exists landing_score int;
alter table public.pireps add column if not exists comfort_score int;
alter table public.pireps add column if not exists points int;
alter table public.pilots add column if not exists points int not null default 0;

-- rows: [icao, le_ident, he_ident, le_lat, le_lon, he_lat, he_lon, le_disp_ft, he_disp_ft, length_ft, width_ft, surface]
create or replace function public.import_runways(p_rows jsonb)
returns int language plpgsql set search_path = public as $$
declare n int;
begin
  insert into runways(icao, le_ident, he_ident, le_lat, le_lon, he_lat, he_lon, le_disp_ft, he_disp_ft, length_ft, width_ft, surface)
  select upper(r->>0), r->>1, r->>2, (r->>3)::float8, (r->>4)::float8, (r->>5)::float8, (r->>6)::float8,
         coalesce(nullif(r->>7,'')::numeric::int, 0), coalesce(nullif(r->>8,'')::numeric::int, 0),
         nullif(r->>9,'')::numeric::int, nullif(r->>10,'')::numeric::int, nullif(r->>11,'')
    from jsonb_array_elements(p_rows) r
   where r->>0 is not null and r->>3 is not null and r->>5 is not null
  on conflict (icao, le_ident, he_ident) do update set
    le_lat = excluded.le_lat, le_lon = excluded.le_lon, he_lat = excluded.he_lat, he_lon = excluded.he_lon,
    le_disp_ft = excluded.le_disp_ft, he_disp_ft = excluded.he_disp_ft, length_ft = excluded.length_ft,
    width_ft = excluded.width_ft, surface = excluded.surface;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.import_runways(jsonb) from public, anon, authenticated;

create or replace function public.admin_import_runways(p_rows jsonb)
returns int language plpgsql security definer set search_path = public as $$
begin
  perform require_admin();
  return import_runways(p_rows);
end $$;
revoke execute on function public.admin_import_runways(jsonb) from public, anon;
grant execute on function public.admin_import_runways(jsonb) to authenticated;

-- Which runway the aircraft landed on, how far past the landing threshold it touched down,
-- and how close to the centreline it stayed. Distances on a local flat projection (fine over a few km).
create or replace function public.analyse_touchdown(p_icao text, p_lat float8, p_lon float8, p_hdg float8, p_roll jsonb)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  rw record; best jsonb; best_score float8 := 1e12; k float8; tx float8; ty float8; fx float8; fy float8;
  ux float8; uy float8; len float8; px float8; py float8; along float8; xoff float8; brg float8; dh float8; sc float8;
  dir int; t_lat float8; t_lon float8; f_lat float8; f_lon float8; disp float8; ident text; opp text;
  pt jsonb; c float8; cmax float8; csum float8; cn int;
begin
  if p_icao is null or p_lat is null or p_lon is null then return '{}'; end if;
  k := cos(radians(p_lat));
  for rw in select * from runways where icao = p_icao loop
    for dir in 0..1 loop
      if dir = 0 then t_lat := rw.le_lat; t_lon := rw.le_lon; f_lat := rw.he_lat; f_lon := rw.he_lon; disp := rw.le_disp_ft; ident := rw.le_ident; opp := rw.he_ident;
      else            t_lat := rw.he_lat; t_lon := rw.he_lon; f_lat := rw.le_lat; f_lon := rw.le_lon; disp := rw.he_disp_ft; ident := rw.he_ident; opp := rw.le_ident; end if;
      fx := (f_lon - t_lon) * k * 111320; fy := (f_lat - t_lat) * 110540;
      len := sqrt(fx*fx + fy*fy);
      continue when len < 100;
      ux := fx / len; uy := fy / len;
      px := (p_lon - t_lon) * k * 111320; py := (p_lat - t_lat) * 110540;
      along := px*ux + py*uy;
      xoff := px*uy - py*ux;            -- positive: right of the centreline, looking down the runway
      brg := mod(degrees(atan2(ux, uy))::numeric + 360, 360)::float8;
      dh := case when p_hdg is null then 0 else abs(mod((p_hdg - brg + 540)::numeric, 360) - 180)::float8 end;
      continue when dh > 45 or abs(xoff) > 150 or along < -600 or along > len + 300;
      sc := abs(xoff) + dh * 2;
      if sc < best_score then
        best_score := sc;
        -- centreline over the rollout (points while still fast after touchdown)
        cmax := abs(xoff); csum := 0; cn := 0;
        if jsonb_typeof(p_roll) = 'array' then
          for pt in select * from jsonb_array_elements(p_roll) limit 200 loop
            px := ((pt->>1)::float8 - t_lon) * k * 111320; py := ((pt->>0)::float8 - t_lat) * 110540;
            c := abs(px*uy - py*ux);
            if c < 150 then cmax := greatest(cmax, c); csum := csum + c; cn := cn + 1; end if;
          end loop;
        end if;
        best := jsonb_build_object(
          'runway', ident, 'opposite', opp, 'length_ft', coalesce(rw.length_ft, round(len * 3.28084)), 'width_ft', rw.width_ft,
          'td_ft', round(along * 3.28084 - disp), 'cl_m', round(xoff::numeric, 1),
          'cl_max_m', round(cmax::numeric, 1), 'cl_avg_m', case when cn > 0 then round((csum / cn)::numeric, 1) end,
          'remaining_ft', round((len - along) * 3.28084), 'disp_ft', disp,
          'rwy', jsonb_build_array(round(t_lat::numeric, 6), round(t_lon::numeric, 6), round(f_lat::numeric, 6), round(f_lon::numeric, 6)),
          'td', jsonb_build_array(round(p_lat::numeric, 6), round(p_lon::numeric, 6)));
      end if;
    end loop;
  end loop;
  return coalesce(best, '{}');
end $$;
revoke execute on function public.analyse_touchdown(text,float8,float8,float8,jsonb) from public, anon, authenticated;

-- Landing score out of 100: rate of descent, G, bounces, centreline, touchdown zone, nose-first touchdowns
create or replace function public.landing_score(p_fpm int, p_g numeric, p_bounces int, p_cl_m numeric, p_td_ft numeric, p_pitch numeric)
returns int language plpgsql immutable set search_path = public as $$
declare s numeric := 100; f numeric := coalesce(p_fpm, 0);
begin
  s := s - case when f < 50 then 8                                   -- floated it on: long and hard to repeat
                when f <= 180 then 0
                when f <= 300 then (f - 180) / 6.0                   -- up to 20
                when f <= 450 then 20 + (f - 300) / 5.0              -- up to 50
                when f <= 600 then 50 + (f - 450) / 7.5              -- up to 70
                else 80 end;
  if p_g is not null and p_g > 1.35 then s := s - least(25, (p_g - 1.35) * 50); end if;
  s := s - 12 * least(coalesce(p_bounces, 0), 4);
  if p_cl_m is not null and abs(p_cl_m) > 2 then s := s - least(20, (abs(p_cl_m) - 2) * 2); end if;
  if p_td_ft is not null then
    s := s - case when p_td_ft < 0 then 30                            -- short of the threshold
                  when p_td_ft < 300 then 8
                  when p_td_ft <= 2500 then 0
                  else least(25, (p_td_ft - 2500) / 100.0) end;
  end if;
  if p_pitch is not null and p_pitch < -0.5 then s := s - 15; end if;   -- nose wheel first
  return greatest(0, least(100, round(s)))::int;
end $$;

-- Comfort score out of 100 from what the passengers felt over the whole flight
create or replace function public.comfort_score(c jsonb)
returns int language plpgsql immutable set search_path = public as $$
declare s numeric := 100; v numeric;
begin
  v := coalesce((c->>'g_s')::numeric, 0);            s := s - least(25, v * 0.5);   -- seconds of noticeable G (|G-1| > 0.25)
  v := coalesce((c->>'bank_s')::numeric, 0);         s := s - least(20, v * 1.0);   -- seconds banked past 30°
  if coalesce((c->>'max_bank')::numeric, 0) > 45 then s := s - 10; end if;
  v := coalesce((c->>'pitch_s')::numeric, 0);        s := s - least(15, v * 1.0);   -- seconds nose up past 18° or down past 8°
  v := coalesce((c->>'vs_s')::numeric, 0);           s := s - least(10, v * 0.3);   -- seconds descending faster than 3,500 fpm
  v := coalesce((c->>'taxi_fast_s')::numeric, 0);    s := s - least(10, v * 0.5);   -- seconds taxiing faster than 30 kt
  v := coalesce((c->>'hard_brake_n')::numeric, 0);   s := s - least(12, v * 4);     -- sharp stops while taxiing
  return greatest(0, least(100, round(s)))::int;
end $$;

create or replace function public.tracker_file(p_key text, p_trip bigint, d jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  u uuid := tracker_pilot(p_key); t trips; ty aircraft_types; a airports; b airports; s va_settings;
  bo timestamptz; bn timestamptz; tko timestamptz; ldg timestamptz; bh numeric; airh numeric;
  dep_nm int; arr_nm int; td jsonb; cf jsonb; v_stats jsonb; v_ls int; v_cs int; type_ok boolean; speed_ok boolean; ok boolean; arr text; chk jsonb; pid bigint; title text; res jsonb;
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

  -- touchdown analysis against the runway, and the comfort of the flight
  td := case when jsonb_typeof(d->'touchdown') = 'object' then
          analyse_touchdown(arr, (d->'touchdown'->>'lat')::float8, (d->'touchdown'->>'lon')::float8,
                            nullif(d->'touchdown'->>'hdg_true','')::float8, coalesce(d->'rollout', '[]'))
        else '{}' end;
  cf := case when jsonb_typeof(d->'comfort') = 'object' then d->'comfort' else '{}' end;
  v_stats := jsonb_strip_nulls(jsonb_build_object(
    'touchdown', td || coalesce(jsonb_strip_nulls(jsonb_build_object(
        'ias', round(nullif(d->'touchdown'->>'ias','')::numeric), 'gs', round(nullif(d->'touchdown'->>'gs','')::numeric),
        'pitch', round(nullif(d->'touchdown'->>'pitch','')::numeric, 1), 'bank', round(nullif(d->'touchdown'->>'bank','')::numeric, 1),
        'wind_dir', round(nullif(d->'touchdown'->>'wind_dir','')::numeric), 'wind_kt', round(nullif(d->'touchdown'->>'wind_kt','')::numeric))), '{}'),
    'comfort', cf,
    'taxi_out_min', case when tko is not null then round(extract(epoch from tko - bo) / 60.0, 1) end,
    'taxi_in_min',  case when ldg is not null then round(extract(epoch from bn - ldg) / 60.0, 1) end,
    'max_alt_ft', nullif(d->>'max_alt_ft','')::numeric::int,
    'fuel_used_lb', nullif(d->>'fuel_used_lb','')::numeric));
  v_ls := case when nullif(d->>'landing_fpm','') is not null then
            landing_score(abs((d->>'landing_fpm')::numeric)::int, nullif(d->>'landing_g','')::numeric, coalesce((d->>'bounces')::int, 0),
                          (td->>'cl_m')::numeric, (td->>'td_ft')::numeric, nullif(d->'touchdown'->>'pitch','')::numeric) end;
  v_cs := case when cf <> '{}' then comfort_score(cf) end;

  insert into pireps(trip_id, pilot_id, aircraft_id, sim, aircraft_title, tracker_ver, block_off, takeoff, landing, block_on,
                     block_h, air_h, fuel_used_lb, landing_fpm, landing_g, bounces, arr_icao, dist_flown, checks, path,
                     stats, landing_score, comfort_score, points)
  values (t.id, u, t.aircraft_id, left(d->>'sim', 40), title, left(d->>'tracker_ver', 20), bo, tko, ldg, bn,
          bh, airh, (d->>'fuel_used_lb')::numeric, abs((d->>'landing_fpm')::numeric)::int, (d->>'landing_g')::numeric,
          coalesce((d->>'bounces')::int, 0), arr, (d->>'dist_flown')::numeric::int, chk,
          coalesce(case when jsonb_typeof(d->'path') = 'array' and jsonb_array_length(d->'path') <= 4000 then d->'path' end, '[]'),
          v_stats, v_ls, v_cs, coalesce(v_ls, 0) + coalesce(v_cs, 0))
  returning id into pid;

  update trips set status = 'filed' where id = t.id;
  update fleet set loc = arr, fuel_lb = coalesce(nullif(d->>'fuel_on_block_lb','')::numeric, fuel_lb) where id = t.aircraft_id;
  update pireps set fuel_on_block_lb = nullif(d->>'fuel_on_block_lb','')::numeric where id = pid;
  delete from positions where pilot_id = u;
  if arr <> t.to_icao then perform rebuild_ferries(t.aircraft_id); end if;

  if ok and s.auto_accept then perform settle(pid); end if;
  select jsonb_build_object('pirep', id, 'status', status, 'net', net, 'rep_delta', rep_delta, 'checks', checks, 'note', review_note,
                            'stats', stats, 'landing_score', landing_score, 'comfort_score', comfort_score, 'points', points)
    into res from pireps where id = pid;
  return res;
end $$;

create or replace function public.settle(p_pirep bigint)
returns void language plpgsql set search_path = public as $$
declare
  pr public.pireps; tr public.trips; p public.pilots; ty public.aircraft_types;
  op numeric; v_cost numeric; v_rev int; v_tip int := 0; v_rep numeric := 0; est numeric; note text := ''; v_fine int := 0; v_ans int; v_miss int; v_cs int;
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
  -- how smooth the ride was
  v_cs := pr.comfort_score;
  if v_cs is not null and tr.kind <> 'ferry' then
    if v_cs >= 90 then v_tip := v_tip + round(tr.price * 0.02); v_rep := v_rep + 0.5; note := note || format('Smooth flight (comfort %s): extra 2%% tip. ', v_cs);
    elsif v_cs < 60 then v_rep := v_rep - 1; note := note || format('Rough ride (comfort %s): passengers complained. ', v_cs);
    end if;
  end if;
  if v_rep > 0 then v_rep := v_rep * (1 + 0.25 * coalesce((p.upgrades->>'pr')::int,0)); end if;
  -- how the cabin was looked after
  select count(*) filter (where status = 'answered'), count(*) filter (where status = 'missed') into v_ans, v_miss from pax_requests where trip_id = tr.id;
  if v_ans + v_miss > 0 then
    note := note || format('Passengers: %s request%s answered%s. ', v_ans, case when v_ans = 1 then '' else 's' end,
                           case when v_miss > 0 then format(', %s missed', v_miss) else '' end);
  end if;
  -- international legs need a customs declaration filed before block off
  if coalesce(tr.customs_needed, false) and (tr.customs_sent_at is null or tr.customs_sent_at > pr.block_off + interval '5 minutes') then
    v_fine := 2500; v_cost := v_cost + v_fine; v_rep := v_rep - 1;
    note := note || 'Customs fine: no declaration filed before departure. ';
  end if;

  update public.pireps set status = 'accepted', revenue = v_rev + v_tip, cost = round(v_cost), tip = v_tip,
         net = v_rev + v_tip - round(v_cost), rep_delta = v_rep, customs_fine = nullif(v_fine, 0),
         review_note = coalesce(nullif(review_note,''), trim(note))
   where id = p_pirep;
  update public.pilots set cash = cash + v_rev + v_tip - round(v_cost), rep = least(100, greatest(0, rep + v_rep)),
         points = points + coalesce(pr.points, 0) where id = p.id;
  update public.fleet set hours = hours + pr.block_h where id = tr.aircraft_id;
  update public.trips set status = 'accepted' where id = tr.id;
  perform public.add_ledger(p.id, format('%s %s–%s: revenue $%s, operating cost $%s%s', tr.flt, tr.from_icao, tr.to_icao,
          to_char(v_rev + v_tip,'FM999,999,990'), to_char(round(v_cost - v_fine),'FM999,999,990'),
          case when v_fine > 0 then format(', customs fine $%s', to_char(v_fine,'FM999,999')) else '' end), (v_rev + v_tip - round(v_cost))::bigint);
end $$;

-- leaderboard and stats need nothing new to read: pireps and pilots are already readable by signed-in pilots

-- the tracker shows fuel in the pilot's units and their points total
create or replace function public.tracker_session(p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := tracker_pilot(p_key); res jsonb;
begin
  update pilots set last_seen = now() where id = u;
  select jsonb_build_object(
    'pilot', (select jsonb_build_object('callsign', callsign, 'name', name, 'company', company, 'prefs', prefs, 'points', points) from pilots where id = u),
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
