// localStorage and sessionStorage (another page of the origin listens: storage_listener.js).

test("Storage methods", () => {
  ok(localStorage === window.localStorage, "one localStorage");
  ok(localStorage instanceof Storage, "a Storage");
  localStorage.clear();
  eq(localStorage.length, 0, "empty");
  localStorage.setItem("k", "v");
  eq(localStorage.getItem("k"), "v", "setItem / getItem");
  eq(localStorage.getItem("nope"), null, "absent is null");
  localStorage.setItem("n", 5);
  eq(localStorage.getItem("n"), "5", "values are strings");
  eq(localStorage.key(0) !== null && localStorage.key(5), null, "key() past the end");
  eq(localStorage.length, 2, "length");
  localStorage.removeItem("n");
  eq(localStorage.length, 1, "removeItem");
});

test("named properties", () => {
  localStorage.clear();
  localStorage.foo = "bar";
  eq(localStorage.getItem("foo"), "bar", "assignment is setItem");
  eq(localStorage.foo, "bar", "property read is getItem");
  eq(localStorage.missing, undefined, "absent property is undefined");
  ok("foo" in localStorage, "in");
  localStorage["with space"] = 1;
  eq(Object.keys(localStorage).sort().join(), "foo,with space", "Object.keys lists the keys");
  delete localStorage.foo;
  eq(localStorage.getItem("foo"), null, "delete is removeItem");
  localStorage.setItem("getItem", "shadow?");
  eq(typeof localStorage.getItem, "function", "a key does not shadow the prototype");
  eq(localStorage.getItem("getItem"), "shadow?", "...but is stored");
  localStorage.clear();
});

test("quota", () => {
  throws(() => localStorage.setItem("big", "x".repeat(5000)), "QuotaExceededError", "a write over storage.local.quota");
  eq(localStorage.getItem("big"), null, "nothing stored");
});

test("sessionStorage", () => {
  sessionStorage.setItem("s", "1");
  eq(sessionStorage.getItem("s"), "1", "sessionStorage");
  eq(localStorage.getItem("s"), null, "separate from localStorage");
  ok(sessionStorage !== localStorage, "two objects");
});

test("storage event for the other page", async () => {
  // the listener page was listening before this page was opened (jswebtest)
  localStorage.setItem("shared", "1");
  localStorage.setItem("shared", "2");
  localStorage.removeItem("shared");
  ok(true, "writes done (the listener page checks the events)");
});

__run();
