-- 002: company setup choices — display settings, starter aircraft and custom registrations.
-- Safe to run more than once.

alter table public.aircraft_types add column if not exists starter boolean not null default false;
update public.aircraft_types set starter = code in ('SF50','PC12','B350','E55P');

alter table public.pilots add column if not exists prefs jsonb not null
  default '{"currency":"USD","weight":"lb","distance":"nm","time":"local"}';

-- registrations: optional country prefix and dash, e.g. G-ABCD, ZJ-ABC, D-IABC, N123AB, 2-ABCD
create or replace function public.valid_reg(p text)
returns boolean language sql immutable set search_path = public as $$
  select p ~ '^([A-Z0-9]{1,3}-[A-Z0-9]{2,5}|N[1-9][0-9]{0,4}[A-Z]{0,2})$'
$$;

create or replace function public.clean_prefs(p jsonb)
returns jsonb language sql immutable set search_path = public as $$
  select jsonb_build_object(
    'currency', case when p->>'currency' in ('USD','GBP','EUR') then p->>'currency' else 'USD' end,
    'weight',   case when p->>'weight' in ('lb','kg') then p->>'weight' else 'lb' end,
    'distance', case when p->>'distance' in ('nm','km','mi') then p->>'distance' else 'nm' end,
    'time',     case when p->>'time' in ('local','utc') then p->>'time' else 'local' end)
$$;

create or replace function public.claim_reg(p_reg text, p_except uuid)
returns text language plpgsql set search_path = public as $$
declare r text := upper(trim(coalesce(p_reg,'')));
begin
  if r = '' then return new_reg(); end if;
  if not valid_reg(r) then
    raise exception 'Registration % isn''t valid. Use a country prefix and dash like G-ABCD or ZJ-JEC, or a US N-number like N123AB.', r;
  end if;
  if exists (select 1 from fleet where reg = r and id is distinct from p_except) then
    raise exception 'Registration % is already in use in the VA.', r;
  end if;
  return r;
end $$;

drop function if exists public.ensure_pilot(text,text,text,text,text);
create or replace function public.ensure_pilot(p_callsign text, p_name text, p_company text, p_prefix text, p_home text,
  p_type text, p_reg text, p_prefs jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare u uuid := auth.uid(); s va_settings; first_pilot boolean; v_type text; v_reg text;
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
  first_pilot := not exists (select 1 from pilots);
  insert into pilots(id, callsign, name, company, prefix, home, cash, is_admin, next_call_at, prefs)
  values (u, p_callsign, trim(p_name), trim(p_company), p_prefix, upper(p_home), s.start_cash, first_pilot,
          now() + interval '45 seconds', clean_prefs(coalesce(p_prefs,'{}')));
  insert into pilot_keys(pilot_id, tracker_key) values (u, replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-',''));
  insert into fleet(pilot_id, type_code, reg, loc) values (u, v_type, v_reg, upper(p_home));
  perform add_ledger(u, format('%s founded at %s with %s %s', trim(p_company), upper(p_home),
          (select name from aircraft_types where code = v_type), v_reg), s.start_cash);
  return u;
end $$;

drop function if exists public.buy_aircraft(text);
create or replace function public.buy_aircraft(p_type text, p_reg text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare u uuid := me(); p pilots; ty aircraft_types; v_id uuid; v_reg text;
begin
  select * into p from pilots where id = u for update;
  select * into ty from aircraft_types where code = p_type;
  if ty.code is null then raise exception 'Unknown aircraft type.'; end if;
  if (select count(*) from fleet where pilot_id = u) >= p.slots then raise exception 'Buy another fleet slot first.'; end if;
  if p.cash < ty.price then raise exception 'Not enough money.'; end if;
  v_reg := claim_reg(p_reg, null);
  update pilots set cash = cash - ty.price where id = u;
  insert into fleet(pilot_id, type_code, reg, loc) values (u, ty.code, v_reg, p.home) returning fleet.id into v_id;
  perform add_ledger(u, format('%s %s added to the fleet', ty.name, v_reg), -ty.price);
  return v_id;
end $$;

create or replace function public.set_registration(p_ac uuid, p_reg text)
returns text language plpgsql security definer set search_path = public as $$
declare u uuid := me(); f fleet; v_reg text;
begin
  select * into f from fleet where id = p_ac and pilot_id = u for update;
  if f.id is null then raise exception 'Not your aircraft.'; end if;
  if exists (select 1 from trips where aircraft_id = p_ac and status = 'flying') then raise exception 'Wait until this aircraft has landed.'; end if;
  if trim(coalesce(p_reg,'')) = '' then raise exception 'Enter a registration.'; end if;
  v_reg := claim_reg(p_reg, p_ac);
  update fleet set reg = v_reg where id = p_ac;
  perform add_ledger(u, format('Re-registered %s as %s', f.reg, v_reg), 0);
  return v_reg;
end $$;

create or replace function public.update_prefs(p_prefs jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := me(); v jsonb;
begin
  update pilots set prefs = clean_prefs(prefs || coalesce(p_prefs,'{}')) where id = u returning prefs into v;
  return v;
end $$;

revoke execute on function public.valid_reg(text) from public, anon, authenticated;
revoke execute on function public.clean_prefs(jsonb) from public, anon, authenticated;
revoke execute on function public.claim_reg(text,uuid) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['ensure_pilot(text,text,text,text,text,text,text,jsonb)','buy_aircraft(text,text)',
                           'set_registration(uuid,text)','update_prefs(jsonb)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
