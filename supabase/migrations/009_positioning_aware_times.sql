-- 009: "go now" jobs allow for positioning. When a job starts away from the aircraft it was generated
-- for, the departure leaves time to fly there first. Safe to run more than once.

-- departure with a positioning allowance (p_pos_h hours to get the aircraft to the departure airport)
create or replace function public.pick_dep2(p_lon float8, p_cat text, p_pos_h numeric)
returns timestamptz language plpgsql volatile set search_path = public as $$
declare r float8 := random(); lead numeric; dep timestamptz; off int; lh numeric; pos numeric := coalesce(p_pos_h, 0);
begin
  lead := case when p_cat = 'urgent' or r < 0.4 then pos + 0.85 + random() * 1.0
               when r < 0.75 then greatest(3 + random() * 11, pos + 2)
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
    -- positioning allowance: a typical jet at 420 kt plus 30 minutes to turn round
    r.dep_at := pick_dep2(f.lon, c.cat, case when p_near is null or f.icao = p_near then 0
                  else (select nm(n.lat,n.lon,f.lat,f.lon) / 420.0 + 0.5 from airports n where n.icao = p_near) end);
    return r;
  end loop;
  return null;
end $$;

revoke execute on function public.pick_dep2(float8,text,numeric) from public, anon, authenticated;
revoke execute on function public.gen_route(text,int,int,int) from public, anon, authenticated;
