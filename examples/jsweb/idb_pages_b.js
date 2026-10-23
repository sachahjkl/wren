// The other page of idb_pages_a.js: asks for version 2 while A holds version 1.

test("B: a higher version is blocked until the other page closes", async () => {
  let blocked = null;
  const db = await new Promise((resolve, reject) => {
    const r = indexedDB.open("shared_pages", 2);
    r.onblocked = (e) => { blocked = e; console.log("BLOCKED"); };
    r.onupgradeneeded = (e) => {
      ok(blocked !== null, "blocked came before the upgrade");
      eq(e.oldVersion, 1, "upgrade from 1");
      eq(e.newVersion, 2, "upgrade to 2");
      const s = r.transaction.objectStore("s");
      const g = s.get(1);
      g.onsuccess = () => eq(g.result && g.result.from, "A", "the record of page A is there");
      s.put({ id: 2, from: "B" });
      s.createIndex("from", "from");
    };
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
  eq(blocked.type, "blocked", "blocked event");
  eq(blocked.oldVersion, 1, "blocked: oldVersion");
  eq(blocked.newVersion, 2, "blocked: newVersion");
  eq(db.version, 2, "version 2");
  db.close();
});

test("B: the version cannot go back", async () => {
  const r = indexedDB.open("shared_pages", 1);
  await new Promise((resolve) => { r.onerror = (e) => { e.preventDefault(); resolve(); }; r.onsuccess = () => resolve(); });
  eq(r.error && r.error.name, "VersionError", "VersionError");
});

__run();
