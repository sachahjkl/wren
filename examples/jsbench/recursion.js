// How deep each kind of call goes: every one ends in a RangeError the script catches, past what real pages need, with the realm alive. Run by
//   build\jsengine.exe verify examples\jsbench\recursion.js
// (once interpreted, once with every function compiled at its first call: the same lines, and none that says FAILED).
(function () {
  "use strict";
  var LEVELS = 2500, NATIVE_LEVELS = 1500;
  function p() { console.log(Array.prototype.join.call(arguments, " ")); }
  function go(name, least, make) {
    var depth = 0, end = "FAILED: no error";
    try { make(function () { depth++; }); } catch (e) { end = e instanceof RangeError ? "RangeError" : "FAILED: " + e; }
    p(name, end, depth >= least ? "deep" : "FAILED: shallow " + depth);
  }

  go("call", LEVELS, function (step) { function f() { step(); f(); } f(); });
  go("new", LEVELS, function (step) { function F() { step(); new F(); } new F(); });
  go("new class", LEVELS, function (step) { class C { constructor() { step(); new C(); } } new C(); });
  go("super", LEVELS, function (step) { class A { constructor() { step(); new B(); } } class B extends A { constructor() { super(); } } new B(); });
  go("derived default", LEVELS, function (step) { class A { constructor() { step(); new B(); } } class B extends A {} new B(); });
  go("spread call", LEVELS, function (step) { function f(...a) { step(); f(...a); } f(1, 2); });
  go("spread new", LEVELS, function (step) { function F(...a) { step(); new F(...a); } new F(1); });
  go("getter", LEVELS, function (step) { var o = { get x() { step(); return o.x; } }; o.x; });
  go("getter on the prototype", LEVELS, function (step) { class A { get x() { step(); return this.x; } } new A().x; });
  go("setter", LEVELS, function (step) { var o = { set x(v) { step(); o.x = v; } }; o.x = 1; });
  go("proxy get", NATIVE_LEVELS, function (step) { var q = new Proxy({}, { get() { step(); return q.x; } }); q.x; });
  go("proxy set", NATIVE_LEVELS, function (step) { var q = new Proxy({}, { set() { step(); q.x = 1; return true; } }); q.x = 1; });
  go("proxy has", NATIVE_LEVELS, function (step) { var q = new Proxy({}, { has() { step(); return "x" in q; } }); "x" in q; });
  go("proxy apply", NATIVE_LEVELS, function (step) { var q = new Proxy(function () {}, { apply() { step(); return q(); } }); q(); });
  go("proxy construct", NATIVE_LEVELS, function (step) { var q = new Proxy(function () {}, { construct() { step(); return new q(); } }); new q(); });
  go("Reflect.apply", NATIVE_LEVELS, function (step) { function f() { step(); Reflect.apply(f, null, []); } f(); });
  go("Reflect.construct", NATIVE_LEVELS, function (step) { function F() { step(); Reflect.construct(F, []); } new F(); });
  go("Reflect.get", NATIVE_LEVELS, function (step) { var o = { get x() { step(); return Reflect.get(o, "x"); } }; o.x; });
  go("bound", NATIVE_LEVELS, function (step) { var b; function f() { step(); b(); } b = f.bind(null); b(); });
  go("bound new", NATIVE_LEVELS, function (step) { var b; function F() { step(); new b(); } b = F.bind(null); new b(); });
  go("apply", NATIVE_LEVELS, function (step) { function f() { step(); f.apply(null, []); } f(); });
  go("map", NATIVE_LEVELS, function (step) { var a = [1]; function f() { step(); a.map(f); } f(); });
  go("forEach", NATIVE_LEVELS, function (step) { var a = [1]; function f() { step(); a.forEach(f); } f(); });
  go("reduce", NATIVE_LEVELS, function (step) { var a = [1, 2]; function f() { step(); a.reduce(f); } f(); });
  go("sort", NATIVE_LEVELS, function (step) { var a = [2, 1]; function f() { step(); a.sort(f); return 0; } a.sort(f); });
  go("replace", NATIVE_LEVELS, function (step) { function f() { step(); "a".replace(/a/, f); return ""; } f(); });
  go("JSON.stringify", NATIVE_LEVELS, function (step) { var o = { toJSON() { step(); return JSON.stringify(o); } }; JSON.stringify(o); });
  go("JSON.parse", NATIVE_LEVELS, function (step) { function f() { step(); JSON.parse("1", f); } f(); });
  go("toString", NATIVE_LEVELS, function (step) { var o = { toString() { step(); return "" + o; } }; "" + o; });
  go("iterator", NATIVE_LEVELS, function (step) { var o = { [Symbol.iterator]() { step(); [...o]; return [][Symbol.iterator](); } }; [...o]; });
  go("generator", NATIVE_LEVELS, function (step) { function* g() { step(); yield* g(); } [...g()]; });

  // a Promise executor: the rejection is the end
  var depth = 0;
  function executor() { depth++; new Promise(executor); }
  new Promise(executor);
  p("Promise executor", depth >= NATIVE_LEVELS ? "deep" : "FAILED: shallow " + depth);

  // what a native that recurses by itself gives near the end of a stack: a deep call chain that parses all along its way
  var parsed = 0;
  function parsing(n) { if (JSON.parse("[[[[[[[[[[1]]]]]]]]]]")[0][0][0][0][0][0][0][0][0][0] === 1) { parsed++; } if (n > 0) { [n].forEach(function () { parsing(n - 1); }); } }
  parsing(NATIVE_LEVELS);
  p("JSON.parse at every depth", parsed === NATIVE_LEVELS + 1 ? "ok" : "FAILED at " + parsed);

  // the stack is whole after each of these: the same recursion again, and a local of this frame still right
  var again = 0;
  function twice(n) { if (n > 0) { [n].map(function () { twice(n - 1); }); } again = n; }
  for (var round = 0; round < 3; round++) { twice(NATIVE_LEVELS); }
  p("again", again === NATIVE_LEVELS ? "ok" : "FAILED: " + again);
})();
