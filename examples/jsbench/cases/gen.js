function* g(k) { for (var i = 0; i < k; i++) { yield i; } }
var c = 0;
for (var r = 0; r < 5; r++) { for (var v of g(1000000)) { c += v; } }
console.log(c);
