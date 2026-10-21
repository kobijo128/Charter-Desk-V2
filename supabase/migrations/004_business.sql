-- 004: running the business — real aircraft catalogue, age and finance, crew, client briefs,
-- flight planning, passenger requests and airport time zones. Safe to run more than once.

-- =====================================================================
-- schema additions
-- =====================================================================
alter table public.airports add column if not exists tz text not null default 'UTC';

alter table public.aircraft_types add column if not exists category text not null default 'jet';
alter table public.aircraft_types add column if not exists crew_req int not null default 1;
alter table public.aircraft_types add column if not exists year_from int not null default 2000;
alter table public.aircraft_types add column if not exists year_to int;

alter table public.fleet add column if not exists year_built int;
alter table public.fleet add column if not exists rate_mul numeric not null default 1;
alter table public.fleet add column if not exists op_mul numeric not null default 1;
alter table public.fleet add column if not exists bought_for numeric not null default 0;
alter table public.fleet add column if not exists loan_balance numeric not null default 0;
alter table public.fleet add column if not exists loan_payment numeric not null default 0;
alter table public.fleet add column if not exists next_payment_at timestamptz;
alter table public.fleet add column if not exists fuel_lb numeric;
alter table public.fleet add column if not exists ops_mode text not null default 'owner';
alter table public.fleet add column if not exists crew_busy_until timestamptz;
alter table public.fleet add column if not exists crew_legs int not null default 0;
alter table public.fleet add column if not exists crew_trip bigint;

alter table public.pilots add column if not exists next_payroll_at timestamptz;
alter table public.pilots add column if not exists simbrief text;

alter table public.trips add column if not exists brief jsonb;
alter table public.trips add column if not exists prep jsonb not null default '{}';
alter table public.trips add column if not exists ofp jsonb;
alter table public.trips add column if not exists ends_at timestamptz;
alter table public.trips drop constraint if exists trips_status_check;
alter table public.trips add constraint trips_status_check
  check (status in ('booked','flying','filed','accepted','rejected','cancelled','outsourced','crew_flying','crew_done'));
alter table public.trips drop constraint if exists trips_source_check;
alter table public.trips add constraint trips_source_check check (source in ('bid','call','ferry','crew'));

alter table public.pireps add column if not exists fuel_end_lb numeric;
alter table public.pireps add column if not exists fines int not null default 0;

alter table public.ledger add column if not exists kind text;

create table if not exists public.crew (
  id               uuid primary key default gen_random_uuid(),
  pilot_id         uuid not null references public.pilots on delete cascade,
  name             text not null,
  skill            int not null,
  experience_hrs   int not null,
  salary_week      int not null,
  satisfaction     numeric(5,2) not null default 75,
  status           text not null default 'training' check (status in ('training','active','grounded','quit')),
  type_code        text references public.aircraft_types,
  training_until   timestamptz,
  training_kind    text,
  opc_due_at       timestamptz,
  recurrent_due_at timestamptz,
  aircraft_id      uuid references public.fleet on delete set null,
  hours            numeric(10,2) not null default 0,
  flights          int not null default 0,
  hired_at         timestamptz not null default now(),
  last_raise_at    timestamptz,
  rev_baseline     numeric not null default 0,
  note             text
);
create index if not exists crew_pilot on public.crew(pilot_id, status);

create table if not exists public.cabin_requests (
  id          bigint generated always as identity primary key,
  pilot_id    uuid not null references public.pilots on delete cascade,
  trip_id     bigint not null references public.trips on delete cascade,
  text        text not null,
  options     jsonb not null,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  status      text not null default 'open' check (status in ('open','answered','missed')),
  answer      int,
  answered_via text
);
create index if not exists cabin_open on public.cabin_requests(pilot_id, status);

-- =====================================================================
-- the aircraft catalogue: real new prices (USD), charter rates per block hour
-- =====================================================================
insert into public.aircraft_types(code,name,cls,category,seats,range_nm,ktas,burn,rate,price,ceil,min_rwy_ft,crew_req,year_from,year_to,sim_match) values
 ('C172','Cessna 172S Skyhawk','Single piston','piston',3,640,122,55,650,450000,140,1700,1,1956,null,'{172,skyhawk}'),
 ('SR22','Cirrus SR22T','Single piston','piston',4,900,183,105,950,1050000,250,2100,1,2001,null,'{sr22}'),
 ('PA46','Piper M350','Single piston','piston',5,1100,213,110,1200,1350000,250,2500,1,1984,null,'{m350,malibu,pa-46,pa46}'),
 ('DA62','Diamond DA62','Twin piston','piston',6,1200,190,110,1250,1350000,200,2300,1,2015,null,'{da62,da-62}'),
 ('BE58','Beechcraft Baron G58','Twin piston','piston',5,1200,200,190,1400,1650000,200,2400,1,1969,null,'{baron,be58,g58}'),
 ('C208','Cessna Grand Caravan EX','Single turboprop','turboprop',9,900,185,390,1800,2900000,250,2200,1,1985,null,'{caravan,c208}'),
 ('KODI','Kodiak 100','Single turboprop','turboprop',8,1000,174,350,1700,3100000,250,1500,1,2007,null,'{kodiak}'),
 ('M600','Piper M600 SLS','Single turboprop','turboprop',5,1400,274,300,2000,3500000,300,2600,1,2016,null,'{m600}'),
 ('TBM8','Daher TBM 850','Single turboprop','turboprop',5,1500,315,420,2200,4000000,310,2600,1,2006,2019,'{tbm 850,tbm 900,tbm8,tbm 9}'),
 ('TBM9','Daher TBM 960','Single turboprop','turboprop',5,1730,330,400,2500,5200000,310,2500,1,2022,null,'{tbm 960,tbm 940,tbm 930,tbm9,tbm 9}'),
 ('PC12','Pilatus PC-12 NGX','Single turboprop','turboprop',8,1750,280,420,2800,6200000,300,2600,1,1994,null,'{pc-12,pc12,pc 12}'),
 ('BE9L','King Air C90GTx','Twin turboprop','turboprop',6,1200,250,500,2400,4300000,300,2700,1,1971,null,'{c90,king air 90,be9l}'),
 ('BE20','King Air 260','Twin turboprop','turboprop',7,1720,310,600,2900,7200000,350,2600,1,1974,null,'{king air 2,b200,be20,king air 260,king air 250}'),
 ('B350','King Air 350i','Twin turboprop','turboprop',9,1800,312,650,3400,8900000,350,3300,1,1990,null,'{king air,kingair,b350}'),
 ('P180','Piaggio P.180 Avanti EVO','Twin turboprop','turboprop',7,1500,400,650,3200,7500000,410,3300,2,1990,2022,'{avanti,p180,p.180}'),
 ('DHC6','DHC-6 Twin Otter 300-G','Twin turboprop','turboprop',15,750,160,600,2600,7500000,250,1500,2,1966,null,'{twin otter,dhc-6,dhc6}'),
 ('EA50','Eclipse 550','Very light jet','jet',4,1125,375,530,2600,3000000,410,3100,1,2006,2017,'{eclipse,ea50}'),
 ('SF50','Cirrus Vision Jet G2+','Very light jet','jet',5,1100,300,450,2700,3400000,310,3300,1,2016,null,'{vision,sf50}'),
 ('C510','Citation Mustang','Very light jet','jet',4,1150,340,700,2900,3400000,410,3200,1,2006,2017,'{mustang,c510}'),
 ('E50P','Phenom 100EX','Very light jet','jet',5,1180,406,650,3300,4600000,410,3200,1,2008,null,'{phenom 100,e50p}'),
 ('HDJT','HondaJet Elite II','Light jet','jet',6,1550,422,700,3800,7200000,430,3500,1,2015,null,'{hondajet,ha-420,hdjt}'),
 ('PRM1','Beechcraft Premier IA','Light jet','jet',6,1200,451,1000,3700,7000000,410,3800,1,2001,2012,'{premier,prm1}'),
 ('C25A','Citation CJ2+','Light jet','jet',6,1600,405,900,3900,7500000,450,3400,1,2000,2016,'{cj2,c25a}'),
 ('C25B','Citation CJ3 Gen2','Light jet','jet',7,2000,416,950,4300,10000000,450,3200,1,2004,null,'{cj3,c25b}'),
 ('C25C','Citation CJ4 Gen2','Light jet','jet',8,2100,451,1050,4800,11200000,450,3400,1,2010,null,'{cj4,c25c}'),
 ('E55P','Phenom 300E','Light jet','jet',7,2000,464,1000,4900,11500000,450,3200,1,2009,null,'{phenom 300,e55p,phenom}'),
 ('PC24','Pilatus PC-24','Light jet','jet',8,2000,440,1000,4800,11500000,450,2700,2,2018,null,'{pc-24,pc24}'),
 ('LJ45','Learjet 45XR','Midsize jet','jet',8,2000,465,1500,5200,13500000,510,5000,2,1998,2012,'{learjet 45,lj45}'),
 ('LJ75','Learjet 75 Liberty','Midsize jet','jet',8,2000,465,1450,5400,10000000,510,4500,2,2013,2022,'{learjet 75,lj75,learjet}'),
 ('C56X','Citation XLS Gen2','Midsize jet','jet',9,2100,441,1500,5600,14900000,450,3600,2,1996,null,'{xls,c56x,excel}'),
 ('H25B','Hawker 900XP','Midsize jet','jet',8,2500,448,1900,5800,16000000,410,5000,2,1984,2013,'{hawker 8,hawker 9,h25b,hawker}'),
 ('G150','Gulfstream G150','Midsize jet','jet',8,2900,470,1500,6500,15000000,450,5000,2,2005,2017,'{g150}'),
 ('C68A','Citation Latitude','Midsize jet','jet',9,2700,446,1400,6900,18500000,450,3600,2,2015,null,'{latitude,c680}'),
 ('E545','Embraer Praetor 500','Midsize jet','jet',9,3340,466,1500,7200,18000000,450,4200,2,2019,null,'{praetor 500,legacy 500,e545}'),
 ('HA4T','Hawker 4000','Super-midsize jet','jet',9,3200,470,1800,7500,23000000,450,5000,2,2008,2013,'{hawker 4000,ha4t}'),
 ('E550','Embraer Praetor 600','Super-midsize jet','jet',12,4000,466,1700,8400,22000000,450,4500,2,2019,null,'{praetor 600,legacy 450,e550}'),
 ('G280','Gulfstream G280','Super-midsize jet','jet',10,3600,470,1700,8700,25000000,450,4750,2,2012,null,'{g280}'),
 ('CL35','Challenger 3500','Super-midsize jet','jet',10,3400,470,1700,8600,27000000,450,4850,2,2004,null,'{challenger 3,cl350,cl35}'),
 ('C700','Citation Longitude','Super-midsize jet','jet',12,3500,476,1800,8800,29000000,450,4900,2,2019,null,'{longitude,c700}'),
 ('E35L','Embraer Legacy 650E','Large jet','jet',13,3900,459,2300,9000,28000000,410,5700,2,2002,2020,'{legacy 6,e35l}'),
 ('F2TH','Falcon 2000LXS','Large jet','jet',10,4000,470,1900,9600,36000000,470,4500,2,1995,2023,'{falcon 2000,f2000,f2th}'),
 ('CL60','Challenger 650','Large jet','jet',12,4000,459,2100,10000,33000000,410,5800,2,1980,2023,'{challenger 6,cl60}'),
 ('GLF4','Gulfstream G450','Large jet','jet',14,4350,476,2600,10500,40000000,450,5600,2,1987,2018,'{g450,gulfstream iv,giv,glf4}'),
 ('F900','Falcon 900LX','Large jet','jet',14,4750,482,2200,11000,44000000,510,5400,2,1986,null,'{falcon 900,f900}'),
 ('FA6X','Falcon 6X','Ultra-long-range jet','jet',16,5500,488,2500,13000,52000000,510,5500,2,2023,null,'{6x,fa6x}'),
 ('FA7X','Falcon 7X','Ultra-long-range jet','jet',14,5950,488,2400,13000,54000000,510,5700,2,2007,2018,'{falcon 7x,fa7x}'),
 ('FA8X','Falcon 8X','Ultra-long-range jet','jet',14,6450,488,2500,13500,60000000,510,6000,2,2016,null,'{falcon 8x,fa8x}'),
 ('GLEX','Bombardier Global 6500','Ultra-long-range jet','jet',16,6600,488,3000,15000,56000000,510,6100,2,1999,null,'{global 6,global express,glex,global 5}'),
 ('GA6C','Gulfstream G600','Ultra-long-range jet','jet',16,6500,488,2800,14000,58000000,510,5700,2,2019,null,'{g600}'),
 ('GLF5','Gulfstream G550','Ultra-long-range jet','jet',16,6750,488,2900,13500,62000000,510,6000,2,2004,2021,'{g550,glf5}'),
 ('GLF6','Gulfstream G650ER','Ultra-long-range jet','jet',16,7500,488,2900,14500,70000000,510,6300,2,2012,null,'{g650,glf6}'),
 ('GA7C','Gulfstream G700','Ultra-long-range jet','jet',19,7750,488,3300,17500,78000000,510,6250,2,2024,null,'{g700}'),
 ('GL7T','Bombardier Global 7500','Ultra-long-range jet','jet',19,7700,488,3300,16500,78000000,510,5800,2,2018,null,'{global 7500,global7500,gl7t}'),
 ('B737','Boeing Business Jet','VIP airliner','jet',19,6000,470,5500,23000,105000000,410,7000,2,1999,null,'{737,bbj}'),
 ('A319','Airbus ACJ319neo','VIP airliner','jet',19,6700,470,5000,22000,110000000,410,7000,2,1999,null,'{a319,acj}')
on conflict (code) do update set name=excluded.name, cls=excluded.cls, category=excluded.category, seats=excluded.seats,
  range_nm=excluded.range_nm, ktas=excluded.ktas, burn=excluded.burn, rate=excluded.rate, price=excluded.price, ceil=excluded.ceil,
  min_rwy_ft=excluded.min_rwy_ft, crew_req=excluded.crew_req, year_from=excluded.year_from, year_to=excluded.year_to, sim_match=excluded.sim_match;
update public.aircraft_types set starter = code in ('SR22','C208','PC12','B350','SF50','E55P');

-- =====================================================================
-- age, value and finance
-- =====================================================================
create or replace function public.ac_age(p_year int) returns int language sql stable set search_path = public as $$
  select greatest(0, extract(year from now())::int - coalesce(p_year, extract(year from now())::int))
$$;
-- new aircraft lose ~15% in year one, then ~6% a year, never below 22% of new
create or replace function public.ac_value(p_price numeric, p_year int) returns numeric language sql stable set search_path = public as $$
  select case when ac_age(p_year) = 0 then p_price
              else greatest(p_price * 0.22, p_price * 0.85 * power(0.94, ac_age(p_year) - 1)) end
$$;
create or replace function public.age_rate_mul(p_year int) returns numeric language sql stable set search_path = public as $$
  select greatest(0.75, 1 - 0.008 * ac_age(p_year))
$$;
create or replace function public.age_op_mul(p_year int) returns numeric language sql stable set search_path = public as $$
  select 1 + 0.006 * ac_age(p_year)
$$;
-- 15% deposit, 10 years at 6.5% a year, paid weekly
create or replace function public.weekly_payment(p_loan numeric) returns numeric language sql immutable as $$
  select case when p_loan <= 0 then 0 else round(p_loan * (0.065/52) / (1 - power(1 + 0.065/52, -520)), 2) end
$$;

-- existing aircraft get an age: starter aircraft were given second-hand
update public.fleet set year_built = extract(year from now())::int - 14 where year_built is null;
update public.fleet set rate_mul = age_rate_mul(year_built), op_mul = age_op_mul(year_built);

-- today's sales listings: brand new (types still in production) plus three used aircraft,
-- the same for every pilot until midnight UTC
create or replace function public.listings(p_type text)
returns table(slot int, year_built int, hours int, price numeric, is_new boolean)
language plpgsql stable set search_path = public as $$
declare t aircraft_types; y int := extract(year from now())::int; d text := to_char(now() at time zone 'UTC','YYYY-MM-DD');
        h bigint; lo int; hi int;
begin
  select * into t from aircraft_types where code = p_type;
  if t.code is null then return; end if;
  if t.year_to is null then
    slot := 0; year_built := y; hours := 3; price := t.price; is_new := true; return next;
  end if;
  lo := t.year_from; hi := least(y - 1, coalesce(t.year_to, y - 1));
  if hi < lo then return; end if;
  for i in 1..3 loop
    h := ('x' || substr(md5(p_type || d || i), 1, 12))::bit(48)::bigint;
    year_built := greatest(lo, hi - (h % least(25, hi - lo + 1))::int);
    hours := greatest(40, (y - year_built) * (220 + (h / 7) % 300))::int;
    price := round(ac_value(t.price, year_built) * (0.92 + ((h / 13) % 17) / 100.0) / 1000) * 1000;
    slot := i; is_new := false; return next;
  end loop;
end $$;

create or replace function public.shop_listings()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(t.code, (select jsonb_agg(to_jsonb(l) order by l.slot) from listings(t.code) l)), '{}')
  from aircraft_types t
$$;

drop function if exists public.buy_listing(text,int,text,boolean);
create or replace function public.buy_listing(p_type text, p_slot int, p_reg text, p_finance boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare u uuid := me(); p pilots; ty aircraft_types; l record; v_reg text; v_id uuid; pay numeric; loan numeric := 0; wk numeric := 0;
begin
  select * into p from pilots where id = u for update;
  select * into ty from aircraft_types where code = p_type;
  if ty.code is null then raise exception 'Unknown aircraft type.'; end if;
  select * into l from listings(p_type) where slot = p_slot;
  if l.slot is null then raise exception 'That aircraft has just been sold. Refresh the shop.'; end if;
  if (select count(*) from fleet where pilot_id = u) >= p.slots then raise exception 'Buy more hangar space first.'; end if;
  if p_finance then loan := round(l.price * 0.85); wk := weekly_payment(loan); pay := l.price - loan;
  else pay := l.price; end if;
  if p.cash < pay then raise exception 'You need % available for this.', to_char(pay, 'FM$999,999,999'); end if;
  v_reg := claim_reg(p_reg, null);
  update pilots set cash = cash - pay where id = u;
  insert into fleet(pilot_id, type_code, reg, loc, year_built, rate_mul, op_mul, bought_for, loan_balance, loan_payment, next_payment_at, hours)
  values (u, ty.code, v_reg, p.home, l.year_built, age_rate_mul(l.year_built), age_op_mul(l.year_built), l.price,
          loan, wk, case when loan > 0 then now() + interval '7 days' end, l.hours)
  returning fleet.id into v_id;
  perform add_ledger(u, format('Bought %s %s %s (%s) for %s%s', case when l.is_new then 'new' else 'used' end, l.year_built, ty.name, v_reg,
          to_char(l.price, 'FM$999,999,999'), case when p_finance then format(', financed: %s deposit, %s a week', to_char(pay,'FM$999,999,999'), to_char(wk,'FM$999,999,990')) else '' end), -pay::bigint);
  return v_id;
end $$;

create or replace function public.payoff_loan(p_ac uuid)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := me(); f fleet; p pilots;
begin
  select * into f from fleet where id = p_ac and pilot_id = u for update;
  select * into p from pilots where id = u for update;
  if f.id is null or f.loan_balance <= 0 then raise exception 'There''s nothing to pay off.'; end if;
  if p.cash < f.loan_balance then raise exception 'You need % to clear this loan.', to_char(f.loan_balance,'FM$999,999,999'); end if;
  update pilots set cash = cash - f.loan_balance where id = u;
  update fleet set loan_balance = 0, loan_payment = 0, next_payment_at = null where id = f.id;
  perform add_ledger(u, format('Paid off the loan on %s', f.reg), -round(f.loan_balance)::bigint);
end $$;

create or replace function public.sell_aircraft(p_ac uuid)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := me(); f fleet; ty aircraft_types; v numeric; net numeric;
begin
  select * into f from fleet where id = p_ac and pilot_id = u for update;
  if f.id is null then raise exception 'Not your aircraft.'; end if;
  if (select count(*) from fleet where pilot_id = u) <= 1 then raise exception 'You need at least one aircraft.'; end if;
  if exists (select 1 from trips where aircraft_id = p_ac and status in ('booked','flying','filed','crew_flying')) then
    raise exception 'Finish or cancel its trips first.'; end if;
  select * into ty from aircraft_types where code = f.type_code;
  v := round(ac_value(ty.price, f.year_built) * 0.88 / 1000) * 1000;
  net := v - f.loan_balance;
  update crew set aircraft_id = null where aircraft_id = p_ac;
  delete from bids where aircraft_id = p_ac and status = 'pending';
  delete from fleet where id = p_ac;
  update pilots set cash = cash + net where id = u;
  perform add_ledger(u, format('Sold %s (%s %s) for %s%s', f.reg, f.year_built, ty.name, to_char(v,'FM$999,999,999'),
          case when f.loan_balance > 0 then format(', loan of %s repaid', to_char(f.loan_balance,'FM$999,999,999')) else '' end), round(net)::bigint);
end $$;

-- =====================================================================
-- crew
-- =====================================================================
-- pay and training scale with how valuable the type is
create or replace function public.crew_tier(p_type text) returns int language sql stable set search_path = public as $$
  select case when price < 2000000 then 1 when price < 5000000 then 2 when price < 9000000 then 3
              when price < 13000000 then 4 when price < 20000000 then 5 when price < 30000000 then 6
              when price < 45000000 then 7 when price < 90000000 then 8 else 9 end
  from aircraft_types where code = p_type
$$;
create or replace function public.base_salary(p_type text) returns int language sql stable set search_path = public as $$
  select (array[900,1500,1900,2300,2800,3300,3800,4400,5000])[crew_tier(p_type)]
$$;
create or replace function public.rating_cost(p_type text) returns int language sql stable set search_path = public as $$
  select (array[3000,12000,20000,30000,42000,52000,62000,78000,95000])[crew_tier(p_type)]
$$;
create or replace function public.flight_income_7d(p_pilot uuid) returns numeric language sql stable set search_path = public as $$
  select coalesce(sum(amount), 0) from ledger where pilot_id = p_pilot and kind = 'flight' and at > now() - interval '7 days'
$$;

-- six pilots looking for work today
create or replace function public.crew_candidates()
returns table(slot int, name text, skill int, experience_hrs int, ask numeric)
language plpgsql stable security definer set search_path = public as $$
declare u uuid := me(); d text := to_char(now() at time zone 'UTC','YYYY-MM-DD'); h bigint;
  firsts text[] := array['Amelia','James','Sofia','Lucas','Hannah','Mateo','Isla','Noah','Chloe','Ethan','Freya','Leo','Maya','Oliver','Zara','Samuel','Elena','Rory','Nadia','Felix','Imogen','Hugo','Priya','Callum'];
  lasts text[]  := array['Clarke','Moreau','Fischer','Rossi','Hughes','Novak','Lindqvist','Duarte','Okafor','Brennan','Kowalski','Laurent','Ashford','Silva','Petrov','Sato','MacLeod','Jensen','Varga','Quinn'];
begin
  for i in 1..6 loop
    h := ('x' || substr(md5(u::text || d || i), 1, 12))::bit(48)::bigint;
    slot := i;
    name := firsts[1 + (h % array_length(firsts,1))::int] || ' ' || lasts[1 + ((h / 31) % array_length(lasts,1))::int];
    skill := 58 + ((h / 7) % 38)::int;
    experience_hrs := 800 + ((h / 11) % 9000)::int + skill * 40;
    ask := round((0.9 + ((h / 17) % 25) / 100.0)::numeric, 2);
    return next;
  end loop;
end $$;

create or replace function public.hire_crew(p_slot int, p_type text)
returns uuid language plpgsql security definer set search_path = public as $$
declare u uuid := me(); p pilots; c record; cost int; sal int; v_id uuid;
begin
  select * into p from pilots where id = u for update;
  select * into c from crew_candidates() where slot = p_slot;
  if c.slot is null then raise exception 'That candidate is no longer available.'; end if;
  if exists (select 1 from crew where pilot_id = u and name = c.name and status <> 'quit') then raise exception '% already works for you.', c.name; end if;
  if not exists (select 1 from aircraft_types where code = p_type) then raise exception 'Choose an aircraft type to train them on.'; end if;
  cost := rating_cost(p_type);
  sal := round(base_salary(p_type) * (0.85 + c.skill / 200.0) * c.ask / 10) * 10;
  if p.cash < cost then raise exception 'The type rating costs %.', to_char(cost,'FM$999,999'); end if;
  update pilots set cash = cash - cost, next_payroll_at = coalesce(next_payroll_at, now() + interval '7 days') where id = u;
  insert into crew(pilot_id, name, skill, experience_hrs, salary_week, satisfaction, status, type_code, training_until, training_kind,
                   opc_due_at, recurrent_due_at, rev_baseline)
  values (u, c.name, c.skill, c.experience_hrs, sal, 72 + (c.skill % 10), 'training', p_type, now() + interval '24 hours', 'initial',
          now() + interval '24 hours' + interval '6 months', now() + interval '24 hours' + interval '12 months', greatest(1, flight_income_7d(u)))
  returning id into v_id;
  perform add_ledger(u, format('Hired %s; %s type rating', c.name, (select name from aircraft_types where code = p_type)), -cost);
  return v_id;
end $$;

-- OPC every 6 months, recurrent every 12, or a new type rating
create or replace function public.crew_training(p_crew uuid, p_kind text, p_type text default null)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := me(); c crew; cost int; dur interval; v_type text;
begin
  select * into c from crew where id = p_crew and pilot_id = u for update;
  if c.id is null or c.status = 'quit' then raise exception 'Not one of your crew.'; end if;
  if c.status = 'training' then raise exception '% is already in training.', c.name; end if;
  if exists (select 1 from fleet where id = c.aircraft_id and ops_mode = 'crew' and crew_busy_until > now()) then
    raise exception '% is flying. Book it once they land.', c.name; end if;
  v_type := case when p_kind = 'rating' then p_type else c.type_code end;
  if v_type is null or not exists (select 1 from aircraft_types where code = v_type) then raise exception 'Choose an aircraft type.'; end if;
  cost := case p_kind when 'opc' then round(rating_cost(v_type) * 0.25) when 'recurrent' then round(rating_cost(v_type) * 0.40)
                      when 'rating' then rating_cost(v_type) else null end;
  if cost is null then raise exception 'Unknown training.'; end if;
  dur := case p_kind when 'opc' then interval '6 hours' else interval '24 hours' end;
  if (select cash from pilots where id = u) < cost then raise exception 'This costs %.', to_char(cost,'FM$999,999'); end if;
  update pilots set cash = cash - cost where id = u;
  update crew set status = 'training', training_kind = p_kind, training_until = now() + dur,
         type_code = v_type, aircraft_id = case when p_kind = 'rating' and v_type <> c.type_code then null else aircraft_id end,
         opc_due_at = case when p_kind in ('opc','rating') then now() + dur + interval '6 months' else opc_due_at end,
         recurrent_due_at = case when p_kind in ('recurrent','rating') then now() + dur + interval '12 months' else recurrent_due_at end
   where id = c.id;
  perform add_ledger(u, format('%s: %s', c.name, case p_kind when 'opc' then 'operator proficiency check' when 'recurrent' then 'recurrent training'
          else 'type rating on the ' || (select name from aircraft_types where code = v_type) end), -cost);
end $$;

create or replace function public.assign_crew(p_crew uuid, p_ac uuid)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := me(); c crew; f fleet;
begin
  select * into c from crew where id = p_crew and pilot_id = u for update;
  if c.id is null or c.status = 'quit' then raise exception 'Not one of your crew.'; end if;
  if p_ac is null then
    if exists (select 1 from fleet where id = c.aircraft_id and ops_mode = 'crew') then raise exception 'Switch that aircraft back to owner flying first.'; end if;
    update crew set aircraft_id = null where id = c.id; return;
  end if;
  select * into f from fleet where id = p_ac and pilot_id = u;
  if f.id is null then raise exception 'Not your aircraft.'; end if;
  if f.type_code <> c.type_code then raise exception '% isn''t rated on this type.', c.name; end if;
  if (select count(*) from crew where aircraft_id = p_ac and status <> 'quit' and id <> c.id) >= 2 * (select crew_req from aircraft_types where code = f.type_code) then
    raise exception 'That aircraft already has enough crew assigned.'; end if;
  update crew set aircraft_id = p_ac where id = c.id;
end $$;

create or replace function public.crew_ready(p_ac uuid) returns boolean language sql stable set search_path = public as $$
  select (select count(*) from crew c where c.aircraft_id = p_ac and c.status = 'active')
         >= (select t.crew_req from fleet f join aircraft_types t on t.code = f.type_code where f.id = p_ac)
$$;

create or replace function public.set_ops_mode(p_ac uuid, p_mode text)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := me(); f fleet;
begin
  select * into f from fleet where id = p_ac and pilot_id = u for update;
  if f.id is null then raise exception 'Not your aircraft.'; end if;
  if p_mode = 'crew' then
    if not crew_ready(p_ac) then raise exception 'Assign enough rated, current crew first (% needed).', (select crew_req from aircraft_types where code = f.type_code); end if;
    if exists (select 1 from trips where aircraft_id = p_ac and status in ('booked','flying','filed')) then
      raise exception 'Fly or cancel your own bookings on this aircraft first.'; end if;
    update fleet set ops_mode = 'crew', crew_legs = 0 where id = p_ac;
  elsif p_mode = 'owner' then
    if f.crew_busy_until > now() then raise exception 'The crew are flying. You can take it back once they land at %.', to_char(f.crew_busy_until at time zone 'UTC','HH24:MI"Z"'); end if;
    update fleet set ops_mode = 'owner', crew_trip = null where id = p_ac;
  else raise exception 'Unknown mode.'; end if;
end $$;

create or replace function public.pay_rise(p_crew uuid, p_pct int)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := me(); c crew;
begin
  if p_pct not in (5, 10, 15) then raise exception 'Choose 5, 10 or 15 percent.'; end if;
  select * into c from crew where id = p_crew and pilot_id = u for update;
  if c.id is null or c.status = 'quit' then raise exception 'Not one of your crew.'; end if;
  update crew set salary_week = round(salary_week * (1 + p_pct / 100.0)), satisfaction = least(100, satisfaction + p_pct * 2.5),
         last_raise_at = now(), rev_baseline = greatest(1, flight_income_7d(u)) where id = c.id;
  perform add_ledger(u, format('%s: %s%% pay rise', c.name, p_pct), 0);
end $$;

create or replace function public.fire_crew(p_crew uuid)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := me(); c crew; pay int;
begin
  select * into c from crew where id = p_crew and pilot_id = u for update;
  if c.id is null or c.status = 'quit' then raise exception 'Not one of your crew.'; end if;
  if exists (select 1 from fleet where id = c.aircraft_id and ops_mode = 'crew') then raise exception 'Switch their aircraft back to owner flying first.'; end if;
  pay := c.salary_week * 2;
  update pilots set cash = cash - pay where id = u;
  update crew set status = 'quit', aircraft_id = null, note = 'Let go' where id = c.id;
  perform add_ledger(u, format('Let %s go: two weeks'' severance', c.name), -pay);
end $$;

-- training finishes; overdue checks ground the pilot
create or replace function public.crew_upkeep(p_pilot uuid)
returns void language plpgsql set search_path = public as $$
begin
  update crew set status = 'active', training_kind = null, training_until = null
   where pilot_id = p_pilot and status = 'training' and training_until <= now();
  update crew set status = 'grounded', note = case when opc_due_at <= now() then 'OPC overdue' else 'Recurrent training overdue' end
   where pilot_id = p_pilot and status = 'active' and (opc_due_at <= now() or recurrent_due_at <= now());
  update crew set status = 'active', note = null
   where pilot_id = p_pilot and status = 'grounded' and opc_due_at > now() and recurrent_due_at > now();
end $$;

-- weekly payroll; satisfaction drifts down as the company earns more than when they were last rewarded
create or replace function public.payroll(p_pilot uuid)
returns void language plpgsql set search_path = public as $$
declare p pilots; c crew; total int; inc numeric; d numeric; i int := 0; wk_hours numeric;
begin
  loop
    select * into p from pilots where id = p_pilot for update;
    exit when p.next_payroll_at is null or p.next_payroll_at > now() or i >= 8;
    i := i + 1;
    select coalesce(sum(salary_week), 0) into total from crew where pilot_id = p_pilot and status <> 'quit';
    if total = 0 then update pilots set next_payroll_at = null where id = p_pilot; exit; end if;
    update pilots set cash = cash - total, next_payroll_at = next_payroll_at + interval '7 days' where id = p_pilot;
    perform add_ledger(p_pilot, format('Weekly crew salaries (%s)', (select case when count(*) = 1 then '1 pilot' else count(*) || ' pilots' end from crew where pilot_id = p_pilot and status <> 'quit')), -total);
    inc := flight_income_7d(p_pilot);
    for c in select * from crew where pilot_id = p_pilot and status <> 'quit' loop
      d := -1.5;
      if inc > c.rev_baseline * 1.25 then d := d - 3; end if;
      if inc > c.rev_baseline * 1.6 then d := d - 3; end if;
      if c.salary_week < base_salary(c.type_code) * (0.85 + c.skill / 200.0) * 0.95 then d := d - 2; end if;
      if c.last_raise_at > now() - interval '28 days' then d := d + 1; end if;
      select coalesce(sum(extract(epoch from t.ends_at - t.started_at) / 3600), 0) into wk_hours
        from trips t where t.aircraft_id = c.aircraft_id and t.source = 'crew' and t.started_at > now() - interval '7 days';
      if wk_hours > 35 then d := d - 2; end if;
      update crew set satisfaction = least(100, greatest(0, satisfaction + d)) where id = c.id returning * into c;
      if c.satisfaction < 25 and random() < 0.35 and not exists (select 1 from fleet where id = c.aircraft_id and crew_busy_until > now()) then
        update crew set status = 'quit', aircraft_id = null, note = 'Resigned: unhappy with pay' where id = c.id;
        update fleet set ops_mode = 'owner' where id = c.aircraft_id and not crew_ready(id);
        perform add_ledger(p_pilot, format('%s resigned. They felt underpaid as the company grew.', c.name), 0);
      end if;
    end loop;
  end loop;
end $$;

-- client briefs: who is asking and what they want on board
create or replace function public.make_brief(p_client text, p_pax int)
returns jsonb language plpgsql volatile set search_path = public as $$
declare items jsonb := '[]'; pool jsonb; n int; pick jsonb; reps text[] := array['Sophie Grant','Marco Bellini','Claire Dubois','Tom Hartley','Aisha Rahman','Lena Vogel','Daniel Reyes','Harriet Cole'];
  roles text[] := array['PA','executive assistant','travel coordinator','family office manager','chief of staff']; v_rep text; txt text;
begin
  pool := '[
   {"kind":"Catering","text":"Light breakfast: croissants, fresh fruit and orange juice","cost":350},
   {"kind":"Catering","text":"Sushi platter for everyone","cost":900},
   {"kind":"Catering","text":"Afternoon tea with finger sandwiches and scones","cost":450},
   {"kind":"Catering","text":"Hot meal: grilled salmon with seasonal vegetables","cost":700},
   {"kind":"Drinks","text":"A bottle of vintage champagne chilled on board","cost":600},
   {"kind":"Drinks","text":"Freshly ground coffee and oat milk","cost":80},
   {"kind":"Drinks","text":"Macallan 18 for the principal","cost":450},
   {"kind":"Drinks","text":"Sparkling water only: no alcohol on board, please","cost":0},
   {"kind":"Dietary","text":"One passenger is coeliac: everything gluten-free","cost":150},
   {"kind":"Dietary","text":"Vegan meals for all passengers","cost":200},
   {"kind":"Dietary","text":"Severe nut allergy: no nuts anywhere on board","cost":0},
   {"kind":"Dietary","text":"Halal meals, please","cost":200},
   {"kind":"Decoration","text":"Fresh white roses in the cabin","cost":250},
   {"kind":"Ground","text":"A car to meet the aircraft planeside on arrival","cost":300},
   {"kind":"Comfort","text":"Blankets and pillows: they''ll want to sleep","cost":0},
   {"kind":"Comfort","text":"Quiet cabin please: they''ll be working","cost":0}]';
  pool := pool || case
    when p_client in ('Wedding party') then '[{"kind":"Decoration","text":"Just Married banner and rose petals","cost":400},{"kind":"Drinks","text":"Champagne toast on departure","cost":500}]'::jsonb
    when p_client in ('Medical transfer','Urgent repatriation') then '[{"kind":"Ground","text":"Wheelchair assistance at both ends","cost":150},{"kind":"Comfort","text":"Space for a stretcher and a medical escort","cost":0}]'::jsonb
    when p_client in ('Golf weekend') then '[{"kind":"Baggage","text":"Four sets of golf clubs in the hold","cost":0}]'::jsonb
    when p_client in ('Family office','Private client') then '[{"kind":"Comfort","text":"Children aged 4 and 7: colouring books and snacks","cost":120},{"kind":"Comfort","text":"A small dog travelling in the cabin (6 kg)","cost":0},{"kind":"Decoration","text":"Birthday cake and balloons for the eldest","cost":400}]'::jsonb
    when p_client in ('Football club','Motorsport team') then '[{"kind":"Catering","text":"High-protein meals and isotonic drinks","cost":500},{"kind":"Baggage","text":"Extra kit bags: about 200 kg","cost":0}]'::jsonb
    when p_client in ('Film production','Touring musician') then '[{"kind":"Baggage","text":"Camera and instrument cases in the cabin","cost":0},{"kind":"Comfort","text":"Strict confidentiality: no photos, no names on the manifest","cost":0}]'::jsonb
    else '[]'::jsonb end;
  n := 1 + floor(random() * 3)::int;
  for i in 1..n loop
    pick := pool -> floor(random() * jsonb_array_length(pool))::int;
    if not items @> jsonb_build_array(pick) then items := items || jsonb_build_array(pick || jsonb_build_object('id', i)); end if;
  end loop;
  v_rep := reps[1 + floor(random()*array_length(reps,1))::int];
  txt := (array[
    'Thanks for taking this one at short notice. A few things to have ready:',
    'Please make sure the following are sorted before departure:',
    'The principal is particular about details, so please check these:',
    'Just a couple of requests for this trip:'])[1 + floor(random()*4)::int];
  return jsonb_build_object('from', format('%s, %s', v_rep, roles[1 + floor(random()*array_length(roles,1))::int]),
                            'client', p_client, 'pax', p_pax, 'text', txt, 'items', items);
end $$;

-- book_trip now attaches the client's brief
create or replace function public.book_trip(p_pilot uuid, p_ac uuid, p_from text, p_to text, p_dist int, p_pax int,
  p_client text, p_caller text, p_dep timestamptz, p_price int, p_source text)
returns bigint language plpgsql set search_path = public as $$
declare tid bigint;
begin
  insert into trips(pilot_id, aircraft_id, kind, flt, from_icao, to_icao, dist, pax, client, caller, dep_at, price, source, seq, brief)
  values (p_pilot, p_ac, 'charter', flt_no(p_pilot, false), p_from, p_to, p_dist, p_pax, p_client, p_caller, p_dep, p_price, p_source, 1000000,
          make_brief(p_client, p_pax))
  returning id into tid;
  perform rebuild_ferries(p_ac);
  return tid;
end $$;
update public.trips set brief = make_brief(client, pax) where kind = 'charter' and brief is null and status in ('booked','flying');

-- =====================================================================
-- crew flying: legs happen in real time and are caught up whenever anyone uses the site
-- =====================================================================
create or replace function public.crew_settle(p_trip bigint)
returns void language plpgsql set search_path = public as $$
declare t trips; f fleet; ty aircraft_types; p pilots; cost numeric; q numeric; v_rep numeric; repo_h numeric; bh numeric; note text := '';
begin
  select * into t from trips where id = p_trip and status = 'crew_flying' for update;
  if t.id is null then return; end if;
  select * into f from fleet where id = t.aircraft_id for update;
  select * into ty from aircraft_types where code = f.type_code;
  select * into p from pilots where id = t.pilot_id for update;
  bh := block_h(ty.ktas, t.dist);
  repo_h := greatest(0, extract(epoch from t.ends_at - t.started_at) / 3600 - bh - 0.25);
  cost := op_rate(round(ty.rate * f.op_mul)::int, p.upgrades) * (bh + repo_h * (1 - 0.25 * coalesce((p.upgrades->>'empty')::int,0)));
  select coalesce(avg((skill + satisfaction) / 2), 60) into q from crew where aircraft_id = f.id and status = 'active';
  if q >= 75 then v_rep := 0.3; note := 'Smooth trip.';
  elsif q < 45 then v_rep := -0.7; note := 'The client noticed an unhappy crew.';
  else v_rep := 0.1; end if;
  update pilots set cash = cash + t.price - round(cost), rep = least(100, greatest(0, rep + v_rep)) where id = p.id;
  update fleet set loc = t.to_icao, hours = hours + bh + repo_h, crew_trip = null where id = f.id;
  update crew set hours = hours + bh + repo_h, flights = flights + 1 where aircraft_id = f.id and status = 'active';
  update trips set status = 'crew_done' where id = t.id;
  insert into ledger(pilot_id, at, text, amount, kind)
  values (p.id, t.ends_at, format('Crew flight %s %s–%s (%s): revenue %s, costs %s. %s', t.flt, t.from_icao, t.to_icao, f.reg,
          to_char(t.price,'FM$999,999,990'), to_char(round(cost),'FM$999,999,990'), note), (t.price - round(cost))::bigint, 'flight');
end $$;

create or replace function public.crew_ops()
returns void language plpgsql set search_path = public as $$
declare f fleet; ty aircraft_types; r route_pick; best route_pick; start_at timestamptz; repo int; best_repo int; bh numeric; rh numeric; price numeric; tid bigint; n int;
begin
  for f in select * from fleet where ops_mode = 'crew' order by id loop
    n := 0;
    loop
      n := n + 1; exit when n > 8;
      select * into f from fleet where id = f.id;
      select * into ty from aircraft_types where code = f.type_code;
      if f.crew_trip is not null then
        exit when f.crew_busy_until > now();
        perform crew_settle(f.crew_trip);
        select * into f from fleet where id = f.id;
        -- a few legs, then a rest period
        if f.crew_legs >= 3 then
          start_at := f.crew_busy_until + interval '11 hours' + random() * interval '2 hours';
          update fleet set crew_legs = 0 where id = f.id;
        else
          start_at := f.crew_busy_until + interval '90 minutes' + random() * interval '150 minutes';
        end if;
        update fleet set crew_busy_until = start_at where id = f.id;
        continue;
      end if;
      start_at := greatest(coalesce(f.crew_busy_until, now()), now() - interval '3 days');
      exit when start_at > now();
      if not crew_ready(f.id) then update fleet set ops_mode = 'owner', crew_busy_until = null where id = f.id; exit; end if;
      -- the crew take the closest of a few enquiries, and the client pays for positioning
      best := null; best_repo := 99999;
      for k in 1..4 loop
        r := gen_route(f.loc, floor(ty.range_nm * 0.9)::int, ty.seats, ty.min_rwy_ft);
        continue when r.from_icao is null;
        repo := case when r.from_icao = f.loc then 0 else ap_nm(f.loc, r.from_icao) end;
        if repo < best_repo then best := r; best_repo := repo; end if;
        exit when repo = 0;
      end loop;
      if best.from_icao is null or best_repo > 400 then
        update fleet set crew_busy_until = start_at + interval '45 minutes' where id = f.id; continue;
      end if;
      r := best; repo := best_repo;
      bh := block_h(ty.ktas, r.dist); rh := block_h(ty.ktas, repo);
      price := round((ty.rate * f.rate_mul * bh + 0.55 * ty.rate * rh) * (0.9 + random() * 0.15) / 100) * 100;
      insert into trips(pilot_id, aircraft_id, kind, flt, from_icao, to_icao, dist, pax, client, dep_at, price, source, status, seq, started_at, ends_at, created_at)
      values (f.pilot_id, f.id, 'charter', flt_no(f.pilot_id, false), r.from_icao, r.to_icao, r.dist, r.pax, r.client,
              start_at + rh * interval '1 hour', price, 'crew', 'crew_flying', 0, start_at, start_at + (rh + bh + 0.25) * interval '1 hour', start_at)
      returning id into tid;
      update fleet set crew_trip = tid, crew_busy_until = start_at + (rh + bh + 0.25) * interval '1 hour', crew_legs = crew_legs + 1 where id = f.id;
    end loop;
  end loop;
end $$;

-- loan payments, caught up week by week
create or replace function public.finance_upkeep(p_pilot uuid)
returns void language plpgsql set search_path = public as $$
declare f fleet; interest numeric; principal numeric; pay numeric; i int;
begin
  for f in select * from fleet where pilot_id = p_pilot and loan_balance > 0 and next_payment_at <= now() loop
    i := 0;
    loop
      select * into f from fleet where id = f.id for update;
      exit when f.loan_balance <= 0 or f.next_payment_at > now() or i >= 8;
      i := i + 1;
      interest := round(f.loan_balance * 0.065 / 52, 2);
      pay := least(f.loan_payment, f.loan_balance + interest);
      principal := pay - interest;
      update fleet set loan_balance = greatest(0, loan_balance - principal), next_payment_at = next_payment_at + interval '7 days' where id = f.id;
      update pilots set cash = cash - pay where id = p_pilot;
      perform add_ledger(p_pilot, format('Loan payment on %s (%s interest)', f.reg, to_char(interest,'FM$999,999,990')), -round(pay)::bigint);
    end loop;
  end loop;
end $$;

-- =====================================================================
-- flight planning actions
-- =====================================================================
create or replace function public.is_international(p_from text, p_to text) returns boolean language sql stable set search_path = public as $$
  select (select country from airports where icao = p_from) is distinct from (select country from airports where icao = p_to)
$$;

create or replace function public.trip_prep(p_trip bigint, p_action text, p_value jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := me(); t trips; item jsonb; cost int; pr jsonb;
begin
  select * into t from trips where id = p_trip and pilot_id = u for update;
  if t.id is null or t.status not in ('booked','flying') then raise exception 'That trip can''t be changed now.'; end if;
  pr := coalesce(t.prep, '{}');
  if p_action = 'arrange' then
    select e into item from jsonb_array_elements(coalesce(t.brief->'items','[]')) e where (e->>'id')::int = (p_value->>'id')::int;
    if item is null then raise exception 'Unknown request.'; end if;
    if pr->'arranged' @> to_jsonb((item->>'id')::int) then return pr; end if;
    cost := coalesce((item->>'cost')::int, 0);
    if cost > 0 then
      update pilots set cash = cash - cost where id = u;
      perform add_ledger(u, format('%s: %s', t.flt, item->>'text'), -cost);
    end if;
    pr := jsonb_set(pr, '{arranged}', coalesce(pr->'arranged','[]') || to_jsonb((item->>'id')::int));
  elsif p_action = 'customs' then
    if not is_international(t.from_icao, t.to_icao) then raise exception 'This is a domestic flight: no customs forms needed.'; end if;
    if not coalesce((pr->>'customs')::boolean, false) then
      update pilots set cash = cash - 150 where id = u;
      perform add_ledger(u, format('%s: customs declaration via handling agent', t.flt), -150);
    end if;
    pr := jsonb_set(pr, '{customs}', 'true');
  elsif p_action = 'fuel' then
    pr := jsonb_set(pr, '{extra_min}', to_jsonb(greatest(0, least(180, coalesce((p_value->>'extra_min')::int, 0)))));
  elsif p_action = 'ofp' then
    if p_value->>'orig' is distinct from t.from_icao or p_value->>'dest' is distinct from t.to_icao then
      raise exception 'That SimBrief plan is for % to %, not this trip (% to %).', p_value->>'orig', p_value->>'dest', t.from_icao, t.to_icao;
    end if;
    update trips set ofp = p_value where id = t.id;
    pr := jsonb_set(pr, '{ofp}', 'true');
  else raise exception 'Unknown planning step.'; end if;
  update trips set prep = pr where id = t.id;
  return pr;
end $$;

create or replace function public.set_simbrief(p_user text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update pilots set simbrief = nullif(left(trim(p_user), 40), '') where id = me();
end $$;

-- =====================================================================
-- passengers ask for things in flight (answer from the tracker or the website)
-- =====================================================================
create or replace function public.cabin_request_pool() returns jsonb language sql immutable as $$
  select '[
   {"text":"Could we have some more champagne, please?","options":["Of course, on its way","We''re saving the last bottle for landing"]},
   {"text":"What time do we land?","options":["Give them the ETA","Point them to the cabin moving map"]},
   {"text":"It''s a bit warm back here. Could you cool the cabin?","options":["Turn the temperature down","It will settle in a few minutes"]},
   {"text":"Is this turbulence normal? One of us is nervous.","options":["Reassure them on the PA","Ask ATC for a smoother level"]},
   {"text":"Can we see anything interesting out of the window?","options":["Point out the landmarks","Not on this routing, sorry"]},
   {"text":"The Wi-Fi has dropped out.","options":["Reset the system","Apologise: no coverage here"]},
   {"text":"Could you arrange a car for us when we land?","options":["Call ahead to the handler","Suggest the taxi rank"]},
   {"text":"Is it OK to move about the cabin?","options":["Yes, the seatbelt sign is off","Please stay seated for now"]},
   {"text":"Any chance of seeing the flight deck after landing?","options":["Happily, after shutdown","Not today, sorry"]},
   {"text":"Could you dim the cabin lights? We''d like to sleep.","options":["Dim the lights","Keep them up for the meal"]},
   {"text":"Can we get a hot drink?","options":["Coffee and tea coming up","Only cold drinks on this sector"]},
   {"text":"We''re celebrating. Anything special on board?","options":["Bring out the dessert","Offer congratulations on the PA"]}
  ]'::jsonb
$$;

create or replace function public.cabin_tick(p_pilot uuid, p_trip bigint, p_phase text)
returns void language plpgsql set search_path = public as $$
declare t trips; pick jsonb; last_at timestamptz;
begin
  -- unanswered requests cost a little reputation
  with gone as (update cabin_requests set status = 'missed' where pilot_id = p_pilot and status = 'open' and expires_at < now() returning 1)
  update pilots set rep = greatest(0, rep - 0.2 * (select count(*) from gone)) where id = p_pilot and exists (select 1 from gone);
  if p_trip is null or p_phase not in ('Climb','Cruise','Descent') then return; end if;
  select * into t from trips where id = p_trip and pilot_id = p_pilot;
  if t.id is null or t.kind <> 'charter' or t.pax = 0 then return; end if;
  if exists (select 1 from cabin_requests where pilot_id = p_pilot and status = 'open') then return; end if;
  select max(created_at) into last_at from cabin_requests where trip_id = p_trip;
  if coalesce(last_at, t.started_at, now() - interval '1 hour') > now() - interval '12 minutes' then return; end if;
  if random() > 0.05 then return; end if;
  pick := cabin_request_pool() -> floor(random() * jsonb_array_length(cabin_request_pool()))::int;
  insert into cabin_requests(pilot_id, trip_id, text, options, expires_at)
  values (p_pilot, p_trip, pick->>'text', pick->'options', now() + interval '8 minutes');
end $$;

create or replace function public.answer_cabin_core(p_pilot uuid, p_req bigint, p_choice int, p_via text)
returns void language plpgsql set search_path = public as $$
declare r cabin_requests;
begin
  select * into r from cabin_requests where id = p_req and pilot_id = p_pilot for update;
  if r.id is null then raise exception 'Unknown request.'; end if;
  if r.status <> 'open' then return; end if;
  update cabin_requests set status = 'answered', answer = p_choice, answered_via = p_via where id = r.id;
  update pilots set rep = least(100, rep + case when p_choice = 0 then 0.1 else 0.05 end) where id = p_pilot;
end $$;

create or replace function public.answer_cabin(p_req bigint, p_choice int)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform answer_cabin_core(me(), p_req, p_choice, 'web');
end $$;

drop function if exists public.tracker_position(text,bigint,float8,float8,int,int,int,text);
create or replace function public.tracker_position(p_key text, p_trip bigint, p_lat float8, p_lon float8, p_alt int, p_gs int, p_hdg int, p_phase text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := tracker_pilot(p_key); res jsonb;
begin
  insert into positions(pilot_id, trip_id, lat, lon, alt, gs, hdg, phase, updated_at)
  values (u, p_trip, p_lat, p_lon, p_alt, p_gs, p_hdg, left(p_phase, 20), now())
  on conflict (pilot_id) do update set trip_id = excluded.trip_id, lat = excluded.lat, lon = excluded.lon, alt = excluded.alt,
    gs = excluded.gs, hdg = excluded.hdg, phase = excluded.phase, updated_at = now();
  update pilots set last_seen = now() where id = u;
  perform cabin_tick(u, p_trip, p_phase);
  select jsonb_build_object('requests', coalesce(jsonb_agg(jsonb_build_object('id', id, 'text', text, 'options', options,
           'expires_at', expires_at) order by id), '[]'))
    into res from cabin_requests where pilot_id = u and status = 'open';
  return res;
end $$;

create or replace function public.tracker_answer(p_key text, p_req bigint, p_choice int)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform answer_cabin_core(tracker_pilot(p_key), p_req, p_choice, 'tracker');
end $$;

-- =====================================================================
-- functions that now account for aircraft age, crew mode, briefs and fines
-- =====================================================================
create or replace function public.resolve_request(p_req bigint)
returns void language plpgsql set search_path = public as $$
declare
  rq public.requests; bm numeric; b record; best_id bigint; best_eff numeric := 1e9;
  npc_min numeric := 1e9; eff numeric; budget numeric;
begin
  select * into rq from public.requests where id = p_req for update;
  select budget_mul into bm from public.request_secrets where request_id = p_req;
  for i in 1..rq.npc loop
    npc_min := least(npc_min, 0.92 + random()*0.30 + random()*0.22);
  end loop;
  for b in select bd.*, p.rep, p.upgrades, ty.rate * f.rate_mul as rate, ty.ktas from public.bids bd
             join public.pilots p on p.id = bd.pilot_id
             join public.fleet f on f.id = bd.aircraft_id
             join public.aircraft_types ty on ty.code = f.type_code
            where bd.request_id = p_req and bd.status = 'pending' loop
    budget := b.basis * bm * (1 + (b.rep - 50)/600) + 0.55 * b.rate * public.block_h(b.ktas, b.repo_nm) * 0.6;
    if b.amount > budget then
      update public.bids set status = 'lost', note = 'Over the client''s budget.' where id = b.id;
      continue;
    end if;
    eff := b.amount / b.basis / (1 + (b.rep - 50)/400) * (1 - 0.03 * coalesce((b.upgrades->>'broker')::int,0));
    if eff < best_eff then best_eff := eff; best_id := b.id; end if;
  end loop;

  if best_id is not null and best_eff < npc_min then
    select bd.*, p.callsign into b from public.bids bd join public.pilots p on p.id = bd.pilot_id where bd.id = best_id;
    update public.bids set status = 'won', note = 'Client accepted your quote.' where id = best_id;
    update public.requests set status = 'awarded', winner = b.pilot_id where id = p_req;
    perform public.book_trip(b.pilot_id, b.aircraft_id, rq.from_icao, rq.to_icao, rq.dist, rq.pax, rq.client, null, rq.dep_at, b.amount, 'bid');
    perform public.add_ledger(b.pilot_id, format('Won %s–%s for %s at $%s', rq.from_icao, rq.to_icao, rq.client, to_char(b.amount,'FM999,999,999')), 0);
    update public.bids set status = 'lost', note = format('%s won with a better quote.', b.callsign)
     where request_id = p_req and status = 'pending';
  else
    update public.requests set status = 'unawarded' where id = p_req;
    for b in select * from public.bids where request_id = p_req and status = 'pending' loop
      update public.bids set status = 'lost',
        note = format('Another operator won at about $%s.', to_char(round(npc_min * b.basis / 100) * 100, 'FM999,999,999'))
       where id = b.id;
    end loop;
  end if;
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
  if f.ops_mode = 'crew' then raise exception '% is being flown by your crew. Switch it back to owner flying to quote.', f.reg; end if;
  select * into ty from aircraft_types where code = f.type_code;
  if rq.pax > ty.seats then raise exception 'Not enough seats.'; end if;
  if rq.dist > ty.range_nm * 0.92 then raise exception 'Beyond this aircraft''s range.'; end if;
  if not rwy_ok(rq.from_icao, rq.to_icao, ty.min_rwy_ft) then raise exception 'A runway on this route is too short for the %.', ty.name; end if;
  wait := (array[30,22,15,10])[1 + least(3, coalesce((p.upgrades->>'fast')::int,0))];
  if rq.decide_at is null and rq.expires_at < now() + wait * interval '1 second' then raise exception 'That request is closing too soon to quote.'; end if;
  loc := future_loc(f.id);
  repo := case when loc = rq.from_icao then 0 else ap_nm(loc, rq.from_icao) end;
  basis := ty.rate * f.rate_mul * block_h(ty.ktas, rq.dist);
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
  if f.id is null or f.ops_mode = 'crew' or c.pax > ty.seats or c.dist > ty.range_nm * 0.92 or not rwy_ok(c.from_icao, c.to_icao, ty.min_rwy_ft) then
    raise exception 'That aircraft can''t fly this job.'; end if;
  update calls set status = 'accepted' where id = c.id;
  tid := book_trip(u, f.id, c.from_icao, c.to_icao, c.dist, c.pax, c.client, c.caller, c.dep_at, c.offer, 'call');
  perform add_ledger(u, format('Phone booking from %s: %s–%s for $%s', c.caller, c.from_icao, c.to_icao, to_char(c.offer,'FM999,999,999')), 0);
  perform schedule_call(u);
  return tid;
end $$;

create or replace function public.poll()
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := me(); p pilots; c record; ac record; r route_pick; fair numeric; ev jsonb; cab jsonb;
begin
  update pilots set last_seen = now() where id = u returning * into p;
  perform maintain();
  perform crew_upkeep(u);
  perform payroll(u);
  perform finance_upkeep(u);
  perform cabin_tick(u, null, '');

  for c in select * from calls where pilot_id = u and status = 'ringing' and expires_at < now() loop
    update calls set status = 'missed' where id = c.id;
    perform schedule_call(u);
  end loop;

  if not exists (select 1 from calls where pilot_id = u and status = 'ringing') and p.next_call_at <= now() then
    select f.id, f.type_code, f.rate_mul, t.* into ac from fleet f join aircraft_types t on t.code = f.type_code
     where f.pilot_id = u and f.ops_mode = 'owner' order by random() limit 1;
    if ac.id is not null then
      r := gen_route(future_loc(ac.id), floor(ac.range_nm*0.9)::int, ac.seats, ac.min_rwy_ft);
      if r.from_icao is not null then
        fair := ac.rate * ac.rate_mul * block_h(ac.ktas, r.dist)
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
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'text', text, 'options', options, 'expires_at', expires_at) order by id), '[]')
    into cab from cabin_requests where pilot_id = u and status = 'open';
  return jsonb_build_object('events', ev, 'cabin', cab, 'now', now());
end $$;

-- maintain also runs crew flights
create or replace function public.maintain()
returns void language plpgsql set search_path = public as $$
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

  for tr in select * from public.trips where kind = 'charter' and status = 'booked' and dep_at < now() - interval '48 hours' loop
    update public.trips set status = 'cancelled' where id = tr.id;
    update public.pilots set rep = greatest(0, rep - 3) where id = tr.pilot_id;
    perform public.add_ledger(tr.pilot_id, format('%s %s–%s lapsed unflown; client rebooked elsewhere', tr.flt, tr.from_icao, tr.to_icao), 0);
    perform public.rebuild_ferries(tr.aircraft_id);
  end loop;

  perform public.crew_ops();

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
         where p.last_seen > now() - interval '15 minutes' and f.ops_mode = 'owner' order by random() limit 1;
      end if;
      perform public.spawn_request(near, null, null);
    end loop;
    update public.va_settings set last_spawn = now();
  end if;
  update public.va_settings set last_maint = now();
end $$;

create or replace function public.outsource_ferry(p_trip bigint)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := me(); t trips; p pilots; ty aircraft_types; f fleet; cost int;
begin
  select * into t from trips where id = p_trip and pilot_id = u for update;
  if t.id is null or t.kind <> 'ferry' or t.status <> 'booked' then raise exception 'That positioning leg can''t be outsourced.'; end if;
  if exists (select 1 from trips where aircraft_id = t.aircraft_id and status in ('booked','flying') and seq < t.seq) then
    raise exception 'Fly or clear the earlier trips for this aircraft first.';
  end if;
  select * into p from pilots where id = u;
  select * into f from fleet where id = t.aircraft_id;
  select * into ty from aircraft_types where code = f.type_code;
  cost := round(op_rate(round(ty.rate * f.op_mul)::int, p.upgrades) * block_h(ty.ktas, t.dist) * 1.5);
  update trips set status = 'outsourced' where id = t.id;
  update fleet set loc = t.to_icao, hours = hours + block_h(ty.ktas, t.dist) where id = t.aircraft_id;
  update pilots set cash = cash - cost where id = u;
  perform add_ledger(u, format('Contract crew positioned aircraft %s–%s', t.from_icao, t.to_icao), -cost);
end $$;

create or replace function public.settle(p_pirep bigint)
returns void language plpgsql set search_path = public as $$
declare
  pr public.pireps; tr public.trips; p public.pilots; ty public.aircraft_types; f public.fleet;
  op numeric; v_cost numeric; v_rev int; v_tip int := 0; v_rep numeric := 0; est numeric; note text := ''; fine int := 0; missed int := 0; item jsonb;
begin
  select * into pr from public.pireps where id = p_pirep for update;
  select * into tr from public.trips where id = pr.trip_id;
  select * into p from public.pilots where id = pr.pilot_id for update;
  select * into f from public.fleet where id = tr.aircraft_id;
  select * into ty from public.aircraft_types where code = f.type_code;
  op := public.op_rate(round(ty.rate * coalesce(f.op_mul, 1))::int, p.upgrades) * pr.block_h;

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
    -- the client's special requests
    for item in select e from jsonb_array_elements(coalesce(tr.brief->'items','[]')) e loop
      if not coalesce(tr.prep->'arranged','[]') @> to_jsonb((item->>'id')::int) then missed := missed + 1; end if;
    end loop;
    if missed > 0 then v_rep := v_rep - 0.5 * missed; note := note || format('%s client request%s not arranged. ', missed, case when missed > 1 then 's' else '' end); end if;
    -- customs
    if public.is_international(tr.from_icao, coalesce(pr.arr_icao, tr.to_icao)) and not coalesce((tr.prep->>'customs')::boolean, false) then
      fine := 3000 + round(tr.price * 0.05); v_rep := v_rep - 1; note := note || format('Customs fine of $%s: no declaration was filed. ', to_char(fine,'FM999,999'));
    end if;
  end if;
  if v_rep > 0 then v_rep := v_rep * (1 + 0.25 * coalesce((p.upgrades->>'pr')::int,0)); end if;

  update public.pireps set status = 'accepted', revenue = v_rev + v_tip, cost = round(v_cost) + fine, tip = v_tip, fines = fine,
         net = v_rev + v_tip - round(v_cost) - fine, rep_delta = v_rep,
         review_note = coalesce(nullif(review_note,''), trim(note))
   where id = p_pirep;
  update public.pilots set cash = cash + v_rev + v_tip - round(v_cost) - fine, rep = least(100, greatest(0, rep + v_rep)) where id = p.id;
  update public.fleet set hours = hours + pr.block_h where id = tr.aircraft_id;
  update public.trips set status = 'accepted' where id = tr.id;
  insert into public.ledger(pilot_id, text, amount, kind)
  values (p.id, format('%s %s–%s: revenue $%s, operating cost $%s%s', tr.flt, tr.from_icao, tr.to_icao,
          to_char(v_rev + v_tip,'FM999,999,990'), to_char(round(v_cost),'FM999,999,990'),
          case when fine > 0 then format(', customs fine $%s', to_char(fine,'FM999,999')) else '' end),
          (v_rev + v_tip - round(v_cost) - fine)::bigint, 'flight');
end $$;

-- the tracker now reports fuel on blocks, which carries over to the next flight
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
                     block_h, air_h, fuel_used_lb, fuel_end_lb, landing_fpm, landing_g, bounces, arr_icao, dist_flown, checks, path)
  values (t.id, u, t.aircraft_id, left(d->>'sim', 40), title, left(d->>'tracker_ver', 20), bo, tko, ldg, bn,
          bh, airh, (d->>'fuel_used_lb')::numeric, nullif(d->>'fuel_end_lb','')::numeric, abs((d->>'landing_fpm')::numeric)::int, (d->>'landing_g')::numeric,
          coalesce((d->>'bounces')::int, 0), arr, (d->>'dist_flown')::numeric::int, chk,
          coalesce(case when jsonb_typeof(d->'path') = 'array' and jsonb_array_length(d->'path') <= 4000 then d->'path' end, '[]'))
  returning id into pid;

  update trips set status = 'filed' where id = t.id;
  update fleet set loc = arr, fuel_lb = coalesce(nullif(d->>'fuel_end_lb','')::numeric, fuel_lb) where id = t.aircraft_id;
  delete from positions where pilot_id = u;
  update cabin_requests set status = 'missed' where pilot_id = u and status = 'open';
  if arr <> t.to_icao then perform rebuild_ferries(t.aircraft_id); end if;

  if ok and s.auto_accept then perform settle(pid); end if;
  select jsonb_build_object('pirep', id, 'status', status, 'net', net, 'rep_delta', rep_delta, 'checks', checks, 'note', review_note)
    into res from pireps where id = pid;
  return res;
end $$;

-- new pilots: a used starter aircraft they own outright, and more opening capital
create or replace function public.ensure_pilot(p_callsign text, p_name text, p_company text, p_prefix text, p_home text,
  p_type text, p_reg text, p_prefs jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); s va_settings; first_pilot boolean; v_type text; v_reg text; v_year int;
begin
  if u is null then raise exception 'Sign in first.'; end if;
  if exists (select 1 from pilots where id = u) then return u; end if;
  select * into s from va_settings;
  p_callsign := upper(trim(p_callsign)); p_prefix := upper(trim(p_prefix));
  if p_callsign !~ '^[A-Z0-9]{3,8}$' then raise exception 'Callsign must be 3–8 letters or numbers.'; end if;
  if p_prefix !~ '^[A-Z]{3}$' then raise exception 'Flight number prefix must be 3 letters.'; end if;
  if length(trim(coalesce(p_name,''))) < 2 then raise exception 'Enter your name.'; end if;
  if length(trim(coalesce(p_company,''))) < 2 then raise exception 'Enter a company name.'; end if;
  if exists (select 1 from pilots where callsign = p_callsign) then raise exception 'That callsign is taken.'; end if;
  if not exists (select 1 from airports where icao = upper(p_home) and active) then p_home := s.start_home; end if;
  select code into v_type from aircraft_types where code = p_type and starter;
  if v_type is null then raise exception 'Choose one of the starter aircraft.'; end if;
  v_reg := claim_reg(p_reg, null);
  v_year := extract(year from now())::int - 14;
  first_pilot := not exists (select 1 from pilots);
  insert into pilots(id, callsign, name, company, prefix, home, cash, is_admin, next_call_at, prefs)
  values (u, p_callsign, trim(p_name), trim(p_company), p_prefix, upper(p_home), s.start_cash, first_pilot,
          now() + interval '45 seconds', clean_prefs(coalesce(p_prefs,'{}')));
  insert into pilot_keys(pilot_id, tracker_key) values (u, replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-',''));
  insert into fleet(pilot_id, type_code, reg, loc, year_built, rate_mul, op_mul, hours)
  values (u, v_type, v_reg, upper(p_home), v_year, age_rate_mul(v_year), age_op_mul(v_year), 14 * 300);
  perform add_ledger(u, format('%s founded at %s with a %s %s, %s', trim(p_company), upper(p_home), v_year,
          (select name from aircraft_types where code = v_type), v_reg), s.start_cash);
  return u;
end $$;

-- opening capital: enough to hire and train a first pilot
update public.va_settings set start_cash = 250000 where start_cash < 250000;
do $$
declare p record;
begin
  for p in select id from public.pilots pl
            where not exists (select 1 from public.ledger l where l.pilot_id = pl.id and l.text like 'Opening capital top-up%') loop
    update public.pilots set cash = cash + 190000 where id = p.id;
    insert into public.ledger(pilot_id, text, amount) values (p.id, 'Opening capital top-up for crew and aircraft finance', 190000);
  end loop;
end $$;

-- airports: import also carries the time zone ([.., scheduled, tz])
create or replace function public.import_airports(p_rows jsonb)
returns int language plpgsql set search_path = public as $$
declare n int;
begin
  insert into airports(icao, name, city, country, lat, lon, size, rwy_ft, paved, scheduled, tz, tags, active)
  select r->>0, r->>1, r->>2, coalesce(r->>3,''), (r->>4)::float8, (r->>5)::float8, coalesce(r->>6,'medium'),
         coalesce((r->>7)::int, 6000), coalesce((r->>8)::boolean, true), coalesce((r->>9)::boolean, false), coalesce(r->>10, 'UTC'),
         case when r->>6 = 'large' then '{biz}'::text[]
              when r->>6 = 'medium' and coalesce((r->>9)::boolean,false) then '{leisure}'::text[]
              else '{}'::text[] end,
         true
    from jsonb_array_elements(p_rows) r
   where (r->>0) ~ '^[A-Z0-9]{3,4}$'
  on conflict (icao) do update set lat = excluded.lat, lon = excluded.lon, size = excluded.size,
    rwy_ft = excluded.rwy_ft, paved = excluded.paved, scheduled = excluded.scheduled, tz = excluded.tz;
  get diagnostics n = row_count;
  return n;
end $$;

-- =====================================================================
-- security
-- =====================================================================
alter table public.crew enable row level security;
alter table public.cabin_requests enable row level security;
revoke insert, update, delete, truncate on public.crew, public.cabin_requests from anon, authenticated;
drop policy if exists read_own on public.crew;           create policy read_own on public.crew           for select to authenticated using (pilot_id = auth.uid());
drop policy if exists read_own on public.cabin_requests; create policy read_own on public.cabin_requests for select to authenticated using (pilot_id = auth.uid());

do $$
declare f text;
begin
  foreach f in array array['ac_age(int)','ac_value(numeric,int)','age_rate_mul(int)','age_op_mul(int)','weekly_payment(numeric)',
     'listings(text)','crew_tier(text)','base_salary(text)','rating_cost(text)','flight_income_7d(uuid)','crew_ready(uuid)',
     'crew_upkeep(uuid)','payroll(uuid)','make_brief(text,int)','crew_settle(bigint)','crew_ops()','finance_upkeep(uuid)',
     'is_international(text,text)','cabin_request_pool()','cabin_tick(uuid,bigint,text)','answer_cabin_core(uuid,bigint,int,text)',
     'book_trip(uuid,uuid,text,text,int,int,text,text,timestamptz,int,text)','resolve_request(bigint)','maintain()','settle(bigint)',
     'import_airports(jsonb)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['shop_listings()','buy_listing(text,int,text,boolean)','payoff_loan(uuid)','sell_aircraft(uuid)',
     'crew_candidates()','hire_crew(int,text)','crew_training(uuid,text,text)','assign_crew(uuid,uuid)','set_ops_mode(uuid,text)',
     'pay_rise(uuid,int)','fire_crew(uuid)','trip_prep(bigint,text,jsonb)','set_simbrief(text)','answer_cabin(bigint,int)',
     'place_bid(bigint,uuid,int)','accept_call(bigint,uuid)','poll()','outsource_ferry(bigint)',
     'ensure_pilot(text,text,text,text,text,text,text,jsonb)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  foreach f in array array['tracker_position(text,bigint,float8,float8,int,int,int,text)','tracker_answer(text,bigint,int)','tracker_file(text,bigint,jsonb)'] loop
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;
-- the old cash-only purchase is replaced by buy_listing
do $$ begin
  if exists (select 1 from pg_proc where proname = 'buy_aircraft') then
    execute 'revoke execute on function public.buy_aircraft(text,text) from authenticated';
  end if;
exception when others then null; end $$;
