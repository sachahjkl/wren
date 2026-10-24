// The keys and key paths IndexedDB does in the browser's code (runtime/web_idb_native.c): the order of keys of every type, what is
// not a key, strings with the code units that need care, key paths on a value (nested, arrays, Blob, strings), multi-entry
// indexes, generated keys injected at a path, and what a getter that throws does.

const rp = (r) => new Promise((resolve, reject) => { r.onsuccess = () => resolve(r.result); r.onerror = (e) => { e.preventDefault(); reject(r.error); }; });
const txDone = (tx) => new Promise((resolve) => { tx.oncomplete = () => resolve("complete"); tx.onabort = () => resolve("abort"); });
const cmp = (a, b) => indexedDB.cmp(a, b);

test("keys: the order of the types, and round trips", async () => {
  const buf = (...b) => new Uint8Array(b).buffer;
  const ordered = [-Infinity, -1e300, -1.5, -0.0000001, 0, 5e-324, 1, 2, 1e300, Infinity,
    new Date(-1), new Date(0), new Date(1e12), "", "\u0000", "a", "a\u0000", "ab", "\ud7ff", "\ud800", "\ud800\udc00", "\udbff\udfff", "\ue000", "\ufffd", "\ufffe", "\uffff",
    buf(), buf(0), buf(0, 0), buf(0, 1), buf(1), buf(255),
    [], [-1], [0, "a"], [0, "b"], ["a"], [buf(1)], [[]], [[0]]];
  for (let i = 1; i < ordered.length; i++) eq(cmp(ordered[i - 1], ordered[i]), -1, "order " + i);
  for (const k of ordered) eq(cmp(k, k), 0, "equal to itself");
  eq(cmp(-0, 0), 0, "-0 is 0");
  eq(cmp(0, -0), 0, "0 is -0");
  eq(Object.is(IDBKeyRange.only(-0).lower, 0), true, "-0 comes back as 0");
  const back = IDBKeyRange.only([1, "x\ud800", new Date(7), buf(0, 3, 0)]).lower;
  eq(back.length, 4, "an array comes back");
  eq(back[1], "x\ud800", "a lone surrogate comes back");
  eq(back[2].getTime(), 7, "a date comes back");
  eq(new Uint8Array(back[3]).join(","), "0,3,0", "a binary key with zeros comes back");
  eq(IDBKeyRange.only("\ufffe\uffff").lower, "\ufffe\uffff", "U+FFFE and U+FFFF come back");
  eq(cmp(new Uint8Array([1, 2]), buf(1, 2)), 0, "a view is its bytes");
  eq(cmp(new DataView(buf(1, 2, 3), 1, 1), buf(2)), 0, "a view with an offset and a length is its bytes");
});

test("keys: what is not a key", () => {
  const bad = [NaN, undefined, null, true, {}, () => 1, Symbol("s"), 1n, new Date(NaN), /x/, [undefined], [, 1], [1, {}]];
  for (const b of bad) throws(() => cmp(b, 1), "DataError", "not a key: " + String(typeof b === "symbol" ? "symbol" : b));
  const loop = []; loop.push(loop);
  throws(() => cmp(loop, 1), "DataError", "an array that contains itself");
  let deep = []; for (let i = 0; i < 70; i++) deep = [deep];
  throws(() => cmp(deep, 1), "DataError", "an array nested 70 deep");
  let ok = []; for (let i = 0; i < 60; i++) ok = [ok];
  eq(cmp(ok, ok), 0, "an array nested 60 deep");
  throws(() => cmp(new Proxy([1], {}), 1), "DataError", "a Proxy of an array");
  const detached = new ArrayBuffer(4);
  structuredClone(detached, { transfer: [detached] });
  throws(() => cmp(detached, 1), "DataError", "a detached buffer");
  const boom = new Error("boom");
  let thrown = null;
  try { cmp({ get [Symbol.toPrimitive]() { throw boom; } }, 1); } catch (e) { thrown = e; }
  eq(thrown instanceof DOMException, true, "an object is no key, whatever its getters");
  const arr = [1]; Object.defineProperty(arr, 1, { get() { throw boom; }, enumerable: true });
  thrown = null;
  try { cmp(arr, 1); } catch (e) { thrown = e; }
  eq(thrown, boom, "what a getter of an element throws is thrown");
});

test("key paths: the validity, and the values they give", async () => {
  const db = await rp(Object.assign(indexedDB.open("keys_paths", 1), { onupgradeneeded() {} }));
  db.close();
  await new Promise((res) => { const r = indexedDB.open("keys_paths", 2); r.onupgradeneeded = () => {
    const d = r.result;
    for (const good of ["", "a", "a.b", "$", "_", "a$b", "\u00e9t\u00e9", "\u{1d49c}", "a\u200cb", "public.true", ["a", "b.c"], [""]]) d.createObjectStore("ok" + JSON.stringify(good) + Math.random(), { keyPath: good });
    for (const bad of ["a..b", "a.", ".a", "1a", "a b", "a-b", "a[0]", [], ["a", 1], ["a..b"], "\u{1f600}"]) {
      throws(() => d.createObjectStore("bad" + Math.random(), { keyPath: bad }), "SyntaxError", "an invalid key path " + JSON.stringify(bad));
    }
    r.transaction.oncomplete = res;
  }; });
  const db2 = await rp(indexedDB.open("keys_paths", 2));
  db2.close();
  indexedDB.deleteDatabase("keys_paths");

  const d = await rp(Object.assign(indexedDB.open("keys_values", 1), { onupgradeneeded() {
    const r = this.result;
    const s = r.createObjectStore("s", { keyPath: "id" });
    s.createIndex("deep", "a.b.c");
    s.createIndex("len", "name.length");
    s.createIndex("tags", "tags", { multiEntry: true });
    s.createIndex("tagsOne", "tags");
    s.createIndex("pair", ["a.b.c", "name"]);
    const g = r.createObjectStore("g", { keyPath: "k.id", autoIncrement: true });
    g.createIndex("x", "x");
  } }));
  const tx = d.transaction(["s", "g"], "readwrite");
  const s = tx.objectStore("s"), g = tx.objectStore("g");
  s.put({ id: 1, a: { b: { c: 5 } }, name: "abc", tags: ["x", "y", "x", {}, "z", ["w"]] });
  s.put({ id: 2, a: { b: {} }, name: "de", tags: "single" });
  s.put({ id: new Date(3), a: { b: { c: "s" } }, name: "", tags: [] });
  const k1 = await rp(g.put({ x: 1 }));
  const k2 = await rp(g.put({ x: 2, k: {} }));
  const k3 = await rp(g.put({ x: 3, k: { other: true } }));
  eq(await txDone(tx), "complete", "the writes");
  eq(k1 + "," + k2 + "," + k3, "1,2,3", "the generated keys");
  const t2 = d.transaction(["s", "g"]);
  const idx = (n, q) => rp(t2.objectStore("s").index(n).getAllKeys(q));
  eq((await idx("deep")).map((k) => k instanceof Date ? "date" : k).join(","), "1,date", "the deep index: 5 (key 1) before a string (the Date key)");
  eq((await idx("deep")).length, 2, "a missing step gives no entry");
  eq(JSON.stringify(await rp(t2.objectStore("s").index("len").getAllKeys())).length > 2, true, "the length index");
  eq((await rp(t2.objectStore("s").index("len").getAll())).map((v) => v.name.length).join(","), "0,2,3", "name.length orders them");
  eq((await idx("tags")).length, 5, "a multi-entry index: one entry per distinct valid element (x, y, z, [w] and single)");
  eq((await rp(t2.objectStore("s").index("tags").count("x"))), 1, "a duplicate element is one entry");
  eq((await idx("tagsOne")).length, 2, "a plain index: an array is one key when all its elements are keys (the one with {} gives none)");
  eq((await rp(t2.objectStore("s").index("pair").getAllKeys())).length, 2, "an array key path gives an array key");
  const gv = await rp(t2.objectStore("g").getAll());
  eq(JSON.stringify(gv.map((v) => v.k.id)), "[1,2,3]", "a generated key is injected at the path");
  eq(gv[2].k.other, true, "the rest of the value is kept");
  d.close();
  indexedDB.deleteDatabase("keys_values");
});

test("key paths: Blob, File, strings and arrays", async () => {
  const d = await rp(Object.assign(indexedDB.open("keys_blob", 1), { onupgradeneeded() {
    const r = this.result;
    const s = r.createObjectStore("s", { autoIncrement: true });
    s.createIndex("size", "size");
    s.createIndex("type", "type");
    s.createIndex("name", "name");
    s.createIndex("mod", "lastModified");
    s.createIndex("len", "length");
  } }));
  const tx = d.transaction("s", "readwrite");
  const s = tx.objectStore("s");
  s.put(new Blob(["abcd"], { type: "text/plain" }));
  s.put(new File(["xy"], "f.txt", { type: "text/x", lastModified: 5000 }));
  s.put("hello");
  s.put([1, 2, 3]);
  eq(await txDone(tx), "complete", "writes");
  const t2 = d.transaction("s");
  const ix = (n) => rp(t2.objectStore("s").index(n).getAllKeys());
  eq((await ix("size")).join(","), "2,1", "size of a File (key 2) and of a Blob (key 1), by size");
  eq((await ix("type")).join(","), "1,2", "type of both");
  eq((await ix("name")).join(","), "2", "name of a File only");
  eq((await ix("mod")).join(","), "2", "lastModified of a File only");
  eq((await ix("len")).join(","), "4,3", "length of an array (key 4) and of a string (key 3), by length");
  d.close();
  indexedDB.deleteDatabase("keys_blob");
});

__run();