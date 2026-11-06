// What the interpreter's hot loop answers itself, against the language: each check throws when it is wrong. `jsengine run examples/jsbench/hotcheck.js`
// (the same file passes in Node: what it says is the language's, not this engine's).
function fail(message) {
	console.log("FAILED " + message);
	throw new Error(message);
}
function same(got, want, what) {
	if (!Object.is(got, want)) fail(what + ": got " + String(got) + ", want " + String(want));
}
function throws(f, type, what) {
	try {f();} catch (e) {
		if (e instanceof type) return;
		fail(what + ": threw " + e);
	}
	fail(what + ": did not throw");
}

// ToInt32 of doubles
var doubles = [
	[0.5, 0], [-0.5, 0], [1.9, 1], [-1.9, -1], [2147483648, -2147483648], [4294967296, 0], [4294967297, 1], [-2147483649, 2147483647],
	[9007199254740992, 0], [9007199254740994, 2], [-9007199254740994, -2], [1e21, -559939584], [-1e21, 559939584], [9223372036854775808, 0],
	[18446744073709551616, 0], [1e300, 0], [NaN, 0], [Infinity, 0], [-Infinity, 0], [-0, 0], [3000000000.7, -1294967296],
];
for (var i = 0; i < doubles.length; i++) {
	var d = doubles[i][0], w = doubles[i][1];
	same(d | 0, w, "or " + d);
	same(d & -1, w, "and " + d);
	same(d ^ 0, w, "xor " + d);
	same(d << 0, w, "shl " + d);
	same(d >> 0, w, "sar " + d);
	same(d >>> 0, w < 0 ? w + 4294967296 : w, "shr " + d);
	same(1 << d, 1 << (w & 31), "a shift by " + d);
}
same(0xffffffff & 0xffffffff, -1, "both doubles");
same(0xcc9e2d51 * 0xffff & 0xffffffff, 0xcc9e2d51 * 0xffff % 4294967296 - 4294967296 + 4294967296 | 0, "a product");
same("3" | 0, 3, "a string");
same(null | 0, 0, "null");
same(undefined | 1, 1, "undefined");
same(true << 2, 4, "a bool");
same(5n & 3n, 1n, "BigInts");
same({valueOf: function () {return 6.5;}} & 3, 2, "an object");

// equality
var o1 = {}, s1 = Symbol("a"), rope = "ab", rope2 = "a";
rope2 += "b";
var eq = [
	[1, 1, true, true], [1, 1.5, false, false], [1.5, 1.5, true, true], [NaN, NaN, false, false], [0, -0, true, true], [1, "1", false, true],
	[null, undefined, false, true], [undefined, undefined, true, true], [null, null, true, true], [null, 0, false, false], [undefined, 0, false, false],
	[null, false, false, false], ["", 0, false, true], [true, 1, false, true], [true, true, true, true], [false, true, false, false],
	[o1, o1, true, true], [o1, {}, false, false], [o1, "[object Object]", false, true], [s1, s1, true, true], [s1, Symbol("a"), false, false],
	["ab", "ab", true, true], ["ab", "ac", false, false], ["ab", "abc", false, false], [rope, rope2, true, true], [1n, 1, false, true], [1n, 1n, true, true],
	[1, 2, false, false], [2147483648, 2147483648, true, true], [1, 1.0, true, true],
];
for (var i = 0; i < eq.length; i++) {
	var e = eq[i];
	same(e[0] === e[1], e[2], "=== " + i);
	same(e[1] === e[0], e[2], "=== reversed " + i);
	same(e[0] !== e[1], !e[2], "!== " + i);
	same(e[0] == e[1], e[3], "== " + i);
	same(e[1] == e[0], e[3], "== reversed " + i);
	same(e[0] != e[1], !e[3], "!= " + i);
}

// this
function who() {return this;}
function strict_who() {"use strict"; return this;}
same(who.call(o1), o1, "an object");
same(who.call(undefined), globalThis, "sloppy undefined");
same(who.call(null), globalThis, "sloppy null");
same(typeof who.call(1), "object", "sloppy number");
same(typeof who.call("a"), "object", "sloppy string");
same(strict_who.call(undefined), undefined, "strict undefined");
same(strict_who.call(1), 1, "strict number");

// a["b"] is a.b
var obj = {x: 1, "a b": 2, 1: 3, "": 4, length: 5};
same(obj["x"], 1, "a name");
same(obj["a b"], 2, "not a name");
same(obj["1"], 3, "an index");
same(obj[""], 4, "the empty string");
obj["x"] = 7;
same(obj.x, 7, "written");
obj["x"]++;
same(obj.x, 8, "incremented");
obj["x"] += 2;
same(obj.x, 10, "added to");
same(delete obj["x"], true, "deleted");
same(obj.x, undefined, "gone");
same("abc"["length"], 3, "a string's length");
same([1, 2]["length"], 2, "an array's length");
same("abc"["0"], "a", "a string's index");
same("abc"["charAt"](1), "b", "a string's method");
same(obj?.["a b"], 2, "an optional chain");
same(null?.["a"], undefined, "an optional chain of null");
same(obj["toString"]() === "[object Object]", true, "a method");
same({m: function () {return this.y;}, y: 3}["m"](), 3, "this of a method");
throws(function () {return null["a"];}, TypeError, "null");
throws(function () {undefined["a"] = 1;}, TypeError, "undefined");
var order = [];
function key() {order.push("key"); return "k";}
(function () {var t = {}; t[(order.push("first"), "k")] = (order.push("second"), 1); same(t.k, 1, "a comma");})();
same(order.join(), "first,second", "the order");
var u8 = new Uint8Array(2);
u8["1"] = 300;
same(u8[1], 44, "a typed array");
same(u8["foo"], undefined, "a name on a typed array");
class Base {get v() {return 1;} m() {return 2;}}
class Derived extends Base {m() {return super["m"]() + super["v"];}}
same(new Derived().m(), 3, "super");

// lengths and reads the engine makes
same("".length, 0, "an empty string");
same(("a" + "b".repeat(3)).length, 4, "a rope");
same("é€".length, 2, "wide");
same((function () {return arguments.length;})(1, 2, 3), 3, "arguments");
same({length: 9}.length, 9, "a plain object");
same(new Uint8Array(3).length, 3, "a typed array");
same((function (a, b) {}).length, 2, "a function");
throws(function () {return null.length;}, TypeError, "null's length");
throws(function () {var u; return u.x;}, TypeError, "undefined's property");
same((1).toFixed(1), "1.0", "a number's method");
same(true.toString(), "true", "a bool's method");
same(Symbol("q").description, "q", "a symbol's getter");
same("x".nothing, undefined, "a string has no such");
same([].nothing, undefined, "an array has no such");
same([1].concat([2]).length, 2, "an array's method");
Array.prototype.extra = function () {return this.length;};
same([1, 2, 3].extra(), 3, "a method added to Array.prototype");
delete Array.prototype.extra;
Object.prototype[7] = "seven";
same([1][7], "seven", "an element on the prototype");
same("x"[7], "seven", "an element on the prototype of a string");
delete Object.prototype[7];
var getter_this;
Object.defineProperty(String.prototype, "self", {get: function () {"use strict"; getter_this = this; return 1;}, configurable: true});
same("abc".self, 1, "a getter of String.prototype");
same(getter_this, "abc", "its this");
delete String.prototype.self;
var px = new Proxy({a: 1}, {get: function (t, k) {return k === "a" ? 2 : t[k];}});
same(px.a, 2, "a proxy");
same(px["a"], 2, "a proxy, the name as a string");
var thrower = {get a() {throw new RangeError("x");}};
throws(function () {return thrower.a;}, RangeError, "a getter that throws");
throws(function () {return thrower["a"];}, RangeError, "the same by name");
var key_of = {toString: function () {return "z";}};
same({z: 1}[key_of], 1, "a key to convert");
var el = [1, 2, 3], ta = new Int16Array([5, 6]);
same(el[1], 2, "an element");
same(el[3], undefined, "past the end");
same(el[-1], undefined, "a negative index");
same(el[1.5], undefined, "a fraction");
same(el["1"], 2, "an index as a string");
same(ta[1], 6, "a typed array's element");
same(ta[2], undefined, "past a typed array");
same("abc"[1], "b", "a string's element");
same("abc"[3], undefined, "past a string");
function calls_element(a) {return a[0]();}
same(calls_element([who]) === globalThis, false, "this of a[0]()");

// writes
var frozen = Object.freeze({a: 1});
frozen.a = 2;
frozen.b = 2;
same(frozen.a, 1, "a frozen property");
same(frozen.b, undefined, "a frozen object");
throws(function () {"use strict"; frozen.a = 2;}, TypeError, "strict, frozen");
throws(function () {"use strict"; frozen.b = 2;}, TypeError, "strict, a new one");
var set_seen;
var with_setter = {set a(v) {set_seen = v;}};
with_setter.a = 3;
same(set_seen, 3, "a setter");
var child = Object.create(with_setter);
child.a = 4;
same(set_seen, 4, "a setter on the prototype");
same(Object.keys(child).length, 0, "nothing own");
var ro = Object.create(Object.defineProperty({}, "r", {value: 1}));
ro.r = 2;
same(ro.r, 1, "read only on the prototype");
"str".x = 1;
throws(function () {"use strict"; "str".x = 1;}, TypeError, "a property of a string, strict");
var arr = [1, 2];
arr.length = 1;
same(arr.length, 1, "an array's length written");
arr.extra = 1;
same(arr.extra, 1, "a property of an array");

// literals
var lit = {a: 1, b: 2, a: 3};
same(Object.keys(lit).join(), "a,b", "a key twice");
same(lit.a, 3, "the last value");
var desc = Object.getOwnPropertyDescriptor({q: 1}, "q");
same(desc.writable && desc.enumerable && desc.configurable, true, "a field's attributes");
same(Object.keys({b: 1, 2: 1, a: 1, 1: 1}).join(), "1,2,b,a", "the order of keys");
same({__proto__: null, a: 1}.toString, undefined, "__proto__");
same(Object.getPrototypeOf({__proto__: Array.prototype}), Array.prototype, "__proto__ set");
var big = {};
for (var i = 0; i < 100; i++) big["k" + i] = i;
same(Object.keys(big).length, 100, "past the shared shapes");
class Fields {a = 1; ["b"] = 2; static c = 3;}
same(new Fields().a + new Fields().b + Fields.c, 6, "class fields");
same([1, , 3].length, 3, "a hole");
same(1 in [1, , 3], false, "the hole");
same([...[1, 2], 3].length, 3, "a spread");

// typeof
same(typeof undefined, "undefined", "undefined");
same(typeof null, "object", "null");
same(typeof 1, "number", "number");
same(typeof 1n, "bigint", "bigint");
same(typeof "", "string", "string");
same(typeof Symbol(), "symbol", "symbol");
same(typeof {}, "object", "object");
same(typeof who, "function", "function");
same(typeof class {}, "function", "class");
same(typeof not_declared, "undefined", "not declared");
var tdz = false;
try {typeof later; let later = 1;} catch (e) {tdz = e instanceof ReferenceError;}
same(tdz, true, "typeof in the temporal dead zone");

// closures: what make_closure gives each kind
function plain_fn(a, b) {}
var anon = function () {};
var arrow = (a) => a;
function* gen(a) {}
async function asy() {}
async function* agen() {}
same(Object.getOwnPropertyNames(plain_fn).join(), Object.getOwnPropertyNames(function (a, b) {}).join(), "the same keys");
same(plain_fn.length, 2, "length");
same(plain_fn.name, "plain_fn", "name");
same(anon.name, "anon", "a name given");
same((function () {}).name, "", "no name");
same(plain_fn.prototype.constructor, plain_fn, "prototype.constructor");
same(Object.getPrototypeOf(plain_fn.prototype), Object.prototype, "the prototype's prototype");
same(Object.keys(plain_fn.prototype).length, 0, "constructor does not enumerate");
same(JSON.stringify(Object.getOwnPropertyDescriptor(plain_fn, "prototype")), '{"value":{},"writable":true,"enumerable":false,"configurable":false}', "prototype's attributes");
same(JSON.stringify(Object.getOwnPropertyDescriptor(plain_fn, "length")), '{"value":2,"writable":false,"enumerable":false,"configurable":true}', "length's attributes");
same(JSON.stringify(Object.getOwnPropertyDescriptor(plain_fn, "name")), '{"value":"plain_fn","writable":false,"enumerable":false,"configurable":true}', "name's attributes");
same(JSON.stringify(Object.getOwnPropertyDescriptor(plain_fn.prototype, "constructor").enumerable), "false", "constructor's attributes");
same("prototype" in arrow, false, "an arrow has none");
same(arrow.length, 1, "an arrow's length");
same("prototype" in asy, false, "an async function has none");
same(Object.getPrototypeOf(gen), Object.getPrototypeOf(function* () {}), "a generator's prototype");
same(Object.getPrototypeOf(gen.prototype), Object.getPrototypeOf(function* () {}).prototype, "a generator's prototype object");
same(Object.getOwnPropertyDescriptor(gen, "prototype").writable, true, "written");
same(Object.prototype.hasOwnProperty.call(gen.prototype, "constructor"), false, "no constructor of its own");
same(Object.getPrototypeOf(agen.prototype), Object.getPrototypeOf(async function* () {}).prototype, "an async generator's");
same(new plain_fn() instanceof plain_fn, true, "a construction");
throws(function () {new arrow();}, TypeError, "an arrow is no constructor");
plain_fn.prototype = {replaced: true};
same(new plain_fn().replaced, true, "a prototype replaced");
var marked = function () {};
marked.extra = 1;
Object.defineProperty(marked, "name", {value: "other"});
same(marked.name, "other", "a name redefined");
same(delete marked.length, true, "length deleted");
same(marked.length, 0, "from Function.prototype");
same((function () {}).length, 0, "the next one has its own");

// return f()
function pass(a) {return a;}
function returns_a_call(a) {return pass(a);}
function returns_a_method(o) {return o.m(1);}
same(returns_a_call(4), 4, "return f()");
same(returns_a_method({m: function (a) {return this === undefined ? 0 : a + 1;}}), 2, "return o.m()");
same(returns_a_call.call(null, 5), 5, "called with call");
function native_tail(a) {return Math.abs(a);}
same(native_tail(-3), 3, "a native");
function ctor_tail() {return new Date(0).getTime();}
same(ctor_tail(), 0, "a method of what was made");
function deep(n) {return n === 0 ? 0 : deep(n - 1);}
same(deep(5000), 0, "a recursion");
function throwing_tail() {return null.x();}
throws(throwing_tail, TypeError, "what it calls throws");
function* gen_tail() {return pass(1);}
same(gen_tail().next().value, 1, "in a generator");
async function async_tail() {return pass(1);}
async_tail().then(function (v) {same(v, 1, "in an async function");});
var trace_seen = (function outer() {return (function inner() {return new Error("x").stack;})();})();
same(typeof trace_seen, "string", "a stack");

// mapped arguments
function aliased(a, b) {
	arguments[0] = 9;
	same(a, 9, "arguments written");
	b = 8;
	same(arguments[1], 8, "the parameter written");
	return arguments.length;
}
same(aliased(1, 2, 3), 3, "aliased");
function missing(a, b) {
	b = 1;
	same(arguments[1], undefined, "a parameter not passed");
	same(arguments.length, 1, "its length");
	arguments[1] = 2;
	same(b, 1, "not mapped");
}
missing(0);
function unmapped(a) {
	delete arguments[0];
	a = 2;
	same(arguments[0], undefined, "deleted");
	arguments[0] = 3;
	same(a, 2, "the map is gone");
}
unmapped(1);
function redefined(a) {
	Object.defineProperty(arguments, "0", {writable: false});
	a = 5;
	same(arguments[0], 1, "not writable: the map is gone");
	Object.defineProperty(arguments, "1", {value: 7, enumerable: false});
	same(arguments[1], 7, "a new index");
	same(Object.keys(arguments).join(), "0", "not enumerable");
}
redefined(1);
function by_accessor(a) {
	Object.defineProperty(arguments, "0", {get: function () {return 11;}});
	same(arguments[0], 11, "an accessor");
	a = 3;
	same(arguments[0], 11, "unmapped by it");
}
by_accessor(1);
function shape_of_arguments(a, b) {return Object.getOwnPropertyNames(arguments).join();}
same(shape_of_arguments(1, 2), "0,1,length,callee", "the keys");
same(shape_of_arguments(1), "0,length,callee", "fewer");
same(shape_of_arguments(1, 2, 3), "0,1,2,length,callee", "more");
function callee_is() {return arguments.callee === callee_is;}
same(callee_is(), true, "callee");
function spread_arguments(a, b) {return [...arguments].length + Array.prototype.slice.call(arguments, 1).length;}
same(spread_arguments(1, 2, 3), 5, "iterated, sliced");
same(Object.prototype.toString.call((function (a) {return arguments;})(1)), "[object Arguments]", "its class");
function frozen_arguments(a) {Object.freeze(arguments); a = 2; return arguments[0];}
same(frozen_arguments(1), 1, "frozen");
function outlives(a) {return arguments;}
var kept = outlives(1, 2);
var kept2 = outlives(3, 4);
kept[0] = 5;
same(kept2[0], 3, "no shared state");
same(kept[0] + kept[1], 7, "after the call");
function arguments_many() {return arguments.length;}
same(arguments_many.apply(null, new Array(1000)), 1000, "a thousand");


// Arrays on the natives' short way, and where they must not take it.
class Sub extends Array {}
same(new Sub(1, 2, 3).slice(1) instanceof Sub, true, "species of a subclass");
same([1, 2, 3].map(function (x) {return x * 2;}).join(), "2,4,6", "map");
same([1, 2, 3, 4].filter(function (x) {return x % 2;}).length, 2, "filter");
same(1 in [, 1].concat([, 2]), true, "concat keeps what is there");
same(0 in [, 1].concat([, 2]), false, "concat keeps a hole");
same([, 1].concat([, 2]).length, 4, "concat counts holes");
same(2 in [1, , 3].slice(0), true, "slice past a hole");
same(1 in [1, , 3].slice(0), false, "slice keeps a hole");
var shrinking = [1, 2, 3, 4];
same(shrinking.map(function (x, i) {if (i === 0) shrinking.length = 2; return x;}).length, 4, "map over an array that shrinks");
var species_array = [1, 2];
species_array.constructor = function (n) {return {length: n, marked: true};};
species_array.constructor[Symbol.species] = species_array.constructor;
same(species_array.slice(0).marked, true, "a constructor of the array's own");
var saved_species = Object.getOwnPropertyDescriptor(Array, Symbol.species);
Object.defineProperty(Array, Symbol.species, {configurable: true, get: function () {return function (n) {return {length: n, marked: 1};};}});
same([1].slice(0).marked, 1, "Array[@@species] replaced");
Object.defineProperty(Array, Symbol.species, saved_species);
same([1].slice(0).marked, undefined, "and put back");
var saved_constructor = Array.prototype.constructor;
Array.prototype.constructor = function () {return {marked: 2};};
Array.prototype.constructor[Symbol.species] = Array.prototype.constructor;
same([1].slice(0).marked, 2, "Array.prototype.constructor replaced");
Array.prototype.constructor = saved_constructor;
var fixed_length = [1, 2, 3];
Object.defineProperty(fixed_length, "length", {writable: false});
throws(function () {"use strict"; fixed_length.push(4);}, TypeError, "a fixed length");

// {...o} and Object.assign by the source's shape.
var order = {b: 1, a: 2};
same(Object.keys({...order}).join(), "b,a", "the source's order");
same(Object.keys({...{2: 1, b: 2, 1: 3}}).join(), "1,2,b", "indices first");
var hidden = {a: 1};
Object.defineProperty(hidden, "h", {value: 2, enumerable: false});
same("h" in {...hidden}, false, "not enumerable");
var symbol_key = Symbol("s");
same(({...{[symbol_key]: 1, a: 2}})[symbol_key], 1, "symbols");
var calls = 0;
same(({...{get a() {calls += 1; return 3;}}}).a, 3, "a getter read");
same(calls, 1, "once");
same(Object.getOwnPropertyDescriptor({a: 0, ...{a: 1}}, "a").value, 1, "over what is there");
var source_changes = {a: 1, b: 2};
var with_setter = {set a(v) {delete source_changes.b;}};
Object.assign(with_setter, source_changes);
same("b" in with_setter, false, "a setter that changes the source");

// A shape's transitions past those a list holds, and after the collection took some.
var by_first_key = [];
for (var k = 0; k < 40; k++) {var made = {}; made["k" + k] = k; by_first_key.push(made);}
for (var k = 0; k < 40; k++) same(by_first_key[k]["k" + k], k, "a first key");
same(Object.keys({k7: 1, a: 2}).join(), "k7,a", "a literal on them");

// A new key on an ordinary object: what the prototypes said of it once (Transition.walked) holds until they change.
function Walked() {this.fresh = 1;}
function made_with_walked() {return new Walked();}
for (var k = 0; k < 3; k++) same(Object.keys(made_with_walked()).join(), "fresh", "a new key, again");
var seen_by_setter = 0;
Object.defineProperty(Walked.prototype, "fresh", {set(v) {seen_by_setter = v;}, configurable: true});
same(Object.keys(made_with_walked()).length, 0, "a setter on the prototype takes it");
same(seen_by_setter, 1, "and sees the value");
delete Walked.prototype.fresh;
for (var k = 0; k < 3; k++) same(made_with_walked().fresh, 1, "gone, the key is the object's");
Object.defineProperty(Object.prototype, "fresh", {value: 2, writable: false, configurable: true});
same(Object.keys(made_with_walked()).length, 0, "read-only further up, nothing is added");
delete Object.prototype.fresh;
for (var k = 0; k < 3; k++) same(Object.keys(made_with_walked()).join(), "fresh", "and again");
Object.defineProperty(Object.prototype, "fresh", {value: 3, writable: true, configurable: true});
same(Object.keys(made_with_walked()).join(), "fresh", "writable further up, it is added");
Object.defineProperty(Object.prototype, "fresh", {writable: false});
same(Object.keys(made_with_walked()).length, 0, "made read-only since");
delete Object.prototype.fresh;
for (var k = 0; k < 3; k++) made_with_walked();
var trapped = [];
Object.setPrototypeOf(Walked.prototype, new Proxy({}, {set(t, key, v, r) {trapped.push(key); return true;}}));
same(Object.keys(made_with_walked()).length, 0, "a proxy behind the prototype takes it");
same(trapped.join(), "fresh", "by its trap");
Object.setPrototypeOf(Walked.prototype, Object.prototype);
for (var k = 0; k < 3; k++) made_with_walked();
Object.freeze(Walked.prototype);
same(Object.keys(made_with_walked()).join(), "fresh", "a frozen prototype without the key takes nothing away");
var strict_set = (function () {"use strict"; return function (o) {o.locked = 1;};})();
var locked_proto = {};
var locked_a = Object.create(locked_proto), locked_b = Object.create(locked_proto);
strict_set(locked_a);
Object.defineProperty(locked_proto, "locked", {value: 0, writable: false});
var refused = false;
try {strict_set(locked_b);} catch (e) {refused = e instanceof TypeError;}
same(refused, true, "strict code is told");
var not_extensible = Object.preventExtensions(Object.create(Walked.prototype));
same((function () {not_extensible.fresh = 1; return "fresh" in not_extensible;})(), false, "an object that takes no key");

// A greedy loop of one character is one state for the whole run; a search that starts with such a run goes on after it.
same(/a+b/.exec("xaaab").index, 1, "a run, from its first position");
same(/a*ab/.exec("aaab")[0], "aaab", "a run gives back what follows needs");
same(/\S+\.\S+/.exec("a.b.c d")[0], "a.b.c", "the last place the next character is");
same(/(\S+)@(\S+)/.exec("x y@z").slice(1).join(), "y,z", "captures around runs");
same(/([^"]*)"/.exec('abc"d')[1], "abc", "a class run and its capture");
same(/.*b/.exec("aab\nb")[0], "aab", "a dot run stops at the line's end");
same(/a+/i.exec("xAaA")[0], "AaA", "a run without regard to case");
same(/\w+(?=!)/.exec("hello! you")[0], "hello", "a run before a lookahead");
same(/(?<=\s)\S+/.exec("ab cd")[0], "cd", "a run after a lookbehind");
same(/(?=(a+))a*b\1/.exec("baaabac")[0], "aba", "a run inside a lookahead keeps its capture");
same(/(a+)b\1/.exec("aaabaa")[0], "aabaa", "a back reference starts further in the run");
same(/a+(?:b|c)/.exec("aaad aac")[0], "aac", "a run, then an alternative");
same(/(?:a+b)+/.exec("aabab")[0], "aabab", "a run in a loop");
same("a@ b c@".replace(/\S+@/g, "#"), "# b #", "a global search over runs");
var sticky_run = /a+b/y;
sticky_run.lastIndex = 1;
same(sticky_run.exec("aaab")[0], "aab", "sticky: the run from lastIndex");
same(/\u{1F600}+x/u.exec("\u{1F600}\u{1F600}x")[0].length, 5, "a run of pairs");
same(/\S+x/u.exec("\u{1F600}\u{1F600}x")[0].length, 5, "a class over pairs");
var long_token = "";
for (var i = 0; i < 2000; i++) {long_token += "abcdefghij";}
same(/\S+(@|%40)\S+\.\S+/.test(long_token), false, "no match in a long run");
same(/\S+@/.test(long_token + "@"), true, "a match at the end of a long run");

// indexOf a word at a time: units on either side of a word's end, bytes with the high bit, wide strings against narrow patterns.
same("abcdefgh!".indexOf("!"), 8, "the first unit past a word");
same("aaaaaaaaaaaaaaab".indexOf("ab"), 14, "first and last unit in different words");
same("\xff\x80\x7f\x01\x00".indexOf("\x7f"), 2, "the high bit and a borrow");
same("\x01\x01\x01\x02\x01\x01\x01\x01".indexOf("\x02"), 3, "a byte above a borrow");
same("ĀāĂăĄą".indexOf("ą"), 5, "wide units");
same("ĀaĂb".indexOf("ab"), -1, "a pattern apart in a wide string");
same("abc".indexOf("Ā"), -1, "a unit a narrow string does not hold");
same("xxxxxxxxxxxxabcabc".indexOf("abc", 13), 15, "from a position");
same("xxxxxxxxabcdefghijkl".lastIndexOf("abc"), 8, "lastIndexOf is another search");

// The matcher's runs (lre_exec.odin): a greedy loop of one character gives back what follows needs, and a search goes on after a run only when no start inside it can match.
function match(re, text, index, want) {
	var m = re.exec(text);
	same(m ? m.index + ":" + JSON.stringify(Array.from(m)) : null, want === null ? null : index + ":" + JSON.stringify(want), String(re) + " of " + text);
}
match(/a+ab/, "aaab", 0, ["aaab"]);
match(/a*b/, "aaac", 0, null);
match(/a*/, "baaa", 0, [""]);
match(/(a+)(a+)/, "aaa", 0, ["aaa", "aa", "a"]);
match(/(a*)(a*)/, "aa", 0, ["aa", "aa", ""]);
match(/a+b/, "aac aab", 4, ["aab"]);
match(/[^"]*"/, 'abc"def"', 0, ['abc"']);
match(/.*x/, "ab\ncdx", 3, ["cdx"]);
match(/.*x/s, "ab\ncdx", 0, ["ab\ncdx"]);
match(/a+(?=b)/, "aaab", 0, ["aaa"]);
match(/a+(?!b)/, "aaab", 0, ["aa"]);
match(/(a+)b\1/, "aaabaa", 1, ["aabaa", "aa"]);   // (a start inside the run matches where the first did not: a back reference reads the start)
match(/\w+(?<=ab)c/, "xabc", 0, ["xabc"]);
match(/(x+)y|(x+)z/, "xxz", 0, ["xxz", null, "xx"]);
match(/(?:a+b)+c/, "aabab", 0, null);
match(/(?:a+b)+c/, "aababc", 0, ["aababc"]);
match(/(?=(a+))a*b\1/, "baaabac", 3, ["aba", "a"]);   // (the states of a lookahead that matched are gone, its captures are not)
match(/(?=a+b)a+c|a/, "aab", 0, ["a"]);
match(/A+b/i, "xaAaB", 1, ["aAaB"]);
match(/[^a]+$/, "a\uffff\uffff", 1, ["\uffff\uffff"]);
match(/\u4e2d+\u6587/, "\u4e2d\u4e2d\u4e2d\u6587", 0, ["\u4e2d\u4e2d\u4e2d\u6587"]);
match(/\S+x/u, "\ud83d\ude00\ud83d\ude00x", 0, ["\ud83d\ude00\ud83d\ude00x"]);
match(/\S+(@|%40)\S+\.\S+/, "x".repeat(100000), 0, null);   // (over the positions of a run from each of them, this does not end)

// indexOf a word at a time: the pattern on each side of a word, in both widths, with candidates that are not it
for (var width = 0; width < 2; width++) {
	var filler = width ? "\u4e2d" : "x";
	for (var before = 0; before < 20; before++) {
		var text = filler.repeat(before) + "needle" + filler.repeat(19 - before);
		same(text.indexOf("needle"), before, "indexOf after " + before);
		same(text.indexOf("n"), before, "one unit after " + before);
		same(text.indexOf("needle", before + 1), -1, "from past it, after " + before);
		same(text.indexOf("nexdle"), -1, "the ends alike");
	}
}
same("a".repeat(30).concat("b").indexOf("aab"), 28, "candidates in a row");
same("abc".indexOf("\u4e2d"), -1, "a unit no string of this width holds");
