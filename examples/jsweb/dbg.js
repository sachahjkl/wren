test("dbg", async () => {
  const manual = await fetch("/redirect?n=1", { redirect: "manual" });
  console.log("manual", manual.type, manual.status);
  try { await fetch("bad://x"); console.log("resolved"); } catch (e) { console.log("rejected", e.name, e.message); }
  console.log("b");
});
__run();
