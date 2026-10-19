// The harness of src/tools/jswebtest: tests run one after the other; results go to the console, which the tool reads.
"use strict";
const __tests = [];
globalThis.test = (name, fn) => { __tests.push([name, fn]); };
globalThis.show = v => {
  try {
    if (typeof v === "string") return JSON.stringify(v);
    if (Array.isArray(v)) return JSON.stringify(v);
    return String(v);
  } catch (e) { return "?"; }
};
globalThis.ok = (cond, what) => { console.log((cond ? "ok " : "FAIL ") + what); };
globalThis.eq = (got, want, what) => {
  const same = Object.is(got, want);
  console.log((same ? "ok " : "FAIL ") + what + (same ? "" : " (got " + show(got) + ", want " + show(want) + ")"));
};
globalThis.throws = (fn, name, what) => {
  try { fn(); console.log("FAIL " + what + " (no exception)"); }
  catch (e) { eq(e && e.name, name, what); }
};
globalThis.rejects = async (p, name, what) => {
  try { await p; console.log("FAIL " + what + " (fulfilled)"); }
  catch (e) { eq(e && e.name, name, what); }
};
globalThis.measure = (name, value) => { console.log("MEASURE " + name + " " + value); };
// a delay without timers (timers are not part of these APIs): a timeout signal
globalThis.sleep = ms => new Promise(resolve => { AbortSignal.timeout(ms).onabort = () => resolve(); });
// asks the test tool to act on the page, resumes when it did
const __waits = {};
globalThis.signal = name => new Promise(resolve => { __waits[name] = resolve; console.log("SIGNAL " + name); });
globalThis.__resume = (name, v) => { const r = __waits[name]; delete __waits[name]; if (r) r(v); };
globalThis.__run = async () => {
  for (const [name, fn] of __tests) {
    try { await fn(); }
    catch (e) { console.log("FAIL " + name + ": threw " + (e && e.name) + ": " + (e && e.message)); }
  }
  console.log("DONE");
};
