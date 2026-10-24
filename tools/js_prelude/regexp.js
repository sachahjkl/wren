// WREN_JS_PRELUDE: time every regular expression the page runs. window.__rx() returns the ones that cost most:
// source/flags, calls, total ms, longest input, and the stack of the slowest call.
(function () {
  const stat = new Map();
  const now = () => performance.now();
  function note(re, input, ms, how) {
    const k = re.source + '/' + re.flags;
    let s = stat.get(k);
    if (!s) { s = { re: k.length > 160 ? k.slice(0, 160) + '...' : k, calls: 0, ms: 0, maxLen: 0, worst: 0, stack: '', how }; stat.set(k, s); }
    s.calls++; s.ms += ms;
    const len = typeof input === 'string' ? input.length : 0;
    if (len > s.maxLen) s.maxLen = len;
    if (ms > s.worst) { s.worst = ms; if (ms > 1) s.stack = new Error().stack.split('\n').slice(2, 7).join(' | '); }
  }
  const P = RegExp.prototype;
  for (const name of ['test', 'exec', Symbol.replace, Symbol.match, Symbol.split, Symbol.search, Symbol.matchAll]) {
    const orig = P[name];
    if (typeof orig !== 'function') continue;
    Object.defineProperty(P, name, { configurable: true, writable: true, value: function (...a) {
      const t = now();
      try { return orig.apply(this, a); } finally { note(this, a[0], now() - t, String(name)); }
    } });
  }
  window.__rx = function (n) {
    return JSON.stringify([...stat.values()].sort((a, b) => b.ms - a.ms).slice(0, n || 8), null, 1);
  };
  if (typeof setInterval === 'function') setInterval(function () {
    const top = [...stat.values()].sort((a, b) => b.ms - a.ms).slice(0, 3).map(s => s.how + ' ' + s.calls + 'x ' + s.ms.toFixed(0) + 'ms max ' + s.maxLen + ' ' + s.re.slice(0, 60));
    console.log('RX ' + location.href.slice(0, 50) + ' :: ' + top.join(' || '));
  }, 4000);
})();