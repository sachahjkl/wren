// What a loading page runs: many functions a few thousand times, loops a check of the interpreter falls on once or twice.
// `jsengine cold`: nothing here is hot enough to be compiled at the default thresholds.
var total = 0;
for (var k = 0; k < 40; k++) {
	var f = new Function("x", "return x + " + k);
	for (var i = 0; i < 3000; i++) total = f(total) % 1000;
}
for (var k = 0; k < 40; k++) {
	var g = new Function("n", "var s = 0; for (var i = 0; i < n; i++) s += i & " + k + "; return s");
	total += g(30000) % 1000;
}
