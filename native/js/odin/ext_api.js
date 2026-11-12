// ext_api.js: chrome.* in an extension context (docs/extensions.md, section 3.9), built from what the browser lists for
// this context (Ext_info: its methods and events, decided by its permissions and its kind). Evaluated by
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
  function invoke(name, args) {
    let cb;
    if (args.length > 0 && typeof args[args.length - 1] === "function") cb = args.pop();
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

  // The namespaces: an object per dotted path, a method per listed method, an event per listed event.
  const chrome = {};
  const path = (dotted) => {
    let o = chrome;
    for (const part of dotted) { if (!(part in o)) o[part] = {}; o = o[part]; }
    return o;
  };
  for (const name of info.methods) {
    const parts = name.split(".");
    const leaf = parts.pop();
    path(parts)[leaf] = function () { return invoke(name, Array.prototype.slice.call(arguments)); };
  }
  for (const name of info.events) {
    const parts = name.split(".");
    const leaf = parts.pop();
    path(parts)[leaf] = new ExtEvent(name);
  }

  // runtime: what answers from the extension itself, without the browser's loop
  const runtime = path(["runtime"]);
  runtime.id = info.id;
  runtime.getURL = (p) => info.base + String(p).replace(/^\/+/, "");
  runtime.getManifest = () => JSON.parse(native.manifest());
  Object.defineProperty(runtime, "lastError", {
    get() { lastErrorRead = true; return lastError; }, enumerable: true, configurable: true,
  });
  const isId = (s) => typeof s === "string" && /^[a-p]{32}$/.test(s);
  if (runtime.sendMessage) {
    // sendMessage([extensionId], message, [options], [callback])
    runtime.sendMessage = function () {
      const a = Array.prototype.slice.call(arguments);
      const cb = typeof a[a.length - 1] === "function" ? a.pop() : undefined;
      let id = null, msg;
      if (a.length >= 3 || (a.length === 2 && (a[0] === null || a[0] === undefined || isId(a[0])))) { id = a[0]; msg = a[1]; } else { msg = a[0]; }
      if (id !== null && id !== undefined && id !== info.id) return fail(cb, new Error("Could not establish connection. Receiving end does not exist."));
      const args = [msg === undefined ? null : msg];
      if (cb !== undefined) args.push(cb);
      return invoke("runtime.sendMessage", args);
    };
  }
  if (runtime.onConnect) {
    // connect([extensionId], [connectInfo])
    runtime.connect = function (a, b) {
      const ci = (typeof a === "object" && a !== null) ? a : (b || {});
      const id = newPortId();
      const name = ci.name === undefined ? "" : String(ci.name);
      const port = new Port(id, name, undefined);
      native.connect(id, name);
      return port;
    };
  }
  runtime.OnInstalledReason = { INSTALL: "install", UPDATE: "update", CHROME_UPDATE: "chrome_update", SHARED_MODULE_UPDATE: "shared_module_update" };
  runtime.PlatformOs = { MAC: "mac", WIN: "win", ANDROID: "android", CROS: "cros", LINUX: "linux", OPENBSD: "openbsd", FUCHSIA: "fuchsia" };
  runtime.ContextType = { TAB: "TAB", POPUP: "POPUP", BACKGROUND: "BACKGROUND", OFFSCREEN_DOCUMENT: "OFFSCREEN_DOCUMENT", SIDE_PANEL: "SIDE_PANEL", DEVELOPER_TOOLS: "DEVELOPER_TOOLS" };

  // (an offscreen document has runtime only, as in Chrome)
  if (info.kind !== "offscreen") {
    const i18n = path(["i18n"]);
    i18n.getMessage = (name, subs) => {
      const list = subs === undefined || subs === null ? [] : (Array.isArray(subs) ? subs : [subs]);
      return native.message(String(name), JSON.stringify(list.slice(0, 9).map(String)));
    };
    i18n.getUILanguage = () => info.lang;
    i18n.getAcceptLanguages = (cb) => { const v = [info.lang]; if (typeof cb === "function") { cb(v); return undefined; } return Promise.resolve(v); };
  }

  if (info.kind !== "content" && info.kind !== "offscreen") {
    const extension = path(["extension"]);
    extension.inIncognitoContext = false;
    extension.getViews = () => [];
    extension.getBackgroundPage = () => null;
    extension.isAllowedIncognitoAccess = (cb) => { if (typeof cb === "function") { cb(false); return undefined; } return Promise.resolve(false); };
    extension.isAllowedFileSchemeAccess = (cb) => { if (typeof cb === "function") { cb(false); return undefined; } return Promise.resolve(false); };
  }
  if (chrome.storage) {
    const s = chrome.storage;
    if (s.local) { s.local.QUOTA_BYTES = 10485760; }
    if (s.session) { s.session.QUOTA_BYTES = 10485760; }
    if (s.sync) { Object.assign(s.sync, { QUOTA_BYTES: 102400, QUOTA_BYTES_PER_ITEM: 8192, MAX_ITEMS: 512, MAX_WRITE_OPERATIONS_PER_HOUR: 1800, MAX_WRITE_OPERATIONS_PER_MINUTE: 120 }); }
  }
  if (chrome.tabs) {
    chrome.tabs.TAB_ID_NONE = -1; chrome.tabs.TAB_INDEX_NONE = -1;
    chrome.tabs.TabStatus = { UNLOADED: "unloaded", LOADING: "loading", COMPLETE: "complete" };
  }
  if (chrome.windows) {
    chrome.windows.WINDOW_ID_NONE = -1; chrome.windows.WINDOW_ID_CURRENT = -2;
    chrome.windows.WindowType = { NORMAL: "normal", POPUP: "popup", PANEL: "panel", APP: "app", DEVTOOLS: "devtools" };
    chrome.windows.CreateType = { NORMAL: "normal", POPUP: "popup", PANEL: "panel" };
    chrome.windows.WindowState = { NORMAL: "normal", MINIMIZED: "minimized", MAXIMIZED: "maximized", FULLSCREEN: "fullscreen", LOCKED_FULLSCREEN: "locked-fullscreen" };
  }
  if (chrome.idle) { chrome.idle.IdleState = { ACTIVE: "active", IDLE: "idle", LOCKED: "locked" }; }
  if (chrome.offscreen) {
    const reasons = ["TESTING", "AUDIO_PLAYBACK", "IFRAME_SCRIPTING", "DOM_SCRAPING", "BLOBS", "DOM_PARSER", "USER_MEDIA", "DISPLAY_MEDIA",
      "WEB_RTC", "CLIPBOARD", "LOCAL_STORAGE", "WORKERS", "BATTERY_STATUS", "MATCH_MEDIA", "GEOLOCATION"];
    chrome.offscreen.Reason = {};
    for (const r of reasons) chrome.offscreen.Reason[r] = r;
  }
  if (chrome.action && chrome.action.setIcon) {
    // ImageData has no JSON form: the icon stays the manifest's until paths are given (drawn icons come later)
    const setIcon = chrome.action.setIcon;
    chrome.action.setIcon = function (details, cb) {
      const d = Object.assign({}, details);
      if (d.imageData !== undefined) { d.imageData = true; }
      return cb === undefined ? setIcon(d) : setIcon(d, cb);
    };
  }

  Object.defineProperty(global, "chrome", { value: chrome, writable: true, configurable: true, enumerable: false });

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
