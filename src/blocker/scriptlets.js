// Scriptlets of the Wren content blocker. Each one is a small function that changes what the page can see or do: it is
// run before any script of the page by the rule `site##+js(name, arg, ...)`. Names and arguments follow the uBlock
// Origin conventions so that the lists written for it work here. Written for this browser; no code of another project.
// The file is the body of a function called with `(rules)`: an array of [name, arg, ...].
'use strict';
var W = window, D = document;
var S = Object.create(null);
var ALIAS = {
  'set': 'set-constant', 'aopr': 'abort-on-property-read', 'aopw': 'abort-on-property-write', 'acs': 'abort-current-script',
  'abort-current-inline-script': 'abort-current-script', 'acis': 'abort-current-script', 'aost': 'abort-on-stack-trace',
  'nostif': 'no-setTimeout-if', 'prevent-setTimeout': 'no-setTimeout-if', 'setTimeout-defuser': 'no-setTimeout-if',
  'nosiif': 'no-setInterval-if', 'prevent-setInterval': 'no-setInterval-if', 'setInterval-defuser': 'no-setInterval-if',
  'nofetch': 'no-fetch-if', 'prevent-fetch': 'no-fetch-if', 'no-fetch-if': 'no-fetch-if', 'noxhr': 'no-xhr-if', 'prevent-xhr': 'no-xhr-if',
  'aeld': 'addEventListener-defuser', 'prevent-addEventListener': 'addEventListener-defuser', 'addEventListener-logger': 'noop',
  'nowoif': 'window.open-defuser', 'no-window-open-if': 'window.open-defuser', 'window.open-defuser': 'window.open-defuser',
  'ra': 'remove-attr', 'rc': 'remove-class', 'jp': 'json-prune', 'jpfr': 'json-prune-fetch-response', 'jpxhr': 'json-prune-xhr-response',
  'trusted-click-element': 'click-element', 'nano-sib': 'nano-setInterval-booster', 'nano-stb': 'nano-setTimeout-booster',
  'noeval': 'noeval', 'noeval-if': 'noeval', 'rmnt': 'remove-node-text', 'remove-node-text': 'remove-node-text',
  'rpnt': 'replace-node-text', 'replace-node-text': 'replace-node-text', 'set-attr': 'set-attr', 'sa': 'set-attr',
  'disable-newtab-links': 'disable-newtab-links', 'set-cookie': 'set-cookie', 'set-local-storage-item': 'set-local-storage-item',
  'set-session-storage-item': 'set-session-storage-item', 'nowebrtc': 'nowebrtc', 'href-sanitizer': 'href-sanitizer',
  'json-edit': 'noop', 'trusted-replace-fetch-response': 'noop', 'spoof-css': 'noop', 'ubo-noop': 'noop'
};
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
function onReady(f) {
  if (D.readyState === 'loading') D.addEventListener('DOMContentLoaded', f, { once: true }); else f();
}
// Runs f now and after the page's changes, at most once per `delay` ms, where the delay is ten times what f took the last time (at least
// 20 ms): a scriptlet that walks the whole document costs a tenth of the page's time at most, however busy the page is.
function observe(f, stay) {
  var delay = 20;
  var run = function () { var t0 = Date.now(); f(); delay = Math.min(2000, Math.max(20, (Date.now() - t0) * 10)); };
  run();
  if (!stay || typeof MutationObserver === 'undefined') return;
  var t = 0;
  new MutationObserver(function () { if (t) return; t = setTimeout(function () { t = 0; run(); }, delay); }).observe(D.documentElement, { childList: true, subtree: true, attributes: true });
}
// Calls visit(n) once for each text node that is a direct child of an element named `mn`, as the page adds them (and again for one whose
// text changes, unless visit changed it: it returns true then). Not a walk of the whole document at every change: the elements are
// those of the tag, a live list. (A page like YouTube has 10 000 text nodes and changes every few milliseconds while it starts.)
function eachNodeText(mn, visit) {
  var seen = new WeakSet(), mine = new WeakSet();
  var scan = function () {
    var els = D.getElementsByTagName(mn);
    for (var i = 0; i < els.length; i++) {
      for (var n = els[i].firstChild; n; n = n.nextSibling) {
        if (n.nodeType !== 3 || seen.has(n)) continue;
        seen.add(n);
        if (visit(n)) mine.add(n);
      }
    }
  };
  onReady(function () {
    try { scan(); } catch (e) {}
    if (typeof MutationObserver === 'undefined') return;
    var t = 0;
    new MutationObserver(function (recs) {
      for (var i = 0; i < recs.length; i++) {
        var r = recs[i];
        if (r.type === 'characterData') { if (mine.has(r.target)) mine.delete(r.target); else seen.delete(r.target); }
      }
      if (!t) t = setTimeout(function () { t = 0; try { scan(); } catch (e) {} }, 20);
    }).observe(D.documentElement, { childList: true, subtree: true, characterData: true });
  });
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
S['json-prune-fetch-response'] = function (paths, required, urlNeedle, stack) {
  if (typeof W.fetch !== 'function' || typeof Response === 'undefined') return;
  var ps = list(paths), rs = list(required), mu = matcher(urlNeedle), orig = W.fetch;
  W.fetch = function (input) {
    var url = typeof input === 'string' ? input : (input && input.url) || '';
    var p = orig.apply(this, arguments);
    if (!mu(url)) return p;
    return p.then(function (res) {
      return res.clone().text().then(function (t) {
        var o;
        try { o = JSON.parse(t); } catch (e) { return res; }
        if (!pruneIn(o, ps, rs)) return res;
        var out = new Response(JSON.stringify(o), { status: res.status, statusText: res.statusText, headers: res.headers });
        try { Object.defineProperty(out, 'url', { value: res.url }); } catch (e) {}
        return out;
      });
    });
  };
};
S['json-prune-xhr-response'] = function (paths, required, urlNeedle) {
  if (typeof W.XMLHttpRequest !== 'function') return;
  var ps = list(paths), rs = list(required), mu = matcher(urlNeedle), P = W.XMLHttpRequest.prototype, open = P.open;
  P.open = function (m, u) {
    var url = String(u), self = this;
    if (mu(url)) this.addEventListener('readystatechange', function () {
      if (self.readyState !== 4 || self.__wbd) return;
      var t = self.responseType === '' || self.responseType === 'text' ? self.responseText : null;
      if (t === null) return;
      try { var o = JSON.parse(t); if (pruneIn(o, ps, rs)) { self.__wbd = 1; var s = JSON.stringify(o); Object.defineProperty(self, 'responseText', { value: s }); Object.defineProperty(self, 'response', { value: s }); } } catch (e) {}
    });
    return open.apply(this, arguments);
  };
};
S['remove-attr'] = function (attrs, selector, behavior) {
  var names = String(attrs).split('|'), sel = selector || '[' + names.join('],[') + ']', stay = /stay/.test(behavior || '');
  var f = function () { try { D.querySelectorAll(sel).forEach(function (e) { names.forEach(function (a) { e.removeAttribute(a); }); }); } catch (e) {} };
  onReady(function () { observe(f, stay || !/asap/.test(behavior || '')); });
  if (/asap/.test(behavior || '')) f();
};
S['remove-class'] = function (classes, selector, behavior) {
  var names = String(classes).split('|'), sel = selector || '.' + names.join(',.'), stay = /stay/.test(behavior || '');
  var f = function () { try { D.querySelectorAll(sel).forEach(function (e) { names.forEach(function (c) { e.classList.remove(c); }); }); } catch (e) {} };
  onReady(function () { observe(f, stay || !/asap/.test(behavior || '')); });
};
S['set-attr'] = function (selector, attr, value) {
  var f = function () { try { D.querySelectorAll(selector).forEach(function (e) { e.setAttribute(attr, value === undefined ? '' : value); }); } catch (e) {} };
  onReady(function () { observe(f, true); });
};
S['click-element'] = function (selectors, extra, delay) {
  var sels = String(selectors).split(/\s*,\s*/).filter(Boolean), i = 0, d = Number(delay) || 0, tries = 0;
  function step() {
    if (i >= sels.length || tries++ > 600) return;
    var e = null; try { e = D.querySelector(sels[i]); } catch (x) { return; }
    if (e) { i++; setTimeout(function () { try { e.click(); } catch (x) {} step(); }, d); return; }
    setTimeout(step, 50);
  }
  onReady(step);
};
S['remove-node-text'] = function (nodeName, condition) {
  var mn = String(nodeName).toLowerCase(), mc = matcher(condition);
  eachNodeText(mn, function (n) { if (mc(n.nodeValue)) { n.nodeValue = ''; return true; } return false; });
};
S['replace-node-text'] = function (nodeName, pattern, replacement, c1, c2) {
  var mn = String(nodeName).toLowerCase(), re;
  try { var m = /^\/(.+)\/([gimsuy]*)$/.exec(pattern); re = m ? new RegExp(m[1], m[2]) : new RegExp(String(pattern).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g'); } catch (e) { return; }
  eachNodeText(mn, function (n) {
    var hit = false;
    try { var text = n.nodeValue; if (re.test(text)) { re.lastIndex = 0; n.nodeValue = text.replace(re, replacement === undefined ? '' : replacement); hit = true; } } catch (e) {}
    re.lastIndex = 0;
    return hit;
  });
};
S['disable-newtab-links'] = function () {
  D.addEventListener('click', function (ev) { var a = ev.target && ev.target.closest && ev.target.closest('a[target="_blank"]'); if (a) { ev.preventDefault(); } }, true);
};
S['href-sanitizer'] = function (selector, attr) {
  var f = function () { try { D.querySelectorAll(selector).forEach(function (a) { var h = a.getAttribute(attr || 'href') || ''; try { var u = new URL(h, location.href); var q = u.searchParams; var inner = q.get('url') || q.get('u') || q.get('q'); if (inner && /^https?:/.test(inner)) a.setAttribute('href', inner); } catch (e) {} }); } catch (e) {} };
  onReady(function () { observe(f, true); });
};
S['set-cookie'] = function (name, value, path) { try { D.cookie = name + '=' + value + '; path=' + (path === 'none' ? '/' : (path || '/')); } catch (e) {} };
S['set-local-storage-item'] = function (key, value) { try { W.localStorage.setItem(key, String(toValue(value))); } catch (e) {} };
S['set-session-storage-item'] = function (key, value) { try { W.sessionStorage.setItem(key, String(toValue(value))); } catch (e) {} };
S['noop'] = noop;

for (var i = 0; i < rules.length; i++) {
  var r = rules[i], name = stripJs(r[0]);
  var f = S[name] || S[ALIAS[name]];
  if (typeof f !== 'function') continue;
  try { f.apply(null, r.slice(1)); } catch (e) {}
}
