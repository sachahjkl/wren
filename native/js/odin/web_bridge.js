// The value bridge between the realms of same-origin documents (frames_bridge.odin): frame.contentWindow.foo, parent.foo().
// Run at pre-initialization, so that what it takes from the realm (Reflect, Map, Proxy...) is the realm's own whatever a page
// later does to them. An object of another realm is a Proxy here that forwards every operation to its realm; primitives are
// copied, DOM nodes and windows are this realm's wrappers of them (frames_bridge.odin). The one table of a realm:
// `exported`, the objects other realms hold, by number.
(function (native) {
  "use strict";
  const R = Reflect;
  const apply = R.apply, rGet = R.get, rSet = R.set, rHas = R.has, rDelete = R.deleteProperty, rKeys = R.ownKeys,
    rGopd = R.getOwnPropertyDescriptor, rDefine = R.defineProperty, rGetProto = R.getPrototypeOf, rSetProto = R.setPrototypeOf,
    rConstruct = R.construct;
  const P = Proxy, MapC = Map, WeakMapC = WeakMap, WeakRefC = WeakRef, FR = FinalizationRegistry, BigIntF = BigInt, SymbolC = Symbol;
  const mapGet = MapC.prototype.get, mapSet = MapC.prototype.set, mapDel = MapC.prototype.delete;
  const wmGet = WeakMapC.prototype.get, wmSet = WeakMapC.prototype.set, derefF = WeakRefC.prototype.deref, regF = FR.prototype.register;
  const bindF = Function.prototype.bind, arrayIsArray = Array.isArray;
  const emptyFn = function () {};
  const OP_GET = 1, OP_SET = 2, OP_HAS = 3, OP_DELETE = 4, OP_KEYS = 5, OP_GOPD = 6, OP_DEFINE = 7, OP_GET_PROTO = 8, OP_SET_PROTO = 9, OP_APPLY = 10, OP_CONSTRUCT = 11, OP_RELEASE = 12;
  const KIND_OBJECT = 0, KIND_FUNCTION = 1, KIND_ARRAY = 2;
  const REALM_FACTOR = 4294967296;   // a key of `imported`: realm * 2^32 + number
  const send = native.send, global = native.global;

  // the symbols a realm can name to another: the well-known ones, by name
  const symbolNames = new MapC(), symbolsByName = new MapC();
  const wellKnown = ["iterator", "asyncIterator", "hasInstance", "toPrimitive", "toStringTag", "species", "isConcatSpreadable", "match", "matchAll", "replace", "search", "split", "unscopables"];
  for (let i = 0; i < wellKnown.length; i++) {
    const s = SymbolC[wellKnown[i]];
    if (s !== undefined) { apply(mapSet, symbolNames, [s, wellKnown[i]]); apply(mapSet, symbolsByName, [wellKnown[i], s]); }
  }

  // ---- what this realm gives others ----
  const exported = new MapC(), numbers = new WeakMapC();
  let nextNumber = 1;   // 0 is the global object
  const numberOf = o => {
    let n = apply(wmGet, numbers, [o]);
    if (n === undefined) { n = nextNumber++; apply(wmSet, numbers, [o, n]); }
    apply(mapSet, exported, [n, o]);
    return n;
  };
  const local = n => n === 0 ? global : apply(mapGet, exported, [n]);

  // ---- what this realm holds of others: one proxy per object, while it is referenced ----
  const imported = new MapC(), info = new WeakMapC();
  const released = new FR(held => {
    const key = held.key;
    const ref = apply(mapGet, imported, [key]);
    if (ref !== undefined && apply(derefF, ref, []) === undefined) apply(mapDel, imported, [key]);
    send(held.realm, OP_RELEASE, held.number);
  });
  const of = t => apply(wmGet, info, [t]);
  const nameable = key => typeof key !== "symbol" || apply(mapGet, symbolNames, [key]) !== undefined;

  const handler = {
    __proto__: null,
    get(t, key) { const i = of(t); return nameable(key) ? send(i.realm, OP_GET, i.number, key) : undefined; },
    set(t, key, value) { const i = of(t); return nameable(key) ? send(i.realm, OP_SET, i.number, key, value) !== false : true; },
    has(t, key) { const i = of(t); return nameable(key) && send(i.realm, OP_HAS, i.number, key) === true; },
    deleteProperty(t, key) { const i = of(t); return !nameable(key) || send(i.realm, OP_DELETE, i.number, key) !== false; },
    ownKeys(t) {
      const i = of(t);
      const keys = send(i.realm, OP_KEYS, i.number);
      if (keys !== undefined) return keys;
      return i.kind === KIND_ARRAY ? ["length"] : [];
    },
    getOwnPropertyDescriptor(t, key) {
      const i = of(t);
      if (!nameable(key)) return undefined;
      const d = send(i.realm, OP_GOPD, i.number, key);
      if (d === undefined) return i.kind === KIND_ARRAY && key === "length" ? rGopd(t, key) : undefined;
      // (the proxy's invariants: nothing here is known to the target, but an array's length)
      const configurable = !(i.kind === KIND_ARRAY && key === "length");
      if (d[4] !== undefined || d[5] !== undefined) return { __proto__: null, get: d[4], set: d[5], enumerable: d[2], configurable };
      return { __proto__: null, value: d[0], writable: d[1], enumerable: d[2], configurable };
    },
    defineProperty(t, key, desc) {
      const i = of(t);
      if (!nameable(key)) return false;
      return send(i.realm, OP_DEFINE, i.number, key, ["value" in desc, desc.value, desc.writable, desc.enumerable, desc.configurable, desc.get, desc.set, "writable" in desc, "enumerable" in desc, "configurable" in desc]) !== false;
    },
    getPrototypeOf(t) { const i = of(t); const p = send(i.realm, OP_GET_PROTO, i.number); return typeof p === "object" || typeof p === "function" ? p : null; },
    setPrototypeOf(t, proto) { const i = of(t); return send(i.realm, OP_SET_PROTO, i.number, proto) !== false; },
    preventExtensions() { return false; },
    apply(t, self, args) { const i = of(t); return send(i.realm, OP_APPLY, i.number, self, args); },
    construct(t, args) { const i = of(t); return send(i.realm, OP_CONSTRUCT, i.number, args); },
  };

  // The value for a reference another realm sent: the object itself when it is this realm's, else its proxy.
  const importRef = (self, realm, number, kind) => {
    if (realm === self) return local(number);
    const key = realm * REALM_FACTOR + number;
    const ref = apply(mapGet, imported, [key]);
    if (ref !== undefined) {
      const p = apply(derefF, ref, []);
      if (p !== undefined) return p;
    }
    // a bound function is constructible and has no `prototype` the proxy's invariants would have to report
    const target = kind === KIND_FUNCTION ? apply(bindF, emptyFn, [undefined]) : kind === KIND_ARRAY ? [] : {};
    const fresh = { realm, number, kind };
    apply(wmSet, info, [target, fresh]);
    const p = new P(target, handler);
    apply(wmSet, info, [p, fresh]);
    apply(mapSet, imported, [key, new WeakRefC(p)]);
    apply(regF, released, [p, { realm, number, key }]);
    return p;
  };

  // A reference to send for an object of this realm, or a proxy it holds: [realm, number, kind].
  const exportRef = (self, o) => {
    const i = apply(wmGet, info, [o]);
    if (i !== undefined) return [i.realm, i.number, i.kind];
    return [self, numberOf(o), typeof o === "function" ? KIND_FUNCTION : arrayIsArray(o) ? KIND_ARRAY : KIND_OBJECT];
  };

  // ---- an operation another realm asks for, on an object of this one ----
  const dispatch = (op, number, a, b) => {
    const o = local(number);
    if (o === undefined) return undefined;   // released, or never given: nothing happens
    switch (op) {
      case OP_GET: return rGet(o, a);
      case OP_SET: return rSet(o, a, b);
      case OP_HAS: return rHas(o, a);
      case OP_DELETE: return rDelete(o, a);
      case OP_KEYS: {
        const all = rKeys(o), out = [];
        for (let i = 0, k = 0; i < all.length; i++) if (nameable(all[i])) out[k++] = all[i];
        return out;
      }
      case OP_GOPD: {
        const d = rGopd(o, a);
        return d === undefined ? undefined : [d.value, d.writable, d.enumerable, d.configurable, d.get, d.set];
      }
      case OP_DEFINE: {
        const d = { __proto__: null };
        if (b[0]) d.value = b[1];
        if (b[7]) d.writable = b[2];
        if (b[8]) d.enumerable = b[3];
        if (b[9]) d.configurable = b[4];
        if (b[5] !== undefined) d.get = b[5];
        if (b[6] !== undefined) d.set = b[6];
        return rDefine(o, a, d);
      }
      case OP_GET_PROTO: return rGetProto(o);
      case OP_SET_PROTO: return rSetProto(o, a);
      case OP_APPLY: return apply(o, a, b);
      case OP_CONSTRUCT: return rConstruct(o, a);
      case OP_RELEASE: apply(mapDel, exported, [number]); return undefined;
    }
    return undefined;
  };

  // An exception of a built-in type crosses as its kind: built-ins read from another window are the reader's own, and a test of
  // `e instanceof otherWindow.TypeError` or a DOMException's name has to hold. Any other value thrown crosses as a value.
  const errorTypes = [Error, TypeError, RangeError, SyntaxError, ReferenceError, EvalError, URIError];
  const errorNames = ["Error", "TypeError", "RangeError", "SyntaxError", "ReferenceError", "EvalError", "URIError"];
  const describeError = e => {
    if (typeof e !== "object" || e === null) return undefined;
    const proto = rGetProto(e);
    if (proto === rGet(rGet(global, "DOMException"), "prototype")) return ["DOMException", e.message, e.name];
    for (let i = 0; i < errorTypes.length; i++) {
      if (proto === errorTypes[i].prototype) return [errorNames[i], e.message, e.stack];
    }
    return undefined;
  };
  const makeError = d => {
    if (d[0] === "DOMException") return rConstruct(rGet(global, "DOMException"), [d[1], d[2]]);
    for (let i = 0; i < errorTypes.length; i++) {
      if (errorNames[i] === d[0]) {
        const e = new errorTypes[i](d[1]);
        if (d[2] !== undefined) rDefine(e, "stack", { __proto__: null, value: d[2], writable: true, configurable: true });
        return e;
      }
    }
    return undefined;
  };

  return {
    __proto__: null,
    describeError,
    makeError,
    dispatch,
    importRef,
    exportRef,
    symbolName: s => apply(mapGet, symbolNames, [s]),
    symbolOf: name => apply(mapGet, symbolsByName, [name]),
    bigint: text => BigIntF(text),
  };
})
