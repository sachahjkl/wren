// navigator.storage and navigator.storageBuckets: a bucket has its own databases (the origin's and the bucket's do not see each
// other), its own estimate and persistence, and deleting it removes its data; the manager estimates and persists the origin.

const rp = (r) => new Promise((resolve, reject) => { r.onsuccess = () => resolve(r.result); r.onerror = (e) => { e.preventDefault(); reject(r.error); }; });
const txDone = (tx) => new Promise((resolve) => { tx.oncomplete = () => resolve("complete"); tx.onabort = () => resolve("abort"); });

async function openIn(factory, name, fill) {
  const r = factory.open(name, 1);
  r.onupgradeneeded = () => r.result.createObjectStore("s");
  const db = await rp(r);
  if (fill) {
    const tx = db.transaction("s", "readwrite");
    tx.objectStore("s").put(fill, "k");
    eq(await txDone(tx), "complete", "write");
  }
  return db;
}

test("storage: estimate, persisted, persist", async () => {
  
  eq(typeof navigator.storage, "object", "navigator.storage");
  eq(Object.prototype.toString.call(navigator.storage), "[object StorageManager]", "a StorageManager");
  const e = await navigator.storage.estimate(); ok(e.quota > 0 && e.usage >= 0, "estimate: " + JSON.stringify(e));
  eq(await navigator.storage.persisted(), false, "not persisted");
  eq(await navigator.storage.persist(), true, "persist grants");
  eq(await navigator.storage.persisted(), true, "persisted now");
  let code = "";
  try { await navigator.storage.getDirectory(); } catch (x) { code = x.name; }
  eq(code, "NotSupportedError", "no origin private file system");
});

test("buckets: open, isolation, estimate, keys, delete", async () => {
  const sb = navigator.storageBuckets;
  eq(Object.prototype.toString.call(sb), "[object StorageBucketManager]", "a StorageBucketManager");
  const a = await sb.open("alpha", { durability: "strict" });
  eq(a.name, "alpha", "name");
  eq(await a.durability(), "strict", "durability");
  eq(await a.expires(), null, "no expiry");
  eq(await a.persisted(), false, "not persisted");
  eq(await a.persist(), true, "persist");
  const b = await sb.open("beta");
  eq(await b.durability(), "relaxed", "default durability");
  const da = await openIn(a.indexedDB, "bk", "in alpha");
  const db = await openIn(b.indexedDB, "bk", "in beta");
  const dm = await openIn(indexedDB, "bk", "in default");
  const get = async (d) => rp(d.transaction("s").objectStore("s").get("k"));
  eq(await get(da), "in alpha", "alpha's own");
  eq(await get(db), "in beta", "beta's own");
  eq(await get(dm), "in default", "the origin's own");
  eq(JSON.stringify(await a.indexedDB.databases()), '[{"name":"bk","version":1}]', "alpha lists its own");
  const ea = await a.estimate();
  ok(ea.usage > 0 && ea.quota > 0, "estimate of alpha: " + JSON.stringify(ea));
  const keys = await sb.keys();
  eq(keys.slice().sort().join(","), "alpha,beta", "keys");
  let bad = "";
  try { await sb.open("Not Valid"); } catch (x) { bad = x.name; }
  eq(bad, "TypeError", "invalid name");
  da.close(); db.close(); dm.close();
  await sb.delete("alpha");
  eq((await sb.keys()).join(","), "beta", "alpha is gone");
  const again = await sb.open("alpha");
  eq(JSON.stringify(await again.indexedDB.databases()), "[]", "a deleted bucket comes back empty");
  eq(JSON.stringify(await indexedDB.databases()), '[{"name":"bk","version":1}]', "the origin's database stays");
  await sb.delete("alpha"); await sb.delete("beta");
  const r = indexedDB.deleteDatabase("bk");
  await rp(r);
});

__run();
