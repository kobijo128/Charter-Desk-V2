-- 010: market upkeep fix, aircraft tagged by simulator, a "my simulator" setting, higher starting cash.
-- Safe to run more than once.

-- 1. The website's API refuses UPDATE statements without a WHERE clause. maintain() and admin_settings()
--    each had one on the single-row va_settings table, so every poll failed and the market stopped
--    expiring and refreshing jobs. Patch the live functions in place.
do $$
declare def text;
begin
    for def in select pg_get_functiondef(p.oid) from pg_proc p
                where p.proname in ('maintain', 'admin_settings') and p.pronamespace = 'public'::regnamespace loop
      def := replace(def, 'set last_spawn = now();', 'set last_spawn = now() where true;');
      def := replace(def, 'set last_maint = now();', 'set last_maint = now() where true;');
      def := regexp_replace(def, '(auto_accept = p_auto_accept)\s*;', '\1 where true;');
      def := replace(def, 'where true where true', 'where true');
      execute def;
    end loop;
end $$;

-- 2. Which simulators each type can be flown in (default aircraft, payware or freeware).
--    A type with no simulator is hidden from the shop and can't be bought; aircraft already owned keep flying.
alter table public.aircraft_types add column if not exists sims text[] not null default '{}';
alter table public.aircraft_types add column if not exists sim_note text;

update public.aircraft_types t set sims = v.sims::text[], sim_note = v.note
from (values
  -- pistons
  ('C172', '{MSFS,P3D,XP}', 'Default in all three'),
  ('BE36', '{MSFS,P3D,XP}', 'MSFS default G36; Carenado A36 for P3D and X-Plane'),
  ('SR22', '{MSFS,P3D,XP}', 'MSFS and X-Plane default; Eaglesoft SR22 for P3D'),
  ('PA34', '{MSFS,P3D,XP}', 'Carenado Seneca V'),
  ('PA46', '{MSFS,P3D,XP}', 'Carenado PA-46 Malibu family'),
  ('DA62', '{MSFS,XP}',     'MSFS default; Aerobask DA62 for X-Plane'),
  ('BE58', '{MSFS,P3D,XP}', 'Default Baron 58 in all three'),
  -- turboprops
  ('MU2',  '{MSFS,P3D,XP}', 'MSFS 2024 Aviator default; Carenado MU-2 for P3D and X-Plane'),
  ('C208', '{MSFS,P3D,XP}', 'MSFS default; Carenado for P3D; Thranda for X-Plane'),
  ('K100', '{MSFS,XP}',     'SimWorks Studios for MSFS; Thranda for X-Plane'),
  ('M600', '{}',            'No dependable simulator version'),
  ('BE9L', '{MSFS,P3D,XP}', 'MSFS 2024 default C90 GTx; Carenado C90 for P3D; X-Plane default C90B'),
  ('E1KG', '{}',            'No dependable simulator version'),
  ('TBM9', '{MSFS,P3D,XP}', 'MSFS default TBM 930; Carenado TBM 850 for P3D; Hot Start TBM 900 for X-Plane'),
  ('PC12', '{MSFS,P3D,XP}', 'MSFS default PC-12 NGX; Carenado for P3D; Thranda/Carenado for X-Plane'),
  ('P180', '{MSFS}',        'Payware P.180 for MSFS'),
  ('DHC6', '{MSFS,P3D,XP}', 'MSFS and X-Plane default; Aerosoft Twin Otter for P3D'),
  ('BE20', '{MSFS,P3D,XP}', 'Carenado King Air B200'),
  ('B350', '{MSFS,P3D,XP}', 'MSFS default 350i; P3D default King Air 350; AirfoilLabs King Air 350 for X-Plane'),
  -- light jets
  ('EA50', '{XP}',          'Aerobask Eclipse 550 for X-Plane'),
  ('SF50', '{MSFS,XP}',     'Default Vision Jet in MSFS and X-Plane'),
  ('C510', '{}',            'No dependable simulator version'),
  ('LJ35', '{MSFS,P3D}',    'Flysimware Learjet 35A'),
  ('C525', '{}',            'No dependable simulator version'),
  ('E50P', '{P3D}',         'Carenado Phenom 100 for P3D'),
  ('C550', '{P3D,XP}',      'Carenado Citation II / S550'),
  ('C25M', '{}',            'No dependable simulator version'),
  ('PRM1', '{P3D}',         'Carenado Premier IA'),
  ('C25A', '{P3D}',         'Carenado 525A CJ2'),
  ('HDJT', '{MSFS}',        'FlightFX HondaJet; freeware HJet'),
  ('BE40', '{}',            'No dependable simulator version'),
  ('C25B', '{MSFS}',        'Cockspur / LivToAir CJ3+'),
  ('LJ75', '{}',            'No dependable simulator version'),
  ('LJ45', '{}',            'No dependable simulator version'),
  ('E55P', '{XP}',          'Aerobask Phenom 300 for X-Plane (MSFS version in development)'),
  ('C25C', '{MSFS}',        'MSFS default Citation CJ4'),
  ('PC24', '{MSFS}',        'MSFS 2024 default (Premium Deluxe)'),
  -- midsize and super-midsize
  ('LJ60', '{}',            'No dependable simulator version'),
  ('C56X', '{P3D}',         'Carenado CE560XL'),
  ('G150', '{}',            'No dependable simulator version'),
  ('H25B', '{P3D}',         'Carenado Hawker 850XP'),
  ('E545', '{}',            'No dependable simulator version'),
  ('C68A', '{}',            'No dependable simulator version'),
  ('C680', '{}',            'No dependable simulator version (MSFS version in development)'),
  ('HA4T', '{}',            'No dependable simulator version'),
  ('E550', '{}',            'No dependable simulator version (MSFS version in development)'),
  ('C750', '{MSFS,P3D,XP}', 'FlightFX Citation X for MSFS; Eaglesoft for P3D; X-Plane default'),
  ('G280', '{}',            'No dependable simulator version'),
  ('CL35', '{}',            'No dependable simulator version (MSFS version in development)'),
  ('C700', '{MSFS}',        'MSFS default Citation Longitude'),
  ('F2TH', '{}',            'No dependable simulator version'),
  -- large and ultra-long-range
  ('E35L', '{}',            'No dependable simulator version'),
  ('CL60', '{MSFS,XP}',     'Hot Start Challenger 650 for X-Plane; freeware CL605/650 for MSFS'),
  ('GLF4', '{}',            'No dependable simulator version'),
  ('F900', '{}',            'No dependable simulator version'),
  ('FA6X', '{}',            'No dependable simulator version'),
  ('E190', '{MSFS,P3D,XP}', 'Fly the E190 airliner add-ons as the Lineage 1000 (feelThere, X-Crafts and others)'),
  ('GLEX', '{MSFS}',        'Freeware Global 6000 for MSFS'),
  ('FA7X', '{}',            'No dependable simulator version'),
  ('GA6C', '{}',            'No dependable simulator version'),
  ('GLF5', '{}',            'No dependable simulator version'),
  ('GLF6', '{MSFS}',        'Freeware G650 for MSFS 2020/2024 (simple systems)'),
  ('GL7T', '{}',            'No dependable simulator version (MSFS version in development)'),
  ('GA7C', '{MSFS}',        'Freeware G700 for MSFS 2020/2024 (simple systems)'),
  ('B737', '{MSFS,P3D,XP}', 'PMDG 737 BBJ for MSFS and P3D; Zibo / LevelUp 737 for X-Plane'),
  ('A319', '{MSFS,P3D,XP}', 'Fenix A319 for MSFS; FSLabs A319 for P3D; ToLiss A319 for X-Plane')
) v(code, sims, note)
where t.code = v.code;

-- starters: affordable types that every pilot can fly in at least one sim
update public.aircraft_types set starter = code in ('SR22','DA62','BE58','C208','TBM9','PC12','B350','SF50','HDJT','C25C','E50P','E55P') where true;

-- block buying a type no simulator has
create or replace function public.fleet_type_check()
returns trigger language plpgsql set search_path = public as $$
begin
  if not exists (select 1 from aircraft_types where code = new.type_code and cardinality(sims) > 0) then
    raise exception 'That aircraft isn''t available in any simulator yet.';
  end if;
  return new;
end $$;
drop trigger if exists fleet_type_check on public.fleet;
create trigger fleet_type_check before insert on public.fleet for each row execute function public.fleet_type_check();
revoke execute on function public.fleet_type_check() from public, anon, authenticated;

-- 3. "My simulator" setting (used to filter the shop)
create or replace function public.clean_prefs(p jsonb)
returns jsonb language sql immutable set search_path = public as $$
  select jsonb_build_object(
    'currency', case when p->>'currency' in ('USD','GBP','EUR') then p->>'currency' else 'USD' end,
    'weight',   case when p->>'weight' in ('lb','kg') then p->>'weight' else 'lb' end,
    'distance', case when p->>'distance' in ('nm','km','mi') then p->>'distance' else 'nm' end,
    'time',     case when p->>'time' in ('local','utc') then p->>'time' else 'local' end,
    'sim',      case when p->>'sim' in ('MSFS','P3D','XP') then p->>'sim' else 'any' end)
$$;
revoke execute on function public.clean_prefs(jsonb) from public, anon, authenticated;

-- 4. Starting cash $500,000 (was $60,000); pilots who started on less get the difference once
do $$
declare old numeric; pl record;
begin
  select start_cash into old from public.va_settings;
  if old < 500000 then
    update public.va_settings set start_cash = 500000 where true;
    for pl in select id from public.pilots loop
      update public.pilots set cash = cash + (500000 - old) where id = pl.id;
      perform public.add_ledger(pl.id, 'Starting capital top-up', (500000 - old)::bigint);
    end loop;
  end if;
end $$;
