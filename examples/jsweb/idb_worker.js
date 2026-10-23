// IndexedDB in a dedicated worker (with idb_worker_script.js): the worker and the page of one origin are clients of one manager:
// versionchange reaches the worker, the page's open is blocked until the worker closes, transactions of both are ordered, a
// terminated worker's connections close (a deletion is not blocked for ever), and the data is the same for both.

const rp = (r) => new Promise((resolve, reject) => { r.onsuccess = () => resolve(r.result); r.onerror = (e) => { e.preventDefault(); reject(r.error); }; });
const txDone = (tx) => new Promise((resolve) => { tx.oncomplete = () => resolve("complete"); tx.onabort = () => resolve("abort"); });

const inbox = [];
const waiting = [];
function deliver() {
  for (let i = waiting.length - 1; i >= 0; i--) {
    const k = inbox.findIndex((m) => m.ev === waiting[i].ev);
    if (k >= 0) { const [m] = inbox.splice(k, 1); const [w] = waiting.splice(i, 1); w.resolve(m); }
  }
}
const worker = new Worker("/jsweb/js/idb_worker_script.js");
worker.onmessage = (e) => { inbox.push(e.data); deliver(); };
worker.onerror = (e) => { inbox.push({ ev: "workerError", message: e.message }); deliver(); };
const expect = (ev) => new Promise((resolve) => { waiting.push({ ev, resolve }); deliver(); });

test("worker: IndexedDB exists and opens a database", async () => {
  worker.postMessage({ cmd: "open1" });
  const m = await Promise.race([expect("opened"), expect("error"), expect("workerError")]);
  eq(m.ev, "opened", "the worker opened a database (" + JSON.stringify(m) + ")");
  eq(m.version, 1, "version 1");
  eq(m.type, "object", "indexedDB in the worker");
  eq(m.name, "[object IDBFactory]", "an IDBFactory");
  eq(m.keyRange, "function", "IDBKeyRange in the worker");
  eq(m.cmp, -1, "indexedDB.cmp");
});

test("worker: versionchange and blocked between a page and a worker", async () => {
  let blocked = false;
  const upgraded = new Promise((resolve, reject) => {
    const r = indexedDB.open("worker_shared", 2);
    r.onblocked = () => { blocked = true; };
    r.onupgradeneeded = (e) => {
      ok(blocked, "blocked came first (the worker still held its connection)");
      eq(e.oldVersion, 1, "from 1");
      const s = r.transaction.objectStore("s");
      s.put({ id: 2, from: "page" });
      s.createIndex("from", "from");
    };
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
  const vc = await expect("versionchange");
  eq(vc.old + ">" + vc.nw, "1>2", "the worker heard versionchange");
  worker.postMessage({ cmd: "close" });
  await expect("closed");
  const db = await upgraded;
  eq(db.version, 2, "version 2 after the worker closed");
  db.close();
});

test("worker: transactions of the page and the worker are ordered, one data", async () => {
  worker.postMessage({ cmd: "write", base: 100, count: 20 });
  const db = await new Promise((resolve) => { const r = indexedDB.open("worker_shared"); r.onsuccess = () => resolve(r.result); });
  const tx = db.transaction("s", "readwrite");
  for (let i = 0; i < 20; i++) tx.objectStore("s").put({ id: 200 + i, from: "page" });
  eq(await txDone(tx), "complete", "the page's transaction completes");
  const w = await expect("written");
  eq(w.res, "complete", "the worker's transaction completes");
  const all = await rp(db.transaction("s").objectStore("s").getAll());
  eq(all.length, 2 + 20 + 20, "every record of both is there (" + all.length + ")");
  eq(all.filter((x) => x.from === "worker").length, 21, "the worker's records");
  eq(await rp(db.transaction("s").objectStore("s").index("from").count("page")), 21, "the page's index sees them");
  db.close();
  worker.postMessage({ cmd: "read" });
  const rd = await expect("read");
  eq(rd.ids.split(",").length, 42, "the worker reads the same data (" + rd.ids.length + " chars)");
});

test("worker: a terminated worker's connection closes", async () => {
  worker.postMessage({ cmd: "hold" });
  const h = await expect("holding");
  eq(h.ev, "holding", "the worker holds a connection");
  let blocked = false;
  const del = new Promise((resolve) => {
    const r = indexedDB.deleteDatabase("worker_hold");
    r.onblocked = () => { blocked = true; };
    r.onsuccess = () => resolve("deleted");
    r.onerror = () => resolve("error");
  });
  await sleep(100);
  worker.terminate();
  eq(await del, "deleted", "the deletion goes through once the worker is gone");
  ok(blocked, "it was blocked by the worker's connection until then");
});

__run();
