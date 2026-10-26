// ReadableStream: scripts' streams, readers, async iteration, tee.

test("a stream from a source", async () => {
  let pulls = 0;
  const s = new ReadableStream({
    start(c) { c.enqueue("a"); },
    pull(c) { pulls++; if (pulls <= 2) c.enqueue("p" + pulls); else c.close(); },
  });
  ok(!s.locked, "not locked");
  const r = s.getReader();
  ok(s.locked, "locked by its reader");
  throws(() => s.getReader(), "TypeError", "a second reader");
  const got = [];
  for (;;) { const { value, done } = await r.read(); if (done) break; got.push(value); }
  eq(got.join(), "a,p1,p2", "chunks in order");
  eq((await r.read()).done, true, "done stays done");
  await r.closed;
  ok(true, "closed resolves");
  r.releaseLock();
  ok(!s.locked, "released");
});

test("errors and cancel", async () => {
  const e = new Error("boom");
  const s = new ReadableStream({ start(c) { c.error(e); } });
  try { await s.getReader().read(); ok(false, "read of an errored stream"); } catch (x) { ok(x === e, "the stored error"); }
  let reason = null;
  const s2 = new ReadableStream({ cancel(r) { reason = r; } });
  await s2.cancel("why");
  eq(reason, "why", "cancel reaches the source");
  const s3 = new ReadableStream();
  s3.getReader();
  await rejects(s3.cancel(), "TypeError", "cancel of a locked stream");
  throws(() => new ReadableStream({ pull: 1 }), "TypeError", "pull must be a function");
  throws(() => new ReadableStream().getReader({ mode: "byob" }), "NotSupportedError", "BYOB readers");
});

test("for await", async () => {
  const s = new ReadableStream({ start(c) { c.enqueue(1); c.enqueue(2); c.close(); } });
  let sum = 0;
  for await (const x of s) sum += x;
  eq(sum, 3, "async iteration");
  ok(!s.locked, "unlocked afterwards");
});

test("tee", async () => {
  const s = new ReadableStream({ start(c) { c.enqueue("x"); c.enqueue("y"); c.close(); } });
  const [a, b] = s.tee();
  const read = async st => { const out = []; for await (const v of st) out.push(v); return out.join(""); };
  eq(await read(a) + "|" + await read(b), "xy|xy", "both branches get every chunk");
});

test("controller", async () => {
  let ctrl;
  const s = new ReadableStream({ start(c) { ctrl = c; } }, { highWaterMark: 2 });
  eq(ctrl.desiredSize, 2, "desiredSize is the high water mark");
  ctrl.enqueue(1);
  eq(ctrl.desiredSize, 1, "minus the queue");
  ctrl.close();
  throws(() => ctrl.enqueue(2), "TypeError", "enqueue after close");
  const r = s.getReader();
  eq((await r.read()).value, 1, "queued chunk read after close");
  eq((await r.read()).done, true, "then done");
});

__run();

test("pipeTo a WritableStream: chunks in order, then close", async () => {
  const got = [];
  let closed = false;
  const src = new ReadableStream({ start(c) { c.enqueue("a"); c.enqueue("b"); c.close(); } });
  const dst = new WritableStream({ write(c) { got.push(c); }, close() { closed = true; } });
  await src.pipeTo(dst);
  eq(got.join(), "a,b", "written in order");
  ok(closed, "the destination closed");
  ok(!src.locked && !dst.locked, "both unlocked after");
});

test("pipeTo: errors and options", async () => {
  const boom = new Error("boom");
  let aborted = null;
  const bad = new ReadableStream({ start(c) { c.error(boom); } });
  let e = await bad.pipeTo(new WritableStream({ abort(r) { aborted = r; } })).catch((x) => x);
  ok(e === boom && aborted === boom, "a source error aborts the destination and rejects");
  let cancelled = null;
  const src = new ReadableStream({ pull(c) { c.enqueue(1); }, cancel(r) { cancelled = r; } });
  e = await src.pipeTo(new WritableStream({ write() { throw boom; } })).catch((x) => x);
  ok(e === boom && cancelled === boom, "a destination error cancels the source");
  let closed = false;
  await new ReadableStream({ start(c) { c.close(); } }).pipeTo(new WritableStream({ close() { closed = true; } }), { preventClose: true });
  ok(!closed, "preventClose leaves the destination open");
  const ac = new AbortController();
  const p = new ReadableStream({ pull(c) { c.enqueue(0); } }).pipeTo(new WritableStream(), { signal: ac.signal });
  ac.abort();
  e = await p.catch((x) => x);
  eq(e && e.name, "AbortError", "the signal aborts the pipe");
  e = await new ReadableStream().pipeTo("x").catch((x) => x);
  eq(e && e.name, "TypeError", "not a WritableStream");
});

test("pipeThrough and backpressure", async () => {
  const got = [];
  const dst = new WritableStream({ write(c) { got.push(c); } });
  const out = new ReadableStream({ start(c) { c.enqueue("x"); c.close(); } }).pipeThrough({ writable: dst, readable: new ReadableStream({ start(c) { c.close(); } }) });
  ok(out instanceof ReadableStream, "pipeThrough returns the readable side");
  let release;
  const w = new WritableStream({ write() { return new Promise((r) => { release = r; }); } }, { highWaterMark: 1 }).getWriter();
  eq(w.desiredSize, 1, "room for one chunk");
  w.write("a");
  eq(w.desiredSize, 0, "full");
  let ready = false;
  w.ready.then(() => { ready = true; });
  await Promise.resolve(); await Promise.resolve();
  ok(!ready, "ready waits under backpressure");
  await new Promise((r) => setTimeout(r, 0));
  release();
  await new Promise((r) => setTimeout(r, 0));
  ok(ready, "ready resolves once the write is done");
  eq(got.join(), "x", "piped through");
});
