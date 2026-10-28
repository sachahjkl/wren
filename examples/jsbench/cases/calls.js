function fib(k) { return k < 2 ? k : fib(k - 1) + fib(k - 2); }
function Point(x, y) { this.x = x; this.y = y; }
Point.prototype.norm2 = function () { return this.x * this.x + this.y * this.y; };
var s = fib(32), p, o = new Point(3, 4), t = 0;
for (var i = 0; i < 5000000; i++) { p = new Point(i, i); t = (t + o.norm2() + p.x) | 0; }
console.log(s, t);
