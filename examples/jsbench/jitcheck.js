// Cases where the JIT's inline code and its fallbacks must agree with the interpreter: run by
//   build\jsengine.exe verify examples\jsbench\jitcheck.js
// (once interpreted, once with every function compiled at its first call: the output must be the same).
(function () {
  "use strict";
  var out = [];
  function p() { out.push(Array.prototype.join.call(arguments, " ")); }
  function show(v) { return typeof v === "number" ? (Object.is(v, -0) ? "-0" : String(v)) : typeof v === "object" && v !== null ? "[obj]" : String(v); }

  // arithmetic at the edges
  var nums = [0, -0, 1, -1, 2, 7, 0x7fffffff, -0x80000000, 0x80000000, 4294967295, 1.5, -2.5, 1e300, -1e-300, NaN, Infinity, -Infinity, "3", true, null, undefined, {}, [2]];
  function arith(a, b) {
    return [a + b, a - b, a * b, a / b, a % b, a & b, a | b, a ^ b, a << b, a >> b, a >>> b, a < b, a <= b, a > b, a >= b, a == b, a != b, a === b, a !== b].map(show).join(",");
  }
  for (var i = 0; i < nums.length; i++) {
    for (var j = 0; j < nums.length; j++) { p("arith", i, j, arith(nums[i], nums[j])); }
  }
  function unary(a) { var x = a, y = a; x++; y--; return [show(x), show(y), show(-a), show(+a), show(~a), show(!a)].join(","); }
  for (var k = 0; k < nums.length; k++) { p("unary", k, unary(nums[k])); }

  // loops, overflow into doubles, locals
  function loop(n) { var s = 0, t = 1; for (var i = 0; i < n; i++) { s += i * i; t = (t * 3) % 1000003; } return s + ":" + t; }
  p("loop", loop(10), loop(100000));
  function overflow() { var x = 0x7ffffff0; for (var i = 0; i < 40; i++) { x++; } var y = -0x7ffffff0; for (i = 0; i < 40; i++) { y--; } return x + " " + y; }
  p("overflow", overflow());

  // properties: own, prototype, getters, setters, shape changes at one site
  function Pt(x, y) { this.x = x; this.y = y; }
  Pt.prototype.sum = function () { return this.x + this.y; };
  Object.defineProperty(Pt.prototype, "twice", { get: function () { return this.x * 2; }, set: function (v) { this.x = v / 2; } });
  function readX(o) { return o.x; }
  function readTwice(o) { return o.twice; }
  function writeX(o, v) { o.x = v; return o.x; }
  var objs = [new Pt(1, 2), { x: "a" }, { y: 1, x: 3 }, Object.create({ x: "proto" }), [5], "str", 42];
  for (var r = 0; r < 3; r++) {
    for (var q = 0; q < objs.length; q++) { p("read", r, q, show(readX(objs[q]))); }
  }
  var pt = new Pt(3, 4);
  for (r = 0; r < 4; r++) { p("getter", readTwice(pt), pt.sum()); pt.twice = r * 10; }
  delete pt.y; p("deleted", pt.y, pt.sum());
  pt.y = 7; p("readded", pt.sum());
  Object.defineProperty(pt, "x", { value: 100, writable: false });
  try { writeX(pt, 5); p("frozen write ok?"); } catch (e) { p("frozen write", e.name); }
  Pt.prototype.sum = function () { return "replaced"; };
  p("method replaced", pt.sum());
  var frozen = Object.freeze({ x: 1 });
  try { writeX(frozen, 2); } catch (e) { p("freeze", e.name); }

  // arrays
  function aget(a, i) { return a[i]; }
  function aset(a, i, v) { a[i] = v; return a.length; }
  var arr = [1, 2, 3];
  p("aget", aget(arr, 0), aget(arr, 2), aget(arr, 3), aget(arr, -1), aget(arr, "1"), aget(arr, 1.5));
  p("aset", aset(arr, 0, 9), aset(arr, 3, 4), aset(arr, 10, 1), arr.join("|"));
  var ta = new Int8Array(4); aset(ta, 1, 300); p("typed", aget(ta, 1));

  // exceptions in compiled code, caught in the same function and outside
  function thrower(n) { var s = 0; for (var i = 0; i < n; i++) { try { if (i % 3 === 2) { throw new Error("e" + i); } s += i; } catch (e) { s += 100; } } return s; }
  p("try", thrower(10));
  function finallyLoop(n) { var s = 0; for (var i = 0; i < n; i++) { try { s += i; } finally { s *= 2; } } return s; }
  p("finally", finallyLoop(10));
  function bad(o) { return o.missing.deeper; }
  try { bad({}); } catch (e) { p("TypeError", e instanceof TypeError); }
  function tdz() { try { return x; } catch (e) { return e.name; } let x = 1; }
  p("tdz", tdz());

  // closures, arguments, recursion, tail calls
  function counter() { var c = 0; return function () { return ++c; }; }
  var ct = counter(); ct(); ct(); p("closure", ct());
  function args() { return arguments.length + ":" + Array.prototype.slice.call(arguments).join(","); }
  p("arguments", args(1, 2, 3), args());
  function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
  p("fib", fib(20));
  function tail(n, acc) { if (n === 0) { return acc; } return tail(n - 1, acc + n); }
  p("tail", tail(1000, 0));

  // globals and equality with null / undefined
  globalThis.__g = 1;
  function bump() { __g = __g + 1; return __g; }
  bump(); p("global", bump());
  function eqs(a) { return [a == null, a === null, a == undefined, a != null, a === undefined].join(","); }
  [null, undefined, 0, "", {}, false].forEach(function (v) { p("eq", show(v), eqs(v)); });

  // switch, strings, generators (not compiled) next to compiled code
  function sw(x) { switch (x) { case 1: return "one"; case "1": return "string"; default: return "other"; } }
  p("switch", sw(1), sw("1"), sw(2));
  function* gen() { yield 1; yield 2; }
  var gs = 0; for (var g of gen()) { gs += g; } p("gen", gs);
  p("str", "ab" + 1 + 2, 1 + 2 + "ab");

  console.log(out.join("\n"));
})();
