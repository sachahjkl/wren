// IndexedDB after the browser's data manager was shut down and started again (the journal file is read): what pages A and B
// of idb_pages_a.js left is there, and a database can be deleted.

test("persistence: the data is back after a restart", async () => {
  const names = (await indexedDB.databases()).filter((d) => d.name === "shared_pages").map((d) => d.name + "@" + d.version).join();
  eq(names, "shared_pages@2", "databases() lists it");
  const db = await new Promise((resolve, reject) => {
    const r = indexedDB.open("shared_pages");
    r.onupgradeneeded = () => reject(new Error("upgrade"));
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
  eq(db.version, 2, "version 2");
  const s = db.transaction("s").objectStore("s");
  const byB = await new Promise((resolve) => { const q = s.index("from").get("B"); q.onsuccess = () => resolve(q.result); });
  eq(byB && byB.id, 2, "the index finds the record of page B");
  const n = await new Promise((resolve) => { const q = s.count(); q.onsuccess = () => resolve(q.result); });
  eq(n, 2, "two records");
  db.close();
  await new Promise((resolve, reject) => {
    const r = indexedDB.deleteDatabase("shared_pages");
    r.onsuccess = () => resolve();
    r.onerror = () => reject(r.error);
  });
  eq((await indexedDB.databases()).filter((d) => d.name === "shared_pages").length, 0, "deleted");
});

__run();
