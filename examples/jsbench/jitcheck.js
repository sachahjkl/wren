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
  // an object with a deleted property has a shape of its own, changed and reallocated in place as properties come
  var dict = { a: 1, b: 2, c: 3 }; delete dict.b;
  function readA(o) { return o.a; }
  for (r = 0; r < 40; r++) { dict["k" + r] = r; p("dict", readA(dict), readX({ x: r })); }
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
  p("tail", tail(100, 0));   // (a tail call recurses through the native call path: 1000 of them overflowed and ended the script here)

  // globals and equality with null / undefined
  globalThis.__g = 1;
  function bump() { __g = __g + 1; return __g; }
  bump(); p("global", bump());
  function eqs(a) { return [a == null, a === null, a == undefined, a != null, a === undefined].join(","); }
  [null, undefined, 0, "", {}, false].forEach(function (v) { p("eq", show(v), eqs(v)); });

  // a return from inside a compiled loop, in a function called from JavaScript: the caller goes on, no frame is left behind
  function find(list, x) { for (var i = 0; i < list.length; i++) { if (list[i] === x) { return i * 2 + 1; } } return -1; }
  function twice(list, x) { return find(list, x) + ":" + find(list, x + 1); }
  var hay = []; for (var h = 0; h < 2000; h++) { hay.push(h); }
  var found = ""; for (var r = 0; r < 300; r++) { found = twice(hay, 1500 + r); }
  p("loop return", found);
  function depth() { var n = 0; function f() { n++; f(); } try { f(); } catch (e) {} return n; }
  var before = depth(); for (var q = 0; q < 500; q++) { twice(hay, 1000); } p("loop return leaves the depth", before === depth());

  // compiled loops that read and write properties: each loop runs long enough to be compiled (a loop is offered to the
  // JIT within INTERRUPT_POLL_EVERY back edges), then is called again with objects of other shapes, prototypes changed,
  // values of other types, so that the compiled code meets what it was not made for (learn exits, deopts)
  var RUN = 24000;
  function Pt3(x) { this.x = x; this.y = x + 1; }
  function sumXY(o, n) { var s = 0; for (var i = 0; i < n; i++) { s = (s + o.x + o.y) | 0; o.x = i & 15; } return s; }
  var shaped = [new Pt3(1), { y: 2, x: 1 }, { x: 1, y: 2 }, { a: 0, x: 1, y: 2 }, { b: 0, x: 1, y: 2 }, { c: 0, x: 1, y: 2 }];
  for (var r = 0; r < shaped.length; r++) { p("prop loop", r, sumXY(shaped[r], RUN)); }
  var dict = { x: 1, y: 2, z: 3 }; delete dict.z;
  p("prop loop: a dictionary", sumXY(dict, RUN));
  dict.w = 4; delete dict.w; p("prop loop: the dictionary changed", sumXY(dict, RUN));
  var getter = { y: 2 }; Object.defineProperty(getter, "x", { get: function () { return 3; }, set: function () {} });
  p("prop loop: an accessor", sumXY(getter, RUN));
  var frozenPt = Object.freeze({ x: 1, y: 2 });
  try { p("prop loop: frozen", sumXY(frozenPt, RUN)); } catch (e) { p("prop loop: frozen", e.name); }
  p("prop loop: a proxy", sumXY(new Proxy({ x: 1, y: 2 }, {}), RUN));
  p("prop loop: an array", sumXY([1, 2], RUN));
  try { p("prop loop: null", sumXY(null, RUN)); } catch (e) { p("prop loop: null", e.name); }

  function sumProto(o, n) { var s = 0; for (var i = 0; i < n; i++) { s = (s + o.k + o.m) | 0; } return s; }
  var P0 = { k: 5, m: 1 }, Q0 = Object.create(P0), o0 = Object.create(Q0);
  p("prototype", sumProto(o0, RUN));
  P0.k = 6; p("prototype: the holder's value", sumProto(o0, RUN));
  Q0.k = 100; p("prototype: shadowed in the middle", sumProto(o0, RUN));
  o0.k = 1000; p("prototype: shadowed in the object", sumProto(o0, RUN));
  delete o0.k; Object.setPrototypeOf(Q0, { k: -1, m: 2 }); delete Q0.k; p("prototype: another chain", sumProto(o0, RUN));
  Object.defineProperty(Object.getPrototypeOf(Q0), "m", { get: function () { return 9; } }); p("prototype: a getter", sumProto(o0, RUN));
  p("prototype: a function's", sumProto(Object.assign(function () {}, { k: 1, m: 1 }), RUN));

  function setV(o, n, v) { for (var i = 0; i < n; i++) { o.v = i & 3; } o.v = v; return o.v; }
  var sv = { v: 0 };
  p("write", setV(sv, RUN, 1), setV(sv, RUN, "s"));
  var withSetter = Object.create({ set v(x) { this.log = (this.log | 0) + x; }, get v() { return this.log; } });
  p("write: a setter on the prototype", setV(withSetter, RUN, 2), withSetter.log);
  Object.freeze(sv); try { p("write: frozen", setV(sv, RUN, 3)); } catch (e) { p("write: frozen", e.name, sv.v); }

  function typesOf(o, n) {
    var same = 0, nullish = 0, truthy = 0, sum = 0;
    for (var i = 0; i < n; i++) {
      var v = o.v;
      if (i === (n >> 1)) { o.v = o.w; }   // a compiled store of another type
      if (v === o.w) { same++; }
      if (v == null) { nullish++; }
      if (v) { truthy++; }
      o.last = v;
      if (i < (n >> 1)) { sum = sum + v; }
    }
    return [same, nullish, truthy, show(sum), show(o.last)].join(" ");
  }
  [[1, 2147483647], [1, -0], [1, 0.5], [0.5, 1], [1, "s"], [1, {}], [1, null], [1, undefined], [1, true], ["s", 1]].forEach(function (vw) {
    p("types", show(vw[0]), show(vw[1]), typesOf({ v: vw[0], w: vw[1] }, RUN));
  });

  function polyX(os, n) { var s = 0; for (var i = 0; i < n; i++) { s += os[i & 3].x; } return show(s); }
  var four = [{ x: 1 }, { a: 0, x: 2 }, { b: 0, c: 0, x: 3 }, Object.create({ x: 5 })];
  p("polymorphic", polyX(four, RUN));
  four[1] = new Proxy({ x: 9 }, { get: function (t, k) { return k === "x" ? 4 : undefined; } }); p("polymorphic: a proxy", polyX(four, RUN));
  four[2] = { get x() { return 11; } }; p("polymorphic: a getter", polyX(four, RUN));
  four[3] = { x: 0.5 }; p("polymorphic: a double", polyX(four, RUN));
  four[0] = { d: 1, e: 1, x: 1 }; four[1] = { f: 1, x: 2 }; p("polymorphic: more shapes than a site takes", polyX(four, RUN));

  function eqsOf(vals, n) {
    var c = 0, o = vals[5];
    for (var i = 0; i < n; i++) {
      var a = vals[i & 7], b = vals[(i >> 3) & 7];
      if (a === b) { c += 1; }
      if (a !== null) { c += 2; }
      if (a === undefined) { c += 4; }
      if (a === o) { c += 8; }
      if (a) { c += 16; }
      if (!a) { c += 32; }
      if (a == null) { c += 64; }
    }
    return c;
  }
  p("equality and truth", eqsOf([null, undefined, 0, true, false, {}, [], -1], RUN));
  p("equality and truth: strings", eqsOf([null, "ab", "a" + "b", "", {}, {}, 1.5, NaN], RUN));

  globalThis.__h = 0;
  function bumpGlobal(n) { var s = 0; for (var i = 0; i < n; i++) { __h = __h + 1; s += __h; } return s; }
  p("globals", bumpGlobal(RUN));
  globalThis.__other = 1; p("globals: the global object grew", bumpGlobal(RUN));
  __h = 0.5; p("globals: a double", show(bumpGlobal(RUN)));
  delete globalThis.__other; delete globalThis.__h;
  try { p("globals: deleted", bumpGlobal(RUN)); } catch (e) { p("globals: deleted", e.name); }

  function elems(o, n) { var s = 0; for (var i = 0; i < n; i++) { var e = o.a[i & 3]; s += e === undefined ? 100 : e; o.a[1] = i & 7; } return show(s) + " " + o.a.length; }
  var eo = { a: [1, 2, 3, 4] };
  p("elements", elems(eo, RUN));
  eo.a.length = 2; p("elements: shorter", elems(eo, RUN));
  eo.a[6] = 1; p("elements: a hole", elems(eo, RUN));
  eo.a = [0.5, 1, 2, 3]; p("elements: doubles", elems(eo, RUN));
  eo.a = new Int8Array(4); p("elements: a typed array", elems(eo, RUN));
  eo.a = { 0: 1, 1: 2, 2: 3, 3: 4, length: 4 }; p("elements: an object", elems(eo, RUN));

  function deep(os, n) { var s = 0; for (var i = 0; i < n; i++) { s += os[0].p.q; } return s; }
  p("chain", deep([{ p: { q: 1 } }], RUN));
  try { p("chain: null", deep([{ p: null }], RUN)); } catch (e) { p("chain: null", e.constructor.name); }

  var cell = 0, late = 1;
  function closed(n) { for (var i = 0; i < n; i++) { cell = cell + (i & 1); } return cell + late; }
  p("closure cells", closed(RUN), closed(RUN));
  function tdzCell(n) { var s = 0; try { for (var i = 0; i < n; i++) { s += i & 1; if (i === n - 1) { s += lateLet; } } } catch (e) { s += 1000; } return s; }
  p("closure cell before its declaration", tdzCell(RUN));
  let lateLet = 5;
  p("closure cell after its declaration", tdzCell(RUN));

  // calls in compiled loops: small functions inlined (the callee guarded, a deopt in it leaves the call to the
  // interpreter), Math functions computed inline, natives called through the helper (exceptions, arrays that grow,
  // collections while compiled code holds objects)
  function add2(a, b) { return a + b; }
  function callAdd(n) { var s = 0; for (var i = 0; i < n; i++) { s = add2(s, i & 7); } return show(s); }
  p("inlined", callAdd(RUN));
  var realAdd = add2; add2 = function (a, b) { return a - b; }; p("inlined: the global replaced", callAdd(RUN)); add2 = realAdd;
  function V2(x, y) { this.x = x; this.y = y; }
  V2.prototype.dot = function (o) { return this.x * o.x + this.y * o.y; };
  V2.prototype.len2 = function () { return this.dot(this); };
  function sumLen(vs, n) { var s = 0; for (var i = 0; i < n; i++) { s = s + vs[i & 3].len2(); } return show(s); }
  var vs4 = [new V2(1, 2), new V2(3, 4), new V2(0.5, 1), new V2(-0, 0)];
  p("inlined methods", sumLen(vs4, RUN));
  vs4[2] = { x: 1, y: 1, len2: function () { return 1000; } }; p("inlined methods: another method", sumLen(vs4, RUN));
  V2.prototype.dot = function (o) { return 7; }; p("inlined methods: the prototype's replaced", sumLen(vs4, RUN));
  vs4[0] = new V2(2147483647, 2147483647); p("inlined methods: overflow in the callee", sumLen(vs4, RUN));
  vs4[1] = { len2: function () { return this.missing.x; } };
  try { p("inlined methods: a TypeError in the callee", sumLen(vs4, RUN)); } catch (e) { p("inlined methods: a TypeError in the callee", e.name); }
  function missingArgs(n) { var s = 0; for (var i = 0; i < n; i++) { s += add2(i) === add2(i) ? 1 : 0; s += add2(i, 1, 2); } return show(s); }
  p("inlined: missing and extra arguments", missingArgs(RUN));
  function fibLoop(n) { var s = 0; for (var i = 0; i < n; i++) { s += fib(i & 7); } return s; }
  p("recursion from a compiled loop", fibLoop(RUN));
  function mathLoop(n) {
    var s = 0, t = 0;
    for (var i = 0; i < n; i++) {
      var x = (i & 15) - 7.5;
      s += Math.floor(x) + Math.ceil(x) + Math.trunc(x) + Math.abs(x) + Math.sqrt(i & 31) + Math.max(x, -x) + Math.min(i & 3, 2);
      t = (t + Math.abs(i - 3) + Math.imul(i, 0x7fffffff) + Math.floor(i)) | 0;
    }
    return show(s) + " " + t + " " + show(Math.max(-0, 0)) + " " + show(Math.min(-0, 0)) + " " + show(Math.floor(-0.5));
  }
  p("Math inline", mathLoop(RUN));
  function mathEdges(vals, n) { var s = 0, m = 0; for (var i = 0; i < n; i++) { var v = vals[i & 7]; s += Math.abs(v); m = Math.max(m, Math.floor(v)); } return show(s) + " " + show(m); }
  p("Math inline: edges", mathEdges([-2147483648, 1, -1, 0, NaN, -0, 1e300, -Infinity], RUN));
  var realFloor = Math.floor; Math.floor = function (x) { return 42; }; p("Math inline: replaced", mathLoop(RUN)); Math.floor = realFloor;
  function pushes(n) { var a = [], s = 0; for (var i = 0; i < n; i++) { a.push(i & 15); s += a[a.length - 1] + a.length; if (a.length > 64) { a.length = 0; } } return s + " " + a.length; }
  p("native calls: an array that grows", pushes(RUN));
  function heldArray(n) { var a = [1, 2, 3], s = 0; for (var i = 0; i < n; i++) { s += a[i % 3]; if ((i & 255) === 0) { a.push(i); a.pop(); } } return s; }
  p("native calls: a held array", heldArray(RUN));
  function natThrows(n) { var s = 0, m = new Map(); try { for (var i = 0; i < n; i++) { m.set(i & 7, i); s += m.get(i & 7); if (i === n - 7) { m.set.call(null, 1, 1); } } } catch (e) { return s + " " + e.name; } return s; }
  p("native calls: an exception", natThrows(RUN));
  function collects(n) {
    var keep = { v: 1 }, s = 0;
    for (var i = 0; i < n; i++) {
      var t = JSON.parse("[1,2,3]");
      s += t[1] + keep.v;
      if ((i & 1023) === 0) { keep = JSON.parse("{\"v\":" + (i & 3) + "}"); }
    }
    return s;
  }
  p("native calls: collections while objects are held", collects(RUN));

  // strings in compiled loops: length, charCodeAt read inline (a rope, an index out of the string, a wide string, the
  // method replaced), String.prototype's other methods called
  function codes(s, n) { var h = 0; for (var i = 0; i < n; i++) { var k = i % (s.length + 2); h = (h * 31 + s.charCodeAt(k)) | 0; } return h; }
  var rope = ""; for (var w = 0; w < 40; w++) { rope += "ab" + w; }
  p("strings", codes("hello, world", RUN), codes(rope, RUN), codes("é€\u{1F600}x", RUN), codes("", RUN));
  var realCode = String.prototype.charCodeAt; String.prototype.charCodeAt = function (i) { return i; };
  p("strings: charCodeAt replaced", codes("abc", RUN)); String.prototype.charCodeAt = realCode;
  function strMethods(s, n) { var c = 0; for (var i = 0; i < n; i++) { c += s.indexOf("o", i & 7) + s.length; } return c; }
  p("strings: a native method", strMethods("hello world", RUN));
  function strOrObj(vs, n) { var c = 0; for (var i = 0; i < n; i++) { c += vs[i & 1].length; } return c; }
  p("strings: a string or an array", strOrObj(["abc", [1, 2]], RUN));

  // switch, strings, generators (not compiled) next to compiled code
  function sw(x) { switch (x) { case 1: return "one"; case "1": return "string"; default: return "other"; } }
  p("switch", sw(1), sw("1"), sw(2));
  function* gen() { yield 1; yield 2; }
  var gs = 0; for (var g of gen()) { gs += g; } p("gen", gs);
  p("str", "ab" + 1 + 2, 1 + 2 + "ab");

  console.log(out.join("\n"));
})();
