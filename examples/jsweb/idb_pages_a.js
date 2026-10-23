// IndexedDB, two pages of one origin (with idb_pages_b.js): page A keeps a connection open, page B asks for a higher version.
// A hears versionchange, B hears blocked, A closes (the tool calls __closeA once B is blocked), B's upgrade runs and commits.

test("A: a connection that hears the version change of another page", async () => {
  const db = await new Promise((resolve, reject) => {
    const r = indexedDB.open("shared_pages", 1);
    r.onupgradeneeded = () => { r.result.createObjectStore("s", { keyPath: "id" }).put({ id: 1, from: "A" }); };
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
  const changed = new Promise((resolve) => { db.onversionchange = (e) => resolve(e); });
  const closed = new Promise((resolve) => { globalThis.__closeA = () => { db.close(); resolve(); }; });
  console.log("LISTENING");
  const e = await changed;
  ok(e instanceof IDBVersionChangeEvent, "versionchange is an IDBVersionChangeEvent");
  eq(e.oldVersion, 1, "oldVersion");
  eq(e.newVersion, 2, "newVersion");
  ok(e.target === db, "on the connection");
  console.log("HEARD");
  await closed;
  throws(() => db.transaction("s"), "InvalidStateError", "a closed connection has no transactions");
});

test("A: the data of the other page's upgrade", async () => {
  await signal("b_done");
  const db = await new Promise((resolve, reject) => {
    const r = indexedDB.open("shared_pages");
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
  eq(db.version, 2, "version 2");
  const s = db.transaction("s").objectStore("s");
  const all = await new Promise((resolve) => { const q = s.getAll(); q.onsuccess = () => resolve(q.result); });
  eq(all.map((x) => x.id + x.from).join(), "1A,2B", "both records");
  eq([...s.indexNames].join(), "from", "the index B made");
  const names = (await indexedDB.databases()).map((d) => d.name + "@" + d.version).join();
  eq(names, "shared_pages@2", "databases()");
  db.close();
});

__run();
