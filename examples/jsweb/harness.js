// The harness of src/tools/webtests/jsweb.odin: tests run one after the other, and what happens goes to the test program through the
// functions of `wrenTest`, which only a page of a test program has (api/testhost.widl: typed on both sides, and not in a browser).
// The program declares how many tests each script runs (jsweb.odin) and fails the section when another number ran.
"use strict";
const __host = globalThis.wrenTest;
const __tests = [];
globalThis.test = (name, fn) => { __tests.push([name, fn]); };
globalThis.show = v => {
  try {
    if (typeof v === "string") return JSON.stringify(v);
    if (Array.isArray(v)) return JSON.stringify(v);
    return String(v);
  } catch (e) { return "?"; }
};
globalThis.ok = (cond, what) => { __host.check(!!cond, String(what)); };
globalThis.eq = (got, want, what) => {
  const same = Object.is(got, want);
  __host.check(same, what + (same ? "" : " (got " + show(got) + ", want " + show(want) + ")"));
};
globalThis.throws = (fn, name, what) => {
  try { fn(); __host.check(false, what + " (no exception)"); }
  catch (e) { eq(e && e.name, name, what); }
};
globalThis.rejects = async (p, name, what) => {
  try { await p; __host.check(false, what + " (fulfilled)"); }
  catch (e) { eq(e && e.name, name, what); }
};
globalThis.measure = (name, value) => { __host.measure(name, Number(value)); };
// says something the program waits for or reads
globalThis.note = text => { __host.note(text); };
// the test, or with no test running the whole script, cannot run on this machine ("webgl-adapter", "av1-decoder"). The
// program looks for itself, and a skip that is not true of the machine fails.
globalThis.skip = (reason, why) => { __host.skip(reason, why || ""); };
// a delay without timers (timers are not part of these APIs): a timeout signal. For a real duration only, and the place says which: what a test waits for has `until`
globalThis.sleep = ms => new Promise(resolve => { AbortSignal.timeout(ms).onabort = () => resolve(); });
const UNTIL_LOOK_MS = 5;
// waits until cond() holds (it may be async), and says what for: what never comes ends on the limit of the section, whose last lines are this.
globalThis.until = async (cond, what) => {
  if (await cond()) return true;
  if (what) console.log("waiting for " + what);
  while (!await cond()) await sleep(UNTIL_LOOK_MS);
  return true;
};
// asks the test tool to act on the page, resumes when it did
const __waits = {};
globalThis.signal = name => new Promise(resolve => { __waits[name] = resolve; __host.signal(name); });
globalThis.__resume = (name, v) => { const r = __waits[name]; delete __waits[name]; if (r) r(v); };
globalThis.__run = async () => {
  for (const [name, fn] of __tests) {
    __host.testBegin(name);
    try { await fn(); }
    catch (e) { __host.check(false, name + ": threw " + (e && e.name) + ": " + (e && e.message)); }
    __host.testEnd(name);
  }
  __host.done();
};
// nothing of this script runs on this machine (see skip)
globalThis.__skipAll = (reason, why) => { skip(reason, why); __host.done(); };
// why a context cannot be had, in the words of the browser
globalThis.webglContextError = () => {
  let why = "";
  const c = document.createElement("canvas");
  c.addEventListener("webglcontextcreationerror", e => { why = e.statusMessage; });
  return c.getContext("webgl") ? null : why || "getContext returned null";
};
