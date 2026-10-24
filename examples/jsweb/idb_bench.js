// IndexedDB micro-benchmarks (MEASURE lines: the numbers go in the journal of the work, they are not pass / fail).

const rp = (r) => new Promise((resolve, reject) => { r.onsuccess = () => resolve(r.result); r.onerror = (e) => { e.preventDefault(); reject(r.error); }; });
const done = (tx) => new Promise((resolve) => { tx.oncomplete = () => resolve("complete"); tx.onabort = () => resolve("abort"); });
const now = () => performance.now();
function open(name, version, upgrade) {
  return new Promise((resolve, reject) => {
    const r = indexedDB.open(name, version);
    r.onupgradeneeded = () => { if (upgrade) upgrade(r.result, r.transaction); };
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}
const rate = (n, ms) => (n / ms * 1000).toFixed(0) + " /s (" + (ms / n * 1000).toFixed(1) + " us each)";

test("bench: opening and committing", async () => {
  let t0 = now();
  void indexedDB;   // the first use loads the JavaScript of IndexedDB
  measure("first use of indexedDB (the prelude is loaded)", (now() - t0).toFixed(2) + " ms");
  t0 = now();
  const N = 50;
  for (let i = 0; i < N; i++) {
    const db = await open("bench_open_" + i, 1, (db) => { db.createObjectStore("s"); });
    db.close();
  }
  measure("open+upgrade+close of a new database", rate(N, now() - t0));
  const db = await open("bench_open_0");
  t0 = now();
  for (let i = 0; i < N; i++) {
    const tx = db.transaction("s", "readwrite");
    tx.objectStore("s").put(i, i);
    await done(tx);
  }
  measure("one small write transaction (committed to the file)", rate(N, now() - t0));
  t0 = now();
  for (let i = 0; i < N; i++) {
    const tx = db.transaction("s", "readonly");
    await rp(tx.objectStore("s").get(i));
  }
  measure("one small read transaction", rate(N, now() - t0));
  db.close();
  for (let i = 0; i < N; i++) indexedDB.deleteDatabase("bench_open_" + i);
});

test("bench: requests inside one transaction", async () => {
  const db = await open("bench_reqs", 1, (db) => { const s = db.createObjectStore("s", { keyPath: "id" }); s.createIndex("by_k", "k"); });
  const N = 2000;
  let tx = db.transaction("s", "readwrite");
  let s = tx.objectStore("s");
  let t0 = now();
  let last;
  for (let i = 0; i < N; i++) last = s.put({ id: i, k: "key" + (i % 100), text: "value number " + i, n: [i, i + 1] });
  await done(tx);
  measure("put of a small object (with an index)", rate(N, now() - t0));
  tx = db.transaction("s", "readonly");
  s = tx.objectStore("s");
  t0 = now();
  await new Promise((resolve) => {
    let i = 0;
    const next = () => { if (i < N) { const r = s.get(i++); r.onsuccess = next; } else resolve(); };
    next();
  });
  measure("get by key, one after the other", rate(N, now() - t0));
  tx = db.transaction("s", "readonly");
  s = tx.objectStore("s");
  t0 = now();
  const all = await rp(s.getAll());
  measure("getAll of " + all.length + " objects", (now() - t0).toFixed(1) + " ms");
  t0 = now();
  let count = 0;
  await new Promise((resolve) => {
    const c = db.transaction("s").objectStore("s").openCursor();
    c.onsuccess = () => { const cur = c.result; if (cur) { count++; cur.continue(); } else resolve(); };
  });
  measure("cursor over " + count + " records", rate(count, now() - t0));
  t0 = now();
  count = 0;
  await new Promise((resolve) => {
    const c = db.transaction("s").objectStore("s").index("by_k").openCursor("key7");
    c.onsuccess = () => { const cur = c.result; if (cur) { count++; cur.continue(); } else resolve(); };
  });
  measure("index cursor over " + count + " records of one key", rate(count, now() - t0));
  db.close();
  indexedDB.deleteDatabase("bench_reqs");
});

test("bench: bulk data", async () => {
  const db = await open("bench_bulk", 1, (db) => { db.createObjectStore("s"); });
  const big = "x".repeat(100000);
  const tx = db.transaction("s", "readwrite");
  const s = tx.objectStore("s");
  let t0 = now();
  for (let i = 0; i < 100; i++) s.put({ i, text: big }, i);
  await done(tx);
  const ms = now() - t0;
  measure("100 values of 100 KB written (10 MB)", ms.toFixed(0) + " ms, " + (10 / ms * 1000).toFixed(0) + " MB/s");
  t0 = now();
  const got = await rp(db.transaction("s").objectStore("s").getAll());
  measure("read them back with getAll", (now() - t0).toFixed(0) + " ms (" + got.length + ")");
  db.close();
  indexedDB.deleteDatabase("bench_bulk");
});

__run();
