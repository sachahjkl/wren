// jsengine hung: what never ends, each case in a realm of its own: the host must get the thread back (its hook runs) and stop it at
// its deadline, interpreted and compiled. The natives here hold no count of their own: only the polls of their loops stop them
// (src/wasm/poll.odin). HUNG_CASES: [name, source to evaluate].
var HUNG = 2 ** 53 - 1;   // the longest array-like
var HUNG_CASES = [
  ["an empty loop", "for (;;) {}"],
  ["a loop that calls", "function f() {} for (;;) f();"],
  ["a loop of natives", "for (;;) Math.floor(1.5);"],
  ["recursion that branches", "function f(n) { if (n === 0) return 0; return f(n - 1) + f(n - 1); } f(200);"],
  ["a closure that branches", "(function () { function f(n) { if (n === 0) return 0; return f(n - 1) + f(n - 1); } return f(40); })();"],
  ["methods that branch", "var o = { f(n) { if (n > 0) { this.f(n - 1); this.f(n - 1); } } }; o.f(200);"],
  ["a getter that branches", "var o = { d: 200, get g() { if (this.d <= 0) return 0; this.d--; var r = this.g + this.g; this.d++; return r; } }; o.g;"],
  ["a generator without end", "function* g() { for (;;) yield 1; } for (var x of g());"],
  ["a callback that branches", "function f(n) { if (n > 0) { [1].forEach(() => f(n - 1)); [1].forEach(() => f(n - 1)); } } f(200);"],
  ["indexOf", "Array.prototype.indexOf.call({ length: HUNG }, 1);"],
  ["lastIndexOf", "Array.prototype.lastIndexOf.call({ length: HUNG }, 1);"],
  ["includes", "Array.prototype.includes.call({ length: HUNG }, 1);"],
  ["reverse", "Array.prototype.reverse.call({ length: HUNG });"],
  ["copyWithin", "Array.prototype.copyWithin.call({ length: HUNG }, 0, 1);"],
  ["sort", "Array.prototype.sort.call({ length: HUNG });"],
  ["join of holes", "Array.prototype.join.call({ length: 2 ** 32 }, '');"],
  ["a sparse array", "new Array(2 ** 32 - 1).lastIndexOf(1);"],
  ["concat of an array-like", "var o = { length: HUNG - 1 }; o[Symbol.isConcatSpreadable] = true; [].concat(o);"],
  ["a regular expression", "/(a+)+$/.test('a'.repeat(64) + 'b');"],
  ["a big integer", "(3n ** (2n ** 24n)).toString().length;"],
];
