/* A small orthographic globe on canvas: land outlines, the route as a great circle,
   optional aircraft position. Drag to rotate, buttons or wheel to zoom. */
(function () {
  'use strict';
  const R = Math.PI / 180;
  let LAND = null, landPromise = null;
  function loadLand() {
    if (LAND) return Promise.resolve(LAND);
    landPromise = landPromise || fetch('data/world.json').then(r => r.json()).then(d => (LAND = d)).catch(() => (LAND = []));
    return landPromise;
  }
  function gcPoints(a, b, n) {
    const p1 = [a.lat * R, a.lon * R], p2 = [b.lat * R, b.lon * R];
    const d = 2 * Math.asin(Math.sqrt(Math.sin((p2[0] - p1[0]) / 2) ** 2 + Math.cos(p1[0]) * Math.cos(p2[0]) * Math.sin((p2[1] - p1[1]) / 2) ** 2)) || 1e-9;
    const out = [];
    for (let i = 0; i <= n; i++) {
      const f = i / n, A = Math.sin((1 - f) * d) / Math.sin(d), B = Math.sin(f * d) / Math.sin(d);
      const x = A * Math.cos(p1[0]) * Math.cos(p1[1]) + B * Math.cos(p2[0]) * Math.cos(p2[1]);
      const y = A * Math.cos(p1[0]) * Math.sin(p1[1]) + B * Math.cos(p2[0]) * Math.sin(p2[1]);
      const z = A * Math.sin(p1[0]) + B * Math.sin(p2[0]);
      out.push({ lat: Math.atan2(z, Math.hypot(x, y)) / R, lon: Math.atan2(y, x) / R });
    }
    return out;
  }
  function nmBetween(a, b) {
    const x = Math.sin((b.lat - a.lat) * R / 2) ** 2 + Math.cos(a.lat * R) * Math.cos(b.lat * R) * Math.sin((b.lon - a.lon) * R / 2) ** 2;
    return 2 * 3440.065 * Math.asin(Math.min(1, Math.sqrt(x)));
  }

  /* opts: { from:{lat,lon,label}, to:{...}, alt:{...}|null, pos:{lat,lon,hdg}|null, flown:[[lat,lon],...] } */
  function Globe(canvas, opts) {
    this.c = canvas; this.o = opts;
    const mid = gcPoints(opts.from, opts.to, 2)[1];
    this.lat0 = mid.lat; this.lon0 = mid.lon;
    const d = nmBetween(opts.from, opts.to);
    this.zoom = Math.max(1, Math.min(9, 2600 / Math.max(d, 120)));
    this.bind();
    loadLand().then(() => this.draw());
    this.draw();
  }
  Globe.prototype.project = function (lat, lon, cx, cy, r) {
    const p = lat * R, l = (lon - this.lon0) * R, p0 = this.lat0 * R;
    const cosc = Math.sin(p0) * Math.sin(p) + Math.cos(p0) * Math.cos(p) * Math.cos(l);
    const x = Math.cos(p) * Math.sin(l), y = Math.cos(p0) * Math.sin(p) - Math.sin(p0) * Math.cos(p) * Math.cos(l);
    if (cosc >= 0) return [cx + r * x, cy - r * y, true];
    const m = Math.hypot(x, y) || 1; // behind the globe: pin to the horizon so filled shapes stay sane
    return [cx + r * x / m, cy - r * y / m, false];
  };
  Globe.prototype.draw = function () {
    const c = this.c, box = c.getBoundingClientRect(), W = Math.max(200, box.width), H = Math.max(200, box.height), dpr = window.devicePixelRatio || 1;
    c.width = W * dpr; c.height = H * dpr;
    const g = c.getContext('2d'); g.setTransform(dpr, 0, 0, dpr, 0, 0);
    const cx = W / 2, cy = H / 2, r = Math.min(W, H) / 2 * 0.92 * this.zoom;
    g.fillStyle = '#F3F5F8'; g.fillRect(0, 0, W, H);
    g.save(); g.beginPath(); g.arc(cx, cy, r, 0, 2 * Math.PI); g.fillStyle = '#DCE6F0'; g.fill(); g.clip();
    // graticule
    g.strokeStyle = 'rgba(14,26,43,0.07)'; g.lineWidth = 1;
    for (let la = -60; la <= 60; la += 30) this.line(g, Array.from({ length: 73 }, (_, i) => ({ lat: la, lon: -180 + i * 5 })), cx, cy, r);
    for (let lo = -180; lo < 180; lo += 30) this.line(g, Array.from({ length: 37 }, (_, i) => ({ lat: -90 + i * 5, lon: lo })), cx, cy, r);
    // land
    if (LAND) {
      g.fillStyle = '#FFFFFF'; g.strokeStyle = '#B9C4D1'; g.lineWidth = 0.8;
      for (const ring of LAND) {
        let any = false; g.beginPath();
        ring.forEach((pt, i) => { const [x, y, v] = this.project(pt[1], pt[0], cx, cy, r); if (v) any = true; i ? g.lineTo(x, y) : g.moveTo(x, y) });
        if (any) { g.closePath(); g.fill(); g.stroke() }
      }
    }
    const o = this.o;
    if (o.alt) { g.setLineDash([3, 4]); g.strokeStyle = '#8A95A6'; g.lineWidth = 1.2; this.line(g, gcPoints(o.to, o.alt, 32), cx, cy, r); g.setLineDash([]) }
    g.strokeStyle = '#0E1A2B'; g.lineWidth = 2.2; this.line(g, gcPoints(o.from, o.to, 96), cx, cy, r);
    if (o.flown && o.flown.length > 1) { g.strokeStyle = '#B88A3A'; g.lineWidth = 3; this.line(g, o.flown.map(p => ({ lat: p[0], lon: p[1] })), cx, cy, r) }
    g.restore();
    // rim
    g.beginPath(); g.arc(cx, cy, r, 0, 2 * Math.PI); g.strokeStyle = 'rgba(14,26,43,0.18)'; g.lineWidth = 1; g.stroke();
    const dot = (p, col, label, rad) => { const [x, y, v] = this.project(p.lat, p.lon, cx, cy, r); if (!v) return;
      g.fillStyle = col; g.beginPath(); g.arc(x, y, rad, 0, 2 * Math.PI); g.fill();
      if (label) { g.font = '600 12px "DM Mono", ui-monospace, monospace'; const w = g.measureText(label).width; let tx = x + 8; if (tx + w > W - 6) tx = x - 8 - w;
        g.fillStyle = 'rgba(255,255,255,0.85)'; g.fillRect(tx - 3, y - 19, w + 6, 16); g.fillStyle = '#0E1A2B'; g.fillText(label, tx, y - 7) } };
    if (o.alt) dot(o.alt, '#8A95A6', o.alt.label, 3);
    dot(o.from, '#8A6526', o.from.label, 5); dot(o.to, '#8A6526', o.to.label, 5);
    if (o.pos) {
      const [x, y, v] = this.project(o.pos.lat, o.pos.lon, cx, cy, r);
      if (v) { g.save(); g.translate(x, y); g.rotate((o.pos.hdg || 0) * R); g.fillStyle = '#B88A3A'; g.strokeStyle = '#fff'; g.lineWidth = 1.5;
        g.beginPath(); g.moveTo(0, -11); g.lineTo(7, 8); g.lineTo(0, 4); g.lineTo(-7, 8); g.closePath(); g.fill(); g.stroke(); g.restore() }
    }
  };
  Globe.prototype.line = function (g, pts, cx, cy, r) {
    let pen = false; g.beginPath();
    for (const p of pts) { const [x, y, v] = this.project(p.lat, p.lon, cx, cy, r); if (!v) { pen = false; continue } pen ? g.lineTo(x, y) : g.moveTo(x, y); pen = true }
    g.stroke();
  };
  Globe.prototype.bind = function () {
    const c = this.c; let drag = null;
    c.style.cursor = 'grab'; c.style.touchAction = 'none';
    c.addEventListener('pointerdown', e => { drag = { x: e.clientX, y: e.clientY, lat: this.lat0, lon: this.lon0 }; c.setPointerCapture(e.pointerId); c.style.cursor = 'grabbing' });
    c.addEventListener('pointermove', e => { if (!drag) return; const k = 0.4 / this.zoom;
      this.lon0 = drag.lon - (e.clientX - drag.x) * k; this.lat0 = Math.max(-85, Math.min(85, drag.lat + (e.clientY - drag.y) * k)); this.draw() });
    const end = () => { drag = null; c.style.cursor = 'grab' };
    c.addEventListener('pointerup', end); c.addEventListener('pointercancel', end);
    c.addEventListener('wheel', e => { e.preventDefault(); this.setZoom(this.zoom * (e.deltaY < 0 ? 1.15 : 0.87)) }, { passive: false });
  };
  Globe.prototype.setZoom = function (z) { this.zoom = Math.max(0.9, Math.min(14, z)); this.draw() };
  Globe.prototype.update = function (opts) { Object.assign(this.o, opts); this.draw() };
  window.CDGlobe = Globe;
})();
