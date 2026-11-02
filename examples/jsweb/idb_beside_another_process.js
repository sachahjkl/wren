// A database made anew, written and read back, while another test program has started and ended on the same machine: what it
// does to its own profile leaves this one's alone. (jsweb_idb_beside_another_process: run twice, with that program in between.)
"use strict";

test("a database made anew beside another process", async () => {
  const name = "beside_another_process";
  await new Promise((resolve, reject) => {
    const del = indexedDB.deleteDatabase(name);
    del.onsuccess = resolve;
    del.onerror = () => reject(del.error);
  });
  const db = await new Promise((resolve, reject) => {
    const open = indexedDB.open(name, 1);
    open.onupgradeneeded = () => open.result.createObjectStore("s");
    open.onsuccess = () => resolve(open.result);
    open.onerror = () => reject(open.error);
  });
  await new Promise((resolve, reject) => {
    const tx = db.transaction("s", "readwrite");
    tx.objectStore("s").put("the value", "the key");
    tx.oncomplete = resolve;
    tx.onerror = () => reject(tx.error);
  });
  const value = await new Promise((resolve, reject) => {
    const get = db.transaction("s").objectStore("s").get("the key");
    get.onsuccess = () => resolve(get.result);
    get.onerror = () => reject(get.error);
  });
  eq(value, "the value", "what was written comes back");
  db.close();
});

__run();
