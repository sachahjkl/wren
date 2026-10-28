var text = "The quick brown fox jumps over the lazy dog 12345 times, then 678 more; foo@example.com bar_baz-9.";
var c = 0, re = /[a-z]+/g, m, re2 = /\d+/, s;
for (var i = 0; i < 100000; i++) {
  re.lastIndex = 0;
  while ((m = re.exec(text)) !== null) { c += m[0].length; }
  if (re2.test(text)) { c++; }
  s = text.replace(/o/g, "0");
}
console.log(c, s.length);
