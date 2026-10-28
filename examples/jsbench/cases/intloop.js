function f(n) { var s = 0; for (var i = 0; i < n; i++) { s = (s + i) | 0; } return s; }
var t = 0;
for (var k = 0; k < 20; k++) { t += f(10000000); }
console.log(t);
