// The WebAssembly JavaScript API (native/js/odin/web_wasm.js), with javascript.webassembly.enabled on.
"use strict";

const str = s => { const b = [...new TextEncoder().encode(s)]; return [b.length, ...b]; };
const sec = (id, body) => [id, body.length, ...body];
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
  const m = await WebAssembly.compile(MODULE);
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

__run();
