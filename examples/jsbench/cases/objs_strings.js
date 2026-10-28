var o = { a: 1, b: 2, c: 3, d: 4, e: 5 }, c = 0;
var text = "The quick brown fox jumps over the lazy dog 12345 times, then 678 more; foo@example.com bar_baz-9.";
for (var i = 0; i < 300000; i++) {
  c += Object.keys(o).length;
  for (var k in o) { c += o[k]; }
  c += text.split(" ").join("-").length;
  var p = { a: i, b: i + 1, c: "x" };
  c += p.b;
}
console.log(c);
