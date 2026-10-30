// The WebAssembly JavaScript API (native/js/odin/web_wasm.js), with javascript.webassembly.enabled on.
"use strict";

const str = s => { const b = [...new TextEncoder().encode(s)]; return [b.length, ...b]; };
const leb = n => (n < 128 ? [n] : [(n & 127) | 128, ...leb(n >> 7)]);
const sec = (id, body) => [id, ...leb(body.length), ...body];
const HEADER = [0, 97, 115, 109, 1, 0, 0, 0];
// imports a function, a table, a memory and a global; exports a function and the memory (a name to escape in JSON);
// three custom sections, two of them "meta"
const MODULE = new Uint8Array([...HEADER,
  ...sec(0, [...str("meta"), 1, 2, 3]),
  ...sec(1, [1, 0x60, 0, 0]),
  ...sec(2, [4,
    ...str("env"), ...str("f"), 0, 0,
    ...str("env"), ...str("t"), 1, 0x70, 0, 1,
    ...str("env"), ...str("m"), 2, 0, 1,
    ...str("env"), ...str("g"), 3, 0x7f, 0]),
  ...sec(3, [1, 0]),
  ...sec(7, [2, ...str("run"), 0, 1, ...str("hé\"\n"), 2, 0]),
  ...sec(10, [1, 2, 0, 0x0b]),
  ...sec(0, [...str("meta"), 4]),
  ...sec(0, [...str("empty")]),
]);
const BAD = new Uint8Array([0, 97, 115, 109, 9, 9, 9, 9]);

// A module to run. Types: 0 (i32)->i32, 1 ()->(), 2 (i32,i32)->i32, 3 (i64)->i64, 4 (f64)->f64, 5 ()->(i32,i32), 6 ()->i32,
// 7 (externref)->externref, 8 (i32)->(i32,i32)
const I32 = 0x7f, I64 = 0x7e, F64 = 0x7c, EXT = 0x6f;
const fn = (...code) => { const b = [0, ...code, 0x0b]; return [b.length, ...b]; };
const EXPORTS = ["add", "callimp", "load", "store", "wide", "fl", "trap", "grow", "pair", "gval", "echo", "pairimp"];
const RUN = new Uint8Array([...HEADER,
  ...sec(1, [9,
    0x60, 1, I32, 1, I32, 0x60, 0, 0, 0x60, 2, I32, I32, 1, I32, 0x60, 1, I64, 1, I64, 0x60, 1, F64, 1, F64,
    0x60, 0, 2, I32, I32, 0x60, 0, 1, I32, 0x60, 1, EXT, 1, EXT, 0x60, 1, I32, 2, I32, I32]),
  ...sec(2, [5,
    ...str("env"), ...str("add1"), 0, 0,
    ...str("env"), ...str("mem"), 2, 0, 1,
    ...str("env"), ...str("tbl"), 1, 0x70, 0, 2,
    ...str("env"), ...str("g"), 3, I32, 0,
    ...str("env"), ...str("two"), 0, 8]),
  ...sec(3, [12, 2, 0, 0, 2, 3, 4, 1, 0, 5, 6, 7, 0]),
  ...sec(7, [EXPORTS.length + 3,
    ...EXPORTS.flatMap((n, i) => [...str(n), 0, i + 2]),
    ...str("mem"), 2, 0,
    ...str("tbl"), 1, 0,
    ...str("g"), 3, 0]),
  ...sec(9, [1, 0, 0x41, 0, 0x0b, 1, 2]),
  ...sec(10, [12,
    ...fn(0x20, 0, 0x20, 1, 0x6a),                                          // add
    ...fn(0x20, 0, 0x10, 0),                                                // callimp
    ...fn(0x20, 0, 0x2d, 0, 0),                                             // load: i32.load8_u
    ...fn(0x20, 0, 0x20, 1, 0x3a, 0, 0, 0x20, 1),                           // store: i32.store8
    ...fn(0x20, 0, 0x42, 1, 0x7c),                                          // wide: + 1n
    ...fn(0x20, 0),                                                         // fl
    ...fn(0x00),                                                            // trap: unreachable
    ...fn(0x20, 0, 0x40, 0),                                                // grow
    ...fn(0x41, 1, 0x41, 2),                                                // pair
    ...fn(0x23, 0),                                                         // gval
    ...fn(0x20, 0),                                                         // echo
    ...fn(0x20, 0, 0x10, 1, 0x6a),                                          // pairimp: the sum of what the import returns
  ]),
]);

const instantiate = (over = {}) => {
  const memory = new WebAssembly.Memory({ initial: 1, maximum: 4 });
  const table = new WebAssembly.Table({ element: "anyfunc", initial: 2 });
  const env = { add1: x => x + 1, mem: memory, tbl: table, g: 42, two: x => [x, x * 2], ...over };
  return { memory, table, env, exports: new WebAssembly.Instance(new WebAssembly.Module(RUN), { env }).exports };
};

test("the namespace", () => {
  eq(String(WebAssembly), "[object WebAssembly]", "toString");
  const d = Object.getOwnPropertyDescriptor(globalThis, "WebAssembly");
  ok(d.writable && !d.enumerable && d.configurable, "the global's attributes");
  eq(Object.getOwnPropertyDescriptor(WebAssembly, "validate").enumerable, true, "operations are enumerable");
  eq(Object.getOwnPropertyDescriptor(WebAssembly, "Module").enumerable, false, "constructors are not");
  ok(!("prototype" in WebAssembly.compile), "compile is no constructor");
  ok(String(WebAssembly.Module).includes("[native code]"), "the objects read as native");
  eq(WebAssembly.compile.length, 1, "compile.length");
  eq(WebAssembly.Module.length, 1, "Module.length");
  for (const name of ["Instance", "Memory", "Table", "Global", "instantiate", "compileStreaming", "instantiateStreaming"]) {
    eq(typeof WebAssembly[name], "function", name);
  }
  eq(Object.getOwnPropertyDescriptor(WebAssembly.Memory.prototype, "grow").enumerable, true, "a method of an interface is enumerable");
  eq(Object.getOwnPropertyDescriptor(WebAssembly.Memory.prototype, "buffer").enumerable, true, "an attribute of an interface is enumerable");
});

test("validate", () => {
  eq(WebAssembly.validate(MODULE), true, "a module");
  eq(WebAssembly.validate(BAD), false, "not a module");
  throws(() => WebAssembly.validate(1), "TypeError", "not a buffer");
});

test("Module", () => {
  const m = new WebAssembly.Module(MODULE);
  eq(String(m), "[object WebAssembly.Module]", "toString");
  ok(m instanceof WebAssembly.Module, "instanceof");
  eq(new WebAssembly.Module(MODULE.buffer).constructor, WebAssembly.Module, "from an ArrayBuffer");
  throws(() => WebAssembly.Module(MODULE), "TypeError", "without new");
  throws(() => new WebAssembly.Module(), "TypeError", "no argument");
  throws(() => new WebAssembly.Module("x"), "TypeError", "not a buffer");
  throws(() => new WebAssembly.Module(BAD), "CompileError", "not a module");
  throws(() => new WebAssembly.Module(new Uint8Array(0)), "CompileError", "empty");
  class Sub extends WebAssembly.Module {}
  eq(WebAssembly.Module.exports(new Sub(MODULE)).length, 2, "a subclass");
});

test("the description", () => {
  const m = new WebAssembly.Module(MODULE);
  eq(JSON.stringify(WebAssembly.Module.imports(m)), JSON.stringify([
    { module: "env", name: "f", kind: "function" }, { module: "env", name: "t", kind: "table" },
    { module: "env", name: "m", kind: "memory" }, { module: "env", name: "g", kind: "global" },
  ]), "imports");
  eq(JSON.stringify(WebAssembly.Module.exports(m)), JSON.stringify([{ name: "run", kind: "function" }, { name: "hé\"\n", kind: "memory" }]), "exports");
  ok(WebAssembly.Module.imports(m) !== WebAssembly.Module.imports(m), "a new array each time");
  throws(() => WebAssembly.Module.imports({}), "TypeError", "imports of no module");
  throws(() => WebAssembly.Module.exports(1), "TypeError", "exports of no module");
  throws(() => WebAssembly.Module.customSections(m), "TypeError", "customSections without a name");
  const meta = WebAssembly.Module.customSections(m, "meta");
  eq(meta.length, 2, "two sections of a name");
  ok(meta[0] instanceof ArrayBuffer, "ArrayBuffers");
  eq(JSON.stringify([...new Uint8Array(meta[0])]), "[1,2,3]", "the first one's bytes");
  eq(JSON.stringify([...new Uint8Array(meta[1])]), "[4]", "the second one's bytes");
  eq(WebAssembly.Module.customSections(m, "empty")[0].byteLength, 0, "an empty section");
  eq(WebAssembly.Module.customSections(m, "none").length, 0, "no such section");
});

test("compile", async () => {
  let settled = false;
  const pending = WebAssembly.compile(MODULE);
  ok(pending instanceof Promise, "a promise");
  pending.then(() => { settled = true; });
  await Promise.resolve();
  await Promise.resolve();
  eq(settled, false, "not settled by the call's microtasks");
  const copy = new Uint8Array(MODULE);
  const kept = WebAssembly.compile(copy);
  copy.fill(0);
  ok(await kept instanceof WebAssembly.Module, "the bytes are copied at the call");
  const m = await pending;
  ok(m instanceof WebAssembly.Module, "a Module");
  eq(WebAssembly.Module.exports(m)[0].name, "run", "a working one");
  await rejects(WebAssembly.compile(BAD), "CompileError", "not a module");
  await rejects(WebAssembly.compile(1), "TypeError", "not a buffer");
});

test("the errors", () => {
  for (const name of ["CompileError", "LinkError", "RuntimeError"]) {
    const C = WebAssembly[name];
    const e = new C("boom");
    ok(e instanceof C && e instanceof Error, name + " is an Error");
    eq(e.name, name, name + ".name");
    eq(e.message, "boom", name + ".message");
    eq(Object.prototype.toString.call(e), "[object Error]", name + " is an error object");
    eq(C("x").constructor, C, name + " is callable without new");
    eq(Object.getPrototypeOf(C), Error, name + "'s constructor");
    eq(new C("x", { cause: 1 }).cause, 1, name + " takes options");
    eq(C.length, 1, name + ".length");
  }
  try { new WebAssembly.Module(BAD); } catch (e) { ok(e.message.startsWith("WebAssembly.Module(): "), "the message says who: " + e.message.slice(0, 80)); }
});

test("Memory: the object", () => {
  const m = new WebAssembly.Memory({ initial: 1, maximum: 3 });
  eq(String(m), "[object WebAssembly.Memory]", "toString");
  const b = m.buffer;
  ok(b instanceof ArrayBuffer, "an ArrayBuffer");
  eq(b.byteLength, 65536, "one page");
  eq(m.buffer, b, "the same buffer until it grows");
  eq(m.grow(1), 1, "grow returns the previous size");
  eq(b.byteLength, 0, "growing detaches the old buffer");
  ok(b.detached, "detached");
  eq(m.buffer.byteLength, 131072, "the new one is larger");
  const before = m.buffer;
  eq(m.grow(0), 2, "grow(0)");
  ok(m.buffer !== before, "grow(0) makes a new buffer too");
  throws(() => m.grow(5), "RangeError", "past the maximum");
  throws(() => new WebAssembly.Memory(), "TypeError", "no descriptor");
  throws(() => new WebAssembly.Memory({}), "TypeError", "no initial");
  throws(() => new WebAssembly.Memory({ initial: -1 }), "TypeError", "a negative initial");
  throws(() => new WebAssembly.Memory({ initial: 2, maximum: 1 }), "RangeError", "maximum below initial");
  throws(() => new WebAssembly.Memory({ initial: 70000 }), "RangeError", "initial past 65536");
  throws(() => WebAssembly.Memory.prototype.grow.call({}, 1), "TypeError", "grow of no memory");
  throws(() => m.buffer.transfer(), "TypeError", "the buffer cannot be transferred");
  throws(() => structuredClone(m.buffer, { transfer: [m.buffer] }), "DataCloneError", "nor be moved by a clone");
  eq(structuredClone(m.buffer).byteLength, m.buffer.byteLength, "it can be copied by a clone");
});

test("Memory: the bytes through JavaScript", () => {
  const m = new WebAssembly.Memory({ initial: 1 });
  const u8 = new Uint8Array(m.buffer);
  u8[0] = 7; u8[65535] = 9;
  eq(u8[0], 7, "an element");
  eq(u8[65535], 9, "the last one");
  eq(u8[65536], undefined, "past the end");
  const u32 = new Uint32Array(m.buffer, 8, 2);
  u32[1] = 0x01020304;
  eq(u32[1], 0x01020304, "a 32-bit element");
  eq(u8[12], 4, "little endian");
  const dv = new DataView(m.buffer);
  dv.setUint16(100, 0x1234, false);
  eq(dv.getUint16(100, false), 0x1234, "DataView");
  eq(u8[100], 0x12, "DataView, big endian");
  dv.setBigInt64(200, -2n, true);
  eq(dv.getBigInt64(200, true), -2n, "DataView, 64 bits");
  u8.set([1, 2, 3], 300);
  eq(u8[302], 3, "set from an array");
  u8.set(new Uint8Array([4, 5, 6]), 310);
  eq(u8[312], 6, "set from a Uint8Array");
  const out = new Uint8Array(3);
  out.set(u8.subarray(310, 313));
  eq(out[2], 6, "set from a view of the memory");
  u8.set(u8.subarray(310, 313), 311);
  eq(JSON.stringify([...u8.subarray(310, 314)]), "[4,4,5,6]", "set within the memory");
  eq(JSON.stringify([...u8.slice(310, 312)]), "[4,4]", "slice");
  ok(u8.slice(0, 1).buffer !== m.buffer, "a slice is a copy");
  eq(m.buffer.slice(310, 311).byteLength, 1, "ArrayBuffer slice");
  eq(new Uint8Array(m.buffer.slice(310, 311))[0], 4, "its bytes");
  u8.fill(0xAB, 400, 410);
  eq(u8[409], 0xAB, "fill");
  eq(u8[410], 0, "fill stops at its end");
  u8.copyWithin(500, 400, 402);
  eq(u8[501], 0xAB, "copyWithin");
  eq(u8.indexOf(0xAB, 400), 400, "indexOf");
  u8.subarray(600, 603).set([3, 1, 2]);
  u8.subarray(600, 603).sort();
  eq(JSON.stringify([...u8.subarray(600, 603)]), "[1,2,3]", "sort");
  u8.subarray(600, 603).reverse();
  eq(u8[600], 3, "reverse");
  eq(new Uint8Array(u8.subarray(600, 603))[0], 3, "a new array from a view");
  eq(u8.subarray(600, 601).toHex(), "03", "toHex");
  eq(Atomics.add(new Int32Array(m.buffer, 1000, 1), 0, 5), 0, "Atomics on it");
  eq(new Int32Array(m.buffer, 1000, 1)[0], 5, "Atomics wrote");
});

test("Memory: shared", () => {
  throws(() => new WebAssembly.Memory({ initial: 1, shared: true }), "TypeError", "shared needs a maximum");
  const m = new WebAssembly.Memory({ initial: 1, maximum: 3, shared: true });
  const b = m.buffer;
  eq(b.constructor.name, "SharedArrayBuffer", "its buffer is a SharedArrayBuffer");
  ok(Object.isFrozen(b), "frozen");
  eq(typeof SharedArrayBuffer, "undefined", "the global stays absent");
  const u8 = new Uint8Array(b);
  u8[5] = 9;
  eq(u8[5], 9, "its bytes");
  eq(new b.constructor(4).byteLength, 4, "its constructor makes others");
  eq(b.slice(5, 6).byteLength, 1, "slice");
  eq(new Uint8Array(b.slice(5, 6))[0], 9, "slice's bytes");
  const i32 = new Int32Array(b, 8, 1);
  eq(Atomics.add(i32, 0, 3), 0, "Atomics.add");
  eq(Atomics.load(i32, 0), 3, "Atomics.load");
  eq(Atomics.notify(i32, 0, 1), 0, "Atomics.notify: nobody waits");
  eq(Atomics.wait(i32, 0, 1), "not-equal", "Atomics.wait, another value");
  m.grow(1);
  eq(b.byteLength, 65536, "growing leaves the old buffer as it was");
  eq(m.buffer.byteLength, 131072, "the new one is larger");
  eq(new Uint8Array(m.buffer)[5], 9, "with the same bytes");
  eq(new TextDecoder().decode(u8.subarray(5, 5)), "", "a decoder takes a view of it");
});

test("Memory: the browser's APIs read and write it", async () => {
  const m = new WebAssembly.Memory({ initial: 2 });
  const u8 = new Uint8Array(m.buffer);
  const r = new TextEncoder().encodeInto("héllo", u8.subarray(70000, 70100));
  eq(r.written, 6, "encodeInto says how many");
  eq(u8[70000], 0x68, "encodeInto wrote");
  eq(new TextDecoder().decode(u8.subarray(70000, 70006)), "héllo", "TextDecoder reads");
  crypto.getRandomValues(u8.subarray(80000, 80032));
  ok(u8.subarray(80000, 80032).some(x => x !== 0), "getRandomValues wrote");
  eq(await new Blob([u8.subarray(70000, 70006)]).text(), "héllo", "a Blob copies");
  eq(btoa(String.fromCharCode(...u8.subarray(70000, 70001))), "aA==", "values from a spread");
});

test("Instance: calls", () => {
  const { exports: x, memory, table } = instantiate();
  eq(String(new WebAssembly.Instance(new WebAssembly.Module(new Uint8Array(HEADER)))), "[object WebAssembly.Instance]", "toString");
  ok(Object.isFrozen(x), "the exports are frozen");
  eq(Object.getPrototypeOf(x), null, "and have no prototype");
  eq(x.add(40, 2), 42, "a call");
  eq(x.add.length, 2, "its length");
  eq(x.add.name, "2", "its name is its index");
  ok(!("prototype" in x.add), "not a constructor");
  throws(() => new x.add(), "TypeError", "new fails");
  eq(x.add(0x7fffffff, 1), -2147483648, "i32 wraps");
  eq(x.add("3", 4.9), 7, "arguments are converted");
  eq(x.callimp(1), 2, "a call of an import");
  eq(x.wide(41n), 42n, "i64 is a BigInt");
  throws(() => x.wide(1), "TypeError", "a Number is no i64");
  eq(x.fl(1.5), 1.5, "f64");
  eq(JSON.stringify(x.pair()), "[1,2]", "several results are an array");
  eq(x.pairimp(5), 15, "an import returning several results");
  eq(x.gval(), 42, "a global imported as a number");
  eq(x.echo("anything"), "anything", "an externref");
  const o = {};
  eq(x.echo(o), o, "an externref keeps its identity");
  eq(x.echo(null), null, "a null externref");
  eq(x.echo(undefined), undefined, "undefined is an externref");
  eq(x.mem, memory, "an exported memory is the object imported");
  eq(x.tbl, table, "an exported table too");
  eq(x.add, x.add, "the same function each time");
  eq(table.get(0), x.add, "a table's function is the export");
  eq(table.get(0)(1, 2), 3, "and it can be called");
  eq(table.get(1), null, "an empty element");
});

test("Instance: memory shared with the module", () => {
  const { exports: x, memory } = instantiate();
  x.store(10, 200);
  eq(new Uint8Array(memory.buffer)[10], 200, "the module wrote, JavaScript reads");
  new Uint8Array(memory.buffer)[11] = 77;
  eq(x.load(11), 77, "JavaScript wrote, the module reads");
  const old = memory.buffer;
  eq(x.grow(1), 1, "the module grows the memory");
  eq(memory.buffer.byteLength, 131072, "the buffer follows");
  ok(old !== memory.buffer && old.byteLength === 0, "the old one is detached");
  x.store(70000, 5);
  eq(new Uint8Array(memory.buffer)[70000], 5, "the new pages");
  throws(() => x.load(1 << 30), "RuntimeError", "a load out of bounds traps");
  eq(new Uint8Array(memory.buffer)[10], 200, "and the memory is still there");
});

test("Instance: what JavaScript and the module see of each other's writes, at once", () => {
  let x;
  const seen = [];
  const { exports, memory } = instantiate({ add1: v => {
    // inside an import: what the module wrote before calling is seen; what is written here is seen by it after
    const h = new Uint8Array(memory.buffer);
    seen.push(h[100]);
    h[101] = v;
    return v;
  } });
  x = exports;
  const h = new Uint8Array(memory.buffer);
  for (let round = 1; round < 5; round++) {
    h[100] = 0;                      // into the cache
    eq(h[100], 0, "a write read back, round " + round);
    x.store(100, round);             // the module changes the page the script has read
    eq(h[100], round, "the module's write is seen, round " + round);
    h[100] = round + 10;             // and the script's, by the module
    eq(x.load(100), round + 10, "the script's write is seen, round " + round);
  }
  x.store(100, 55);
  eq(x.callimp(66), 66, "a call through an import");
  eq(seen[seen.length - 1], 55, "an import sees what the module wrote before");
  eq(x.load(101), 66, "the module sees what the import wrote, before it returns to JavaScript");
  // many pages, more than the cache keeps; elements on both sides of a page's end
  const big = new WebAssembly.Memory({ initial: 4 });
  const b = new Uint8Array(big.buffer), w = new Uint32Array(big.buffer);
  for (let i = 0; i < 200000; i += 1000) b[i] = i % 251;
  let bad = 0;
  for (let i = 0; i < 200000; i += 1000) if (b[i] !== i % 251) bad++;
  eq(bad, 0, "written and read over many pages");
  w[1023] = 0x01020304; w[1024] = 0x05060708;
  eq(w[1023], 0x01020304, "the last element of a page");
  eq(w[1024], 0x05060708, "the first of the next");
  eq(new Uint8Array(big.buffer.slice(4092, 4100)).join(), "4,3,2,1,8,7,6,5", "the same bytes for a copy, with writes not yet sent");
  b[9] = 3;
  eq(new DataView(big.buffer).getUint8(9), 3, "the same for a DataView");
  eq(new TextDecoder().decode(b.subarray(9, 9)), "", "and a call with the bytes");
  b[10] = 104;
  eq(new TextDecoder().decode(b.subarray(10, 11)), "h", "a call with the bytes sees the last write");
  const small = new WebAssembly.Memory({ initial: 1, maximum: 2 });
  new Uint8Array(small.buffer)[65535] = 8;
  small.grow(1);
  eq(new Uint8Array(small.buffer)[65535], 8, "a write not yet sent survives grow");
});

test("Instance: errors through calls", () => {
  const boom = new Error("boom");
  const { exports: x } = instantiate({ add1() { throw boom; } });
  try { x.callimp(1); ok(false, "an import that throws"); } catch (e) { eq(e, boom, "an import's exception comes through"); }
  throws(() => x.trap(), "RuntimeError", "a trap");
  try { x.trap(); } catch (e) { eq(e.message, "unreachable", "a trap's message"); }
  eq(x.add(1, 1), 2, "the instance still works after them");
  const deep = instantiate({ add1: v => (v > 50 ? v : deep.exports.callimp(v + 1)) });
  eq(deep.exports.callimp(0), 51, "JavaScript and the module calling each other, deep");
  const endless = instantiate({ add1: v => endless.exports.callimp(v) });
  throws(() => endless.exports.callimp(0), "RangeError", "without end, it stops with a RangeError");
});

test("Instance: linking", () => {
  const module = new WebAssembly.Module(RUN);
  const good = { add1: x => x, mem: new WebAssembly.Memory({ initial: 1 }), tbl: new WebAssembly.Table({ element: "anyfunc", initial: 2 }), g: 1, two: x => [x, x] };
  throws(() => new WebAssembly.Instance(), "TypeError", "no module");
  throws(() => new WebAssembly.Instance({}), "TypeError", "not a module");
  throws(() => new WebAssembly.Instance(module), "TypeError", "no imports");
  throws(() => new WebAssembly.Instance(module, 1), "TypeError", "imports of the wrong type");
  throws(() => new WebAssembly.Instance(module, {}), "TypeError", "no such module");
  throws(() => new WebAssembly.Instance(module, { env: { ...good, add1: 1 } }), "LinkError", "not a function");
  throws(() => new WebAssembly.Instance(module, { env: { ...good, mem: {} } }), "LinkError", "not a memory");
  throws(() => new WebAssembly.Instance(module, { env: { ...good, tbl: {} } }), "LinkError", "not a table");
  throws(() => new WebAssembly.Instance(module, { env: { ...good, g: "x" } }), "LinkError", "not a number");
  throws(() => new WebAssembly.Instance(module, { env: { ...good, mem: new WebAssembly.Memory({ initial: 0 }) } }), "LinkError", "a memory too small");
  throws(() => new WebAssembly.Instance(module, { env: { ...good, tbl: new WebAssembly.Table({ element: "anyfunc", initial: 1 }) } }), "LinkError", "a table too small");
  const other = new WebAssembly.Instance(module, { env: good }).exports;
  throws(() => new WebAssembly.Instance(module, { env: { ...good, add1: other.add } }), "LinkError", "an export of another signature");
  const linked = new WebAssembly.Instance(module, { env: { ...good, add1: other.callimp } }).exports;
  eq(linked.callimp(4), 4, "an export of the same signature, called directly");
  const g = new WebAssembly.Global({ value: "i32" }, 9);
  eq(new WebAssembly.Instance(module, { env: { ...good, g } }).exports.g, g, "an imported Global is the object");
});

test("Table", () => {
  const { exports: x } = instantiate();
  const t = new WebAssembly.Table({ element: "anyfunc", initial: 2, maximum: 4 });
  eq(String(t), "[object WebAssembly.Table]", "toString");
  eq(t.length, 2, "length");
  eq(t.get(0), null, "starts empty");
  t.set(0, x.add);
  eq(t.get(0), x.add, "set and get");
  t.set(0);
  eq(t.get(0), null, "set to nothing");
  throws(() => t.set(0, () => 1), "TypeError", "only exported functions");
  throws(() => t.get(2), "RangeError", "get out of range");
  throws(() => t.set(2, null), "RangeError", "set out of range");
  eq(t.grow(1), 2, "grow returns the previous length");
  eq(t.length, 3, "and it grew");
  eq(t.grow(1, x.add), 3, "grow with a value");
  eq(t.get(3), x.add, "the value");
  throws(() => t.grow(1), "RangeError", "past the maximum");
  const e = new WebAssembly.Table({ element: "externref", initial: 1 }, "start");
  eq(e.get(0), "start", "an externref table with a first value");
  e.set(0, 5);
  eq(e.get(0), 5, "any value");
  e.set(0);
  eq(e.get(0), undefined, "set to nothing is undefined");
  throws(() => new WebAssembly.Table({ element: "x", initial: 1 }), "TypeError", "a bad element");
  throws(() => new WebAssembly.Table({ element: "anyfunc" }), "TypeError", "no initial");
  throws(() => new WebAssembly.Table({ element: "anyfunc", initial: 2, maximum: 1 }), "RangeError", "maximum below initial");
});

test("Global", () => {
  const i = new WebAssembly.Global({ value: "i32", mutable: true }, 5);
  eq(String(i), "[object WebAssembly.Global]", "toString");
  eq(i.value, 5, "value");
  eq(i.valueOf(), 5, "valueOf");
  i.value = 6.9;
  eq(i.value, 6, "set, converted");
  const c = new WebAssembly.Global({ value: "i32" }, 1);
  throws(() => { c.value = 2; }, "TypeError", "an immutable one");
  eq(new WebAssembly.Global({ value: "i32" }).value, 0, "i32 by default");
  eq(new WebAssembly.Global({ value: "i64" }).value, 0n, "i64 by default");
  eq(new WebAssembly.Global({ value: "i64" }, 3n).value, 3n, "i64");
  throws(() => new WebAssembly.Global({ value: "i64" }, 3), "TypeError", "a Number is no i64");
  eq(new WebAssembly.Global({ value: "f32" }, 1.1).value, Math.fround(1.1), "f32");
  eq(new WebAssembly.Global({ value: "f64" }, 1.1).value, 1.1, "f64");
  eq(new WebAssembly.Global({ value: "externref" }).value, undefined, "externref by default");
  eq(new WebAssembly.Global({ value: "externref" }, "a").value, "a", "externref");
  eq(new WebAssembly.Global({ value: "anyfunc" }).value, null, "anyfunc by default");
  const { exports: x } = instantiate();
  eq(new WebAssembly.Global({ value: "anyfunc" }, x.add).value, x.add, "anyfunc");
  throws(() => new WebAssembly.Global({ value: "anyfunc" }, () => 1), "TypeError", "only exported functions");
  throws(() => new WebAssembly.Global({ value: "x" }), "TypeError", "a bad type");
  throws(() => new WebAssembly.Global(), "TypeError", "no descriptor");
  eq(x.g.value, 42, "an exported global");
});

// Types: 0 (i32)->() ; imports a tag of it and a function; `thrower` throws it, `pass` calls the import inside nothing,
// `caught` calls the import in a try_table and gives the value it caught, or -1 without an exception.
const EH = new Uint8Array([...HEADER,
  ...sec(1, [2, 0x60, 1, I32, 0, 0x60, 1, I32, 1, I32]),
  ...sec(2, [2, ...str("env"), ...str("tag"), 4, 0, 0, ...str("env"), ...str("f"), 0, 0]),
  ...sec(3, [4, 0, 0, 1, 1]),
  ...sec(7, [5, ...str("thrower"), 0, 1, ...str("pass"), 0, 2, ...str("caught"), 0, 3, ...str("any"), 0, 4, ...str("t"), 4, 0]),
  ...sec(10, [4,
    ...fn(0x20, 0, 0x08, 0),                                                           // throw 0
    ...fn(0x20, 0, 0x10, 0),                                                           // call the import
    // block (result i32) ; try_table (catch 0 0): call the import ; i32.const -1 ; return ; end ; unreachable ; end
    ...fn(0x02, I32, 0x1f, 0x40, 1, 0, 0, 0, 0x20, 0, 0x10, 0, 0x41, 0x7f, 0x0f, 0x0b, 0x00, 0x0b),
    // block ; try_table (catch_all 0): call the import ; i32.const 0 ; return ; end ; unreachable ; end ; i32.const 1
    ...fn(0x02, 0x40, 0x1f, 0x40, 1, 2, 0, 0x20, 0, 0x10, 0, 0x41, 0, 0x0f, 0x0b, 0x00, 0x0b, 0x41, 1),
  ]),
]);

test("Tag and Exception", () => {
  const t = new WebAssembly.Tag({ parameters: ["i32"] });
  eq(String(t), "[object WebAssembly.Tag]", "Tag toString");
  throws(() => new WebAssembly.Tag(), "TypeError", "no descriptor");
  throws(() => new WebAssembly.Tag({ parameters: ["x"] }), "TypeError", "a bad parameter");
  const e = new WebAssembly.Exception(t, [42.5]);
  eq(String(e), "[object WebAssembly.Exception]", "Exception toString");
  ok(e.is(t), "is");
  ok(!e.is(new WebAssembly.Tag({ parameters: ["i32"] })), "is another tag");
  eq(e.getArg(t, 0), 42, "getArg, converted");
  throws(() => e.getArg(t, 1), "RangeError", "getArg out of range");
  throws(() => e.getArg(new WebAssembly.Tag({ parameters: [] }), 0), "TypeError", "getArg of another tag");
  throws(() => new WebAssembly.Exception(t, []), "TypeError", "the wrong number of values");
  throws(() => new WebAssembly.Exception({}, []), "TypeError", "no tag");
  eq(new WebAssembly.Exception(new WebAssembly.Tag({ parameters: ["i64"] }), [1n]).getArg instanceof Function, true, "i64");

  let f = () => {};
  const x = new WebAssembly.Instance(new WebAssembly.Module(EH), { env: { tag: t, f: v => f(v) } }).exports;
  eq(x.t, t, "an exported tag is the object imported");
  try { x.thrower(7); ok(false, "a module's exception reaches JavaScript"); } catch (ex) {
    ok(ex instanceof WebAssembly.Exception, "it is a WebAssembly.Exception");
    ok(ex.is(t), "of its tag");
    eq(ex.getArg(t, 0), 7, "with its value");
  }
  f = () => { throw new WebAssembly.Exception(t, [9]); };
  eq(x.caught(0), 9, "an Exception thrown by an import is caught by the module");
  try { x.pass(0); ok(false, "and goes through one that does not catch"); } catch (ex) {
    ok(ex.is(t) && ex.getArg(t, 0) === 9, "through a module that does not catch");
  }
  f = () => { x.thrower(11); };
  eq(x.caught(0), 11, "module -> JavaScript -> module: caught by the first");
  const plain = new Error("plain");
  f = () => { throw plain; };
  try { x.pass(0); ok(false, "a plain error"); } catch (ex) { eq(ex, plain, "a plain error goes through as itself"); }
  eq(x.any(0), 1, "a plain error can be caught by a module (catch_all)");
  f = () => { throw 7; };
  try { x.pass(0); ok(false, "a primitive thrown"); } catch (ex) { eq(ex, 7, "a primitive thrown goes through as itself"); }
  f = () => {};
  eq(x.any(0), 0, "catch_all when nothing is thrown");
  ok(WebAssembly.JSTag instanceof WebAssembly.Tag, "JSTag");
  eq(typeof SharedArrayBuffer, "undefined", "no SharedArrayBuffer without cross-origin isolation");
  f = () => {};
  eq(x.caught(0), -1, "nothing thrown");
});

// The old form of exceptions (try, catch, catch_all, rethrow, delegate), translated at compilation.
const TRY = 0x06, CATCH = 0x07, THROW = 0x08, RETHROW = 0x09, END = 0x0b, DELEGATE = 0x18, CATCH_ALL = 0x19, VOID = 0x40;
const LEGACY = new Uint8Array([...HEADER,
  // 0 (i32)->() ; 1 (i32)->i32
  ...sec(1, [2, 0x60, 1, I32, 0, 0x60, 1, I32, 1, I32]),
  // imports a function (0) and two tags (0, 1)
  ...sec(2, [3, ...str("env"), ...str("f"), 0, 0, ...str("env"), ...str("a"), 4, 0, 0, ...str("env"), ...str("b"), 4, 0, 0]),
  ...sec(3, [7, 1, 1, 1, 1, 1, 1, 1]),
  ...sec(7, [8, ...str("caught"), 0, 1, ...str("all"), 0, 2, ...str("order"), 0, 3, ...str("again"), 0, 4, ...str("delegated"), 0, 5, ...str("out"), 0, 6,
    ...str("br"), 0, 7, ...str("a"), 4, 0]),
  ...sec(10, [7,
    // caught: try (result i32) f(x) ; -1 ; catch a: the value + 1 ; end
    ...fn(TRY, I32, 0x20, 0, 0x10, 0, 0x41, 0x7f, CATCH, 0, 0x41, 1, 0x6a, END),
    // all: try (result i32) f(x) ; 0 ; catch_all: 5 ; end
    ...fn(TRY, I32, 0x20, 0, 0x10, 0, 0x41, 0, CATCH_ALL, 0x41, 5, END),
    // order: try (result i32) f(x) ; 0 ; catch a: drop, 1 ; catch b: drop, 2 ; catch_all: 3 ; end
    ...fn(TRY, I32, 0x20, 0, 0x10, 0, 0x41, 0, CATCH, 0, 0x1a, 0x41, 1, CATCH, 1, 0x1a, 0x41, 2, CATCH_ALL, 0x41, 3, END),
    // again: try (result i32) ; try: f(x) ; catch_all: rethrow 0 ; end ; 0 ; catch a: the value ; end
    ...fn(TRY, I32, TRY, VOID, 0x20, 0, 0x10, 0, CATCH_ALL, RETHROW, 0, END, 0x41, 0, CATCH, 0, END),
    // delegated: try (result i32) ; try (catch that is skipped) ; try: f(x) ; delegate 1 ; catch_all: 100, return ; end ; 0 ; catch a: the value ; end
    ...fn(TRY, I32, TRY, VOID, TRY, VOID, 0x20, 0, 0x10, 0, DELEGATE, 1, CATCH_ALL, 0x41, 0xe4, 0, 0x0f, END, 0x41, 0, CATCH, 0, END),
    // out: try ; try: f(x) ; delegate 1 (out of the function) ; catch_all: 100 return ; end ; 0
    ...fn(TRY, VOID, TRY, VOID, 0x20, 0, 0x10, 0, DELEGATE, 1, CATCH_ALL, 0x41, 0xe4, 0, 0x0f, END, 0x41, 0),
    // br: block (result i32) ; try (result i32) ; f(x) ; 7 ; br 1 ; catch a: 8 ; br 1 ; end ; end
    ...fn(0x02, I32, TRY, I32, 0x20, 0, 0x10, 0, 0x41, 7, 0x0c, 1, CATCH, 0, 0x1a, 0x41, 8, 0x0c, 1, END, END),
  ]),
]);

test("the old form of exceptions", () => {
  eq(WebAssembly.validate(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 96, 0, 0, 3, 2, 1, 0, 10, 8, 1, 6, 0, 6, 64, 25, 11, 11])), true, "the module sites test with");
  eq(WebAssembly.validate(LEGACY), true, "validate");
  const a = new WebAssembly.Tag({ parameters: ["i32"] }), b = new WebAssembly.Tag({ parameters: ["i32"] });
  let f = () => {};
  const x = new WebAssembly.Instance(new WebAssembly.Module(LEGACY), { env: { f: v => f(v), a, b } }).exports;
  eq(x.a, a, "a tag");
  eq(x.caught(0), -1, "nothing thrown");
  f = v => { throw new WebAssembly.Exception(a, [v]); };
  eq(x.caught(41), 42, "catch, with its value");
  eq(x.all(0), 5, "catch_all");
  eq(x.order(1), 1, "the first catch");
  eq(x.again(9), 9, "rethrow, to the try around");
  eq(x.delegated(6), 6, "delegate skips the try in between");
  try { x.out(3); ok(false, "delegate out of the function"); } catch (e) { eq(e.getArg(a, 0), 3, "delegate out of the function"); }
  eq(x.br(0), 8, "a branch from a handler, past the try");
  f = v => { throw new WebAssembly.Exception(b, [v]); };
  eq(x.order(1), 2, "the second catch");
  try { x.caught(1); ok(false, "another tag goes through"); } catch (e) { ok(e.is(b), "another tag goes through"); }
  f = () => { throw new Error("js"); };
  eq(x.order(1), 3, "catch_all, JavaScript's own");
  f = () => {};
  eq(x.order(1), 0, "nothing thrown, the last");
  eq(x.br(0), 7, "a branch from the body, past the try");
  throws(() => new WebAssembly.Module(new Uint8Array([...HEADER, ...sec(1, [1, 0x60, 0, 0]), ...sec(3, [1, 0]), ...sec(10, [1, ...fn(TRY, VOID, RETHROW, 9, END)])])), "CompileError", "a bad module stays one");
});

test("the old form of exceptions, with the new blocks' types far in the type section", () => {
  // 70 types before the module's own, so what the translation adds has an index with bit 6 set
  const types = new Array(70).fill(0).flatMap((_, i) => [0x60, 1, I32, 2, I32, i % 2 ? I64 : F64]);
  const m = new Uint8Array([...HEADER,
    ...sec(1, [72, ...types, 0x60, 1, I32, 1, I32, 0x60, 1, I32, 0]),
    ...sec(2, [2, ...str("env"), ...str("f"), 0, 70, ...str("env"), ...str("a"), 4, 0, 71]),
    ...sec(3, [1, 70]),
    ...sec(7, [1, ...str("c"), 0, 1]),
    ...sec(10, [1, ...fn(TRY, I32, 0x20, 0, 0x10, 0, CATCH, 0, 0x41, 2, 0x6a, END)]),
  ]);
  const a = new WebAssembly.Tag({ parameters: ["i32"] });
  let f = v => v;
  const x = new WebAssembly.Instance(new WebAssembly.Module(m), { env: { f: v => f(v), a } }).exports;
  eq(x.c(5), 5, "nothing thrown");
  f = v => { throw new WebAssembly.Exception(a, [v]); };
  eq(x.c(5), 7, "caught");
});

test("a call with many values", () => {
  const N = 40;
  const many = new Uint8Array([...HEADER,
    ...sec(1, [1, 0x60, N, ...new Array(N).fill(I32), N, ...new Array(N).fill(I32)]),
    ...sec(2, [1, ...str("env"), ...str("f"), 0, 0]),
    ...sec(3, [1, 0]),
    ...sec(7, [1, ...str("c"), 0, 1]),
    ...sec(10, [1, ...leb(2 * N + 2 + 2), 0, ...new Array(N).fill(0).flatMap((_, i) => [0x20, i]), 0x10, 0, 0x0b]),
  ]);
  const args = new Array(N).fill(0).map((_, i) => i * 3);
  const x = new WebAssembly.Instance(new WebAssembly.Module(many), { env: { f: (...a) => a.map(v => v + 1) } }).exports;
  const r = x.c(...args);
  eq(r.length, N, "as many results");
  eq(r[39], 39 * 3 + 1, "the last one, through an import");
});

test("instantiate", async () => {
  const env = instantiate().env;
  const r = await WebAssembly.instantiate(RUN, { env });
  ok(r.module instanceof WebAssembly.Module, "bytes: a module");
  ok(r.instance instanceof WebAssembly.Instance, "and an instance");
  eq(r.instance.exports.add(1, 2), 3, "that works");
  const i = await WebAssembly.instantiate(r.module, { env });
  ok(i instanceof WebAssembly.Instance, "a Module: an instance");
  await rejects(WebAssembly.instantiate(BAD), "CompileError", "bad bytes");
  await rejects(WebAssembly.instantiate(RUN), "TypeError", "no imports");
  await rejects(WebAssembly.instantiate(RUN, { env: { ...env, add1: 1 } }), "LinkError", "a bad import");
  await rejects(WebAssembly.instantiate(1), "TypeError", "not bytes");
});

test("instantiateStreaming", async () => {
  const env = instantiate().env;
  const wasm = new Response(RUN, { headers: { "Content-Type": "application/wasm" } });
  const r = await WebAssembly.instantiateStreaming(wasm, { env });
  eq(r.instance.exports.add(2, 2), 4, "a Response");
  const p = Promise.resolve(new Response(RUN, { headers: { "Content-Type": "application/wasm; x=1" } }));
  eq((await WebAssembly.instantiateStreaming(p, { env })).instance.exports.add(2, 3), 5, "the promise of a Response");
  ok(await WebAssembly.compileStreaming(new Response(RUN, { headers: { "Content-Type": "application/wasm" } })) instanceof WebAssembly.Module, "compileStreaming");
  await rejects(WebAssembly.instantiateStreaming(new Response(RUN), { env }), "TypeError", "another MIME type");
  await rejects(WebAssembly.instantiateStreaming(1, { env }), "TypeError", "no Response");
  await rejects(WebAssembly.compileStreaming(new Response(RUN, { status: 404, headers: { "Content-Type": "application/wasm" } })), "TypeError", "not ok");
});

__run();
