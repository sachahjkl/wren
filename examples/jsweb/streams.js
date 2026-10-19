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
