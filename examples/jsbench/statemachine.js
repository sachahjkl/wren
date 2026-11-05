// A hash written as a state machine, one small method per step, the next method kept in a property of the state:
// what a bot manager on a news site does to its own source, about 12 calls a character, all through one call site.
// `jsengine run examples/jsbench/statemachine.js` against `node examples/jsbench/statemachine.js`.
var print = typeof console !== "undefined" ? console.log : globalThis.print;

var CHARS = 400000;

function length_of(s) {return s.length;}
function char_at(s, i) {return s.charCodeAt(i);}

function s_test() {if (this["pos"] < length_of(this["text"])) this.step = s_read; else this.step = s_fin0;}
function s_read() {this["k"] = char_at(this["text"], this["pos"]); this.step = s_skip;}
function s_skip() {if ([10, 13, 32].includes(this["k"])) this.step = s_next; else this.step = s_mul1;}
function s_mul1() {this["k"] = (this["k"] & 0xffff) * 0xcc9e2d51 + (((this["k"] >>> 16) * 0xcc9e2d51 & 0xffff) << 16) & 0xffffffff; this.step = s_rot1;}
function s_rot1() {this["k"] = this["k"] << 15 | this["k"] >>> 17; this.step = s_mul2;}
function s_mul2() {this["k"] = (this["k"] & 0xffff) * 0x1b873593 + (((this["k"] >>> 16) * 0x1b873593 & 0xffff) << 16) & 0xffffffff; this.step = s_xor;}
function s_xor() {this["h"] ^= this["k"]; this.step = s_rot2;}
function s_rot2() {this["h"] = this["h"] << 13 | this["h"] >>> 19; this.step = s_mul5;}
function s_mul5() {this["t"] = (this["h"] & 0xffff) * 5 + (((this["h"] >>> 16) * 5 & 0xffff) << 16) & 0xffffffff; this.step = s_add;}
function s_add() {this["h"] = (this["t"] & 0xffff) + 0x6b64 + (((this["t"] >>> 16) + 0xe654 & 0xffff) << 16); this.step = s_count;}
function s_count() {this["n"]++; this.step = s_next;}
function s_next() {this["pos"]++; this.step = s_test;}
function s_fin0() {this["h"] ^= this["n"]; this.step = s_fin1;}
function s_fin1() {this["h"] ^= this["h"] >>> 16; this.step = s_fin2;}
function s_fin2() {this["h"] = (this["h"] & 0xffff) * 0x85ebca6b + (((this["h"] >>> 16) * 0x85ebca6b & 0xffff) << 16) & 0xffffffff; this.step = s_fin3;}
function s_fin3() {this["h"] ^= this["h"] >>> 13; this.step = s_fin4;}
function s_fin4() {this["h"] = (this["h"] & 0xffff) * 0xc2b2ae35 + (((this["h"] >>> 16) * 0xc2b2ae35 & 0xffff) << 16) & 0xffffffff; this.step = s_fin5;}
function s_fin5() {this["h"] ^= this["h"] >>> 16; this.step = s_done;}
function s_done() {return true;}

function hash(text, seed) {
	var o = {text: text, h: seed, n: 0, pos: 0, step: s_read};
	while (!o.step());
	return o["h"] >>> 0;
}

var text = "";
for (var i = 0; text.length < CHARS; i++) text += "function f" + i + "(a,b){return a+b;}";
var t0 = Date.now();
var h = hash(text, 42);
var ms = Date.now() - t0;
print("hash " + h + " in " + ms + " ms, " + (ms * 1e6 / (text.length * 12)).toFixed(0) + " ns a call");
