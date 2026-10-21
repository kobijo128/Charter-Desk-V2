-- 012: ground handling requests to the departure and arrival FBOs, catering orders, and SimBrief
-- flight plans fetched by the server (no copying between sites). Safe to run more than once.

-- handling and catering on each trip; only trips booked from now on are scored on them
alter table public.trips add column if not exists handling_dep jsonb;
alter table public.trips add column if not exists handling_arr jsonb;
alter table public.trips add column if not exists catering_order jsonb;
alter table public.trips add column if not exists ground_ops boolean not null default false;
alter table public.trips alter column ground_ops set default true;

-- a plausible reference number for confirmations
create or replace function public.ref_code(p_prefix text)
returns text language sql volatile set search_path = public as $$
  select p_prefix || '-' || upper(substr(md5(random()::text), 1, 6))
$$;
revoke execute on function public.ref_code(text) from public, anon, authenticated;

create or replace function public.send_handling(p_trip bigint, p_end text, p_req jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := me(); t trips; ap airports; rec jsonb; svc jsonb;
begin
  select * into t from trips where id = p_trip and pilot_id = u for update;
  if t.id is null or t.status not in ('booked','flying') then raise exception 'That trip can''t be changed now.'; end if;
  if p_end not in ('dep','arr') then raise exception 'Choose the departure or arrival airport.'; end if;
  if p_end = 'dep' and t.handling_dep is not null then return t.handling_dep; end if;
  if p_end = 'arr' and t.handling_arr is not null then return t.handling_arr; end if;
  select * into ap from airports where icao = case when p_end = 'dep' then t.from_icao else t.to_icao end;
  svc := coalesce((select jsonb_agg(left(s, 60)) from jsonb_array_elements_text(case when jsonb_typeof(p_req->'services') = 'array' then p_req->'services' else '[]' end) s limit 20), '[]');
  rec := jsonb_strip_nulls(jsonb_build_object(
    'sent_at', now(), 'ref', ref_code('HDL'), 'agent', coalesce(ap.city, ap.icao) || ' FBO', 'icao', ap.icao,
    'time', left(p_req->>'time', 40), 'pax', least(99, greatest(0, coalesce((p_req->>'pax')::int, t.pax))),
    'fuel', nullif(left(coalesce(p_req->>'fuel', ''), 40), ''), 'services', svc,
    'notes', nullif(left(coalesce(p_req->>'notes', ''), 600), '')));
  if p_end = 'dep' then update trips set handling_dep = rec where id = t.id;
  else update trips set handling_arr = rec where id = t.id; end if;
  return rec;
end $$;
revoke execute on function public.send_handling(bigint,text,jsonb) from public, anon;
grant execute on function public.send_handling(bigint,text,jsonb) to authenticated;

create or replace function public.send_catering(p_trip bigint, p_order jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := me(); t trips; ap airports; rec jsonb;
begin
  select * into t from trips where id = p_trip and pilot_id = u for update;
  if t.id is null or t.status not in ('booked','flying') then raise exception 'That trip can''t be changed now.'; end if;
  if t.kind = 'ferry' then raise exception 'Positioning flights carry no passengers, so no catering.'; end if;
  if coalesce(t.brief->>'galley', 'cold') = 'none' then raise exception 'This aircraft has no galley, so there''s nothing to cater.'; end if;
  if t.catering_order is not null then return t.catering_order; end if;
  select * into ap from airports where icao = t.from_icao;
  rec := jsonb_strip_nulls(jsonb_build_object(
    'sent_at', now(), 'ref', ref_code('CAT'), 'supplier', coalesce(ap.city, ap.icao) || ' inflight catering',
    'deliver', left(p_order->>'deliver', 40), 'pax', t.pax,
    'menu', nullif(left(coalesce(p_order->>'menu', ''), 400), ''), 'drinks', nullif(left(coalesce(p_order->>'drinks', ''), 300), ''),
    'dietary', nullif(left(coalesce(p_order->>'dietary', ''), 300), ''), 'notes', nullif(left(coalesce(p_order->>'notes', ''), 400), '')));
  update trips set catering_order = rec where id = t.id;
  return rec;
end $$;
revoke execute on function public.send_catering(bigint,jsonb) from public, anon;
grant execute on function public.send_catering(bigint,jsonb) to authenticated;

-- ---------- SimBrief ----------
do $$ begin
  create extension if not exists http with schema extensions;
exception when others then raise notice 'The http extension isn''t available here (%), so SimBrief plans can''t be fetched by the server.', sqlerrm;
end $$;

-- secrets the site never shows (only these functions read them)
create table if not exists public.private_settings (key text primary key, value text not null);
alter table public.private_settings enable row level security;
revoke all on public.private_settings from anon, authenticated;
alter table public.va_settings add column if not exists simbrief_api boolean not null default false;

create or replace function public.admin_set_simbrief_key(p_key text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v text := nullif(trim(coalesce(p_key, '')), '');
begin
  perform require_admin();
  if v is null then delete from private_settings where key = 'simbrief_api_key';
  else insert into private_settings values ('simbrief_api_key', v) on conflict (key) do update set value = excluded.value; end if;
  update va_settings set simbrief_api = v is not null where true;
  return v is not null;
end $$;
revoke execute on function public.admin_set_simbrief_key(text) from public, anon;
grant execute on function public.admin_set_simbrief_key(text) to authenticated;

-- signs a SimBrief API request the way SimBrief's own API kit does: md5(api key + request)
create or replace function public.simbrief_sign(p_req text)
returns text language plpgsql security definer set search_path = public as $$
declare k text;
begin
  if me() is null then raise exception 'Sign in first.'; end if;
  select value into k from private_settings where key = 'simbrief_api_key';
  if k is null then raise exception 'The VA has no SimBrief API key set up.'; end if;
  return md5(k || coalesce(p_req, ''));
end $$;
revoke execute on function public.simbrief_sign(text) from public, anon;
grant execute on function public.simbrief_sign(text) to authenticated;

-- turn SimBrief's XML into the compact OFP the site stores
create or replace function public.ofp_from_xml(x xml)
returns jsonb language plpgsql immutable set search_path = public as $$
declare
  f text; v jsonb; fixes jsonb;
begin
  fixes := coalesce((
    select jsonb_agg(jsonb_build_array((xpath('/fix/ident/text()', n))[1]::text,
                                       round(((xpath('/fix/pos_lat/text()', n))[1]::text)::numeric, 4),
                                       round(((xpath('/fix/pos_long/text()', n))[1]::text)::numeric, 4)) order by ord)
    from unnest(xpath('/OFP/navlog/fix', x)) with ordinality as z(n, ord)
    where ord <= 400), '[]');
  v := jsonb_strip_nulls(jsonb_build_object(
    'orig', (xpath('/OFP/origin/icao_code/text()', x))[1]::text,
    'dest', (xpath('/OFP/destination/icao_code/text()', x))[1]::text,
    'altn', (xpath('/OFP/alternate/icao_code/text()', x))[1]::text,
    'route', left((xpath('/OFP/general/route/text()', x))[1]::text, 1500),
    'fl', 'FL' || lpad((round(((xpath('/OFP/general/initial_altitude/text()', x))[1]::text)::numeric / 100))::text, 3, '0'),
    'ramp', (xpath('/OFP/fuel/plan_ramp/text()', x))[1]::text,
    'extra', (xpath('/OFP/fuel/extra/text()', x))[1]::text,
    'landing', (xpath('/OFP/fuel/plan_landing/text()', x))[1]::text,
    'units', (xpath('/OFP/params/units/text()', x))[1]::text,
    'ete', ((xpath('/OFP/times/est_time_enroute/text()', x))[1]::text)::numeric,
    'dist', ((xpath('/OFP/general/route_distance/text()', x))[1]::text)::numeric,
    'type', (xpath('/OFP/aircraft/icaocode/text()', x))[1]::text,
    'callsign', (xpath('/OFP/atc/callsign/text()', x))[1]::text,
    'ci', (xpath('/OFP/general/costindex/text()', x))[1]::text,
    'zfw', (xpath('/OFP/weights/est_zfw/text()', x))[1]::text,
    'tow', (xpath('/OFP/weights/est_tow/text()', x))[1]::text,
    'ldw', (xpath('/OFP/weights/est_ldw/text()', x))[1]::text,
    'wind', (xpath('/OFP/general/avg_wind_comp/text()', x))[1]::text,
    'request_id', (xpath('/OFP/params/request_id/text()', x))[1]::text,
    'static_id', (xpath('/OFP/params/static_id/text()', x))[1]::text,
    'generated', to_timestamp(((xpath('/OFP/params/time_generated/text()', x))[1]::text)::bigint),
    'pdf', (xpath('/OFP/files/directory/text()', x))[1]::text || (xpath('/OFP/files/pdf/link/text()', x))[1]::text,
    'fixes', fixes));
  return v;
end $$;

-- Fetch a plan from SimBrief on the server and issue it as this trip's OFP.
-- p_ofp_id: the plan SimBrief just generated through the API. Without it, the pilot's latest plan.
-- p_since: when polling, ignore plans generated before this moment (returns status 'waiting').
create or replace function public.simbrief_import(p_trip bigint, p_ofp_id text, p_since timestamptz)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  u uuid := me(); t trips; p pilots; url text; r record; x xml; o jsonb;
begin
  select * into t from trips where id = p_trip and pilot_id = u for update;
  if t.id is null or t.status not in ('booked','flying') then raise exception 'That trip can''t be changed now.'; end if;
  select * into p from pilots where id = u;
  if nullif(p_ofp_id, '') is not null then
    if p_ofp_id !~ '^[A-Za-z0-9_]{4,80}$' then raise exception 'That isn''t a SimBrief plan reference.'; end if;
    url := 'https://www.simbrief.com/ofp/flightplans/xml/' || p_ofp_id || '.xml';
  else
    if p.simbrief_user is null then raise exception 'Link your SimBrief username first.'; end if;
    url := 'https://www.simbrief.com/api/xml.fetcher.php?username=' || extensions.urlencode(p.simbrief_user);
  end if;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT', '20');
  select * into r from extensions.http_get(url);
  if r.status = 400 and p_ofp_id is null then raise exception 'SimBrief doesn''t recognise the username %, or it has no plans yet.', p.simbrief_user; end if;
  if r.status <> 200 then raise exception 'SimBrief didn''t answer (error %). Try again in a moment.', r.status; end if;
  begin
    x := xmlparse(document r.content);
  exception when others then raise exception 'SimBrief sent something that isn''t a flight plan. Try again in a moment.';
  end;
  o := ofp_from_xml(x);
  if p_since is not null and coalesce((o->>'generated')::timestamptz, '-infinity') < p_since - interval '2 minutes' then
    return jsonb_build_object('status', 'waiting');
  end if;
  if upper(coalesce(o->>'orig', '')) <> t.from_icao or upper(coalesce(o->>'dest', '')) <> t.to_icao then
    if p_since is not null then return jsonb_build_object('status', 'waiting', 'latest', concat(o->>'orig', '–', o->>'dest')); end if;
    raise exception 'Your latest SimBrief plan is %–%, not %–%. Generate it for this trip first.', o->>'orig', o->>'dest', t.from_icao, t.to_icao;
  end if;
  if length(o::text) > 60000 then o := o - 'fixes'; end if;
  update trips set ofp = o || jsonb_build_object('saved_at', now()) where id = t.id;
  return jsonb_build_object('status', 'loaded', 'ofp', o);
end $$;
revoke execute on function public.simbrief_import(bigint,text,timestamptz) from public, anon;
grant execute on function public.simbrief_import(bigint,text,timestamptz) to authenticated;

-- the tracker session also shows handling and catering status

create or replace function public.settle(p_pirep bigint)
returns void language plpgsql set search_path = public as $$
declare
  pr public.pireps; tr public.trips; p public.pilots; ty public.aircraft_types;
  op numeric; v_cost numeric; v_rev int; v_tip int := 0; v_rep numeric := 0; est numeric; note text := ''; v_fine int := 0; v_ans int; v_miss int; v_cs int; v_g int := 0; v_needcat boolean;
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
  -- ground arrangements: handling at both ends and catering, booked before they were needed
  if tr.kind <> 'ferry' and coalesce(tr.ground_ops, false) then
    v_needcat := coalesce(tr.brief->>'galley', 'cold') <> 'none';
    if tr.handling_dep is null or (tr.handling_dep->>'sent_at')::timestamptz > pr.block_off then
      v_rep := v_rep - 0.5; note := note || format('No handling booked at %s: passengers waited on the ramp. ', tr.from_icao);
    else v_g := v_g + 1; end if;
    if tr.handling_arr is null or (tr.handling_arr->>'sent_at')::timestamptz > coalesce(pr.landing, pr.block_on) then
      v_rep := v_rep - 0.5; note := note || format('No handling booked at %s: nobody met the aircraft. ', tr.to_icao);
    else v_g := v_g + 1; end if;
    if v_needcat then
      if tr.catering_order is null or (tr.catering_order->>'sent_at')::timestamptz > pr.block_off then
        v_rep := v_rep - 1; note := note || 'Catering never arrived. ';
      else v_g := v_g + 1; end if;
    end if;
    if v_g = (case when v_needcat then 3 else 2 end) then v_rep := v_rep + 0.5; note := note || 'Ground arrangements spot on. '; end if;
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
