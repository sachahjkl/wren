// IndexedDB: databases, versions, object stores, indexes, keys, cursors, transactions, structured clones, abort.

const rp = (r) => new Promise((resolve, reject) => {
  r.onsuccess = () => resolve(r.result);
  r.onerror = (e) => { e.preventDefault(); reject(r.error); };
});
const txDone = (tx) => new Promise((resolve, reject) => {
  tx.oncomplete = () => resolve("complete");
  tx.onabort = () => resolve("abort");
  tx.onerror = () => {};
});
function open(name, version, upgrade) {
  return new Promise((resolve, reject) => {
    const r = indexedDB.open(name, version);
    r.onupgradeneeded = (e) => { if (upgrade) upgrade(r.result, e, r.transaction); };
    r.onsuccess = () => resolve(r.result);
    r.onerror = (e) => { e.preventDefault(); reject(r.error); };
    r.onblocked = () => { };
  });
}
let n = 0;
const fresh = () => "db" + (++n) + "_" + Math.random().toString(36).slice(2, 8);

test("the factory", async () => {
  ok(typeof indexedDB === "object" && indexedDB instanceof IDBFactory, "indexedDB is an IDBFactory");
  ok(indexedDB === window.indexedDB, "one factory");
  eq(indexedDB.cmp(1, 2), -1, "cmp 1 < 2");
  eq(indexedDB.cmp("a", "a"), 0, "cmp equal");
  eq(indexedDB.cmp([1, 2], [1]), 1, "cmp arrays");
  eq(indexedDB.cmp(new Date(5), 1000), 1, "a date is above a number");
  eq(indexedDB.cmp("a", new Uint8Array([1])), -1, "a string is below binary");
  eq(indexedDB.cmp(-0, 0), 0, "-0 is 0");
  throws(() => indexedDB.cmp(NaN, 1), "DataError", "NaN is not a key");
  throws(() => indexedDB.cmp({}, 1), "DataError", "an object is not a key");
  throws(() => indexedDB.cmp(1), "TypeError", "cmp needs two arguments");
  throws(() => new IDBFactory(), "TypeError", "no constructor");
  const name = fresh();
  const r = indexedDB.open(name);
  ok(r instanceof IDBOpenDBRequest && r instanceof IDBRequest && r instanceof EventTarget, "an IDBOpenDBRequest");
  eq(r.readyState, "pending", "pending");
  throws(() => r.result, "InvalidStateError", "no result yet");
  const db = await new Promise((res) => { r.onupgradeneeded = () => {}; r.onsuccess = () => res(r.result); });
  ok(db instanceof IDBDatabase, "a database");
  eq(db.name, name, "name");
  eq(db.version, 1, "version 1");
  eq(db.objectStoreNames.length, 0, "no stores");
  db.close();
  throws(() => indexedDB.open(name, 0), "TypeError", "version 0");
  throws(() => indexedDB.open(name, -1), "TypeError", "negative version");
  throws(() => indexedDB.open(name, NaN), "TypeError", "NaN version");
});

test("create stores, put, get, delete", async () => {
  const name = fresh();
  const db = await open(name, 1, (db) => {
    const s = db.createObjectStore("people", { keyPath: "id" });
    s.createIndex("by_name", "name");
    s.createIndex("by_age", "age", { unique: false });
    db.createObjectStore("notes", { autoIncrement: true });
    db.createObjectStore("plain");
  });
  eq([...db.objectStoreNames].join(), "notes,people,plain", "sorted names");
  ok(db.objectStoreNames.contains("people") && !db.objectStoreNames.contains("x"), "contains");
  const tx = db.transaction(["people", "notes"], "readwrite");
  eq(tx.mode, "readwrite", "mode");
  ok(tx.db === db, "tx.db");
  const people = tx.objectStore("people");
  ok(people === tx.objectStore("people"), "the same store object");
  eq(people.name, "people", "store name");
  eq(people.keyPath, "id", "keyPath");
  eq(people.autoIncrement, false, "autoIncrement");
  eq([...people.indexNames].join(), "by_age,by_name", "index names");
  const k = await rp(people.put({ id: 1, name: "Ada", age: 36 }));
  eq(k, 1, "put returns the key");
  await rp(people.add({ id: 2, name: "Alan", age: 41 }));
  await rp(people.add({ id: 3, name: "Grace", age: 36 }));
  let err = null;
  try { await rp(people.add({ id: 2, name: "dup" })); } catch (e) { err = e; }
  eq(err && err.name, "ConstraintError", "add on an existing key fails");
  const notes = tx.objectStore("notes");
  eq(await rp(notes.add("first")), 1, "generated key 1");
  eq(await rp(notes.add("second")), 2, "generated key 2");
  eq(await rp(notes.put("third", 10)), 10, "explicit key");
  eq(await rp(notes.add("fourth")), 11, "the generator follows");
  eq(await txDone(tx), "complete", "complete");

  const t2 = db.transaction(["people", "notes", "plain"], "readwrite");
  const p2 = t2.objectStore("people");
  const got = await rp(p2.get(2));
  eq(got.name, "Alan", "get");
  eq(await rp(p2.get(99)), undefined, "absent is undefined");
  eq(await rp(p2.getKey(3)), 3, "getKey");
  eq(await rp(p2.count()), 3, "count");
  eq((await rp(p2.getAll())).map((x) => x.id).join(), "1,2,3", "getAll");
  eq((await rp(p2.getAllKeys(IDBKeyRange.lowerBound(2)))).join(), "2,3", "getAllKeys with a range");
  eq((await rp(p2.getAll(null, 2))).length, 2, "getAll with a count");
  eq((await rp(p2.index("by_name").get("Grace"))).id, 3, "index get");
  eq(await rp(p2.index("by_age").count(36)), 2, "index count");
  eq((await rp(p2.index("by_age").getAllKeys(36))).join(), "1,3", "index getAllKeys gives primary keys");
  eq(await rp(p2.delete(IDBKeyRange.bound(1, 2))), undefined, "delete");
  eq(await rp(p2.count()), 1, "deleted");
  await rp(p2.clear());
  eq(await rp(p2.count()), 0, "cleared");
  const plain = t2.objectStore("plain");
  await rp(plain.put("v", [1, "a", new Date(7)]));
  eq((await rp(plain.get([1, "a", new Date(7)]))), "v", "array and date keys");
  await txDone(t2);
  db.close();
});

test("errors thrown by the methods", async () => {
  const db = await open(fresh(), 1, (db) => { db.createObjectStore("s", { keyPath: "k" }); db.createObjectStore("o"); });
  const ro = db.transaction("s", "readonly");
  const roDone = txDone(ro);
  const s = ro.objectStore("s");
  throws(() => s.put({ k: 1 }), "ReadOnlyError", "put in a read-only transaction");
  throws(() => s.get(), "TypeError", "get needs an argument");
  throws(() => s.get(undefined), "DataError", "undefined is not a key");
  throws(() => s.get({}), "DataError", "an object is not a key");
  throws(() => db.transaction("missing"), "NotFoundError", "unknown store");
  throws(() => db.transaction([]), "InvalidAccessError", "empty scope");
  throws(() => db.transaction("s", "versionchange"), "TypeError", "versionchange mode");
  throws(() => db.createObjectStore("x"), "InvalidStateError", "createObjectStore outside an upgrade");
  throws(() => ro.objectStore("o"), "NotFoundError", "a store outside the scope");
  const rw = db.transaction(["s", "o"], "readwrite");
  const o = rw.objectStore("o");
  throws(() => o.put(1), "DataError", "out-of-line store needs a key");
  throws(() => rw.objectStore("s").put({ k: 1 }, 1), "DataError", "in-line store refuses a key");
  throws(() => rw.objectStore("s").put({ nokey: 1 }), "DataError", "no key at the path");
  throws(() => rw.objectStore("s").put(() => 1), "DataCloneError", "functions do not clone");
  throws(() => o.put(1, {}), "DataError", "invalid key");
  throws(() => o.openCursor(null, "sideways"), "TypeError", "bad direction");
  const rwDone = txDone(rw);
  await rwDone;
  throws(() => o.put(1, 1), "TransactionInactiveError", "a finished transaction");
  await roDone;
  db.close();
  throws(() => db.transaction("s"), "InvalidStateError", "a closed connection");
});

test("cursors", async () => {
  const db = await open(fresh(), 1, (db) => {
    const s = db.createObjectStore("s", { keyPath: "id" });
    s.createIndex("g", "group");
  });
  const tx = db.transaction("s", "readwrite");
  const s = tx.objectStore("s");
  for (let i = 1; i <= 9; i++) s.put({ id: i, group: "g" + (i % 3), v: i * i });
  const walk = (src, range, dir, keyOnly) => new Promise((resolve) => {
    const out = [];
    const r = keyOnly ? src.openKeyCursor(range, dir) : src.openCursor(range, dir);
    r.onsuccess = () => {
      const c = r.result;
      if (!c) { resolve(out); return; }
      out.push(c.key + ":" + c.primaryKey + (keyOnly ? "" : ":" + c.value.v));
      c.continue();
    };
  });
  eq((await walk(s, null, "next")).join(), "1:1:1,2:2:4,3:3:9,4:4:16,5:5:25,6:6:36,7:7:49,8:8:64,9:9:81", "forward");
  eq((await walk(s, IDBKeyRange.bound(3, 5), "prev")).join(), "5:5:25,4:4:16,3:3:9", "backward with a range");
  eq((await walk(s.index("g"), null, "next", true)).join(), "g0:3,g0:6,g0:9,g1:1,g1:4,g1:7,g2:2,g2:5,g2:8", "index key cursor");
  eq((await walk(s.index("g"), null, "nextunique", true)).join(), "g0:3,g1:1,g2:2", "nextunique");
  eq((await walk(s.index("g"), null, "prevunique", true)).join(), "g2:2,g1:1,g0:3", "prevunique gives the first record of each key");
  eq((await walk(s.index("g"), "g1", "prev", true)).join(), "g1:7,g1:4,g1:1", "index prev on one key");
  const r = s.openCursor();
  const keys = await new Promise((resolve) => {
    const seen = [];
    r.onsuccess = () => {
      const c = r.result;
      if (!c) { resolve(seen); return; }
      seen.push(c.key);
      if (c.key === 1) c.advance(3); else c.continue(c.key + 2);
    };
  });
  eq(keys.join(), "1,4,6,8", "advance and continue(key)");
  // continuePrimaryKey
  const r2 = s.index("g").openCursor();
  const cp = await new Promise((resolve) => {
    const seen = [];
    let first = true;
    r2.onsuccess = () => {
      const c = r2.result;
      if (!c) { resolve(seen); return; }
      seen.push(c.key + ":" + c.primaryKey);
      if (first) { first = false; c.continuePrimaryKey("g0", 6); } else c.continue();
    };
  });
  eq(cp.join(), "g0:3,g0:6,g0:9,g1:1,g1:4,g1:7,g2:2,g2:5,g2:8", "continuePrimaryKey to the next record");
  // update and delete through a cursor
  await new Promise((resolve) => {
    const c = s.openCursor(IDBKeyRange.bound(1, 3));
    c.onsuccess = () => {
      const cur = c.result;
      if (!cur) { resolve(); return; }
      if (cur.key === 2) cur.delete(); else { const v = cur.value; v.v = -v.v; cur.update(v); }
      cur.continue();
    };
  });
  eq((await rp(s.getAll(IDBKeyRange.bound(1, 4)))).map((x) => x.v).join(), "-1,-9,16", "update and delete");
  await txDone(tx);
  db.close();
});

test("structured clones", async () => {
  const db = await open(fresh(), 1, (db) => { db.createObjectStore("s"); });
  const tx = db.transaction("s", "readwrite");
  const s = tx.objectStore("s");
  const date = new Date(1234567890123);
  const map = new Map([[1, "a"], ["b", { c: 2 }]]);
  const set = new Set([1, 2, 3]);
  const buf = new Uint8Array([1, 2, 3, 250]).buffer;
  const typed = new Float64Array([1.5, -2.5, 1e300]);
  const nested = { a: [1, { b: new Date(5) }], re: /x+/gi, big: 12345678901234567890n, undef: undefined, nul: null, neg0: -0 };
  const cyc = { name: "loop" }; cyc.self = cyc;
  const err = new RangeError("boom");
  await rp(s.put({ date, map, set, buf, typed, nested, cyc, err }, "all"));
  const back = await rp(s.get("all"));
  ok(back.date instanceof Date && back.date.getTime() === 1234567890123, "Date");
  ok(back.map instanceof Map && back.map.get("b").c === 2, "Map");
  ok(back.set instanceof Set && back.set.has(2), "Set");
  ok(back.buf instanceof ArrayBuffer && new Uint8Array(back.buf)[3] === 250, "ArrayBuffer");
  ok(back.typed instanceof Float64Array && back.typed[2] === 1e300, "typed array");
  ok(back.nested.a[1].b instanceof Date && back.nested.re.flags === "gi" && back.nested.big === 12345678901234567890n, "nested values");
  ok("undef" in back.nested && back.nested.undef === undefined && back.nested.nul === null && Object.is(back.nested.neg0, -0), "undefined, null, -0");
  ok(back.cyc.self === back.cyc, "cycles");
  ok(back.err instanceof RangeError && back.err.message === "boom", "Error");
  ok(back.date !== date, "a copy");
  // the value is a snapshot of the moment of the call
  const obj = { v: 1 };
  const req = s.put(obj, "snap");
  obj.v = 2;
  await rp(req);
  eq((await rp(s.get("snap"))).v, 1, "put stores a snapshot");
  const blob = new Blob(["hello blob"], { type: "text/plain" });
  await rp(s.put({ blob, file: new File(["file data"], "f.txt", { type: "text/x-test", lastModified: 99 }) }, "blobs"));
  const b = await rp(s.get("blobs"));
  ok(b.blob instanceof Blob && b.blob.size === 10 && b.blob.type === "text/plain", "Blob");
  eq(await b.blob.text(), "hello blob", "Blob contents");
  ok(b.file instanceof File && b.file.name === "f.txt" && b.file.lastModified === 99, "File");
  await txDone(tx);
  db.close();
});

test("transactions: order, abort, auto-commit", async () => {
  const db = await open(fresh(), 1, (db) => { db.createObjectStore("s", { keyPath: "k" }); });
  // an aborted transaction leaves nothing
  const t1 = db.transaction("s", "readwrite");
  const s1 = t1.objectStore("s");
  s1.put({ k: 1 });
  const aborted = txDone(t1);
  const putReq = s1.put({ k: 2 });
  const errs = [];
  putReq.onerror = (e) => { errs.push(e.target.error.name); e.preventDefault(); };
  t1.abort();
  eq(await aborted, "abort", "abort event");
  eq(errs.join(), "AbortError", "pending requests fail with AbortError");
  eq(t1.error, null, "an explicit abort has no error");
  throws(() => t1.abort(), "InvalidStateError", "abort twice");
  const t2 = db.transaction("s");
  eq(await rp(t2.objectStore("s").count()), 0, "nothing was stored");
  // two writers run one after the other; a reader started between sees the first
  const order = [];
  const w1 = db.transaction("s", "readwrite");
  const w2 = db.transaction("s", "readwrite");
  const r3 = db.transaction("s", "readonly");
  w1.oncomplete = () => order.push("w1 complete");
  w2.oncomplete = () => order.push("w2 complete");
  r3.oncomplete = () => order.push("r3 complete");
  w1.objectStore("s").put({ k: 10 }).onsuccess = () => order.push("w1 put");
  w2.objectStore("s").put({ k: 20 }).onsuccess = () => order.push("w2 put");
  const seen = await new Promise((resolve) => {
    r3.objectStore("s").getAllKeys().onsuccess = (e) => { order.push("r3 read"); resolve(e.target.result); };
  });
  eq(seen.join(), "10,20", "a reader created after two writers sees both");
  await new Promise((r) => { r3.oncomplete = r; });
  eq(order.slice(0, 4).join(), "w1 put,w1 complete,w2 put,w2 complete", "writers in creation order");
  // an exception in a handler aborts the transaction
  const t3 = db.transaction("s", "readwrite");
  const res = txDone(t3);
  t3.objectStore("s").put({ k: 30 }).onsuccess = () => { throw new Error("handler failed"); };
  eq(await res, "abort", "a throwing handler aborts");
  eq(t3.error && t3.error.name, "AbortError", "with AbortError");
  // a failed request aborts unless the error is handled
  const t4 = db.transaction("s", "readwrite");
  const res4 = txDone(t4);
  t4.objectStore("s").add({ k: 10 });
  eq(await res4, "abort", "an unhandled request error aborts");
  eq(t4.error && t4.error.name, "ConstraintError", "with the request's error");
  const t5 = db.transaction("s", "readwrite");
  const res5 = txDone(t5);
  const dup = t5.objectStore("s").add({ k: 10 });
  dup.onerror = (e) => e.preventDefault();
  eq(await res5, "complete", "a prevented error does not abort");
  // the transaction is inactive once the callback returned (kept alive here by a chain of requests)
  const t6 = db.transaction("s", "readonly");
  const st6 = t6.objectStore("s");
  let chain = 0;
  const next = () => { if (++chain < 300) st6.get(1).onsuccess = next; };
  next();
  let late = null;
  await new Promise((r) => { setTimeout(() => { try { st6.get(1); late = "no error"; } catch (e) { late = e.name; } r(); }, 0); });
  eq(late, "TransactionInactiveError", "inactive after a task");
  // ... but alive through microtasks and in the callbacks of its requests
  const t7 = db.transaction("s", "readonly");
  const st7 = t7.objectStore("s");
  await Promise.resolve();
  const v7 = await rp(st7.get(10));
  eq(v7.k, 10, "usable across a microtask");
  const v8 = await rp(st7.get(20));
  eq(v8.k, 20, "usable inside a request callback's microtasks");
  db.close();
});

test("versions: upgrade, versionchange, blocked, delete", async () => {
  const name = fresh();
  const events = [];
  const db1 = await open(name, 1, (db, e) => { events.push("upgrade1 " + e.oldVersion + "->" + e.newVersion); db.createObjectStore("a"); });
  db1.onversionchange = (e) => { events.push("versionchange " + e.oldVersion + "->" + e.newVersion); };
  const r2 = indexedDB.open(name, 2);
  r2.onblocked = (e) => { events.push("blocked " + e.oldVersion + "->" + e.newVersion); db1.close(); };
  r2.onupgradeneeded = (e) => { events.push("upgrade2 " + e.oldVersion + "->" + e.newVersion); r2.result.createObjectStore("b"); };
  const db2 = await new Promise((resolve) => { r2.onsuccess = () => resolve(r2.result); });
  eq(events.join("|"), "upgrade1 0->1|versionchange 1->2|blocked 1->2|upgrade2 1->2", "events in order");
  eq(db2.version, 2, "version 2");
  eq([...db2.objectStoreNames].join(), "a,b", "stores of both");
  const lower = indexedDB.open(name, 1);
  const verr = await new Promise((resolve) => { lower.onerror = (e) => { e.preventDefault(); resolve(lower.error.name); }; lower.onsuccess = () => resolve("success"); });
  eq(verr, "VersionError", "a lower version fails");
  const list = await indexedDB.databases();
  ok(list.some((d) => d.name === name && d.version === 2), "databases() lists it");
  // closing in versionchange: no blocked
  db2.onversionchange = () => db2.close();
  let blocked = false;
  const r3 = indexedDB.open(name, 3);
  r3.onblocked = () => { blocked = true; };
  const db3 = await new Promise((resolve) => { r3.onsuccess = () => resolve(r3.result); });
  eq(blocked, false, "no blocked event when the connection closes in its handler");
  db3.close();
  const del = indexedDB.deleteDatabase(name);
  const dv = await new Promise((resolve) => { del.onsuccess = (e) => resolve(e.oldVersion); });
  eq(dv, 3, "deleteDatabase reports the old version");
  ok(!(await indexedDB.databases()).some((d) => d.name === name), "gone from databases()");
  const again = await open(name, undefined, (db, e) => events.push("again " + e.oldVersion));
  eq(again.version, 1, "recreated at version 1");
  again.close();
  // an aborted upgrade
  const name2 = fresh();
  const r4 = indexedDB.open(name2, 1);
  r4.onupgradeneeded = () => { r4.result.createObjectStore("x"); r4.transaction.abort(); };
  const res4 = await new Promise((resolve) => { r4.onerror = (e) => { e.preventDefault(); resolve(r4.error.name); }; r4.onsuccess = () => resolve("success"); });
  eq(res4, "AbortError", "an aborted upgrade fails the open");
  ok(!(await indexedDB.databases()).some((d) => d.name === name2), "and leaves no database");
});

test("indexes: unique, multiEntry, key paths", async () => {
  const db = await open(fresh(), 1, (db) => {
    const s = db.createObjectStore("s", { keyPath: ["a", "b"] });
    s.createIndex("tags", "tags", { multiEntry: true });
    s.createIndex("email", "email", { unique: true });
    s.createIndex("deep", "x.y.z");
    s.createIndex("pair", ["a", "tags"]);
  });
  const tx = db.transaction("s", "readwrite");
  const s = tx.objectStore("s");
  eq(JSON.stringify(s.keyPath), '["a","b"]', "array key path");
  await rp(s.put({ a: 1, b: 2, tags: ["x", "y", "x"], email: "e1", x: { y: { z: 5 } } }));
  await rp(s.put({ a: 1, b: 3, tags: ["y"], email: "e2" }));
  let err = null;
  try { await rp(s.put({ a: 1, b: 4, email: "e1" })); } catch (e) { err = e; }
  eq(err && err.name, "ConstraintError", "unique index violated");
  eq((await rp(s.index("tags").getAllKeys("y"))).map((k) => k.join("-")).join(), "1-2,1-3", "multiEntry lists a record under each tag");
  eq(await rp(s.index("tags").count("x")), 1, "a repeated tag counts once");
  eq((await rp(s.index("deep").getAllKeys(5))).length, 1, "nested key path");
  eq(await rp(s.index("pair").count()), 2, "an array key path whose parts are keys (an array is one)");
  eq(s.index("email").unique, true, "unique");
  eq(s.index("tags").multiEntry, true, "multiEntry");
  eq(s.index("tags").objectStore, s, "index.objectStore");
  await txDone(tx).catch(() => {});
  db.close();
});

test("createIndex on existing records, rename, delete", async () => {
  const name = fresh();
  const db1 = await open(name, 1, (db) => {
    const s = db.createObjectStore("s", { keyPath: "id" });
    for (let i = 0; i < 700; i++) s.put({ id: i, mod: i % 10, name: "n" + i });
  });
  db1.close();
  const db2 = await open(name, 2, (db, e, tx) => {
    const s = tx.objectStore("s");
    s.createIndex("mod", "mod");
    s.createIndex("name", "name", { unique: true });
    s.name = "renamed";
    s.index("mod").name = "m";
  });
  eq([...db2.objectStoreNames].join(), "renamed", "renamed store");
  const tx = db2.transaction("renamed");
  const s = tx.objectStore("renamed");
  eq([...s.indexNames].join(), "m,name", "renamed index");
  eq(await rp(s.index("m").count(3)), 70, "700 records indexed in batches");
  eq((await rp(s.index("name").get("n699"))).id, 699, "unique index populated");
  db2.close();
  const db3 = await open(name, 3, (db, e, tx) => {
    tx.objectStore("renamed").deleteIndex("m");
    db.deleteObjectStore("renamed");
    db.createObjectStore("fresh");
  });
  eq([...db3.objectStoreNames].join(), "fresh", "deleted and created");
  db3.close();
  // a unique index that existing records violate aborts the upgrade
  const name2 = fresh();
  const d = await open(name2, 1, (db) => { const s = db.createObjectStore("s", { autoIncrement: true }); s.put({ v: 1 }); s.put({ v: 1 }); });
  d.close();
  const r = indexedDB.open(name2, 2);
  r.onupgradeneeded = () => { r.transaction.objectStore("s").createIndex("v", "v", { unique: true }); };
  const res = await new Promise((resolve) => { r.onerror = (e) => { e.preventDefault(); resolve(r.error.name); }; r.onsuccess = () => resolve("success"); });
  eq(res, "AbortError", "the upgrade aborts");
  const again = await open(name2);
  eq(again.version, 1, "back at version 1");
  eq(again.transaction("s").objectStore("s").indexNames.length, 0, "without the index");
  again.close();
});

test("key ranges", async () => {
  const r = IDBKeyRange.bound(1, 5, true, false);
  ok(r instanceof IDBKeyRange, "an IDBKeyRange");
  eq([r.lower, r.upper, r.lowerOpen, r.upperOpen].join(), "1,5,true,false", "attributes");
  ok(!r.includes(1) && r.includes(5) && r.includes(3) && !r.includes(6), "includes");
  const o = IDBKeyRange.only("k");
  ok(o.includes("k") && !o.includes("l"), "only");
  eq(IDBKeyRange.lowerBound(3).upper, undefined, "no upper");
  eq(IDBKeyRange.upperBound(3, true).upperOpen, true, "upperBound open");
  throws(() => IDBKeyRange.bound(5, 1), "DataError", "lower above upper");
  throws(() => IDBKeyRange.bound(1, 1, true), "DataError", "empty range");
  throws(() => IDBKeyRange.only({}), "DataError", "invalid key");
  throws(() => new IDBKeyRange(), "TypeError", "no constructor");
  ok(IDBKeyRange.bound("a", "z").includes("m"), "strings");
  ok(IDBKeyRange.bound([1], [2]).includes([1, 5]), "arrays");
});

test("persistence across connections and the quota", async () => {
  const name = fresh();
  const db = await open(name, 1, (db) => { db.createObjectStore("s"); });
  const tx = db.transaction("s", "readwrite");
  tx.objectStore("s").put("kept", "k");
  await txDone(tx);
  db.close();
  const db2 = await open(name);
  eq(await rp(db2.transaction("s").objectStore("s").get("k")), "kept", "still there after a reopen");
  db2.close();
});

__run();
