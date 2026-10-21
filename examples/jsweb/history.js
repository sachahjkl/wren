// location and history (the document is http://127.0.0.1:8765/jsweb/page?x=1).

test("location", () => {
  ok(location === window.location && location === document.location, "one Location");
  eq(location.href, "http://127.0.0.1:8765/jsweb/page?x=1", "href");
  eq(String(location), location.href, "stringifier");
  eq(location.origin, "http://127.0.0.1:8765", "origin");
  eq(location.protocol, "http:", "protocol");
  eq(location.host, "127.0.0.1:8765", "host");
  eq(location.hostname, "127.0.0.1", "hostname");
  eq(location.port, new URL("http://127.0.0.1:8765").port, "port");
  eq(location.pathname, "/jsweb/page", "pathname");
  eq(location.search, "?x=1", "search");
  eq(location.hash, "", "hash");
  ok(Object.getOwnPropertyDescriptor(location, "href") !== undefined, "[LegacyUnforgeable]: own properties");
  eq(Object.getOwnPropertyDescriptor(location, "href").configurable, false, "...not configurable");
  eq(location.ancestorOrigins.length, 0, "ancestorOrigins: no frames");
  ok(JSON.parse(JSON.stringify(location)).href === location.href, "JSON.stringify(location) reads every member");
});

test("pushState and replaceState", () => {
  const len = history.length;
  eq(history.state, null, "no state at first");
  const st = { a: [1, 2], d: new Date(7) };
  history.pushState(st, "", "/jsweb/page?step=2");
  eq(location.href, "http://127.0.0.1:8765/jsweb/page?step=2", "the URL changed");
  eq(history.length, len + 1, "a new entry");
  ok(history.state !== st, "the state is a clone");
  eq(history.state.a[1], 2, "its content");
  ok(history.state.d instanceof Date, "structured clone");
  ok(history.state === history.state, "the same object while unchanged");
  history.replaceState("plain", "");
  eq(history.state, "plain", "replaceState");
  eq(history.length, len + 1, "no new entry");
  throws(() => history.pushState(() => 1, ""), "DataCloneError", "a function cannot be a state");
  throws(() => history.pushState(null, "", "http://example.com/"), "SecurityError", "another origin");
  throws(() => history.pushState(null, "", "http://[bad"), "SyntaxError", "an invalid URL");
  eq(history.scrollRestoration, "auto", "scrollRestoration");
  history.scrollRestoration = "manual";
  eq(history.scrollRestoration, "manual", "scrollRestoration setter");
  history.scrollRestoration = "bogus";
  eq(history.scrollRestoration, "manual", "invalid value ignored");
});

test("back: popstate", async () => {
  history.pushState({ page: 3 }, "", "/jsweb/page?step=3");
  const p = new Promise(r => window.addEventListener("popstate", r, { once: true }));
  history.back();
  const e = await p;
  ok(e instanceof PopStateEvent, "a PopStateEvent");
  eq(e.state, "plain", "the entry's state");
  eq(history.state, "plain", "history.state follows");
  eq(location.search, "?step=2", "the URL follows");
  const f = new Promise(r => { window.onpopstate = r; });
  history.forward();
  eq((await f).state.page, 3, "forward");
  window.onpopstate = null;
  eq(new PopStateEvent("popstate", { state: 5 }).state, 5, "PopStateEvent constructor");
});

test("fragments: hashchange", async () => {
  const before = location.href;
  const p = new Promise(r => { window.onhashchange = r; });
  location.hash = "#part";
  eq(location.hash, "#part", "the hash changed at once");
  const e = await p;
  ok(e instanceof HashChangeEvent, "a HashChangeEvent");
  eq(e.oldURL, before, "oldURL");
  eq(e.newURL, before + "#part", "newURL");
  eq(history.state, null, "a fragment navigation clears the state");
  window.onhashchange = null;
  const h = new HashChangeEvent("hashchange", { oldURL: "a", newURL: "b" });
  eq(h.oldURL + h.newURL, "ab", "HashChangeEvent constructor");
});

test("navigations go to the embedder", async () => {
  location.assign("/jsweb/other");
  location.replace("/jsweb/replaced");
  location.reload();
  throws(() => location.assign("http://[bad"), "SyntaxError", "invalid URL");
  await signal("navigations");
  ok(true, "the tool checked the navigations");
});

__run();
