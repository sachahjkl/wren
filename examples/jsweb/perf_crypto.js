// performance, crypto.

test("performance", () => {
  ok(performance === performance, "[Replaceable] singleton");
  const t0 = performance.now();
  ok(t0 > 0 && performance.now() >= t0, "now() is monotonic");
  ok(performance.timeOrigin > 1.6e12, "timeOrigin is a Unix time in ms");
  const m = performance.mark("m1", { detail: { k: 1 } });
  ok(m instanceof PerformanceMark && m instanceof PerformanceEntry, "mark() returns a PerformanceMark");
  eq(m.entryType, "mark", "entryType");
  eq(m.duration, 0, "duration");
  eq(m.detail.k, 1, "detail (a clone)");
  performance.mark("m2", { startTime: m.startTime + 5 });
  const ms = performance.measure("span", "m1", "m2");
  ok(ms instanceof PerformanceMeasure, "measure() returns a PerformanceMeasure");
  ok(Math.abs(ms.duration - 5) < 1e-6, "measure between marks");
  const ms2 = performance.measure("opt", { start: "m1", duration: 2, detail: "d" });
  // the spec computes end = start + duration, then duration = end - start: not exact in floating point
  ok(Math.abs(ms2.duration - 2) < 1e-9, "measure with options");
  eq(ms2.detail, "d", "measure detail");
  eq(performance.getEntriesByType("mark").map(e => e.name).join(), "m1,m2", "getEntriesByType");
  eq(performance.getEntriesByName("span")[0].entryType, "measure", "getEntriesByName");
  eq(performance.getEntriesByName("m1", "measure").length, 0, "getEntriesByName with a type");
  eq(performance.getEntries().length, 4, "getEntries");
  eq(performance.getEntriesByName("m1")[0].detail.k, 1, "detail kept with the entry");
  eq(JSON.stringify(performance.getEntriesByName("span")[0].toJSON().name), '"span"', "entry toJSON");
  ok(typeof performance.toJSON().timeOrigin === "number", "performance.toJSON");
  throws(() => performance.measure("x", "no-such-mark"), "SyntaxError", "an unknown mark");
  throws(() => performance.mark("neg", { startTime: -1 }), "TypeError", "a negative startTime");
  performance.clearMarks("m1");
  eq(performance.getEntriesByType("mark").length, 1, "clearMarks(name)");
  performance.clearMarks();
  performance.clearMeasures();
  eq(performance.getEntries().length, 0, "clear all");
  const pm = new PerformanceMark("free");
  eq(pm.name, "free", "PerformanceMark constructor");
  eq(performance.getEntries().length, 0, "...does not record");
});

test("crypto", async () => {
  ok(crypto === crypto && crypto.subtle === crypto.subtle, "singletons");
  const u8 = new Uint8Array(32);
  ok(crypto.getRandomValues(u8) === u8, "returns its argument");
  ok(u8.some(b => b !== 0), "filled");
  const u32 = crypto.getRandomValues(new Uint32Array(4));
  ok(u32.some(v => v !== 0), "Uint32Array");
  crypto.getRandomValues(new BigUint64Array(2));
  throws(() => crypto.getRandomValues(new Float32Array(2)), "TypeMismatchError", "float arrays refused");
  throws(() => crypto.getRandomValues(new Uint8Array(65537)), "QuotaExceededError", "over 65536 bytes");
  throws(() => crypto.getRandomValues(new ArrayBuffer(4)), "TypeError", "an ArrayBuffer is not a view");
  const id = crypto.randomUUID();
  ok(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(id), "randomUUID is a version 4 UUID");
  const hex = b => Array.from(new Uint8Array(b), x => x.toString(16).padStart(2, "0")).join("");
  eq(hex(await crypto.subtle.digest("SHA-256", new TextEncoder().encode("abc"))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256");
  eq(hex(await crypto.subtle.digest({ name: "sha-1" }, new Uint8Array([0x61, 0x62, 0x63]).buffer)), "a9993e364706816aba3e25717850c26c9cd0d89d", "SHA-1, algorithm object, case-insensitive");
  await rejects(crypto.subtle.digest("MD5", new Uint8Array(1)), "NotSupportedError", "unknown algorithm");
  await rejects(crypto.subtle.generateKey({ name: "AES-GCM" }, true, ["encrypt"]), "NotSupportedError", "other operations reject");
});

__run();
