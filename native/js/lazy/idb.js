// IndexedDB 3.0 (W3C): indexedDB, IDBFactory, IDBDatabase, IDBTransaction, IDBObjectStore, IDBIndex, IDBCursor,
// IDBCursorWithValue, IDBKeyRange, IDBRequest, IDBOpenDBRequest, IDBVersionChangeEvent, DOMStringList. The engine's glue
// is runtime/web_idb.c; the data, the scheduling of transactions and the journal are the browser's (src/idb), reached
// through host.call(op, bytes).
//
// What lives here: the objects scripts see, argument checks in the specification's order, keys (JavaScript value <->
// the byte encoding of src/idb/key.odin, ordered by comparing bytes), key paths, the structured clone of values (the
// engine's serializer, through host.serialize / deserialize), requests and their queue per transaction, the events (an
// IDB event target of its own: a request's parent is its transaction, whose parent is the connection) and the active /
// inactive state of transactions (a transaction is active from its creation, or the event of one of its requests, until
// the microtask checkpoint that follows; the browser calls `cleanup` there).
//
// What does not: anything stored. Each request of a transaction is executed by the browser when its task comes
// (host.post), the answer becomes the request's result and an event is fired. Transactions start, complete and abort
// by events from the browser, which orders the transactions of all pages of the origin (readers share, a writer waits
// for earlier overlapping transactions) and writes the journal before saying "complete".
(function (host) {
  "use strict";

  // ---- the browser's side ----------------------------------------------------------------------------------------
  const OP = { OPEN: 1, DELETE: 2, LIST: 3, CLOSE: 4, VC_DONE: 5, BEGIN: 6, COMMIT: 7, ABORT: 8, EXEC: 9, TASK: 10, EVENT: 11, CLEANUP: 12, LIMITS: 13, ESTIMATE: 15, PERSIST: 16, BUCKETS: 17 };
  const REQ = { GET: 1, COUNT: 2, GET_ALL: 3, CURSOR: 4, PUT: 5, GEN_KEY: 6, DELETE: 7, CLEAR: 8, INDEX_PUT: 9,
    CREATE_STORE: 10, DELETE_STORE: 11, RENAME_STORE: 12, CREATE_INDEX: 13, DELETE_INDEX: 14, RENAME_INDEX: 15, PEEK_KEY: 16 };
  const EV = { TASK: 1, OPEN_UPGRADE: 2, OPEN_DONE: 3, OPEN_ERROR: 4, BLOCKED: 5, VERSION_CHANGE: 6, DELETE_DONE: 7, DELETE_ERROR: 8,
    TX_STARTED: 9, TX_COMPLETE: 10, TX_ABORTED: 11, CONN_CLOSED: 12, LIST: 13 };
  // idb.Error -> DOMException name
  const ERR_NAME = ["", "ConstraintError", "QuotaExceededError", "ReadOnlyError", "NotFoundError", "InvalidStateError", "DataError",
    "VersionError", "AbortError", "DataError", "UnknownError", "UnknownError"];
  const E_ABORTED = 8, E_UNKNOWN = 11;
  const MAX_UV = 9007199254740991;

  const call = host.call, serialize = host.serialize, deserialize = host.deserialize, isProxy = host.isProxy, drain = host.drain;
  let DOMEx = null;   // the realm's DOMException (its interface objects exist from start on: the ones of pre-initialization are not the page's)
  const hasOwn = Object.prototype.hasOwnProperty;
  const isArray = Array.isArray;
  const isView = ArrayBuffer.isView;
  const getTime = Date.prototype.getTime;
  const abByteLength = Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "byteLength").get;
  const mathFloor = Math.floor;
  const PRIVATE = {};

  function dom(name, message) { return new DOMEx(message || name, name); }
  function fail(code, what) { return dom(ERR_NAME[code] || "UnknownError", what); }

  // ---- bytes ------------------------------------------------------------------------------------------------------
  // Names are kept as WTF-8: a lone surrogate keeps its own 3-byte form (two names differing by one are two names).
  function utf8(s) {
    const n = s.length;
    let ascii = true;
    for (let i = 0; i < n; i++) { if (s.charCodeAt(i) > 0x7f) { ascii = false; break; } }
    if (ascii) { const b = new Uint8Array(n); for (let i = 0; i < n; i++) b[i] = s.charCodeAt(i); return b; }
    const out = [];
    for (let i = 0; i < n; i++) {
      let c = s.charCodeAt(i);
      if (c >= 0xd800 && c <= 0xdbff && i + 1 < n) {
        const d = s.charCodeAt(i + 1);
        if (d >= 0xdc00 && d <= 0xdfff) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); i++; }
      }
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
      else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return new Uint8Array(out);
  }

  function unitsToString(units) {
    if (units.length < 4096) return String.fromCharCode.apply(null, units);
    let s = "";
    for (let i = 0; i < units.length; i += 4096) s += String.fromCharCode.apply(null, units.slice(i, i + 4096));
    return s;
  }

  function utf8d(b) {
    const units = [];
    for (let i = 0; i < b.length;) {
      const c = b[i++];
      let cp;
      if (c < 0x80) cp = c;
      else if (c < 0xe0) cp = ((c & 31) << 6) | (b[i++] & 63);
      else if (c < 0xf0) { cp = ((c & 15) << 12) | ((b[i] & 63) << 6) | (b[i + 1] & 63); i += 2; }
      else { cp = ((c & 7) << 18) | ((b[i] & 63) << 12) | ((b[i + 1] & 63) << 6) | (b[i + 2] & 63); i += 3; }
      if (cp >= 0x10000) { cp -= 0x10000; units.push(0xd800 + (cp >> 10), 0xdc00 + (cp & 1023)); } else units.push(cp);
    }
    return unitsToString(units);
  }

  const fdv = new DataView(new ArrayBuffer(8));
  class Wr {
    constructor() { this.b = new Uint8Array(64); this.n = 0; }
    need(k) {
      if (this.n + k > this.b.length) {
        let c = this.b.length * 2;
        while (c < this.n + k) c *= 2;
        const nb = new Uint8Array(c);
        nb.set(this.b.subarray(0, this.n));
        this.b = nb;
      }
    }
    u8(v) { this.need(1); this.b[this.n++] = v; }
    uv(v) {
      this.need(10);
      while (v >= 128) { this.b[this.n++] = (v % 128) | 128; v = mathFloor(v / 128); }
      this.b[this.n++] = v;
    }
    raw(u8) { this.need(u8.length); this.b.set(u8, this.n); this.n += u8.length; }
    bytes(u8) { this.uv(u8.length); this.raw(u8); }
    str(s) { this.bytes(utf8(s)); }
    f64(v) { this.need(8); fdv.setFloat64(0, v, true); for (let i = 0; i < 8; i++) this.b[this.n++] = fdv.getUint8(i); }
    done() { return this.b.subarray(0, this.n); }
  }

  class Rd {
    constructor(b, p) { this.b = b; this.p = p || 0; }
    u8() { return this.b[this.p++]; }
    uv() {
      let v = 0, m = 1, c;
      do { c = this.b[this.p++]; v += (c & 127) * m; m *= 128; } while (c & 128);
      return v;
    }
    bytes() { const n = this.uv(); const r = this.b.subarray(this.p, this.p + n); this.p += n; return r; }
    str() { return utf8d(this.bytes()); }
    f64() { for (let i = 0; i < 8; i++) fdv.setUint8(i, this.b[this.p++]); return fdv.getFloat64(0, true); }
  }

  // ---- keys -------------------------------------------------------------------------------------------------------
  const dv = new DataView(new ArrayBuffer(8));

  function putNumber(w, tag, v) {
    dv.setFloat64(0, v === 0 ? 0 : v);
    w.need(9);
    w.b[w.n++] = tag;
    const neg = dv.getUint8(0) & 0x80;
    for (let i = 0; i < 8; i++) {
      const x = dv.getUint8(i);
      w.b[w.n++] = neg ? x ^ 0xff : (i === 0 ? x ^ 0x80 : x);
    }
  }

  function putString(w, s) {
    w.need(2 * s.length + 3);
    w.b[w.n++] = 0x30;
    for (let i = 0; i < s.length; i++) {
      const c = s.charCodeAt(i);
      if (c >= 0xfffe) { w.b[w.n++] = 0xff; w.b[w.n++] = 0xff; w.b[w.n++] = c === 0xfffe ? 1 : 2; }
      else { const v = c + 1; w.b[w.n++] = v >> 8; w.b[w.n++] = v & 255; }
    }
    w.b[w.n++] = 0;
    w.b[w.n++] = 0;
  }

  function putBinary(w, bytes) {
    w.need(2 * bytes.length + 2);
    w.b[w.n++] = 0x40;
    for (let i = 0; i < bytes.length; i++) {
      const c = bytes[i];
      w.b[w.n++] = c;
      if (c === 0) w.b[w.n++] = 0xff;
    }
    w.b[w.n++] = 0;
  }

  function isDate(v) {
    try { getTime.call(v); return true; } catch { return false; }
  }
  function isArrayBuffer(v) {
    try { abByteLength.call(v); return true; } catch { return false; }
  }

  // Writes the key of `v` ("convert a value to a key"); false when it is not a valid key (the writer is then unusable).
  function putKey(w, v, seen) {
    switch (typeof v) {
      case "number": if (v !== v) return false; putNumber(w, 0x10, v); return true;
      case "string": putString(w, v); return true;
      case "object": {
        if (v === null) return false;
        if (isArray(v) && !isProxy(v)) {   // (a Proxy of an array is not an Array exotic object: no key)
          if (seen.length >= 64 || seen.includes(v)) return false;
          seen.push(v);
          w.u8(0x50);
          const len = v.length;
          for (let i = 0; i < len; i++) {
            if (!hasOwn.call(v, i)) return false;
            if (!putKey(w, v[i], seen)) return false;
          }
          w.u8(0);
          seen.pop();
          return true;
        }
        if (isDate(v)) { const t = getTime.call(v); if (t !== t) return false; putNumber(w, 0x20, t); return true; }
        // (a detached buffer is not a key)
        if (isView(v)) {
          let bytes;
          try { bytes = new Uint8Array(v.buffer, v.byteOffset, v.byteLength); } catch { return false; }
          putBinary(w, bytes);
          return true;
        }
        if (isArrayBuffer(v)) {
          let bytes;
          try { bytes = new Uint8Array(v); } catch { return false; }
          putBinary(w, bytes);
          return true;
        }
        return false;
      }
    }
    return false;
  }

  // The encoded key of a value, or null when it is not a key.
  function keyOf(v) {
    const w = new Wr();
    return putKey(w, v, []) ? w.done() : null;
  }

  function readNumber(rd) {
    const neg = !(rd.b[rd.p] & 0x80);   // transformed: a set top bit means it was non-negative
    for (let i = 0; i < 8; i++) {
      const x = rd.b[rd.p + i];
      dv.setUint8(i, neg ? x ^ 0xff : (i === 0 ? x ^ 0x80 : x));
    }
    rd.p += 8;
    return dv.getFloat64(0);
  }

  function readKey(rd) {
    const tag = rd.u8();
    switch (tag) {
      case 0x10: return readNumber(rd);
      case 0x20: return new Date(readNumber(rd));
      case 0x30: {
        const units = [];
        for (;;) {
          const a = rd.b[rd.p], c = rd.b[rd.p + 1];
          if (a === 0 && c === 0) { rd.p += 2; break; }
          if (a === 0xff && c === 0xff) { units.push(0xfffe + rd.b[rd.p + 2] - 1); rd.p += 3; }
          else { units.push(((a << 8) | c) - 1); rd.p += 2; }
        }
        return unitsToString(units);
      }
      case 0x40: {
        const out = [];
        for (;;) {
          const c = rd.b[rd.p++];
          if (c === 0) { if (rd.b[rd.p] === 0xff) { rd.p++; out.push(0); continue; } break; }
          out.push(c);
        }
        return new Uint8Array(out).buffer;
      }
      case 0x50: {
        const arr = [];
        while (rd.b[rd.p] !== 0) arr.push(readKey(rd));
        rd.p++;
        return arr;
      }
    }
    return undefined;
  }

  function decodeKey(bytes) { return readKey(new Rd(bytes, 0)); }

  function compareBytes(a, b) {
    const n = a.length < b.length ? a.length : b.length;
    for (let i = 0; i < n; i++) { if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1; }
    return a.length === b.length ? 0 : (a.length < b.length ? -1 : 1);
  }

  // ---- key paths --------------------------------------------------------------------------------------------------
  const IDENT = /^[\p{ID_Start}$_][\p{ID_Continue}$\u200c\u200d]*$/u;

  function validPathString(s) {
    if (s === "") return true;
    for (const part of s.split(".")) { if (!IDENT.test(part)) return false; }
    return true;
  }

  function validKeyPath(p) {
    if (typeof p === "string") return validPathString(p);
    if (isArray(p)) {
      if (p.length === 0) return false;
      for (const s of p) { if (typeof s !== "string" || !validPathString(s)) return false; }
      return true;
    }
    return false;
  }

  // null | string | string[], as bytes for the browser (opaque there) and back
  function packPath(p) {
    const w = new Wr();
    if (p === null) w.u8(0);
    else if (typeof p === "string") { w.u8(1); w.str(p); }
    else { w.u8(2); w.uv(p.length); for (const s of p) w.str(s); }
    return w.done();
  }
  function keyPathOf(st, k) {
    if (!isArray(k)) return k;
    if (st.kpSource !== k) { st.kpSource = k; st.kp = Object.freeze(k.slice()); }
    return st.kp;
  }
  function frozenPath(p) { return isArray(p) ? Object.freeze(p.slice()) : p; }
  function unpackPath(b) {
    if (b.length === 0) return null;
    const rd = new Rd(b, 0);
    switch (rd.u8()) {
      case 0: return null;
      case 1: return rd.str();
      default: { const n = rd.uv(); const out = []; for (let i = 0; i < n; i++) out.push(rd.str()); return Object.freeze(out); }
    }
  }

  const FAILURE = Symbol("failure");

  // "Evaluate a key path on a value": FAILURE when a step has no value.
  function evalPathString(v, path) {
    if (path === "") return v;
    let cur = v;
    for (const id of path.split(".")) {
      if (typeof cur === "string" && id === "length") { cur = cur.length; continue; }
      if (isArray(cur) && id === "length") { cur = cur.length; continue; }
      if (cur !== null && typeof cur === "object") {
        if (id === "size" || id === "type" || id === "name" || id === "lastModified") {
          if (typeof Blob === "function" && cur instanceof Blob) {
            if (id === "size" || id === "type") { cur = cur[id]; continue; }
            if (typeof File === "function" && cur instanceof File) { cur = cur[id]; continue; }
          }
        }
        if (!hasOwn.call(cur, id)) return FAILURE;
        cur = cur[id];
        continue;
      }
      return FAILURE;
    }
    return cur;
  }

  // The encoded key a key path gives for a value: undefined (no value at the path), null (not a valid key)
  function pathKey(v, path) {
    if (typeof path === "string") {
      const r = evalPathString(v, path);
      if (r === FAILURE) return undefined;
      return keyOf(r);
    }
    const w = new Wr();
    w.u8(0x50);
    for (const p of path) {
      const r = evalPathString(v, p);
      if (r === FAILURE) return undefined;
      if (!putKey(w, r, [])) return null;
    }
    w.u8(0);
    return w.done();
  }

  // Index keys of a value (multi-entry: one per distinct valid element of an array result)
  function indexKeys(v, ix) {
    const path = ix.keyPath;
    if (typeof path === "string") {
      const r = evalPathString(v, path);
      if (r === FAILURE) return [];
      if (ix.multiEntry && isArray(r)) {
        const out = [];
        const seen = [];
        for (let i = 0; i < r.length; i++) {
          if (!hasOwn.call(r, i)) continue;
          const k = keyOf(r[i]);
          if (k === null) continue;
          let dup = false;
          for (const s of seen) { if (compareBytes(s, k) === 0) { dup = true; break; } }
          if (!dup) { seen.push(k); out.push(k); }
        }
        return out;
      }
      const k = keyOf(r);
      return k === null ? [] : [k];
    }
    const k = pathKey(v, path);
    return k === undefined || k === null ? [] : [k];
  }

  // Can a generated key be injected at this path of the value? ("check that a key could be injected into a value")
  function canInject(v, path) {
    const parts = path === "" ? [] : path.split(".");
    let cur = v;
    for (let i = 0; i < parts.length - 1; i++) {
      if (cur === null || typeof cur !== "object") return false;
      if (!hasOwn.call(cur, parts[i])) { cur = undefined; break; }
      cur = cur[parts[i]];
    }
    if (cur === undefined) return true;
    return cur !== null && typeof cur === "object";
  }

  function inject(v, path, key) {
    const parts = path.split(".");
    let cur = v;
    for (let i = 0; i < parts.length - 1; i++) {
      if (!hasOwn.call(cur, parts[i])) cur[parts[i]] = {};
      cur = cur[parts[i]];
    }
    Object.defineProperty(cur, parts[parts.length - 1], { value: key, writable: true, enumerable: true, configurable: true });
  }

  // ---- argument conversions ---------------------------------------------------------------------------------------
  function str(v) { return `${v}`; }
  function arity(n, given, what, iface) {
    if (given < n) throw new TypeError(`Failed to execute '${what}' on '${iface}': ${n} argument${n > 1 ? "s" : ""} required, but only ${given} present.`);
  }
  function enforceUnsignedLong(v, what) {
    const n = Number(v);
    if (!Number.isFinite(n)) throw new TypeError(`${what}: the value is not a finite number.`);
    const t = n < 0 ? Math.ceil(n) : mathFloor(n);
    if (t < 0 || t > 4294967295) throw new TypeError(`${what}: the value is out of range.`);
    return t;
  }
  function checkEnum(v, values, what) {
    const s = str(v);
    if (!values.includes(s)) throw new TypeError(`${what}: '${s}' is not a valid enum value.`);
    return s;
  }

  // ---- key ranges -------------------------------------------------------------------------------------------------
  const rangeState = new WeakMap();

  class IDBKeyRange {
    constructor() { throw new TypeError("Illegal constructor"); }
    get lower() { const s = rs(this); return s.lower === null ? undefined : decodeKey(s.lower); }
    get upper() { const s = rs(this); return s.upper === null ? undefined : decodeKey(s.upper); }
    get lowerOpen() { return rs(this).lowerOpen; }
    get upperOpen() { return rs(this).upperOpen; }
    includes(key) {
      const s = rs(this);
      arity(1, arguments.length, "includes", "IDBKeyRange");
      const k = keyOf(key);
      if (k === null) throw dom("DataError", "The parameter is not a valid key.");
      return inRange(s, k);
    }
    static only(value) {
      arity(1, arguments.length, "only", "IDBKeyRange");
      const k = keyOf(value);
      if (k === null) throw dom("DataError", "The parameter is not a valid key.");
      return makeRange(k, k, false, false);
    }
    static lowerBound(lower, open = false) {
      arity(1, arguments.length, "lowerBound", "IDBKeyRange");
      const k = keyOf(lower);
      if (k === null) throw dom("DataError", "The parameter is not a valid key.");
      return makeRange(k, null, !!open, true);
    }
    static upperBound(upper, open = false) {
      arity(1, arguments.length, "upperBound", "IDBKeyRange");
      const k = keyOf(upper);
      if (k === null) throw dom("DataError", "The parameter is not a valid key.");
      return makeRange(null, k, true, !!open);
    }
    static bound(lower, upper, lowerOpen = false, upperOpen = false) {
      arity(2, arguments.length, "bound", "IDBKeyRange");
      const l = keyOf(lower);
      if (l === null) throw dom("DataError", "The parameter is not a valid key.");
      const u = keyOf(upper);
      if (u === null) throw dom("DataError", "The parameter is not a valid key.");
      const c = compareBytes(l, u);
      if (c > 0 || (c === 0 && (lowerOpen || upperOpen))) throw dom("DataError", "The lower key is greater than the upper key.");
      return makeRange(l, u, !!lowerOpen, !!upperOpen);
    }
  }
  function rs(o) {
    const s = rangeState.get(o);
    if (s === undefined) throw new TypeError("Illegal invocation");
    return s;
  }
  function makeRange(lower, upper, lowerOpen, upperOpen) {
    const r = Object.create(IDBKeyRange.prototype);
    rangeState.set(r, { lower, upper, lowerOpen, upperOpen });
    return r;
  }
  function inRange(s, k) {
    if (s.lower !== null) { const c = compareBytes(k, s.lower); if (c < 0 || (c === 0 && s.lowerOpen)) return false; }
    if (s.upper !== null) { const c = compareBytes(k, s.upper); if (c > 0 || (c === 0 && s.upperOpen)) return false; }
    return true;
  }
  // A range, a key, or nothing (unbounded) from a method's `query`; DataError for a value that is not a key.
  function rangeArg(q, optional) {
    if (q === undefined && optional) return null;
    if (q === null && optional) return null;
    const s = rangeState.get(q);
    if (s !== undefined) return s;
    const k = keyOf(q);
    if (k === null) throw dom("DataError", "The parameter is not a valid key or key range.");
    return { lower: k, upper: k, lowerOpen: false, upperOpen: false };
  }
  function putRange(w, r) {
    if (r === null) { w.u8(0); return; }
    w.u8((r.lower !== null ? 1 : 0) | (r.upper !== null ? 2 : 0) | (r.lowerOpen ? 4 : 0) | (r.upperOpen ? 8 : 0));
    if (r.lower !== null) w.bytes(r.lower);
    if (r.upper !== null) w.bytes(r.upper);
  }

  // ---- events: an event target of IDB's own (request -> transaction -> connection) -------------------------------------
  const etState = new WeakMap();      // target -> { listeners: [], handlers: {} }
  const evState = new WeakMap();      // event -> its dispatch state

  function ets(t) {
    let s = etState.get(t);
    if (s === undefined) { s = { listeners: [], handlers: Object.create(null) }; etState.set(t, s); }
    return s;
  }
  function newEvState() { return { target: null, current: null, phase: 0, stop: false, stopImm: false, canceled: false, dispatching: false, passive: false, path: [] }; }

  const EVENT_OVERRIDES = {
    target: { get() { const s = evState.get(this); return s ? s.target : null; }, enumerable: true, configurable: true },
    srcElement: { get() { const s = evState.get(this); return s ? s.target : null; }, enumerable: true, configurable: true },
    currentTarget: { get() { const s = evState.get(this); return s ? s.current : null; }, enumerable: true, configurable: true },
    eventPhase: { get() { const s = evState.get(this); return s ? s.phase : 0; }, enumerable: true, configurable: true },
    defaultPrevented: { get() { const s = evState.get(this); return s ? s.canceled : false; }, enumerable: true, configurable: true },
    returnValue: {
      get() { const s = evState.get(this); return s ? !s.canceled : true; },
      set(v) { if (!v) this.preventDefault(); }, enumerable: true, configurable: true,
    },
    cancelBubble: {
      get() { const s = evState.get(this); return s ? s.stop : false; },
      set(v) { const s = evState.get(this); if (s && v) s.stop = true; }, enumerable: true, configurable: true,
    },
    isTrusted: { get() { return true; }, enumerable: true, configurable: true },
    preventDefault: {
      value: function preventDefault() { const s = evState.get(this); if (s && this.cancelable && !s.passive) s.canceled = true; },
      writable: true, enumerable: true, configurable: true,
    },
    stopPropagation: {
      value: function stopPropagation() { const s = evState.get(this); if (s) s.stop = true; },
      writable: true, enumerable: true, configurable: true,
    },
    stopImmediatePropagation: {
      value: function stopImmediatePropagation() { const s = evState.get(this); if (s) { s.stop = true; s.stopImm = true; } },
      writable: true, enumerable: true, configurable: true,
    },
    composedPath: {
      value: function composedPath() { const s = evState.get(this); return s && s.dispatching ? [s.target, ...s.path] : []; },
      writable: true, enumerable: true, configurable: true,
    },
  };

  // The events fired by IDB are Events made with a prototype of ours (the dispatch state above): `constructor` says Event.
  // This runs before the realm has its interfaces: the classes are linked to Event / EventTarget by `start`, and the
  // native Event is made with Reflect.construct on the class that was called.
  let NativeEvent = null;
  class IDBPlainEvent {
    constructor(type, init) {
      const e = Reflect.construct(NativeEvent, [type, init], new.target);
      evState.set(e, newEvState());
      return e;
    }
  }
  Object.defineProperties(IDBPlainEvent.prototype, EVENT_OVERRIDES);

  const versions = new WeakMap();   // IDBVersionChangeEvent -> [oldVersion, newVersion]
  class IDBVersionChangeEvent {
    constructor(type, init = undefined) {
      if (arguments.length < 1) throw new TypeError("Failed to construct 'IDBVersionChangeEvent': 1 argument required, but only 0 present.");
      if (new.target === undefined) throw new TypeError("Failed to construct 'IDBVersionChangeEvent': Please use the 'new' operator, this DOM object constructor cannot be called as a function.");
      const e = Reflect.construct(NativeEvent, [type, init], new.target);
      evState.set(e, newEvState());
      const o = init === undefined || init === null ? undefined : init.oldVersion;
      const n = init === undefined || init === null ? undefined : init.newVersion;
      versions.set(e, [o === undefined ? 0 : enforceUint64(o), n === undefined || n === null ? null : enforceUint64(n)]);
      return e;
    }
    get oldVersion() { const v = versions.get(this); if (v === undefined) throw illegal(); return v[0]; }
    get newVersion() { const v = versions.get(this); if (v === undefined) throw illegal(); return v[1]; }
  }
  Object.defineProperties(IDBVersionChangeEvent.prototype, EVENT_OVERRIDES);
  function enforceUint64(v) {
    const n = Number(v);
    if (!Number.isFinite(n) || n < 0 || n > MAX_UV) throw new TypeError("The version is out of range.");
    return mathFloor(n);
  }

  function plainEvent(type, bubbles, cancelable) { return new IDBPlainEvent(type, { bubbles, cancelable }); }
  function versionEvent(type, oldV, newV) {
    return new IDBVersionChangeEvent(type, { oldVersion: oldV, newVersion: newV });
  }

  function parentOf(t) {
    const rq = reqState.get(t);
    if (rq !== undefined) return rq.tx !== null ? rq.tx.wrapper : null;
    const tx = txState.get(t);
    if (tx !== undefined) return tx.conn.wrapper;
    return null;
  }

  // Runs the listeners of `t` for the phase; returns true if one threw.
  function invoke(t, event, st, phase) {
    const s = etState.get(t);
    if (s === undefined) return false;
    st.current = t;
    st.phase = phase;
    let threw = false;
    const list = s.listeners.slice();
    const type = event.type;
    for (let pass = 0; pass < (phase === 2 ? 2 : 1); pass++) {
      for (const l of list) {
        if (l.removed || l.type !== type) continue;
        if (phase === 1 && !l.capture) continue;
        if (phase === 3 && l.capture) continue;
        if (phase === 2 && (pass === 0) !== !!l.capture) continue;
        if (st.stopImm) return threw;
        if (l.once) removeListener(s, l);
        let cb = l.callback;
        if (l.handler) { cb = s.handlers[type]; if (typeof cb !== "function") continue; }
        st.passive = !!l.passive;
        listenerDepth++;
        try {
          if (typeof cb === "function") cb.call(t, event);
          else if (cb !== null && typeof cb === "object") {
            const h = cb.handleEvent;
            if (typeof h !== "function") throw new TypeError("The 'handleEvent' property of the event listener is not callable.");
            h.call(cb, event);
          }
        } catch (e) {
          threw = true;
          host.report(e);
        }
        listenerDepth--;
        st.passive = false;
        // the browser calls us for an event with nothing else running: the microtasks a listener queued run before the next listener
        if (inHostEvent && listenerDepth === 0) drain();
      }
    }
    return threw;
  }

  let listenerDepth = 0;   // listeners running (an event dispatched by a script inside one is nested)
  let inHostEvent = false;   // the browser called us to deliver an event: the stack holds nothing of a script

  function removeListener(s, l) {
    l.removed = true;
    const i = s.listeners.indexOf(l);
    if (i >= 0) s.listeners.splice(i, 1);
  }

  // Dispatches `event` at `target` along its path. Result: { canceled, threw }.
  function dispatch(target, event) {
    let st = evState.get(event);
    if (st === undefined) { st = newEvState(); evState.set(event, st); Object.defineProperties(event, EVENT_OVERRIDES); }
    st.target = target;
    st.dispatching = true;
    st.stop = false;
    st.stopImm = false;
    const path = [];
    for (let p = parentOf(target); p !== null; p = parentOf(p)) path.push(p);
    st.path = path;
    let threw = false;
    for (let i = path.length - 1; i >= 0 && !st.stop; i--) { if (invoke(path[i], event, st, 1)) threw = true; }
    if (!st.stop) { if (invoke(target, event, st, 2)) threw = true; }
    if (event.bubbles) { for (let i = 0; i < path.length && !st.stop; i++) { if (invoke(path[i], event, st, 3)) threw = true; } }
    st.dispatching = false;
    st.phase = 0;
    st.current = null;
    st.stop = false;
    st.stopImm = false;
    return { canceled: st.canceled, threw };
  }

  class IDBEventTarget {
    constructor() { }
    addEventListener(type, callback, options = undefined) {
      arity(2, arguments.length, "addEventListener", "EventTarget");
      const t = str(type);
      if (callback === null || callback === undefined) return;
      let capture = false, once = false, passive = false, signal;
      if (options !== null && typeof options === "object") {
        capture = !!options.capture; once = !!options.once; passive = !!options.passive; signal = options.signal;
      } else capture = !!options;
      if (callback !== null && typeof callback !== "object" && typeof callback !== "function") throw new TypeError("The callback provided as parameter 2 is not an object.");
      if (signal !== undefined && signal.aborted) return;
      const s = ets(this);
      for (const l of s.listeners) { if (!l.handler && l.type === t && l.callback === callback && l.capture === capture) return; }
      const l = { type: t, callback, capture, once, passive, removed: false, handler: false };
      s.listeners.push(l);
      if (signal !== undefined) signal.addEventListener("abort", () => removeListener(s, l), { once: true });
    }
    removeEventListener(type, callback, options = undefined) {
      arity(2, arguments.length, "removeEventListener", "EventTarget");
      const t = str(type);
      const capture = options !== null && typeof options === "object" ? !!options.capture : !!options;
      const s = ets(this);
      for (const l of s.listeners) {
        if (!l.handler && l.type === t && l.callback === callback && l.capture === capture) { removeListener(s, l); break; }
      }
    }
    dispatchEvent(event) {
      arity(1, arguments.length, "dispatchEvent", "EventTarget");
      if (!(event instanceof Event)) throw new TypeError("Failed to execute 'dispatchEvent' on 'EventTarget': parameter 1 is not of type 'Event'.");
      const st = evState.get(event);
      if (st !== undefined && st.dispatching) throw dom("InvalidStateError", "The event is already being dispatched.");
      return !dispatch(this, event).canceled;
    }
  }
  // 	his of an event handler attribute must be one of our event targets (the prototype object is not)
  function brandTarget(o) {
    if (!reqState.has(o) && !dbState.has(o) && !txState.has(o)) throw new TypeError("Illegal invocation");
  }

  function defineHandlers(cls, types) {
    for (const type of types) {
      const name = "on" + type;
      // (the accessors' names are Web IDL's: "get onsuccess", "set onsuccess")
      const accessors = {
        ["get " + name]: function () { brandTarget(this); const s = etState.get(this); const h = s === undefined ? undefined : s.handlers[type]; return h === undefined ? null : h; },
        ["set " + name]: function (v) {
          brandTarget(this);
          const s = ets(this);
          const f = (v !== null && (typeof v === "object" || typeof v === "function")) ? v : null;
          if (!(type in s.handlers) && f !== null) s.listeners.push({ type, callback: null, capture: false, once: false, passive: false, removed: false, handler: true });
          s.handlers[type] = f;
        },
      };
      Object.defineProperty(cls.prototype, name, { get: accessors["get " + name], set: accessors["set " + name], enumerable: true, configurable: true });
    }
  }
  // ---- tasks, the active state of transactions --------------------------------------------------------------------
  const tasks = new Map();
  let nextTask = 1;
  function post(fn) {
    const id = nextTask++;
    tasks.set(id, fn);
    const w = new Wr();
    w.uv(id);
    call(OP.TASK, w.done());
  }

  const activeSet = new Set();
  let cleanupArmed = false;
  function activate(tx) {
    tx.state = "active";
    activeSet.add(tx);
    if (!cleanupArmed) { cleanupArmed = true; call(OP.CLEANUP); }
  }
  const vcDone = [];   // connections whose versionchange handlers have run: answered once their microtasks are done
  function cleanup() {
    cleanupArmed = false;
    while (vcDone.length > 0) {
      const w = new Wr();
      w.uv(vcDone.shift());
      call(OP.VC_DONE, w.done());
    }
    const list = [...activeSet];
    activeSet.clear();
    for (const tx of list) { if (tx.state === "active") tx.state = "inactive"; }
    for (const tx of list) maybeCommit(tx);
  }

  // ---- state of the objects ---------------------------------------------------------------------------------------
  const dbState = new WeakMap();      // IDBDatabase -> connection
  const txState = new WeakMap();      // IDBTransaction -> T
  const reqState = new WeakMap();     // IDBRequest -> R
  const storeState = new WeakMap();   // IDBObjectStore -> { meta, tx }
  const indexState = new WeakMap();   // IDBIndex -> { meta, store (state), tx }
  const cursorState = new WeakMap();  // IDBCursor -> C
  const listState = new WeakMap();    // DOMStringList -> array

  const conns = new Map();            // connection id -> connection
  const txs = new Map();              // transaction id -> T
  const openReqs = new Map();         // request id -> R (open / delete requests)
  const listReqs = new Map();         // request id -> { resolve, reject }

  function illegal() { return new TypeError("Illegal invocation"); }
  function sOf(map, o) { const s = map.get(o); if (s === undefined) throw illegal(); return s; }

  // ---- DOMStringList ----------------------------------------------------------------------------------------------
  class DOMStringList {
    constructor() { throw new TypeError("Illegal constructor"); }
    get length() { return sOf(listState, this).length; }
    item(index) {
      arity(1, arguments.length, "item", "DOMStringList");
      const l = sOf(listState, this);
      const i = Number(index) >>> 0;
      return i < l.length ? l[i] : null;
    }
    contains(string) { arity(1, arguments.length, "contains", "DOMStringList"); return sOf(listState, this).includes(str(string)); }
  }
  DOMStringList.prototype[Symbol.iterator] = Array.prototype[Symbol.iterator];
  function makeList(names) {
    const l = Object.create(DOMStringList.prototype);
    listState.set(l, []);
    setList(l, names);
    return l;
  }
  function setList(l, names) {
    const a = listState.get(l);
    for (let i = names.length; i < a.length; i++) delete l[i];
    a.length = 0;
    for (let i = 0; i < names.length; i++) { a.push(names[i]); l[i] = names[i]; }
  }

  // ---- requests ---------------------------------------------------------------------------------------------------
  class IDBRequest extends IDBEventTarget {
    constructor() { super(); throw new TypeError("Illegal constructor"); }
    get result() {
      const r = sOf(reqState, this);
      if (r.readyState !== "done") throw dom("InvalidStateError", "The request has not finished.");
      return r.result;
    }
    get error() {
      const r = sOf(reqState, this);
      if (r.readyState !== "done") throw dom("InvalidStateError", "The request has not finished.");
      return r.error;
    }
    get source() { return sOf(reqState, this).source; }
    get transaction() { const t = sOf(reqState, this).tx; return t === null ? null : t.wrapper; }
    get readyState() { return sOf(reqState, this).readyState; }
  }
  class IDBOpenDBRequest extends IDBRequest { }
  defineHandlers(IDBRequest, ["success", "error"]);
  defineHandlers(IDBOpenDBRequest, ["blocked", "upgradeneeded"]);

  function newRequest(proto, source, tx) {
    const w = Object.create(proto);
    const r = { wrapper: w, readyState: "pending", result: undefined, error: null, source, tx, cursor: null };
    reqState.set(w, r);
    return r;
  }

  // ---- connections, the factory -------------------------------------------------------------------------------------
  function readMeta(rd) {
    const version = rd.uv();
    const n = rd.uv();
    const stores = [];
    for (let i = 0; i < n; i++) {
      const s = { id: rd.uv(), name: rd.str(), keyPath: unpackPath(rd.bytes()), autoIncrement: !!(rd.u8() & 1), indexes: [], hostIndexes: [], deleted: false, ready: true };
      const m = rd.uv();
      for (let j = 0; j < m; j++) {
        const ix = { id: rd.uv(), name: rd.str(), keyPath: unpackPath(rd.bytes()), unique: false, multiEntry: false, deleted: false, ready: true };
        const f = rd.u8();
        ix.unique = !!(f & 1);
        ix.multiEntry = !!(f & 2);
        s.indexes.push(ix);
        s.hostIndexes.push(ix);
      }
      stores.push(s);
    }
    return { version, stores };
  }

  function newConnection(id, name, meta) {
    const db = Object.create(IDBDatabase.prototype);
    etState.set(db, { listeners: [], handlers: Object.create(null) });
    const c = { id, name, version: meta.version, wrapper: db, stores: meta.stores, closePending: false, closed: false, upgradeTx: null, names: null, txCount: 0 };
    c.names = makeList(c.stores.map((s) => s.name).sort());
    dbState.set(db, c);
    conns.set(id, c);
    return c;
  }

  function updateNames(c) { setList(c.names, c.stores.map((s) => s.name).sort()); }

  class IDBFactory {
    constructor() { throw new TypeError("Illegal constructor"); }
    open(name, version = undefined) {
      const F = sOf(factoryState, this);
      arity(1, arguments.length, "open", "IDBFactory");
      const n = str(name);
      let v = 0, has = 0;
      if (version !== undefined) {
        const x = Number(version);
        if (!Number.isFinite(x) || x < 0 || x > MAX_UV) throw new TypeError("Failed to execute 'open' on 'IDBFactory': The version provided is out of range.");
        v = mathFloor(x);
        if (v === 0) throw new TypeError("Failed to execute 'open' on 'IDBFactory': The version provided must not be 0.");
        has = 1;
      }
      const w = new Wr();
      w.str(n); w.uv(v); w.u8(has); w.str(F.bucket);
      const rep = call(OP.OPEN, w.done());
      if (rep[0] && !(F.bucket !== "" && rep[0] === E_UNKNOWN)) throw fail(rep[0]);
      const req = newRequest(IDBOpenDBRequest.prototype, null, null);
      req.name = n;
      if (rep[0]) {   // the bucket was deleted: the request fails
        post(() => openError(req, E_UNKNOWN));
        return req.wrapper;
      }
      openReqs.set(new Rd(rep, 1).uv(), req);
      return req.wrapper;
    }
    deleteDatabase(name) {
      const F = sOf(factoryState, this);
      arity(1, arguments.length, "deleteDatabase", "IDBFactory");
      const w = new Wr();
      w.str(str(name)); w.str(F.bucket);
      const rep = call(OP.DELETE, w.done());
      if (rep[0]) throw fail(rep[0]);
      const req = newRequest(IDBOpenDBRequest.prototype, null, null);
      req.isDelete = true;
      openReqs.set(new Rd(rep, 1).uv(), req);
      return req.wrapper;
    }
    databases() {
      try {
        const F = sOf(factoryState, this);
        const lw = new Wr();
        lw.str(F.bucket);
        const rep = call(OP.LIST, lw.done());
        if (rep[0]) throw fail(rep[0]);
        const id = new Rd(rep, 1).uv();
        return new Promise((resolve, reject) => listReqs.set(id, { resolve, reject }));
      } catch (e) { return Promise.reject(e); }
    }
    cmp(first, second) {
      sOf(factoryState, this);
      arity(2, arguments.length, "cmp", "IDBFactory");
      const a = keyOf(first);
      if (a === null) throw dom("DataError", "The parameter is not a valid key.");
      const b = keyOf(second);
      if (b === null) throw dom("DataError", "The parameter is not a valid key.");
      return compareBytes(a, b);
    }
  }
  const factoryState = new WeakMap();

  // ---- IDBDatabase ------------------------------------------------------------------------------------------------
  class IDBDatabase extends IDBEventTarget {
    constructor() { super(); throw new TypeError("Illegal constructor"); }
    get name() { return sOf(dbState, this).name; }
    get version() { return sOf(dbState, this).version; }
    get objectStoreNames() { return sOf(dbState, this).names; }
    createObjectStore(name, options = undefined) {
      const c = sOf(dbState, this);
      arity(1, arguments.length, "createObjectStore", "IDBDatabase");
      const n = str(name);
      let keyPath = null, autoIncrement = false;
      if (options !== undefined && options !== null) {
        if (typeof options !== "object" && typeof options !== "function") throw new TypeError("The options argument is not of type 'IDBObjectStoreParameters'.");
        let kp = options.keyPath;
        autoIncrement = !!options.autoIncrement;
        if (kp !== undefined && kp !== null) {
          if (typeof kp === "object" && !isArray(kp) && Symbol.iterator in kp) kp = [...kp].map(str);
          else if (isArray(kp)) kp = kp.map(str);
          else kp = str(kp);
          keyPath = kp;
        }
      }
      const T = c.upgradeTx;
      if (T === null) throw dom("InvalidStateError", "The database is not running a version change transaction.");
      if (T.state !== "active") throw dom("TransactionInactiveError", "The transaction is not active.");
      if (keyPath !== null && !validKeyPath(keyPath)) throw dom("SyntaxError", "The keyPath option is not a valid key path.");
      if (c.stores.some((s) => s.name === n)) throw dom("ConstraintError", "An object store with the specified name already exists.");
      if (autoIncrement && (keyPath === "" || isArray(keyPath))) throw dom("InvalidAccessError", "The autoIncrement option was set but the keyPath option was empty or an array.");
      // The store is there for the script at once; the browser makes it in its turn among the transaction's requests (those queued
      // before a deletion of a store of that name still run on the old one).
      const meta = { id: 0, name: n, keyPath: frozenPath(keyPath), autoIncrement, indexes: [], hostIndexes: [], deleted: false, ready: false };
      c.stores.push(meta);
      updateNames(c);
      enqueueInternal(T, () => {
        const w = reqWriter(T, REQ.CREATE_STORE, 0);
        w.str(n); w.bytes(packPath(keyPath)); w.u8(autoIncrement ? 1 : 0);
        meta.id = expectOk(call(OP.EXEC, w.done())).uv();
        meta.ready = true;
      });
      return storeFor(T, meta);
    }
    deleteObjectStore(name) {
      const c = sOf(dbState, this);
      arity(1, arguments.length, "deleteObjectStore", "IDBDatabase");
      const n = str(name);
      const T = c.upgradeTx;
      if (T === null) throw dom("InvalidStateError", "The database is not running a version change transaction.");
      if (T.state !== "active") throw dom("TransactionInactiveError", "The transaction is not active.");
      const i = c.stores.findIndex((s) => s.name === n);
      if (i < 0) throw dom("NotFoundError", "The object store was not found.");
      const meta = c.stores[i];
      c.stores.splice(i, 1);
      meta.deleted = true;
      for (const ix of meta.indexes) ix.deleted = true;
      updateNames(c);
      enqueueInternal(T, () => {
        if (!meta.ready) return;
        expectOk(call(OP.EXEC, reqWriter(T, REQ.DELETE_STORE, meta.id).done()));
      });
    }
    transaction(storeNames, mode = "readonly", options = undefined) {
      const c = sOf(dbState, this);
      arity(1, arguments.length, "transaction", "IDBDatabase");
      let names;
      if (typeof storeNames === "string") names = [storeNames];
      else if (storeNames !== null && typeof storeNames === "object" && typeof storeNames[Symbol.iterator] === "function") names = [...storeNames].map(str);
      else names = [str(storeNames)];
      const m = checkEnum(mode, ["readonly", "readwrite", "versionchange"], "IDBTransactionMode");
      let durability = "default";
      if (options !== undefined && options !== null) {
        if (typeof options !== "object" && typeof options !== "function") throw new TypeError("The options argument is not of type 'IDBTransactionOptions'.");
        if (options.durability !== undefined) durability = checkEnum(options.durability, ["default", "strict", "relaxed"], "IDBTransactionDurability");
      }
      if (c.upgradeTx !== null && c.upgradeTx.state !== "finished") throw dom("InvalidStateError", "A version change transaction is running.");
      if (c.closePending || c.closed) throw dom("InvalidStateError", "The database connection is closing.");
      if (names.length === 0) throw dom("InvalidAccessError", "The storeNames parameter is empty.");
      const scope = [];
      for (const n of names) {
        const meta = c.stores.find((s) => s.name === n);
        if (meta === undefined) throw dom("NotFoundError", "One of the specified object stores was not found.");
        if (!scope.includes(meta)) scope.push(meta);
      }
      if (m === "versionchange") throw new TypeError("Failed to execute 'transaction' on 'IDBDatabase': The mode provided ('versionchange') is not one of 'readonly' or 'readwrite'.");
      scope.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
      const w = new Wr();
      w.uv(c.id); w.u8(m === "readwrite" ? 1 : 0); w.u8(durability === "strict" ? 1 : 0); w.uv(scope.length);
      for (const s of scope) w.uv(s.id);
      const rep = call(OP.BEGIN, w.done());
      if (rep[0]) throw fail(rep[0]);
      const rd = new Rd(rep, 1);
      const T = newTransaction(c, rd.uv(), m, scope, durability);
      if (rd.u8() !== 0) { T.started = true; T.startedEarly = true; }   // (the browser started it at once: its first request need not wait for an event)
      return T.wrapper;
    }
    close() {
      const c = sOf(dbState, this);
      if (c.closePending) return;
      c.closePending = true;
      const w = new Wr();
      w.uv(c.id);
      call(OP.CLOSE, w.done());
      conns.delete(c.id);   // (its transactions still finish: they are found by their own ids)
    }
  }
  defineHandlers(IDBDatabase, ["abort", "close", "error", "versionchange"]);

  // ---- transactions -----------------------------------------------------------------------------------------------
  class IDBTransaction extends IDBEventTarget {
    constructor() { super(); throw new TypeError("Illegal constructor"); }
    get objectStoreNames() {
      const T = sOf(txState, this);
      if (T.mode === "versionchange") return T.conn.names;
      if (T.names === null) T.names = makeList(T.scope.map((s) => s.name));
      return T.names;
    }
    get mode() { return sOf(txState, this).mode; }
    get durability() { return sOf(txState, this).durability; }
    get db() { return sOf(txState, this).conn.wrapper; }
    get error() { return sOf(txState, this).error; }
    objectStore(name) {
      const T = sOf(txState, this);
      arity(1, arguments.length, "objectStore", "IDBTransaction");
      const n = str(name);
      if (T.state === "finished") throw dom("InvalidStateError", "The transaction has finished.");
      const meta = T.mode === "versionchange" ? T.conn.stores.find((s) => s.name === n) : T.scope.find((s) => s.name === n);
      if (meta === undefined) throw dom("NotFoundError", "The specified object store was not found.");
      return storeFor(T, meta);
    }
    abort() {
      const T = sOf(txState, this);
      if (T.state === "committing" || T.state === "finished") throw dom("InvalidStateError", "The transaction is already finishing.");
      abortTransaction(T, null, E_ABORTED, true);
    }
    commit() {
      const T = sOf(txState, this);
      if (T.state !== "active") throw dom("InvalidStateError", "The transaction is not active.");
      T.state = "committing";
      maybeCommit(T);
    }
  }
  defineHandlers(IDBTransaction, ["abort", "complete", "error"]);

  function newTransaction(conn, id, mode, scope, durability) {
    const w = Object.create(IDBTransaction.prototype);
    etState.set(w, { listeners: [], handlers: Object.create(null) });
    const T = { id, conn, mode, scope, durability, state: "active", started: false, queue: [], busy: false, error: null, wrapper: w,
      stores: new Map(), names: null, commitSent: false, dead: false, upgradeReq: null, backup: null };
    txState.set(w, T);
    txs.set(id, T);
    conn.txCount++;
    activate(T);
    return T;
  }

  function maybeCommit(T) {
    if (T.dead || T.commitSent || !T.started) return;
    if (T.state !== "inactive" && T.state !== "committing") return;
    if (T.queue.length > 0 || T.busy) return;
    T.commitSent = true;
    T.state = "committing";
    const w = new Wr();
    w.uv(T.id);
    const rep = call(OP.COMMIT, w.done());
    if (rep[0]) {
      // the browser has no such transaction any more (it was aborted there): its event tells
      T.commitSent = false;
    }
  }

  // Aborts: the work is taken back by the browser at once; the requests that did not run fail with AbortError, then
  // "abort" fires at the transaction.
  function abortTransaction(T, error, code, tellHost) {
    if (T.dead) return;
    T.dead = true;
    T.state = "finished";
    T.error = error;
    activeSet.delete(T);
    const pending = T.queue.splice(0);
    const wasUpgrade = T.mode === "versionchange";
    if (wasUpgrade) { restoreMeta(T); T.conn.version = T.oldVersion; }
    for (const q of pending) {
      if (q.R === null) continue;
      post(() => {
        const R = q.R;
        R.readyState = "done"; R.result = undefined; R.error = dom("AbortError", "The transaction was aborted.");
        dispatch(R.wrapper, plainEvent("error", true, true));
      });
    }
    post(() => {
      if (T.conn.upgradeTx === T) T.conn.upgradeTx = null;   // (no version change transaction is running any more in the handlers)
      dispatch(T.wrapper, plainEvent("abort", true, false));
      if (T.upgradeReq !== null) T.upgradeReq.tx = null;   // the open request no longer has a transaction once it ended
      T.conn.txCount--;
      forgetTx(T);
    });
    if (tellHost) {
      const w = new Wr();
      w.uv(T.id); w.u8(code);
      call(OP.ABORT, w.done());
    }
    txs.delete(T.id);
  }

  function forgetTx(T) {
    txs.delete(T.id);
    if (T.conn.upgradeTx === T) T.conn.upgradeTx = null;
  }

  // ---- running a transaction's requests ---------------------------------------------------------------------------
  function reqWriter(T, op, store) {
    const w = new Wr();
    w.uv(T.id);
    w.u8(op);
    if (op !== REQ.CREATE_STORE) w.uv(store);
    return w;
  }

  function enqueueInternal(T, exec) {
    T.queue.push({ R: null, exec });
    if (T.started) processNext(T);
  }

  function enqueue(T, R, exec) {
    T.queue.push({ R, exec });
    if (T.started) processNext(T);
  }

  function processNext(T) {
    if (T.busy || !T.started || T.dead) return;
    if (T.queue.length === 0) return;
    T.busy = true;
    post(() => runNext(T));
  }

  function runNext(T) {
    if (T.dead) return;
    const q = T.queue.shift();
    if (q === undefined) { T.busy = false; maybeCommit(T); return; }
    const R = q.R;
    if (R === null) {   // an operation of the transaction's own (no request, no event): index creation
      try { q.exec(T, null); } catch (e) {
        if (e instanceof Failure) { abortTransaction(T, fail(e.code, e.message), e.code, true); return; }
        throw e;
      }
      T.busy = false;
      if (T.queue.length > 0) processNext(T); else maybeCommit(T);
      return;
    }
    let ok = true, value, errCode = 0, errMsg;
    try {
      value = q.exec(T, R);
    } catch (e) {
      if (e instanceof Failure) { ok = false; errCode = e.code; errMsg = e.message; } else throw e;
    }
    R.readyState = "done";
    if (T.state !== "committing") T.state = "active";
    activeSet.add(T);
    if (!cleanupArmed) { cleanupArmed = true; call(OP.CLEANUP); }
    let outcome;
    if (ok) {
      R.result = value; R.error = null;
      outcome = dispatch(R.wrapper, plainEvent("success", false, false));
      T.busy = false;
      if (outcome.threw && T.state !== "committing") { abortTransaction(T, dom("AbortError", "An exception was thrown by an event handler."), E_ABORTED, true); return; }
    } else {
      R.result = undefined; R.error = fail(errCode, errMsg);
      outcome = dispatch(R.wrapper, plainEvent("error", true, true));
      T.busy = false;
      if (outcome.threw) { abortTransaction(T, dom("AbortError", "An exception was thrown by an event handler."), E_ABORTED, true); return; }
      if (!outcome.canceled) { abortTransaction(T, R.error, errCode, true); return; }
    }
    if (T.state === "active" || T.state === "inactive" || T.state === "committing") processNext(T);
  }

  class Failure {
    constructor(code, message) { this.code = code; this.message = message; }
  }
  function expectOk(rep) {
    if (rep[0]) throw new Failure(rep[0]);
    return new Rd(rep, 1);
  }

  // ---- object stores ----------------------------------------------------------------------------------------------
  function storeFor(T, meta) {
    let w = T.stores.get(meta);
    if (w === undefined) {
      w = Object.create(IDBObjectStore.prototype);
      storeState.set(w, { meta, tx: T, indexes: new Map(), wrapper: w, names: null });
      T.stores.set(meta, w);
    }
    return w;
  }

  // The checks every request method starts with (put, get...): the store exists, the transaction is active, and writes need a writable one.
  function checkStore(S, write) {
    if (S.meta.deleted) throw dom("InvalidStateError", "The object store has been deleted.");
    const T = S.tx;
    if (T.state !== "active") throw dom("TransactionInactiveError", "The transaction is " + (T.state === "finished" ? "finished." : "not active."));
    if (write && T.mode === "readonly") throw dom("ReadOnlyError", "The transaction is read-only.");
    return T;
  }

  // The structured clone of a value runs with the transaction inactive (a getter of the value cannot use it)
  function cloneValue(T, value) {
    const prev = T.state;
    T.state = "inactive";
    try { return serialize(value); } finally { if (T.state === "inactive") T.state = prev; }
  }

  function valueOf(rd) { return deserialize(rd.bytes()); }

  function pathOf(S) { return S.meta.keyPath; }

  // The index keys of a value, for the indexes of the store as they are when the request runs: the keys taken when the request
  // was made (snap, [index, keys] of the indexes there were: the value was a snapshot then) where there are, else from the
  // clone (an index created since, by a version change transaction whose requests were queued before it).
  function snapIndexKeys(S, value) { return S.meta.indexes.map((ix) => [ix, indexKeys(value, ix)]); }
  function writeIndexKeys(w, S, snap, bytes) {
    const list = [];
    let clone = null;
    // (the indexes the browser has now: one made later, or one deleted later, is not for a request that is ahead of it)
    for (const ix of S.meta.hostIndexes) {
      let keys = null;
      for (const e of snap) { if (e[0] === ix) { keys = e[1]; break; } }
      if (keys === null) { if (clone === null) clone = deserialize(bytes); keys = indexKeys(clone, ix); }
      for (const k of keys) list.push([ix.id, k]);
    }
    w.uv(list.length);
    for (const [id, k] of list) { w.uv(id); w.bytes(k); }
  }

  function doPut(S, value, key, noOverwrite, what) {
    const T = checkStore(S, true);
    const meta = S.meta;
    const kp = meta.keyPath;
    if (kp !== null && key !== undefined) throw dom("DataError", "The object store uses in-line keys and the key parameter was provided.");
    if (kp === null && !meta.autoIncrement && key === undefined) throw dom("DataError", "The object store uses out-of-line keys and has no key generator and the key parameter was not provided.");
    let keyBytes = null;
    if (key !== undefined) {
      keyBytes = keyOf(key);
      if (keyBytes === null) throw dom("DataError", "The parameter is not a valid key.");
    }
    const bytes = cloneValue(T, value);
    let generate = false;
    // key paths are read on the clone, not on the value (a getter or a Proxy of the value ran once, in the clone)
    const evalValue = (typeof value === "object" && value !== null && (kp !== null || meta.indexes.length > 0)) ? deserialize(bytes) : value;
    if (kp !== null) {
      const k = pathKey(evalValue, kp);
      if (k === null) throw dom("DataError", "The key path yielded a value that is not a valid key.");
      if (k === undefined) {
        if (!meta.autoIncrement) throw dom("DataError", "Evaluating the object store's key path did not yield a value.");
        if (typeof kp !== "string" || !canInject(evalValue, kp)) throw dom("DataError", "A key could not be injected into the value.");
        generate = true;
      } else keyBytes = k;
    }
    const R = newRequest(IDBRequest.prototype, S.wrapper, T);
    etState.set(R.wrapper, { listeners: [], handlers: Object.create(null) });
    // index keys of the value as it is now (the clone is the snapshot); with a generated key they come from the clone
    const snapshot = generate ? null : snapIndexKeys(S, evalValue);
    enqueue(T, R, () => {
      let kb = keyBytes, vb = bytes, ik = null;
      if (generate) {
        // the generator's next key (it moves on with the put, and only if the put succeeds)
        const g = reqWriter(T, REQ.PEEK_KEY, meta.id);
        kb = expectOk(call(OP.EXEC, g.done())).bytes().slice();
        const clone = deserialize(bytes);
        inject(clone, kp, decodeKey(kb));
        vb = serialize(clone);
        ik = new Wr();
        writeIndexKeys(ik, S, snapIndexKeys(S, clone), vb);
      } else {
        ik = new Wr();
        writeIndexKeys(ik, S, snapshot, vb);
      }
      const w = reqWriter(T, REQ.PUT, meta.id);
      w.u8((noOverwrite ? 1 : 0) | (kb !== null ? 2 : 0) | (generate ? 4 : 0));
      if (kb !== null) w.bytes(kb);
      w.bytes(vb);
      w.raw(ik.done());
      return decodeKey(expectOk(call(OP.EXEC, w.done())).bytes());
    });
    return R.wrapper;
  }

  function isDictionary(v) {
    if (v === null || typeof v !== "object") return false;
    const p = Object.getPrototypeOf(v);
    return p === Object.prototype || p === null;
  }

  // getAll / getAllKeys arguments: (query, count) or ({ query, count, direction })
  function listArgs(queryOrOptions, count) {
    let query = queryOrOptions, direction = "next";
    // an ordinary object that is not a key is the options dictionary (a Date, a buffer, an array are queries)
    if (isDictionary(queryOrOptions) && !rangeState.has(queryOrOptions) && keyOf(queryOrOptions) === null) {
      query = queryOrOptions.query;
      if (queryOrOptions.count !== undefined) count = queryOrOptions.count;
      if (queryOrOptions.direction !== undefined) direction = checkEnum(queryOrOptions.direction, ["next", "nextunique", "prev", "prevunique"], "IDBCursorDirection");
    }
    const range = rangeArg(query, true);
    const limit = count === undefined ? 0 : enforceUnsignedLong(count, "count");
    return { range, limit, backwards: direction === "prev" || direction === "prevunique", unique: direction === "nextunique" || direction === "prevunique" };
  }

  // getAllRecords' dictionary { query, count, direction }
  function optionsArgs(opt) {
    if (opt === undefined || opt === null) opt = {};
    else if (typeof opt !== "object" && typeof opt !== "function") throw new TypeError("The options argument is not of type 'IDBGetAllOptions'.");
    const direction = opt.direction === undefined ? "next" : checkEnum(opt.direction, ["next", "nextunique", "prev", "prevunique"], "IDBCursorDirection");
    const range = rangeArg(opt.query, true);
    const limit = opt.count === undefined ? 0 : enforceUnsignedLong(opt.count, "count");
    return { range, limit, backwards: direction === "prev" || direction === "prevunique", unique: direction === "nextunique" || direction === "prevunique" };
  }

  const recordState = new WeakMap();
  class IDBRecord {
    constructor() { throw new TypeError("Illegal constructor"); }
    get key() { return sOf(recordState, this).key; }
    get primaryKey() { return sOf(recordState, this).primaryKey; }
    get value() { return sOf(recordState, this).value; }
  }
  function makeRecord(key, primaryKey, value) {
    const r = Object.create(IDBRecord.prototype);
    recordState.set(r, { key, primaryKey, value });
    return r;
  }

  function getAllRequest(S, src, T, srcWrapper, mode, queryOrOptions, count, preset) {
    const a = preset || listArgs(queryOrOptions, count);
    const R = newRequest(IDBRequest.prototype, srcWrapper, T);
    etState.set(R.wrapper, { listeners: [], handlers: Object.create(null) });
    enqueue(T, R, () => {
      // the browser answers a long list in pieces (about 2 MiB of reply each, with where to go on): only one piece is in flight at a time
      const out = [];
      let resume = null;
      for (;;) {
        const w = reqWriter(T, REQ.GET_ALL, S.meta.id);
        w.uv(src.index ? src.index.id : 0);
        putRange(w, a.range);
        w.u8(mode); w.u8((a.backwards ? 1 : 0) | (a.unique ? 2 : 0) | (resume !== null ? 4 : 0)); w.uv(a.limit > 0 ? a.limit - out.length : 0);
        if (resume !== null) { w.bytes(resume.key); w.bytes(resume.pk); }
        const rd = expectOk(call(OP.EXEC, w.done()));
        const n = rd.uv();
        for (let i = 0; i < n; i++) {
          if (mode === 1) out.push(decodeKey(rd.bytes()));
          else if (mode === 2) out.push(valueOf(rd));
          else { const k = decodeKey(rd.bytes()), pk = decodeKey(rd.bytes()); out.push(makeRecord(k, pk, valueOf(rd))); }
        }
        if (rd.u8() === 0 || (a.limit > 0 && out.length >= a.limit)) break;
        resume = { key: rd.bytes().slice(), pk: rd.bytes().slice() };
      }
      return out;
    });
    return R.wrapper;
  }

  function getRequest(S, src, T, srcWrapper, keyOnly, query) {
    const range = rangeArg(query, false);
    const R = newRequest(IDBRequest.prototype, srcWrapper, T);
    etState.set(R.wrapper, { listeners: [], handlers: Object.create(null) });
    enqueue(T, R, () => {
      const w = reqWriter(T, REQ.GET, S.meta.id);
      w.uv(src.index ? src.index.id : 0);
      putRange(w, range);
      w.u8(keyOnly ? 1 : 0);
      const rd = expectOk(call(OP.EXEC, w.done()));
      if (!rd.u8()) return undefined;
      const pk = rd.bytes();
      return keyOnly ? decodeKey(pk) : valueOf(rd);
    });
    return R.wrapper;
  }

  function countRequest(S, src, T, srcWrapper, query) {
    const range = rangeArg(query, true);
    const R = newRequest(IDBRequest.prototype, srcWrapper, T);
    etState.set(R.wrapper, { listeners: [], handlers: Object.create(null) });
    enqueue(T, R, () => {
      const w = reqWriter(T, REQ.COUNT, S.meta.id);
      w.uv(src.index ? src.index.id : 0);
      putRange(w, range);
      return expectOk(call(OP.EXEC, w.done())).uv();
    });
    return R.wrapper;
  }

  class IDBObjectStore {
    constructor() { throw new TypeError("Illegal constructor"); }
    get name() { return sOf(storeState, this).meta.name; }
    set name(value) {
      const S = sOf(storeState, this);
      const n = str(value);
      const T = S.tx;
      if (T.mode !== "versionchange") throw dom("InvalidStateError", "The object store's name can only be changed in a version change transaction.");
      if (S.meta.deleted) throw dom("InvalidStateError", "The object store has been deleted.");
      if (T.state !== "active") throw dom("TransactionInactiveError", "The transaction is not active.");
      if (n === S.meta.name) return;
      if (T.conn.stores.some((s) => s !== S.meta && s.name === n)) throw dom("ConstraintError", "An object store with the specified name already exists.");
      const meta = S.meta;
      meta.name = n;
      updateNames(T.conn);
      enqueueInternal(T, () => {   // (a store not made yet is made under its name then)
        if (!meta.ready) return;
        const w = reqWriter(T, REQ.RENAME_STORE, meta.id);
        w.str(n);
        expectOk(call(OP.EXEC, w.done()));
      });
    }
    // (an array key path: the same frozen array each time for one object, another for another)
    get keyPath() { const S = sOf(storeState, this); return keyPathOf(S, S.meta.keyPath); }
    get indexNames() {
      const S = sOf(storeState, this);
      const names = S.meta.deleted ? [] : S.meta.indexes.map((i) => i.name).sort();
      if (S.names === null) S.names = makeList(names);
      else setList(S.names, names);
      return S.names;
    }
    get transaction() { return sOf(storeState, this).tx.wrapper; }
    get autoIncrement() { return sOf(storeState, this).meta.autoIncrement; }
    put(value, key = undefined) { const S = sOf(storeState, this); arity(1, arguments.length, "put", "IDBObjectStore"); return doPut(S, value, key, false); }
    add(value, key = undefined) { const S = sOf(storeState, this); arity(1, arguments.length, "add", "IDBObjectStore"); return doPut(S, value, key, true); }
    delete(query) {
      const S = sOf(storeState, this);
      arity(1, arguments.length, "delete", "IDBObjectStore");
      const T = checkStore(S, true);
      const range = rangeArg(query, false);
      const R = newRequest(IDBRequest.prototype, this, T);
      etState.set(R.wrapper, { listeners: [], handlers: Object.create(null) });
      enqueue(T, R, () => {
        const w = reqWriter(T, REQ.DELETE, S.meta.id);
        putRange(w, range);
        expectOk(call(OP.EXEC, w.done()));
        return undefined;
      });
      return R.wrapper;
    }
    clear() {
      const S = sOf(storeState, this);
      const T = checkStore(S, true);
      const R = newRequest(IDBRequest.prototype, this, T);
      etState.set(R.wrapper, { listeners: [], handlers: Object.create(null) });
      enqueue(T, R, () => { expectOk(call(OP.EXEC, reqWriter(T, REQ.CLEAR, S.meta.id).done())); return undefined; });
      return R.wrapper;
    }
    get(query) {
      const S = sOf(storeState, this);
      arity(1, arguments.length, "get", "IDBObjectStore");
      const T = checkStore(S, false);
      return getRequest(S, {}, T, this, false, query, "get", "IDBObjectStore");
    }
    getKey(query) {
      const S = sOf(storeState, this);
      arity(1, arguments.length, "getKey", "IDBObjectStore");
      const T = checkStore(S, false);
      return getRequest(S, {}, T, this, true, query, "getKey", "IDBObjectStore");
    }
    getAll(queryOrOptions = undefined, count = undefined) {
      const S = sOf(storeState, this);
      const T = checkStore(S, false);
      return getAllRequest(S, {}, T, this, 2, queryOrOptions, count);
    }
    getAllKeys(queryOrOptions = undefined, count = undefined) {
      const S = sOf(storeState, this);
      const T = checkStore(S, false);
      return getAllRequest(S, {}, T, this, 1, queryOrOptions, count);
    }
    getAllRecords(options = undefined) {
      const S = sOf(storeState, this);
      const a = optionsArgs(options);
      const T = checkStore(S, false);
      return getAllRequest(S, {}, T, this, 3, undefined, undefined, a);
    }
    count(query = undefined) {
      const S = sOf(storeState, this);
      const T = checkStore(S, false);
      return countRequest(S, {}, T, this, query);
    }
    openCursor(query = undefined, direction = "next") {
      const S = sOf(storeState, this);
      const T = checkStore(S, false);
      return openCursor(S, {}, T, this, query, direction, false);
    }
    openKeyCursor(query = undefined, direction = "next") {
      const S = sOf(storeState, this);
      const T = checkStore(S, false);
      return openCursor(S, {}, T, this, query, direction, true);
    }
    index(name) {
      const S = sOf(storeState, this);
      arity(1, arguments.length, "index", "IDBObjectStore");
      const n = str(name);
      if (S.meta.deleted) throw dom("InvalidStateError", "The object store has been deleted.");
      if (S.tx.state === "finished") throw dom("InvalidStateError", "The transaction has finished.");
      const meta = S.meta.indexes.find((i) => i.name === n);
      if (meta === undefined) throw dom("NotFoundError", "The specified index was not found.");
      return indexFor(S, meta);
    }
    createIndex(name, keyPath, options = undefined) {
      const S = sOf(storeState, this);
      arity(2, arguments.length, "createIndex", "IDBObjectStore");
      const n = str(name);
      let kp;
      if (isArray(keyPath)) kp = keyPath.map(str);
      else if (keyPath !== null && typeof keyPath === "object" && typeof keyPath[Symbol.iterator] === "function") kp = [...keyPath].map(str);
      else kp = str(keyPath);
      let unique = false, multiEntry = false;
      if (options !== undefined && options !== null) {
        if (typeof options !== "object" && typeof options !== "function") throw new TypeError("The options argument is not of type 'IDBIndexParameters'.");
        unique = !!options.unique; multiEntry = !!options.multiEntry;
      }
      const T = S.tx;
      if (T.mode !== "versionchange") throw dom("InvalidStateError", "The database is not running a version change transaction.");
      if (S.meta.deleted) throw dom("InvalidStateError", "The object store has been deleted.");
      if (T.state !== "active") throw dom("TransactionInactiveError", "The transaction is not active.");
      if (S.meta.indexes.some((i) => i.name === n)) throw dom("ConstraintError", "An index with the specified name already exists.");
      if (!validKeyPath(kp)) throw dom("SyntaxError", "The keyPath argument contains an invalid key path.");
      if (isArray(kp) && multiEntry) throw dom("InvalidAccessError", "The keyPath argument is an array and the multiEntry option is true.");
      // The index is there for the script at once; the browser makes it, and fills it from the records, in its turn among the
      // transaction's requests (those queued before it do not know it, a failure aborts the transaction).
      const meta = { id: 0, name: n, keyPath: frozenPath(kp), unique, multiEntry, deleted: false, ready: false };
      S.meta.indexes.push(meta);
      enqueueInternal(T, () => {
        const w = reqWriter(T, REQ.CREATE_INDEX, S.meta.id);
        w.str(n); w.bytes(packPath(kp)); w.u8((unique ? 1 : 0) | (multiEntry ? 2 : 0));
        meta.id = expectOk(call(OP.EXEC, w.done())).uv();
        populateIndex(T, S, meta);
        meta.ready = true;
        S.meta.hostIndexes.push(meta);
      });
      return indexFor(S, meta);
    }
    deleteIndex(name) {
      const S = sOf(storeState, this);
      arity(1, arguments.length, "deleteIndex", "IDBObjectStore");
      const n = str(name);
      const T = S.tx;
      if (T.mode !== "versionchange") throw dom("InvalidStateError", "The database is not running a version change transaction.");
      if (S.meta.deleted) throw dom("InvalidStateError", "The object store has been deleted.");
      if (T.state !== "active") throw dom("TransactionInactiveError", "The transaction is not active.");
      const i = S.meta.indexes.findIndex((x) => x.name === n);
      if (i < 0) throw dom("NotFoundError", "The specified index was not found.");
      const meta = S.meta.indexes[i];
      // gone for the script at once; the browser drops it in its turn (the requests queued before still fill it)
      S.meta.indexes.splice(i, 1);
      meta.deleted = true;
      enqueueInternal(T, () => {
        if (!meta.ready) return;
        const w = reqWriter(T, REQ.DELETE_INDEX, S.meta.id);
        w.uv(meta.id);
        expectOk(call(OP.EXEC, w.done()));
        const h = S.meta.hostIndexes.indexOf(meta);
        if (h >= 0) S.meta.hostIndexes.splice(h, 1);
      });
    }
  }

  // Fills a new index from the records the store has: the browser lists them, the key path is evaluated here.
  function populateIndex(T, S, ix) {
    let after = null;
    for (;;) {
      const w = reqWriter(T, REQ.GET_ALL, S.meta.id);
      w.uv(0);
      putRange(w, after === null ? null : { lower: after, upper: null, lowerOpen: true, upperOpen: false });
      w.u8(3); w.u8(0); w.uv(256);
      const rep = call(OP.EXEC, w.done());
      if (rep[0]) throw new Failure(rep[0]);
      const rd = new Rd(rep, 1);
      const n = rd.uv();
      if (n === 0) break;
      for (let i = 0; i < n; i++) {
        const key = rd.bytes().slice();
        const pk = rd.bytes().slice();
        const value = deserialize(rd.bytes());
        after = pk;
        const keys = indexKeys(value, ix);
        if (keys.length === 0) continue;
        const iw = reqWriter(T, REQ.INDEX_PUT, S.meta.id);
        iw.uv(ix.id); iw.bytes(pk); iw.uv(keys.length);
        for (const k of keys) iw.bytes(k);
        const r2 = call(OP.EXEC, iw.done());
        // (a unique index that the records violate: the version change transaction aborts with a ConstraintError)
        if (r2[0]) throw new Failure(r2[0], "Unable to add the index entries.");
      }
      const more = rd.u8();   // (a piece cut short by its size: the next one goes on)
      if (n < 256 && more === 0) break;
    }
  }

  // ---- indexes ----------------------------------------------------------------------------------------------------
  function indexFor(S, meta) {
    let w = S.indexes.get(meta);
    if (w === undefined) {
      w = Object.create(IDBIndex.prototype);
      indexState.set(w, { meta, store: S, wrapper: w });
      S.indexes.set(meta, w);
    }
    return w;
  }

  function checkIndex(X) {
    if (X.meta.deleted || X.store.meta.deleted) throw dom("InvalidStateError", "The index or its object store has been deleted.");
    const T = X.store.tx;
    if (T.state !== "active") throw dom("TransactionInactiveError", "The transaction is " + (T.state === "finished" ? "finished." : "not active."));
    return T;
  }

  class IDBIndex {
    constructor() { throw new TypeError("Illegal constructor"); }
    get name() { return sOf(indexState, this).meta.name; }
    set name(value) {
      const X = sOf(indexState, this);
      const n = str(value);
      const S = X.store, T = S.tx;
      if (T.mode !== "versionchange") throw dom("InvalidStateError", "The index's name can only be changed in a version change transaction.");
      if (X.meta.deleted || S.meta.deleted) throw dom("InvalidStateError", "The index or its object store has been deleted.");
      if (T.state !== "active") throw dom("TransactionInactiveError", "The transaction is not active.");
      if (n === X.meta.name) return;
      if (S.meta.indexes.some((i) => i !== X.meta && i.name === n)) throw dom("ConstraintError", "An index with the specified name already exists.");
      const meta = X.meta;
      meta.name = n;
      enqueueInternal(T, () => {   // (an index not made yet is made under its name then)
        if (!meta.ready) return;
        const w = reqWriter(T, REQ.RENAME_INDEX, S.meta.id);
        w.uv(meta.id); w.str(n);
        expectOk(call(OP.EXEC, w.done()));
      });
    }
    get objectStore() { return sOf(indexState, this).store.wrapper; }
    get keyPath() { const X = sOf(indexState, this); return keyPathOf(X, X.meta.keyPath); }
    get multiEntry() { return sOf(indexState, this).meta.multiEntry; }
    get unique() { return sOf(indexState, this).meta.unique; }
    get(query) {
      const X = sOf(indexState, this);
      arity(1, arguments.length, "get", "IDBIndex");
      const T = checkIndex(X);
      return getRequest(X.store, { index: X.meta }, T, this, false, query, "get", "IDBIndex");
    }
    getKey(query) {
      const X = sOf(indexState, this);
      arity(1, arguments.length, "getKey", "IDBIndex");
      const T = checkIndex(X);
      return getRequest(X.store, { index: X.meta }, T, this, true, query, "getKey", "IDBIndex");
    }
    getAll(queryOrOptions = undefined, count = undefined) {
      const X = sOf(indexState, this);
      const T = checkIndex(X);
      return getAllRequest(X.store, { index: X.meta }, T, this, 2, queryOrOptions, count);
    }
    getAllKeys(queryOrOptions = undefined, count = undefined) {
      const X = sOf(indexState, this);
      const T = checkIndex(X);
      return getAllRequest(X.store, { index: X.meta }, T, this, 1, queryOrOptions, count);
    }
    getAllRecords(options = undefined) {
      const X = sOf(indexState, this);
      const a = optionsArgs(options);
      const T = checkIndex(X);
      return getAllRequest(X.store, { index: X.meta }, T, this, 3, undefined, undefined, a);
    }
    count(query = undefined) {
      const X = sOf(indexState, this);
      const T = checkIndex(X);
      return countRequest(X.store, { index: X.meta }, T, this, query);
    }
    openCursor(query = undefined, direction = "next") {
      const X = sOf(indexState, this);
      const T = checkIndex(X);
      return openCursor(X.store, { index: X.meta }, T, this, query, direction, false);
    }
    openKeyCursor(query = undefined, direction = "next") {
      const X = sOf(indexState, this);
      const T = checkIndex(X);
      return openCursor(X.store, { index: X.meta }, T, this, query, direction, true);
    }
  }

  // ---- cursors ----------------------------------------------------------------------------------------------------
  const DIRECTIONS = ["next", "nextunique", "prev", "prevunique"];
  const NOCACHE = Symbol("nocache");

  class IDBCursor {
    constructor() { throw new TypeError("Illegal constructor"); }
    get source() { return sOf(cursorState, this).sourceWrapper; }
    get direction() { return DIRECTIONS[sOf(cursorState, this).direction]; }
    // (the same object until the cursor moves: a script that changed it sees its change)
    get key() { const C = sOf(cursorState, this); if (C.key === null) return undefined; if (C.kv === NOCACHE) C.kv = decodeKey(C.key); return C.kv; }
    get primaryKey() { const C = sOf(cursorState, this); if (C.pk === null) return undefined; if (C.pv === NOCACHE) C.pv = decodeKey(C.pk); return C.pv; }
    get request() { return sOf(cursorState, this).R.wrapper; }
    advance(count) {
      const C = sOf(cursorState, this);
      arity(1, arguments.length, "advance", "IDBCursor");
      const n = enforceUnsignedLong(count, "count");
      if (n === 0) throw new TypeError("A count of 0 is not valid.");
      const T = cursorReady(C);
      step(C, T, null, null, n);
    }
    continue(key = undefined) {
      const C = sOf(cursorState, this);
      const T = cursorReady(C);
      let target = null;
      if (key !== undefined) {
        target = keyOf(key);
        if (target === null) throw dom("DataError", "The parameter is not a valid key.");
        const c = compareBytes(target, C.key);
        const fwd = C.direction < 2;
        if ((fwd && c <= 0) || (!fwd && c >= 0)) throw dom("DataError", "The parameter is less than or equal to this cursor's position.");
      }
      step(C, T, target, null, 1);
    }
    continuePrimaryKey(key, primaryKey) {
      const C = sOf(cursorState, this);
      arity(2, arguments.length, "continuePrimaryKey", "IDBCursor");
      const T = C.R.tx;
      if (T.state !== "active") throw dom("TransactionInactiveError", "The transaction is not active.");
      if (C.srcDeleted()) throw dom("InvalidStateError", "The cursor's source has been deleted.");
      if (C.index === null) throw dom("InvalidAccessError", "The cursor's source is not an index.");
      if (C.direction === 1 || C.direction === 3) throw dom("InvalidAccessError", "The cursor's direction is a unique one.");
      if (!C.gotValue) throw dom("InvalidStateError", "The cursor is being iterated or has iterated past its end.");
      const k = keyOf(key);
      if (k === null) throw dom("DataError", "The parameter is not a valid key.");
      const pk = keyOf(primaryKey);   // (the first key is checked before the second is read)
      if (pk === null) throw dom("DataError", "The parameter is not a valid key.");
      const c = compareBytes(k, C.key);
      const fwd = C.direction < 2;
      if ((fwd && (c < 0 || (c === 0 && compareBytes(pk, C.pk) <= 0))) || (!fwd && (c > 0 || (c === 0 && compareBytes(pk, C.pk) >= 0)))) {
        throw dom("DataError", "The parameters are less than or equal to this cursor's position.");
      }
      step(C, T, k, pk, 1);
    }
    update(value) {
      const C = sOf(cursorState, this);
      arity(1, arguments.length, "update", "IDBCursor");
      const T = C.R.tx;
      if (T.state !== "active") throw dom("TransactionInactiveError", "The transaction is not active.");
      if (T.mode === "readonly") throw dom("ReadOnlyError", "The transaction is read-only.");
      if (C.srcDeleted()) throw dom("InvalidStateError", "The cursor's source has been deleted.");
      if (!C.gotValue || C.keyOnly) throw dom("InvalidStateError", "The cursor is being iterated, past its end, or a key cursor.");
      const bytes = cloneValue(T, value);
      const S = C.store;
      const kp = S.meta.keyPath;
      const evalValue = (typeof value === "object" && value !== null && (kp !== null || S.meta.indexes.length > 0)) ? deserialize(bytes) : value;
      if (kp !== null) {
        const k = pathKey(evalValue, kp);
        if (k === null || k === undefined || compareBytes(k, C.pk) !== 0) throw dom("DataError", "The effective key of the value differs from the cursor's primary key.");
      }
      const R = newRequest(IDBRequest.prototype, this, T);
      etState.set(R.wrapper, { listeners: [], handlers: Object.create(null) });
      const snapshot = snapIndexKeys(S, evalValue);
      const pk = C.pk;
      enqueue(T, R, () => {
        const w = reqWriter(T, REQ.PUT, S.meta.id);
        w.u8(2); w.bytes(pk); w.bytes(bytes);
        const ik = new Wr();
        writeIndexKeys(ik, S, snapshot, bytes);
        w.raw(ik.done());
        return decodeKey(expectOk(call(OP.EXEC, w.done())).bytes());
      });
      return R.wrapper;
    }
    delete() {
      const C = sOf(cursorState, this);
      const T = C.R.tx;
      if (T.state !== "active") throw dom("TransactionInactiveError", "The transaction is not active.");
      if (T.mode === "readonly") throw dom("ReadOnlyError", "The transaction is read-only.");
      if (C.srcDeleted()) throw dom("InvalidStateError", "The cursor's source has been deleted.");
      if (!C.gotValue || C.keyOnly) throw dom("InvalidStateError", "The cursor is being iterated, past its end, or a key cursor.");
      const R = newRequest(IDBRequest.prototype, this, T);
      etState.set(R.wrapper, { listeners: [], handlers: Object.create(null) });
      const pk = C.pk;
      enqueue(T, R, () => {
        const w = reqWriter(T, REQ.DELETE, C.store.meta.id);
        putRange(w, { lower: pk, upper: pk, lowerOpen: false, upperOpen: false });
        expectOk(call(OP.EXEC, w.done()));
        return undefined;
      });
      return R.wrapper;
    }
  }
  class IDBCursorWithValue extends IDBCursor {
    get value() { return sOf(cursorState, this).value; }
  }

  function cursorReady(C) {
    const T = C.R.tx;
    if (T.state !== "active") throw dom("TransactionInactiveError", "The transaction is not active.");
    if (C.srcDeleted()) throw dom("InvalidStateError", "The cursor's source has been deleted.");
    if (!C.gotValue) throw dom("InvalidStateError", "The cursor is being iterated or has iterated past its end.");
    return T;
  }

  // Asks for the next record of a cursor again through its own request.
  function step(C, T, target, targetPk, count) {
    C.gotValue = false;
    const R = C.R;
    R.readyState = "pending";
    R.result = undefined;
    enqueue(T, R, () => cursorExec(C, T, R, target, targetPk, count));
  }

  function cursorExec(C, T, R, target, targetPk, count) {
    const w = reqWriter(T, REQ.CURSOR, C.store.meta.id);
    w.uv(C.index === null ? 0 : C.index.id);
    putRange(w, C.range);
    w.u8(C.direction);
    if (C.key === null) { w.u8(0); w.bytes(new Uint8Array(0)); w.bytes(new Uint8Array(0)); }
    else { w.u8(1); w.bytes(C.key); w.bytes(C.pk); }
    if (target !== null) { w.u8(1); w.bytes(target); } else { w.u8(0); w.bytes(new Uint8Array(0)); }
    if (targetPk !== null) { w.u8(1); w.bytes(targetPk); } else { w.u8(0); w.bytes(new Uint8Array(0)); }
    w.uv(count);
    w.u8(C.keyOnly ? 1 : 0);
    const rd = expectOk(call(OP.EXEC, w.done()));
    if (!rd.u8()) {
      C.key = null; C.pk = null; C.kv = C.pv = NOCACHE; C.value = undefined; C.gotValue = false;
      return null;
    }
    C.key = rd.bytes().slice();
    C.pk = rd.bytes().slice();
    C.kv = C.pv = NOCACHE;
    C.value = C.keyOnly ? undefined : valueOf(rd);
    C.gotValue = true;
    return C.wrapper;
  }

  function openCursor(S, src, T, srcWrapper, query, direction, keyOnly) {
    const range = rangeArg(query, true);
    const dir = DIRECTIONS.indexOf(checkEnum(direction, DIRECTIONS, "IDBCursorDirection"));
    const R = newRequest(IDBRequest.prototype, srcWrapper, T);
    etState.set(R.wrapper, { listeners: [], handlers: Object.create(null) });
    const w = Object.create(keyOnly ? IDBCursor.prototype : IDBCursorWithValue.prototype);
    const index = src.index || null;
    const C = {
      R, range, direction: dir, keyOnly, key: null, pk: null, kv: NOCACHE, pv: NOCACHE, value: undefined, gotValue: false, store: S, index,
      sourceWrapper: srcWrapper, wrapper: w,
      srcDeleted() { return S.meta.deleted || (index !== null && index.deleted); },
    };
    cursorState.set(w, C);
    enqueue(T, R, () => cursorExec(C, T, R, null, null, 1));
    return R.wrapper;
  }

  // ---- the browser's events ---------------------------------------------------------------------------------------
  function snapshotMeta(c) {
    return c.stores.map((s) => ({ meta: s, name: s.name, indexes: s.indexes.slice(), names: s.indexes.map((i) => i.name) }));
  }
  function restoreMeta(T) {
    const c = T.conn;
    const b = T.backup;
    if (b === null) return;
    const keep = new Set(b.map((x) => x.meta));
    for (const s of c.stores) { if (!keep.has(s)) { s.deleted = true; for (const ix of s.indexes) ix.deleted = true; } }
    c.stores = b.map((x) => x.meta);
    for (const x of b) {
      x.meta.name = x.name;
      x.meta.deleted = false;
      for (const ix of x.meta.indexes) { if (!x.indexes.includes(ix)) ix.deleted = true; }
      x.meta.indexes = x.indexes.slice();
      x.meta.hostIndexes = x.indexes.filter((ix) => ix.ready);
      x.meta.indexes.forEach((ix, i) => { ix.name = x.names[i]; ix.deleted = false; });
    }
    updateNames(c);
  }

  function openError(req, code) {
    req.readyState = "done";
    req.result = undefined;
    req.error = fail(code);
    req.tx = null;
    dispatch(req.wrapper, plainEvent("error", true, true));
  }

  function onEvent() {
    inHostEvent = true;
    try { onEventInner(); } finally { inHostEvent = false; }
  }
  function onEventInner() {
    const rep = call(OP.EVENT);
    const rd = new Rd(rep, 1);
    const kind = rd.u8();
    const id = rd.uv(), conn = rd.uv(), txId = rd.uv(), v1 = rd.uv(), v2 = rd.uv(), a = rd.uv(), err = rd.u8();
    const data = rd.bytes();
    switch (kind) {
      case EV.TASK: {
        const fn = tasks.get(a);
        tasks.delete(a);
        if (fn !== undefined) fn();
        break;
      }
      case EV.OPEN_UPGRADE: {
        const req = openReqs.get(id);
        if (req === undefined) break;
        const meta = readMeta(new Rd(data, 0));
        const c = newConnection(conn, req.name || "", meta);
        const old = v1;
        c.version = v2;
        const T = newTransaction(c, txId, "versionchange", [], "default");
        T.started = true;
        T.upgradeReq = req;
        T.oldVersion = old;
        T.backup = snapshotMeta(c);
        c.upgradeTx = T;
        // the transaction's metadata is the connection's live one (stores created here are added to it)
        req.readyState = "done"; req.result = c.wrapper; req.error = null; req.tx = T;
        req.conn = c;
        const out = dispatch(req.wrapper, versionEvent("upgradeneeded", old, v2));
        if (out.threw && !T.dead) abortTransaction(T, dom("AbortError", "An exception was thrown by an upgradeneeded handler."), E_ABORTED, true);
        break;
      }
      case EV.OPEN_DONE: {
        const req = openReqs.get(id);
        if (req === undefined) break;
        openReqs.delete(id);
        if (req.conn === undefined) {
          const meta = readMeta(new Rd(data, 0));
          req.conn = newConnection(conn, "", meta);
        }
        req.readyState = "done"; req.result = req.conn.wrapper; req.error = null; req.tx = null;
        req.conn.version = v1;
        const out = dispatch(req.wrapper, plainEvent("success", false, false));
        if (out.threw) req.conn.wrapper.close();
        break;
      }
      case EV.OPEN_ERROR: {
        const req = openReqs.get(id);
        if (req === undefined) break;
        openReqs.delete(id);
        if (req.conn !== undefined) { req.conn.closed = true; req.conn.closePending = true; conns.delete(req.conn.id); }
        openError(req, err);
        break;
      }
      case EV.BLOCKED: {
        const req = openReqs.get(id);
        if (req === undefined) break;
        dispatch(req.wrapper, versionEvent("blocked", v1, req.isDelete ? null : v2));
        break;
      }
      case EV.VERSION_CHANGE: {
        const c = conns.get(conn);
        if (c === undefined) break;
        dispatch(c.wrapper, versionEvent("versionchange", v1, v2 === 0 ? null : v2));
        // the handlers have run: the answer goes when the microtasks they queued (a promise that closes the connection) are done
        vcDone.push(conn);
        if (!cleanupArmed) { cleanupArmed = true; call(OP.CLEANUP); }
        break;
      }
      case EV.DELETE_DONE: {
        const req = openReqs.get(id);
        if (req === undefined) break;
        openReqs.delete(id);
        req.readyState = "done"; req.result = undefined; req.error = null;
        dispatch(req.wrapper, versionEvent("success", v1, null));
        break;
      }
      case EV.DELETE_ERROR: {
        const req = openReqs.get(id);
        if (req === undefined) break;
        openReqs.delete(id);
        openError(req, err);
        break;
      }
      case EV.TX_STARTED: {
        const T = txs.get(txId);
        if (T === undefined || T.dead) break;
        if (T.startedEarly) { T.startedEarly = false; break; }
        T.started = true;
        processNext(T);
        if (T.queue.length === 0) maybeCommit(T);
        break;
      }
      case EV.TX_COMPLETE: {
        const T = txs.get(txId);
        if (T === undefined || T.dead) break;
        T.state = "finished";
        T.dead = true;
        activeSet.delete(T);
        txs.delete(T.id);
        T.conn.txCount--;
        if (T.conn.upgradeTx === T) T.conn.upgradeTx = null;
        dispatch(T.wrapper, plainEvent("complete", false, false));
        if (T.upgradeReq !== null) T.upgradeReq.tx = null;
        if (T.conn.upgradeTx === T) T.conn.upgradeTx = null;
        break;
      }
      case EV.TX_ABORTED: {
        const T = txs.get(txId);
        if (T === undefined || T.dead) break;   // a transaction this side aborted: already handled
        abortTransaction(T, fail(err, "The transaction was aborted by the browser."), err, false);
        break;
      }
      case EV.CONN_CLOSED: {
        const c = conns.get(conn);
        if (c === undefined) break;
        c.closed = true; c.closePending = true;
        conns.delete(conn);
        dispatch(c.wrapper, plainEvent("close", false, false));
        break;
      }
      case EV.LIST: {
        const w = listReqs.get(id);
        if (w === undefined) break;
        listReqs.delete(id);
        const lrd = new Rd(data, 0);
        const n = lrd.uv();
        const out = [];
        for (let i = 0; i < n; i++) out.push({ name: lrd.str(), version: lrd.uv() });
        w.resolve(out);
        break;
      }
    }
  }

  // ---- navigator.storage, navigator.storageBuckets -----------------------------------------------------------------
  const smState = new WeakMap(), sbmState = new WeakMap(), sbState = new WeakMap();
  function bucketCall(op, build) {
    const w = new Wr();
    build(w);
    const rep = call(op, w.done());
    if (rep[0]) throw fail(rep[0]);
    return new Rd(rep, 1);
  }
  function estimateOf(bucket) {
    const rd = bucketCall(OP.ESTIMATE, (w) => w.str(bucket));
    return { usage: rd.uv(), quota: rd.uv() };
  }
  function persistOf(bucket, request) {
    return bucketCall(OP.PERSIST, (w) => { w.str(bucket); w.u8(request ? 1 : 0); }).u8() !== 0;
  }
  const notSupported = (what) => Promise.reject(dom("NotSupportedError", what + " is not supported."));

  class StorageManager {
    constructor() { throw new TypeError("Illegal constructor"); }
    estimate() { try { sOf(smState, this); return Promise.resolve(estimateOf("")); } catch (e) { return Promise.reject(e); } }
    persist() { try { sOf(smState, this); return Promise.resolve(persistOf("", true)); } catch (e) { return Promise.reject(e); } }
    persisted() { try { sOf(smState, this); return Promise.resolve(persistOf("", false)); } catch (e) { return Promise.reject(e); } }
    getDirectory() { return notSupported("The origin private file system"); }
  }

  const BUCKET_NAME = /^[a-z0-9][a-z0-9_-]{0,62}$/;
  function makeBucket(name, info) {
    const b = Object.create(StorageBucket.prototype);
    const factory = Object.create(IDBFactory.prototype);
    factoryState.set(factory, { bucket: name });
    sbState.set(b, { name, persisted: info.persisted, durability: info.durability, expires: info.expires, factory });
    return b;
  }
  class StorageBucketManager {
    constructor() { throw new TypeError("Illegal constructor"); }
    open(name, options = undefined) {
      try {
        sOf(sbmState, this);
        arity(1, arguments.length, "open", "StorageBucketManager");
        const n = str(name);
        if (!BUCKET_NAME.test(n)) throw new TypeError("Failed to execute 'open' on 'StorageBucketManager': The bucket name is not valid.");
        let persisted = false, durability = "", expires = -1;
        if (options !== undefined && options !== null) {
          if (typeof options !== "object" && typeof options !== "function") throw new TypeError("The options argument is not of type 'StorageBucketOptions'.");
          persisted = !!options.persisted;
          if (options.durability !== undefined) durability = checkEnum(options.durability, ["strict", "relaxed"], "StorageBucketDurability");
          if (options.expires !== undefined && options.expires !== null) expires = Number(options.expires);
        }
        const rd = bucketCall(OP.BUCKETS, (w) => { w.u8(0); w.str(n); w.u8(persisted ? 1 : 0); w.str(durability); w.f64(expires); });
        const info = { persisted: rd.u8() !== 0, durability: rd.str(), expires: rd.f64() };
        return Promise.resolve(makeBucket(n, info));
      } catch (e) { return Promise.reject(e); }
    }
    keys() {
      try {
        sOf(sbmState, this);
        const rd = bucketCall(OP.BUCKETS, (w) => w.u8(1));
        const n = rd.uv(), out = [];
        for (let i = 0; i < n; i++) { const name = rd.str(); if (name !== "default") out.push(name); }
        return Promise.resolve(out);
      } catch (e) { return Promise.reject(e); }
    }
    delete(name) {
      try {
        sOf(sbmState, this);
        arity(1, arguments.length, "delete", "StorageBucketManager");
        const n = str(name);
        if (!BUCKET_NAME.test(n)) throw new TypeError("Failed to execute 'delete' on 'StorageBucketManager': The bucket name is not valid.");
        bucketCall(OP.BUCKETS, (w) => { w.u8(2); w.str(n); });
        return Promise.resolve(undefined);
      } catch (e) { return Promise.reject(e); }
    }
  }

  class StorageBucket {
    constructor() { throw new TypeError("Illegal constructor"); }
    get name() { return sOf(sbState, this).name; }
    get indexedDB() { return sOf(sbState, this).factory; }
    persist() { try { const B = sOf(sbState, this); B.persisted = persistOf(B.name, true); return Promise.resolve(B.persisted); } catch (e) { return Promise.reject(e); } }
    persisted() { try { const B = sOf(sbState, this); return Promise.resolve(persistOf(B.name, false)); } catch (e) { return Promise.reject(e); } }
    estimate() { try { const B = sOf(sbState, this); return Promise.resolve(estimateOf(B.name)); } catch (e) { return Promise.reject(e); } }
    durability() { try { return Promise.resolve(sOf(sbState, this).durability); } catch (e) { return Promise.reject(e); } }
    setExpires(expires) {
      try {
        const B = sOf(sbState, this);
        const ms = Number(expires);
        B.expires = ms;
        bucketCall(OP.BUCKETS, (w) => { w.u8(3); w.str(B.name); w.f64(ms); });
        return Promise.resolve(undefined);
      } catch (e) { return Promise.reject(e); }
    }
    expires() { try { const B = sOf(sbState, this); return Promise.resolve(B.expires < 0 ? null : B.expires); } catch (e) { return Promise.reject(e); } }
    getDirectory() { return notSupported("The origin private file system"); }
  }
  // ---- the global ---------------------------------------------------------------------------------------------------
  const factory = Object.create(IDBFactory.prototype);
  factoryState.set(factory, { bucket: "" });

  // The interfaces' operations and attributes are enumerable, like Web IDL's.
  function exposeMembers(cls) {
    for (const holder of [cls.prototype, cls]) {
      for (const key of Reflect.ownKeys(holder)) {
        if (typeof key !== "string" || key === "constructor" || key === "prototype") continue;
        if (holder === cls && (key === "length" || key === "name")) continue;
        const d = Object.getOwnPropertyDescriptor(holder, key);
        if (d.configurable) { d.enumerable = true; Object.defineProperty(holder, key, d); }
      }
    }
    Object.defineProperty(cls.prototype, Symbol.toStringTag, { value: cls.name, configurable: true });
  }

  const all = [IDBRequest, IDBOpenDBRequest, IDBFactory, IDBDatabase, IDBTransaction, IDBObjectStore, IDBIndex, IDBCursor, IDBCursorWithValue,
    IDBKeyRange, IDBVersionChangeEvent, IDBRecord, DOMStringList, StorageManager, StorageBucketManager, StorageBucket];
  const classes = {};
  for (const cls of all) {
    exposeMembers(cls);
    if (cls !== DOMStringList) classes[cls.name] = cls;   // (the realm's own DOMStringList stays the global one: see start)
  }

  // The realm's interfaces exist (the prelude runs at the first use): ours are linked to them.
  function start() {
    // the lists of names are DOMStringLists of this realm (instanceof), with their own methods
    if (typeof globalThis.DOMStringList === "function") Object.setPrototypeOf(DOMStringList.prototype, globalThis.DOMStringList.prototype);
    NativeEvent = Event;
    DOMEx = DOMException;
    // the roots of our event targets inherit from EventTarget itself, with their own addEventListener, removeEventListener and
    // dispatchEvent (the inherited ones need a native receiver)
    for (const root of [IDBRequest, IDBDatabase, IDBTransaction]) {
      for (const name of ["addEventListener", "removeEventListener", "dispatchEvent"]) {
        const d = Object.getOwnPropertyDescriptor(IDBEventTarget.prototype, name);
        d.enumerable = true;
        Object.defineProperty(root.prototype, name, d);
      }
      Object.setPrototypeOf(root.prototype, EventTarget.prototype);
      Object.setPrototypeOf(root, EventTarget);
    }
    Object.setPrototypeOf(IDBVersionChangeEvent.prototype, Event.prototype);
    Object.setPrototypeOf(IDBVersionChangeEvent, Event);
    Object.setPrototypeOf(IDBPlainEvent.prototype, Event.prototype);
    Object.defineProperty(IDBPlainEvent.prototype, "constructor", { value: Event, writable: true, configurable: true });
  }

  const storage = Object.create(StorageManager.prototype);
  smState.set(storage, true);
  const buckets = Object.create(StorageBucketManager.prototype);
  sbmState.set(buckets, true);
  return { classes, factory, storage, buckets, hooks: { event: onEvent, cleanup }, start };
})
