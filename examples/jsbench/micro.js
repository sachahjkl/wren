// JavaScript engine micro-benchmarks (no DOM): the shapes of code an interpreter or a compiler handles differently.
//   build\jsengine.exe run examples\jsbench\micro.js        (Wren's engine; tools\js_bench.ps1 -Mode micro)
//   qjs examples\jsbench\micro.js, node, d8...               (any shell with console.log)
// One line per case: "MICRO<TAB>name<TAB>ns per iteration"; each case runs long enough to be timed (doubling its count
// until it lasts CALIBRATE_MS), then MEASURE_RUNS times, the best run counting. A checksum line ends the output: an engine
// that computes a case wrongly shows a different one.
(function () {
  "use strict";
  var CALIBRATE_MS = 150, MEASURE_RUNS = 3;
  var now = Date.now;   // (jsengine's realm has no performance object; 150 ms runs keep Date's 1 ms within 1 %)
  var check = 0;
  function measure(name, body) {
    // the checksum takes a fixed count (the timed runs' counts depend on the engine's speed)
    var r = body(3000);
    check = (check * 31 + (typeof r === "number" ? (r % 1000003) | 0 : String(r).length)) | 0;
    var n = 1024, t = 0;
    for (;;) {
      var t0 = now();
      r = body(n);
      t = now() - t0;
      if (t >= CALIBRATE_MS || n >= (1 << 28)) { break; }
      n *= t > 0 ? Math.min(8, Math.max(2, Math.ceil(CALIBRATE_MS * 1.2 / t))) : 8;
    }
    var best = Infinity;
    for (var k = 0; k < MEASURE_RUNS; k++) {
      var t1 = now();
      r = body(n);
      best = Math.min(best, now() - t1);
    }
    console.log("MICRO\t" + name + "\t" + (best * 1e6 / n).toFixed(2));
  }

  measure("int loop (sum += i)", function (n) { var s = 0; for (var i = 0; i < n; i++) { s = (s + i) | 0; } return s; });
  measure("float loop (x = x * 1.000001 + 0.5)", function (n) { var x = 1.5; for (var i = 0; i < n; i++) { x = x * 1.000001 + 0.5; } return x | 0; });
  measure("nested loops, int compare", function (n) { var c = 0, m = Math.sqrt(n) | 0; for (var i = 0; i < m; i++) { for (var j = 0; j < m; j++) { if ((i ^ j) & 1) { c++; } } } return c; });
  function add(a, b) { return a + b; }
  measure("call of a small function", function (n) { var s = 0; for (var i = 0; i < n; i++) { s = add(s, 1); } return s; });
  function fib(k) { return k < 2 ? k : fib(k - 1) + fib(k - 2); }
  measure("recursion (fib, per call)", function (n) { var calls = 0, s = 0; while (calls < n) { s += fib(15); calls += 1973; } return s; });
  measure("closure counter", function (n) { var c = 0; var inc = function () { c++; }; for (var i = 0; i < n; i++) { inc(); } return c; });
  function Point(x, y) { this.x = x; this.y = y; }
  Point.prototype.norm2 = function () { return this.x * this.x + this.y * this.y; };
  measure("property get (o.x + o.y)", function (n) { var o = new Point(1, 2), s = 0; for (var i = 0; i < n; i++) { s = (s + o.x + o.y) | 0; } return s; });
  measure("property set (o.x = i)", function (n) { var o = new Point(1, 2); for (var i = 0; i < n; i++) { o.x = i; } return o.x; });
  measure("method call on a prototype", function (n) { var o = new Point(3, 4), s = 0; for (var i = 0; i < n; i++) { s = (s + o.norm2()) | 0; } return s; });
  measure("polymorphic property get (4 shapes)", function (n) {
    var os = [{ a: 1, x: 1 }, { b: 1, x: 2 }, { c: 1, x: 3 }, { d: 1, x: 4 }], s = 0;
    for (var i = 0; i < n; i++) { s = (s + os[i & 3].x) | 0; } return s;
  });
  measure("object allocation (new Point)", function (n) { var p; for (var i = 0; i < n; i++) { p = new Point(i, i); } return p.x; });
  measure("array read (a[i & 1023])", function (n) { var a = []; for (var k = 0; k < 1024; k++) { a.push(k); } var s = 0; for (var i = 0; i < n; i++) { s = (s + a[i & 1023]) | 0; } return s; });
  measure("array write (a[i & 1023] = i)", function (n) { var a = new Array(1024).fill(0); for (var i = 0; i < n; i++) { a[i & 1023] = i; } return a[5]; });
  measure("typed array (Int32Array sum)", function (n) { var a = new Int32Array(1024); for (var k = 0; k < 1024; k++) { a[k] = k; } var s = 0; for (var i = 0; i < n; i++) { s = (s + a[i & 1023]) | 0; } return s; });
  measure("string concat + charCodeAt", function (n) { var s = "", h = 0; for (var i = 0; i < n; i++) { if ((i & 255) === 0) { s = ""; } s += "a"; h = (h + s.charCodeAt(s.length - 1)) | 0; } return h; });
  measure("global variable read/write", function (n) { globalThis.__g = 0; for (var i = 0; i < n; i++) { __g = __g + 1; } return __g; });
  measure("switch on small ints", function (n) { var s = 0; for (var i = 0; i < n; i++) { switch (i & 3) { case 0: s += 1; break; case 1: s += 3; break; case 2: s ^= 5; break; default: s -= 1; } } return s; });
  measure("Math.floor / Math.abs", function (n) { var s = 0; for (var i = 0; i < n; i++) { s += Math.floor(Math.abs(i * 0.5 - 3)); } return s; });
  measure("for-of over an array (per element)", function (n) { var a = []; for (var k = 0; k < 256; k++) { a.push(k); } var s = 0, m = n >> 8; for (var r = 0; r < m; r++) { for (var v of a) { s += v; } } return s; });
  measure("try/catch in a loop (no throw)", function (n) { var s = 0; for (var i = 0; i < n; i++) { try { s += i; } catch (e) { s = 0; } } return s; });
  console.log("MICRO\tchecksum\t" + check);
})();
