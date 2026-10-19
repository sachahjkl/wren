// Costs of the web APIs (reported as MEASURE lines): what crossing into the browser costs per call.

function time(name, n, fn) {
  fn(Math.min(n, 100));   // warm-up
  const t0 = performance.now();
  fn(n);
  const ms = performance.now() - t0;
  measure(name + "_ns_per_call", (ms * 1e6 / n).toFixed(0));
}

test("costs", async () => {
  localStorage.clear();
  localStorage.setItem("key", "value of some length");
  localStorage.setItem("item", "value of some length");
  time("localStorage_getItem", 100000, n => { let x; for (let i = 0; i < n; i++) x = localStorage.getItem("key"); return x; });
  time("localStorage_named_get", 100000, n => { let x; for (let i = 0; i < n; i++) x = localStorage.item; return x; });
  time("localStorage_setItem", 20000, n => { for (let i = 0; i < n; i++) localStorage.setItem("key", "v" + (i & 7)); });
  const u = new URL("https://example.com/a/b?c=d#e");
  time("URL_pathname", 100000, n => { let x; for (let i = 0; i < n; i++) x = u.pathname; return x; });
  time("new_URL", 20000, n => { for (let i = 0; i < n; i++) new URL("https://example.com/" + i); });
  const h = new Headers({ a: "1", b: "2", c: "3" });
  time("Headers_get", 100000, n => { let x; for (let i = 0; i < n; i++) x = h.get("b"); return x; });
  const enc = new TextEncoder(), dec = new TextDecoder();
  const s = "x".repeat(1000);
  time("TextEncoder_encode_1KB", 20000, n => { for (let i = 0; i < n; i++) enc.encode(s); });
  const b = enc.encode(s);
  time("TextDecoder_decode_1KB", 20000, n => { for (let i = 0; i < n; i++) dec.decode(b); });
  time("performance_now", 100000, n => { let x; for (let i = 0; i < n; i++) x = performance.now(); return x; });
  time("crypto_getRandomValues_16B", 50000, n => { const a = new Uint8Array(16); for (let i = 0; i < n; i++) crypto.getRandomValues(a); });
  const t0 = performance.now();
  for (let i = 0; i < 200; i++) await (await fetch("/jsweb/json")).text();
  measure("fetch_small_round_trip_ms", ((performance.now() - t0) / 200).toFixed(3));
  localStorage.clear();
  ok(true, "measured");
});

__run();
