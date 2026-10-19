// WebSocket (the test server's /ws/echo), EventSource (/sse/basic).

test("WebSocket", async () => {
  const ws = new WebSocket("ws://127.0.0.1:8765/ws/echo");
  eq(ws.readyState, WebSocket.CONNECTING, "CONNECTING");
  eq(ws.binaryType, "blob", "binaryType default");
  eq(ws.url, "ws://127.0.0.1:8765/ws/echo", "url");
  throws(() => ws.send("early"), "InvalidStateError", "send while connecting");
  await new Promise(r => { ws.onopen = r; });
  eq(ws.readyState, WebSocket.OPEN, "OPEN");
  const next = () => new Promise(r => ws.addEventListener("message", r, { once: true }));
  let m = next();
  ws.send("h\u00e9llo");
  let e = await m;
  ok(e instanceof MessageEvent, "a MessageEvent");
  eq(e.data, "h\u00e9llo", "text echo");
  eq(e.origin, "ws://127.0.0.1:8765", "origin");
  m = next();
  ws.send(new Uint8Array([1, 2, 3]));
  e = await m;
  ok(e.data instanceof Blob, "binary as a Blob (binaryType blob)");
  eq(new Uint8Array(await e.data.arrayBuffer()).join(), "1,2,3", "its bytes");
  ws.binaryType = "arraybuffer";
  m = next();
  ws.send(new Blob(["xy"]));
  e = await m;
  ok(e.data instanceof ArrayBuffer && e.data.byteLength === 2, "binary as an ArrayBuffer");
  ok(e.data === e.data, "the same object");
  ws.binaryType = "nope";
  eq(ws.binaryType, "arraybuffer", "an invalid binaryType is ignored");
  throws(() => ws.close(1001), "InvalidAccessError", "close code out of range");
  throws(() => ws.close(1000, "x".repeat(124)), "SyntaxError", "close reason too long");
  const closed = new Promise(r => { ws.onclose = r; });
  ws.close(1000, "bye");
  eq(ws.readyState, WebSocket.CLOSING, "CLOSING");
  const c = await closed;
  ok(c instanceof CloseEvent, "a CloseEvent");
  eq(c.code, 1000, "code");
  eq(c.reason, "", "reason: the server's close frame (the test server echoes the code only)");
  eq(c.wasClean, true, "wasClean");
  eq(ws.readyState, WebSocket.CLOSED, "CLOSED");
  throws(() => new WebSocket("http://127.0.0.1:8765/#frag"), "SyntaxError", "a fragment");
  const ce = new CloseEvent("close", { code: 4000, reason: "r", wasClean: true });
  eq(ce.code + ce.reason + ce.wasClean, "4000rtrue", "CloseEvent constructor");
});

test("WebSocket failure", async () => {
  const ws = new WebSocket("ws://127.0.0.1:8765/ws/forbidden");
  const log = [];
  ws.onerror = () => log.push("error");
  await new Promise(r => { ws.onclose = e => { log.push("close " + e.code); r(); }; });
  eq(log.join(), "error,close 1006", "error then close 1006");
});

test("EventSource", async () => {
  const es = new EventSource("/sse/basic");
  eq(es.readyState, EventSource.CONNECTING, "CONNECTING");
  eq(es.url, "http://127.0.0.1:8765/sse/basic", "url");
  eq(es.withCredentials, false, "withCredentials");
  const e = await new Promise(r => { es.onmessage = r; });
  eq(es.readyState, EventSource.OPEN, "OPEN");
  ok(e instanceof MessageEvent, "a MessageEvent");
  ok(typeof e.data === "string" && e.data.length > 0, "data");
  eq(e.origin, "http://127.0.0.1:8765", "origin");
  es.close();
  eq(es.readyState, EventSource.CLOSED, "close()");
  throws(() => new EventSource("http://[x"), "SyntaxError", "invalid URL");
});

__run();
