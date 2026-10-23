// Windows of other documents (HTML §7.2.3 "the WindowProxy exotic object", §7.2.3.x cross-origin objects), for the
// engine's glue (runtime/frames.c). Every document runs in an engine instance of its own: the window of another one
// (a frame, the parent, the top level) is a Proxy of this realm named by the navigable's id, the same object each
// time, which reaches only what HTML lets a cross-origin window reach: postMessage, location (to navigate it), closed,
// frames / window / self, length, top, parent, opener, close, focus, blur, and its child frames by index or name.
// Anything else throws a SecurityError, same origin or not (two documents never share objects here), except what pages
// take from a same-origin frame to have a pristine copy: the ECMAScript built-ins, the interface objects and constructors
// of the web platform, a few global functions, console, and history (see `pristine`), all of them this realm's own.
(function (host) {
  "use strict";
  const proxies = new Map();   // navigable id -> WindowProxy
  const windows = new WeakSet();
  const NONE = {};
  const INDEX = /^(0|[1-9][0-9]*)$/;
  const MEMBERS = ["window", "self", "location", "close", "closed", "focus", "blur", "frames", "length", "top", "opener", "parent", "postMessage"];
  const FALLBACK = ["then", Symbol.toStringTag, Symbol.hasInstance, Symbol.isConcatSpreadable];
  const BUILTINS = new Set(["JSON", "Math", "Reflect", "Intl", "Object", "Function", "Array", "String", "Number", "Boolean",
    "Symbol", "BigInt", "Date", "RegExp", "Error", "TypeError", "RangeError", "SyntaxError", "ReferenceError", "EvalError",
    "URIError", "AggregateError", "Map", "Set", "WeakMap", "WeakSet", "WeakRef", "Promise", "Proxy", "ArrayBuffer",
    "DataView", "Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array", "Int32Array", "Uint32Array",
    "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array", "parseInt", "parseFloat", "isNaN", "isFinite",
    "encodeURI", "encodeURIComponent", "decodeURI", "decodeURIComponent", "escape", "unescape", "NaN", "Infinity", "undefined"]);
  // the window functions that are stateless (they act on the realm that calls them)
  const FUNCTIONS = new Set(["fetch", "setTimeout", "clearTimeout", "setInterval", "clearInterval", "requestAnimationFrame",
    "cancelAnimationFrame", "requestIdleCallback", "cancelIdleCallback", "queueMicrotask", "structuredClone", "atob", "btoa",
    "getComputedStyle", "matchMedia", "reportError", "createImageBitmap", "addEventListener", "removeEventListener", "dispatchEvent"]);
  const nativeFunction = (f) => typeof f === "function" && /\[native code\]\s*\}\s*$/.test(Function.prototype.toString.call(f));
  let selfId = 0;

  const own = () => {
    if (selfId === 0) selfId = host.self();
    return selfId;
  };

  function securityError(name) {
    let origin = "null";
    try { origin = globalThis.location.origin; } catch (e) { /* no location */ }
    const what = typeof name === "symbol" ? String(name) : `'${name}'`;
    return new DOMException(`Blocked a frame with origin "${origin}" from accessing ${what} of another window: the documents of other frames are reachable through postMessage only.`, "SecurityError");
  }

  function postMessageTo(id) {
    // postMessage(message, targetOrigin, transfer) or postMessage(message, {targetOrigin, transfer})
    return function postMessage(message, targetOrigin, transfer) {
      if (arguments.length < 1) throw new TypeError("Failed to execute 'postMessage' on 'Window': 1 argument required, but only 0 present.");
      let to = "/", tr;
      if (targetOrigin !== null && typeof targetOrigin === "object") {
        if (targetOrigin.targetOrigin !== undefined) to = String(targetOrigin.targetOrigin);
        tr = targetOrigin.transfer;
      } else if (targetOrigin !== undefined) {
        to = String(targetOrigin);
        tr = transfer;
      }
      host.post(id, message, to, tr);
    };
  }

  const fallbackDescriptor = { value: undefined, writable: false, enumerable: false, configurable: true };

  function locationOf(id) {
    const replace = function replace(url) { host.navigate(id, String(url), true); };
    const setHref = function (v) { host.navigate(id, String(v), false); };
    return new Proxy(Object.create(null), {
      get(t, p) {
        if (p === "replace") return replace;
        if (FALLBACK.includes(p)) return undefined;
        throw securityError(p);
      },
      set(t, p, v) {
        if (p === "href") { setHref(v); return true; }
        throw securityError(p);
      },
      has(t, p) { return p === "href" || p === "replace" || FALLBACK.includes(p); },
      ownKeys() { return ["href", "replace"].concat(FALLBACK); },
      getOwnPropertyDescriptor(t, p) {
        if (p === "replace") return { value: replace, writable: false, enumerable: false, configurable: true };
        if (p === "href") return { get: undefined, set: setHref, enumerable: false, configurable: true };
        if (FALLBACK.includes(p)) return fallbackDescriptor;
        throw securityError(p);
      },
      defineProperty(t, p) { throw securityError(p); },
      deleteProperty(t, p) { throw securityError(p); },
      getPrototypeOf() { return null; },
      setPrototypeOf(t, v) { return v === null; },
      preventExtensions() { return false; },
    });
  }

  function makeWindow(id) {
    let proxy, loc = null;
    const fns = {
      postMessage: postMessageTo(id),
      close: function close() {},
      focus: function focus() {},
      blur: function blur() {},
    };
    const member = (p) => {
      switch (p) {
        case "window": case "self": case "frames": return proxy;
        case "location": return loc || (loc = locationOf(id));
        case "closed": return host.closed(id);
        case "length": return host.length(id);
        case "top": { const t = host.top(id); return t ? windowOf(t) : null; }
        case "parent": { const q = host.parent(id); return q ? windowOf(q) : proxy; }
        case "opener": return null;
        case "postMessage": case "close": case "focus": case "blur": return fns[p];
      }
      return NONE;
    };
    // a same-origin window's ECMAScript built-ins (stateless: JSON, Math, constructors...) are given as this realm's own,
    // which scripts probing another frame for them can use; its documents and state stay out of reach
    const builtin = (p) => {
      if (typeof p !== "string" || !BUILTINS.has(p) || !host.sameOrigin(id)) return NONE;
      return globalThis[p];
    };
    // What a script takes from a same-origin frame to have a pristine copy of a function (SPF: contentWindow.history.pushState,
    // called on window.history; polyfills: contentWindow.Array, .fetch, .console): this realm's interface objects,
    // constructors and functions of the platform, not the frame's state. history is an object with History's prototype and
    // no brand: its methods are the ones to .call() on a real history, and fail when called on it.
    let history = null;
    const pristine = (p) => {
      if (typeof p !== "string" || !host.sameOrigin(id)) return NONE;
      if (p === "history") return history || (history = Object.create(globalThis.History.prototype));
      if (p === "console") return globalThis.console;
      if (FUNCTIONS.has(p)) { const v = globalThis[p]; return nativeFunction(v) ? v.bind(globalThis) : NONE; }
      if (/^[A-Z]/.test(p) && Object.getOwnPropertyDescriptor(globalThis, p) !== undefined) { const v = globalThis[p]; return nativeFunction(v) ? v : NONE; }
      return NONE;
    };
    const child = (p) => {
      if (typeof p !== "string") return NONE;
      const c = INDEX.test(p) ? host.child(id, Number(p)) : host.named(id, p);
      return c ? windowOf(c) : NONE;
    };
    proxy = new Proxy(Object.create(null), {
      get(t, p) {
        if (FALLBACK.includes(p)) return undefined;
        let v = member(p);
        if (v !== NONE) return v;
        v = child(p);
        if (v !== NONE) return v;
        v = builtin(p);
        if (v !== NONE) return v;
        v = pristine(p);
        if (v !== NONE) return v;
        throw securityError(p);
      },
      set(t, p, v) {
        if (p === "location") { host.navigate(id, String(v), false); return true; }
        throw securityError(p);
      },
      has(t, p) { return MEMBERS.includes(p) || FALLBACK.includes(p) || child(p) !== NONE || builtin(p) !== NONE || pristine(p) !== NONE; },
      ownKeys() {
        const keys = [];
        const n = host.length(id);
        for (let i = 0; i < n; i++) keys.push(String(i));
        for (const k of host.names(id)) if (!keys.includes(k) && !MEMBERS.includes(k)) keys.push(k);
        return keys.concat(MEMBERS, FALLBACK);
      },
      getOwnPropertyDescriptor(t, p) {
        const c = child(p);
        if (c !== NONE) return { value: c, writable: false, enumerable: INDEX.test(p), configurable: true };
        if (p === "location") return { get: () => member("location"), set: (v) => { host.navigate(id, String(v), false); }, enumerable: false, configurable: true };
        if (p === "postMessage" || p === "close" || p === "focus" || p === "blur") return { value: fns[p], writable: false, enumerable: false, configurable: true };
        if (MEMBERS.includes(p)) return { get: () => member(p), set: undefined, enumerable: false, configurable: true };
        if (FALLBACK.includes(p)) return fallbackDescriptor;
        const v = builtin(p) !== NONE ? builtin(p) : pristine(p);
        if (v !== NONE) return { value: v, writable: false, enumerable: false, configurable: true };
        throw securityError(p);
      },
      defineProperty(t, p) { throw securityError(p); },
      deleteProperty(t, p) { throw securityError(p); },
      getPrototypeOf() { return null; },
      setPrototypeOf(t, v) { return v === null; },
      preventExtensions() { return false; },
    });
    windows.add(proxy);
    return proxy;
  }

  function prune() {
    for (const k of Array.from(proxies.keys())) if (host.closed(k)) proxies.delete(k);
  }

  // The window of navigable `id` in this realm: the global for its own, a WindowProxy for another, null for none.
  function windowOf(id) {
    if (!id) return null;
    if (id === own()) return globalThis;
    let w = proxies.get(id);
    if (w === undefined) {
      w = makeWindow(id);
      proxies.set(id, w);
      if (proxies.size % 64 === 0) prune();
    }
    return w;
  }

  // window[index] and window[name] of the window's own child frames (the Window's named properties: prelude/shadow.js)
  function lookup(name) {
    const me = own();
    if (!me || typeof name !== "string") return undefined;
    const c = INDEX.test(name) ? host.child(me, Number(name)) : host.named(me, name);
    return c ? windowOf(c) : undefined;
  }

  host.install({ windowOf, isWindow: (v) => windows.has(v), lookup });
})(__wren_frames_host);
delete globalThis.__wren_frames_host;
