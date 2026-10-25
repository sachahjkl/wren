// WREN_JS_PRELUDE for tools\yt_idle.ps1: what a page does in the background. Between window.__census.start() and stop() it counts, per
// call site, the timers (setTimeout / setInterval) and animation frames that run, the observers' callbacks (Mutation, Intersection, Resize,
// Performance), fetch / XHR / beacons, postMessage, and the reads that force a layout (getBoundingClientRect, getComputedStyle, offsetWidth...),
// with the time the callbacks and the reads took. window.__census.report() is the JSON of the top rows of each kind, per second.
// The wrappers stay in place when it is not counting (a flag test); a timer made before start() is counted when it runs, by where it was made.
(function () {
  const C = window.__census = { on: false, t0: 0, t1: 0, kinds: {} };
  const now = () => performance.now();
  const site = (skip) => {
    try { const l = (new Error().stack || '').split('\n')[skip] || ''; const s = l.trim().replace(/^at /, ''); return s.length > 140 ? s.slice(0, 140) : s; } catch (e) { return '?'; }
  };
  const head = (f) => { try { return String(f).replace(/\s+/g, ' ').slice(0, 70); } catch (e) { return '?'; } };
  const rec = (kind, key, ms, items) => {
    if (!C.on) return;
    const k = C.kinds[kind] || (C.kinds[kind] = {});
    const e = k[key] || (k[key] = { n: 0, ms: 0, max: 0, items: 0 });
    e.n++; e.ms += ms; e.items += items || 0; if (ms > e.max) e.max = ms;
  };
  const timed = (kind, key, fn, self, args, items) => {
    if (!C.on) return fn.apply(self, args);
    const t = now();
    try { return fn.apply(self, args); } finally { rec(kind, key, now() - t, items); }
  };
  C.start = () => { C.kinds = {}; C.on = true; C.t0 = now(); return 1; };
  C.stop = () => { C.on = false; C.t1 = now(); return 1; };
  C.report = (top) => {
    const secs = Math.max((C.t1 - C.t0) / 1000, 0.001), out = { seconds: +secs.toFixed(2), kinds: {} };
    for (const kind in C.kinds) {
      const rows = Object.entries(C.kinds[kind]).map(([key, e]) => ({ key, n: e.n, perSec: +(e.n / secs).toFixed(2), msPerSec: +(e.ms / secs).toFixed(2), avgMs: +(e.ms / e.n).toFixed(3), maxMs: +e.max.toFixed(1), items: e.items }));
      rows.sort((a, b) => b.msPerSec - a.msPerSec || b.n - a.n);
      out.kinds[kind] = { totalN: rows.reduce((s, r) => s + r.n, 0), totalMsPerSec: +rows.reduce((s, r) => s + r.msPerSec, 0).toFixed(2), rows: rows.slice(0, top || 8) };
    }
    return JSON.stringify(out);
  };

  // timers and frames: keyed by where they were made and what they run
  for (const name of ['setTimeout', 'setInterval']) {
    const orig = window[name];
    window[name] = function (fn, delay) {
      if (typeof fn !== 'function') return orig.apply(this, arguments);
      const key = name + ' ' + (name === 'setInterval' ? 'every ' + delay + ' ' : '') + site(2) + ' | ' + head(fn);
      const args = Array.prototype.slice.call(arguments);
      args[0] = function () { return timed('timers', key, fn, this, arguments); };
      return orig.apply(this, args);
    };
  }
  {
    const orig = window.requestAnimationFrame;
    window.requestAnimationFrame = function (fn) {
      if (typeof fn !== 'function') return orig.apply(this, arguments);
      const key = 'rAF ' + site(2) + ' | ' + head(fn);
      return orig.call(this, function () { return timed('frames', key, fn, this, arguments); });
    };
  }
  // observers: the constructor keeps its prototype (instanceof still works); the callback is timed, the records counted
  for (const name of ['MutationObserver', 'IntersectionObserver', 'ResizeObserver', 'PerformanceObserver']) {
    const Orig = window[name];
    if (typeof Orig !== 'function') continue;
    const W = function (fn, opts) {
      if (typeof fn !== 'function') return new Orig(fn, opts);
      const key = name + ' ' + site(2) + ' | ' + head(fn);
      return new Orig(function (list) { return timed('observers', key, fn, this, arguments, list && (list.length !== undefined ? list.length : (list.getEntries ? list.getEntries().length : 0))); }, opts);
    };
    W.prototype = Orig.prototype;
    window[name] = W;
  }
  // network and messages
  if (window.fetch) {
    const orig = window.fetch;
    window.fetch = function (input, init) {
      if (!C.on) return orig.apply(this, arguments);
      const url = String(input && input.url || input).split('?')[0].slice(-90), t = now();
      const p = orig.apply(this, arguments);
      p.then(() => rec('fetch', ((init && init.method) || 'GET') + ' ' + url, now() - t), () => rec('fetch', 'FAILED ' + url, now() - t));
      return p;
    };
  }
  if (window.XMLHttpRequest) {
    const P = XMLHttpRequest.prototype, open = P.open, send = P.send;
    P.open = function (m, u) { this.__cu = m + ' ' + String(u).split('?')[0].slice(-90); return open.apply(this, arguments); };
    P.send = function () { if (C.on) { const t = now(), k = this.__cu || 'XHR'; this.addEventListener('loadend', () => rec('xhr', k, now() - t)); } return send.apply(this, arguments); };
  }
  if (navigator.sendBeacon) {
    const orig = navigator.sendBeacon;
    navigator.sendBeacon = function (u) { rec('beacon', String(u).split('?')[0].slice(-90), 0); return orig.apply(this, arguments); };
  }
  {
    const orig = window.postMessage;
    window.postMessage = function () { rec('postMessage', site(2), 0); return orig.apply(this, arguments); };
    if (window.MessagePort) {
      const op = MessagePort.prototype.postMessage;
      MessagePort.prototype.postMessage = function () { rec('postMessage', 'port ' + site(2), 0); return op.apply(this, arguments); };
    }
  }
  // reads that force a style pass and a layout; the site is looked up only for the slow ones
  const SLOW = 0.3;
  const readers = [[Element.prototype, ['getBoundingClientRect', 'getClientRects', 'scrollIntoView']]];
  for (const [proto, names] of readers) {
    for (const name of names) {
      const orig = proto[name];
      if (typeof orig !== 'function') continue;
      proto[name] = function () {
        if (!C.on) return orig.apply(this, arguments);
        const t = now();
        try { return orig.apply(this, arguments); } finally { const d = now() - t; rec('layout', name, d); if (d >= SLOW) rec('layout slow', name + ' @ ' + site(2), d); }
      };
    }
  }
  for (const [proto, names] of [[Element.prototype, ['clientWidth', 'clientHeight', 'clientTop', 'clientLeft', 'scrollWidth', 'scrollHeight', 'scrollTop', 'scrollLeft']], [HTMLElement.prototype, ['offsetWidth', 'offsetHeight', 'offsetTop', 'offsetLeft', 'innerText']]]) {
    for (const name of names) {
      const d = Object.getOwnPropertyDescriptor(proto, name);
      if (!d || !d.get) continue;
      const g = d.get;
      Object.defineProperty(proto, name, { configurable: true, enumerable: d.enumerable, set: d.set, get() {
        if (!C.on) return g.call(this);
        const t = now();
        try { return g.call(this); } finally { const dt = now() - t; rec('layout', name, dt); if (dt >= SLOW) rec('layout slow', name + ' @ ' + site(2), dt); }
      } });
    }
  }
  {
    const orig = window.getComputedStyle;
    window.getComputedStyle = function () {
      if (!C.on) return orig.apply(this, arguments);
      const t = now();
      try { return orig.apply(this, arguments); } finally { const d = now() - t; rec('layout', 'getComputedStyle', d); if (d >= SLOW) rec('layout slow', 'getComputedStyle @ ' + site(2), d); }
    };
  }
})();
