// Peak memory shape: 300 k small objects kept alive, 100 k Map entries, some strings and arrays (judge prints heap stats).
var keep = [];
for (var i = 0; i < 300000; i++) { keep.push({ id: i, name: "n" + i, tags: [i, i + 1] }); }
var m = new Map();
for (var j = 0; j < 100000; j++) { m.set("k" + j, { v: j }); }
var c = 0;
for (var k = 0; k < 300000; k += 7) { c += keep[k].tags[1] + m.get("k" + (k % 100000)).v; }
console.log(c);
