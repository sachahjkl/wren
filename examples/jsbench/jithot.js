// What is really hot: one loop, one function called all the time. `jsengine reach` at the default thresholds: compiled all the same.
function step(s, i) { return (s + (i & 7)) | 0; }
var s = 0;
for (var i = 0; i < 80000000; i++) s = step(s, i);
