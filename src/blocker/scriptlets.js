// Scriptlets of the Wren content blocker. Each one is a small function that changes what the page can see or do: it is
// run before any script of the page by the rule `site##+js(name, arg, ...)`. Names and arguments follow the uBlock
// Origin conventions so that the lists written for it work here. Written for this browser; no code of another project.
// The file is the body of a function called with `(rules)`: an array of [name, arg, ...].
'use strict';
var W = window, D = document;
var S = Object.create(null);
var ALIAS = {};   // (the browser sends canonical names)
function stripJs(n) { n = String(n).trim(); return n.replace(/\.js$/, ''); }
function noop() {}
function yes() { return true; }
function no() { return false; }
function noopPromise() { return Promise.resolve(); }
function ReferenceErr() { var s = ''; for (var i = 0; i < 12; i++) s += String.fromCharCode(97 + Math.floor(Math.random() * 26)); return new ReferenceError(s + ' is not defined'); }
// 'text' or '/regex/flags': a test function; an empty pattern matches everything
function matcher(p) {
  if (p === undefined || p === '' || p === null) return function () { return true; };
  p = String(p);
  var neg = false;
  if (p.charAt(0) === '!') { neg = true; p = p.slice(1); }
  var m = /^\/(.+)\/([gimsuy]*)$/.exec(p), f;
  if (m) { try { var r = new RegExp(m[1], m[2].replace(/[gy]/g, '')); f = function (x) { return r.test(String(x)); }; } catch (e) { f = function () { return false; }; } }
  else f = function (x) { return String(x).indexOf(p) !== -1; };
  return neg ? function (x) { return !f(x); } : f;
}
function toValue(v) {
  switch (v) {
    case 'undefined': return undefined; case 'false': return false; case 'true': return true; case 'null': return null;
    case 'emptyObj': return {}; case 'emptyArr': return []; case 'noopFunc': return noop; case 'trueFunc': return yes; case 'falseFunc': return no;
    case 'throwFunc': return function () { throw ReferenceErr(); }; case 'noopPromiseResolve': return function () { return Promise.resolve({}); };
    case 'noopPromiseReject': return function () { return Promise.reject(); }; case '': return ''; case 'yes': return 'yes'; case 'no': return 'no';
    case 'NaN': return NaN; case 'Infinity': return Infinity; case '-Infinity': return -Infinity;
  }
  if (/^-?\d+(\.\d+)?$/.test(v)) { var n = Number(v); if (Math.abs(n) <= 32767) return n; }
  return String(v);
}
// Walks `chain` (a.b.c) from `owner`, waiting for the objects that do not exist yet; calls leaf(object, property).
function trap(owner, chain, i, leaf) {
  var prop = chain[i];
  if (i === chain.length - 1) { leaf(owner, prop); return; }
  var cur;
  try { cur = owner[prop]; } catch (e) { return; }
  if (cur !== null && (typeof cur === 'object' || typeof cur === 'function')) { trap(cur, chain, i + 1, leaf); return; }
  var d = Object.getOwnPropertyDescriptor(owner, prop);
  if (d && d.configurable === false) return;
  var val = cur;
  try {
    Object.defineProperty(owner, prop, {
      configurable: true, enumerable: true,
      get: function () { return val; },
      set: function (v) { val = v; if (v !== null && (typeof v === 'object' || typeof v === 'function')) trap(v, chain, i + 1, leaf); }
    });
  } catch (e) {}
}
function onPath(path, leaf) { trap(W, String(path).split('.'), 0, leaf); }
function currentScriptMatches(needle) {
  var s = D.currentScript;
  if (!s) return needle === '';
  if (needle === '' || needle === undefined) return true;
  var m = matcher(needle);
  return m(s.textContent || '') || m(s.src || '');
}
function pruneIn(obj, paths, required, depth) {
  if (!obj || typeof obj !== 'object' || (depth || 0) > 8) return false;
  var hit = false;
  function resolve(o, parts, k, del) {
    if (o === null || typeof o !== 'object') return false;
    var key = parts[k];
    if (key === '*' || key === '[]') {
      var any = false;
      for (var p in o) { if (k === parts.length - 1) { if (del) delete o[p]; any = true; } else if (resolve(o[p], parts, k + 1, del)) any = true; }
      return any;
    }
    if (!(key in o)) return false;
    if (k === parts.length - 1) { if (del) delete o[key]; return true; }
    return resolve(o[key], parts, k + 1, del);
  }
  if (required.length) {
    for (var i = 0; i < required.length; i++) if (!resolve(obj, required[i].split('.'), 0, false)) return false;
  }
  for (var j = 0; j < paths.length; j++) if (resolve(obj, paths[j].split('.'), 0, true)) hit = true;
  return hit;
}
function list(s) { return String(s === undefined ? '' : s).split(/\s+/).filter(Boolean); }

S['set-constant'] = function (chain, value, how) {
  var v = toValue(value === undefined ? 'undefined' : value);
  onPath(chain, function (o, p) {
    if (how === 'aborted' && !(p in o)) return;
    try { Object.defineProperty(o, p, { configurable: true, enumerable: true, get: function () { return v; }, set: function () {} }); } catch (e) {}
  });
};
S['abort-on-property-read'] = function (chain) {
  onPath(chain, function (o, p) { try { Object.defineProperty(o, p, { configurable: true, get: function () { throw ReferenceErr(); }, set: function () {} }); } catch (e) {} });
};
S['abort-on-property-write'] = function (chain) {
  onPath(chain, function (o, p) {
    var v = o[p];
    try { Object.defineProperty(o, p, { configurable: true, get: function () { return v; }, set: function () { throw ReferenceErr(); } }); } catch (e) {}
  });
};
S['abort-current-script'] = function (chain, needle, context) {
  onPath(chain, function (o, p) {
    var v = o[p];
    try {
      Object.defineProperty(o, p, {
        configurable: true,
        get: function () { if (currentScriptMatches(needle)) throw ReferenceErr(); return v; },
        set: function (x) { if (currentScriptMatches(needle)) throw ReferenceErr(); v = x; }
      });
    } catch (e) {}
  });
};
S['abort-on-stack-trace'] = function (chain, needle) {
  var m = matcher(needle);
  onPath(chain, function (o, p) {
    var v = o[p];
    try { Object.defineProperty(o, p, { configurable: true, get: function () { if (m(new Error().stack)) throw ReferenceErr(); return v; }, set: function (x) { if (m(new Error().stack)) throw ReferenceErr(); v = x; } }); } catch (e) {}
  });
};
function timerDefuser(name) {
  return function (needle, delay) {
    var orig = W[name], mn = matcher(needle), md = delay === undefined || delay === '' ? null : String(delay);
    W[name] = function (cb, d) {
      var src = typeof cb === 'function' ? Function.prototype.toString.call(cb) : String(cb);
      if (mn(src) && (md === null || String(d) === md || (md.charAt(0) === '!' && String(d) !== md.slice(1)))) return 0;
      return orig.apply(this, arguments);
    };
  };
}
S['no-setTimeout-if'] = timerDefuser('setTimeout');
S['no-setInterval-if'] = timerDefuser('setInterval');
function booster(name) {
  return function (needle, delay, boost) {
    var orig = W[name], mn = matcher(needle), dl = delay === undefined || delay === '' || delay === '*' ? null : Number(delay), b = boost === undefined ? 0.05 : Number(boost);
    if (!(b >= 0.001 && b <= 50)) b = 0.05;
    W[name] = function (cb, d) {
      var src = typeof cb === 'function' ? Function.prototype.toString.call(cb) : String(cb);
      if (mn(src) && (dl === null || Number(d) === dl)) arguments[1] = Math.max(Math.floor(Number(d) * b), 0);
      return orig.apply(this, arguments);
    };
  };
}
S['nano-setInterval-booster'] = booster('setInterval');
S['nano-setTimeout-booster'] = booster('setTimeout');
S['no-fetch-if'] = function (needle, responseBody) {
  if (typeof W.fetch !== 'function') return;
  var orig = W.fetch, parts = list(needle), tests = [];
  parts.forEach(function (p) { var i = p.indexOf(':'); tests.push(i > 0 && /^[a-z]+$/.test(p.slice(0, i)) ? [p.slice(0, i), matcher(p.slice(i + 1))] : ['url', matcher(p)]); });
  W.fetch = function (input, init) {
    var url = typeof input === 'string' ? input : (input && input.url) || String(input), o = init || {};
    var ok = tests.every(function (t) { var v = t[0] === 'url' ? url : (t[0] === 'method' ? (o.method || (input && input.method) || 'GET') : (o[t[0]] === undefined ? '' : String(o[t[0]]))); return t[1](v); });
    if (!ok) return orig.apply(this, arguments);
    var body = responseBody === 'emptyStr' ? '' : '{}';
    try { return Promise.resolve(new Response(body, { status: 200, statusText: 'OK' })); } catch (e) { return Promise.resolve({ ok: true, status: 200, text: function () { return Promise.resolve(body); }, json: function () { return Promise.resolve({}); }, clone: function () { return this; } }); }
  };
};
S['no-xhr-if'] = function (needle) {
  if (typeof W.XMLHttpRequest !== 'function') return;
  var P = W.XMLHttpRequest.prototype, open = P.open, send = P.send, parts = list(needle), tests = parts.map(function (p) { var i = p.indexOf(':'); return i > 0 && /^[a-z]+$/.test(p.slice(0, i)) ? [p.slice(0, i), matcher(p.slice(i + 1))] : ['url', matcher(p)]; });
  P.open = function (method, url) { this.__wbm = String(method); this.__wbu = String(url); return open.apply(this, arguments); };
  P.send = function () {
    var self = this;
    if (tests.every(function (t) { return t[0] === 'method' ? t[1](self.__wbm) : t[1](self.__wbu); })) {
      try { Object.defineProperty(this, 'readyState', { value: 4 }); Object.defineProperty(this, 'status', { value: 200 }); Object.defineProperty(this, 'responseText', { value: '' }); Object.defineProperty(this, 'response', { value: '' }); } catch (e) {}
      setTimeout(function () { try { if (typeof self.onreadystatechange === 'function') self.onreadystatechange(); self.dispatchEvent(new Event('readystatechange')); self.dispatchEvent(new Event('load')); self.dispatchEvent(new Event('loadend')); } catch (e) {} }, 1);
      return;
    }
    return send.apply(this, arguments);
  };
};
S['addEventListener-defuser'] = function (type, needle) {
  if (!W.EventTarget) return;
  var P = W.EventTarget.prototype, orig = P.addEventListener, mt = matcher(type), mn = matcher(needle);
  P.addEventListener = function (t, h) {
    var src = '';
    try { src = typeof h === 'function' ? Function.prototype.toString.call(h) : (h && typeof h.handleEvent === 'function' ? Function.prototype.toString.call(h.handleEvent) : ''); } catch (e) {}
    if (mt(t) && mn(src)) return;
    return orig.apply(this, arguments);
  };
};
S['window.open-defuser'] = function (needle, delay, replacement) {
  var orig = W.open, mn = matcher(needle);
  W.open = function (url) {
    if (mn(url === undefined ? '' : url)) {
      if (replacement === 'obj') return new Proxy(function () {}, { get: function () { return noop; } });
      return null;
    }
    return orig.apply(this, arguments);
  };
};
S['noeval'] = function () { W.eval = noop; };
S['nowebrtc'] = function () { ['RTCPeerConnection', 'webkitRTCPeerConnection', 'mozRTCPeerConnection'].forEach(function (n) { if (W[n]) W[n] = function () { return { createDataChannel: noop, close: noop, addEventListener: noop, createOffer: noopPromise, setLocalDescription: noopPromise }; }; }); };
S['json-prune'] = function (paths, required, stack) {
  var ps = list(paths), rs = list(required), ms = stack ? matcher(stack) : null;
  var orig = JSON.parse;
  JSON.parse = function () {
    var r = orig.apply(this, arguments);
    if (ms && !ms(new Error().stack)) return r;
    try { pruneIn(r, ps, rs); } catch (e) {}
    return r;
  };
};
S['noop'] = noop;

for (var i = 0; i < rules.length; i++) {
  var r = rules[i], name = stripJs(r[0]);
  var f = S[name] || S[ALIAS[name]];
  if (typeof f !== 'function') continue;
  try { f.apply(null, r.slice(1)); } catch (e) {}
}
