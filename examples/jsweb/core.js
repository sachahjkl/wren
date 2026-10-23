// DOMException, atob / btoa, TextEncoder / TextDecoder, structuredClone.

test("DOMException", () => {
  const e = new DOMException("msg", "AbortError");
  eq(e.name, "AbortError", "DOMException name");
  eq(e.message, "msg", "DOMException message");
  eq(e.code, 20, "DOMException legacy code");
  ok(e instanceof DOMException && e instanceof Error, "DOMException inherits from Error");
  eq(Object.prototype.toString.call(e), "[object DOMException]", "DOMException toStringTag");
  eq(String(e), "AbortError: msg", "Error.prototype.toString on a DOMException");
  eq(new DOMException().name, "Error", "default name");
  eq(new DOMException("x", "Custom").code, 0, "code of an unknown name");
  eq(DOMException.ABORT_ERR, 20, "constant on the interface");
  eq(typeof e.stack, "string", "stack");
  throws(() => DOMException("x"), "TypeError", "DOMException needs new");
});

test("atob / btoa", () => {
  eq(btoa("hello"), "aGVsbG8=", "btoa");
  eq(btoa(""), "", "btoa empty");
  eq(btoa("\u00ff\u00fe"), "//4=", "btoa Latin-1");
  eq(atob("aGVsbG8="), "hello", "atob");
  eq(atob(" aGVs bG8 "), "hello", "atob ignores ASCII white space");
  eq(atob("aGVsbG8"), "hello", "atob without padding");
  eq(atob("//4=").charCodeAt(0), 255, "atob gives a binary string");
  throws(() => btoa("\u0100"), "InvalidCharacterError", "btoa outside Latin-1");
  throws(() => atob("a"), "InvalidCharacterError", "atob of a bad length");
  throws(() => atob("ab!d"), "InvalidCharacterError", "atob of a bad character");
  throws(() => atob("ab=d"), "InvalidCharacterError", "atob of misplaced padding");
});

test("TextEncoder", () => {
  const enc = new TextEncoder();
  eq(enc.encoding, "utf-8", "encoding");
  const b = enc.encode("h\u00e9\ud83d\ude00");
  ok(b instanceof Uint8Array, "encode gives a Uint8Array");
  eq(Array.from(b).join(","), "104,195,169,240,159,152,128", "UTF-8 bytes");
  eq(Array.from(enc.encode("\ud800x")).join(","), "239,191,189,120", "a lone surrogate becomes U+FFFD");
  eq(enc.encode().length, 0, "encode() is empty");
  const dst = new Uint8Array(4);
  const r = enc.encodeInto("a\u00e9\u20ac", dst);
  eq(r.read, 2, "encodeInto read (whole characters only)");
  eq(r.written, 3, "encodeInto written");
  eq(Array.from(dst).join(","), "97,195,169,0", "encodeInto bytes");
  const r2 = enc.encodeInto("\ud83d\ude00", new Uint8Array(8));
  eq(r2.read, 2, "encodeInto counts a surrogate pair as 2");
  throws(() => enc.encodeInto("a", new Uint16Array(2)), "TypeError", "encodeInto needs a Uint8Array");
});

test("TextDecoder", () => {
  const d = new TextDecoder();
  eq(d.encoding, "utf-8", "default encoding");
  eq(d.fatal, false, "fatal default");
  eq(d.ignoreBOM, false, "ignoreBOM default");
  eq(d.decode(new Uint8Array([0xEF, 0xBB, 0xBF, 0x68, 0xC3, 0xA9])), "h\u00e9", "decode strips the BOM");
  eq(d.decode(new Uint8Array([0x61, 0xFF, 0x62]).buffer), "a\ufffdb", "replacement of invalid bytes (ArrayBuffer input)");
  eq(d.decode(new DataView(new Uint8Array([0x41, 0x42, 0x43]).buffer, 1, 2)), "BC", "a DataView input");
  eq(d.decode(), "", "decode() is empty");
  const s = new TextDecoder("utf-8");
  const euro = [0xE2, 0x82, 0xAC];
  eq(s.decode(new Uint8Array(euro.slice(0, 2)), { stream: true }) + s.decode(new Uint8Array(euro.slice(2))), "\u20ac", "streaming across chunks");
  const f = new TextDecoder("utf-8", { fatal: true });
  eq(f.fatal, true, "fatal option");
  throws(() => f.decode(new Uint8Array([0xFF])), "TypeError", "fatal mode throws");
  eq(new TextDecoder("latin1").encoding, "windows-1252", "a label maps to its encoding");
  eq(new TextDecoder(" UTF8 ").encoding, "utf-8", "labels are trimmed, case-insensitive");
  eq(new TextDecoder("windows-1252").decode(new Uint8Array([0x80, 0xE9])), "\u20ac\u00e9", "windows-1252");
  eq(new TextDecoder("shift_jis").decode(new Uint8Array([0x82, 0xA0])), "\u3042", "Shift_JIS");
  throws(() => new TextDecoder("nope"), "RangeError", "unknown label");
  throws(() => new TextDecoder(""), "RangeError", "empty label");
  eq(new TextDecoder("utf-16le").decode(new Uint8Array([0x41, 0, 0x42, 0])), "AB", "UTF-16LE");
});

test("structuredClone", () => {
  const o = { a: 1, d: new Date(5), m: new Map([[1, "x"]]), s: new Set([2]), r: /x/g, u8: new Uint8Array([1, 2]) };
  o.self = o;
  const c = structuredClone(o);
  ok(c !== o && c.a === 1, "a copy");
  ok(c.self === c, "cycles are kept");
  ok(c.d instanceof Date && c.d.getTime() === 5, "Date");
  ok(c.m instanceof Map && c.m.get(1) === "x", "Map");
  ok(c.s instanceof Set && c.s.has(2), "Set");
  ok(c.r instanceof RegExp && c.r.source === "x" && c.r.flags === "g", "RegExp");
  ok(c.u8 instanceof Uint8Array && c.u8[1] === 2, "typed arrays");
  throws(() => structuredClone(() => 1), "DataCloneError", "a function cannot be cloned");
  const ab = new ArrayBuffer(8);
  const moved = structuredClone(ab, { transfer: [ab] });
  eq(moved.byteLength, 8, "transferred buffer arrives");
  eq(ab.byteLength, 0, "transferred buffer is detached");
  throws(() => structuredClone(1, { transfer: [ab, ab] }), "DataCloneError", "a buffer twice in the transfer list");
});

test("performance.timing and performance.navigation (legacy)", () => {
  const t = performance.timing;
  ok(t instanceof PerformanceTiming, "a PerformanceTiming");
  ok(t === performance.timing, "the same object each time");
  eq(t.navigationStart, Math.floor(performance.timeOrigin), "navigationStart is the time origin");
  ok(t.responseStart >= t.navigationStart && t.responseEnd >= t.responseStart, "the network steps in order");
  ok(t.domComplete >= t.domInteractive && t.loadEventEnd >= t.loadEventStart, "the document steps in order");
  eq(t.unloadEventStart, 0, "no unload event");
  eq(t.redirectStart, 0, "no redirect");
  const n = performance.navigation;
  ok(n instanceof PerformanceNavigation && n === performance.navigation, "a PerformanceNavigation, the same each time");
  eq(n.type, 0, "TYPE_NAVIGATE");
  eq(n.redirectCount, 0, "no redirect");
});

__run();
