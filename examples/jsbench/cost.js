// What pages run often, in Wasm instructions an iteration, interpreted: `jsengine cost --pref wasm.wasmtime.fuel=true examples/jsbench/cost.js`
// (the limits are about a tenth over what the engine costs: a case over its limit is a path that got longer, or left the interpreter's hot loop).
var sink;
var text = "abcdefghij";
function hash_step(h) {return (h & 0xffff) * 0xcc9e2d51 + (((h >>> 16) * 0xcc9e2d51 & 0xffff) << 16) & 0xffffffff;}
function method_this() {return this.x;}
function bracket() {this["x"] = this["x"] ^ 5;}
function pass(a) {return a;}
function returns_a_call(a) {return pass(a);}
function count_arguments(a) {return arguments.length + a;}
function not_equal(a, b) {return a === b;}

var COST_CASES = [
	["a method that reads this", 1850, function (n) {var o = {a: 1, x: 2, m: method_this}; for (var i = 0; i < n; i++) o.m();}],
	["o[\"x\"] is o.x", 2150, function (n) {var o = {a: 1, x: 2, m: bracket}; for (var i = 0; i < n; i++) o.m();}],
	["a hash on doubles", 2700, function (n) {var h = 7; for (var i = 0; i < n; i++) h = hash_step(h);}],
	["return f()", 2650, function (n) {for (var i = 0; i < n; i++) returns_a_call(i);}],
	["a string's length", 700, function (n) {for (var i = 0; i < n; i++) sink = text.length;}],
	["=== of strings and values", 3150, function (n) {var a = "x", b = "y"; for (var i = 0; i < n; i++) {not_equal(a, b); not_equal(a, null);}}],
	["typeof", 850, function (n) {for (var i = 0; i < n; i++) sink = typeof text;}],
	["{a, b, c}", 2100, function (n) {for (var i = 0; i < n; i++) sink = {a: 1, b: 2, c: 3};}],
	["a function expression", 2100, function (n) {for (var i = 0; i < n; i++) sink = function () {};}],
	["an arrow function", 2200, function (n) {for (var i = 0; i < n; i++) sink = () => i;}],
	["arguments of a sloppy function", 3550, function (n) {for (var i = 0; i < n; i++) count_arguments(i);}],
];

// Objects used as maps: each first key a transition of the shape of `{}`, which every object literal starts from.
var first_keys = [];
for (var i = 0; i < 3000; i++) {var o = {}; o["first" + i] = i; first_keys.push(o);}
COST_CASES.push(["{a} beside 3000 first keys", 1650, function (n) {for (var i = 0; i < n; i++) sink = {a: 1};}]);

// What a page's natives and callbacks cost: on a fast array without the object protocol, what a promise or an iterator holds from the pool.
var numbers = [1, 2, 3, 4, 5, 6, 7, 8];
var eight = {a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8};
function no_op() {}
function always() {return true;}
COST_CASES.push(["slice of 8", 4650, function (n) {for (var i = 0; i < n; i++) sink = numbers.slice(2);}]);
COST_CASES.push(["concat of 8 and 8", 8650, function (n) {for (var i = 0; i < n; i++) sink = numbers.concat(numbers);}]);
COST_CASES.push(["forEach over 8", 12300, function (n) {for (var i = 0; i < n; i++) numbers.forEach(no_op);}]);
COST_CASES.push(["filter over 8", 16800, function (n) {for (var i = 0; i < n; i++) sink = numbers.filter(always);}]);
COST_CASES.push(["new Promise", 6200, function (n) {for (var i = 0; i < n; i++) sink = new Promise(no_op);}]);
COST_CASES.push(["{...o} of 8", 4700, function (n) {for (var i = 0; i < n; i++) sink = {...eight};}]);
COST_CASES.push(["a function called", 1250, function (n) {var f = no_op; for (var i = 0; i < n; i++) f();}]);
function Fields() {this.a = 1; this.b = 2; this.c = 3;}
COST_CASES.push(["new with three fields", 4350, function (n) {for (var i = 0; i < n; i++) sink = new Fields();}]);
var run_of_text = "https://example.com/a-long-path-of-an-article/with?utm_source=abc&utm_medium=social&id=0123456789#fragment";
var email_like = /\S+(@|%40)\S+\.\S+/;
var vendor = 1234;
COST_CASES.push(["a number made a string, again", 2300, function (n) {for (var i = 0; i < n; i++) sink = vendor.toString() + ":true";}]);
var pairs = [[1, 2], [3, 4]];
COST_CASES.push(["destructured pairs", 5400, function (n) {for (var i = 0; i < n; i++) {var [a, b] = pairs[i & 1]; sink = a + b;}}]);
var counted = new Map([[1, 1], [2, 2], [3, 3]]);
COST_CASES.push(["a map's entries by next()", 5200, function (n) {for (var i = 0; i < n; i++) {var it = counted.values(); sink = it.next().value + it.next().value;}}]);
COST_CASES.push(["a search that starts with a run", 133000, function (n) {for (var i = 0; i < n; i++) sink = email_like.test(run_of_text);}]);
