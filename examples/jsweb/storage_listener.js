// The other page of storage.js: the storage events of its writes.

test("storage events", async () => {
  const events = [];
  const done = new Promise(r => {
    window.addEventListener("storage", e => {
      if (e.key !== "shared") return;
      events.push(e);
      if (events.length === 3) r();
    });
  });
  console.log("LISTENING");   // the tool opens the writing page once it reads this
  await done;
  const e = events[0];
  ok(e instanceof StorageEvent, "a StorageEvent");
  eq(e.oldValue, null, "first: oldValue null");
  eq(e.newValue, "1", "first: newValue");
  eq(e.url, "http://127.0.0.1:8765/jsweb/page", "url of the writing document");
  ok(e.storageArea === localStorage, "storageArea");
  eq(events[1].oldValue + ">" + events[1].newValue, "1>2", "second change");
  eq(events[2].newValue, null, "removal: newValue null");
  eq(e.isTrusted, true, "trusted");
  const c = new StorageEvent("storage", { key: "k", newValue: "n", storageArea: sessionStorage });
  eq(c.key + c.newValue + c.oldValue, "knnull", "StorageEvent constructor");
  ok(c.storageArea === sessionStorage, "constructor storageArea");
});

__run();
