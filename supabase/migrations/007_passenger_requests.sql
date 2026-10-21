-- 007: passenger requests during the flight. They pop up in the tracker and on the website while you're
-- airborne with passengers; answer within 5 minutes or take a small reputation knock.
-- Safe to run more than once.

create table if not exists public.pax_requests (
  id          bigint generated always as identity primary key,
  trip_id     bigint not null references public.trips on delete cascade,
  pilot_id    uuid not null references public.pilots on delete cascade,
  seat        text not null,
  who         text not null,
  message     text not null,
  choices     jsonb not null,           -- [{"label": "...", "good": true}, ...]
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  answered_at timestamptz,
  answer      text,
  status      text not null default 'open' check (status in ('open','answered','missed'))
);
create index if not exists pax_requests_open on public.pax_requests(status, expires_at);
alter table public.pax_requests enable row level security;
revoke insert, update, delete, truncate on public.pax_requests from anon, authenticated;
drop policy if exists read_own on public.pax_requests;
create policy read_own on public.pax_requests for select to authenticated using (pilot_id = auth.uid());
alter table public.trips add column if not exists pax_next_at timestamptz;

-- maybe raise a new request: roughly every 20 to 40 minutes in flight, never two at once
create or replace function public.maybe_pax_request(p_trip bigint, p_phase text, p_alt int)
returns void language plpgsql set search_path = public as $$
declare t trips; b jsonb; pick int; seat text; who text; msg text; ch jsonb; diet text;
  names text[] := array['Mr Hale','Mrs Moreau','the principal','Ms Laine','Dr Varga','the bride','Mr Okafor','the tour manager','a young passenger','Ms Ashby'];
begin
  select * into t from trips where id = p_trip;
  if t.id is null or t.kind <> 'charter' or t.pax < 1 or t.status <> 'flying' then return; end if;
  if p_phase not in ('Climb','Cruise','Descent') or coalesce(p_alt, 0) < 3000 then return; end if;
  if exists (select 1 from pax_requests where trip_id = t.id and status = 'open') then return; end if;
  if t.pax_next_at is null then
    update trips set pax_next_at = now() + (8 + random() * 15) * interval '1 minute' where id = t.id; return;
  end if;
  if t.pax_next_at > now() then return; end if;
  b := t.brief;
  seat := (array['1A','1C','2A','2C','3A','3C','4A','Divan'])[1 + floor(random()*8)::int];
  who := names[1 + floor(random()*10)::int];
  diet := b->'dietary'->>0;
  pick := floor(random() * 10)::int;
  if p_phase = 'Descent' then pick := 10 + floor(random() * 3)::int; end if;
  case pick
    when 0 then msg := 'It''s getting a bit chilly back here. Could you warm the cabin up?';
      ch := '[{"label":"Turn the cabin temperature up","good":true},{"label":"Offer blankets instead","good":true},{"label":"Ignore it","good":false}]';
    when 1 then msg := 'How long until we land?';
      ch := '[{"label":"Give them the ETA from the FMS","good":true},{"label":"\"Not long now\"","good":false}]';
    when 2 then msg := 'Could we have the Wi-Fi password? There''s a call in ten minutes.';
      ch := '[{"label":"Share the password","good":true},{"label":"Explain there''s no Wi-Fi on this aircraft","good":true}]';
    when 3 then msg := 'Is there any more champagne?';
      ch := '[{"label":"Open another bottle","good":true},{"label":"Offer something else from the bar","good":true},{"label":"Say it''s all gone","good":false}]';
    when 4 then msg := 'That bump made us nervous. Is everything all right?';
      ch := '[{"label":"Seat belt sign on and a calm announcement","good":true},{"label":"Say nothing","good":false}]';
    when 5 then msg := 'Can we see anything interesting out of the window?';
      ch := '[{"label":"Point out the landmarks below","good":true},{"label":"\"Just clouds, sorry\"","good":false}]';
    when 6 then msg := coalesce('Just checking the meals are suitable: ' || diet || '.', 'Could we have something to eat a little earlier than planned?');
      ch := '[{"label":"Confirm and serve it now","good":true},{"label":"Promise to check after landing","good":false}]';
    when 7 then msg := 'The meeting has moved forward. Can we get there any faster?';
      ch := '[{"label":"Ask ATC for a direct routing","good":true},{"label":"Increase cruise speed","good":true},{"label":"Explain we''re already on time","good":true}]';
    when 8 then msg := 'Could you dim the cabin lights? Someone would like to sleep.';
      ch := '[{"label":"Dim the lights and close the blinds","good":true},{"label":"Leave them","good":false}]';
    when 9 then msg := 'Would it be possible to say hello to the captain?';
      ch := '[{"label":"Invite them up for a chat after landing","good":true},{"label":"Make a friendly PA instead","good":true}]';
    when 10 then msg := 'Will there be a car waiting for us when we land?';
      ch := '[{"label":"Confirm the car with the FBO","good":true},{"label":"\"I''m sure it''ll be fine\"","good":false}]';
    when 11 then msg := 'My ears are hurting on the way down.';
      ch := '[{"label":"Ease the descent rate and offer sweets","good":true},{"label":"Tell them it''ll pass","good":false}]';
    else msg := 'Can we keep the bags on board until we''re inside the FBO?';
      ch := '[{"label":"Arrange it with ground handling","good":true},{"label":"Explain the bags go first","good":true}]';
  end case;
  insert into pax_requests(trip_id, pilot_id, seat, who, message, choices, expires_at)
  values (t.id, t.pilot_id, seat, who, msg, ch, now() + interval '5 minutes');
  update trips set pax_next_at = now() + (18 + random() * 22) * interval '1 minute' where id = t.id;
end $$;

-- answers from the website or the tracker
create or replace function public.answer_pax(p_pilot uuid, p_req bigint, p_choice int)
returns jsonb language plpgsql set search_path = public as $$
declare r pax_requests; c jsonb; good boolean;
begin
  select * into r from pax_requests where id = p_req and pilot_id = p_pilot for update;
  if r.id is null then raise exception 'Request not found.'; end if;
  if r.status <> 'open' or r.expires_at < now() then raise exception 'Too late: the moment has passed.'; end if;
  c := r.choices -> p_choice;
  if c is null then raise exception 'Choose one of the options.'; end if;
  good := coalesce((c->>'good')::boolean, true);
  update pax_requests set status = 'answered', answered_at = now(), answer = c->>'label' where id = r.id;
  update pilots set rep = least(100, greatest(0, rep + case when good then 0.2 else -0.2 end)) where id = p_pilot;
  return jsonb_build_object('good', good, 'reply', case when good then (array['Thank you, that''s perfect.','Lovely, thanks!','Much appreciated.','Great, thank you.'])[1 + floor(random()*4)::int]
                                                     else (array['Oh. Right.','Hmm, okay then.','That''s a shame.'])[1 + floor(random()*3)::int] end);
end $$;

create or replace function public.answer_request(p_req bigint, p_choice int)
returns jsonb language plpgsql security definer set search_path = public as $$
begin return answer_pax(me(), p_req, p_choice); end $$;

create or replace function public.tracker_answer(p_key text, p_req bigint, p_choice int)
returns jsonb language plpgsql security definer set search_path = public as $$
begin return answer_pax(tracker_pilot(p_key), p_req, p_choice); end $$;

-- unanswered requests: a small knock to reputation
create or replace function public.expire_pax()
returns void language plpgsql set search_path = public as $$
declare r record;
begin
  for r in update pax_requests set status = 'missed' where status = 'open' and expires_at < now() returning pilot_id loop
    update pilots set rep = greatest(0, rep - 0.3) where id = r.pilot_id;
  end loop;
end $$;

-- position reports now also return any passenger request waiting for an answer
create or replace function public.tracker_ping(p_key text, p_trip bigint, p_lat float8, p_lon float8, p_alt int, p_gs int, p_hdg int, p_phase text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := tracker_pilot(p_key); r pax_requests;
begin
  insert into positions(pilot_id, trip_id, lat, lon, alt, gs, hdg, phase, updated_at)
  values (u, p_trip, p_lat, p_lon, p_alt, p_gs, p_hdg, left(p_phase, 20), now())
  on conflict (pilot_id) do update set trip_id = excluded.trip_id, lat = excluded.lat, lon = excluded.lon, alt = excluded.alt,
    gs = excluded.gs, hdg = excluded.hdg, phase = excluded.phase, updated_at = now();
  update pilots set last_seen = now() where id = u;
  perform expire_pax();
  if exists (select 1 from trips where id = p_trip and pilot_id = u) then perform maybe_pax_request(p_trip, p_phase, p_alt); end if;
  select * into r from pax_requests where pilot_id = u and trip_id = p_trip and status = 'open' order by id desc limit 1;
  if r.id is null then return jsonb_build_object('request', null); end if;
  return jsonb_build_object('request', jsonb_build_object('id', r.id, 'seat', r.seat, 'who', r.who, 'message', r.message,
    'choices', (select jsonb_agg(x->'label') from jsonb_array_elements(r.choices) x), 'expires_at', r.expires_at));
end $$;

-- older trackers keep working and still raise requests
create or replace function public.tracker_position(p_key text, p_trip bigint, p_lat float8, p_lon float8, p_alt int, p_gs int, p_hdg int, p_phase text)
returns void language plpgsql security definer set search_path = public as $$
begin perform tracker_ping(p_key, p_trip, p_lat, p_lon, p_alt, p_gs, p_hdg, p_phase); end $$;


create or replace function public.poll()
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid := me(); p pilots; c record; ac record; r route_pick; fair numeric; ev jsonb; rm numeric;
begin
  update pilots set last_seen = now() where id = u returning * into p;
  perform maintain();
  perform expire_pax();

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
  return jsonb_build_object('events', ev, 'now', now(),
    'pax', (select jsonb_agg(jsonb_build_object('id', pq.id, 'trip_id', pq.trip_id, 'seat', pq.seat, 'who', pq.who, 'message', pq.message,
              'choices', (select jsonb_agg(x->'label') from jsonb_array_elements(pq.choices) x), 'expires_at', pq.expires_at) order by pq.id)
            from pax_requests pq where pq.pilot_id = u and pq.status = 'open'));
end $$;

create or replace function public.settle(p_pirep bigint)
returns void language plpgsql set search_path = public as $$
declare
  pr public.pireps; tr public.trips; p public.pilots; ty public.aircraft_types;
  op numeric; v_cost numeric; v_rev int; v_tip int := 0; v_rep numeric := 0; est numeric; note text := ''; v_fine int := 0; v_ans int; v_miss int;
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
  update public.pilots set cash = cash + v_rev + v_tip - round(v_cost), rep = least(100, greatest(0, rep + v_rep)) where id = p.id;
  update public.fleet set hours = hours + pr.block_h where id = tr.aircraft_id;
  update public.trips set status = 'accepted' where id = tr.id;
  perform public.add_ledger(p.id, format('%s %s–%s: revenue $%s, operating cost $%s%s', tr.flt, tr.from_icao, tr.to_icao,
          to_char(v_rev + v_tip,'FM999,999,990'), to_char(round(v_cost - v_fine),'FM999,999,990'),
          case when v_fine > 0 then format(', customs fine $%s', to_char(v_fine,'FM999,999')) else '' end), (v_rev + v_tip - round(v_cost))::bigint);
end $$;

revoke execute on function public.maybe_pax_request(bigint,text,int) from public, anon, authenticated;
revoke execute on function public.answer_pax(uuid,bigint,int) from public, anon, authenticated;
revoke execute on function public.expire_pax() from public, anon, authenticated;
revoke execute on function public.settle(bigint) from public, anon, authenticated;
revoke execute on function public.answer_request(bigint,int) from public, anon;
grant execute on function public.answer_request(bigint,int) to authenticated;
grant execute on function public.tracker_ping(text,bigint,float8,float8,int,int,int,text) to anon, authenticated;
grant execute on function public.tracker_answer(text,bigint,int) to anon, authenticated;
