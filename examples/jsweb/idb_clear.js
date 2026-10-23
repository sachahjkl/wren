// IndexedDB and "Clear site data": everything the origin keeps goes, open connections are closed (onclose), the next open
// finds nothing.

test("clear site data", async () => {
  const db = await new Promise((resolve, reject) => {
    const r = indexedDB.open("to_clear", 3);
    r.onupgradeneeded = () => r.result.createObjectStore("s").put("value", "k");
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
  ok((await indexedDB.databases()).some((d) => d.name === "to_clear"), "the database is listed");
  const closed = new Promise((resolve) => { db.onclose = () => resolve("close"); });
  await signal("clear");
  eq(await closed, "close", "the connection heard close");
  throws(() => db.transaction("s"), "InvalidStateError", "no transaction on it");
  eq((await indexedDB.databases()).length, 0, "no database left");
  const db2 = await new Promise((resolve, reject) => {
    const r = indexedDB.open("to_clear");
    r.onupgradeneeded = () => {};
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
  eq(db2.version, 1, "a new database at version 1");
  eq(db2.objectStoreNames.length, 0, "without stores");
  db2.close();
});

__run();
