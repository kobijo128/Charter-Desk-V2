-- 005: hired crew. Pilots hire captains and first officers, pay salaries, type training,
-- recurrent training and 6-monthly OPCs. Crew-operated aircraft fly real-time charters on their own.
-- Safe to run more than once.

alter table public.fleet add column if not exists ops text not null default 'pilot';
alter table public.fleet add column if not exists crew_busy_until timestamptz;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'fleet_ops_check') then
    alter table public.fleet add constraint fleet_ops_check check (ops in ('pilot','crew'));
  end if;
end $$;

create table if not exists public.crew (
  id             bigint generated always as identity primary key,
  pilot_id       uuid not null references public.pilots on delete cascade,
  name           text not null,
  role           text not null check (role in ('captain','fo')),
  type_code      text not null references public.aircraft_types,
  experience     int  not null,              -- years
  skill          numeric not null,           -- 0.85 to 1.15
  salary         numeric not null,           -- per month, USD
  satisfaction   numeric not null default 80,
  status         text not null default 'training' check (status in ('training','active','left')),
  aircraft_id    uuid references public.fleet on delete set null,
  trained_at     timestamptz not null,
  busy_until     timestamptz,
  opc_due        timestamptz not null,
  recurrent_due  timestamptz not null,
  next_pay       timestamptz not null,
  sat_checked    timestamptz not null default now(),
  raise_asked    boolean not null default false,
  notice_until   timestamptz,
  hours          numeric not null default 0,
  hired_at       timestamptz not null default now()
);
create index if not exists crew_pilot on public.crew(pilot_id, status);

create table if not exists public.crew_candidates (
  id          bigint generated always as identity primary key,
  pilot_id    uuid not null references public.pilots on delete cascade,
  name        text not null,
  role        text not null,
  experience  int not null,
  skill       numeric not null,
  category    text not null,
  salary_ask  numeric not null,
  expires_at  timestamptz not null
);

create table if not exists public.crew_legs (
  id          bigint generated always as identity primary key,
  pilot_id    uuid not null references public.pilots on delete cascade,
  aircraft_id uuid references public.fleet on delete set null,
  reg         text not null,
  from_icao   text not null,
  to_icao     text not null,
  dist        int not null,
  pax         int not null,
  client      text not null,
  dep_at      timestamptz not null,
  arr_at      timestamptz not null,
  block_h     numeric not null,
  revenue     numeric not null,
  cost        numeric not null,
  status      text not null default 'flying' check (status in ('flying','done'))
);
create index if not exists crew_legs_open on public.crew_legs(status, arr_at);

alter table public.crew enable row level security;
alter table public.crew_candidates enable row level security;
alter table public.crew_legs enable row level security;
revoke insert, update, delete, truncate on public.crew, public.crew_candidates, public.crew_legs from anon, authenticated;
drop policy if exists read_own on public.crew;            create policy read_own on public.crew for select to authenticated using (pilot_id = auth.uid());
drop policy if exists read_own on public.crew_candidates; create policy read_own on public.crew_candidates for select to authenticated using (pilot_id = auth.uid());
drop policy if exists read_own on public.crew_legs;       create policy read_own on public.crew_legs for select to authenticated using (pilot_id = auth.uid());

-- pay scales by aircraft category, USD
create or replace function public.crew_rates(p_category text)
returns table(salary numeric, training numeric, opc numeric) language sql immutable set search_path = public as $$
  select s, t, o from (values
    ('piston', 5500::numeric, 6000::numeric, 2000::numeric),
    ('turboprop', 8000, 20000, 4000),
    ('light', 11000, 35000, 6000),
    ('mid', 14000, 50000, 8000),
    ('large', 19000, 75000, 12000)) v(c, s, t, o)
  where c = p_category
$$;

create or replace function public.company_income30(p_pilot uuid)
returns numeric language sql stable set search_path = public as $$
  select coalesce((select sum(revenue) from pireps where pilot_id = p_pilot and status = 'accepted' and created_at > now() - interval '30 days'), 0)
       + coalesce((select sum(revenue) from crew_legs where pilot_id = p_pilot and status = 'done' and arr_at > now() - interval '30 days'), 0)
$$;

-- what a crew member expects to earn: their grade, plus more as the company does well
create or replace function public.crew_expected(p_crew public.crew)
returns numeric language sql stable set search_path = public as $$
  select r.salary * (case when p_crew.role = 'fo' then 0.6 else 1 end) * (0.8 + 0.025 * least(p_crew.experience, 20))
         * (1 + 0.2 * log(2, 1 + coalesce(public.company_income30(p_crew.pilot_id), 0) / 100000.0))
    from aircraft_types t, crew_rates(t.category) r where t.code = p_crew.type_code
$$;



create or replace function public.crew_ready(p_crew public.crew)
returns boolean language sql stable set search_path = public as $$
  select p_crew.status = 'active' and p_crew.trained_at <= now() and coalesce(p_crew.busy_until, now()) <= now()
     and p_crew.opc_due > now() and p_crew.recurrent_due > now() and p_crew.notice_until is null
$$;

-- a fresh list of people looking for work, refreshed every 12 hours
create or replace function public.refresh_candidates()
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := me(); n int; cat text; role text; ex int; sk numeric; r record;
  firsts text[] := array['Amelia','James','Sofia','Lucas','Emma','Noah','Chloe','Oliver','Isabel','Henrik','Marta','Theo','Ana','Rafael','Leah','Tom','Ingrid','Luca','Freya','Marco','Nadia','Felix','Elena','Sam','Priya','Daniel','Yuki','Omar','Hanna','Pierre'];
  lasts text[] := array['Hart','Moreau','Lindqvist','Rossi','Kowalski','Byrne','Silva','Becker','Novak','Duarte','Okafor','Hughes','Jensen','Martin','Costa','Fischer','Laurent','Walsh','Nakamura','Haddad','Vermeer','Quinn','Brandt','Ferreira','Lowe','Petrov','Sato','Ibrahim','Carter','Dubois'];
begin
  delete from crew_candidates where pilot_id = u and expires_at < now();
  select count(*) into n from crew_candidates where pilot_id = u;
  for i in 1..(8 - n) loop
    cat := (array['piston','turboprop','turboprop','light','light','light','mid','mid','large'])[1 + floor(random()*9)::int];
    role := case when random() < 0.55 then 'captain' else 'fo' end;
    ex := case when role = 'captain' then 4 + floor(random()*22)::int else 1 + floor(random()*8)::int end;
    sk := round((0.85 + random()*0.2 + least(ex, 20) * 0.005)::numeric, 2);
    select * into r from crew_rates(cat);
    insert into crew_candidates(pilot_id, name, role, experience, skill, category, salary_ask, expires_at)
    values (u, firsts[1 + floor(random()*30)::int] || ' ' || lasts[1 + floor(random()*30)::int], role, ex, sk, cat,
            round(r.salary * (case when role = 'fo' then 0.6 else 1 end) * (0.8 + 0.025 * least(ex, 20)) * (0.95 + random()*0.15) / 100) * 100,
            now() + interval '12 hours' + random() * interval '12 hours');
  end loop;
end $$;

-- hire a candidate and send them on a type rating course for one of your aircraft types (12 hours)
create or replace function public.hire_crew(p_cand bigint, p_type text)
returns bigint language plpgsql security definer set search_path = public as $$
declare u uuid := me(); c crew_candidates; t aircraft_types; r record; cost numeric; cid bigint; p pilots;
begin
  select * into c from crew_candidates where id = p_cand and pilot_id = u for update;
  if c.id is null then raise exception 'That candidate has taken another job.'; end if;
  select * into t from aircraft_types where code = p_type;
  if t.code is null then raise exception 'Choose an aircraft type.'; end if;
  if not exists (select 1 from fleet where pilot_id = u and type_code = p_type) then raise exception 'You don''t operate that type.'; end if;
  if t.category <> c.category and not (c.category = 'large' or (c.category = 'mid' and t.category in ('light','turboprop','piston'))
      or (c.category = 'light' and t.category in ('turboprop','piston')) or (c.category = 'turboprop' and t.category = 'piston')) then
    raise exception '% hasn''t flown anything as big as the % and won''t take the job.', c.name, t.name; end if;
  select * into r from crew_rates(t.category);
  cost := round(r.training * case when c.role = 'fo' then 0.8 else 1 end);
  select * into p from pilots where id = u for update;
  if p.cash < cost then raise exception 'Type training costs $%. You have $%.', to_char(cost,'FM999,999,999'), to_char(p.cash,'FM999,999,999'); end if;
  update pilots set cash = cash - cost where id = u;
  insert into crew(pilot_id, name, role, type_code, experience, skill, salary, status, trained_at, opc_due, recurrent_due, next_pay)
  values (u, c.name, c.role, t.code, c.experience, c.skill, c.salary_ask, 'training', now() + interval '12 hours',
          now() + interval '12 hours' + interval '182 days', now() + interval '12 hours' + interval '365 days', now() + interval '30 days')
  returning id into cid;
  delete from crew_candidates where id = c.id;
  perform add_ledger(u, format('Hired %s as %s; %s type rating course', c.name, case when c.role = 'fo' then 'first officer' else 'captain' end, t.code), -cost::bigint);
  return cid;
end $$;

create or replace function public.assign_crew(p_crew bigint, p_ac uuid)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := me(); c crew; f fleet;
begin
  select * into c from crew where id = p_crew and pilot_id = u and status <> 'left' for update;
  if c.id is null then raise exception 'Crew member not found.'; end if;
  if p_ac is not null then
    select * into f from fleet where id = p_ac and pilot_id = u;
    if f.id is null then raise exception 'Not your aircraft.'; end if;
    if f.type_code <> c.type_code then raise exception '% is rated on the %, not the %.', c.name, c.type_code, f.type_code; end if;
  end if;
  if c.aircraft_id is not null and exists (select 1 from crew_legs where aircraft_id = c.aircraft_id and status = 'flying') then
    raise exception '% is flying right now.', c.name; end if;
  update crew set aircraft_id = p_ac where id = c.id;
end $$;

create or replace function public.set_ops(p_ac uuid, p_mode text)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := me(); f fleet; t aircraft_types; n int; leg crew_legs;
begin
  select * into f from fleet where id = p_ac and pilot_id = u for update;
  if f.id is null then raise exception 'Not your aircraft.'; end if;
  select * into t from aircraft_types where code = f.type_code;
  if p_mode = 'crew' then
    if exists (select 1 from trips where aircraft_id = p_ac and status in ('booked','flying','filed')) then
      raise exception 'Fly or cancel %''s booked trips first.', f.reg; end if;
    select count(*) into n from crew c where c.aircraft_id = p_ac and c.status <> 'left';
    if n < t.crew_req then raise exception 'The % needs % pilot%. Assign crew to % first.', t.name, t.crew_req, case when t.crew_req > 1 then 's' else '' end, f.reg; end if;
    if not exists (select 1 from crew c where c.aircraft_id = p_ac and c.status <> 'left' and c.role = 'captain') then
      raise exception '% needs a captain assigned.', f.reg; end if;
    delete from bids where aircraft_id = p_ac and status = 'pending';
    update fleet set ops = 'crew' where id = p_ac;
  elsif p_mode = 'pilot' then
    select * into leg from crew_legs where aircraft_id = p_ac and status = 'flying';
    if leg.id is not null then raise exception '% is on a crew flight to % and lands at % UTC.', f.reg, leg.to_icao, to_char(leg.arr_at at time zone 'UTC','HH24:MI'); end if;
    update fleet set ops = 'pilot' where id = p_ac;
  else raise exception 'Unknown mode.'; end if;
end $$;

-- OPC (every 6 months) or recurrent training (every 12 months): paid now, crew unavailable while it runs
create or replace function public.crew_check(p_crew bigint, p_kind text)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := me(); c crew; t aircraft_types; r record; cost numeric; p pilots;
begin
  select * into c from crew where id = p_crew and pilot_id = u and status = 'active' for update;
  if c.id is null then raise exception 'Crew member not available.'; end if;
  if exists (select 1 from crew_legs l where l.aircraft_id = c.aircraft_id and l.status = 'flying') then raise exception '% is flying right now.', c.name; end if;
  select * into t from aircraft_types where code = c.type_code;
  select * into r from crew_rates(t.category);
  cost := case when p_kind = 'opc' then r.opc when p_kind = 'recurrent' then round(r.training * 0.5) end;
  if cost is null then raise exception 'Unknown check.'; end if;
  select * into p from pilots where id = u for update;
  if p.cash < cost then raise exception 'That costs $%. You have $%.', to_char(cost,'FM999,999,999'), to_char(p.cash,'FM999,999,999'); end if;
  update pilots set cash = cash - cost where id = u;
  if p_kind = 'opc' then
    update crew set opc_due = greatest(opc_due, now()) + interval '182 days', busy_until = now() + interval '4 hours' where id = c.id;
  else
    update crew set recurrent_due = greatest(recurrent_due, now()) + interval '365 days', busy_until = now() + interval '8 hours' where id = c.id;
  end if;
  perform add_ledger(u, format('%s for %s (%s)', case when p_kind = 'opc' then 'Operator proficiency check' else 'Recurrent training' end, c.name, c.type_code), -cost::bigint);
end $$;

create or replace function public.set_salary(p_crew bigint, p_salary numeric)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := me(); c crew; target numeric;
begin
  select * into c from crew where id = p_crew and pilot_id = u and status <> 'left' for update;
  if c.id is null then raise exception 'Crew member not found.'; end if;
  if p_salary < 1000 or p_salary > 100000 then raise exception 'Enter a monthly salary between $1,000 and $100,000.'; end if;
  -- a pay rise lifts morale straight away; a cut hurts it
  update crew set salary = round(p_salary), raise_asked = false,
         satisfaction = least(100, greatest(0, satisfaction + case when p_salary > c.salary then least(30, (p_salary / c.salary - 1) * 150) else -least(40, (1 - p_salary / c.salary) * 200) end)),
         notice_until = case when p_salary > c.salary then null else notice_until end
   where id = c.id;
  perform add_ledger(u, format('%s''s salary changed to $%s a month', c.name, to_char(round(p_salary),'FM999,999')), 0);
end $$;

create or replace function public.release_crew(p_crew bigint)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := me(); c crew; f fleet; t aircraft_types; n int;
begin
  select * into c from crew where id = p_crew and pilot_id = u and status <> 'left' for update;
  if c.id is null then raise exception 'Crew member not found.'; end if;
  if exists (select 1 from crew_legs l where l.aircraft_id = c.aircraft_id and l.status = 'flying') then raise exception '% is flying right now.', c.name; end if;
  update pilots set cash = cash - c.salary where id = u;
  update crew set status = 'left', aircraft_id = null where id = c.id;
  perform add_ledger(u, format('%s left the company (one month''s notice pay)', c.name), -round(c.salary)::bigint);
  if c.aircraft_id is not null then perform crew_check_aircraft(c.aircraft_id); end if;
end $$;

-- an aircraft without enough crew goes back to the owner's control
create or replace function public.crew_check_aircraft(p_ac uuid)
returns void language plpgsql set search_path = public as $$
declare f fleet; t aircraft_types; n int;
begin
  select * into f from fleet where id = p_ac;
  if f.id is null or f.ops <> 'crew' then return; end if;
  select * into t from aircraft_types where code = f.type_code;
  select count(*) into n from crew where aircraft_id = p_ac and status <> 'left';
  if n < t.crew_req and not exists (select 1 from crew_legs where aircraft_id = p_ac and status = 'flying') then
    update fleet set ops = 'pilot' where id = p_ac;
    perform add_ledger(f.pilot_id, format('%s is back under your control: not enough crew assigned', f.reg), 0);
  end if;
end $$;

-- background work: salaries, morale, crew flights
create or replace function public.crew_tick()
returns void language plpgsql set search_path = public as $$
declare cm record; leg record; f record; t aircraft_types; r route_pick; bh numeric; rev numeric; cost numeric;
  sk numeric; sat numeric; target numeric; n int; ncap int; gap numeric; p pilots; crow crew;
begin
  -- training courses finish
  update crew set status = 'active' where status = 'training' and trained_at <= now();

  -- salaries every 30 days
  for cm in select * from crew where status <> 'left' and next_pay <= now() limit 200 loop
    update pilots set cash = cash - cm.salary where id = cm.pilot_id;
    update crew set next_pay = next_pay + interval '30 days' where id = cm.id;
    perform add_ledger(cm.pilot_id, format('Salary, %s', cm.name), -round(cm.salary)::bigint);
  end loop;

  -- morale drifts daily towards what their pay is worth to them
  for cm in select * from crew where status = 'active' and sat_checked <= now() - interval '1 day' limit 200 loop
    select * into crow from crew where id = cm.id;
    target := least(100, greatest(0, 65 + 150 * (cm.salary / greatest(crew_expected(crow), 1) - 1)));
    -- overdue checks are a sign of a badly run operation
    if cm.opc_due < now() or cm.recurrent_due < now() then target := target - 10; end if;
    sat := cm.satisfaction + (target - cm.satisfaction) * 0.25;
    update crew set satisfaction = round(sat, 1), sat_checked = now() where id = cm.id;
    if sat < 35 and not cm.raise_asked then
      update crew set raise_asked = true where id = cm.id;
      perform add_ledger(cm.pilot_id, format('%s has asked for a pay rise', cm.name), 0);
    end if;
    if sat < 15 and cm.notice_until is null then
      update crew set notice_until = now() + interval '3 days' where id = cm.id;
      perform add_ledger(cm.pilot_id, format('%s has handed in their notice: 3 days to change their mind', cm.name), 0);
    elsif sat >= 25 and cm.notice_until is not null then
      update crew set notice_until = null where id = cm.id;
      perform add_ledger(cm.pilot_id, format('%s has withdrawn their notice', cm.name), 0);
    end if;
  end loop;
  for cm in select * from crew where notice_until is not null and notice_until <= now() and status <> 'left' loop
    update crew set status = 'left', aircraft_id = null where id = cm.id;
    perform add_ledger(cm.pilot_id, format('%s has left the company', cm.name), 0);
    if cm.aircraft_id is not null then perform crew_check_aircraft(cm.aircraft_id); end if;
  end loop;

  -- crew flights land
  for leg in select * from crew_legs where status = 'flying' and arr_at <= now() limit 100 loop
    update crew_legs set status = 'done' where id = leg.id;
    update pilots set cash = cash + leg.revenue - leg.cost where id = leg.pilot_id;
    update fleet set loc = leg.to_icao, hours = hours + leg.block_h where id = leg.aircraft_id;
    update crew set hours = hours + leg.block_h where aircraft_id = leg.aircraft_id and status <> 'left';
    select coalesce(avg(satisfaction), 70) into sat from crew where aircraft_id = leg.aircraft_id and status <> 'left';
    -- the next job comes along in 10 to 40 hours; unhappy crews take longer to find work
    gap := (10 + random() * 30) * (1 + greatest(0, 60 - sat) / 60);
    update fleet set crew_busy_until = now() + gap * interval '1 hour' where id = leg.aircraft_id;
    perform add_ledger(leg.pilot_id, format('Crew flight %s %s–%s for %s: revenue $%s, costs $%s', leg.reg, leg.from_icao, leg.to_icao, leg.client,
            to_char(leg.revenue,'FM999,999,990'), to_char(leg.cost,'FM999,999,990')), round(leg.revenue - leg.cost)::bigint);
    if sat < 30 and random() < 0.3 then
      update pilots set rep = greatest(0, rep - 1) where id = leg.pilot_id;
      perform add_ledger(leg.pilot_id, format('A client complained about the crew on %s', leg.reg), 0);
    end if;
    perform crew_check_aircraft(leg.aircraft_id);
  end loop;

  -- crew-operated aircraft pick up their next job
  for f in select fl.*, ty.rate, ty.ktas, ty.range_nm, ty.seats, ty.min_rwy_ft, ty.crew_req from fleet fl join aircraft_types ty on ty.code = fl.type_code
            where fl.ops = 'crew' and coalesce(fl.crew_busy_until, now()) <= now()
              and not exists (select 1 from crew_legs l where l.aircraft_id = fl.id and l.status = 'flying') limit 50 loop
    select count(*), coalesce(avg(skill), 1), count(*) filter (where role = 'captain') into n, sk, ncap from crew cr where cr.aircraft_id = f.id and crew_ready(cr);
    if n < f.crew_req or ncap < 1 then
      update fleet set crew_busy_until = now() + interval '1 hour' where id = f.id;
      continue;
    end if;
    r := gen_route(f.loc, floor(f.range_nm * 0.9)::int, f.seats, f.min_rwy_ft);
    if r.from_icao is null or r.from_icao <> f.loc then
      -- only take work that starts where the aircraft is
      r := null;
      select a.icao into r.to_icao from airports a, airports h
       where h.icao = f.loc and a.active and a.icao <> f.loc and a.rwy_ft >= f.min_rwy_ft and a.size <> 'small'
         and a.lat between h.lat - 15 and h.lat + 15 and nm(a.lat,a.lon,h.lat,h.lon) between 120 and least(f.range_nm * 0.8, 1200)
       order by random() limit 1;
      if r.to_icao is null then update fleet set crew_busy_until = now() + interval '2 hours' where id = f.id; continue; end if;
      r.from_icao := f.loc; r.dist := ap_nm(f.loc, r.to_icao);
      r.pax := greatest(1, least(f.seats, 1 + floor(random() * f.seats)::int));
      select name into r.client from clients order by random() limit 1;
    end if;
    select * into p from pilots where id = f.pilot_id;
    bh := block_h(f.ktas, r.dist);
    -- crews work through brokers, who keep 15%
    rev := round(f.rate * rate_mul(f.year) * bh * (0.8 + random() * 0.3) * 0.85 * sk);
    cost := round(op_rate(f.rate, p.upgrades) * bh);
    insert into crew_legs(pilot_id, aircraft_id, reg, from_icao, to_icao, dist, pax, client, dep_at, arr_at, block_h, revenue, cost)
    values (f.pilot_id, f.id, f.reg, r.from_icao, r.to_icao, r.dist, r.pax, r.client, now(), now() + bh * interval '1 hour', round(bh, 2), rev, cost);
  end loop;
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
  if f.ops = 'crew' then raise exception '% is flown by your crew. Take it back in the Hangar to quote with it.', f.reg; end if;
  select * into ty from aircraft_types where code = f.type_code;
  if rq.pax > ty.seats then raise exception 'Not enough seats.'; end if;
  if rq.dist > ty.range_nm * 0.92 then raise exception 'Beyond this aircraft''s range.'; end if;
  if not rwy_ok(rq.from_icao, rq.to_icao, ty.min_rwy_ft) then raise exception 'A runway on this route is too short for the %.', ty.name; end if;
  wait := (array[30,22,15,10])[1 + least(3, coalesce((p.upgrades->>'fast')::int,0))];
  if rq.decide_at is null and rq.expires_at < now() + wait * interval '1 second' then raise exception 'That request is closing too soon to quote.'; end if;
  loc := future_loc(f.id);
  repo := case when loc = rq.from_icao then 0 else ap_nm(loc, rq.from_icao) end;
  basis := ty.rate * rate_mul(f.year) * block_h(ty.ktas, rq.dist);
  if p_amount < 100 or p_amount > basis * 10 then raise exception 'Enter a realistic price.'; end if;
  insert into bids(request_id, pilot_id, aircraft_id, amount, basis, repo_nm) values (p_request, u, f.id, p_amount, basis, repo);
  update requests set player_bids = player_bids + 1,
         decide_at = coalesce(decide_at, now() + wait * interval '1 second'), status = 'deciding'
   where id = p_request returning decide_at into rq.decide_at;
  return rq.decide_at;
exception when unique_violation then raise exception 'You already quoted on this request.';
end $$;

create or replace function public.poll()
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := me(); p pilots; c record; ac record; r route_pick; fair numeric; ev jsonb; rm numeric;
begin
  update pilots set last_seen = now() where id = u returning * into p;
  perform maintain();

  for c in select * from calls where pilot_id = u and status = 'ringing' and expires_at < now() loop
    update calls set status = 'missed' where id = c.id;
    perform schedule_call(u);
  end loop;

  if not exists (select 1 from calls where pilot_id = u and status = 'ringing') and p.next_call_at <= now() then
    select f.id, f.type_code, f.year as ac_year, t.* into ac from fleet f join aircraft_types t on t.code = f.type_code
     where f.pilot_id = u and f.ops = 'pilot' order by random() limit 1;
    if ac.id is not null then
      r := gen_route(future_loc(ac.id), floor(ac.range_nm*0.9)::int, ac.seats, ac.min_rwy_ft);
      if r.from_icao is not null then
        rm := rate_mul(ac.ac_year);
        fair := ac.rate * rm * block_h(ac.ktas, r.dist)
              + 0.55 * ac.rate * rm * block_h(ac.ktas, coalesce(nullif(ap_nm(future_loc(ac.id), r.from_icao),0),0));
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

create or replace function public.maintain()
returns void language plpgsql set search_path = public as $$
declare s public.va_settings; rq record; tgt int; open_n int; active_n int; near text; tr record; h int; gap interval; ln record;
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

  -- monthly finance payments (a batch per run so one call never takes long)
  for ln in select id from public.fleet where loan_balance > 0 and loan_next_due <= now() order by loan_next_due limit 50 loop
    perform public.take_loan_payment(ln.id);
  end loop;

  perform public.crew_tick();

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
    update public.va_settings set last_spawn = now() where true;
  end if;
  update public.va_settings set last_maint = now() where true;
end $$;

create or replace function public.accept_call(p_call bigint, p_aircraft uuid)
returns bigint language plpgsql security definer set search_path = public as $$
declare u uuid := me(); c calls; f fleet; ty aircraft_types; tid bigint;
begin
  select * into c from calls where id = p_call and pilot_id = u for update;
  if c.id is null or c.status <> 'ringing' or c.expires_at < now() then raise exception 'The caller has hung up.'; end if;
  select * into f from fleet where id = p_aircraft and pilot_id = u and ops = 'pilot';
  select * into ty from aircraft_types where code = f.type_code;
  if f.id is null or c.pax > ty.seats or c.dist > ty.range_nm * 0.92 or not rwy_ok(c.from_icao, c.to_icao, ty.min_rwy_ft) then
    raise exception 'That aircraft can''t fly this job.'; end if;
  update calls set status = 'accepted' where id = c.id;
  tid := book_trip(u, f.id, c.from_icao, c.to_icao, c.dist, c.pax, c.client, c.caller, c.dep_at, c.offer, 'call');
  perform add_ledger(u, format('Phone booking from %s: %s–%s for $%s', c.caller, c.from_icao, c.to_icao, to_char(c.offer,'FM999,999,999')), 0);
  perform schedule_call(u);
  return tid;
end $$;

create or replace function public.tracker_start(p_key text, p_trip bigint)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := tracker_pilot(p_key); t trips;
begin
  select * into t from trips where id = p_trip and pilot_id = u for update;
  if t.id is null or t.status not in ('booked','flying') then raise exception 'That booking is not available to fly.'; end if;
  if (select ops from fleet where id = t.aircraft_id) = 'crew' then raise exception 'That aircraft is flown by your crew. Take it back in the Hangar first.'; end if;
  if exists (select 1 from trips where aircraft_id = t.aircraft_id and status in ('booked','flying') and seq < t.seq) then
    raise exception 'This aircraft has an earlier trip to fly first.';
  end if;
  update trips set status = 'flying', started_at = coalesce(started_at, now()) where id = t.id;
end $$;

create or replace function public.sell_aircraft(p_ac uuid)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := me(); f fleet; ty aircraft_types; v bigint;
begin
  select * into f from fleet where id = p_ac and pilot_id = u;
  if f.id is null then raise exception 'Not your aircraft.'; end if;
  if (select count(*) from fleet where pilot_id = u) <= 1 then raise exception 'You need at least one aircraft.'; end if;
  if exists (select 1 from trips where aircraft_id = p_ac and status in ('booked','flying','filed')) then raise exception 'Finish or cancel its trips first.'; end if;
  if exists (select 1 from crew_legs where aircraft_id = p_ac and status = 'flying') then raise exception 'Wait until its crew flight has landed.'; end if;
  select * into ty from aircraft_types where code = f.type_code;
  v := round(ac_value(f.type_code, f.year) * 0.92 - f.loan_balance);
  delete from bids where aircraft_id = p_ac and status = 'pending';
  delete from fleet where id = p_ac;
  update pilots set cash = cash + v where id = u;
  perform add_ledger(u, format('Sold %s %s %s%s', f.year, ty.name, f.reg,
          case when f.loan_balance > 0 then ' and repaid its loan' else '' end), v);
end $$;

revoke execute on function public.crew_rates(text) from public, anon, authenticated;
revoke execute on function public.company_income30(uuid) from public, anon, authenticated;
revoke execute on function public.crew_expected(public.crew) from public, anon, authenticated;
revoke execute on function public.crew_ready(public.crew) from public, anon, authenticated;
revoke execute on function public.crew_tick() from public, anon, authenticated;
revoke execute on function public.crew_check_aircraft(uuid) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['refresh_candidates()','hire_crew(bigint,text)','assign_crew(bigint,uuid)','set_ops(uuid,text)',
     'crew_check(bigint,text)','set_salary(bigint,numeric)','release_crew(bigint)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
