// AbortController and AbortSignal.

test("AbortController", () => {
  const c = new AbortController();
  const s = c.signal;
  ok(s === c.signal, "signal is [SameObject]");
  ok(s instanceof AbortSignal && s instanceof EventTarget, "an AbortSignal, an EventTarget");
  eq(s.aborted, false, "not aborted");
  eq(s.reason, undefined, "no reason yet");
  s.throwIfAborted();
  const order = [];
  s.onabort = e => order.push("handler " + e.type + " " + e.isTrusted + " " + (s.reason === reason));
  s.addEventListener("abort", () => order.push("listener " + s.aborted));
  const reason = { why: "custom" };
  c.abort(reason);
  eq(s.aborted, true, "aborted");
  ok(s.reason === reason, "the reason is the value given (any)");
  eq(order.join("|"), "handler abort true true|listener true", "abort event, handler and listener see the reason");
  c.abort("again");
  ok(s.reason === reason, "a second abort changes nothing");
  try { s.throwIfAborted(); ok(false, "throwIfAborted throws"); } catch (e) { ok(e === reason, "throwIfAborted throws the reason"); }
});

test("default reason", () => {
  const c = new AbortController();
  c.abort();
  ok(c.signal.reason instanceof DOMException, "a DOMException");
  eq(c.signal.reason.name, "AbortError", "AbortError");
});

test("AbortSignal.abort", () => {
  const s = AbortSignal.abort();
  eq(s.aborted, true, "aborted at once");
  eq(s.reason.name, "AbortError", "default reason");
  eq(AbortSignal.abort(42).reason, 42, "given reason");
});

test("AbortSignal.timeout", async () => {
  const s = AbortSignal.timeout(20);
  eq(s.aborted, false, "not yet");
  await new Promise(r => s.addEventListener("abort", r));
  eq(s.reason.name, "TimeoutError", "TimeoutError");
  ok(s.reason instanceof DOMException, "a DOMException");
  throws(() => AbortSignal.timeout(-1), "TypeError", "[EnforceRange]: negative");
});

test("AbortSignal.any", async () => {
  const a = new AbortController(), b = new AbortController();
  const any = AbortSignal.any([a.signal, b.signal]);
  eq(any.aborted, false, "follows its sources");
  let seen = null;
  a.signal.addEventListener("abort", () => { seen = any.reason; });
  b.abort("B");
  eq(any.aborted, true, "aborted with a source");
  eq(any.reason, "B", "the source's reason");
  eq(seen, null, "listeners of the other source not called");
  const already = AbortSignal.any([new AbortController().signal, AbortSignal.abort("x")]);
  eq(already.reason, "x", "an aborted source aborts at once");
  const nested = AbortSignal.any([AbortSignal.any([a.signal])]);
  let inside = "";
  a.signal.addEventListener("abort", () => { inside = String(nested.reason); });
  a.abort("A");
  eq(nested.reason, "A", "dependent of a dependent");
  eq(inside, "A", "the dependent's reason is set before the source's listeners run");
  const t = AbortSignal.any([AbortSignal.timeout(10)]);
  await new Promise(r => t.onabort = r);
  eq(t.reason.name, "TimeoutError", "a timeout source");
  throws(() => AbortSignal.any([{}]), "TypeError", "not an AbortSignal");
});

test("{signal} removes listeners", () => {
  const c = new AbortController();
  const t = new EventTarget();
  let n = 0;
  t.addEventListener("x", () => n++, { signal: c.signal });
  t.dispatchEvent(new Event("x"));
  c.abort();
  t.dispatchEvent(new Event("x"));
  eq(n, 1, "the listener is gone after abort");
  let m = 0;
  t.addEventListener("x", () => m++, { signal: AbortSignal.abort() });
  t.dispatchEvent(new Event("x"));
  eq(m, 0, "an aborted signal adds nothing");
});

__run();
