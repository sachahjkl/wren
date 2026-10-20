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

  host.install({
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
