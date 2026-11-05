// Code of the kinds that stayed interpreted on real pages (docs/performance.md, round 28): `jsengine reach` runs this and
// fails when it was refused, or when the interpreter's checks are not mostly in compiled code.
(function () {
  "use strict";
  var RUN = 60000;
  var items = [];
  for (var i = 0; i < 64; i++) { var o = {}; o["k" + i] = i; o.v = i; o.t = "tag" + (i & 3); items.push(o); }   // more shapes than a site takes
  function blockList(url, list) {   // a try in the loop, natives on strings
    var found = null;
    for (var i = 0; i < list.length; i++) {
      var k = list[i];
      try { if (k.t === url) { found = k; break; } } catch (e) { found = e; }
      if (k.t.indexOf("x") !== -1) { found = k; }
    }
    return found;
  }
  function closures(n) { var s = 0; for (var i = 0; i < n; i++) { var f = function () { return i; }; s += f(); } return s; }
  function kinds(v) { var s = 0; for (var i = 0; i < 8; i++) { if (typeof v === "object" && v instanceof Array) { s += 1; } else if ("length" in Object(v)) { s += 2; } } return s; }
  function forOf(a) { var s = 0; for (var x of a) { s += x; } return s; }
  function nested(n) { var s = 0; for (var i = 0; i < n; i++) { for (var j = 0; j < 3; j++) { s += i ^ j; } } return s; }
  function lets(n) { var s = 0; for (var i = 0; i < n; i++) { let a = i; const b = a + 1; s += b; } return s; }
  function poly(n) { var s = 0; for (var i = 0; i < n; i++) { s += items[i & 63].v; } return s; }
  var callees = [function (x) { return x + 1; }, function (x) { return x + 2; }, function (x) { return x + 3; }, function (x) { return x + 4; }, function (x) { return x + 5; }, function (x) { return x + 6; }];
  function manyCallees(n) { var s = 0; for (var i = 0; i < n; i++) { s += callees[i % 6](i); } return s; }
  var sum = 0;
  for (var r = 0; r < RUN / 60; r++) {
    sum += blockList("none", items) === null ? 1 : 0;
    sum += closures(20) + kinds(r & 1 ? [] : "s") + forOf([1, 2, 3]) + nested(10) + lets(10) + poly(40) + manyCallees(40);
  }
  console.log(sum);
})();
