// JavaScript engine benchmarks shaped like application code (no DOM): records parsed and summed, objects updated in
// place, a sort with a comparator, a tokenizer, small classes with methods.
//   build\jsengine.exe run examples\jsbench\realworld.js        (Wren's engine; add -jit for the JIT)
//   qjs examples\jsbench\realworld.js, node, d8...               (any shell with console.log)
// One line per case: "MICRO<TAB>name<TAB>ns per iteration" (an iteration is one item: a record, an object, a
// comparison's element, a character, a call), the format of micro.js and macro.js; a checksum line ends the output.
(function () {
  "use strict";
  var CALIBRATE_MS = 150, MEASURE_RUNS = 3;
  var now = Date.now;
  var check = 0;
  function measure(name, body) {
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

  // records: a JSON document of 200 records, parsed, then its fields summed and filtered
  var recs = [];
  for (var q = 0; q < 200; q++) { recs.push({ id: q, name: "item" + q, price: (q * 37) % 101 + 0.5, tags: ["a", "b"], stock: q % 7, active: q % 3 !== 0 }); }
  var doc = JSON.stringify(recs);
  measure("JSON records: parse + sum (per record)", function (n) {
    var s = 0, m = (n / 200 | 0) + 1;
    for (var r = 0; r < m; r++) {
      var a = JSON.parse(doc);
      for (var i = 0; i < a.length; i++) { var e = a[i]; if (e.active && e.stock > 1) { s += e.price * e.stock; } }
    }
    return s | 0;
  });
  var parsed = JSON.parse(doc);
  measure("JSON records: sum of parsed records (per record)", function (n) {
    var s = 0;
    for (var i = 0; i < n; i++) { var e = parsed[i % 200]; if (e.active) { s += e.price * e.stock + e.id; } }
    return s | 0;
  });

  // particles: objects updated in place, doubles, a bounce
  function Particle(i) { this.x = i % 97; this.y = i % 89; this.vx = (i % 7) - 3.5; this.vy = (i % 5) - 2.25; }
  var ps = []; for (var k = 0; k < 1000; k++) { ps.push(new Particle(k)); }
  measure("particles: update (per particle)", function (n) {
    var m = (n / 1000 | 0) + 1, e = 0;
    for (var r = 0; r < m; r++) {
      for (var i = 0; i < ps.length; i++) {
        var p = ps[i];
        p.x += p.vx * 0.016; p.y += p.vy * 0.016;
        if (p.x < 0 || p.x > 100) { p.vx = -p.vx; }
        if (p.y < 0 || p.y > 100) { p.vy = -p.vy; }
        e += p.vx * p.vx + p.vy * p.vy;
      }
    }
    return e | 0;
  });

  // a sort with a comparator, of objects by a key
  var keyed = []; for (var j = 0; j < 500; j++) { keyed.push({ k: (j * 7919) % 1009, v: j }); }
  measure("sort of objects with a comparator (per element)", function (n) {
    var c = 0, m = (n / 500 | 0) + 1;
    for (var r = 0; r < m; r++) { var a = keyed.slice(); a.sort(function (x, y) { return x.k - y.k; }); c += a[r % 500].v; }
    return c;
  });

  // a tokenizer: characters classified by their codes, tokens counted
  var src = ""; for (var w = 0; w < 50; w++) { src += "let x" + w + " = foo(" + w + ", 'str') + 12.5 * bar[" + w + "];\n"; }
  measure("tokenizer over charCodeAt (per character)", function (n) {
    var tokens = 0, m = (n / src.length | 0) + 1;
    for (var r = 0; r < m; r++) {
      var inWord = false;
      for (var i = 0; i < src.length; i++) {
        var ch = src.charCodeAt(i);
        var word = (ch >= 97 && ch <= 122) || (ch >= 48 && ch <= 57) || ch === 95;
        if (word && !inWord) { tokens++; }
        if (!word && ch > 32) { tokens++; }
        inWord = word;
      }
    }
    return tokens;
  });

  // small classes with methods, called in a loop
  class Vec { constructor(x, y) { this.x = x; this.y = y; } dot(o) { return this.x * o.x + this.y * o.y; } len2() { return this.dot(this); } }
  var vs = []; for (var z = 0; z < 64; z++) { vs.push(new Vec(z % 9, z % 5)); }
  measure("methods of a class (per call)", function (n) {
    var s = 0;
    for (var i = 0; i < n; i++) { s = (s + vs[i & 63].len2()) | 0; }
    return s;
  });

  console.log("MICRO\tchecksum\t" + check);
})();
