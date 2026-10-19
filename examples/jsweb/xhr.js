// XMLHttpRequest.
const OTHER = "http://127.0.0.1:8767";

function send(x, body) {
  return new Promise(resolve => {
    x.addEventListener("loadend", () => resolve(), { once: true });
    x.send(body);
  });
}

test("GET: states and events", async () => {
  const x = new XMLHttpRequest();
  eq(x.readyState, XMLHttpRequest.UNSENT, "UNSENT");
  const log = [];
  x.onreadystatechange = () => log.push("rs" + x.readyState);
  for (const t of ["loadstart", "progress", "load", "loadend"]) x.addEventListener(t, e => log.push(t + (e instanceof ProgressEvent ? "" : "?")));
  x.open("GET", "/jsweb/json");
  eq(x.readyState, XMLHttpRequest.OPENED, "OPENED");
  await send(x);
  eq(log.join(" "), "rs1 loadstart rs2 rs3 progress rs4 load loadend", "readystatechange and progress events in order");
  eq(x.status, 200, "status");
  eq(x.statusText, "OK", "statusText");
  eq(x.responseURL, "http://127.0.0.1:8765/jsweb/json", "responseURL");
  eq(x.getResponseHeader("Content-Type"), "application/json", "getResponseHeader (case-insensitive)");
  eq(x.getResponseHeader("nope"), null, "absent header");
  ok(x.getAllResponseHeaders().includes("content-type: application/json\r\n"), "getAllResponseHeaders: lower case, CR LF");
  eq(JSON.parse(x.responseText).a, 1, "responseText");
  eq(x.response, x.responseText, "response is the text");
});

test("responseType", async () => {
  const j = new XMLHttpRequest();
  j.open("GET", "/jsweb/json");
  j.responseType = "json";
  await send(j);
  eq(j.response.s, "\u00e9t\u00e9", "json");
  throws(() => j.responseText, "InvalidStateError", "responseText of a json request");
  const a = new XMLHttpRequest();
  a.open("GET", "/jsweb/json");
  a.responseType = "arraybuffer";
  await send(a);
  ok(a.response instanceof ArrayBuffer && a.response.byteLength > 10, "arraybuffer");
  ok(a.response === a.response, "the same object every time");
  const b = new XMLHttpRequest();
  b.open("GET", "/jsweb/json");
  b.responseType = "blob";
  await send(b);
  ok(b.response instanceof Blob && b.response.type === "application/json", "blob");
  const l = new XMLHttpRequest();
  l.open("GET", "/jsweb/latin1");
  await send(l);
  eq(l.responseText, "caf\u00e9", "the response's charset");
  const o = new XMLHttpRequest();
  o.open("GET", "/jsweb/latin1");
  o.overrideMimeType("text/plain; charset=utf-8");
  await send(o);
  eq(o.responseText, "caf\ufffd", "overrideMimeType");
  const bad = new XMLHttpRequest();
  bad.open("GET", "/jsweb/headers");
  bad.responseType = "json";
  await send(bad);
  eq(bad.response, null, "json of invalid JSON is null");
  bad.responseType = "nope";
  eq(bad.responseType, "json", "an invalid responseType is ignored");
  throws(() => { bad.responseType = "text"; }, "InvalidStateError", "responseType when DONE");
});

test("POST, headers", async () => {
  const x = new XMLHttpRequest();
  x.open("POST", "/echo-headers");
  x.setRequestHeader("X-Test", "a");
  x.setRequestHeader("X-Test", "b");
  x.setRequestHeader("Cookie", "no");
  x.responseType = "json";
  await send(x, "body");
  eq(x.response["x-test"], "a, b", "repeated author headers");
  eq(x.response["cookie"], undefined, "forbidden header ignored");
  eq(x.response._method, "POST", "method");
  ok(String(x.response["content-type"]).startsWith("text/plain;charset=UTF-8"), "Content-Type of a string body");
  const e = new XMLHttpRequest();
  e.open("POST", "/webapi/echo");
  e.responseType = "arraybuffer";
  await send(e, new Uint8Array([5, 6, 7]));
  eq(new Uint8Array(e.response).join(), "5,6,7", "binary body");
  throws(() => e.setRequestHeader("a", "b"), "InvalidStateError", "setRequestHeader when not OPENED");
  const s = new XMLHttpRequest();
  s.open("GET", "/x");
  throws(() => s.setRequestHeader("a b", "c"), "SyntaxError", "invalid header name");
  throws(() => s.open("TRACE", "/x"), "SecurityError", "forbidden method");
  throws(() => s.open("GET", "http://[bad"), "SyntaxError", "invalid URL");
});

test("upload events", async () => {
  const x = new XMLHttpRequest();
  const log = [];
  for (const t of ["loadstart", "progress", "load", "loadend"]) x.upload.addEventListener(t, () => log.push(t));
  ok(x.upload === x.upload, "upload is [SameObject]");
  x.open("POST", "/webapi/echo");
  await send(x, "abc");
  eq(log.join(), "loadstart,progress,load,loadend", "upload events");
});

test("errors, abort, timeout", async () => {
  const c = new XMLHttpRequest();
  const log = [];
  c.onerror = e => log.push("error " + e.type);
  c.open("GET", OTHER + "/cors/none");
  await send(c);
  eq(log.join(), "error error", "a CORS failure is an error event");
  eq(c.status, 0, "status 0 after an error");
  eq(c.readyState, 4, "DONE");
  eq(c.responseText, "", "no response");
  const ok2 = new XMLHttpRequest();
  ok2.open("GET", OTHER + "/cors/open");
  await send(ok2);
  eq(ok2.responseText, "open", "cross-origin with CORS");
  const a = new XMLHttpRequest();
  const al = [];
  a.onreadystatechange = () => al.push(a.readyState);
  a.onabort = () => al.push("abort");
  a.onloadend = () => al.push("loadend");
  a.open("GET", "/webapi/slow?ms=3000");
  a.send();
  a.abort();
  eq(al.join(), "1,4,abort,loadend", "abort(): DONE, abort, loadend");
  eq(a.readyState, 0, "UNSENT afterwards");
  const t = new XMLHttpRequest();
  t.open("GET", "/webapi/slow?ms=3000");
  t.timeout = 50;
  let timedOut = false;
  t.ontimeout = () => { timedOut = true; };
  await send(t);
  eq(timedOut, true, "timeout event");
  const s = new XMLHttpRequest();
  s.open("GET", "/jsweb/json", false);
  throws(() => s.send(), "NetworkError", "synchronous requests are refused");
  throws(() => { s.timeout = 5; }, "InvalidAccessError", "timeout of a synchronous request");
  const w = new XMLHttpRequest();
  w.open("GET", OTHER + "/cors/creds");
  w.withCredentials = true;
  await send(w);
  ok(w.responseText.startsWith("creds:"), "withCredentials");
  throws(() => { w.withCredentials = false; w.open("GET", "/x"); w.send(); w.withCredentials = true; }, "InvalidStateError", "withCredentials while sending");
  w.abort();
});

test("blob: URL", async () => {
  const u = URL.createObjectURL(new Blob(["xhr blob"], { type: "text/plain" }));
  const x = new XMLHttpRequest();
  x.open("GET", u);
  await send(x);
  eq(x.responseText, "xhr blob", "XMLHttpRequest of a blob: URL");
  eq(x.getResponseHeader("content-type"), "text/plain", "its type");
});

__run();
