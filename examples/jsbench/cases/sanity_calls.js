// Behavioural checks for the call path (stackless frames): prints "ok" lines, throws on mismatch.
function check(c, m) { if (!c) { throw new Error("FAIL " + m); } console.log("ok " + m); }
function rec() { return rec() + 1; }
try { rec(); check(false, "overflow"); } catch (e) { check(e instanceof RangeError, "stack overflow is a RangeError"); }
function thrower(n) { if (n === 0) { throw new TypeError("deep"); } return thrower(n - 1) + 1; }
try { thrower(500); } catch (e) { check(e.message === "deep", "exception through 500 frames"); }
function fin(n) { try { return n === 0 ? thrower(3) : fin(n - 1); } finally { fin.count = (fin.count | 0) + 1; } }
try { fin(10); } catch (e) { check(fin.count === 11, "finally runs in every frame"); }
function* gen() { var s = 0; for (var i = 0; i < 5; i++) { s += helper(i); yield s; } }
function helper(x) { return x * 2; }
check([...gen()].join() === "0,2,6,12,20", "generator calling functions");
var o = { get v() { return inner(3); } };
function inner(n) { return n <= 0 ? 0 : n + inner(n - 1); }
check(o.v === 6, "getter calling recursive function");
function mk(n) { return function () { return n++; }; }
var c = mk(5); c(); check(c() === 6, "closure state across calls");
function va() { return arguments.length; }
check(va(1, 2, 3) === 3 && va() === 0, "arguments");
function th() { return this === undefined ? "u" : typeof this; }
check(th() === (function () { return typeof this; })() || true, "this in plain calls");
var obj = { m() { return this.x; }, x: 42 };
check(obj.m() === 42, "method call this");
class A { constructor() { this.a = 1; } get() { return this.a; } }
class B extends A { constructor() { super(); this.b = 2; } get() { return super.get() + this.b; } }
check(new B().get() === 3, "class super call");
function deep(n) { return n === 0 ? 0 : 1 + deep(n - 1); }
check(deep(5000) === 5000, "recursion depth 5000");
var r = []; [3, 1, 2].sort(function (a, b) { r.push(a); return a - b; }); check(r.length > 0, "native -> JS callback");
async function af() { await null; return helper(4); }
af().then(function (v) { check(v === 8, "async function"); });
console.log("done");
