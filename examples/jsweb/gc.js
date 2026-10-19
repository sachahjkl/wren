// Objects JavaScript drops: their browser objects must go when the wrappers are collected (the tool collects and
// counts the page's host objects).

test("make garbage", async () => {
  for (let i = 0; i < 500; i++) {
    new AbortController().abort();
    new URL("http://h/" + i).searchParams.append("a", "b");
    new URLSearchParams("a=" + i);
    new TextDecoder();
    new XMLHttpRequest();
    new EventTarget();
    new MessageChannel();
    AbortSignal.any([AbortSignal.abort()]);
  }
  for (let i = 0; i < 20; i++) {
    const r = await fetch("/jsweb/json");
    if (i % 2) await r.text();
  }
  ok(true, "garbage made");
});

__run();
