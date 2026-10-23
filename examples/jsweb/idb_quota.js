// IndexedDB quota (the tool lowers indexeddb.quota to 1 MiB for this page): a transaction that goes past it fails with
// QuotaExceededError and leaves the data as it was; deleting data makes room again.

const done = (tx) => new Promise((resolve) => {
  tx.oncomplete = () => resolve("complete");
  tx.onabort = () => resolve("abort");
});

test("quota: QuotaExceededError, then room after a delete", async () => {
  const db = await new Promise((resolve, reject) => {
    const r = indexedDB.open("quota_db", 1);
    r.onupgradeneeded = () => r.result.createObjectStore("s");
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
  let n = 0, failure = null;
  for (; n < 40 && failure === null; n++) {
    const tx = db.transaction("s", "readwrite");
    const rq = tx.objectStore("s").put(new Uint8Array(100 * 1024), n);
    rq.onerror = () => { failure = rq.error; };
    await done(tx);
  }
  ok(failure !== null, "a transaction failed");
  eq(failure && failure.name, "QuotaExceededError", "QuotaExceededError");
  ok(n >= 8 && n <= 11, "about 1 MiB fitted (" + n + " puts, the last one failed)");
  const count = await new Promise((resolve) => { const q = db.transaction("s").objectStore("s").count(); q.onsuccess = () => resolve(q.result); });
  eq(count, n - 1, "the failed transaction left nothing");
  const del = db.transaction("s", "readwrite");
  del.objectStore("s").clear();
  eq(await done(del), "complete", "clear");
  const again = db.transaction("s", "readwrite");
  again.objectStore("s").put(new Uint8Array(100 * 1024), "again");
  eq(await done(again), "complete", "room after the delete");
  db.close();
});

__run();
