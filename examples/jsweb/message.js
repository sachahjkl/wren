// MessageChannel, MessagePort, window.postMessage.

test("MessageChannel", async () => {
  const ch = new MessageChannel();
  ok(ch.port1 instanceof MessagePort && ch.port1 === ch.port1, "ports");
  const got = [];
  const done = new Promise(r => {
    ch.port2.onmessage = e => { got.push(e.data); if (got.length === 3) r(); };
  });
  const obj = { n: 1, d: new Date(3) };
  ch.port1.postMessage(obj);
  ch.port1.postMessage("two");
  ch.port1.postMessage([3]);
  obj.n = 2;
  await done;
  eq(got[0].n, 1, "the message is a clone made when posted");
  ok(got[0].d instanceof Date, "structured clone");
  eq(got[1], "two", "in order");
  eq(got[2][0], 3, "arrays");
});

test("start() and queued messages", async () => {
  const ch = new MessageChannel();
  ch.port1.postMessage("early");
  await sleep(10);
  let e2 = null;
  ch.port2.addEventListener("message", e => { e2 = e; });
  await sleep(10);
  eq(e2, null, "addEventListener does not start the port");
  const p = new Promise(r => ch.port2.addEventListener("message", r));
  ch.port2.start();
  await p;
  eq(e2.data, "early", "start() delivers what was queued");
  ok(e2 instanceof MessageEvent, "a MessageEvent");
  eq(e2.isTrusted, true, "trusted");
});

test("transfer and close", async () => {
  const ch = new MessageChannel();
  const ab = new Uint8Array([1, 2, 3]).buffer;
  const p = new Promise(r => { ch.port2.onmessage = e => r(e.data); });
  ch.port1.postMessage(ab, [ab]);
  eq(ab.byteLength, 0, "transferred buffer detached");
  eq(new Uint8Array(await p)[2], 3, "the bytes arrive");
  throws(() => ch.port1.postMessage(() => 1), "DataCloneError", "a function cannot be posted");
  let late = false;
  ch.port2.onmessage = () => { late = true; };
  ch.port1.close();
  ch.port1.postMessage("lost");
  await sleep(20);
  eq(late, false, "nothing after close()");
});

test("window.postMessage", async () => {
  const p = new Promise(r => { window.onmessage = r; });
  window.postMessage({ hello: "w" }, "*");
  const e = await p;
  eq(e.data.hello, "w", "data");
  eq(e.origin, "http://127.0.0.1:8765", "origin");
  ok(e.source === window, "source");
  let wrong = false;
  window.onmessage = () => { wrong = true; };
  window.postMessage("x", "http://example.com");
  await sleep(20);
  eq(wrong, false, "another targetOrigin: not delivered");
  const p2 = new Promise(r => { window.onmessage = r; });
  window.postMessage("y", { targetOrigin: "/" });
  eq((await p2).data, "y", "targetOrigin / and the options form");
  window.onmessage = null;
  throws(() => window.postMessage(1, "::"), "SyntaxError", "an invalid targetOrigin");
});

test("MessageEvent constructor", () => {
  const e = new MessageEvent("message", { data: { a: 1 }, origin: "o", lastEventId: "7" });
  eq(e.data.a, 1, "data");
  eq(e.origin, "o", "origin");
  eq(e.lastEventId, "7", "lastEventId");
  eq(e.source, null, "source");
  eq(e.ports.length, 0, "ports");
  ok(Object.isFrozen(e.ports), "ports is frozen");
  eq(new MessageEvent("x").data, null, "data default null");
});

__run();
