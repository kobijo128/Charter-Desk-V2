-- 004: aircraft catalogue with real prices, model years, financing and age-based charter rates.
-- Safe to run more than once. Existing aircraft become owned outright, model year 2015.

alter table public.aircraft_types add column if not exists category text not null default 'light';
alter table public.aircraft_types add column if not exists price_new bigint not null default 0;
alter table public.aircraft_types add column if not exists year_from int not null default 2000;
alter table public.aircraft_types add column if not exists year_to int not null default 2026;
alter table public.aircraft_types add column if not exists crew_req int not null default 2;
alter table public.aircraft_types alter column price type bigint;

insert into public.aircraft_types(code,name,cls,category,seats,range_nm,ktas,burn,rate,price_new,year_from,year_to,ceil,min_rwy_ft,crew_req,sim_match,starter,price) select v.*, v.price_new from (values
 ('C172','Cessna 172 Skyhawk','Piston single','piston',3,640,122,50,450,500000,1956,2026,140,1700,1,ARRAY['172','skyhawk'],false),
 ('SR22','Cirrus SR22T','Piston single','piston',3,1000,210,108,900,1150000,2001,2026,250,2000,1,ARRAY['sr22'],true),
 ('BE36','Beechcraft Bonanza G36','Piston single','piston',4,900,175,90,850,1050000,1984,2026,180,2000,1,ARRAY['bonanza','be36'],false),
 ('PA46','Piper M350','Piston single','piston',5,1100,213,110,1000,1300000,1984,2026,250,2500,1,ARRAY['m350','malibu','pa46','pa-46'],false),
 ('BE58','Beechcraft Baron G58','Piston twin','piston',5,1200,200,180,1300,1650000,1969,2026,200,2500,1,ARRAY['baron','be58'],true),
 ('PA34','Piper Seneca V','Piston twin','piston',5,800,190,160,1100,1150000,1972,2026,250,2500,1,ARRAY['seneca','pa34','pa-34'],false),
 ('DA62','Diamond DA62','Piston twin','piston',6,1200,180,100,1100,1450000,2015,2026,200,2500,1,ARRAY['da62','da-62'],true),
 ('M600','Piper M600/SLS','Turboprop single','turboprop',5,1650,274,260,1800,3500000,2016,2026,300,2700,1,ARRAY['m600'],true),
 ('TBM9','Daher TBM 960','Turboprop single','turboprop',5,1730,330,400,2400,5300000,2014,2026,310,2400,1,ARRAY['tbm'],true),
 ('E1KG','EPIC E1000 GX','Turboprop single','turboprop',5,1650,325,400,2300,4700000,2019,2026,340,2600,1,ARRAY['e1000','epic'],false),
 ('PC12','Pilatus PC-12 NGX','Turboprop single','turboprop',8,1800,290,420,3100,6400000,1994,2026,300,2600,1,ARRAY['pc-12','pc12'],true),
 ('C208','Cessna Grand Caravan EX','Turboprop single','turboprop',9,900,185,380,1700,2900000,1985,2026,250,2500,1,ARRAY['caravan','c208','208'],true),
 ('K100','Kodiak 100','Turboprop single','turboprop',9,1000,174,330,1600,3100000,2007,2026,250,1500,1,ARRAY['kodiak'],false),
 ('BE9L','Beechcraft King Air C90GTx','Turboprop twin','turboprop',6,1250,270,600,2600,4300000,1971,2021,300,2900,1,ARRAY['c90','king air 90'],false),
 ('BE20','Beechcraft King Air 260','Turboprop twin','turboprop',8,1720,310,650,3200,7600000,1974,2026,350,3300,1,ARRAY['king air 200','king air 250','king air 260','be20'],false),
 ('B350','Beechcraft King Air 360','Turboprop twin','turboprop',9,1800,312,700,3700,8600000,1990,2026,350,3300,1,ARRAY['king air 350','king air 360','b350'],true),
 ('P180','Piaggio P.180 Avanti EVO','Turboprop twin','turboprop',7,1720,400,600,3400,7400000,1990,2022,410,3200,2,ARRAY['avanti','p180','p.180'],false),
 ('MU2','Mitsubishi MU-2B','Turboprop twin','turboprop',7,1400,300,650,2400,2600000,1963,1986,300,2700,1,ARRAY['mu-2','mu2'],false),
 ('DHC6','DHC-6 Twin Otter','Turboprop twin','turboprop',19,800,170,600,3200,7500000,1965,2026,250,1500,2,ARRAY['twin otter','dhc-6','dhc6'],false),
 ('EA50','Eclipse 550','Very light jet','light',5,1125,375,450,2800,3100000,2006,2016,410,2800,1,ARRAY['eclipse'],false),
 ('SF50','Cirrus Vision Jet G2+','Very light jet','light',5,1200,311,450,2900,3400000,2016,2026,310,3300,1,ARRAY['vision','sf50'],true),
 ('C510','Cessna Citation Mustang','Very light jet','light',4,1150,340,600,3000,3400000,2006,2017,410,3200,1,ARRAY['mustang','c510'],false),
 ('E50P','Embraer Phenom 100EX','Very light jet','light',5,1180,405,650,3500,4800000,2008,2026,410,3200,1,ARRAY['phenom 100'],true),
 ('HDJT','HondaJet Elite II','Very light jet','light',6,1550,422,700,3800,7200000,2015,2026,430,3500,1,ARRAY['hondajet','hdjt'],false),
 ('C25M','Cessna Citation M2 Gen2','Light jet','light',6,1550,404,700,3600,6000000,2013,2026,410,3300,1,ARRAY['citation m2','c25m'],true),
 ('C525','Cessna CitationJet CJ1+','Light jet','light',5,1300,380,750,3200,4600000,1993,2011,410,3300,1,ARRAY['cj1','citationjet','c525'],false),
 ('C25A','Cessna Citation CJ2+','Light jet','light',6,1600,418,850,3900,7000000,2000,2016,450,3400,1,ARRAY['cj2','c25a'],false),
 ('C25B','Cessna Citation CJ3 Gen2','Light jet','light',7,2040,416,900,4300,9300000,2004,2026,450,3200,1,ARRAY['cj3','c25b'],false),
 ('C25C','Cessna Citation CJ4 Gen2','Light jet','light',8,2165,451,1050,5200,11500000,2010,2026,450,3500,1,ARRAY['cj4','c25c'],false),
 ('PRM1','Beechcraft Premier IA','Light jet','light',6,1200,450,1000,3500,6500000,2001,2013,410,3800,1,ARRAY['premier','prm1'],false),
 ('E55P','Embraer Phenom 300E','Light jet','light',7,2010,464,1000,4900,11400000,2009,2026,450,3600,1,ARRAY['phenom 300','phenom300'],true),
 ('PC24','Pilatus PC-24','Light jet','light',8,2000,440,1150,5400,11600000,2018,2026,450,2900,2,ARRAY['pc-24','pc24'],false),
 ('BE40','Hawker 400XP','Light jet','light',7,1450,450,1200,4100,7300000,1985,2010,450,4200,2,ARRAY['hawker 400','beechjet','be40'],false),
 ('C550','Cessna Citation Bravo','Light jet','light',7,1900,400,1200,3600,5500000,1978,2006,450,3600,2,ARRAY['citation ii','bravo','c550'],false),
 ('LJ35','Learjet 35A','Light jet','light',8,2000,440,1500,3800,4600000,1974,1993,450,5000,2,ARRAY['learjet 35','lj35'],false),
 ('LJ45','Learjet 45XR','Light jet','light',8,1900,464,1200,4800,11000000,1998,2012,510,4500,2,ARRAY['learjet 45','lj45'],false),
 ('LJ75','Learjet 75 Liberty','Light jet','light',8,2080,465,1200,5000,9900000,2013,2022,510,4400,2,ARRAY['learjet 75','lj75'],false),
 ('C56X','Cessna Citation XLS Gen2','Midsize jet','mid',9,2100,441,1450,5600,14500000,1996,2026,450,3600,2,ARRAY['xls','excel','c56x'],false),
 ('LJ60','Learjet 60XR','Midsize jet','mid',7,2400,465,1700,5800,13800000,1993,2012,510,5400,2,ARRAY['learjet 60','lj60'],false),
 ('H25B','Hawker 900XP','Midsize jet','mid',8,2550,447,1700,5800,15500000,1984,2013,410,5000,2,ARRAY['hawker 800','hawker 900','h25b'],false),
 ('G150','Gulfstream G150','Midsize jet','mid',8,2950,476,1700,6800,15000000,2006,2017,450,5000,2,ARRAY['g150'],false),
 ('C68A','Cessna Citation Latitude','Midsize jet','mid',9,2700,446,1400,6900,18000000,2015,2026,450,3600,2,ARRAY['latitude','c68a'],false),
 ('C680','Cessna Citation Sovereign+','Midsize jet','mid',9,3200,460,1600,7000,18500000,2004,2021,470,3700,2,ARRAY['sovereign','c680'],false),
 ('E545','Embraer Praetor 500','Midsize jet','mid',9,3340,466,1500,7600,17900000,2014,2026,450,4200,2,ARRAY['praetor 500','legacy 450','e545'],false),
 ('C750','Cessna Citation X+','Super-midsize jet','mid',12,3460,525,2500,10000,23500000,1996,2018,510,5200,2,ARRAY['citation x','c750'],false),
 ('CL35','Bombardier Challenger 350/3500','Super-midsize jet','mid',10,3400,470,1700,8600,27000000,2004,2026,450,4900,2,ARRAY['challenger 300','challenger 350','challenger 3500','cl30','cl35'],false),
 ('E550','Embraer Praetor 600','Super-midsize jet','mid',11,4000,466,1700,8300,23000000,2014,2026,450,4700,2,ARRAY['praetor 600','legacy 500','e550'],false),
 ('G280','Gulfstream G280','Super-midsize jet','mid',10,3600,482,1750,8800,25000000,2012,2026,450,4750,2,ARRAY['g280'],false),
 ('C700','Cessna Citation Longitude','Super-midsize jet','mid',12,3500,476,1700,9000,30000000,2019,2026,450,4900,2,ARRAY['longitude','c700'],false),
 ('HA4T','Hawker 4000','Super-midsize jet','mid',10,3200,470,1900,8000,22000000,2008,2013,450,5000,2,ARRAY['hawker 4000','ha4t'],false),
 ('F2TH','Dassault Falcon 2000LXS','Super-midsize jet','mid',10,4000,470,1900,9600,35000000,1995,2026,470,4800,2,ARRAY['falcon 2000','f2th'],false),
 ('CL60','Bombardier Challenger 650','Large jet','large',12,4000,459,2300,10500,33000000,1980,2022,410,5800,2,ARRAY['challenger 650','challenger 605','challenger 604','cl60'],false),
 ('E35L','Embraer Legacy 650E','Large jet','large',13,3900,459,2500,9500,31000000,2002,2020,410,5800,2,ARRAY['legacy 600','legacy 650','e35l'],false),
 ('F900','Dassault Falcon 900LX','Large jet','large',12,4750,459,2100,11500,44000000,1986,2026,510,5000,2,ARRAY['falcon 900','f900'],false),
 ('GLF4','Gulfstream G450','Large jet','large',14,4200,476,2600,11000,43000000,1987,2018,450,5600,2,ARRAY['g450','giv','g-iv','glf4'],false),
 ('FA6X','Dassault Falcon 6X','Large jet','large',16,5500,482,2500,14000,52000000,2022,2026,510,5500,2,ARRAY['falcon 6x','fa6x'],false),
 ('FA7X','Dassault Falcon 7X/8X','Large jet','large',14,6450,470,2400,13500,58000000,2007,2026,510,5700,2,ARRAY['falcon 7x','falcon 8x','fa7x','fa8x'],false),
 ('GA6C','Gulfstream G600','Large jet','large',16,6600,488,2800,14000,58000000,2019,2026,510,5500,2,ARRAY['g600','g500','ga6c','ga5c'],false),
 ('GLEX','Bombardier Global 6500','Ultra-long-range jet','large',16,6600,488,3000,15000,56000000,1999,2026,510,6500,2,ARRAY['global 6500','global 6000','global express','glex'],false),
 ('GLF5','Gulfstream G550','Ultra-long-range jet','large',16,6750,488,2900,13500,62000000,1997,2021,510,5900,2,ARRAY['g550','gv','glf5'],false),
 ('GLF6','Gulfstream G650ER','Ultra-long-range jet','large',16,7500,488,3000,16000,75000000,2012,2026,510,6300,2,ARRAY['g650','glf6'],false),
 ('GL7T','Bombardier Global 7500','Ultra-long-range jet','large',19,7700,488,3300,18500,78000000,2018,2026,510,5800,2,ARRAY['global 7500','global 8000','gl7t'],false),
 ('GA7C','Gulfstream G700','Ultra-long-range jet','large',19,7750,488,3300,18000,78000000,2023,2026,510,6250,2,ARRAY['g700','ga7c'],false),
 ('E190','Embraer Lineage 1000E','Bizliner','large',19,4600,470,4500,22000,53000000,2008,2020,410,6100,2,ARRAY['lineage','e190'],false),
 ('A319','Airbus ACJ319neo','Bizliner','large',19,6000,450,5500,25000,85000000,1999,2026,410,6500,2,ARRAY['acj','a319'],false),
 ('B737','Boeing Business Jet','Bizliner','large',19,6000,470,5500,26000,80000000,1999,2026,410,6500,2,ARRAY['bbj','737'],false)
) v(code,name,cls,category,seats,range_nm,ktas,burn,rate,price_new,year_from,year_to,ceil,min_rwy_ft,crew_req,sim_match,starter)
on conflict (code) do update set name=excluded.name, cls=excluded.cls, category=excluded.category, seats=excluded.seats,
  range_nm=excluded.range_nm, ktas=excluded.ktas, burn=excluded.burn, rate=excluded.rate, price_new=excluded.price_new,
  year_from=excluded.year_from, year_to=excluded.year_to, ceil=excluded.ceil, min_rwy_ft=excluded.min_rwy_ft,
  crew_req=excluded.crew_req, sim_match=excluded.sim_match, starter=excluded.starter, price=excluded.price;

alter table public.fleet add column if not exists year int;
alter table public.fleet add column if not exists loan_balance numeric not null default 0;
alter table public.fleet add column if not exists loan_payment numeric not null default 0;
alter table public.fleet add column if not exists loan_next_due timestamptz;
update public.fleet set year = 2015 where year is null;
alter table public.fleet alter column year set default 2015;
alter table public.fleet alter column year set not null;
alter table public.va_settings add column if not exists loan_apr numeric not null default 0.05;

-- age in years (never negative)
create or replace function public.ac_age(p_year int)
returns int language sql stable set search_path = public as $$
  select greatest(0, extract(year from now())::int - p_year)
$$;

-- market value: steep early depreciation that flattens out, floor at 25% of new
create or replace function public.ac_value(p_code text, p_year int)
returns bigint language sql stable set search_path = public as $$
  select round(price_new * (0.25 + 0.75 * exp(-ac_age(p_year) / 9.0)) / 1000) * 1000 from aircraft_types where code = p_code
$$;

-- older aircraft command lower charter rates (minimum 65% of a new one)
create or replace function public.rate_mul(p_year int)
returns numeric language sql stable set search_path = public as $$
  select greatest(0.65, 1 - 0.012 * ac_age(p_year))::numeric
$$;

-- monthly payment on an amortising loan
create or replace function public.loan_monthly(p_principal numeric, p_years int, p_apr numeric)
returns numeric language sql immutable set search_path = public as $$
  select case when p_principal <= 0 then 0
              when p_apr = 0 then round(p_principal / (p_years * 12))
              else round(p_principal * (p_apr/12) / (1 - power(1 + p_apr/12, -p_years * 12))) end
$$;

-- with ownership now paid through the purchase price or loan, running costs are fuel, maintenance and fees
create or replace function public.op_rate(p_rate int, p_upg jsonb)
returns numeric language sql immutable set search_path = public as $$
  select p_rate * 0.35 * (1 - 0.05 * coalesce((p_upg->>'crew')::int,0))
$$;

create or replace function public.take_loan_payment(p_ac uuid)
returns void language plpgsql set search_path = public as $$
declare f fleet; s va_settings; interest numeric; pay numeric; i int := 0; tname text;
begin
  select * into s from va_settings;
  select * into f from fleet where id = p_ac for update;
  select name into tname from aircraft_types where code = f.type_code;
  while f.loan_balance > 0 and f.loan_next_due <= now() and i < 12 loop
    interest := round(f.loan_balance * s.loan_apr / 12);
    pay := least(f.loan_payment, f.loan_balance + interest);
    f.loan_balance := greatest(0, f.loan_balance + interest - pay);
    f.loan_next_due := f.loan_next_due + interval '30 days';
    update pilots set cash = cash - pay where id = f.pilot_id;
    perform add_ledger(f.pilot_id, format('Finance payment, %s %s%s', tname, f.reg,
            case when f.loan_balance = 0 then ' (loan paid off)' else '' end), -pay::bigint);
    i := i + 1;
  end loop;
  update fleet set loan_balance = f.loan_balance, loan_next_due = case when f.loan_balance > 0 then f.loan_next_due end,
         loan_payment = case when f.loan_balance > 0 then f.loan_payment else 0 end
   where id = p_ac;
end $$;

-- founding a company: starter aircraft of the chosen model year, fully financed over 20 years
create or replace function public.found_company(p_callsign text, p_name text, p_company text, p_prefix text, p_home text,
  p_type text, p_year int, p_reg text, p_prefs jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); s va_settings; first_pilot boolean; ty aircraft_types; v_reg text; v_val bigint; v_home text;
begin
  if u is null then raise exception 'Sign in first.'; end if;
  if exists (select 1 from pilots where id = u) then return u; end if;
  select * into s from va_settings;
  p_callsign := upper(trim(p_callsign)); p_prefix := upper(trim(p_prefix)); v_home := upper(trim(p_home));
  if p_callsign !~ '^[A-Z0-9]{3,8}$' then raise exception 'Callsign must be 3–8 letters or numbers.'; end if;
  if p_prefix !~ '^[A-Z]{3}$' then raise exception 'Flight number prefix must be 3 letters.'; end if;
  if length(trim(coalesce(p_name,''))) < 2 then raise exception 'Enter your name.'; end if;
  if length(trim(coalesce(p_company,''))) < 2 then raise exception 'Enter a company name.'; end if;
  if exists (select 1 from pilots where callsign = p_callsign) then raise exception 'That callsign is taken.'; end if;
  if not exists (select 1 from airports where icao = v_home and active) then raise exception 'Choose a home base from the list.'; end if;
  select * into ty from aircraft_types where code = p_type and starter;
  if ty.code is null then raise exception 'Choose one of the starter aircraft.'; end if;
  if p_year is null or p_year < ty.year_from or p_year > least(ty.year_to, extract(year from now())::int) then
    raise exception 'The % was built from % to %.', ty.name, ty.year_from, ty.year_to; end if;
  if (select rwy_ft from airports where icao = v_home) < ty.min_rwy_ft then
    raise exception 'The runway at % is too short for the %.', v_home, ty.name; end if;
  v_reg := claim_reg(p_reg, null);
  v_val := ac_value(ty.code, p_year);
  first_pilot := not exists (select 1 from pilots);
  insert into pilots(id, callsign, name, company, prefix, home, cash, is_admin, next_call_at, prefs)
  values (u, p_callsign, trim(p_name), trim(p_company), p_prefix, v_home, s.start_cash, first_pilot,
          now() + interval '45 seconds', clean_prefs(coalesce(p_prefs,'{}')));
  insert into pilot_keys(pilot_id, tracker_key) values (u, replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-',''));
  insert into fleet(pilot_id, type_code, reg, loc, year, loan_balance, loan_payment, loan_next_due)
  values (u, ty.code, v_reg, v_home, p_year, v_val, loan_monthly(v_val, 20, s.loan_apr), now() + interval '30 days');
  perform add_ledger(u, format('%s founded at %s', trim(p_company), v_home), s.start_cash);
  perform add_ledger(u, format('%s %s %s, financed over 20 years', p_year, ty.name, v_reg), 0);
  return u;
end $$;

-- the old sign-up and purchase calls now ask for a page refresh
create or replace function public.ensure_pilot(p_callsign text, p_name text, p_company text, p_prefix text, p_home text,
  p_type text, p_reg text, p_prefs jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
begin raise exception 'Charter Desk FS has been updated. Refresh the page and try again.'; end $$;
create or replace function public.buy_aircraft(p_type text, p_reg text default null)
returns uuid language plpgsql security definer set search_path = public as $$
begin raise exception 'Charter Desk FS has been updated. Refresh the page and try again.'; end $$;

create or replace function public.purchase_aircraft(p_type text, p_year int, p_reg text, p_finance boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare u uuid := me(); p pilots; s va_settings; ty aircraft_types; v_id uuid; v_reg text; v_val bigint; dep bigint; loan bigint;
begin
  select * into s from va_settings;
  select * into p from pilots where id = u for update;
  select * into ty from aircraft_types where code = p_type;
  if ty.code is null then raise exception 'Unknown aircraft type.'; end if;
  if p_year is null or p_year < ty.year_from or p_year > least(ty.year_to, extract(year from now())::int) then
    raise exception 'The % was built from % to %.', ty.name, ty.year_from, ty.year_to; end if;
  if (select count(*) from fleet where pilot_id = u) >= p.slots then raise exception 'Buy another fleet slot first.'; end if;
  v_val := ac_value(ty.code, p_year);
  dep := case when p_finance then round(v_val * 0.15) else v_val end;
  loan := v_val - dep;
  if p.cash < dep then raise exception 'You need % for this. You have %.',
     '$' || to_char(dep,'FM999,999,999'), '$' || to_char(p.cash,'FM999,999,999'); end if;
  v_reg := claim_reg(p_reg, null);
  update pilots set cash = cash - dep where id = u;
  insert into fleet(pilot_id, type_code, reg, loc, year, loan_balance, loan_payment, loan_next_due)
  values (u, ty.code, v_reg, p.home, p_year, loan, loan_monthly(loan, 15, s.loan_apr), case when loan > 0 then now() + interval '30 days' end)
  returning fleet.id into v_id;
  perform add_ledger(u, format('Bought %s %s %s%s', p_year, ty.name, v_reg,
          case when loan > 0 then ' (15% deposit, rest financed over 15 years)' else '' end), -dep);
  return v_id;
end $$;

create or replace function public.repay_loan(p_ac uuid)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := me(); f fleet; p pilots;
begin
  select * into f from fleet where id = p_ac and pilot_id = u for update;
  if f.id is null then raise exception 'Not your aircraft.'; end if;
  if f.loan_balance <= 0 then raise exception 'This aircraft has no loan.'; end if;
  select * into p from pilots where id = u for update;
  if p.cash < f.loan_balance then raise exception 'You need $% to pay off this loan.', to_char(f.loan_balance,'FM999,999,999'); end if;
  update pilots set cash = cash - f.loan_balance where id = u;
  update fleet set loan_balance = 0, loan_payment = 0, loan_next_due = null where id = p_ac;
  perform add_ledger(u, format('Paid off the loan on %s', f.reg), -round(f.loan_balance)::bigint);
end $$;

-- selling: market value less a 8% broker fee, minus any loan still owed
create or replace function public.sell_aircraft(p_ac uuid)
returns void language plpgsql security definer set search_path = public as $$
declare u uuid := me(); f fleet; ty aircraft_types; v bigint;
begin
  select * into f from fleet where id = p_ac and pilot_id = u;
  if f.id is null then raise exception 'Not your aircraft.'; end if;
  if (select count(*) from fleet where pilot_id = u) <= 1 then raise exception 'You need at least one aircraft.'; end if;
  if exists (select 1 from trips where aircraft_id = p_ac and status in ('booked','flying','filed')) then raise exception 'Finish or cancel its trips first.'; end if;
  select * into ty from aircraft_types where code = f.type_code;
  v := round(ac_value(f.type_code, f.year) * 0.92 - f.loan_balance);
  delete from bids where aircraft_id = p_ac and status = 'pending';
  delete from fleet where id = p_ac;
  update pilots set cash = cash + v where id = u;
  perform add_ledger(u, format('Sold %s %s %s%s', f.year, ty.name, f.reg,
          case when f.loan_balance > 0 then ' and repaid its loan' else '' end), v);
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
     where f.pilot_id = u order by random() limit 1;
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

revoke execute on function public.ac_age(int) from public, anon, authenticated;
revoke execute on function public.rate_mul(int) from public, anon, authenticated;
revoke execute on function public.loan_monthly(numeric,int,numeric) from public, anon, authenticated;
revoke execute on function public.take_loan_payment(uuid) from public, anon, authenticated;
revoke execute on function public.ac_value(text,int) from public, anon;
grant execute on function public.ac_value(text,int) to authenticated;
revoke execute on function public.found_company(text,text,text,text,text,text,int,text,jsonb) from public, anon;
grant execute on function public.found_company(text,text,text,text,text,text,int,text,jsonb) to authenticated;
revoke execute on function public.purchase_aircraft(text,int,text,boolean) from public, anon;
grant execute on function public.purchase_aircraft(text,int,text,boolean) to authenticated;
revoke execute on function public.repay_loan(uuid) from public, anon;
grant execute on function public.repay_loan(uuid) to authenticated;
