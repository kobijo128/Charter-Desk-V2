/* Charter Desk VA — web app. Talks to Supabase; all game rules run in the database. */
'use strict';

const CFG = window.CHARTER_CONFIG || {};
const $ = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const CURRENCIES = { USD: { sym: '$', rate: 1, name: 'US dollar' }, GBP: { sym: '£', rate: 0.79, name: 'Pound sterling' }, EUR: { sym: '€', rate: 0.92, name: 'Euro' } };
const PREF_DEFAULTS = { currency: 'USD', weight: 'lb', distance: 'nm', time: 'local', sim: 'any' };
const SIM_NAMES = { MSFS: 'MSFS', P3D: 'P3D', XP: 'X-Plane' };
const flyable = t => (t.sims || []).length > 0;
const forMe = t => flyable(t) && (pref('sim') === 'any' || t.sims.includes(pref('sim')));
const simBadges = t => `<span class="sims">${(t.sims || []).map(x => `<i class="${pref('sim') === x ? 'mine' : ''}">${SIM_NAMES[x]}</i>`).join('')}</span>`;
let PREFS_OVERRIDE = null; // used on the setup screen before the pilot exists
const pref = k => (PREFS_OVERRIDE || D.me?.prefs || {})[k] || PREF_DEFAULTS[k];
const cur = () => CURRENCIES[pref('currency')] || CURRENCIES.USD;
const toLocal = usd => (usd || 0) * cur().rate;          // game money is stored in US dollars
const toUsd = local => (local || 0) / cur().rate;
const money = n => { const v = Math.round(toLocal(n)); return (v < 0 ? '−' : '') + cur().sym + Math.abs(v).toLocaleString('en-US') };
const kmoney = n => { const v = toLocal(n), a = Math.abs(v), sg = v < 0 ? '−' : ''; return a >= 1e6 ? sg + cur().sym + (a / 1e6).toFixed(2) + 'M' : a >= 1e4 ? sg + cur().sym + (a / 1e3).toFixed(1) + 'k' : money(n) };
const DIST = { nm: 1, km: 1.852, mi: 1.15078 };
const dist = nmv => nmv == null ? '—' : `${Math.round(nmv * DIST[pref('distance')]).toLocaleString('en-US')} ${pref('distance')}`;
const wt = lb => lb == null ? '—' : `${Math.round(pref('weight') === 'kg' ? lb * 0.453592 : lb).toLocaleString('en-US')} ${pref('weight')}`;
const wtRate = lbh => `${Math.round(pref('weight') === 'kg' ? lbh * 0.453592 : lbh).toLocaleString('en-US')} ${pref('weight')}/h`;
const REG_RE = /^([A-Z0-9]{1,3}-[A-Z0-9]{2,5}|N[1-9][0-9]{0,4}[A-Z]{0,2})$/;
const COUNTRY_REG = { JE: 'ZJ-', GG: '2-', GB: 'G-', IE: 'EI-', FR: 'F-', DE: 'D-', CH: 'HB-', AT: 'OE-', NL: 'PH-', BE: 'OO-', ES: 'EC-', PT: 'CS-', IT: 'I-', GR: 'SX-', TR: 'TC-', NO: 'LN-', SE: 'SE-', DK: 'OY-', IS: 'TF-', AE: 'A6-', MA: 'CN-', US: 'N' };
const EURO = ['IE', 'FR', 'DE', 'AT', 'NL', 'BE', 'ES', 'PT', 'IT', 'GR'];
function suggestReg(country, prefix, taken) {
  const p = COUNTRY_REG[country] || 'G-', L = 'ABCDEFGHJKLMNPRSTUVWXYZ', base = (prefix || '').toUpperCase().replace(/[^A-Z]/g, '');
  const tail = p.length >= 3 ? 3 : 4, rl = n => Array.from({ length: n }, () => L[Math.floor(Math.random() * L.length)]).join('');
  for (let i = 0; i < 60; i++) {
    const r = p === 'N' ? 'N' + (100 + Math.floor(Math.random() * 900)) + (base.slice(0, 2) || rl(2))
      : p + ((i === 0 ? base : base.slice(0, tail - 1) + rl(1)) + rl(tail)).slice(0, tail);
    if (REG_RE.test(r) && !(taken || []).includes(r)) return r;
  }
  return '';
}
const pad = n => String(n).padStart(2, '0');
const hm = h => { const m = Math.round((h || 0) * 60); return `${Math.floor(m / 60)}:${pad(m % 60)}` };
const rand = (a, b) => a + Math.random() * (b - a);
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const R = Math.PI / 180;
const BIDWAIT = [30, 22, 15, 10];
const UPG = {
  sales: { name: 'Sales desk', cost: [30000, 70000, 140000], desc: 'Clients phone you directly more often, with private offers above market rate.' },
  broker: { name: 'Broker relations', cost: [25000, 60000, 120000], desc: 'Brokers favour you: a 3% edge on every quote per level.' },
  fast: { name: 'Priority broker line', cost: [20000, 50000, 100000], desc: 'Get decisions faster on requests you open: 30s, then 22s, 15s and 10s.' },
  crew: { name: 'Crew training', cost: [40000, 90000, 180000], desc: 'Cuts operating cost per flight hour by 5% per level.' },
  pr: { name: 'PR and brand', cost: [35000, 80000, 160000], desc: 'Reputation gains count 25% more per level. Reputation wins close bids.' },
  empty: { name: 'Empty-leg sales', cost: [50000, 120000], desc: 'Sell seats on positioning legs. Each level recovers 25% of positioning cost.' },
};
const CALL_LINES = [
  (c, A, B) => `Hi, I've been given your number by a friend. I need ${c.pax} of us from ${A.city} to ${B.city}. Can you do it?`,
  (c, A, B) => `It's short notice, I know. ${B.city} for ${c.pax}, leaving from ${A.city}. Your name came up as the operator to call.`,
  (c, A, B) => `My assistant usually books this, but she's away. We need ${c.from_icao} to ${c.to_icao}, ${c.pax} passengers. I'll pay well for reliability.`,
  (c, A, B) => `We flew with you before and it went smoothly. Same again please: ${A.city} to ${B.city}, ${c.pax} on board.`,
];

if (!window.supabase || !CFG.supabaseUrl || CFG.supabaseUrl.includes('YOUR-PROJECT')) {
  $('#main').innerHTML = `<div class="authwrap"><div class="authcard"><div class="authlogo"><svg width="30" height="30" viewBox="0 0 34 34" aria-hidden="true"><path d="M6 28 L14 6 L20 6 L16 20 L28 20 L28 28 Z" fill="#B88A3A"></path></svg><b>Charter Desk <span>FS</span></b></div><h1>Almost there</h1><p>Open <b class="mono">config.js</b> and fill in your Supabase project URL and anon key, then reload this page.</p></div></div>`;
  throw new Error('Charter Desk is not configured');
}
const sb = window.supabase.createClient(CFG.supabaseUrl, CFG.supabaseAnonKey);

/* ---------- state ---------- */
const D = { settings: {}, airports: {}, apList: [], types: {}, clients: [], me: null, fleet: [], requests: [], bids: [], calls: [], trips: [], myPireps: [] };
const UI = { tab: 'market', band: 'any', showAll: false, nearOnly: true, sort: 'closing', acId: null, sound: false };
const NEAR_NM = 800;
const TABS = [['market', 'Market'], ['trips', 'Trips'], ['hangar', 'Hangar'], ['crew', 'Crew'], ['shop', 'Shop'], ['live', 'Live map'], ['reports', 'Reports'], ['pilots', 'Pilots'], ['ledger', 'Ledger'], ['profile', 'Profile'], ['staff', 'Staff']];
try { UI.sound = localStorage.getItem('cd-ringer') === '1'; } catch (e) { }
let pollTimer = null, liveMap = null, liveLayer = null;

async function rpc(fn, args) {
  const { data, error } = await sb.rpc(fn, args || {});
  if (error) throw new Error(error.message);
  return data;
}
async function q(promise) {
  const { data, error } = await promise;
  if (error) throw new Error(error.message);
  return data;
}

/* ---------- theme ---------- */
const THEMES = ['system', 'light', 'dark'];
let THEME = 'system'; try { THEME = localStorage.getItem('cd-theme') || 'system' } catch (e) { }
function applyTheme() { if (THEME === 'system') delete document.documentElement.dataset.theme; else document.documentElement.dataset.theme = THEME }
applyTheme();
const isDark = () => THEME === 'dark' || (THEME === 'system' && window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches);
const cssv = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
const tileUrl = () => `https://{s}.basemaps.cartocdn.com/${isDark() ? 'dark_all' : 'rastertiles/voyager'}/{z}/{x}/{y}{r}.png`;
try { matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { if (THEME === 'system' && D.me) { renderHeader(); renderTab() } }) } catch (e) { }

/* ---------- geometry and planning ---------- */
function nmLL(la1, lo1, la2, lo2) { const a = Math.sin((la2 - la1) * R / 2) ** 2 + Math.cos(la1 * R) * Math.cos(la2 * R) * Math.sin((lo2 - lo1) * R / 2) ** 2; return Math.round(2 * 3440.065 * Math.asin(Math.min(1, Math.sqrt(a)))) }
function nm(a, b) { const A = D.airports[a], B = D.airports[b]; return A && B ? nmLL(A.lat, A.lon, B.lat, B.lon) : 0 }
function brg(a, b) { const A = D.airports[a], B = D.airports[b]; const y = Math.sin((B.lon - A.lon) * R) * Math.cos(B.lat * R); const x = Math.cos(A.lat * R) * Math.sin(B.lat * R) - Math.sin(A.lat * R) * Math.cos(B.lat * R) * Math.cos((B.lon - A.lon) * R); return (Math.atan2(y, x) / R + 360) % 360 }
const blockH = (t, d) => d <= 0 ? 0 : d / t.ktas + 0.33;
const upg = k => (D.me?.upgrades || {})[k] || 0;
const opRate = t => t.rate * 0.35 * (1 - 0.05 * upg('crew'));
const thisYear = () => new Date().getUTCFullYear();
const acAge = y => Math.max(0, thisYear() - y);
const acValue = (t, y) => Math.round(t.price_new * (0.25 + 0.75 * Math.exp(-acAge(y) / 9)) / 1000) * 1000;
const rmul = y => Math.max(0.65, 1 - 0.012 * acAge(y));
const acRate = ac => typeOf(ac).rate * rmul(ac.year);
const loanMonthly = (p, years) => { const r = (D.settings.loan_apr ?? 0.05) / 12; return p <= 0 ? 0 : r === 0 ? Math.round(p / (years * 12)) : Math.round(p * r / (1 - Math.pow(1 + r, -years * 12))) };
const modelYears = t => { const out = []; for (let y = Math.min(t.year_to, thisYear()); y >= Math.max(t.year_from, thisYear() - 40); y--) out.push(y); return out };
const mny = n => { const v = toLocal(n); return v >= 1e6 ? (v / 1e6).toFixed(v >= 1e7 ? 1 : 2).replace(/\.0$/, '') + 'M' : null };
const bigMoney = n => { const m = mny(n); return m ? cur().sym + m : kmoney(n) };
const repoFactor = () => 1 - 0.25 * upg('empty');
const rwy = icao => D.airports[icao]?.rwy_ft ?? 6000;
const rwyOk = (t, r) => rwy(r.from_icao) >= t.min_rwy_ft && rwy(r.to_icao) >= t.min_rwy_ft;
const fits = (t, r) => r.dist <= t.range_nm * 0.92 && r.pax <= t.seats && rwyOk(t, r);
const whyNot = (t, r) => r.pax > t.seats ? `${r.pax} pax, ${t.seats} seats` : r.dist > t.range_nm * 0.92 ? 'Beyond range' : !rwyOk(t, r) ? 'Runway too short' : '';
const ft = v => v == null ? '—' : `${Math.round(v).toLocaleString('en-US')} ft`;
const acById = id => D.fleet.find(a => a.id === id);
const typeOf = ac => D.types[ac.type_code];
const queue = ac => D.trips.filter(t => t.aircraft_id === ac.id && (t.status === 'booked' || t.status === 'flying')).sort((a, b) => a.seq - b.seq);
const futureLoc = ac => { const qd = queue(ac); return qd.length ? qd[qd.length - 1].to_icao : ac.loc };
const pilotFleet = () => D.fleet.filter(a => a.ops !== 'crew');
const active = () => { const a = acById(UI.acId); return a && a.ops !== 'crew' ? a : (pilotFleet()[0] || null) };
const anyAc = () => acById(UI.acId) || D.fleet[0];
function quote(ac, r, from) {
  const t = typeOf(ac), loc = from || futureLoc(ac);
  const repoNm = loc === r.from_icao ? 0 : nm(loc, r.from_icao);
  const bh = blockH(t, r.dist), rh = blockH(t, repoNm);
  const rate = t.rate * rmul(ac.year);
  return { loc, repoNm, bh, rh, basis: rate * bh, guide: Math.round(rate * bh / 100) * 100, repoCost: Math.round(opRate(t) * rh * repoFactor()), fair: Math.round((rate * bh + 0.55 * rate * rh) / 100) * 100, opc: Math.round(opRate(t) * (bh + rh * repoFactor())) };
}
const TURN_H = 0.5;
// when the aircraft is free: now, or after the last booked leg plus a turnaround
function freeAt(ac) {
  const qd = queue(ac); if (!qd.length) return Date.now();
  const l = qd[qd.length - 1], end = ts(l.dep_at) + (l.kind === 'ferry' ? 0 : blockH(typeOf(ac), l.dist)) * 36e5;
  return Math.max(Date.now(), end + TURN_H * 36e5);
}
// when you must leave to make the departure, counting any positioning leg
function timing(ac, r, qd) {
  const free = freeAt(ac), leave = ts(r.dep_at) - (qd.repoNm ? (qd.rh + TURN_H) * 36e5 : 0);
  return { free, leave, busy: free > Date.now() + 6e4, late: leave < free - 5 * 6e4, soon: leave - free < 2.5 * 36e5 };
}
function winOdds(r, ac, amount) {
  const qd = quote(ac, r), t = typeOf(ac), cl = D.clients.find(c => c.name === r.client) || { bud_lo: 0.95, bud_hi: 1.2 };
  const rep = D.me.rep, repF = 1 + (rep - 50) / 400, edge = 1 - 0.03 * upg('broker');
  let w = 0; const N = 500;
  for (let i = 0; i < N; i++) {
    const budget = qd.basis * rand(+cl.bud_lo, +cl.bud_hi) * (1 + (rep - 50) / 600) + 0.55 * t.rate * qd.rh * 0.6;
    if (amount > budget) continue;
    let m = Infinity; for (let c = 0; c < r.npc; c++) m = Math.min(m, 0.92 + Math.random() * 0.30 + Math.random() * 0.22);
    if (amount / qd.basis / repF * edge < m) w++;
  }
  return w / N;
}
function cruiseFL(t, from, to, d) {
  let fl = d < 150 ? 220 : d < 300 ? 300 : d < 600 ? 360 : d < 1500 ? 400 : 430; fl = Math.min(fl, t.ceil); const east = brg(from, to) < 180;
  if (fl > 410 && t.ceil >= 450) return east ? 450 : 430;
  fl = Math.min(fl, 410); let f = Math.floor(fl / 10); if (east && f % 2 === 0) f--; if (!east && f % 2 === 1) f--; return f * 10;
}
function alternate(icao) { let best = null, bd = 1e9; for (const a of D.apList) { if (a.icao === icao) continue; const d = nm(icao, a.icao); if (d < bd) { bd = d; best = a.icao } } return [best, bd] }
function prevLoc(trip) { const ac = acById(trip.aircraft_id); const qd = queue(ac); const i = qd.findIndex(t => t.id === trip.id); return i <= 0 ? ac.loc : qd[i - 1].to_icao }
function plan(trip) {
  const ac = acById(trip.aircraft_id), t = typeOf(ac), r = { ...trip };
  const from = prevLoc(trip), qd = quote(ac, r, trip.from_icao);
  const [alt, altd] = alternate(trip.to_icao);
  const tripFuel = Math.round(t.burn * (trip.dist / t.ktas) + t.burn * 0.25), altFuel = Math.round(t.burn * (altd / t.ktas + 0.15)), res = Math.round(t.burn * 0.75), taxi = Math.round(t.burn * 0.08);
  return { ac, t, from, bh: qd.bh, opc: Math.round(opRate(t) * qd.bh * (trip.kind === 'ferry' ? repoFactor() : 1)), alt, altd, fl: cruiseFL(t, trip.from_icao, trip.to_icao, trip.dist), tripFuel, altFuel, res, taxi, block: tripFuel + altFuel + res + taxi, payload: trip.pax * 230 };
}

/* ---------- time ---------- */
const utc = () => pref('time') === 'utc';
const TZC = {};
function tzOf(icao) {
  if (!icao) return 'UTC';
  if (TZC[icao]) return TZC[icao];
  const a = D.airports[icao]; let z = 'UTC';
  try { if (a && window.tzlookup) z = window.tzlookup(a.lat, a.lon) } catch (e) { }
  return TZC[icao] = z;
}
const FMT = {};
function partsIn(ms, tz) {
  const f = FMT[tz] ||= new Intl.DateTimeFormat('en-GB', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', weekday: 'short', hourCycle: 'h23' });
  const o = {}; for (const p of f.formatToParts(new Date(ms))) o[p.type] = p.value; return o;
}
const hhmm = (ms, tz) => { const p = partsIn(ms, tz); return `${p.hour}:${p.minute}` };
// departure-style time: in UTC, or local at the given airport
function fmtDep(v, icao) {
  if (!v) return '—';
  const tz = utc() || !icao ? 'UTC' : tzOf(icao), p = partsIn(ts(v), tz), n = partsIn(Date.now(), tz);
  const day = Math.round((Date.UTC(+p.year, +p.month - 1, +p.day) - Date.UTC(+n.year, +n.month - 1, +n.day)) / 864e5);
  const t = `${p.hour}:${p.minute}${tz === 'UTC' ? 'Z' : ' LT'}`;
  return day === 0 ? `Today ${t}` : day === 1 ? `Tmrw ${t}` : day === -1 ? `Yday ${t}` : `${p.weekday} ${+p.day} ${t}`;
}
const fmtDate = v => { const tz = utc() ? 'UTC' : Intl.DateTimeFormat().resolvedOptions().timeZone; const p = partsIn(ts(v), tz); return `${p.day}/${p.month} ${p.hour}:${p.minute}${tz === 'UTC' ? 'Z' : ''}` };
function mmss(ms) { ms = Math.max(0, ms); const s = Math.ceil(ms / 1000); return s >= 3600 ? `${Math.floor(s / 3600)}h ${pad(Math.floor(s % 3600 / 60))}m` : `${Math.floor(s / 60)}:${pad(s % 60)}` }
const ts = v => new Date(v).getTime();
const relTime = v => { const m = Math.max(0, Math.round((ts(v) - Date.now()) / 60000)); return m >= 60 ? `${Math.floor(m / 60)}h ${pad(m % 60)}m` : `${m} min` };

/* ---------- toasts and sound ---------- */
function toast(msg, kind) { const el = document.createElement('div'); el.className = 'toast ' + (kind || ''); el.textContent = msg; $('#toasts').prepend(el); setTimeout(() => el.remove(), 5500); while ($('#toasts').children.length > 4) $('#toasts').lastChild.remove() }
let actx = null;
function ring() {
  if (!UI.sound) return;
  try {
    actx = actx || new (window.AudioContext || window.webkitAudioContext)(); const now = actx.currentTime;
    for (let k = 0; k < 2; k++) for (let i = 0; i < 8; i++) { const o = actx.createOscillator(), g = actx.createGain(), t0 = now + k * 1.2 + i * 0.05; o.frequency.value = i % 2 ? 440 : 480; g.gain.setValueAtTime(0.0001, t0); g.gain.exponentialRampToValueAtTime(0.08, t0 + 0.01); g.gain.exponentialRampToValueAtTime(0.0001, t0 + 0.05); o.connect(g).connect(actx.destination); o.start(t0); o.stop(t0 + 0.06) }
  } catch (e) { }
}

/* ---------- boot ---------- */
async function boot() {
  const { data: { session } } = await sb.auth.getSession();
  sb.auth.onAuthStateChange((ev) => { if (ev === 'SIGNED_OUT') location.reload() });
  if (!session) return renderAuth();
  await loadStatic();
  D.uid = session.user.id;
  D.me = await q(sb.from('pilots').select('*').eq('id', D.uid).maybeSingle());
  if (!D.me) return renderOnboarding();
  await refreshCore();
  UI.acId = D.fleet[0]?.id;
  const h = location.hash.slice(1); if (TABS.some(t => t[0] === h)) UI.tab = h;
  document.body.classList.add('in');
  $('#top').hidden = false;
  renderAll();
  await doPoll();
  pollTimer = setInterval(doPoll, 4000);
  setInterval(() => { clock(); updateCountdowns() }, 1000);
}
async function loadAirports() {
  // Supabase returns at most 1,000 rows per request, so fetch the list in pages
  const cols = 'icao,name,city,country,lat,lon,tags,active,size,rwy_ft';
  const first = await sb.from('airports').select(cols, { count: 'exact' }).order('icao').range(0, 999);
  if (first.error) throw new Error(first.error.message);
  const pages = Math.ceil((first.count || 0) / 1000), rest = [];
  for (let i = 1; i < pages; i++) rest.push(q(sb.from('airports').select(cols).order('icao').range(i * 1000, i * 1000 + 999)));
  return first.data.concat(...(await Promise.all(rest)));
}
async function loadStatic() {
  const [settings, aps, types, clients] = await Promise.all([
    q(sb.from('va_settings').select('*').single()),
    loadAirports(),
    q(sb.from('aircraft_types').select('*').order('price')),
    q(sb.from('clients').select('*'))]);
  D.settings = settings; D.apList = aps.filter(a => a.active); D.airports = Object.fromEntries(aps.map(a => [a.icao, a]));
  D.types = Object.fromEntries(types.map(t => [t.code, t])); D.typeList = types; D.clients = clients;
  document.title = 'Charter Desk FS';
}
async function refreshCore() {
  const u = D.uid;
  const [me, fleet, requests, bids, calls, trips, pireps, crew, legs] = await Promise.all([
    q(sb.from('pilots').select('*').eq('id', u).single()),
    q(sb.from('fleet').select('*').eq('pilot_id', u).order('created_at')),
    q(sb.from('requests').select('*').in('status', ['open', 'deciding']).order('expires_at').limit(200)),
    q(sb.from('bids').select('*').eq('pilot_id', u).order('id', { ascending: false }).limit(25)),
    q(sb.from('calls').select('*').eq('pilot_id', u).eq('status', 'ringing')),
    q(sb.from('trips').select('*').eq('pilot_id', u).in('status', ['booked', 'flying', 'filed']).order('seq')),
    q(sb.from('pireps').select('id,trip_id,status,net,rep_delta,landing_fpm,block_h,created_at,review_note').eq('pilot_id', u).order('id', { ascending: false }).limit(8)),
    q(sb.from('crew').select('*').eq('pilot_id', u).in('status', ['training', 'active']).order('id')),
    q(sb.from('crew_legs').select('*').eq('pilot_id', u).order('id', { ascending: false }).limit(15))]);
  const prevCall = D.calls[0]?.id;
  Object.assign(D, { me, fleet, requests, bids, calls, trips, myPireps: pireps, crew, legs });
  if (D.calls[0] && D.calls[0].id !== prevCall) ring();
}
let polling = false;
async function doPoll() {
  if (polling) return; polling = true;
  try {
    const res = await rpc('poll');
    D.pax = res.pax || [];
    for (const e of (res.events || [])) toast(e.won ? `Won: ${e.client}, ${e.route} at ${money(e.amount)}. It's in your trips.` : `Lost ${e.route}. ${e.note}`, e.won ? 'ok' : 'bad');
    await refreshCore();
    renderHeader(); renderCall(); renderCabin();
    if (['market', 'trips', 'crew'].includes(UI.tab) && !$('#modal').children.length && !(UI.tab === 'trips' && UI.plan)) renderTabSafe();
  } catch (e) { console.warn(e) }
  polling = false;
}

/* ---------- auth screens ---------- */
function renderAuth(mode) {
  mode = mode || 'in';
  $('#main').innerHTML = `<div class="authwrap"><form class="authcard" id="authForm">
    <div class="authlogo"><svg width="30" height="30" viewBox="0 0 34 34" aria-hidden="true"><path d="M6 28 L14 6 L20 6 L16 20 L28 20 L28 28 Z" fill="#B88A3A"></path></svg><b>Charter Desk <span>FS</span></b></div><h1>${mode === 'in' ? 'Welcome back' : 'Join the desk'}</h1><p>${mode === 'in' ? 'Sign in to run your charter company.' : 'Create a pilot account. You\'ll set up your company next.'}</p>
    <div class="field"><label for="aEmail">Email</label><input id="aEmail" type="email" autocomplete="email" required></div>
    <div class="field"><label for="aPass">Password</label><input id="aPass" type="password" autocomplete="${mode === 'in' ? 'current-password' : 'new-password'}" minlength="8" required></div>
    <div class="err" id="aErr"></div>
    <button class="btn pri" type="submit">${mode === 'in' ? 'Sign in' : 'Create account'}</button>
    <div style="display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap">
      <button class="linkbtn" type="button" id="aSwitch">${mode === 'in' ? 'New pilot? Create an account' : 'Already registered? Sign in'}</button>
      ${mode === 'in' ? '<button class="linkbtn" type="button" id="aReset">Forgot password</button>' : ''}</div>
  </form></div>`;
  $('#aSwitch').onclick = () => renderAuth(mode === 'in' ? 'up' : 'in');
  if ($('#aReset')) $('#aReset').onclick = async () => {
    const email = $('#aEmail').value.trim(); if (!email) { $('#aErr').textContent = 'Enter your email first.'; return }
    const { error } = await sb.auth.resetPasswordForEmail(email, { redirectTo: location.origin + location.pathname });
    $('#aErr').textContent = error ? error.message : 'Check your email for a reset link.';
  };
  $('#authForm').onsubmit = async e => {
    e.preventDefault(); $('#aErr').textContent = '';
    const email = $('#aEmail').value.trim(), password = $('#aPass').value;
    const { data, error } = mode === 'in' ? await sb.auth.signInWithPassword({ email, password }) : await sb.auth.signUp({ email, password, options: { emailRedirectTo: location.origin + location.pathname } });
    if (error) { $('#aErr').textContent = error.message; return }
    if (mode === 'up' && !data.session) { $('#aErr').textContent = 'Check your email to confirm the account, then sign in.'; return }
    boot();
  };
}
const SETTINGS_FIELDS = [
  ['currency', 'Currency', [['USD', 'US dollar ($)'], ['GBP', 'Pound sterling (£)'], ['EUR', 'Euro (€)']]],
  ['weight', 'Fuel and payload', [['lb', 'Pounds (lb)'], ['kg', 'Kilograms (kg)']]],
  ['distance', 'Distance', [['nm', 'Nautical miles (nm)'], ['km', 'Kilometres (km)'], ['mi', 'Statute miles (mi)']]],
  ['time', 'Flight times shown in', [['local', 'Local time at each airport'], ['utc', 'UTC (Zulu)']]],
  ['sim', 'Simulator you fly', [['any', 'Several / any'], ['MSFS', 'Microsoft Flight Simulator'], ['P3D', 'Prepar3D'], ['XP', 'X-Plane']]]];
const settingsFields = (vals, idp) => SETTINGS_FIELDS.map(([k, l, opts]) => `<div class="field"><label for="${idp}${k}">${l}</label><select id="${idp}${k}" data-pref="${k}">${opts.map(([v, t]) => `<option value="${v}" ${vals[k] === v ? 'selected' : ''}>${t}</option>`).join('')}</select></div>`).join('');
const readSettings = idp => Object.fromEntries(SETTINGS_FIELDS.map(([k]) => [k, $('#' + idp + k).value]));

async function renderOnboarding() {
  const taken = (await q(sb.from('fleet').select('reg').limit(10000)).catch(() => [])).map(x => x.reg);
  const starters = D.typeList.filter(t => t.starter && flyable(t)).sort((a, b) => a.price_new - b.price_new);
  const home0 = D.airports[D.settings.start_home] ? D.settings.start_home : D.apList[0]?.icao;
  const st = { type: starters.find(t => t.code === D.settings.start_type)?.code || starters[0]?.code, regTouched: false, year: null };
  const countryCur = c => ['GB', 'JE', 'GG'].includes(c) ? 'GBP' : EURO.includes(c) ? 'EUR' : 'USD';
  const startPrefs = { ...PREF_DEFAULTS, currency: countryCur(D.airports[home0]?.country) };
  PREFS_OVERRIDE = startPrefs;
  const opts = D.apList.map(a => `<option value="${a.icao}">${esc(a.city)} · ${esc(a.name)}</option>`).join('');
  $('#main').innerHTML = `<div class="authwrap"><form class="authcard wide" id="obForm" novalidate>
    <div><div class="authlogo"><svg width="30" height="30" viewBox="0 0 34 34" aria-hidden="true"><path d="M6 28 L14 6 L20 6 L16 20 L28 20 L28 28 Z" fill="#B88A3A"></path></svg><b>Charter Desk <span>FS</span></b></div><h1>Found your company</h1><p style="margin-top:6px">You start with <b id="obCash"></b> in the bank and one aircraft of your choice at your home base, fully financed over 20 years. Payments come out every 30 days, so keep flying.</p></div>
    <h3 class="obh">1 · Pilot and company</h3>
    <div class="row2"><div class="field"><label for="obCs">Pilot callsign</label><input id="obCs" maxlength="8" placeholder="ALT001" autocomplete="off"></div>
    <div class="field"><label for="obName">Your name</label><input id="obName" maxlength="40" autocomplete="name"></div></div>
    <div class="field"><label for="obCo">Company name</label><input id="obCo" maxlength="40" placeholder="Jersey Executive Charter"></div>
    <div class="row2"><div class="field"><label for="obPx">Flight number prefix</label><input id="obPx" maxlength="3" placeholder="JEC"></div>
    <div class="field"><label for="obHome">Home base (ICAO)</label><input id="obHome" list="obHomeList" value="${home0}" maxlength="4" autocomplete="off" style="text-transform:uppercase"><datalist id="obHomeList">${opts}</datalist><span class="hint" id="obHomeHint"></span></div></div>
    <h3 class="obh">2 · Starter aircraft</h3>
    <div class="starters" id="obTypes"></div>
    <div class="row2"><div class="field"><label for="obYear">Model year</label><select id="obYear"></select></div>
    <div class="field"><label>Finance</label><div class="finbox" id="obFin"></div></div></div>
    <div class="row2"><div class="field"><label for="obReg">Registration</label><input id="obReg" maxlength="9" autocomplete="off" style="text-transform:uppercase"><span class="hint" id="obRegHint"></span></div>
    <div class="field"><label>&nbsp;</label><button type="button" class="btn" id="obRegNew">Suggest another</button></div></div>
    <h3 class="obh">3 · Settings</h3>
    <div class="row2">${settingsFields(startPrefs, 'obP')}</div>
    <p class="hint" style="margin:0">Everyone in the VA trades in the same economy. Currency changes what you see, at fixed game rates: $1 = £0.79 = €0.92. You can change all of these later on your Profile page.</p>
    <div class="err" id="obErr"></div><button class="btn pri" type="submit">Start trading</button></form></div>`;
  const drawTypes = () => {
    if (!forMe(D.types[st.type])) st.type = (starters.find(forMe) || starters[0]).code;
    $('#obTypes').innerHTML = starters.slice().sort((a, b) => forMe(b) - forMe(a)).map(t => `<button type="button" class="starter ${forMe(t) ? '' : 'nosim'}" data-type="${t.code}" aria-pressed="${t.code === st.type}" title="${esc(t.sim_note || '')}">
      <span class="sh"><b>${esc(t.name)}</b><span class="mono">${t.code}</span></span><span class="muted">${esc(t.cls)}</span>${simBadges(t)}
      <span class="specs"><span><label>Seats</label>${t.seats}</span><span><label>Range</label>${dist(t.range_nm)}</span><span><label>Cruise</label>${t.ktas} kt</span><span><label>Earns (new)</label>${kmoney(t.rate)}/h</span></span></button>`).join('');
    $('#obCash').textContent = money(D.settings.start_cash);
    const t = D.types[st.type], yrs = modelYears(t);
    if (!yrs.includes(st.year)) st.year = yrs.find(y => acAge(y) >= 10) ?? yrs[yrs.length - 1];
    $('#obYear').innerHTML = yrs.map(y => `<option value="${y}" ${y === st.year ? 'selected' : ''}>${y}${acAge(y) === 0 ? ' · new' : acAge(y) === 1 ? ' · 1 year old' : ` · ${acAge(y)} years old`}</option>`).join('');
    drawFin();
  };
  const drawFin = () => {
    const t = D.types[st.type], v = acValue(t, st.year);
    $('#obFin').innerHTML = `<b>${bigMoney(v)}</b> aircraft · <b>${money(loanMonthly(v, 20))}</b> a month<br><span class="hint">Earns about ${kmoney(t.rate * rmul(st.year))} an hour flown; running costs ${kmoney(opRate(t))}/h.</span>`;
  };
  const homeCode = () => $('#obHome').value.trim().toUpperCase();
  const country = () => D.airports[homeCode()]?.country;
  const checkHome = () => { const a = D.airports[homeCode()]; $('#obHomeHint').textContent = a ? `${a.name}, ${a.city} · runway ${ft(a.rwy_ft)}` : 'Type an ICAO code or search by city.'; $('#obHomeHint').className = 'hint ' + (a ? 'good' : 'bad'); return !!a };
  const checkReg = () => { const r = $('#obReg').value.trim().toUpperCase(); const ok = REG_RE.test(r) && !taken.includes(r);
    $('#obRegHint').textContent = !r ? 'Letters and numbers with a country prefix, like G-ABCD or ZJ-JEC.' : taken.includes(r) ? 'Already used by another pilot.' : ok ? 'Looks good.' : 'Use a country prefix and dash (G-ABCD, ZJ-JEC, D-IABC) or a US N-number (N123AB).';
    $('#obRegHint').className = 'hint ' + (r && !ok ? 'bad' : r ? 'good' : ''); return ok };
  const suggest = () => { $('#obReg').value = suggestReg(country(), $('#obPx').value || 'ABC', taken); checkReg() };
  drawTypes(); suggest(); checkHome();
  $('#obYear').onchange = () => { st.year = +$('#obYear').value; drawFin() };
  $('#obTypes').onclick = e => { const b = e.target.closest('[data-type]'); if (b) { st.type = b.dataset.type; drawTypes() } };
  $('#obRegNew').onclick = () => { st.regTouched = false; suggest() };
  $('#obReg').oninput = () => { st.regTouched = true; checkReg() };
  $('#obCo').oninput = () => { if (!$('#obPx').dataset.touched) { $('#obPx').value = $('#obCo').value.split(/\s+/).filter(Boolean).map(w => w[0]).join('').toUpperCase().slice(0, 3); if (!st.regTouched) suggest() } };
  $('#obPx').oninput = () => { $('#obPx').dataset.touched = '1'; if (!st.regTouched) suggest() };
  $('#obHome').oninput = () => { if (checkHome()) $('#obHome').onchange() };
  $('#obHome').onchange = () => { if (!checkHome()) return; $('#obPcurrency').value = countryCur(country()); PREFS_OVERRIDE = readSettings('obP'); drawTypes(); if (!st.regTouched) suggest() };
  document.querySelectorAll('#obForm [data-pref]').forEach(el => el.onchange = () => { PREFS_OVERRIDE = readSettings('obP'); drawTypes() });
  $('#obForm').onsubmit = async e => {
    e.preventDefault(); $('#obErr').textContent = '';
    const need = [['obCs', 'a callsign'], ['obName', 'your name'], ['obCo', 'a company name'], ['obPx', 'a 3-letter prefix']].find(([k]) => !$('#' + k).value.trim());
    if (need) { $('#obErr').textContent = `Enter ${need[1]}.`; $('#' + need[0]).focus(); return }
    if (!checkHome()) { $('#obErr').textContent = 'Choose a home base from the list.'; $('#obHome').focus(); return }
    if (!checkReg()) { $('#obErr').textContent = 'Fix the registration first.'; $('#obReg').focus(); return }
    const sa = D.airports[homeCode()], stt = D.types[st.type];
    if (sa.rwy_ft < stt.min_rwy_ft) { $('#obErr').textContent = `${sa.icao}'s runway is too short for the ${stt.name}. Pick another aircraft or home base.`; return }
    try {
      await rpc('found_company', { p_callsign: $('#obCs').value, p_name: $('#obName').value, p_company: $('#obCo').value, p_prefix: $('#obPx').value,
        p_home: homeCode(), p_type: st.type, p_year: st.year, p_reg: $('#obReg').value.trim().toUpperCase(), p_prefs: readSettings('obP') });
      PREFS_OVERRIDE = null; boot();
    } catch (err) { $('#obErr').textContent = err.message }
  };
}

/* ---------- header, call, countdowns ---------- */
function renderHeader() {
  $('#coName').textContent = `${D.me.company} · ${D.me.callsign}`;
  $('#gCash').textContent = money(D.me.cash);
  $('#gRep').textContent = Math.round(D.me.rep) + ' / 100';
  $('#gRepBar').style.width = D.me.rep + '%';
  $('#soundBtn').textContent = UI.sound ? 'Ringer on' : 'Ringer off';
  $('#themeBtn').textContent = THEME === 'system' ? 'Theme: auto' : THEME === 'dark' ? 'Theme: dark' : 'Theme: light';
  const counts = { market: D.bids.filter(b => b.status === 'pending').length, trips: D.trips.length };
  $('#tabs').innerHTML = TABS.filter(t => t[0] !== 'staff' || D.me.is_admin).map(([k, l]) =>
    `<a href="#${k}" data-tab="${k}" ${UI.tab === k ? 'aria-current="page"' : ''}>${l}${counts[k] ? `<span class="ct">${counts[k]}</span>` : ''}</a>`).join('');
}
function clock() {
  const now = Date.now(); $('#gUtc').textContent = hhmm(now, 'UTC') + 'Z';
  const ac = D.me && (active() || anyAc()); if (!ac) return;
  const tz = tzOf(ac.loc); $('#gLocalLabel').textContent = `Local · ${ac.loc}`; $('#gLocal').textContent = hhmm(now, tz);
}
function updateCountdowns() {
  const now = Date.now();
  document.querySelectorAll('[data-cd]').forEach(e => e.textContent = mmss(+e.dataset.cd - now));
  document.querySelectorAll('[data-bar]').forEach(e => { const a = +e.dataset.from, b = +e.dataset.until; e.style.width = clamp((now - a) / (b - a) * 100, 0, 100) + '%' });
}
function renderCabin() {
  const r = (D.pax || [])[0], el = $('#cabin');
  if (!r) { el.innerHTML = ''; el.dataset.id = ''; return }
  if (el.dataset.id === String(r.id)) return;
  el.dataset.id = r.id;
  const trip = D.trips.find(t => t.id === r.trip_id);
  el.innerHTML = `<div class="cabincard" role="alertdialog" aria-label="Cabin call from seat ${esc(r.seat)}">
   <div class="cabinhd"><span class="lbl">Cabin call · seat ${esc(r.seat)}</span><span class="hint">answer in <span data-cd="${ts(r.expires_at)}"></span></span></div>
   <p class="who">${esc(r.who.charAt(0).toUpperCase() + r.who.slice(1))}${trip ? ` · ${trip.flt}` : ''}</p>
   <q>${esc(r.message)}</q>
   <div class="cabinbtns">${r.choices.map((c, i) => `<button type="button" class="btn" data-act="paxans" data-id="${r.id}" data-i="${i}">${esc(c)}</button>`).join('')}</div></div>`;
  if (UI.sound) { try { actx = actx || new (window.AudioContext || window.webkitAudioContext)(); const o = actx.createOscillator(), g = actx.createGain(), t0 = actx.currentTime; o.frequency.setValueAtTime(880, t0); o.frequency.setValueAtTime(660, t0 + 0.18); g.gain.setValueAtTime(0.0001, t0); g.gain.exponentialRampToValueAtTime(0.08, t0 + 0.02); g.gain.exponentialRampToValueAtTime(0.0001, t0 + 0.5); o.connect(g).connect(actx.destination); o.start(t0); o.stop(t0 + 0.5) } catch (e) { } }
  updateCountdowns();
}
function renderCall() {
  const c = D.calls[0]; if (!c) { $('#call').innerHTML = ''; return }
  if ($('#call').dataset.id === String(c.id)) return;
  $('#call').dataset.id = c.id;
  const A = D.airports[c.from_icao], B = D.airports[c.to_icao];
  const el = pilotFleet().filter(a => fits(typeOf(a), c));
  const initials = c.caller.split(/\s+/).map(w => w[0]).join('').slice(0, 2).toUpperCase();
  $('#call').innerHTML = `<div class="callcard" role="alertdialog" aria-label="Incoming call from ${esc(c.caller)}">
  <span class="lbl">CHARTER DESK FS · INCOMING CALL</span>
  <div class="avatar" aria-hidden="true">${esc(initials)}</div>
  <div class="who"><b>${esc(c.caller)}</b><span>${esc(c.client)} · rings off in <span data-cd="${ts(c.expires_at)}"></span></span></div>
  <div class="msg"><q>${esc(CALL_LINES[c.line % 4](c, A, B))}</q>
   <div class="line"><span>${c.from_icao} → ${c.to_icao}</span><span>${dist(c.dist)} · ${fmtDep(c.dep_at, c.from_icao)}</span></div>
   <div class="line" style="align-items:baseline"><span>Offering</span><span class="offer">${money(c.offer)}</span></div>
   ${el.length > 1 ? `<select class="sel" id="callAc" aria-label="Aircraft">${el.map(a => `<option value="${a.id}">${a.reg} · ${a.type_code} at ${futureLoc(a)}</option>`).join('')}</select>` : el.length ? `<div class="line"><span>Aircraft</span><span>${el[0].reg} at ${futureLoc(el[0])}</span></div>` : '<div class="line"><span>None of your aircraft can fly this job.</span></div>'}</div>
  <div class="answer">
   <div><button type="button" class="no" data-act="declinecall" data-id="${c.id}" aria-label="Decline the call"><svg width="26" height="26" viewBox="0 0 24 24" aria-hidden="true"><path fill="#fff" d="M12 9c-1.6 0-3.15.25-4.6.72v3.1c0 .39-.23.74-.56.9-.98.49-1.87 1.12-2.66 1.85a1 1 0 0 1-1.41-.02L.29 13.08a1 1 0 0 1 0-1.41C3.34 8.77 7.46 7 12 7s8.66 1.77 11.71 4.67a1 1 0 0 1 0 1.41l-2.48 2.47a1 1 0 0 1-1.41.02 11.27 11.27 0 0 0-2.66-1.85 1 1 0 0 1-.56-.9v-3.1C15.15 9.25 13.6 9 12 9z"/></svg></button>Decline</div>
   <div><button type="button" class="yes" data-act="acceptcall" data-id="${c.id}" aria-label="Accept the job" ${el.length ? '' : 'disabled'}><svg width="26" height="26" viewBox="0 0 24 24" aria-hidden="true"><path fill="#fff" d="M6.6 10.8a15.1 15.1 0 0 0 6.6 6.6l2.2-2.2c.3-.3.7-.4 1-.2 1.1.4 2.3.6 3.6.6.6 0 1 .4 1 1V20c0 .6-.4 1-1 1A17 17 0 0 1 3 4c0-.6.4-1 1-1h3.5c.6 0 1 .4 1 1 0 1.3.2 2.5.6 3.6.1.3 0 .7-.2 1z"/></svg></button>Accept job</div>
  </div></div>`;
  updateCountdowns();
}

/* ---------- tabs ---------- */
function renderAll() { renderHeader(); renderCall(); renderTab() }
function renderTabSafe() { const ae = document.activeElement; if (ae && $('#main').contains(ae) && ae.matches('input,select,textarea')) return; renderTab() }
function renderTab() {
  const f = { market: renderMarket, trips: renderTrips, hangar: renderHangar, crew: renderCrew, shop: renderShop, live: renderLive, reports: renderReports, pilots: renderPilots, ledger: renderLedger, profile: renderProfile, staff: renderStaff }[UI.tab] || renderMarket;
  Promise.resolve(f()).catch(e => { $('#main').innerHTML = `<div class="panel empty">Couldn't load this page: ${esc(e.message)}</div>` });
}

const BANDS = [['any', 'Any'], ['0-1', 'Under 1h'], ['1-2', '1–2h'], ['2-3', '2–3h'], ['3-5', '3–5h'], ['5-99', '5h+']];
const inBand = h => { if (UI.band === 'any') return true; const [a, b] = UI.band.split('-').map(Number); return h >= a && h < b };

function renderMarket() {
  const ac = active(); if (!ac) { $('#main').innerHTML = `<div class="panel empty">${D.fleet.length ? 'All your aircraft are flown by crew. Take one back on the <a href="#crew" data-tab="crew">Crew</a> page to quote yourself.' : 'You have no aircraft. Add one in the Shop.'}</div>`; return }
  const t = typeOf(ac);
  let list = D.requests.map(r => { const q = quote(ac, r), tm = timing(ac, r, q); return { r, ok: fits(t, r) && !tm.late, q, tm } }).filter(x => inBand(blockH(t, x.r.dist)));
  const hidden = list.filter(x => !x.ok).length;
  if (!UI.showAll) list = list.filter(x => x.ok);
  const far = list.filter(x => x.q.repoNm > NEAR_NM).length;
  if (UI.nearOnly) list = list.filter(x => x.q.repoNm <= NEAR_NM);
  const sorts = { closing: (a, b) => ts(a.r.decide_at || a.r.expires_at) - ts(b.r.decide_at || b.r.expires_at), value: (a, b) => b.q.guide - a.q.guide, dep: (a, b) => ts(a.r.dep_at) - ts(b.r.dep_at), repo: (a, b) => a.q.repoNm - b.q.repoNm };
  list.sort(sorts[UI.sort]);
  const h = new Date().getHours();
  const mood = h < 6 ? 'Overnight: a quiet board, mostly urgent and medical work.' : h < 12 ? 'Morning: business routes between financial centres lead the board.' : h < 17 ? 'Afternoon: a mix of business returns and leisure departures.' : 'Evening: leisure demand to the Med and islands is building.';
  const pending = D.bids.filter(b => b.status === 'pending'), recent = D.bids.filter(b => b.status !== 'pending').slice(0, 7);
  $('#main').innerHTML = `<div class="market">
 <aside class="side">
  <div class="panel"><h3>Bidding with</h3><div class="acpick">${pilotFleet().map(a => { const tt = typeOf(a), n = queue(a).length; return `<button type="button" class="acopt" data-act="pickac" data-id="${a.id}" aria-pressed="${a.id === ac.id}"><b>${a.reg}</b><span>${esc(tt.name)}</span><em>At ${futureLoc(a)}${n ? ` after ${n} leg${n > 1 ? 's' : ''}` : ''} · ${tt.seats} seats · ${dist(tt.range_nm)}</em></button>` }).join('')}</div></div>
  <div class="panel"><h3>Flight time</h3><div class="bands">${BANDS.map(([k, l]) => `<button type="button" class="chip" data-act="band" data-k="${k}" aria-pressed="${UI.band === k}">${l}</button>`).join('')}</div>
   <p class="muted" style="font-size:12px;margin:10px 0 0">Block time in the ${esc(t.name)}, including taxi and climb.</p></div>
  <div class="panel"><h3>${esc(t.name)}</h3><div class="specs">
   <div><label>Cruise</label><span>${t.ktas} kt</span></div><div><label>Range</label><span>${dist(t.range_nm)}</span></div>
   <div><label>Seats</label><span>${t.seats}</span></div><div><label>Charter rate</label><span>${kmoney(acRate(ac))}/h</span></div>
   <div><label>Op. cost</label><span>${kmoney(opRate(t))}/h</span></div><div><label>Fuel burn</label><span>${wtRate(t.burn)}</span></div><div><label>Min. runway</label><span>${ft(t.min_rwy_ft)}</span></div></div></div>
 </aside>
 <section style="min-width:0">
  <div class="boardhead"><div><h2>${h < 5 || h >= 18 ? 'Tonight’s' : h < 12 ? 'This morning’s' : 'This afternoon’s'} enquiries</h2><p>${mood} Every ${esc(D.settings.va_name)} pilot sees this board.</p></div>
   <div class="boardtools"><label class="check"><input type="checkbox" id="nearOnly" data-act="nearonly" ${UI.nearOnly ? 'checked' : ''}> Only within ${dist(NEAR_NM)} of ${ac.reg}${far && UI.nearOnly ? ` (${far} further away)` : ''}</label>
   <label class="check"><input type="checkbox" id="showAll" data-act="showall" ${UI.showAll ? 'checked' : ''}> Show requests this aircraft can't fly${hidden && !UI.showAll ? ` (${hidden})` : ''}</label>
   <select class="sel" id="sortSel" data-act="sort" aria-label="Sort requests">${[['closing', 'Closing soonest'], ['value', 'Highest value'], ['dep', 'Earliest departure'], ['repo', 'Closest to aircraft']].map(([k, l]) => `<option value="${k}" ${UI.sort === k ? 'selected' : ''}>${l}</option>`).join('')}</select></div></div>
  <div class="strips">${list.length ? list.map(x => strip(x, ac)).join('') : `<div class="empty">No requests in this time band for ${ac.reg} right now. New requests arrive every minute or so.</div>`}</div>
 </section>
 <aside class="bidcol">
  <div class="panel"><h3>Bids with brokers</h3>${pending.length ? `<div style="display:flex;flex-direction:column;gap:8px">${pending.map(b => { const r = D.requests.find(x => x.id === b.request_id); const until = r?.decide_at ? ts(r.decide_at) : Date.now(); return `<div class="bid"><div class="r"><span>${r ? `${r.from_icao} → ${r.to_icao}` : 'Request'}</span><b>${money(b.amount)}</b></div><div class="bar"><i data-bar data-from="${ts(b.placed_at)}" data-until="${until}"></i></div><small>${acById(b.aircraft_id)?.reg || ''}${r && r.player_bids > 1 ? ` · ${r.player_bids - 1} other VA pilot${r.player_bids > 2 ? 's' : ''} quoting` : ''} · decision in <span data-cd="${until}"></span></small></div>` }).join('')}</div>` : `<p class="muted" style="margin:0;font-size:13px">No open bids. Pick a job and quote a price. The broker decides ${BIDWAIT[Math.min(3, upg('fast'))]} seconds after the first quote.</p>`}</div>
  <div class="panel"><h3>Recent decisions</h3>${recent.length ? recent.map(b => `<div class="result"><span class="tag ${b.status}">${b.status === 'won' ? 'Won' : 'Lost'}</span><div><span class="mono">${money(b.amount)}</span><br><span class="muted">${esc(b.note || '')}</span></div></div>`).join('') : '<p class="muted" style="margin:0;font-size:13px">Broker decisions appear here.</p>'}</div>
 </aside></div>`;
  updateCountdowns();
  SEEN_READY = true;
}
function goNow(qd, tm, r) {
  const leaveIn = tm.leave - Date.now();
  if (qd.repoNm) return leaveIn < 5 * 6e4 ? `Go now · position to ${r.from_icao} now` : `Go now · leave ${qd.loc} in ${relTime(tm.leave)}`;
  return tm.busy ? `Back-to-back · departs in ${relTime(r.dep_at)}` : `Go now · in ${relTime(r.dep_at)}`;
}
const SEEN_JOBS = new Set(); let SEEN_READY = false;
function strip({ r, ok, q: qd, tm }, ac) {
  const t = typeOf(ac), bid = D.bids.find(b => b.request_id === r.id), A = D.airports[r.from_icao] || {}, B = D.airports[r.to_icao] || {};
  const deciding = r.status === 'deciding';
  let act;
  if (!ok) act = `<span class="why">${esc(whyNot(t, r) || (qd.repoNm ? 'Can\'t position in time' : `${ac.reg} busy until ${fmtDep(new Date(tm.free).toISOString(), qd.loc)}`))}</span>`;
  else if (bid) act = `<span class="placed">Bid ${kmoney(bid.amount)}</span><span class="cd">decision <span data-cd="${ts(r.decide_at)}"></span></span>`;
  else act = `<button type="button" data-act="bid" data-id="${r.id}">Quote</button><span class="cd">${deciding ? `deciding <span data-cd="${ts(r.decide_at)}"></span>` : `closes <span data-cd="${ts(r.expires_at)}"></span>`}</span>`;
  const fresh = !SEEN_JOBS.has(r.id); SEEN_JOBS.add(r.id);
  return `<article class="job cat-${r.cat} ${ok ? '' : 'na'} ${fresh && SEEN_READY ? 'fresh' : ''}">
  <div class="where"><span class="cities">${esc(A.city || r.from_icao)} <i>to</i> ${esc(B.city || r.to_icao)}</span>
   <span class="sub"><b>${r.from_icao} – ${r.to_icao}</b> · ${esc(r.client)} · ${r.pax} passenger${r.pax > 1 ? 's' : ''} · ${r.npc} quoting${r.player_bids ? ` + ${r.player_bids} VA` : ''}</span>
   ${ok && qd.repoNm ? `<span class="repo">Positioning ${dist(qd.repoNm)} from ${qd.loc} first · leave by ${fmtDep(new Date(tm.leave).toISOString(), qd.loc)}</span>` : ''}</div>
  <div class="facts"><span><label>Departs</label><b>${fmtDep(r.dep_at, r.from_icao)}</b>${ok && tm.soon ? `<em class="gonow">${goNow(qd, tm, r)}</em>` : ''}</span><span><label>Flight time</label><b>${hm(blockH(t, r.dist))}</b></span><span><label>Distance</label><b>${dist(r.dist)}</b></span><span><label>Market rate</label><b class="money">${ok ? kmoney(qd.guide) : '—'}</b></span></div>
  <div class="act">${act}</div></article>`;
}

function renderTrips() {
  if (UI.plan && D.trips.some(t => t.id === UI.plan)) return renderPlanner(D.trips.find(t => t.id === UI.plan));
  UI.plan = null;
  const list = D.trips.slice().sort((a, b) => (a.aircraft_id || '').localeCompare(b.aircraft_id || '') || a.seq - b.seq);
  const reps = D.myPireps;
  $('#main').innerHTML = `<div class="section"><div class="sechead"><div><h2>Trips</h2><p>Fly each leg with the Charter Desk Tracker: load the aircraft at the departure gate, pick the booking in the tracker and press Start flight. The report files itself at block on.</p></div><a class="btn" href="#profile" data-tab="profile">Get the tracker</a></div>
  ${list.length ? `<div class="trips">${list.map(tripCard).join('')}</div>` : `<div class="panel empty">Nothing booked. Quote on the request board or wait for the phone to ring.<div style="margin-top:12px"><a class="btn pri" href="#market" data-tab="market">Open the request board</a></div></div>`}</div>
  ${reps.length ? `<div class="section"><h2>Your recent reports</h2><div class="panel tablewrap"><table class="grid"><thead><tr><th>Filed</th><th>Status</th><th>Block</th><th>Landing</th><th>Net</th><th>Rep</th><th>Note</th></tr></thead><tbody>${reps.map(p => `<tr class="click" data-act="pirep" data-id="${p.id}"><td class="n">${fmtDate(p.created_at)}</td><td><span class="tag ${p.status}">${p.status}</span></td><td class="n">${hm(p.block_h)}</td><td class="n">${p.landing_fpm ?? '—'} fpm</td><td class="n">${p.net == null ? '—' : money(p.net)}</td><td class="n">${p.rep_delta == null ? '—' : (p.rep_delta > 0 ? '+' : '') + (+p.rep_delta).toFixed(1)}</td><td>${esc(p.review_note || '')}</td></tr>`).join('')}</tbody></table></div></div>` : ''}`;
  list.forEach(tr => drawMap(document.getElementById('map-' + tr.id), tr));
}
function tripCard(trip) {
  const ac = acById(trip.aircraft_id); if (!ac) return '';
  const p = plan(trip), t = p.t, qd = queue(ac), first = qd[0]?.id === trip.id, ferry = trip.kind === 'ferry';
  const profit = trip.price - p.opc;
  const fltNum = (trip.flt.split(' ')[1] || '').replace(/\D/g, '');
  const A = D.airports[trip.from_icao], B = D.airports[trip.to_icao];
  const state = trip.status === 'flying' ? '<span class="tag flying">In flight</span>' : trip.status === 'filed' ? '<span class="tag filed">Awaiting review</span>' : first ? '<span class="tag won">Ready to fly</span>' : '<span class="tag pending">Queued</span>';
  const ferryCost = Math.round(opRate(t) * p.bh * 1.5);
  return `<article class="trip"><div class="info">
  <div class="flt"><b>${trip.flt}</b><span class="muted">${ac.reg} · ${esc(t.name)}</span>${ferry ? '<span class="tag ferry">Positioning</span>' : `<span class="tag ${trip.source === 'call' ? 'call' : 'won'}">${trip.source === 'call' ? 'Phone booking' : 'Won bid'}</span>`}${state}</div>
  <div><div class="route">${trip.from_icao}<i>▸</i>${trip.to_icao}</div><div class="places">${esc(A?.name)}, ${esc(A?.city)} to ${esc(B?.name)}, ${esc(B?.city)}${ferry ? ' · empty' : ` · ${esc(trip.caller ? trip.caller + ' (' + trip.client + ')' : trip.client)}`}</div></div>
  <div class="grid4">
   <div class="kv"><label>${ferry ? `Arrive ${trip.to_icao} by` : 'Departs'}</label><span>${fmtDep(trip.dep_at, ferry ? trip.to_icao : trip.from_icao)}</span></div>
   <div class="kv"><label>Distance</label><span>${dist(trip.dist)}</span></div>
   <div class="kv"><label>Est. block</label><span>${hm(p.bh)}</span></div>
   <div class="kv"><label>Cruise</label><span>FL${p.fl}</span></div>
   <div class="kv"><label>Passengers</label><span>${trip.pax} · ${wt(p.payload)}</span></div>
   <div class="kv"><label>Block fuel</label><span>${wt(p.block)}</span></div>
   <div class="kv"><label>Alternate</label><span>${p.alt} · ${dist(p.altd)}</span></div>
   <div class="kv"><label>Runways</label><span>${ft(rwy(trip.from_icao))} / ${ft(rwy(trip.to_icao))}</span></div>
   <div class="kv"><label>Course</label><span>${String(Math.round(brg(trip.from_icao, trip.to_icao))).padStart(3, '0')}°</span></div>
   <div class="kv"><label>Revenue</label><span>${money(trip.price)}</span></div>
   <div class="kv"><label>Est. op. cost</label><span>${money(p.opc)}</span></div>
   <div class="kv"><label>Est. profit</label><span class="${profit >= 0 ? 'pos' : 'neg'}">${money(profit)}</span></div>
   <div class="kv"><label>Fuel split</label><span style="font-size:12px">Trip ${wt(p.tripFuel)} · Res ${wt(p.res)}</span></div>
  </div>
  ${planChips(trip)}
  ${trip.brief ? `<div class="note brief-teaser"><b>${esc(trip.brief.from)}:</b> ${esc(briefLine(trip.brief))}</div>` : ''}
  <div class="btns">
   ${trip.status === 'booked' || trip.status === 'flying' ? `<button type="button" class="btn pri" data-act="planner" data-id="${trip.id}">Plan this flight</button>` : ''}
   <button type="button" class="btn" data-act="copyplan" data-id="${trip.id}">Copy plan</button>
   ${ferry && first && trip.status === 'booked' ? `<button type="button" class="btn" data-act="outsource" data-id="${trip.id}" data-cost="${ferryCost}">Use a contract crew · ${kmoney(ferryCost)}</button>` : ''}
   ${!ferry && trip.status === 'booked' ? `<button type="button" class="btn danger" data-act="cancel" data-id="${trip.id}">Cancel</button>` : ''}
  </div>
  ${!first && trip.status === 'booked' ? `<div class="waiting">Fly ${qd[0].flt} (${qd[0].from_icao} → ${qd[0].to_icao}) with ${ac.reg} first.</div>` : ''}
 </div><div class="mapbox"><canvas id="map-${trip.id}" aria-label="Route map ${trip.from_icao} to ${trip.to_icao}"></canvas></div></article>`;
}
async function drawMap(cvs, trip) {
  if (!cvs) return;
  if (window.d3) { try { await drawLandMap(cvs, trip); return } catch (e) { console.warn('map', e) } }
  drawDotMap(cvs, trip);
}
async function drawLandMap(cvs, trip) {
  const p = plan(trip), A = D.airports[trip.from_icao], B = D.airports[trip.to_icao], AL = D.airports[p.alt];
  const box = cvs.parentElement.getBoundingClientRect(), W = Math.max(260, box.width), H = Math.max(240, box.height), dpr = window.devicePixelRatio || 1;
  cvs.width = W * dpr; cvs.height = H * dpr; const c = cvs.getContext('2d'); c.setTransform(dpr, 0, 0, dpr, 0, 0);
  const pts = [A, B, AL].filter(Boolean).map(a => [a.lon, a.lat]);
  const lons = pts.map(x => x[0]), lats = pts.map(x => x[1]), cx = (Math.min(...lons) + Math.max(...lons)) / 2, cy = (Math.min(...lats) + Math.max(...lats)) / 2;
  pts.push([cx - 2.5, cy - 1.5], [cx + 2.5, cy + 1.5]);   // never zoom in closer than a few degrees
  const proj = d3.geoMercator().fitExtent([[50, 34], [W - 50, H - 30]], { type: 'MultiPoint', coordinates: pts });
  const path = d3.geoPath(proj, c), land = await landShapes();
  if (!cvs.isConnected) return;
  c.fillStyle = cssv('--map-sea'); c.fillRect(0, 0, W, H);
  c.beginPath(); path(d3.geoGraticule().step([5, 5])()); c.strokeStyle = cssv('--map-grid'); c.lineWidth = 1; c.stroke();
  if (land) { c.beginPath(); path(land); c.fillStyle = cssv('--map-land'); c.fill(); c.strokeStyle = cssv('--map-land-edge'); c.lineWidth = .7; c.stroke() }
  if (BORDERS) { c.beginPath(); path(BORDERS); c.strokeStyle = cssv('--map-border'); c.lineWidth = .6; c.stroke() }
  if (AL) { c.beginPath(); path({ type: 'LineString', coordinates: [[B.lon, B.lat], [AL.lon, AL.lat]] }); c.setLineDash([3, 4]); c.strokeStyle = cssv('--map-muted'); c.lineWidth = 1.2; c.stroke(); c.setLineDash([]) }
  c.beginPath(); path({ type: 'LineString', coordinates: [[A.lon, A.lat], [B.lon, B.lat]] }); c.strokeStyle = trip.kind === 'ferry' ? '#B88A3A' : cssv('--map-route');
  c.lineWidth = 2.5; if (trip.kind === 'ferry') c.setLineDash([6, 4]); c.stroke(); c.setLineDash([]);
  const dot = (a, label, col, r) => { const q = proj([a.lon, a.lat]); c.beginPath(); c.arc(q[0], q[1], r, 0, 7); c.fillStyle = col; c.fill(); c.strokeStyle = cssv('--surface'); c.lineWidth = 1.5; c.stroke();
    if (!label) return; c.font = '600 12px "DM Mono", monospace'; const tw = c.measureText(label).width; let tx = q[0] + 8; if (tx + tw > W - 6) tx = q[0] - 8 - tw;
    c.fillStyle = cssv('--map-label'); c.fillText(label, tx, q[1] - 7) };
  if (AL) { const qa = proj([AL.lon, AL.lat]), qb = proj([B.lon, B.lat]); dot(AL, Math.hypot(qa[0] - qb[0], qa[1] - qb[1]) < 46 ? '' : AL.icao + ' ALT', cssv('--map-muted'), 3) }
  dot(A, A.icao, cssv('--map-mark'), 5); dot(B, B.icao, cssv('--map-mark'), 5);
}
function drawDotMap(cv, trip) {
  if (!cv) return; const p = plan(trip); const [alt] = [p.alt];
  const pts = [trip.from_icao, trip.to_icao, alt].map(k => D.airports[k]).filter(Boolean);
  const box = cv.parentElement.getBoundingClientRect(); const W = Math.max(260, box.width), H = Math.max(240, box.height); const dpr = window.devicePixelRatio || 1; cv.width = W * dpr; cv.height = H * dpr; const c = cv.getContext('2d'); c.scale(dpr, dpr);
  const la = pts.map(a => a.lat), lo = pts.map(a => a.lon); const minLa = Math.min(...la), maxLa = Math.max(...la), minLo = Math.min(...lo), maxLo = Math.max(...lo);
  const midLat = (minLa + maxLa) / 2, k = Math.cos(midLat * R); const sp = Math.max((maxLo - minLo) * k / W, (maxLa - minLa) / H, 2 / Math.min(W, H)) * 1.45;
  const cx = (minLo + maxLo) / 2, cy = midLat; const X = lon => W / 2 + (lon - cx) * k / sp, Y = lat => H / 2 - (lat - cy) / sp;
  c.fillStyle = cssv('--map-sea'); c.fillRect(0, 0, W, H);
  const step = sp * Math.min(W, H) > 20 ? 10 : sp * Math.min(W, H) > 8 ? 5 : 2; c.strokeStyle = cssv('--map-grid'); c.lineWidth = 1; c.font = '10px "DM Mono",monospace'; c.fillStyle = cssv('--map-muted');
  for (let g = Math.floor((cy - H * sp / 2) / step) * step; g < cy + H * sp / 2; g += step) { const y = Y(g); c.beginPath(); c.moveTo(0, y); c.lineTo(W, y); c.stroke(); c.fillText(`${Math.abs(g)}°${g >= 0 ? 'N' : 'S'}`, 4, y - 3) }
  for (let g = Math.floor((cx - W * sp / k / 2) / step) * step; g < cx + W * sp / k / 2; g += step) { const x = X(g); c.beginPath(); c.moveTo(x, 0); c.lineTo(x, H); c.stroke(); c.fillText(`${Math.abs(g)}°${g >= 0 ? 'E' : 'W'}`, x + 3, H - 5) }
  D.apList.forEach(a => { if (a.size === 'small') return; const x = X(a.lon), y = Y(a.lat); if (x < 0 || x > W || y < 0 || y > H) return; c.fillStyle = cssv('--map-dot'); c.beginPath(); c.arc(x, y, 2, 0, 7); c.fill() });
  const gc = (A, B, dash, col, w) => { c.save(); c.setLineDash(dash); c.strokeStyle = col; c.lineWidth = w; c.beginPath(); const n = 40; const p1 = [A.lat * R, A.lon * R], p2 = [B.lat * R, B.lon * R]; const d = 2 * Math.asin(Math.sqrt(Math.sin((p2[0] - p1[0]) / 2) ** 2 + Math.cos(p1[0]) * Math.cos(p2[0]) * Math.sin((p2[1] - p1[1]) / 2) ** 2)) || 1e-9; for (let i = 0; i <= n; i++) { const f = i / n; const a = Math.sin((1 - f) * d) / Math.sin(d), b = Math.sin(f * d) / Math.sin(d); const x = a * Math.cos(p1[0]) * Math.cos(p1[1]) + b * Math.cos(p2[0]) * Math.cos(p2[1]), y = a * Math.cos(p1[0]) * Math.sin(p1[1]) + b * Math.cos(p2[0]) * Math.sin(p2[1]), z = a * Math.sin(p1[0]) + b * Math.sin(p2[0]); const lat = Math.atan2(z, Math.hypot(x, y)) / R, lon = Math.atan2(y, x) / R; i ? c.lineTo(X(lon), Y(lat)) : c.moveTo(X(lon), Y(lat)) } c.stroke(); c.restore() };
  const F = D.airports[trip.from_icao], T = D.airports[trip.to_icao], AL = D.airports[alt];
  if (AL) gc(T, AL, [2, 3], cssv('--map-muted'), 1);
  gc(F, T, trip.kind === 'ferry' ? [5, 4] : [], trip.kind === 'ferry' ? '#B88A3A' : cssv('--map-route'), 2.5);
  const lab = (a, col, txt, r) => { const x = X(a.lon), y = Y(a.lat); c.fillStyle = col; c.beginPath(); c.arc(x, y, r, 0, 7); c.fill(); c.font = '600 12px "DM Mono",monospace'; c.fillStyle = cssv('--map-label'); const tw = c.measureText(txt).width; let tx = x + 8; if (tx + tw > W - 4) tx = x - 8 - tw; c.fillText(txt, tx, y - 6) };
  if (AL) { const near = Math.hypot(X(AL.lon) - X(T.lon), Y(AL.lat) - Y(T.lat)) < 40; if (near) { c.fillStyle = cssv('--map-muted'); c.beginPath(); c.arc(X(AL.lon), Y(AL.lat), 2.5, 0, 7); c.fill() } else lab(AL, cssv('--map-muted'), alt + ' ALT', 2.5) } lab(F, cssv('--map-mark'), trip.from_icao, 4.5); lab(T, cssv('--map-mark'), trip.to_icao, 4.5);
}

function renderHangar() {
  const used = D.fleet.length;
  $('#main').innerHTML = `<div class="section"><div class="sechead"><div><h2>Hangar</h2><p>${used} of ${D.me.slots} fleet slots in use. Aircraft stay wherever their last flight ended. Finance payments come out every 30 days.</p></div></div>
  <form class="panel" id="coForm" style="display:flex;gap:12px;align-items:end;flex-wrap:wrap"><div class="field" style="flex:1;min-width:200px"><label for="coInput">Company name</label><input id="coInput" maxlength="40" value="${esc(D.me.company)}"></div>
   <div class="field" style="width:120px"><label for="pxInput">Flight prefix</label><input id="pxInput" maxlength="3" value="${esc(D.me.prefix)}"></div><button class="btn pri" type="submit">Save</button></form>
  <div class="cards">${D.fleet.map(a => {
    const t = typeOf(a), n = queue(a).length, val = acValue(t, a.year), loan = +a.loan_balance || 0, net = Math.round(val * 0.92 - loan);
    return `<div class="card ${a.id === active()?.id ? 'active' : ''}"><div class="hd"><b class="mono">${a.reg}</b><span>${a.year} · ${a.type_code}</span></div><p>${esc(t.name)} · ${esc(t.cls)}${a.ops === 'crew' ? ' · <span class="tag call">Crew-operated</span>' : ''}</p>
  <div class="specs"><div><label>Location</label><span>${a.loc} ${esc(D.airports[a.loc]?.city || '')}</span></div><div><label>Hours flown</label><span>${hm(a.hours)}</span></div>
   <div><label>Market value</label><span>${bigMoney(val)}</span></div><div><label>Charter rate</label><span>${kmoney(acRate(a))}/h</span></div>
   <div><label>Loan</label><span>${loan > 0 ? bigMoney(loan) : 'Owned outright'}</span></div><div><label>${loan > 0 ? 'Monthly payment' : 'Legs queued'}</label><span>${loan > 0 ? `${kmoney(a.loan_payment)} · ${fmtDate(a.loan_next_due).split(' ')[0]}` : n}</span></div></div>
  <div class="foot">${a.ops === 'crew' ? '<a class="btn" href="#crew" data-tab="crew">Crew operations</a>' : a.id === active()?.id ? '<span class="tag won">Bidding aircraft</span>' : `<button type="button" class="btn" data-act="pickac" data-id="${a.id}">Bid with this</button>`}
  <button type="button" class="btn" data-act="rereg" data-id="${a.id}">Change registration</button>
  ${loan > 0 ? `<button type="button" class="btn" data-act="repay" data-id="${a.id}" ${D.me.cash < loan ? 'disabled title="Not enough cash to pay it off"' : ''}>Pay off loan</button>` : ''}
  ${D.fleet.length > 1 ? `<button type="button" class="btn danger" data-act="sell" data-id="${a.id}" data-net="${net}" ${n ? 'disabled title="Finish or cancel its trips first"' : ''}>Sell · ${net < 0 ? '−' : ''}${bigMoney(Math.abs(net))}</button>` : ''}</div></div>` }).join('')}
  ${Array.from({ length: Math.max(0, D.me.slots - used) }, () => `<div class="card" style="border-style:dashed;justify-content:center;align-items:center;text-align:center;min-height:180px"><p>Empty slot</p><a class="btn" href="#shop" data-tab="shop">Add an aircraft</a></div>`).join('')}</div></div>`;
  $('#coForm').onsubmit = async e => { e.preventDefault(); await act(() => rpc('update_company', { p_company: $('#coInput').value, p_prefix: $('#pxInput').value }), 'Company details saved.') };
}

const SHOP_CATS = [['piston', 'Pistons'], ['turboprop', 'Turboprops'], ['light', 'Very light & light jets'], ['mid', 'Midsize & super-midsize'], ['large', 'Large & ultra-long-range']];
async function renderShop() {
  let cands = [];
  try { await rpc('refresh_candidates'); cands = await q(sb.from('crew_candidates').select('*').eq('pilot_id', D.uid).order('salary_ask')) } catch (e) { }
  const free = D.me.slots - D.fleet.length, slotCost = 60000 * 2 ** (D.me.slots - 2), cash = D.me.cash;
  UI.shopCat ||= 'all';
  const mySim = pref('sim'), simOnly = mySim !== 'any' && !UI.shopAllSims;
  const avail = D.typeList.filter(t => flyable(t) && (!simOnly || t.sims.includes(mySim)));
  const hiddenN = D.typeList.filter(flyable).length - avail.length;
  const cats = SHOP_CATS.filter(([k]) => UI.shopCat === 'all' || UI.shopCat === k);
  const card = t => { const own = D.fleet.filter(a => a.type_code === t.code).length, yrs = modelYears(t), oldest = yrs[yrs.length - 1], cheapest = acValue(t, oldest), isNew = t.year_to >= thisYear(), dep = cheapest * 0.15;
   return `<div class="card"><div class="hd"><b>${esc(t.name)}</b><span>${t.code}</span></div><p>${esc(t.cls)} · built ${t.year_from}${t.year_to >= thisYear() ? ' to today' : `–${t.year_to}`}${own ? ` · ${own} in fleet` : ''}</p>
  <div class="simrow">${simBadges(t)}<span class="hint">${esc(t.sim_note || '')}</span></div>
  <div class="specs"><div><label>Seats</label><span>${t.seats}</span></div><div><label>Range</label><span>${dist(t.range_nm)}</span></div><div><label>Cruise</label><span>${t.ktas} kt</span></div><div><label>Charter rate (new)</label><span>${kmoney(t.rate)}/h</span></div><div><label>Min. runway</label><span>${ft(t.min_rwy_ft)}</span></div><div><label>Crew</label><span>${t.crew_req === 1 ? 'Single pilot' : 'Two pilots'}</span></div></div>
  <div class="foot"><span style="display:flex;flex-direction:column"><span class="price">${isNew ? bigMoney(t.price_new) + ' new' : 'Used only'}</span><span class="hint">Used from ${bigMoney(cheapest)} (${oldest}) · deposit ${bigMoney(dep)}${cash >= dep ? '' : ` <span class="neg">· need ${bigMoney(dep - cash)} more</span>`}</span></span><button type="button" class="btn ${free && cash >= dep ? 'pri' : ''}" data-act="buyac" data-k="${t.code}" ${!free ? 'disabled' : ''}>Choose</button></div></div>` };
  $('#main').innerHTML = `<div class="section"><div class="sechead"><div><h2>Aircraft</h2><p>New and used, priced by age. Older aircraft cost less but earn lower charter rates. Pay in full, or finance with a 15% deposit over 15 years. Aircraft are delivered to ${D.me.home}. ${free ? `You have ${free} free fleet slot${free > 1 ? 's' : ''}.` : 'All fleet slots are full, so buy a slot first.'} Only aircraft you can fly in a simulator are listed.</p></div>
  <div class="card" style="min-width:min(280px,100%)"><div class="hd"><b>Fleet slot ${D.me.slots + 1}</b><span class="price">${kmoney(slotCost)}</span></div><button type="button" class="btn pri" data-act="buyslot" ${cash < slotCost ? 'disabled' : ''}>Buy slot</button></div></div>
  <div class="bands" role="tablist">${[['all', 'All aircraft'], ...SHOP_CATS].map(([k, l]) => `<button type="button" class="chip" role="tab" data-act="shopcat" data-k="${k}" aria-pressed="${UI.shopCat === k}">${l} · ${avail.filter(t => k === 'all' || t.category === k).length}</button>`).join('')}</div>
  ${mySim !== 'any' ? `<label class="check" style="display:inline-flex;margin:4px 0 10px"><input type="checkbox" data-act="shopsims" ${simOnly ? 'checked' : ''}> Only aircraft available in ${SIM_NAMES[mySim]}${hiddenN ? ` (${hiddenN} more in other sims)` : ''}</label>` : `<p class="hint" style="margin:4px 0 10px">Set your simulator on the <a href="#profile" data-tab="profile">Profile</a> page to list only aircraft you can fly.</p>`}
  ${cats.map(([k, l]) => { const list = avail.filter(t => t.category === k).sort((a, b) => a.price_new - b.price_new); if (!list.length) return ''; const lo = Math.min(...list.map(t => acValue(t, modelYears(t).slice(-1)[0]))), hi = Math.max(...list.map(t => t.price_new));
    return `<div class="shopcat"><div class="shopcathd"><h3>${l}</h3><span class="muted mono">${list.length} type${list.length > 1 ? 's' : ''} · used from ${bigMoney(lo)} · new up to ${bigMoney(hi)}</span></div><div class="cards">${list.map(card).join('')}</div></div>` }).join('') || '<div class="panel empty">No aircraft match. Untick the simulator filter to see the rest.</div>'}</div>
 ${crewShopSection(cands)}
 <div class="section"><div class="sechead"><div><h2>Company upgrades</h2><p>Permanent improvements to how your desk wins and runs work.</p></div></div>
 <div class="cards">${Object.entries(UPG).map(([k, u]) => { const l = upg(k), c = u.cost[l]; return `<div class="card"><div class="hd"><b>${u.name}</b><div class="pips">${u.cost.map((_, i) => `<i class="${i < l ? 'on' : ''}"></i>`).join('')}</div></div><p>${u.desc}</p>
  <div class="foot">${l >= u.cost.length ? '<span class="tag won">Maxed</span>' : `<span class="price">${kmoney(c)}</span><button type="button" class="btn ${cash >= c ? 'pri' : ''}" data-act="upg" data-k="${k}" ${cash < c ? 'disabled' : ''}>Level ${l + 1}</button>`}</div></div>` }).join('')}</div></div>`;
}


/* ---------- crew ---------- */
const CREW_RATES = { piston: [5500, 6000, 2000], turboprop: [8000, 20000, 4000], light: [11000, 35000, 6000], mid: [14000, 50000, 8000], large: [19000, 75000, 12000] };
const CAT_RANK = { piston: 0, turboprop: 1, light: 2, mid: 3, large: 4 };
const roleName = r => r === 'fo' ? 'First officer' : 'Captain';
const crewTraining = (role, cat) => Math.round(CREW_RATES[cat][1] * (role === 'fo' ? 0.8 : 1));
const daysTo = v => Math.ceil((ts(v) - Date.now()) / 864e5);
const dueText = v => { const d = daysTo(v); return d < 0 ? `<span class="neg">overdue ${-d}d</span>` : d <= 14 ? `<span class="warn">in ${d}d</span>` : `in ${d}d` };
function crewState(c) {
  const now = Date.now();
  if (c.status === 'training') return `In type training until ${fmtDate(c.trained_at)}`;
  if (c.notice_until) return `<span class="neg">On notice until ${fmtDate(c.notice_until)}</span>`;
  if (c.busy_until && ts(c.busy_until) > now) return `In a check until ${fmtDate(c.busy_until)}`;
  if (ts(c.opc_due) < now || ts(c.recurrent_due) < now) return '<span class="neg">Grounded: check overdue</span>';
  const leg = D.legs.find(l => l.status === 'flying' && l.aircraft_id === c.aircraft_id && c.aircraft_id);
  if (leg) return `Flying ${leg.from_icao} → ${leg.to_icao}`;
  return c.aircraft_id ? 'Ready' : 'Ready · not assigned';
}
function opsLine(a) {
  const t = typeOf(a), mine = D.crew.filter(c => c.aircraft_id === a.id), leg = D.legs.find(l => l.status === 'flying' && l.aircraft_id === a.id);
  const ready = mine.filter(c => c.status === 'active' && !c.notice_until && ts(c.opc_due) > Date.now() && ts(c.recurrent_due) > Date.now() && (!c.busy_until || ts(c.busy_until) <= Date.now()));
  if (a.ops !== 'crew') return 'You fly this aircraft';
  if (leg) return `Crew flight ${leg.from_icao} → ${leg.to_icao} for ${esc(leg.client)}, lands ${fmtDep(leg.arr_at, leg.to_icao)} · earns about ${kmoney(leg.revenue - leg.cost)}`;
  if (ready.length < t.crew_req || !ready.some(c => c.role === 'captain')) return `<span class="warn">Waiting for crew: needs ${t.crew_req} ready pilot${t.crew_req > 1 ? 's' : ''} including a captain</span>`;
  return a.crew_busy_until && ts(a.crew_busy_until) > Date.now() ? `On the ground at ${a.loc}; brokers expect the next job around ${fmtDep(a.crew_busy_until, a.loc)}` : `Looking for the next job at ${a.loc}`;
}
function renderCrew() {
  const legsDone = D.legs.filter(l => l.status === 'done');
  const monthly = D.crew.reduce((x, c) => x + +c.salary, 0);
  $('#main').innerHTML = `<div class="section"><div class="sechead"><div><h2>Crew operations</h2><p>Hand an aircraft to your crew and they fly charters on their own, in real time, while you're away. Brokers keep 15%. You can't quote with a crew-operated aircraft; take it back here when you want to fly it yourself.</p></div><a class="btn pri" href="#shop" data-tab="shop" data-shop="crew">Hire crew</a></div>
  <div class="cards">${D.fleet.map(a => { const t = typeOf(a), mine = D.crew.filter(c => c.aircraft_id === a.id); return `<div class="card ${a.ops === 'crew' ? 'active' : ''}">
    <div class="hd"><b class="mono">${a.reg}</b><span>${a.year} · ${a.type_code}</span></div>
    <p>${esc(t.name)} · at ${a.loc} · ${t.crew_req === 1 ? 'single pilot' : 'two pilots'}</p>
    <p class="opsline">${opsLine(a)}</p>
    <div class="crewlist">${mine.length ? mine.map(c => `<span>${esc(c.name)} · ${c.role === 'fo' ? 'FO' : 'CPT'}</span>`).join('') : '<span class="muted">No crew assigned</span>'}</div>
    <div class="foot">${a.ops === 'crew' ? `<button type="button" class="btn" data-act="ops" data-id="${a.id}" data-mode="pilot">Take back to fly myself</button>` : `<button type="button" class="btn pri" data-act="ops" data-id="${a.id}" data-mode="crew">Let crew fly it</button>`}</div></div>` }).join('')}</div></div>
  <div class="section"><div class="sechead"><div><h2>Your crew</h2><p>${D.crew.length ? `${D.crew.length} pilot${D.crew.length > 1 ? 's' : ''} · ${money(monthly)} a month in salaries. OPCs are due every 6 months and recurrent training every 12; overdue pilots are grounded. Morale falls as the company earns more, so expect requests for pay rises.` : 'Nobody yet. Hire captains and first officers in the Shop.'}</p></div></div>
  ${D.crew.length ? `<div class="panel tablewrap"><table class="grid crewtab"><thead><tr><th>Pilot</th><th>Rating</th><th>Aircraft</th><th>Morale</th><th>Salary / month</th><th>OPC</th><th>Recurrent</th><th>Status</th><th></th></tr></thead><tbody>
  ${D.crew.map(c => { const rated = D.fleet.filter(a => a.type_code === c.type_code), cat = D.types[c.type_code].category, sat = +c.satisfaction;
    return `<tr><td><b>${esc(c.name)}</b><br><span class="hint">${roleName(c.role)} · ${c.experience} yr${c.experience === 1 ? "" : "s"} · ${hm(c.hours)} with you</span></td>
    <td class="n">${c.type_code}</td>
    <td><select class="sel" data-act="assign" data-id="${c.id}" aria-label="Aircraft for ${esc(c.name)}"><option value="">Not assigned</option>${rated.map(a => `<option value="${a.id}" ${a.id === c.aircraft_id ? 'selected' : ''}>${a.reg}</option>`).join('')}</select></td>
    <td><div class="morale"><i style="width:${sat}%;background:${sat >= 60 ? 'var(--ok)' : sat >= 35 ? 'var(--brass-light)' : 'var(--bad)'}"></i></div><span class="hint">${Math.round(sat)}%${c.raise_asked ? ' · <b class="neg">asking for a raise</b>' : ''}</span></td>
    <td class="n">${money(c.salary)} <button type="button" class="linkbtn" data-act="pay" data-id="${c.id}">Change</button></td>
    <td class="n">${dueText(c.opc_due)}<br><button type="button" class="linkbtn" data-act="check" data-kind="opc" data-id="${c.id}">Book · ${kmoney(CREW_RATES[cat][2])}</button></td>
    <td class="n">${dueText(c.recurrent_due)}<br><button type="button" class="linkbtn" data-act="check" data-kind="recurrent" data-id="${c.id}">Book · ${kmoney(CREW_RATES[cat][1] * 0.5)}</button></td>
    <td>${crewState(c)}</td>
    <td><button type="button" class="btn danger" data-act="release" data-id="${c.id}">Let go</button></td></tr>` }).join('')}</tbody></table></div>` : ''}</div>
  ${D.legs.length ? `<div class="section"><h2>Recent crew flights</h2><div class="panel tablewrap"><table class="grid"><thead><tr><th>Aircraft</th><th>Route</th><th>Client</th><th>Departed</th><th>Block</th><th>Net</th><th>Status</th></tr></thead><tbody>
  ${D.legs.map(l => `<tr><td class="n">${l.reg}</td><td class="n">${l.from_icao} → ${l.to_icao}</td><td>${esc(l.client)}</td><td class="n">${fmtDep(l.dep_at, l.from_icao)}</td><td class="n">${hm(l.block_h)}</td><td class="n ${l.revenue - l.cost >= 0 ? 'pos' : 'neg'}">${money(l.revenue - l.cost)}</td><td>${l.status === 'flying' ? `<span class="tag flying">Lands ${fmtDep(l.arr_at, l.to_icao)}</span>` : '<span class="tag accepted">Done</span>'}</td></tr>`).join('')}</tbody></table></div></div>` : ''}`;
}
function crewShopSection(cands) {
  const myCats = [...new Set(D.fleet.map(a => typeOf(a).category))];
  return `<div class="section" id="hire"><div class="sechead"><div><h2>Hire crew</h2><p>Pilots looking for work right now; the list changes through the day. You pay a type rating course when you hire (it takes 12 hours), then a monthly salary. They'll only fly aircraft no bigger than they're used to.</p></div></div>
  ${cands.length ? `<div class="cards">${cands.map(c => { const r = CREW_RATES[c.category], types = [...new Set(D.fleet.map(a => a.type_code))].filter(tc => CAT_RANK[D.types[tc].category] <= CAT_RANK[c.category]);
    return `<div class="card"><div class="hd"><b>${esc(c.name)}</b><span>${roleName(c.role)}</span></div><p>${c.experience} years' experience · used to ${c.category === 'light' ? 'light jets' : c.category === 'mid' ? 'midsize jets' : c.category === 'large' ? 'large jets' : c.category + 's'} · skill ${Math.round(c.skill * 100)}</p>
    <div class="specs"><div><label>Asks</label><span>${money(c.salary_ask)} / month</span></div><div><label>Leaves the market</label><span>${fmtDate(c.expires_at)}</span></div></div>
    <div class="foot">${types.length ? `<select class="sel" id="hireType${c.id}" aria-label="Type rating for ${esc(c.name)}">${types.map(tc => `<option value="${tc}">${tc} · course ${kmoney(crewTraining(c.role, D.types[tc].category))}</option>`).join('')}</select><button type="button" class="btn pri" data-act="hire" data-id="${c.id}">Hire</button>` : '<span class="hint">None of your aircraft suit this pilot.</span>'}</div></div>` }).join('')}</div>` : '<div class="panel empty">Loading candidates…</div>'}</div>`;
}

async function buyBox(code) {
  const t = D.types[code], taken = (await q(sb.from('fleet').select('reg').limit(10000)).catch(() => [])).map(x => x.reg);
  const yrs = modelYears(t), y0 = yrs.find(y => acAge(y) >= 8) ?? yrs[yrs.length - 1];
  $('#modal').innerHTML = `<div class="scrim" data-act="scrim"><form class="modal" id="buyForm" role="dialog" aria-modal="true" aria-label="Buy ${esc(t.name)}">
   <div><h3>${esc(t.cls)}</h3><div class="route">${esc(t.name)}</div></div>
   <div class="row2"><div class="field"><label for="byYear">Model year</label><select id="byYear">${yrs.map(y => `<option value="${y}" ${y === y0 ? 'selected' : ''}>${y}${acAge(y) === 0 ? ' · new' : acAge(y) === 1 ? ' · 1 year old' : ` · ${acAge(y)} years old`}</option>`).join('')}</select></div>
   <div class="field"><label for="byReg">Registration</label><input id="byReg" maxlength="9" value="${suggestReg(D.airports[D.me.home]?.country, D.me.prefix, taken)}" autocomplete="off" style="text-transform:uppercase"><span class="hint" id="byRegHint"></span></div></div>
   <div class="grid4"><div class="kv"><label>Price</label><span id="byPrice"></span></div><div class="kv"><label>Charter rate</label><span id="byRate"></span></div><div class="kv"><label>Running cost</label><span>${kmoney(opRate(t))}/h</span></div><div class="kv"><label>Your cash</label><span>${money(D.me.cash)}</span></div></div>
   <div class="field"><label>Payment</label>
    <label class="check pay"><input type="radio" name="byPay" value="cash" id="byCash"> <span>Pay in full · <b id="byFull"></b></span></label>
    <label class="check pay"><input type="radio" name="byPay" value="finance" id="byFin" checked> <span>Finance · <b id="byDep"></b> deposit, then <b id="byMonthly"></b> a month for 15 years</span></label></div>
   <div class="err" id="byErr"></div>
   <div class="btns" style="justify-content:flex-end"><button type="button" class="btn" data-act="close">Cancel</button><button type="submit" class="btn pri" id="byGo">Buy aircraft</button></div></form></div>`;
  const upd = () => {
    const y = +$('#byYear').value, v = acValue(t, y), dep = Math.round(v * 0.15), fin = $('#byFin').checked;
    $('#byPrice').textContent = bigMoney(v); $('#byRate').textContent = `${kmoney(t.rate * rmul(y))}/h`;
    $('#byFull').textContent = money(v); $('#byDep').textContent = money(dep); $('#byMonthly').textContent = money(loanMonthly(v - dep, 15));
    const need = fin ? dep : v, r = $('#byReg').value.trim().toUpperCase(), regOk = REG_RE.test(r) && !taken.includes(r);
    $('#byRegHint').textContent = taken.includes(r) ? 'Already used in the VA.' : regOk ? '' : 'Use a country prefix and dash (G-ABCD) or an N-number (N123AB).';
    $('#byRegHint').className = 'hint ' + (regOk ? '' : 'bad');
    $('#byErr').textContent = D.me.cash < need ? `You need ${money(need)} for this option.` : '';
    $('#byGo').disabled = D.me.cash < need || !regOk;
  };
  $('#buyForm').oninput = upd; upd();
  $('#buyForm').onsubmit = async e => {
    e.preventDefault();
    const y = +$('#byYear').value, reg = $('#byReg').value.trim().toUpperCase();
    try { await rpc('purchase_aircraft', { p_type: code, p_year: y, p_reg: reg, p_finance: $('#byFin').checked }); closeModal(); toast(`${y} ${t.name} ${reg} delivered to ${D.me.home}.`, 'ok'); await afterChange() }
    catch (err) { $('#byErr').textContent = err.message }
  };
}

async function renderLedger() {
  const rows = await q(sb.from('ledger').select('*').eq('pilot_id', D.uid).order('id', { ascending: false }).limit(150));
  const flown = await q(sb.from('pireps').select('block_h,dist_flown,revenue').eq('pilot_id', D.uid).eq('status', 'accepted').limit(5000));
  const sum = (a, k) => a.reduce((s, x) => s + (+x[k] || 0), 0);
  $('#main').innerHTML = `<div class="section"><h2>Ledger</h2>
 <div class="stats">${[['Balance', money(D.me.cash)], ['Flights flown', flown.length], ['Block hours', hm(sum(flown, 'block_h'))], ['Distance flown', dist(sum(flown, 'dist_flown'))], ['Revenue', money(sum(flown, 'revenue'))], ['Reputation', Math.round(D.me.rep)]].map(([l, v]) => `<div class="panel kv"><label>${l}</label><span style="font-size:18px">${v}</span></div>`).join('')}</div>
 <div class="panel tablewrap"><table class="ledger"><tbody>${rows.map(e => `<tr><td class="t">${fmtDate(e.at)}</td><td>${esc(e.text)}</td><td class="a" style="color:${e.amount >= 0 ? 'var(--ok)' : 'var(--bad)'}">${e.amount ? money(e.amount) : ''}</td></tr>`).join('')}</tbody></table></div></div>`;
}


/* ---------- flight planning ---------- */
let REGION_NAMES = null; try { REGION_NAMES = new Intl.DisplayNames(['en'], { type: 'region' }) } catch (e) { }
const countryName = c => { try { return (REGION_NAMES && c && REGION_NAMES.of(c)) || c || 'unknown' } catch (e) { return c } };
const briefLine = b => [b.catering, b.drinks, ...(b.dietary || []), ...(b.requests || [])].filter(Boolean).join('; ');
function planChips(trip) {
  const chips = [];
  if (trip.customs_needed) chips.push(trip.customs_sent_at ? '<span class="tag accepted">Customs filed</span>' : '<span class="tag pending">Customs not filed</span>');
  chips.push(trip.ofp ? '<span class="tag accepted">OFP issued</span>' : '<span class="tag ferry">No OFP yet</span>');
  return `<div class="chips">${chips.join('')}</div>`;
}
const EXTRA_MIN = [0, 15, 30, 45, 60, 90];
function simbriefUrl(trip, extraLb) {
  const ac = acById(trip.aircraft_id), p = plan(trip), kg = pref('weight') === 'kg';
  const fltNum = (trip.flt.split(' ')[1] || '').replace(/\D/g, '');
  const b = trip.brief, rmk = b ? `CHARTER ${trip.client || ''}. ${briefLine(b)}`.toUpperCase().replace(/[^A-Z0-9 .,;:'\/-]/g, '').slice(0, 230) : (trip.kind === 'ferry' ? 'POSITIONING FLIGHT' : '');
  const q = new URLSearchParams({ type: ac.type_code, orig: trip.from_icao, dest: trip.to_icao, altn: p.alt, airline: D.me.prefix, fltnum: fltNum,
    reg: ac.reg, pax: String(trip.pax), fl: String(p.fl * 100), units: kg ? 'KGS' : 'LBS', manualrmk: rmk });
  if (extraLb > 0) { q.set('addedfuel', String(Math.round(kg ? extraLb * 0.453592 : extraLb))); q.set('addedfuel_units', 'wgt') }
  return 'https://dispatch.simbrief.com/options/custom?' + q.toString();
}
function renderPlanner(trip) {
  const ac = acById(trip.aircraft_id), t = typeOf(ac), p = plan(trip), A = D.airports[trip.from_icao], B = D.airports[trip.to_icao], b = trip.brief;
  UI.extraMin ??= trip.extra_fuel_min ?? 0;
  const extraLb = Math.round(t.burn * UI.extraMin / 60), blockLb = p.block + extraLb, fob = ac.fuel_lb != null ? +ac.fuel_lb : null;
  const o = trip.ofp, kgOfp = o && /kg/i.test(o.units || '');
  const ofpWt = v => v == null || v === '' ? '—' : `${Math.round(+v).toLocaleString('en-US')} ${kgOfp ? 'kg' : 'lb'}`;
  $('#main').innerHTML = `<div class="section"><div class="sechead"><div><button type="button" class="linkbtn" data-act="planclose">← All trips</button>
   <h2 style="margin-top:6px">${trip.flt} · ${trip.from_icao} to ${trip.to_icao}</h2><p>${esc(A?.city)} to ${esc(B?.city)} · ${ac.reg} ${esc(t.name)} · ${trip.kind === 'ferry' ? `arrive ${trip.to_icao} by ${fmtDep(trip.dep_at, trip.to_icao)}` : `departs ${fmtDep(trip.dep_at, trip.from_icao)}`} · ${trip.kind === 'ferry' ? 'positioning, no passengers' : `${trip.pax} passenger${trip.pax > 1 ? 's' : ''}`}</p></div>${planChips(trip)}</div>
  <div class="planner">
   <div class="pcol">
    ${b ? `<div class="panel brief"><h3>Client brief</h3><p class="from">From ${esc(b.from)}</p>
      <p>Hello, confirming ${b.pax} passenger${b.pax > 1 ? 's' : ''} for ${fmtDep(trip.dep_at, trip.from_icao)}. Catering: ${esc(b.catering)}. Drinks: ${esc(b.drinks)}.</p>
      ${(b.dietary || []).length ? `<p><b>Dietary:</b> ${b.dietary.map(esc).join('; ')}.</p>` : ''}
      ${(b.requests || []).length ? `<p><b>Also, please arrange:</b></p><ul>${b.requests.map(x => `<li>${esc(x)}</li>`).join('')}</ul>` : ''}
      <p>${esc(b.signoff)}</p></div>` : `<div class="panel brief"><h3>Positioning flight</h3><p>No passengers and no catering. Get the aircraft to ${trip.to_icao} for the next job.</p></div>`}

    <div class="panel"><h3>Customs</h3>${trip.customs_needed ? (trip.customs_sent_at
      ? `<p class="okline">Declaration filed ${fmtDate(trip.customs_sent_at)}. You're clear to leave.</p>`
      : `<p>This flight leaves ${esc(countryName(A?.country))} for ${esc(countryName(B?.country))}. File the general declaration before you block off, or you'll be fined ${money(2500)} on arrival.</p><button type="button" class="btn pri" data-act="customs" data-id="${trip.id}">File customs declaration</button>`)
      : `<p class="muted">Domestic flight within ${esc(countryName(A?.country))}. No declaration needed.</p>`}</div>

    <div class="panel"><h3>Fuel</h3>
     <div class="grid4">
      <div class="kv"><label>On board now</label><span>${fob == null ? 'Not known yet' : wt(fob)}</span></div>
      <div class="kv"><label>Trip + taxi</label><span>${wt(p.tripFuel + p.taxi)}</span></div>
      <div class="kv"><label>Alternate + reserve</label><span>${wt(p.altFuel + p.res)}</span></div>
      <div class="kv"><label>Planned block fuel</label><span>${wt(blockLb)}</span></div></div>
     <p class="hint" style="margin:10px 0 6px">${fob == null ? 'Fuel on board is recorded by the tracker when this aircraft parks after a flight.' : `Recorded by the tracker when ${ac.reg} parked after its last flight. ${fob >= blockLb ? 'Enough on board already.' : `Uplift about ${wt(blockLb - fob)}.`}`}</p>
     <div class="field"><label>Extra fuel</label><div class="bands">${EXTRA_MIN.map(m => `<button type="button" class="chip" data-act="extra" data-m="${m}" aria-pressed="${UI.extraMin === m}">${m ? `+${m} min · ${wt(Math.round(t.burn * m / 60))}` : 'None'}</button>`).join('')}</div></div></div>

    <div class="panel"><h3>Operational flight plan</h3>
     ${D.me.simbrief_user ? `<p>SimBrief account: <b>${esc(D.me.simbrief_user)}</b> <button type="button" class="linkbtn" data-act="sbchange">change</button></p>` :
      `<form id="sbForm" class="row2" style="align-items:end"><div class="field"><label for="sbUser">Your SimBrief (Navigraph) username</label><input id="sbUser" autocomplete="off" placeholder="as shown in SimBrief account settings"></div><button type="submit" class="btn">Link SimBrief</button></form>`}
     <ol class="steps" style="margin:10px 0">
      <li>Generate the plan in SimBrief. It opens with this trip, the alternate, cruise level, passengers${extraLb ? `, ${wt(extraLb)} extra fuel` : ''} and the client's requests in the remarks.</li>
      <li>Come back here and fetch it to issue the OFP.</li></ol>
     <div class="btns"><a class="btn pri" href="${simbriefUrl(trip, extraLb)}" target="_blank" rel="noopener">Generate in SimBrief ↗</a>
      <button type="button" class="btn" data-act="fetchofp" data-id="${trip.id}" ${D.me.simbrief_user ? '' : 'disabled title="Link your SimBrief username first"'}>Fetch my OFP</button></div>
     <div class="err" id="ofpErr"></div>
     ${o ? `<div class="ofp"><div class="ofphd"><b>OFP ${esc(o.callsign || trip.flt)}</b><span>Issued ${fmtDate(o.saved_at || o.generated)}</span></div>
      <div class="grid4"><div class="kv"><label>Cruise</label><span>${esc(o.fl || '—')}</span></div><div class="kv"><label>Time en route</label><span>${o.ete ? hm(o.ete / 3600) : '—'}</span></div>
       <div class="kv"><label>Ramp fuel</label><span>${ofpWt(o.ramp)}</span></div><div class="kv"><label>Extra fuel</label><span>${ofpWt(o.extra)}</span></div>
       <div class="kv"><label>Landing fuel</label><span>${ofpWt(o.landing)}</span></div><div class="kv"><label>Alternate</label><span>${esc(o.altn || '—')}</span></div>
       <div class="kv"><label>Distance</label><span>${o.dist ? o.dist + ' nm' : '—'}</span></div><div class="kv"><label>Airframe</label><span>${esc(o.type || ac.type_code)}</span></div></div>
      <p class="route-str mono">${esc(o.route || '')}</p>
      ${o.pdf ? `<a class="btn" href="${esc(o.pdf)}" target="_blank" rel="noopener">Open full OFP (PDF) ↗</a>` : ''}</div>` : ''}
    </div>
   </div>
   <div class="gcol"><div class="globebox"><canvas id="globe" aria-label="Route on the globe from ${trip.from_icao} to ${trip.to_icao}"></canvas>
    <div class="globetools"><button type="button" class="btn" data-act="gzoom" data-z="-1" aria-label="Zoom out">−</button><button type="button" class="btn" data-act="gzoom" data-z="0">Whole globe</button><button type="button" class="btn" data-act="gzoom" data-z="1" aria-label="Zoom in">+</button></div>
    <p class="hint">Drag to turn the globe.</p></div></div>
  </div></div>`;
  if ($('#sbForm')) $('#sbForm').onsubmit = async e => { e.preventDefault(); await act(() => rpc('set_simbrief', { p_user: $('#sbUser').value }), 'SimBrief linked.') };
  drawGlobe($('#globe'), trip, o);
}

let LAND = null, BORDERS = null; const GLOBE = {};
async function landShapes() {
  if (LAND) return LAND;
  if (!window.d3 || !window.topojson) return null;
  try {
    const w = await fetch('https://cdn.jsdelivr.net/npm/world-atlas@2.0.2/countries-50m.json').then(r => r.json());
    LAND = topojson.merge ? topojson.merge(w, w.objects.countries.geometries) : topojson.feature(w, w.objects.land);
    BORDERS = topojson.mesh ? topojson.mesh(w, w.objects.countries, (x, y) => x !== y) : null;
  } catch (e) { LAND = null }
  return LAND;
}
async function drawGlobe(cv, trip, ofp) {
  if (!cv || !window.d3) { if (cv) cv.parentElement.innerHTML = '<p class="hint">The globe needs an internet connection to load.</p>'; return }
  const A = D.airports[trip.from_icao], B = D.airports[trip.to_icao], AL = D.airports[plan(trip).alt];
  const box = cv.parentElement.getBoundingClientRect(), W = Math.max(280, box.width), H = Math.min(560, Math.max(320, W)), dpr = window.devicePixelRatio || 1;
  cv.width = W * dpr; cv.height = H * dpr; cv.style.height = H + 'px';
  const c = cv.getContext('2d'); c.setTransform(dpr, 0, 0, dpr, 0, 0);
  const route = { type: 'LineString', coordinates: [[A.lon, A.lat], [B.lon, B.lat]] };
  const mid = d3.geoInterpolate([A.lon, A.lat], [B.lon, B.lat])(0.5);
  const proj = d3.geoOrthographic().rotate([-mid[0], -mid[1]]).translate([W / 2, H / 2]).clipAngle(90);
  const span = d3.geoDistance([A.lon, A.lat], [B.lon, B.lat]);
  const base = Math.min(W, H) / 2 * 0.92;
  UI.globeZoom ??= 1;
  proj.scale(base * UI.globeZoom);
  GLOBE.redraw = () => { proj.scale(base * UI.globeZoom); draw() };
  GLOBE.fit = () => Math.min(8, Math.max(1, 1.1 / Math.max(span, 0.03)));
  const path = d3.geoPath(proj, c), land = await landShapes(), grat = d3.geoGraticule10();
  const draw = () => {
    c.clearRect(0, 0, W, H);
    c.beginPath(); path({ type: 'Sphere' }); c.fillStyle = cssv('--map-sea'); c.fill();
    c.beginPath(); path(grat); c.strokeStyle = cssv('--map-grid'); c.lineWidth = 1; c.stroke();
    if (land) { c.beginPath(); path(land); c.fillStyle = cssv('--map-land'); c.fill(); c.strokeStyle = cssv('--map-land-edge'); c.lineWidth = .6; c.stroke() }
    if (BORDERS) { c.beginPath(); path(BORDERS); c.strokeStyle = cssv('--map-border'); c.lineWidth = .5; c.stroke() }
    if (AL) { c.beginPath(); path({ type: 'LineString', coordinates: [[B.lon, B.lat], [AL.lon, AL.lat]] }); c.setLineDash([3, 4]); c.strokeStyle = cssv('--map-muted'); c.lineWidth = 1.2; c.stroke(); c.setLineDash([]) }
    c.beginPath(); path(route); c.strokeStyle = trip.kind === 'ferry' ? '#B88A3A' : cssv('--map-route'); c.lineWidth = 3; c.stroke();
    const dot = (a, label, col, r) => { const p = proj([a.lon, a.lat]); if (!p || d3.geoDistance([a.lon, a.lat], proj.invert([W / 2, H / 2])) > Math.PI / 2) return;
      c.beginPath(); c.arc(p[0], p[1], r, 0, 7); c.fillStyle = col; c.fill(); c.strokeStyle = '#fff'; c.lineWidth = 1.5; c.stroke();
      c.font = '600 12px "DM Mono", monospace'; c.fillStyle = cssv('--map-label'); c.fillText(label, p[0] + 8, p[1] - 8) };
    if (AL) { const pa = proj([AL.lon, AL.lat]), pb = proj([B.lon, B.lat]), near = pa && pb && Math.hypot(pa[0] - pb[0], pa[1] - pb[1]) < 60; dot(AL, near ? '' : AL.icao + ' ALT', cssv('--map-muted'), 3) }
    dot(A, A.icao, cssv('--map-mark'), 5); dot(B, B.icao, cssv('--map-mark'), 5);
    c.beginPath(); path({ type: 'Sphere' }); c.strokeStyle = cssv('--map-land-edge'); c.lineWidth = 1; c.stroke();
  };
  draw();
  let drag = null;
  cv.onpointerdown = e => { drag = { x: e.clientX, y: e.clientY, r: proj.rotate() }; cv.setPointerCapture(e.pointerId) };
  cv.onpointermove = e => { if (!drag) return; const k = 75 / proj.scale() * 4; proj.rotate([drag.r[0] + (e.clientX - drag.x) * k, Math.max(-90, Math.min(90, drag.r[1] - (e.clientY - drag.y) * k))]); draw() };
  cv.onpointerup = cv.onpointercancel = () => { drag = null };
}
async function fetchOfp(tripId) {
  const trip = D.trips.find(t => t.id === tripId), user = D.me.simbrief_user;
  $('#ofpErr').textContent = 'Fetching your latest SimBrief plan…';
  let j;
  try {
    const r = await fetch(`https://www.simbrief.com/api/xml.fetcher.php?username=${encodeURIComponent(user)}&json=1`);
    if (!r.ok) throw new Error(r.status === 400 ? `SimBrief doesn't recognise the username ${user}, or it has no plans yet.` : `SimBrief returned an error (${r.status}).`);
    j = await r.json();
  } catch (e) { $('#ofpErr').textContent = e.message.includes('Failed to fetch') ? 'Couldn\'t reach SimBrief. Check your connection and try again.' : e.message; return }
  const g = (o, ...k) => k.reduce((x, y) => x == null ? x : x[y], o);
  const ofp = { orig: g(j, 'origin', 'icao_code'), dest: g(j, 'destination', 'icao_code'), altn: g(j, 'alternate', 'icao_code'), route: g(j, 'general', 'route'),
    fl: g(j, 'general', 'initial_altitude') ? 'FL' + String(Math.round(+g(j, 'general', 'initial_altitude') / 100)).padStart(3, '0') : null,
    ramp: g(j, 'fuel', 'plan_ramp'), extra: g(j, 'fuel', 'extra'), landing: g(j, 'fuel', 'plan_landing'), units: g(j, 'params', 'units'),
    ete: +g(j, 'times', 'est_time_enroute') || null, dist: +g(j, 'general', 'route_distance') || null, type: g(j, 'aircraft', 'icaocode'),
    callsign: g(j, 'atc', 'callsign'), generated: g(j, 'params', 'time_generated') ? new Date(+g(j, 'params', 'time_generated') * 1000).toISOString() : null,
    pdf: g(j, 'files', 'directory') && g(j, 'files', 'pdf', 'link') ? g(j, 'files', 'directory') + g(j, 'files', 'pdf', 'link') : null };
  try { await rpc('save_ofp', { p_trip: tripId, p_ofp: ofp, p_extra_min: UI.extraMin || 0 }); toast(`OFP issued for ${trip.flt}.`, 'ok'); await afterChange() }
  catch (e) { $('#ofpErr').textContent = e.message }
}

/* ---------- live map ---------- */
const planeSvg = (hdg, col) => `<svg width="26" height="26" viewBox="0 0 24 24" style="transform:rotate(${hdg}deg)"><path fill="${col}" stroke="#FFFFFF" stroke-width=".8" d="M12 2c.8 0 1.3.9 1.3 2v5.2l7.7 4.6v2l-7.7-2.3v4.6l2.2 1.7V21L12 20.1 8.5 21v-1.2l2.2-1.7v-4.6L3 15.8v-2l7.7-4.6V4c0-1.1.5-2 1.3-2z"/></svg>`;
async function renderLive() {
  $('#main').innerHTML = `<div class="section"><div class="sechead"><div><h2>Live map</h2><p id="liveNote">Pilots flying with the tracker right now. Updates every 15 seconds.</p></div></div><div id="livemap"></div></div>`;
  liveMap = L.map('livemap', { worldCopyJump: true }).setView([48, 4], 4);
  L.tileLayer(tileUrl(), { attribution: '&copy; OpenStreetMap contributors &copy; CARTO', subdomains: 'abcd', maxZoom: 12 }).addTo(liveMap);
  liveLayer = L.layerGroup().addTo(liveMap);
  await refreshLive(true);
}
async function refreshLive(fit) {
  if (UI.tab !== 'live' || !liveMap) return;
  const rows = await q(sb.from('positions').select('*, pilots(callsign,company), trips(flt,from_icao,to_icao)'));
  liveLayer.clearLayers();
  const bounds = [];
  rows.forEach(p => {
    const t = p.trips, A = t && D.airports[t.from_icao], B = t && D.airports[t.to_icao];
    if (A && B) L.polyline([[A.lat, A.lon], [p.lat, p.lon], [B.lat, B.lon]], { color: '#8A6526', weight: 1.5, opacity: .7, dashArray: '4 4' }).addTo(liveLayer);
    L.marker([p.lat, p.lon], { icon: L.divIcon({ className: 'plane-icon', html: planeSvg(p.hdg || 0, p.pilot_id === D.uid ? '#D4B06A' : (isDark() ? '#E7ECF3' : '#0E1A2B')), iconSize: [26, 26], iconAnchor: [13, 13] }) })
      .bindPopup(`<b>${esc(p.pilots?.callsign)}</b> · ${esc(p.pilots?.company)}<br>${t ? `${esc(t.flt)} ${t.from_icao} → ${t.to_icao}<br>` : ''}<span class="mono">${(p.alt || 0).toLocaleString()} ft · ${p.gs || 0} kt · ${esc(p.phase || '')}</span>`).addTo(liveLayer);
    bounds.push([p.lat, p.lon]);
  });
  $('#liveNote').textContent = rows.length ? `${rows.length} pilot${rows.length > 1 ? 's' : ''} flying now. Updates every 15 seconds.` : 'Nobody is flying right now. Aircraft appear here when a pilot starts the tracker.';
  if (fit && bounds.length) liveMap.fitBounds(bounds, { padding: [60, 60], maxZoom: 7 });
}
setInterval(() => refreshLive(false).catch(() => { }), 15000);

/* ---------- reports and pilots ---------- */
async function renderReports() {
  const [rows, mine] = await Promise.all([
    q(sb.from('pireps').select('id,status,landing_fpm,block_h,net,created_at,arr_icao,landing_score,comfort_score,points,trips(flt,from_icao,to_icao,kind),pilots(callsign)').order('id', { ascending: false }).limit(60)),
    q(sb.from('pireps').select('landing_fpm,landing_g,block_h,air_h,landing_score,comfort_score,points,status,stats').eq('pilot_id', D.uid).limit(5000)).then(r => r.filter(x => x.status !== 'rejected'))]);
  const acc = mine.filter(r => r.status === 'accepted'), avg = (xs) => xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null;
  const fpms = mine.map(r => r.landing_fpm).filter(v => v != null), ls = mine.map(r => r.landing_score).filter(v => v != null), cs = mine.map(r => r.comfort_score).filter(v => v != null);
  const cls = mine.map(r => r.stats?.touchdown?.cl_m).filter(v => v != null).map(Math.abs);
  const best = fpms.length ? Math.min(...fpms.filter(v => v >= 30).concat(fpms.length && fpms.every(v => v < 30) ? fpms : [])) : null;
  const tile = (l, v, sub) => `<div class="kv"><label>${l}</label><span>${v}</span>${sub ? `<small class="muted">${sub}</small>` : ''}</div>`;
  $('#main').innerHTML = `<div class="section"><div class="sechead"><div><h2>Your flying</h2><p>From your filed reports. Points come from landing and comfort scores, added when a report is accepted.</p></div></div>
  <div class="panel stats mystats">
   ${tile('Points', (D.me.points || 0).toLocaleString('en-US'), `${acc.length} accepted flight${acc.length === 1 ? '' : 's'}`)}
   ${tile('Hours', hm(mine.reduce((a, r) => a + (+r.block_h || 0), 0)), `air ${hm(mine.reduce((a, r) => a + (+r.air_h || 0), 0))}`)}
   ${tile('Average landing', fpms.length ? Math.round(avg(fpms)) + ' fpm' : '—', best != null ? `best ${best} fpm` : '')}
   ${tile('Landing score', ls.length ? Math.round(avg(ls)) : '—', ls.length ? `${ls.filter(v => v >= 90).length} greasers (90+)` : 'from tracker 0.3')}
   ${tile('Comfort score', cs.length ? Math.round(avg(cs)) : '—', cs.length ? `${cs.filter(v => v >= 90).length} smooth flights` : 'from tracker 0.3')}
   ${tile('Centreline', cls.length ? avg(cls).toFixed(1) + ' m' : '—', cls.length ? 'average at touchdown' : 'needs runway data')}
  </div></div>
  <div class="section"><div class="sechead"><div><h2>Flight reports</h2><p>The latest flights across the VA. Select one for the full report: times, landing analysis, comfort and track.</p></div></div>
  <div class="panel tablewrap"><table class="grid"><thead><tr><th>Filed</th><th>Pilot</th><th>Flight</th><th>Route</th><th>Block</th><th>Landing</th><th>Scores</th><th>Points</th><th>Status</th></tr></thead><tbody>
  ${rows.length ? rows.map(p => `<tr class="click" data-act="pirep" data-id="${p.id}"><td class="n">${fmtDate(p.created_at)}</td><td class="n">${esc(p.pilots?.callsign)}</td><td class="n">${esc(p.trips?.flt)}${p.trips?.kind === 'ferry' ? ' <span class="tag ferry">Pos</span>' : ''}</td><td class="n">${p.trips?.from_icao} → ${p.arr_icao}</td><td class="n">${hm(p.block_h)}</td><td class="n">${p.landing_fpm ?? '—'} fpm</td><td class="n">${scoreChip(p.landing_score, 'L')} ${scoreChip(p.comfort_score, 'C')}</td><td class="n">${p.points != null ? p.points : '—'}</td><td><span class="tag ${p.status}">${p.status}</span></td></tr>`).join('') : '<tr><td colspan="9" class="muted">No flights filed yet.</td></tr>'}
  </tbody></table></div></div>`;
}
const scoreClass = v => v == null ? '' : v >= 85 ? 'good' : v >= 60 ? 'mid' : 'low';
const scoreChip = (v, l) => v == null ? '<span class="muted">—</span>' : `<span class="score ${scoreClass(v)}" title="${l === 'L' ? 'Landing' : 'Comfort'} score">${l} ${v}</span>`;
const scoreRingHtml = (v, label) => `<div class="ring ${scoreClass(v)}" style="--v:${v ?? 0}"><b>${v ?? '—'}</b><span>${label}</span></div>`;
const zt = v => v ? new Date(v).toISOString().slice(11, 16) + 'Z' : '—';
const mins = m => m == null ? '—' : `${Math.round(m)} min`;
// a plan view of the runway with the touchdown point, the touchdown zone and the centreline offset
function runwaySvg(td) {
  if (!td || !td.length_ft) return '';
  const L = td.length_ft, W = Math.max(60, td.width_ft || 100), sx = 560 / L, h = 54, cy = 40;
  const x = v => 20 + Math.max(-300, Math.min(L + 200, v + (td.disp_ft || 0))) * sx;
  const yOff = m => cy + Math.max(-1.6, Math.min(1.6, (m * 3.28084) / (W / 2))) * (h / 2);
  const tz0 = x(500), tz1 = x(2500);
  return `<svg class="rwy" viewBox="0 0 600 84" role="img" aria-label="Runway ${esc(td.runway)} plan view with the touchdown point">
   <rect x="20" y="${cy - h / 2}" width="${L * sx}" height="${h}" rx="3" class="rwy-surf"/>
   ${td.disp_ft ? `<rect x="20" y="${cy - h / 2}" width="${td.disp_ft * sx}" height="${h}" class="rwy-disp"/>` : ''}
   <rect x="${tz0}" y="${cy - h / 2}" width="${Math.max(0, tz1 - tz0)}" height="${h}" class="rwy-tdz"/>
   <line x1="22" x2="${20 + L * sx - 2}" y1="${cy}" y2="${cy}" class="rwy-cl"/>
   ${td.cl_max_m != null ? `<rect x="${x(td.td_ft)}" y="${yOff(-td.cl_max_m)}" width="${Math.min(150, Math.max(4, (td.remaining_ft || 0) * sx * 0.25))}" height="${Math.max(1, yOff(td.cl_max_m) - yOff(-td.cl_max_m))}" class="rwy-band"/>` : ''}
   <circle cx="${x(td.td_ft)}" cy="${yOff(-(td.cl_m || 0))}" r="5.5" class="rwy-td"/>
   <text x="22" y="80" class="rwy-t">${esc(td.runway)}</text><text x="${20 + L * sx}" y="80" text-anchor="end" class="rwy-t">${esc(td.opposite || '')}</text>
   <text x="${(tz0 + tz1) / 2}" y="10" text-anchor="middle" class="rwy-t">touchdown zone</text></svg>`;
}
async function openPirep(id, staff) {
  const p = await q(sb.from('pireps').select('*,trips(flt,from_icao,to_icao,kind,client,price,dist),pilots(callsign,name,company)').eq('id', id).single());
  const t = p.trips || {};
  const checkNames = { departure: 'Departure airport', arrival: 'Arrival airport', aircraft: 'Aircraft type', speed: 'Plausible speed', crash: 'No crash', slew: 'No slew', sim_rate: 'Normal sim rate', overspeed: 'No overspeed below 10,000 ft' };
  const checks = Object.entries(p.checks || {}).map(([k, v]) => `<span class="${v.ok ? 'check-ok' : 'check-bad'}">${v.ok ? '✓' : '✗'} ${checkNames[k] || k}${k === 'departure' || k === 'arrival' ? ` (${dist(v.nm)})` : ''}${k === 'sim_rate' && !v.ok ? ` ×${v.max}` : ''}${k === 'overspeed' && !v.ok ? ` ${v.seconds}s` : ''}</span>`).join('');
  $('#modal').innerHTML = `<div class="scrim" data-act="scrim"><div class="modal" role="dialog" aria-modal="true" aria-label="Flight report" style="width:min(800px,100%)">
  <div><h3 style="margin:0 0 4px">${esc(t.flt)} · ${esc(p.pilots?.callsign)} · ${esc(p.pilots?.company)}</h3><div class="route">${t.from_icao}<i>▸</i>${p.arr_icao}${p.arr_icao !== t.to_icao ? ` <span class="muted" style="font-size:14px">planned ${t.to_icao}</span>` : ''}</div>
  <div class="muted" style="font-size:13px">${esc(p.sim || '')} · ${esc(p.aircraft_title || '')} · <span class="tag ${p.status}">${p.status}</span></div></div>
  <div class="pmap" id="pmap"></div>
  ${scorecard(p)}
  <h4 class="rh">Times</h4>
  <div class="grid4">
   <div class="kv"><label>Block off</label><span>${zt(p.block_off)}</span></div>
   <div class="kv"><label>Takeoff</label><span>${zt(p.takeoff)}</span></div>
   <div class="kv"><label>Landing</label><span>${zt(p.landing)}</span></div>
   <div class="kv"><label>Block on</label><span>${zt(p.block_on)}</span></div>
   <div class="kv"><label>Block time</label><span>${hm(p.block_h)}</span></div>
   <div class="kv"><label>Air time</label><span>${p.air_h != null ? hm(p.air_h) : '—'}</span></div>
   <div class="kv"><label>Taxi out / in</label><span>${mins(p.stats?.taxi_out_min)} / ${mins(p.stats?.taxi_in_min)}</span></div>
   <div class="kv"><label>Distance flown</label><span>${dist(p.dist_flown)}</span></div>
   <div class="kv"><label>Highest altitude</label><span>${p.stats?.max_alt_ft ? ft(p.stats.max_alt_ft) : '—'}</span></div>
   <div class="kv"><label>Fuel used</label><span>${wt(p.fuel_used_lb)}</span></div>
   <div class="kv"><label>Fuel on blocks</label><span>${wt(p.fuel_on_block_lb)}</span></div>
   <div class="kv"><label>Net</label><span class="${(p.net || 0) >= 0 ? 'pos' : 'neg'}">${p.net == null ? '—' : money(p.net)}</span></div></div>
  <h4 class="rh">Checks</h4>
  <div class="checks">${checks}</div>
  ${p.review_note ? `<div class="note">${esc(p.review_note)}</div>` : ''}
  ${staff && p.status === 'pending' ? `<div class="field"><label for="rvNote">Note to the pilot</label><input id="rvNote" maxlength="200" placeholder="e.g. Diverted for weather, accepted"></div>
   <div class="btns" style="justify-content:flex-end"><button type="button" class="btn danger" data-act="review" data-id="${p.id}" data-ok="0">Reject</button><button type="button" class="btn pri" data-act="review" data-id="${p.id}" data-ok="1">Accept and pay</button></div>` : `<div class="btns" style="justify-content:flex-end"><button type="button" class="btn" data-act="close">Close</button></div>`}
  </div></div>`;
  const m = L.map('pmap', { attributionControl: true });
  L.tileLayer(tileUrl(), { attribution: '&copy; OpenStreetMap &copy; CARTO', subdomains: 'abcd', maxZoom: 12 }).addTo(m);
  const path = (p.path || []).map(x => [x[0], x[1]]);
  const A = D.airports[t.from_icao], B = D.airports[t.to_icao];
  if (A && B) L.polyline([[A.lat, A.lon], [B.lat, B.lon]], { color: '#8A95A6', weight: 1, dashArray: '3 4' }).addTo(m);
  if (path.length > 1) L.polyline(path, { color: '#8A6526', weight: 3 }).addTo(m);
  const bounds = path.length > 1 ? path : (A && B ? [[A.lat, A.lon], [B.lat, B.lon]] : [[48, 4]]);
  m.fitBounds(bounds, { padding: [30, 30], maxZoom: 9 });
}
function scorecard(p) {
  const st = p.stats || {}, td = st.touchdown || {}, c = st.comfort, fpm = p.landing_fpm;
  const fpmCls = fpm == null ? '' : fpm <= 180 ? 'pos' : fpm <= 400 ? 'warnc' : 'neg';
  const side = v => v == null ? '—' : `${Math.abs(v).toFixed(1)} m ${v > 0.05 ? 'right' : v < -0.05 ? 'left' : ''}`;
  const tdTxt = td.td_ft == null ? '—' : td.td_ft < 0 ? `${Math.abs(td.td_ft).toLocaleString('en-US')} ft short` : `${td.td_ft.toLocaleString('en-US')} ft`;
  const wind = td.wind_kt != null ? `${String(td.wind_dir ?? 0).padStart(3, '0')}° / ${td.wind_kt} kt` : '—';
  const line = (label, secs, extra) => secs ? `<li><span>${label}</span><b>${Math.round(secs)} s${extra ? ` · ${extra}` : ''}</b></li>` : '';
  const comfortList = c ? [
    line('Noticeable G-forces', c.g_s, c.max_g ? `${c.min_g?.toFixed?.(2) ?? c.min_g}–${c.max_g?.toFixed?.(2) ?? c.max_g} g` : ''),
    line('Banked past 30°', c.bank_s, c.max_bank ? `max ${Math.round(c.max_bank)}°` : ''),
    line('Steep pitch', c.pitch_s),
    line('Descending over 3,500 fpm', c.vs_s),
    line('Taxiing over 30 kt', c.taxi_fast_s),
    c.hard_brake_n ? `<li><span>Sharp stops while taxiing</span><b>${c.hard_brake_n}</b></li>` : ''].join('') : '';
  return `<div class="scard">
   <div class="rings">${scoreRingHtml(p.landing_score, "Landing")}${scoreRingHtml(p.comfort_score, "Comfort")}<div class="pts"><b>${p.points ?? '—'}</b><span>${p.status === 'accepted' ? 'points earned' : p.status === 'pending' ? 'points on acceptance' : 'points'}</span></div></div>
   <div>
    <h4 class="rh" style="margin-top:0">Landing${td.runway ? ` · runway ${esc(td.runway)}` : ''}</h4>
    <div class="grid4">
     <div class="kv"><label>Rate of descent</label><span class="${fpmCls}">${fpm ?? '—'} fpm</span></div>
     <div class="kv"><label>G-force</label><span>${p.landing_g ?? '—'} g</span></div>
     <div class="kv"><label>Bounces</label><span>${p.bounces}</span></div>
     <div class="kv"><label>Speed at touchdown</label><span>${td.ias != null ? td.ias + ' kt' : '—'}</span></div>
     <div class="kv"><label>Past threshold</label><span>${tdTxt}</span></div>
     <div class="kv"><label>Centreline</label><span>${side(td.cl_m)}</span></div>
     <div class="kv"><label>Max off centre</label><span>${td.cl_max_m != null ? td.cl_max_m.toFixed(1) + ' m' : '—'}</span></div>
     <div class="kv"><label>Pitch / wind</label><span>${td.pitch != null ? td.pitch + '°' : '—'} · ${wind}</span></div></div>
    ${td.length_ft ? runwaySvg(td) : `<p class="hint" style="margin:8px 0 0">${p.stats && p.stats.touchdown ? 'No runway data for this airport yet, so centreline and touchdown distance are not available.' : 'Fly with tracker 0.3 or later for runway, centreline and comfort analysis.'}</p>`}
    ${c ? `<h4 class="rh">Comfort</h4>${comfortList ? `<ul class="comfort">${comfortList}</ul>` : '<p class="hint" style="margin:0">A smooth ride from start to finish: nothing the passengers noticed.</p>'}` : ''}
   </div></div>`;
}
async function renderPilots() {
  const [pilots, reps] = await Promise.all([
    q(sb.from('pilots').select('id,callsign,name,company,rep,cash,points,is_admin,created_at').order('points', { ascending: false })).then(r => r.sort((x, y) => (y.points || 0) - (x.points || 0) || y.rep - x.rep)),
    q(sb.from('pireps').select('pilot_id,landing_fpm,block_h,landing_score,comfort_score').eq('status', 'accepted').limit(10000))]);
  const st = {}; reps.forEach(r => { const s = st[r.pilot_id] ||= { n: 0, h: 0, l: 0, ln: 0, ls: 0, lsn: 0, cs: 0, csn: 0 }; s.n++; s.h += +r.block_h || 0; if (r.landing_fpm != null) { s.l += r.landing_fpm; s.ln++ } if (r.landing_score != null) { s.ls += r.landing_score; s.lsn++ } if (r.comfort_score != null) { s.cs += r.comfort_score; s.csn++ } });
  $('#main').innerHTML = `<div class="section"><div class="sechead"><div><h2>Pilots</h2><p>Every company flying for ${esc(D.settings.va_name)}, ranked by points. Pilots earn points for smooth, accurate flying: up to 100 for the landing and 100 for passenger comfort on every accepted flight.</p></div></div>
  <div class="panel tablewrap"><table class="grid"><thead><tr><th>#</th><th>Callsign</th><th>Pilot</th><th>Company</th><th>Points</th><th>Flights</th><th>Hours</th><th>Avg landing</th><th>Scores</th><th>Reputation</th><th>Balance</th></tr></thead><tbody>
  ${pilots.map((p, i) => { const s = st[p.id] || { n: 0, h: 0, ln: 0, lsn: 0, csn: 0 }; return `<tr${p.id === D.uid ? ' style="background:var(--brass-bg)"' : ''}><td class="n">${i + 1}</td><td class="n">${esc(p.callsign)}${p.is_admin ? ' <span class="tag call">Staff</span>' : ''}</td><td>${esc(p.name)}</td><td>${esc(p.company)}</td><td class="n"><b>${(p.points || 0).toLocaleString('en-US')}</b></td><td class="n">${s.n}</td><td class="n">${hm(s.h)}</td><td class="n">${s.ln ? Math.round(s.l / s.ln) + ' fpm' : '—'}</td><td class="n">${scoreChip(s.lsn ? Math.round(s.ls / s.lsn) : null, 'L')} ${scoreChip(s.csn ? Math.round(s.cs / s.csn) : null, 'C')}</td><td class="n">${Math.round(p.rep)}</td><td class="n">${kmoney(p.cash)}</td></tr>` }).join('')}
  </tbody></table></div></div>`;
}

/* ---------- profile ---------- */
async function renderProfile() {
  const key = await rpc('my_tracker_key');
  const code = btoa(JSON.stringify({ u: CFG.supabaseUrl, a: CFG.supabaseAnonKey, k: key }));
  $('#main').innerHTML = `<div class="section"><h2>Flight tracker</h2>
  <div class="panel" style="display:flex;flex-direction:column;gap:14px">
   <ol class="steps"><li>Install FSUIPC for your sim: FSUIPC7 for MSFS 2020/2024, FSUIPC6 for Prepar3D, or XPUIPC for X-Plane. The free versions work.</li>
   <li>Download the Charter Desk Tracker and run it. Windows may ask you to confirm because the app is new.</li>
   <li>Paste the setup code below when the tracker asks for it.</li>
   <li>Load your aircraft at the departure gate, choose the booking in the tracker and press Start flight. Fly normally; the report files itself when you're parked with the brake set or engines off.</li></ol>
   <div class="btns"><a class="btn pri" href="${esc(CFG.trackerDownloadUrl || '#')}" target="_blank" rel="noopener">Download the tracker ↗</a></div>
   <div class="field"><label>Your tracker setup code</label><div class="code" id="setupCode">${code}</div></div>
   <div class="btns"><button type="button" class="btn" data-act="copycode">Copy setup code</button><button type="button" class="btn danger" data-act="rotatekey">Make a new code</button></div>
   <p class="muted" style="margin:0;font-size:12.5px">The code lets the tracker file flights as you. Keep it private. Making a new code stops the old one working.</p></div></div>
  <div class="section"><h2>Settings</h2><form class="panel" id="prefForm" style="display:flex;flex-direction:column;gap:12px">
   <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px">${settingsFields({ ...PREF_DEFAULTS, ...(D.me.prefs || {}) }, 'pf')}</div>
   <p class="hint" style="margin:0">Currency changes what you see. Everyone trades in one VA economy, converted at fixed game rates: $1 = £0.79 = €0.92.</p>
   <div class="btns"><button class="btn pri" type="submit">Save settings</button></div></form></div>
  <div class="section"><h2>Account</h2><div class="panel kv" style="display:flex;gap:28px;flex-wrap:wrap"><div><label>Callsign</label><span>${esc(D.me.callsign)}</span></div><div><label>Name</label><span>${esc(D.me.name)}</span></div><div><label>Home base</label><span>${D.me.home}</span></div><div><label>Joined</label><span>${new Date(D.me.created_at).toLocaleDateString('en-GB')}</span></div></div></div>`;
  $('#prefForm').onsubmit = async e => { e.preventDefault(); await act(() => rpc('update_prefs', { p_prefs: readSettings('pf') }), 'Settings saved.'); clock() };
}

/* ---------- staff ---------- */
async function renderStaff() {
  if (!D.me.is_admin) { UI.tab = 'market'; return renderTab() }
  const [pending, pilots] = await Promise.all([
    q(sb.from('pireps').select('id,created_at,landing_fpm,block_h,checks,arr_icao,trips(flt,from_icao,to_icao),pilots(callsign)').eq('status', 'pending').order('id')),
    q(sb.from('pilots').select('id,callsign,name,company,is_admin,cash,rep').order('callsign'))]);
  const s = D.settings;
  $('#main').innerHTML = `<div class="section"><div class="sechead"><div><h2>Reports to review</h2><p>Reports that failed an automatic check${s.auto_accept ? '' : ', or every report while automatic acceptance is off'}.</p></div></div>
  <div class="panel tablewrap"><table class="grid"><thead><tr><th>Filed</th><th>Pilot</th><th>Flight</th><th>Route</th><th>Failed checks</th></tr></thead><tbody>
  ${pending.length ? pending.map(p => `<tr class="click" data-act="pirepstaff" data-id="${p.id}"><td class="n">${fmtDate(p.created_at)}</td><td class="n">${esc(p.pilots?.callsign)}</td><td class="n">${esc(p.trips?.flt)}</td><td class="n">${p.trips?.from_icao} → ${p.arr_icao}</td><td>${Object.entries(p.checks || {}).filter(([, v]) => !v.ok).map(([k]) => `<span class="check-bad">${k}</span>`).join(' ') || '—'}</td></tr>`).join('') : '<tr><td colspan="5" class="muted">Nothing waiting. Nice.</td></tr>'}</tbody></table></div></div>

  <div class="section"><h2>VA settings</h2><form class="panel" id="setForm" style="display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;align-items:end">
   <div class="field"><label for="sName">VA name</label><input id="sName" value="${esc(s.va_name)}"></div>
   <div class="field"><label for="sTz">Market time zone</label><input id="sTz" value="${esc(s.timezone)}"></div>
   <div class="field"><label for="sCash">New pilot starting cash (USD)</label><input id="sCash" type="number" value="${s.start_cash}"></div>
   <div class="field"><label for="sBase">Base board size</label><input id="sBase" type="number" min="4" max="40" value="${s.market_base}"></div>
   <label class="check"><input type="checkbox" id="sAuto" ${s.auto_accept ? 'checked' : ''}> Accept clean reports automatically</label>
   <button class="btn pri" type="submit">Save settings</button></form></div>

  <div class="section"><div class="sechead"><div><h2>Airports</h2><p>${D.apList.length.toLocaleString('en-US')} active airports feed the request board. The worldwide list comes from OurAirports (public domain); refresh it to pick up any runway or position changes. Paste CSV rows to add or update many at once: ICAO, name, city, country, latitude, longitude, tags (biz, leisure, ski, long, separated by spaces).</p></div></div>
   <form class="panel" id="apForm" style="display:flex;flex-direction:column;gap:10px"><textarea class="ta" id="apCsv" placeholder="LFKC,Calvi Sainte-Catherine,Calvi,FR,42.5308,8.7933,leisure"></textarea><div class="btns"><button class="btn pri" type="submit">Import airports</button><button class="btn" type="button" id="apWorld">Refresh the worldwide list</button></div><div class="err" id="apErr"></div></form></div>

  <div class="section"><div class="sechead"><div><h2>Runways</h2><p>Runway threshold positions let flight reports show the runway used, touchdown distance past the threshold and centreline accuracy. <b id="rwCount">Checking…</b></p></div></div>
   <div class="panel" style="display:flex;flex-direction:column;gap:10px"><div class="btns"><button class="btn pri" type="button" id="rwLoad">Load runway data</button></div><div class="err" id="rwErr"></div></div></div>

  <div class="section"><h2>Pilots</h2><div class="panel tablewrap"><table class="grid"><thead><tr><th>Callsign</th><th>Name</th><th>Company</th><th>Balance</th><th>Rep</th><th>Staff</th><th>Adjust</th></tr></thead><tbody>
  ${pilots.map(p => `<tr><td class="n">${esc(p.callsign)}</td><td>${esc(p.name)}</td><td>${esc(p.company)}</td><td class="n">${money(p.cash)}</td><td class="n">${Math.round(p.rep)}</td>
   <td><label class="check"><input type="checkbox" data-act="staff" data-id="${p.id}" ${p.is_admin ? 'checked' : ''} ${p.id === D.uid ? 'disabled' : ''}> Staff</label></td>
   <td><button type="button" class="btn" data-act="adjust" data-id="${p.id}" data-cs="${esc(p.callsign)}">Adjust</button></td></tr>`).join('')}</tbody></table></div></div>`;
  $('#setForm').onsubmit = async e => { e.preventDefault(); await act(async () => { await rpc('admin_settings', { p_va_name: $('#sName').value, p_timezone: $('#sTz').value, p_start_cash: +$('#sCash').value, p_market_base: +$('#sBase').value, p_auto_accept: $('#sAuto').checked }); await loadStatic() }, 'Settings saved.') };
  sb.from('runways').select('icao', { count: 'exact', head: true }).then(({ count }) => { $('#rwCount') && ($('#rwCount').textContent = count ? `${count.toLocaleString('en-US')} runways loaded.` : 'No runway data loaded yet.') });
  $('#rwLoad').onclick = async () => {
    $('#rwErr').textContent = 'Loading runway data…';
    try {
      const rows = await fetch('data/runways.json').then(r => { if (!r.ok) throw new Error('Couldn\'t load data/runways.json'); return r.json() });
      let n = 0; for (let i = 0; i < rows.length; i += 1000) { n += await rpc('admin_import_runways', { p_rows: rows.slice(i, i + 1000) }); $('#rwErr').textContent = `Imported ${n.toLocaleString('en-US')} of ${rows.length.toLocaleString('en-US')}…` }
      $('#rwErr').textContent = ''; $('#rwCount').textContent = `${n.toLocaleString('en-US')} runways loaded.`; toast(`Runway data loaded: ${n.toLocaleString('en-US')} runways.`, 'ok');
    } catch (err) { $('#rwErr').textContent = err.message }
  };
  $('#apWorld').onclick = async () => {
    $('#apErr').textContent = 'Loading the worldwide list…';
    try {
      const rows = await fetch('data/airports.json').then(r => { if (!r.ok) throw new Error('Couldn\'t load data/airports.json'); return r.json() });
      let n = 0; for (let i = 0; i < rows.length; i += 1000) { n += await rpc('admin_import_airports', { p_rows: rows.slice(i, i + 1000) }); $('#apErr').textContent = `Imported ${n.toLocaleString('en-US')} of ${rows.length.toLocaleString('en-US')}…` }
      $('#apErr').textContent = ''; toast(`Airport list refreshed: ${n.toLocaleString('en-US')} airports.`, 'ok'); await loadStatic(); renderTab();
    } catch (err) { $('#apErr').textContent = err.message }
  };
  $('#apForm').onsubmit = async e => {
    e.preventDefault(); const lines = $('#apCsv').value.split(/\r?\n/).map(l => l.trim()).filter(Boolean); let n = 0; $('#apErr').textContent = '';
    for (const line of lines) {
      const c = line.split(',').map(x => x.trim());
      if (c.length < 6 || isNaN(+c[4]) || isNaN(+c[5])) { $('#apErr').textContent = `Skipped "${line}": needs ICAO, name, city, country, latitude, longitude.`; continue }
      try { await rpc('admin_upsert_airport', { p_icao: c[0], p_name: c[1], p_city: c[2], p_country: c[3], p_lat: +c[4], p_lon: +c[5], p_tags: (c[6] || '').split(/\s+/).filter(Boolean), p_active: true }); n++ }
      catch (err) { $('#apErr').textContent = `${c[0]}: ${err.message}` }
    }
    if (n) { toast(`Imported ${n} airport${n > 1 ? 's' : ''}.`, 'ok'); await loadStatic(); renderTab() }
  };
}

/* ---------- quote modal ---------- */
function openBid(r) {
  const ac = active(), qd = quote(ac, r), tm = timing(ac, r, qd);
  $('#modal').innerHTML = `<div class="scrim" data-act="scrim"><div class="modal" role="dialog" aria-modal="true" aria-label="Quote for request">
  <div><h3 style="margin:0 0 4px">Quote · REQ ${r.id} · ${esc(r.client)}</h3><div class="route">${r.from_icao}<i>▸</i>${r.to_icao}</div><div class="muted" style="font-size:13px">${esc(D.airports[r.from_icao]?.city)} to ${esc(D.airports[r.to_icao]?.city)} · ${r.pax} pax · departs ${fmtDep(r.dep_at, r.from_icao)}</div></div>
  <div class="grid4"><div class="kv"><label>Aircraft</label><span>${ac.reg}</span></div><div class="kv"><label>Block</label><span>${hm(qd.bh)}</span></div>
   <div class="kv"><label>Positioning</label><span>${qd.repoNm ? `${dist(qd.repoNm)} · ${kmoney(qd.repoCost)} · leave ${qd.loc} by ${fmtDep(new Date(tm.leave).toISOString(), qd.loc)}` : 'None'}</span></div><div class="kv"><label>Op. cost</label><span>${kmoney(qd.opc)}</span></div></div>
  <div class="field"><label for="bidAmt">Your price (${pref('currency')})</label><div class="amount"><span>${cur().sym}</span><input id="bidAmt" inputmode="numeric" value="${Math.round(toLocal(qd.guide) / 100) * 100}"></div>
   <input type="range" id="bidRange" min="${Math.round(toLocal(qd.guide) * 0.6 / 100) * 100}" max="${Math.round(toLocal(qd.fair) * 1.6 / 100) * 100}" step="100" value="${Math.round(toLocal(qd.guide) / 100) * 100}" aria-label="Adjust price">
   <div style="display:flex;justify-content:space-between;font-size:11.5px;flex-wrap:wrap;gap:6px" class="muted mono"><span>Market rate ${kmoney(qd.guide * 0.95)}–${kmoney(qd.guide * 1.1)}${qd.repoNm ? `; outside operators may not need to position` : ''}</span><span>${r.npc} outside operators${r.player_bids ? ` + ${r.player_bids} VA pilot${r.player_bids > 1 ? 's' : ''}` : ''}</span></div></div>
  <div class="odds"><div class="kv"><label>Margin</label><span id="oMargin"></span></div><div class="kv"><label>Est. win chance</label><span id="oWin"></span></div><div class="kv"><label>Decision in</label><span>${r.decide_at ? `<span data-cd="${ts(r.decide_at)}"></span>` : BIDWAIT[Math.min(3, upg('fast'))] + 's'}</span></div></div>
  <div class="oddsbar"><i id="oBar"></i></div>
  <p class="muted" style="margin:0;font-size:12px">The estimate counts outside operators only. Other VA pilots may undercut you.</p>
  <div class="err" id="bidErr"></div>
  <div class="btns" style="justify-content:flex-end"><button type="button" class="btn" data-act="close">Cancel</button><button type="button" class="btn pri" id="sendBid" data-act="sendbid" data-id="${r.id}">Send quote</button></div></div></div>`;
  const inp = $('#bidAmt'), rg = $('#bidRange');
  const upd = () => { const v = toUsd(parseInt(inp.value.replace(/\D/g, '')) || 0); const m = v - qd.opc; $('#oMargin').textContent = money(m); $('#oMargin').className = m >= 0 ? 'pos' : 'neg'; const o = winOdds(r, ac, v); $('#oWin').textContent = Math.round(o * 100) + '%'; $('#oBar').style.width = o * 100 + '%'; $('#oBar').style.background = o > 0.6 ? 'var(--ok)' : o > 0.3 ? 'var(--brass-light)' : 'var(--bad)'; $('#sendBid').disabled = v < 100 };
  inp.addEventListener('input', () => { rg.value = parseInt(inp.value.replace(/\D/g, '')) || 0; upd() });
  rg.addEventListener('input', () => { inp.value = rg.value; upd() });
  upd(); updateCountdowns(); inp.focus(); inp.select();
}
async function regBox(title, body, label, exceptId, fn) {
  const taken = (await q(sb.from('fleet').select('id,reg').limit(10000)).catch(() => [])).filter(x => x.id !== exceptId).map(x => x.reg);
  const sug = suggestReg(D.airports[D.me.home]?.country, D.me.prefix, taken);
  $('#modal').innerHTML = `<div class="scrim" data-act="scrim"><form class="modal" id="regForm" role="dialog" aria-modal="true" aria-label="${esc(title)}"><h2>${esc(title)}</h2><p class="muted" style="margin:0">${body}</p>
   <div class="field"><label for="rgReg">Registration</label><input id="rgReg" maxlength="9" value="${sug}" autocomplete="off" style="text-transform:uppercase"><span class="hint" id="rgHint"></span></div>
   <div class="err" id="rgErr"></div><div class="btns" style="justify-content:flex-end"><button type="button" class="btn" data-act="close">Cancel</button><button type="submit" class="btn pri">${esc(label)}</button></div></form></div>`;
  const chk = () => { const r = $('#rgReg').value.trim().toUpperCase(), ok = REG_RE.test(r) && !taken.includes(r);
    $('#rgHint').textContent = taken.includes(r) ? 'Already used in the VA.' : ok ? 'Looks good.' : 'Use a country prefix and dash (G-ABCD, ZJ-JEC) or a US N-number (N123AB).'; $('#rgHint').className = 'hint ' + (ok ? 'good' : 'bad'); return ok };
  $('#rgReg').oninput = chk; chk(); $('#rgReg').focus(); $('#rgReg').select();
  $('#regForm').onsubmit = async e => { e.preventDefault(); if (!chk()) return; try { await fn($('#rgReg').value.trim().toUpperCase()); closeModal(); await afterChange() } catch (err) { $('#rgErr').textContent = err.message } };
}
function confirmBox(title, body, label, fn) {
  $('#modal').innerHTML = `<div class="scrim" data-act="scrim"><div class="modal" role="dialog" aria-modal="true" aria-label="${esc(title)}"><h2>${esc(title)}</h2><div class="muted">${body}</div><div class="err" id="cfErr"></div><div class="btns" style="justify-content:flex-end"><button type="button" class="btn" data-act="close">Keep it</button><button type="button" class="btn pri" id="cfOk">${esc(label)}</button></div></div></div>`;
  $('#cfOk').onclick = async () => { try { await fn(); closeModal(); await afterChange() } catch (e) { $('#cfErr').textContent = e.message } };
}
function closeModal() { $('#modal').innerHTML = '' }
async function afterChange() { await refreshCore(); renderAll() }
async function act(fn, okMsg) {
  try { await fn(); if (okMsg) toast(okMsg, 'ok'); await afterChange() }
  catch (e) { toast(e.message, 'bad') }
}

/* ---------- events ---------- */
document.addEventListener('click', async e => {
  const tab = e.target.closest('[data-tab]');
  if (tab) { e.preventDefault(); if (liveMap) { liveMap.remove(); liveMap = null } UI.tab = tab.dataset.tab; history.replaceState(null, '', '#' + UI.tab); renderAll(); window.scrollTo(0, 0); if (tab.dataset.shop) setTimeout(() => document.getElementById('hire')?.scrollIntoView({ behavior: 'smooth' }), 900); return }
  const b = e.target.closest('[data-act]'); if (!b) return;
  const a = b.dataset.act, id = b.dataset.id;
  if (a === 'scrim') { if (e.target === b) closeModal(); return }
  if (a === 'close') closeModal();
  if (a === 'signout') { await sb.auth.signOut(); location.reload() }
  if (a === 'paxans') { try { const res = await rpc('answer_request', { p_req: +id, p_choice: +b.dataset.i }); toast(`${res.good ? '✓' : '·'} "${res.reply}"`, res.good ? 'ok' : ''); } catch (err) { toast(err.message, 'bad') } D.pax = (D.pax || []).filter(x => x.id !== +id); $('#cabin').dataset.id = ''; renderCabin(); return }
  if (a === 'theme') { THEME = THEMES[(THEMES.indexOf(THEME) + 1) % 3]; try { localStorage.setItem('cd-theme', THEME) } catch (_) { } applyTheme(); renderHeader(); if (liveMap) { liveMap.remove(); liveMap = null } renderTab(); return }
  if (a === 'sound') { UI.sound = !UI.sound; try { localStorage.setItem('cd-ringer', UI.sound ? '1' : '0') } catch (_) { } if (UI.sound) { try { actx = actx || new (window.AudioContext || window.webkitAudioContext)(); actx.resume() } catch (_) { } } renderHeader() }
  if (a === 'pickac') { UI.acId = id; renderTab() }
  if (a === 'band') { UI.band = b.dataset.k; renderTab() }
  if (a === 'bid') { const r = D.requests.find(x => x.id === +id); if (r) openBid(r) }
  if (a === 'sendbid') {
    const v = Math.round(toUsd(parseInt($('#bidAmt').value.replace(/\D/g, '')) || 0));
    try { await rpc('place_bid', { p_request: +id, p_aircraft: active().id, p_amount: v }); closeModal(); toast(`Quote of ${money(v)} sent.`, ''); await afterChange() }
    catch (err) { $('#bidErr').textContent = err.message }
  }
  if (a === 'acceptcall') { const ac = $('#callAc')?.value || pilotFleet().find(x => fits(typeOf(x), D.calls[0]))?.id; await act(() => rpc('accept_call', { p_call: +id, p_aircraft: ac }), 'Booked. Plan it under Trips.'); $('#call').dataset.id = '' }
  if (a === 'declinecall') { await act(() => rpc('decline_call', { p_call: +id })); $('#call').dataset.id = '' }
  if (a === 'copyplan') {
    const tr = D.trips.find(x => x.id === +id), p = plan(tr), ac = p.ac;
    const txt = `${tr.flt}  ${ac.reg} (${ac.type_code})\n${tr.from_icao} → ${tr.to_icao}  ALTN ${p.alt}\nDEP ${fmtDep(tr.dep_at, tr.from_icao)}  PAX ${tr.pax}  PAYLOAD ${wt(p.payload)}\nDIST ${dist(tr.dist)}  FL${p.fl}  EST BLOCK ${hm(p.bh)}\nFUEL trip ${wt(p.tripFuel)} / altn ${wt(p.altFuel)} / res ${wt(p.res)} / taxi ${wt(p.taxi)} = ${wt(p.block)}`;
    try { await navigator.clipboard.writeText(txt); toast('Flight plan copied.', 'ok') } catch (_) { confirmBox('Flight plan', `<pre class="code" style="white-space:pre-wrap">${esc(txt)}</pre>`, 'Done', async () => { }) }
  }
  if (a === 'outsource') confirmBox('Use a contract crew?', `A contract crew positions the aircraft for ${money(+b.dataset.cost)}. You won't need to fly this leg.`, 'Pay and position', () => rpc('outsource_ferry', { p_trip: +id }));
  if (a === 'cancel') { const tr = D.trips.find(x => x.id === +id); confirmBox(`Cancel ${tr.flt}?`, `${esc(tr.client)} will need another operator. You'll pay a ${money(Math.round(tr.price * 0.2))} cancellation fee and lose 5 reputation.`, 'Cancel trip', () => rpc('cancel_trip', { p_trip: +id })) }
  if (a === 'buyslot') await act(() => rpc('buy_slot'), 'New fleet slot ready.');
  if (a === 'buyac') buyBox(b.dataset.k).catch(err => toast(err.message, 'bad'));
  if (a === 'shopcat') { UI.shopCat = b.dataset.k; renderTab() }
  if (a === 'shopsims') { UI.shopAllSims = !b.checked; renderTab() }
  if (a === 'planner') { UI.plan = +id; UI.extraMin = null; UI.globeZoom = 1; renderTab(); window.scrollTo(0, 0) }
  if (a === 'planclose') { UI.plan = null; renderTab() }
  if (a === 'extra') { UI.extraMin = +b.dataset.m; renderTab() }
  if (a === 'customs') await act(() => rpc('submit_customs', { p_trip: +id }), 'Customs declaration filed.');
  if (a === 'fetchofp') fetchOfp(+id);
  if (a === 'gzoom') { const z = +b.dataset.z; UI.globeZoom = z === 0 ? 1 : Math.min(GLOBE.fit ? GLOBE.fit() * 1.5 : 8, Math.max(1, (UI.globeZoom || 1) * (z > 0 ? 1.6 : 1 / 1.6))); GLOBE.redraw?.() }
  if (a === 'sbchange') { confirmBox('Change SimBrief account', `<div class="field" style="margin-top:8px"><label for="sbNew">SimBrief username</label><input id="sbNew" value="${esc(D.me.simbrief_user || '')}"></div>`, 'Save', () => rpc('set_simbrief', { p_user: $('#sbNew').value })) }
  if (a === 'ops') await act(() => rpc('set_ops', { p_ac: id, p_mode: b.dataset.mode }), b.dataset.mode === 'crew' ? 'Handed to your crew. They\'ll take the next job that comes up.' : 'Back under your control.');
  if (a === 'hire') { const tc = $('#hireType' + id).value, c = D.types[tc]; await act(() => rpc('hire_crew', { p_cand: +id, p_type: tc }), `Hired. Type rating course on the ${c.name} finishes in 12 hours.`) }
  if (a === 'check') { const c = D.crew.find(x => x.id === +id), cat = D.types[c.type_code].category, k = b.dataset.kind; confirmBox(k === 'opc' ? `Book an OPC for ${c.name}?` : `Book recurrent training for ${c.name}?`, `${money(k === 'opc' ? CREW_RATES[cat][2] : CREW_RATES[cat][1] * 0.5)}. ${c.name} is unavailable for ${k === 'opc' ? '4' : '8'} hours, and the next one is due ${k === 'opc' ? '6' : '12'} months after the current due date.`, 'Book it', () => rpc('crew_check', { p_crew: +id, p_kind: k })) }
  if (a === 'pay') { const c = D.crew.find(x => x.id === +id); confirmBox(`Change ${c.name}'s pay`, `<div class="field" style="margin-top:8px"><label for="paySal">Monthly salary (${pref('currency')})</label><input id="paySal" type="number" min="1000" step="100" value="${Math.round(toLocal(c.salary) / 100) * 100}"></div><p class="hint" style="margin-top:8px">A raise lifts morale straight away. A cut hurts it.</p>`, 'Save', () => rpc('set_salary', { p_crew: +id, p_salary: Math.round(toUsd(+$('#paySal').value)) })) }
  if (a === 'release') { const c = D.crew.find(x => x.id === +id); confirmBox(`Let ${c.name} go?`, `You pay one month's notice, ${money(c.salary)}. Any aircraft left without enough crew comes back under your control.`, 'Let go', () => rpc('release_crew', { p_crew: +id })) }
  if (a === 'repay') { const ac = acById(id); confirmBox(`Pay off the loan on ${ac.reg}?`, `${money(ac.loan_balance)} comes out of your balance now, and the monthly payments stop.`, 'Pay off loan', () => rpc('repay_loan', { p_ac: id })) }
  if (a === 'rereg') { const ac = acById(id); regBox(`Re-register ${ac.reg}`, `Choose a new registration for your ${esc(typeOf(ac).name)}. It's free, and every pilot will see the new one.`, 'Save registration', ac.id,
    async reg => { await rpc('set_registration', { p_ac: id, p_reg: reg }); toast(`${ac.reg} is now ${reg}.`, 'ok') }) }
  if (a === 'upg') await act(() => rpc('buy_upgrade', { p_key: b.dataset.k }), `${UPG[b.dataset.k].name} upgraded.`);
  if (a === 'sell') { const ac = acById(id), t = typeOf(ac), net = +b.dataset.net; confirmBox(`Sell ${ac.reg}?`, `The ${ac.year} ${esc(t.name)} sells for ${money(Math.round(acValue(t, ac.year) * 0.92))} after an 8% broker fee${+ac.loan_balance > 0 ? `, and ${money(ac.loan_balance)} of that repays its loan` : ''}. You ${net < 0 ? 'pay' : 'receive'} ${money(Math.abs(net))}.`, 'Sell aircraft', async () => { await rpc('sell_aircraft', { p_ac: id }); if (UI.acId === id) UI.acId = null }) }
  if (a === 'pirep') openPirep(+id, false).catch(err => toast(err.message, 'bad'));
  if (a === 'pirepstaff') openPirep(+id, true).catch(err => toast(err.message, 'bad'));
  if (a === 'review') { const note = $('#rvNote')?.value || ''; try { await rpc('admin_review', { p_pirep: +id, p_accept: b.dataset.ok === '1', p_note: note }); closeModal(); toast('Review saved.', 'ok'); renderTab() } catch (err) { toast(err.message, 'bad') } }
  if (a === 'copycode') { try { await navigator.clipboard.writeText($('#setupCode').textContent); toast('Setup code copied.', 'ok') } catch (_) { const r = document.createRange(); r.selectNodeContents($('#setupCode')); getSelection().removeAllRanges(); getSelection().addRange(r); toast('Press Ctrl+C to copy the selected code.', '') } }
  if (a === 'rotatekey') confirmBox('Make a new setup code?', 'The tracker will stop working until you paste the new code into it.', 'Make new code', () => rpc('rotate_tracker_key'));
  if (a === 'adjust') {
    confirmBox(`Adjust ${b.dataset.cs}`, `<div class="row2" style="margin-top:8px"><div class="field"><label for="adCash">Cash change (${pref('currency')})</label><input id="adCash" type="number" value="0"></div><div class="field"><label for="adRep">Reputation change</label><input id="adRep" type="number" step="0.5" value="0"></div></div><div class="field" style="margin-top:10px"><label for="adWhy">Reason</label><input id="adWhy" maxlength="120"></div>`, 'Apply',
      () => rpc('admin_adjust', { p_pilot: id, p_cash: Math.round(toUsd(+$('#adCash').value || 0)), p_rep: +$('#adRep').value || 0, p_reason: $('#adWhy').value }));
  }
});
document.addEventListener('change', async e => {
  const a = e.target.dataset.act;
  if (a === 'showall') { UI.showAll = e.target.checked; renderTab() }
  if (a === 'assign') await act(() => rpc('assign_crew', { p_crew: +e.target.dataset.id, p_ac: e.target.value || null }), 'Crew assignment saved.');
  if (a === 'nearonly') { UI.nearOnly = e.target.checked; renderTab() }
  if (a === 'sort') { UI.sort = e.target.value; renderTab() }
  if (a === 'staff') { try { await rpc('admin_set_staff', { p_pilot: e.target.dataset.id, p_staff: e.target.checked }); toast('Staff access updated.', 'ok') } catch (err) { toast(err.message, 'bad'); e.target.checked = !e.target.checked } }
});
document.addEventListener('keydown', e => { if (e.key === 'Escape') closeModal(); if (e.key === 'Enter' && e.target.id === 'bidAmt') $('#sendBid').click() });
window.addEventListener('hashchange', () => { if (!D.me) return; const h = location.hash.slice(1); if (TABS.some(t => t[0] === h) && h !== UI.tab) { if (liveMap) { liveMap.remove(); liveMap = null } UI.tab = h; renderAll() } });
let rz; window.addEventListener('resize', () => { clearTimeout(rz); rz = setTimeout(() => { if (UI.tab === 'trips' && !$('#modal').children.length) renderTab() }, 200) });

boot().catch(e => { $('#main').innerHTML = `<div class="authwrap"><div class="authcard"><div class="authlogo"><svg width="30" height="30" viewBox="0 0 34 34" aria-hidden="true"><path d="M6 28 L14 6 L20 6 L16 20 L28 20 L28 28 Z" fill="#B88A3A"></path></svg><b>Charter Desk <span>FS</span></b></div><h1>Couldn't start</h1><p>${esc(e.message)}</p></div></div>` });
