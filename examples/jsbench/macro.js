// Engine macro-benchmarks (no DOM): library-heavy shapes that micro.js does not time (JSON, regexp, strings, array
// methods, Map/Set, classes, generators, closures, exceptions). Same output format as micro.js, so
// tools\jsrt_ab.ps1 -Script examples\jsbench\macro.js compares builds. ns per iteration of the body.
(function () {
  "use strict";
  var CALIBRATE_MS = 150, MEASURE_RUNS = 3;
  var now = Date.now;
  var check = 0;
  function measure(name, body) {
    var r = body(300);
    check = (check * 31 + (typeof r === "number" ? (r % 1000003) | 0 : String(r).length)) | 0;
    var n = 64, t = 0;
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

  var sample = { id: 1, name: "wren", tags: ["a", "b", "c"], nested: { x: 1.5, y: [1, 2, 3, { z: null }], ok: true }, text: "hello \"world\"\n" };
  var sampleJson = JSON.stringify(sample);
  measure("JSON.parse (small object)", function (n) { var o; for (var i = 0; i < n; i++) { o = JSON.parse(sampleJson); } return o.id; });
  measure("JSON.stringify (small object)", function (n) { var s; for (var i = 0; i < n; i++) { s = JSON.stringify(sample); } return s; });

  var text = "The quick brown fox jumps over the lazy dog 12345 times, then 678 more; foo@example.com bar_baz-9.";
  measure("regexp test /\\d+/", function (n) { var c = 0, re = /\d+/; for (var i = 0; i < n; i++) { if (re.test(text)) { c++; } } return c; });
  measure("regexp exec global loop", function (n) { var c = 0, re = /[a-z]+/g, m; for (var i = 0; i < n; i++) { re.lastIndex = 0; while ((m = re.exec(text)) !== null) { c += m[0].length; } } return c; });
  measure("string replace /o/g", function (n) { var s; for (var i = 0; i < n; i++) { s = text.replace(/o/g, "0"); } return s; });
  measure("string split + join", function (n) { var s; for (var i = 0; i < n; i++) { s = text.split(" ").join("-"); } return s; });
  measure("indexOf / slice / toUpperCase", function (n) { var c = 0; for (var i = 0; i < n; i++) { c += text.indexOf("lazy") + text.slice(4, 20).length + text.toUpperCase().length; } return c; });
  measure("template literal + number toString", function (n) { var s; for (var i = 0; i < n; i++) { s = `item-${i}:${i * 2}`; } return s; });
  measure("parseInt / parseFloat", function (n) { var c = 0; for (var i = 0; i < n; i++) { c += parseInt("12345", 10) + parseFloat("3.25"); } return c; });

  var arr256 = []; for (var q = 0; q < 256; q++) { arr256.push((q * 7919) % 257); }
  measure("array map+filter+reduce (256)", function (n) { var c = 0, m = (n >> 8) + 1; for (var r = 0; r < m; r++) { c += arr256.map(function (x) { return x * 2; }).filter(function (x) { return x & 2; }).reduce(function (a, b) { return a + b; }, 0); } return c; });
  measure("array sort with comparator (256)", function (n) { var c = 0, m = (n >> 8) + 1; for (var r = 0; r < m; r++) { var a = arr256.slice(); a.sort(function (x, y) { return x - y; }); c += a[10]; } return c; });
  measure("array push/pop", function (n) { var a = [], c = 0; for (var i = 0; i < n; i++) { a.push(i); if ((i & 7) === 7) { c += a.pop() + a.pop(); } } return c + a.length; });
  measure("array forEach (per element)", function (n) { var c = 0, m = (n >> 8) + 1; for (var r = 0; r < m; r++) { arr256.forEach(function (x) { c += x; }); } return c; });
  measure("array literal [i, i+1, i+2]", function (n) { var a; for (var i = 0; i < n; i++) { a = [i, i + 1, i + 2]; } return a[1]; });
  measure("object literal {a, b, c}", function (n) { var o; for (var i = 0; i < n; i++) { o = { a: i, b: i + 1, c: "x" }; } return o.b; });
  measure("Object.keys + for-in (5 props)", function (n) { var o = { a: 1, b: 2, c: 3, d: 4, e: 5 }, c = 0; for (var i = 0; i < n; i++) { c += Object.keys(o).length; for (var k in o) { c += o[k]; } } return c; });
  measure("Map set/get (int keys)", function (n) { var m = new Map(), c = 0; for (var i = 0; i < n; i++) { m.set(i & 1023, i); c += m.get((i * 7) & 1023) | 0; } return c; });
  measure("Set add/has (string keys)", function (n) { var s = new Set(), keys = []; for (var k = 0; k < 64; k++) { keys.push("key" + k); } var c = 0; for (var i = 0; i < n; i++) { s.add(keys[i & 63]); if (s.has(keys[(i * 5) & 63])) { c++; } } return c; });
  measure("dynamic property key (o[k])", function (n) { var o = { alpha: 1, beta: 2, gamma: 3, delta: 4 }, ks = ["alpha", "beta", "gamma", "delta"], c = 0; for (var i = 0; i < n; i++) { c += o[ks[i & 3]]; } return c; });

  class Base { constructor(v) { this.v = v; } get double() { return this.v * 2; } inc() { this.v++; return this; } }
  class Derived extends Base { constructor(v) { super(v); this.w = 1; } inc() { super.inc(); this.w++; return this; } }
  measure("class new + super call", function (n) { var d, c = 0; for (var i = 0; i < n; i++) { d = new Derived(i); d.inc(); c += d.w; } return c; });
  measure("getter access", function (n) { var b = new Base(3), c = 0; for (var i = 0; i < n; i++) { c += b.double; } return c; });
  measure("closure creation + call", function (n) { var c = 0; for (var i = 0; i < n; i++) { var f = function () { return i; }; c += f(); } return c; });
  measure("arguments / rest / spread", function (n) { function f() { return arguments.length; } function g(...r) { return r.length; } var c = 0, a = [1, 2, 3]; for (var i = 0; i < n; i++) { c += f(1, 2) + g(1, 2, 3) + Math.max(...a); } return c; });
  measure("destructuring", function (n) { var c = 0, o = { a: 1, b: 2 }, a = [3, 4]; for (var i = 0; i < n; i++) { var { a: x, b: y } = o; var [p, q] = a; c += x + y + p + q; } return c; });
  measure("generator (per yield)", function (n) { function* g(k) { for (var i = 0; i < k; i++) { yield i; } } var c = 0; for (var v of g(n)) { c += v; } return c; });
  measure("throw + catch", function (n) { var c = 0; for (var i = 0; i < n; i++) { try { throw new Error("x"); } catch (e) { c++; } } return c; });
  measure("string compare / switch on strings", function (n) { var ks = ["a", "bb", "ccc", "dddd"], c = 0; for (var i = 0; i < n; i++) { switch (ks[i & 3]) { case "a": c += 1; break; case "bb": c += 2; break; case "ccc": c += 3; break; default: c += 4; } } return c; });
  measure("Math.sin / sqrt / pow", function (n) { var c = 0; for (var i = 0; i < n; i++) { c += Math.sin(i) + Math.sqrt(i) + Math.pow(i, 0.5); } return c | 0; });
  measure("Float64Array fill + sum (256)", function (n) { var a = new Float64Array(256), c = 0, m = (n >> 8) + 1; for (var r = 0; r < m; r++) { for (var i = 0; i < 256; i++) { a[i] = i * 0.5; } for (var j = 0; j < 256; j++) { c += a[j]; } } return c | 0; });
  console.log("MICRO\tchecksum\t" + check);
})();
