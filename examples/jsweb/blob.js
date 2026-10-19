// Blob, File, FileReader, blob: URLs.

test("Blob", async () => {
  const b = new Blob(["ab", new Uint8Array([0x63]), new Blob(["d"]), new Uint16Array([0x6665]).buffer], { type: "Text/Plain" });
  eq(b.size, 6, "size of the parts");
  eq(b.type, "text/plain", "type in lower case");
  eq(await b.text(), "abcdef", "text()");
  eq(new Uint8Array(await b.arrayBuffer())[5], 0x66, "arrayBuffer()");
  ok((await b.bytes()) instanceof Uint8Array, "bytes()");
  const s = b.slice(1, -1, "x/y");
  eq(s.size, 4, "slice size");
  eq(s.type, "x/y", "slice type");
  eq(await s.text(), "bcde", "slice content");
  eq(await b.slice(-2).text(), "ef", "slice from the end");
  eq(new Blob([], { type: "\u00e9" }).type, "", "a type out of range is empty");
  eq(await new Blob(["a\nb"], { endings: "native" }).text(), "a\r\nb", "native line endings");
  eq(new Blob().size, 0, "empty");
  throws(() => new Blob("abc"), "TypeError", "parts must be a sequence");
  eq(await new Blob(["\ud800"]).text(), "\ufffd", "USVString parts");
});

test("File", () => {
  const before = Date.now();
  const f = new File(["x"], "a.txt", { type: "text/plain" });
  ok(f instanceof Blob, "a File is a Blob");
  eq(f.name, "a.txt", "name");
  ok(f.lastModified >= before - 1, "lastModified defaults to now");
  eq(new File([], "b", { lastModified: 42 }).lastModified, 42, "lastModified given");
  throws(() => new File(["x"]), "TypeError", "File needs a name");
});

test("FileReader", async () => {
  const r = new FileReader();
  eq(r.readyState, FileReader.EMPTY, "EMPTY");
  const events = [];
  for (const t of ["loadstart", "progress", "load", "loadend"]) r.addEventListener(t, e => events.push(e.type + ":" + e.loaded));
  const done = new Promise(res => r.onloadend = res);
  r.readAsText(new Blob(["h\u00e9llo"]));
  eq(r.readyState, FileReader.LOADING, "LOADING");
  throws(() => r.readAsText(new Blob([])), "InvalidStateError", "busy");
  await done;
  eq(r.result, "h\u00e9llo", "readAsText");
  eq(events.join(), "loadstart:0,progress:6,load:6,loadend:6", "events");
  const r2 = new FileReader();
  r2.readAsDataURL(new Blob(["hi"], { type: "text/plain" }));
  await new Promise(res => r2.onload = res);
  eq(r2.result, "data:text/plain;base64,aGk=", "readAsDataURL");
  const r3 = new FileReader();
  r3.readAsArrayBuffer(new Blob([new Uint8Array([7, 8])]));
  await new Promise(res => r3.onload = res);
  eq(new Uint8Array(r3.result)[1], 8, "readAsArrayBuffer");
  const r4 = new FileReader();
  r4.readAsText(new Blob([new Uint8Array([0xE9])]), "windows-1252");
  await new Promise(res => r4.onload = res);
  eq(r4.result, "\u00e9", "readAsText with an encoding");
  const r5 = new FileReader();
  let loaded = false;
  r5.onload = () => { loaded = true; };
  const aborted = new Promise(res => r5.onabort = res);
  r5.readAsText(new Blob(["x"]));
  r5.abort();
  await aborted;
  await sleep(20);
  eq(loaded, false, "abort() stops the read");
  eq(r5.result, null, "no result after abort");
});

test("blob: URLs", async () => {
  const b = new Blob(["blob body"], { type: "text/x-test" });
  const u = URL.createObjectURL(b);
  ok(u.startsWith("blob:http://127.0.0.1:8765/"), "blob: URL of this origin");
  const r = await fetch(u);
  eq(r.status, 200, "fetch of a blob: URL");
  eq(r.headers.get("content-type"), "text/x-test", "its type");
  eq(await r.text(), "blob body", "its bytes");
  URL.revokeObjectURL(u);
  await rejects(fetch(u), "TypeError", "a revoked URL fails");
});

__run();
