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
	["a method that reads this", 2700, function (n) {var o = {a: 1, x: 2, m: method_this}; for (var i = 0; i < n; i++) o.m();}],
	["o[\"x\"] is o.x", 3200, function (n) {var o = {a: 1, x: 2, m: bracket}; for (var i = 0; i < n; i++) o.m();}],
	["a hash on doubles", 3800, function (n) {var h = 7; for (var i = 0; i < n; i++) h = hash_step(h);}],
	["return f()", 3450, function (n) {for (var i = 0; i < n; i++) returns_a_call(i);}],
	["a string's length", 1200, function (n) {for (var i = 0; i < n; i++) sink = text.length;}],
	["=== of strings and values", 4200, function (n) {var a = "x", b = "y"; for (var i = 0; i < n; i++) {not_equal(a, b); not_equal(a, null);}}],
	["typeof", 1350, function (n) {for (var i = 0; i < n; i++) sink = typeof text;}],
	["{a, b, c}", 3050, function (n) {for (var i = 0; i < n; i++) sink = {a: 1, b: 2, c: 3};}],
	["a function expression", 3650, function (n) {for (var i = 0; i < n; i++) sink = function () {};}],
	["an arrow function", 3700, function (n) {for (var i = 0; i < n; i++) sink = () => i;}],
	["arguments of a sloppy function", 5600, function (n) {for (var i = 0; i < n; i++) count_arguments(i);}],
];
