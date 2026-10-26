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

test("TransformStream: identity, a transformer, flush, terminate", async () => {
  const id = new TransformStream();
  ok(id.readable instanceof ReadableStream && id.writable instanceof WritableStream, "its two sides");
  const w = id.writable.getWriter();
  w.write("a"); w.write("b"); w.close();
  const got = [];
  for await (const c of id.readable) got.push(c);
  eq(got.join(), "a,b", "the identity transform passes chunks through");

  const up = new TransformStream({
    transform(chunk, c) { c.enqueue(chunk.toUpperCase()); c.enqueue("|"); },
    flush(c) { c.enqueue("end"); },
  });
  const src = new ReadableStream({ start(c) { c.enqueue("x"); c.enqueue("y"); c.close(); } });
  const out = [];
  for await (const c of src.pipeThrough(up)) out.push(c);
  eq(out.join(""), "X|Y|end", "pipeThrough a transformer, then flush");

  const term = new TransformStream({ transform(chunk, c) { c.enqueue(chunk); c.terminate(); } });
  const tw = term.writable.getWriter();
  tw.write(1).catch(() => {});
  const tr = term.readable.getReader();
  eq((await tr.read()).value, 1, "the chunk before terminate");
  eq((await tr.read()).done, true, "terminate closes the readable side");
  await rejects(tw.write(2), "TypeError", "and errors the writable side");

  const bad = new TransformStream({ transform() { throw new RangeError("no"); } });
  const bw = bad.writable.getWriter();
  const pending = bad.readable.getReader().read();   // (the readable side asks: writes wait for that, its highWaterMark is 0)
  await rejects(bw.write("z"), "RangeError", "a transform that throws rejects the write");
  await rejects(pending, "RangeError", "and errors the readable side");
  throws(() => new TransformStream({ readableType: "bytes" }), "RangeError", "readableType");

  const started = [];
  const s2 = new TransformStream({ start(c) { started.push(typeof c.enqueue, c.desiredSize); } }, undefined, { highWaterMark: 2 });
  eq(started.join(), "function,2", "start gets the controller; desiredSize is the readable side's");
  ok(s2.writable.getWriter().desiredSize === 1, "the writable side's highWaterMark defaults to 1");

  const cancelled = [];
  const c3 = new TransformStream({ cancel(r) { cancelled.push(r); } });
  await c3.readable.cancel("why");
  eq(cancelled.join(), "why", "cancelling the readable side runs cancel()");
  eq(await c3.writable.getWriter().write("q").catch((r) => r), "why", "... and errors the writable side with the reason");
});

test("TextDecoderStream and TextEncoderStream", async () => {
  const d = new TextDecoderStream("utf-8", { fatal: false });
  eq(d.encoding + ":" + d.fatal + ":" + d.ignoreBOM, "utf-8:false:false", "attributes");
  const src = new ReadableStream({ start(c) { c.enqueue(new Uint8Array([0x61, 0xE2, 0x82])); c.enqueue(new Uint8Array([0xAC, 0x62])); c.close(); } });
  let text = "";
  for await (const s of src.pipeThrough(d)) text += s;
  eq(text, "a\u20acb", "a character cut between two chunks");
  const d2 = new TextDecoderStream();
  const w2 = d2.writable.getWriter();
  w2.write("not bytes").catch(() => {});
  await rejects(d2.readable.getReader().read(), "TypeError", "a chunk that is not bytes errors the stream");
  const t = new TextDecoderStream("windows-1252");
  eq(t.encoding, "windows-1252", "another encoding");

  const e = new TextEncoderStream();
  eq(e.encoding, "utf-8", "TextEncoderStream.encoding");
  const ew = e.writable.getWriter();
  ew.write("a\uD83D"); ew.write("\uDE00"); ew.write("\uD800"); ew.close();
  const bytes = [];
  for await (const b of e.readable) bytes.push(...b);
  eq(bytes.join(), [0x61, 0xF0, 0x9F, 0x98, 0x80, 0xEF, 0xBF, 0xBD].join(), "a surrogate pair cut between chunks, and a lone one at the end");
  const round = new ReadableStream({ start(c) { c.enqueue("h\u00e9llo"); c.close(); } }).pipeThrough(new TextEncoderStream()).pipeThrough(new TextDecoderStream());
  let back = "";
  for await (const s of round) back += s;
  eq(back, "h\u00e9llo", "encoded then decoded");
});
test("CompressionStream and DecompressionStream", async () => {
  const text = "Wren ".repeat(2000) + "\u00e9t\u00e9";
  const bytesOf = async (readable) => { const out = []; for await (const c of readable) out.push(...c); return new Uint8Array(out); };
  const source = () => new ReadableStream({ start(c) { const b = new TextEncoder().encode(text); c.enqueue(b.subarray(0, 100)); c.enqueue(b.subarray(100)); c.close(); } });
  for (const format of ["gzip", "deflate", "deflate-raw"]) {
    const packed = await bytesOf(source().pipeThrough(new CompressionStream(format)));
    ok(packed.length > 0 && packed.length < 200, format + ": compressed " + packed.length + " bytes");
    if (format === "gzip") eq(packed[0] + "," + packed[1], "31,139", "gzip: its magic number");
    if (format === "deflate") eq(packed[0], 0x78, "deflate: the zlib header");
    const back = await bytesOf(new ReadableStream({ start(c) { for (const b of packed) c.enqueue(new Uint8Array([b])); c.close(); } }).pipeThrough(new DecompressionStream(format)));
    eq(new TextDecoder().decode(back), text, format + ": decompressed byte by byte, the same text");
  }
  throws(() => new CompressionStream("zip"), "TypeError", "an unknown format");
  const junk = new ReadableStream({ start(c) { c.enqueue(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8])); c.close(); } });
  await rejects(bytesOf(junk.pipeThrough(new DecompressionStream("gzip"))), "TypeError", "data that is not gzip");
  const whole = await bytesOf(source().pipeThrough(new CompressionStream("gzip")));
  const cut = new ReadableStream({ start(c) { c.enqueue(whole.subarray(0, whole.length - 4)); c.close(); } });
  await rejects(bytesOf(cut.pipeThrough(new DecompressionStream("gzip"))), "TypeError", "data cut before its end");
  const extra = new ReadableStream({ start(c) { c.enqueue(whole); c.enqueue(new Uint8Array([0])); c.close(); } });
  await rejects(bytesOf(extra.pipeThrough(new DecompressionStream("gzip"))), "TypeError", "data after the end");
  const notBytes = new CompressionStream("gzip");
  const w = notBytes.writable.getWriter();
  const pending = notBytes.readable.getReader().read();
  await rejects(w.write("text"), "TypeError", "a chunk that is not a BufferSource");
  await rejects(pending, "TypeError", "errors the readable side too");
});