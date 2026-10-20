// adoptedStyleSheets (CSSOM §6.1.5) of the document and of shadow roots, for the engine's glue (runtime/shadow.c): an
// ObservableArray<CSSStyleSheet> per root, a proxy over an array whose every change (index set, length, push, splice)
// is checked (constructed stylesheets only) and given to the browser, which applies the sheets. The arrays are kept
// by root handle, not by wrapper: a shadow root's wrapper may be collected and made again while its sheets still
// apply; entries of roots that are gone are dropped from time to time.
(function (host) {
  "use strict";
  const byRoot = new Map();   // root handle -> { array, proxy }
  let made = 0;
  const INDEX = /^(0|[1-9][0-9]*)$/;

  function check(v) {
    const k = host.isSheet(v);
    if (k === 0) throw new TypeError("Failed to set the 'adoptedStyleSheets' property: Failed to convert value to 'CSSStyleSheet'.");
    if (k === 1) throw new DOMException("Failed to set the 'adoptedStyleSheets' property: Can't adopt non-constructed stylesheets.", "NotAllowedError");
    return v;
  }

  function prune() {
    for (const h of Array.from(byRoot.keys())) if (!host.isLive(h)) byRoot.delete(h);
  }

  function entry(handle) {
    let e = byRoot.get(handle);
    if (e) return e;
    const array = [];
    const commit = () => host.adopt(handle, array);
    const proxy = new Proxy(array, {
      set(t, prop, value) {
        if (typeof prop === "string" && INDEX.test(prop)) {
          const i = Number(prop);
          if (i > t.length) throw new RangeError("adoptedStyleSheets: index past the end");
          t[i] = check(value);
          commit();
          return true;
        }
        if (prop === "length") {
          const n = Number(value);
          if (!Number.isInteger(n) || n < 0 || n > t.length) throw new RangeError("adoptedStyleSheets: invalid length");
          t.length = n;
          commit();
          return true;
        }
        return Reflect.set(t, prop, value);
      },
      deleteProperty(t, prop) {
        if (typeof prop === "string" && INDEX.test(prop)) {
          // an ObservableArray deletes its last element only
          if (Number(prop) !== t.length - 1) return false;
          t.length -= 1;
          commit();
          return true;
        }
        return Reflect.deleteProperty(t, prop);
      },
      defineProperty(t, prop, desc) {
        if (typeof prop === "string" && INDEX.test(prop)) {
          if (!("value" in desc)) return false;
          const i = Number(prop);
          if (i > t.length) return false;
          t[i] = check(desc.value);
          commit();
          return true;
        }
        return Reflect.defineProperty(t, prop, desc);
      },
    });
    e = { array, proxy };
    byRoot.set(handle, e);
    if (++made % 64 === 0) prune();
    return e;
  }

  // The Window's named properties (HTML §7.2.2.3): elements with an id, and embed / form / img / object elements with a
  // name, reachable as properties of the global (`test1` for <div id=test1>). A proxy between Window.prototype and
  // EventTarget.prototype (the "named properties object"): what the global and Window.prototype define wins.
  function namedProperties(windowProto) {
    const target = Object.create(Object.getPrototypeOf(windowProto));
    const NAMED = new Set(["embed", "form", "img", "object"]);
    const lookup = (name) => {
      if (typeof name !== "string" || name === "") return undefined;
      if (typeof name.isWellFormed === "function" && !name.isWellFormed()) return undefined;   // lone surrogates
      const d = globalThis.document;
      if (d === undefined || d === null) return undefined;
      try {
        for (const el of d.getElementsByName(name)) if (NAMED.has(el.localName)) return el;
        const el = d.getElementById(name);
        return el === null ? undefined : el;
      } catch (e) {
        return undefined;
      }
    };
    const proxy = new Proxy(target, {
      get(t, p, r) {
        if (typeof p === "string" && !(p in t)) { const v = lookup(p); if (v !== undefined) return v; }
        return Reflect.get(t, p, r);
      },
      has(t, p) { return Reflect.has(t, p) || lookup(p) !== undefined; },
      getOwnPropertyDescriptor(t, p) {
        const own = Reflect.getOwnPropertyDescriptor(t, p);
        if (own !== undefined) return own;
        const v = lookup(p);
        return v === undefined ? undefined : { value: v, writable: true, enumerable: false, configurable: true };
      },
      defineProperty() { return false; },
      deleteProperty() { return false; },
      // an immutable prototype: setting the same one succeeds
      setPrototypeOf(t, v) { return v === Reflect.getPrototypeOf(t); },
    });
    Object.setPrototypeOf(windowProto, proxy);
  }

  // element.part (CSS Shadow Parts §5): the DOMTokenList of the part attribute, the same object every time.
  function elementExtras() {
    const E = globalThis.Element;
    if (typeof E !== "function") return;
    const lists = new WeakMap();
    Object.defineProperty(E.prototype, "part", {
      configurable: true,
      enumerable: true,
      get() {
        let l = lists.get(this);
        if (l === undefined) { l = host.partList(this); lists.set(this, l); }
        return l;
      },
      set(v) { this.part.value = v; },
    });
  }

  host.install({
    namedProperties,
    elementExtras,
    get(target, handle) { return entry(handle).proxy; },
    set(target, handle, value) {
      if (value === null || typeof value !== "object" || typeof value[Symbol.iterator] !== "function") {
        throw new TypeError("Failed to set the 'adoptedStyleSheets' property: The provided value cannot be converted to a sequence.");
      }
      const list = Array.from(value, check);
      const e = entry(handle);
      e.array.length = 0;
      for (const s of list) e.array.push(s);
      host.adopt(handle, e.array);
    },
  });
})(__wren_shadow_host);
delete globalThis.__wren_shadow_host;
