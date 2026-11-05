// Babel's object spread, as pages ship it: `{...a, b: 1}` compiled for old browsers, each key through
// Object.keys, Object.getOwnPropertySymbols, a filter, forEach and a helper that defines it.
// `jsengine run examples/jsbench/objectspread.js` against `node examples/jsbench/objectspread.js`.
var print = typeof console !== "undefined" ? console.log : globalThis.print;

var ROUNDS = 40000;

function to_key(k) {return typeof k === "symbol" ? k : String(k);}
function define(o, k, v) {
	k = to_key(k);
	if (k in o) Object.defineProperty(o, k, {value: v, enumerable: true, configurable: true, writable: true});
	else o[k] = v;
	return o;
}
function keys_of(o, enumerable) {
	var keys = Object.keys(o);
	if (Object.getOwnPropertySymbols) {
		var symbols = Object.getOwnPropertySymbols(o);
		if (enumerable) symbols = symbols.filter(function (s) {return Object.getOwnPropertyDescriptor(o, s).enumerable;});
		keys.push.apply(keys, symbols);
	}
	return keys;
}
function spread(target) {
	for (var i = 1; i < arguments.length; i++) {
		var source = arguments[i] != null ? arguments[i] : {};
		if (i % 2) keys_of(Object(source), true).forEach(function (k) {define(target, k, source[k]);});
		else if (Object.getOwnPropertyDescriptors) Object.defineProperties(target, Object.getOwnPropertyDescriptors(source));
		else keys_of(Object(source)).forEach(function (k) {Object.defineProperty(target, k, Object.getOwnPropertyDescriptor(source, k));});
	}
	return target;
}

var base = {id: 1, name: "vendor", purposes: [1, 2, 3], legitimate: null, flexible: false, cookie: 12, url: "x", features: []};
var more = {stacks: 2, special: true, policy: "y"};
var t0 = Date.now();
var total = 0;
for (var r = 0; r < ROUNDS; r++) {
	var o = spread({}, base, more);
	o = spread(spread({}, o), {}, {id: r});
	total += o.id + Object.keys(o).length;
}
var ms = Date.now() - t0;
print("total " + total + " in " + ms + " ms, " + (ms * 1e6 / ROUNDS).toFixed(0) + " ns a round");
