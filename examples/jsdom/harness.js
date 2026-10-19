// Test harness of the pages of examples/jsdom (src/tools/jsdomtest runs it before each page): checks report through
// the console, "PASS name" or "FAIL name: why", and a page says "DONE" when it is over (done(), after its asynchronous
// checks).
(function () {
  function show(v) {
    if (typeof v === "string") { return JSON.stringify(v); }
    if (v === null || typeof v !== "object") { return String(v); }
    try { return Object.prototype.toString.call(v) + " " + JSON.stringify(v); } catch (e) { return Object.prototype.toString.call(v); }
  }
  globalThis.t = function (name, cond, detail) {
    console.log((cond ? "PASS " : "FAIL ") + name + (cond || detail === undefined ? "" : ": " + detail));
  };
  globalThis.eq = function (name, got, want) {
    t(name, Object.is(got, want), "got " + show(got) + ", want " + show(want));
  };
  globalThis.throws = function (name, fn, errName) {
    try { fn(); t(name, false, "no exception, want " + errName); }
    catch (e) { t(name, !!e && e.name === errName, "threw " + (e && e.name) + " (" + (e && e.message) + "), want " + errName); }
  };
  // runs `fn` and reports an exception it throws as a failure (the rest of the page goes on)
  globalThis.section = function (name, fn) {
    try { fn(); } catch (e) { t(name + " (section)", false, "exception " + (e && e.name) + ": " + (e && e.message) + "\n" + (e && e.stack)); }
  };
  globalThis.done = function () { console.log("DONE"); };
  // a few turns of the microtask queue (MutationObserver notifications, promise reactions)
  globalThis.later = function (n) {
    let p = Promise.resolve();
    for (let i = 0; i < (n || 4); i++) { p = p.then(() => undefined); }
    return p;
  };
})();
