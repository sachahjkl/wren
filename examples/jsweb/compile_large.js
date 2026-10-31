// Functions and programs with many variables: the compiler looks their names up in a table (src/engine/frontend/js_emit.odin,
// NAME_INDEX_MIN_ENTRIES); what a name means must not depend on how many there are.

const MANY = 300;
const names = (prefix, n = MANY) => Array.from({ length: n }, (_, i) => prefix + i);

test("many variables in a function", () => {
  const vars = names("v").map((n, i) => `var ${n} = ${i};`).join("");
  const f = new Function("a0", `${vars}
    function inner() { return v7 + v299 + a0; }
    var v7 = 1000;                     // the same var again: one variable
    return [inner(), typeof missing, (() => v0)()].join(" ");`);
  eq(f(5), "1304 undefined 0", "var, var again, argument, global from a nested function");
  const lets = names("l").map((n, i) => `let ${n} = ${i};`).join("");
  const g = new Function(`${lets}
    { let l5 = "inner"; var seen = l5; }
    const read = () => l5 + l299;
    return seen + " " + read();`);
  eq(g(), "inner 304", "a block's let shadows, the function's are seen from a closure");
  const h = new Function("x", `${vars} var x; var arguments; function self() { return typeof self; } return [x, typeof arguments, self()].join(" ");`);
  eq(h(9), "9 object function", "a var named as the argument, arguments, a function's own name");
  const e = new Function(`${vars} var r = eval("v3 + 1"); return r + " " + eval("var v300 = 2; v300 + v299");`);
  eq(e(), "4 301", "direct eval sees them, and adds one");
  const w = new Function("o", `${vars} with (o) { return (() => v1 + v2)(); }`);
  eq(w({ v1: 100 }), 102, "with: the object first, then the variables");
});

test("redeclarations in a long list", () => {
  const vars = names("v").map(n => `var ${n};`).join("");
  throws(() => new Function(`${vars} let v250;`), "SyntaxError", "let after a var of the same name");
  throws(() => new Function(`${vars} { var q; } let q;`), "SyntaxError", "let after a var of a nested block");
  eq(new Function(`${vars} { let v250 = 1; return v250; }`)(), 1, "a let in a block over a var is allowed");
  const list = names("g").map(n => `var ${n}; function f_${n}() { return ${n}; }`).join("");
  throws(() => (0, eval)(`${list} let g42;`), "SyntaxError", "a global let over a global var of the same program");
});

test("many variables in a program and a module", async () => {
  const decls = names("big_g").map((n, i) => `var ${n} = ${i};`).join("");
  eq((0, eval)(`${decls} (function () { return (() => big_g299 + big_g1)(); })()`), 300, "indirect eval: globals from nested functions");
  const body = names("m").map((n, i) => (i % 2 ? `var ${n} = ${i};` : `let ${n} = ${i};`)).join("") +
    names("m_f", 100).map((n, i) => `function ${n}() { return m${i} + m${i + 1}; }`).join("") +
    `export const sum = m_f0() + m_f99(); export const lexical = (() => { try { return undefinedName; } catch (e) { return e.name; } })();` +
    `export { m298 as renamed, m_f1 };`;
  const u = URL.createObjectURL(new Blob([body], { type: "text/javascript" }));
  const mod = await import(u);
  URL.revokeObjectURL(u);
  eq(mod.sum, 200, "a module's lets, vars and functions from its functions");
  eq(mod.lexical, "ReferenceError", "a name no list has");
  eq(mod.renamed, 298, "export of a name of the long list, renamed");
  eq(mod.m_f1(), 3, "export of a function of the long list");
  const dup = URL.createObjectURL(new Blob([names("d").map(n => `let ${n};`).join("") + "var d9;"], { type: "text/javascript" }));
  await rejects(import(dup), "SyntaxError", "a module's var over its let");
  URL.revokeObjectURL(dup);
});

__run();
