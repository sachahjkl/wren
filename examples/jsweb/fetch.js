// fetch() against the test server: bodies, headers, statuses, redirects, CORS, aborts, streams, request bodies.
const OTHER = "http://127.0.0.1:8767";

test("text, json, headers", async () => {
  const r = await fetch("/jsweb/json");
  ok(r instanceof Response, "a Response");
  eq(r.status, 200, "status");
  eq(r.ok, true, "ok");
  eq(r.statusText, "OK", "statusText");
  eq(r.type, "basic", "same-origin: basic");
  eq(r.url, "http://127.0.0.1:8765/jsweb/json", "url");
  eq(r.redirected, false, "not redirected");
  eq(r.headers.get("content-type"), "application/json", "header");
  throws(() => r.headers.set("x", "y"), "TypeError", "response headers are immutable");
  const j = await r.json();
  eq(j.s, "\u00e9t\u00e9", "json() decodes UTF-8");
  eq(r.bodyUsed, true, "bodyUsed");
  const h = await fetch("/jsweb/headers");
  eq(h.headers.get("x-multi"), "one, two", "repeated headers combined");
  eq(h.headers.get("set-cookie"), null, "Set-Cookie is not exposed");
  eq(await h.text(), "headers", "text()");
});

test("statuses and redirects", async () => {
  const nf = await fetch("/status/404");
  eq(nf.status, 404, "404 resolves");
  eq(nf.ok, false, "not ok");
  eq(nf.statusText, "Not Found", "statusText");
  const rd = await fetch("/redirect?n=2");
  eq(rd.redirected, true, "redirected");
  eq(rd.url, "http://127.0.0.1:8765/", "final URL");
  await rejects(fetch("/redirect?n=1", { redirect: "error" }), "TypeError", "redirect: error");
  const manual = await fetch("/redirect?n=1", { redirect: "manual" });
  eq(manual.type, "opaqueredirect", "redirect: manual");
  eq(manual.status, 0, "opaque redirect status");
});

test("network errors and CORS", async () => {
  await rejects(fetch("bad://x"), "TypeError", "unsupported scheme");
  const open = await fetch(OTHER + "/cors/open");
  eq(open.type, "cors", "cross-origin with CORS");
  eq(await open.text(), "open", "readable");
  await rejects(fetch(OTHER + "/cors/none"), "TypeError", "cross-origin without CORS fails");
  const opaque = await fetch(OTHER + "/cors/none", { mode: "no-cors" });
  eq(opaque.type, "opaque", "no-cors gives an opaque response");
  eq(opaque.status, 0, "opaque status");
  eq(await opaque.text(), "", "opaque body is empty");
  await rejects(fetch(OTHER + "/cors/open", { mode: "same-origin" }), "TypeError", "same-origin mode");
  const ex = await fetch(OTHER + "/cors/expose");
  eq(ex.headers.get("x-shown"), "yes", "exposed header");
  eq(ex.headers.get("x-hidden"), null, "not exposed header");
  const api = await fetch(OTHER + "/cors/api", { method: "PUT", headers: { "X-Token": "t" }, body: "abc" });
  eq(await api.text(), 'PUT token="t" body=3', "preflighted request");
});

test("abort", async () => {
  const c = new AbortController();
  const p = fetch("/webapi/slow?ms=3000", { signal: c.signal });
  c.abort("gave up");
  try { await p; ok(false, "aborted fetch rejects"); } catch (e) { eq(e, "gave up", "rejected with the signal's reason"); }
  await rejects(fetch("/jsweb/json", { signal: AbortSignal.abort() }), "AbortError", "an aborted signal: AbortError");
  const slow = await fetch("/webapi/slow?ms=3000", { signal: AbortSignal.timeout(100) });
  await rejects(slow.text(), "TimeoutError", "AbortSignal.timeout: the body read fails with TimeoutError");
  const c2 = new AbortController();
  const r = await fetch("/webapi/slow?ms=3000", { signal: c2.signal });
  const t = r.text();
  c2.abort();
  await rejects(t, "AbortError", "abort while the body arrives");
});

test("body stream", async () => {
  const r = await fetch("/webapi/chunks?n=4&ms=20");
  const reader = r.body.getReader();
  let text = "", chunks = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    ok(value instanceof Uint8Array, "chunk " + chunks + " is a Uint8Array");
    text += new TextDecoder().decode(value);
    chunks++;
  }
  eq(text, "chunk-0\nchunk-1\nchunk-2\nchunk-3\n", "every chunk");
  ok(chunks >= 2, "chunks as they arrive");
  eq(r.bodyUsed, true, "bodyUsed after reading the stream");
  let n = 0;
  for await (const c of (await fetch("/webapi/chunks?n=3&ms=10")).body) n += c.length;
  eq(n, 24, "for await over a body");
  const cl = await fetch("/jsweb/json");
  const copy = cl.clone();
  eq((await cl.json()).a, 1, "a network response...");
  eq((await copy.json()).a, 1, "...and its clone");
});

test("request bodies", async () => {
  const echo = async (body, init = {}) => new Uint8Array(await (await fetch("/webapi/echo", { method: "POST", body, ...init })).arrayBuffer());
  eq(new TextDecoder().decode(await echo("h\u00e9")), "h\u00e9", "string body (UTF-8)");
  eq((await echo(new Uint8Array([1, 2, 3]))).join(), "1,2,3", "Uint8Array body");
  eq((await echo(new Uint8Array([9, 8, 7, 6]).subarray(1, 3))).join(), "8,7", "a view's own bytes");
  eq((await echo(new Blob(["blob"]))).length, 4, "Blob body");
  eq(new TextDecoder().decode(await echo(new URLSearchParams("a=1"))), "a=1", "URLSearchParams body");
  const fd = new FormData();
  fd.append("k", "v");
  const mp = new TextDecoder().decode(await echo(fd));
  ok(mp.includes('name="k"') && mp.includes("v"), "FormData body (multipart)");
  const stream = new ReadableStream({ start(c) { c.enqueue(new Uint8Array([65])); c.enqueue(new Uint8Array([66])); c.close(); } });
  eq(new TextDecoder().decode(await echo(stream, { duplex: "half" })), "AB", "ReadableStream body");
  const hdrs = await (await fetch("/echo-headers", { method: "POST", body: new URLSearchParams("x=1"), headers: { "X-Test": "yes" } })).json();
  const get = n => { for (const k in hdrs.headers || hdrs) if (k.toLowerCase() === n) return String((hdrs.headers || hdrs)[k]); return ""; };
  ok(get("content-type").startsWith("application/x-www-form-urlencoded"), "Content-Type of a URLSearchParams body");
  ok(get("x-test").includes("yes"), "author headers sent");
});

test("cookies", async () => {
  await fetch("/cookie/set?raw=jsweb%3Done%3B%20Path%3D%2F");
  eq(await (await fetch("/cookie/show")).text(), "jsweb=one", "same-origin requests carry cookies");
  ok(document.cookie.includes("jsweb=one"), "document.cookie sees it");
  eq(await (await fetch("/cookie/show", { credentials: "omit" })).text(), "", "credentials: omit");
});

test("large bodies", async () => {
  let t0 = performance.now();
  const ab = await (await fetch("/big?mb=10")).arrayBuffer();
  const t1 = performance.now();
  eq(ab.byteLength, 10 << 20, "10 MiB arrayBuffer()");
  measure("fetch_10MiB_arrayBuffer_ms", (t1 - t0).toFixed(1));
  t0 = performance.now();
  const txt = await (await fetch("/jsweb/text?mb=10")).text();
  const t2 = performance.now();
  eq(txt.length, 10 << 20, "10 MiB text()");
  measure("fetch_10MiB_text_ms", (t2 - t0).toFixed(1));
});

__run();
