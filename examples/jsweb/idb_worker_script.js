// The worker of idb_worker.js: IndexedDB in a dedicated worker, a client of the same manager as the page of its origin.
const open = (name, version, upgrade) => new Promise((resolve, reject) => {
  const r = indexedDB.open(name, version);
  r.onupgradeneeded = () => { if (upgrade) upgrade(r.result, r.transaction); };
  r.onsuccess = () => resolve(r.result);
  r.onerror = (e) => { e.preventDefault(); reject(r.error); };
  r.onblocked = () => postMessage({ ev: "blocked" });
});
const txDone = (tx) => new Promise((resolve) => { tx.oncomplete = () => resolve("complete"); tx.onabort = () => resolve("abort"); });
let db = null;

onmessage = async (e) => {
  const m = e.data;
  try {
    if (m.cmd === "open1") {
      db = await open("worker_shared", 1, (d) => { d.createObjectStore("s", { keyPath: "id" }).put({ id: 1, from: "worker" }); });
      db.onversionchange = (ev) => postMessage({ ev: "versionchange", old: ev.oldVersion, nw: ev.newVersion });
      postMessage({ ev: "opened", version: db.version, type: typeof indexedDB, name: String(indexedDB), keyRange: typeof IDBKeyRange, cmp: indexedDB.cmp(1, 2) });
    } else if (m.cmd === "close") {
      db.close();
      postMessage({ ev: "closed" });
    } else if (m.cmd === "write") {
      const d = await open("worker_shared");
      const tx = d.transaction("s", "readwrite");
      for (let i = 0; i < m.count; i++) tx.objectStore("s").put({ id: m.base + i, from: "worker" });
      const res = await txDone(tx);
      d.close();
      postMessage({ ev: "written", res });
    } else if (m.cmd === "read") {
      const d = await open("worker_shared");
      const all = await new Promise((resolve) => { const q = d.transaction("s").objectStore("s").getAll(); q.onsuccess = () => resolve(q.result); });
      d.close();
      postMessage({ ev: "read", ids: all.map((x) => x.id + x.from[0]).join() });
    } else if (m.cmd === "hold") {
      // keeps a connection open until the worker is terminated (the manager must close it then)
      db = await open("worker_hold", 1, (d) => d.createObjectStore("s"));
      postMessage({ ev: "holding" });
    }
  } catch (err) {
    postMessage({ ev: "error", name: err && err.name, message: err && err.message });
  }
};
