// ext_api.js: chrome.* in an extension context (docs/extensions.md, section 3.9), built from what the browser lists for
// this context (Ext_info: its methods, events and local members, decided by its permissions and its kind, and the
// constants of its namespaces; all generated from api/ext_<namespace>.widl into src/page/ext_api_generated.odin). The
// arguments are matched to their signature and checked by the browser (one decoder per method). Evaluated by
// ext_runtime.odin (prelude_call) with the natives of module ext and the global; returns the event pump the browser
// calls (wj_ext_event).
//   * A method returns a promise. If its last argument is a function, the method calls it with the result and returns
//     undefined; on an error, chrome.runtime.lastError is set during that callback, and an unread one is logged.
//   * Messages and call arguments are JSON, as in Chrome: a value JSON cannot hold arrives as null. The browser puts a
//     message's JSON text into the event's JSON as it is (no second encoding).
(function (native, global) {
  "use strict";
  const info = JSON.parse(native.info());
  const listeners = new Map();   // event name -> [functions]
  const ports = new Map();       // port id -> Port
  let lastError;                 // {message}
  let lastErrorRead = true;

  const encode = (v) => { const t = JSON.stringify(v); return t === undefined ? "null" : t; };
  const decode = (text) => {
    if (text === "") return undefined;
    if (text[0] === "!") throw new Error(text.slice(1));
    return JSON.parse(text);
  };
  const report = (e) => { try { console.error(e); } catch (_) {} };

  // A call of `name` with `args` (an array; a function at its end is the callback).
  function invoke(name, args, promiseOnly) {
    let cb;
    if (!promiseOnly && args.length > 0 && typeof args[args.length - 1] === "function") cb = args.pop();
    while (args.length > 0 && args[args.length - 1] === undefined) args.pop();
    let text;
    try { text = JSON.stringify(args); } catch (e) { return fail(cb, e); }
    const p = native.call(name, text).then(decode);
    if (cb === undefined) return p;
    p.then((v) => cb(v), (e) => withLastError(e, cb));
    return undefined;
  }
  function fail(cb, e) {
    if (cb === undefined) return Promise.reject(e);
    withLastError(e, cb);
    return undefined;
  }
  function withLastError(e, cb) {
    lastError = { message: (e && e.message) || String(e) };
    lastErrorRead = false;
    try { cb(); } finally {
      if (!lastErrorRead) report("Unchecked runtime.lastError: " + lastError.message);
      lastError = undefined;
      lastErrorRead = true;
    }
  }

  // An event object (chrome.runtime.onMessage...). `name` null: a port's own event, which the browser does not track.
  class ExtEvent {
    constructor(name) { this._name = name; }
    addListener(f) {
      if (typeof f !== "function") throw new TypeError("addListener: the listener is not a function");
      let list = listeners.get(this._key());
      if (!list) { list = []; listeners.set(this._key(), list); }
      if (list.includes(f)) return;
      list.push(f);
      if (list.length === 1 && this._name !== null) native.listen(this._name, true);
    }
    removeListener(f) {
      const list = listeners.get(this._key());
      if (!list) return;
      const i = list.indexOf(f);
      if (i < 0) return;
      list.splice(i, 1);
      if (list.length === 0 && this._name !== null) native.listen(this._name, false);
    }
    hasListener(f) { const list = listeners.get(this._key()); return !!list && list.includes(f); }
    hasListeners() { const list = listeners.get(this._key()); return !!list && list.length > 0; }
    _key() { if (this._name !== null) return this._name; if (!this._own) this._own = Symbol(); return this._own; }
  }
  function dispatch(key, args) {
    const list = listeners.get(key);
    if (!list) return [];
    const out = [];
    for (const f of list.slice()) {
      try { out.push(f(...args)); } catch (e) { report(e); }
    }
    return out;
  }

  class Port {
    constructor(id, name, sender) {
      this._id = id;
      this._open = true;
      this.name = name;
      if (sender !== undefined) this.sender = sender;
      this.onMessage = new ExtEvent(null);
      this.onDisconnect = new ExtEvent(null);
      ports.set(id, this);
    }
    postMessage(m) {
      if (!this._open) throw new Error("Attempting to use a disconnected port object");
      native.portPost(this._id, encode(m));
    }
    disconnect() {
      if (!this._open) return;
      this._open = false;
      ports.delete(this._id);
      native.portClose(this._id);
    }
  }
  const newPortId = () => Math.floor(Math.random() * 4503599627370496) + 1;

  // The members a context answers itself ([Local] in api/ext_<namespace>.widl): installed when the browser lists them
  // for this context (info.local), as the routed methods are.
  const isId = (s) => typeof s === "string" && /^[a-p]{32}$/.test(s);
  const answer = (v, cb) => { if (typeof cb === "function") { cb(v); return undefined; } return Promise.resolve(v); };
  const value = (v) => (o, k) => { o[k] = v; };
  const LOCAL = {
    "runtime.id": value(info.id),
    "runtime.lastError": (o, k) => Object.defineProperty(o, k, {
      get() { lastErrorRead = true; return lastError; }, enumerable: true, configurable: true,
    }),
    "runtime.getURL": value((p) => info.base + String(p).replace(/^\/+/, "")),
    "runtime.getManifest": value(() => JSON.parse(native.manifest())),
    // connect([extensionId], [connectInfo])
    "runtime.connect": value(function (a, b) {
      const ci = (typeof a === "object" && a !== null) ? a : (b || {});
      const id = newPortId();
      const name = ci.name === undefined ? "" : String(ci.name);
      const port = new Port(id, name, undefined);
      native.connect(id, name);
      return port;
    }),
    "i18n.getMessage": value((name, subs) => {
      const list = subs === undefined || subs === null ? [] : (Array.isArray(subs) ? subs : [subs]);
      return native.message(String(name), JSON.stringify(list.slice(0, 9).map(String)));
    }),
    "i18n.getUILanguage": value(() => info.lang),
    "i18n.getAcceptLanguages": value((cb) => answer([info.lang], cb)),
    "extension.inIncognitoContext": value(false),
    "extension.getViews": value(() => []),
    "extension.getBackgroundPage": value(() => null),
    "extension.isAllowedIncognitoAccess": value((cb) => answer(false, cb)),
    "extension.isAllowedFileSchemeAccess": value((cb) => answer(false, cb)),
  };

  // runtime.sendMessage([extensionId], message, [options], [callback]): another extension's id has no receiver (no
  // message between extensions), so only the message reaches the browser.
  function sendMessage(promiseOnly, a) {
    const cb = !promiseOnly && typeof a[a.length - 1] === "function" ? a.pop() : undefined;
    let id = null, msg;
    if (a.length >= 3 || (a.length === 2 && (a[0] === null || a[0] === undefined || isId(a[0])))) { id = a[0]; msg = a[1]; } else { msg = a[0]; }
    if (id !== null && id !== undefined && id !== info.id) return fail(cb, new Error("Could not establish connection. Receiving end does not exist."));
    const args = [msg === undefined ? null : msg];
    if (cb !== undefined) args.push(cb);
    return invoke("runtime.sendMessage", args);
  }

  // ImageData has no JSON form: the icon stays the manifest's until paths are given (drawn icons come later)
  function setIcon(promiseOnly, a) {
    const d = Object.assign({}, a[0]);
    if (d.imageData !== undefined) { d.imageData = true; }
    const args = [d];
    if (!promiseOnly && typeof a[1] === "function") args.push(a[1]);
    return invoke("action.setIcon", args);
  }
  const SPECIAL = { "runtime.sendMessage": sendMessage, "action.setIcon": setIcon };

  // The namespaces: an object per dotted path, a method per listed method, an event per listed event, the constants of
  // each namespace that exists. `promiseOnly`: browser.* of the Firefox flavour (a function argument is data there).
  // The events are the same objects in both trees: a listener added through one is seen through the other.
  const events = new Map();
  function build(promiseOnly) {
    const root = {};
    const path = (dotted) => {
      let o = root;
      for (const part of dotted) { if (!(part in o)) o[part] = {}; o = o[part]; }
      return o;
    };
    const find = (dotted) => {
      let o = root;
      for (const part of dotted) { if (!(part in o)) return undefined; o = o[part]; }
      return o;
    };
    for (const name of info.methods) {
      const parts = name.split(".");
      const leaf = parts.pop();
      const special = SPECIAL[name];
      path(parts)[leaf] = special !== undefined
        ? function () { return special(promiseOnly, Array.prototype.slice.call(arguments)); }
        : function () { return invoke(name, Array.prototype.slice.call(arguments), promiseOnly); };
    }
    for (const name of info.events) {
      const parts = name.split(".");
      const leaf = parts.pop();
      if (!events.has(name)) events.set(name, new ExtEvent(name));
      path(parts)[leaf] = events.get(name);
    }
    for (const name of info.local) {
      const install = LOCAL[name];
      if (install === undefined) continue;
      const parts = name.split(".");
      const leaf = parts.pop();
      install(path(parts), leaf);
    }
    for (const ns of Object.keys(info.constants)) {
      const o = find(ns.split("."));
      if (o !== undefined) Object.assign(o, info.constants[ns]);
    }
    return root;
  }
  const chrome = build(false);
  Object.defineProperty(global, "chrome", { value: chrome, writable: true, configurable: true, enumerable: false });
  if (info.flavour === "firefox") {
    Object.defineProperty(global, "browser", { value: build(true), writable: true, configurable: true, enumerable: false });
  }

  // runtime.onMessage: the first listener that answers (sendResponse, `return true` then sendResponse, or a promise)
  // gives the answer; when none keeps the channel open, the sender learns there is no answer from here.
  function deliverMessage(ev) {
    const reply = ev.r || 0;
    let responded = false;
    let keep = false;
    const answer = (text, has) => { if (responded || reply === 0) return; responded = true; native.respond(reply, text, has); };
    const sendResponse = (v) => { let t; try { t = v === undefined ? "" : encode(v); } catch (e) { t = "!" + e.message; } answer(t, true); };
    const list = listeners.get("runtime.onMessage") || [];
    for (const f of list.slice()) {
      let r;
      try { r = f(ev.a[0], ev.a[1], sendResponse); } catch (e) { report(e); continue; }
      if (r === true) keep = true;
      else if (r && typeof r.then === "function") {
        keep = true;
        r.then(sendResponse, (e) => answer("!" + ((e && e.message) || String(e)), true));
      }
    }
    if (!keep) answer("", false);
  }

  return function pump() {
    for (;;) {
      const text = native.take();
      if (text === "") return;
      let ev;
      try { ev = JSON.parse(text); } catch (e) { report(e); continue; }
      switch (ev.t) {
        case "event":
          if (ev.e === "runtime.onMessage") deliverMessage(ev);
          else dispatch(ev.e, ev.a || []);
          break;
        case "connect": {
          const port = new Port(ev.p, ev.n, ev.s);
          dispatch("runtime.onConnect", [port]);
          break;
        }
        case "port": {
          const port = ports.get(ev.p);
          if (port) dispatch(port.onMessage._key(), [ev.m, port]);
          break;
        }
        case "disconnect": {
          const port = ports.get(ev.p);
          if (port) { port._open = false; ports.delete(ev.p); dispatch(port.onDisconnect._key(), [port]); }
          break;
        }
      }
    }
  };
})
