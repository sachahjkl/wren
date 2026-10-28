function* g(k) { for (var i = 0; i < k; i++) { yield i; } }
var c = 0;
for (var i = 0; i < 2000000; i++) { var f = function () { return i; }; c += f(); }
for (var v of g(2000000)) { c += v; }
function f2() { return arguments.length; }
function g2(...r) { return r.length; }
var a = [1, 2, 3];
for (var i = 0; i < 500000; i++) { c += f2(1, 2) + g2(1, 2, 3) + Math.max(...a); var arr = [i, i + 1, i + 2]; c += arr.length; }
console.log(c);
