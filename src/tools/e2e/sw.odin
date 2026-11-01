package e2e_scenarios

// Service workers, the Cache API and BroadcastChannel, against the test server (http://127.0.0.1: a secure context): examples/site/sw/ registers sw.js,
// which caches data.txt at install, claims the page, answers virtual.txt and a whole navigation (virtual-page.html) itself, serves data.txt from its
// cache and answers messages. Checks the page's view (ready, controller, the answers, the messages, caches.keys) and that a page with no service worker
// in its scope is not intercepted. Then the Cache API's Vary / ignoreVary and response URLs, which interfaces each realm has, a module service worker,
// and with tools/testserver/sw.go: versions (update(), waiting, skipWaiting, controllerchange, the update check of a navigation), clients (matchAll, get,
// openWindow, focus), an idle worker stopped and started again, navigation preload (preloadResponse, fallback).

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file") SW_SIZE :: [2]int{1000, 700}
@(private = "file") SITE_PAGE :: "/site/sw/index.html"
@(private = "file") FOREIGN_ORIGIN :: "http://localhost:%d"
@(private = "file") OPAQUE_SCRIPT :: "%s/jsload/gen?code=window.opaqueRan%%3D(window.opaqueRan%%7C%%7C0)%%2B1"
// How long a worker with nothing to do lasts in this test: short, what ends it is waited for. What it is otherwise.
@(private = "file") SHORT_IDLE_MS :: "20"
@(private = "file") USUAL_IDLE_MS :: "30000"
@(private = "file") CONTROLLED :: "!!navigator.serviceWorker.controller"
@(private = "file") UNREGISTER_SW_SCOPES :: `navigator.serviceWorker.getRegistrations().then((rs) => Promise.all(rs.filter((r) => new URL(r.scope).pathname.startsWith("/sw/")).map((r) => r.unregister())))`

@(test)
service_worker_of_a_page :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	base := fmt.tprintf("%s/site/sw", server.origin)
	s := e2e.start(t, {size = SW_SIZE, url = e2e.url(server, SITE_PAGE)})
	e2e.expect_eval(s, "registered", fmt.tprintf("%s/", base), "register() resolves with the registration (its scope)")
	e2e.expect_eval(s, `navigator.serviceWorker.ready.then((r) => r.active.state === "activated" ? "activated" : new Promise((ok) => { r.active.onstatechange = () => { if (r.active.state === "activated") ok("activated"); }; }))`, "activated", "ready: the worker installed (cache filled, skipWaiting) and activated")
	e2e.wait_js(s, CONTROLLED)   // clients.claim() made the registering page controlled
	e2e.expect_eval(s, `fetch("virtual.txt").then((r) => r.text())`, "from the service worker", "a request of the controlled page answered by respondWith(new Response)")
	e2e.expect_eval(s, `caches.keys().then((k) => k.join(","))`, "v1", "the page sees the cache the worker made (caches.keys)")
	cached := e2e.eval(s, `caches.open("v1").then((c) => c.match("data.txt")).then((r) => r ? r.text() : "none")`, await = true)
	testing.expectf(t, strings.contains(cached, "data from the network"), "cache.addAll stored the response (cache.match from the page): got %q", cached)
	e2e.expect_eval(s, `navigator.storage.estimate().then((e) => e.usage > 0 && e.quota > e.usage)`, "true", "navigator.storage.estimate() counts the Cache API")
	data := e2e.eval(s, `fetch("data.txt").then((r) => r.text())`, await = true)
	testing.expectf(t, strings.contains(data, "data from the network"), "a request answered from the cache (respondWith(caches.match)): got %q", data)
	e2e.expect_eval(s, `fetch("cached-only.txt").then((r) => r.text())`, "put by the worker", "a response the worker put in its cache, which the network does not have")

	// an opaque response handed to the page: scripts in the worker never have its bytes, the page's <script> runs it all the same
	opaque := fmt.tprintf(OPAQUE_SCRIPT, fmt.tprintf(FOREIGN_ORIGIN, server.base))
	add_script := fmt.tprintf(`new Promise((ok) => {{ const s = document.createElement("script"); s.src = "%s"; s.onload = () => ok(String(window.opaqueRan)); s.onerror = () => ok("error"); document.head.appendChild(s); }})`, opaque)
	e2e.expect_eval(s, add_script, "1", "a no-cors script of another origin answered with fetch(e.request), an opaque response: it runs")
	e2e.expect_eval(s, add_script, "2", "the same answered from the cache, where the opaque response was put")
	e2e.expect_eval(s, fmt.tprintf(`caches.open("opaque").then((c) => c.match("%s")).then((r) => r.text().then((t) => [r.type, r.status, "[" + r.url + "]", "[" + t + "]"].join(" ")))`, opaque), "opaque 0 [] []", "read from the cache, it is still opaque to scripts")
	e2e.expect_eval(s, fmt.tprintf(`fetch("opaque-for-cors?to=" + encodeURIComponent("%s")).then(() => "answered", (e) => e.name)`, opaque), "TypeError", "an opaque response for a request that is not no-cors is a network error")

	e2e.eval(s, `navigator.serviceWorker.controller.postMessage("ping"); "sent"`)
	e2e.wait_js(s, "swMessages.length > 0")
	e2e.expect_eval(s, `swMessages.join(",")`, "pong:ping", "postMessage both ways (the worker answers through event.source)")
	e2e.expect_eval(s, `new Promise((ok) => { const a = new BroadcastChannel("t"), b = new BroadcastChannel("t"); b.onmessage = (e) => { ok(e.data + " " + e.origin); a.close(); b.close(); }; a.postMessage("hello"); })`, fmt.tprintf("hello %s", server.origin), "BroadcastChannel: a message to another channel of the same name, with the origin")
	e2e.expect_eval(s, `new Promise((ok) => { const src = "const c = new OffscreenCanvas(40, 30); const g = c.getContext(\"2d\"); g.fillStyle = \"#f00\"; g.fillRect(0, 0, 40, 30); const px = g.getImageData(5, 5, 1, 1).data; c.convertToBlob().then((b) => postMessage(px[0] + \",\" + px[3] + \" \" + b.type + \" \" + (b.size > 0)));"; const w = new Worker("data:text/javascript," + encodeURIComponent(src)); w.onmessage = (e) => { ok(e.data); w.terminate(); }; w.onerror = (e) => ok("error " + e.message); })`, "255,255 image/png true", "OffscreenCanvas in a worker: drawn, read back, encoded")
	e2e.expect_eval(s, "String(crossOriginIsolated)", "false", "crossOriginIsolated is false (realms share no memory)")
	e2e.expect_eval(s, `caches.open("vary").then((c) => c.put(new Request("vx", {headers: {"X-L": "a"}}), new Response("A", {headers: {"Vary": "X-L"}})).then(() => c.put(new Request("vx", {headers: {"X-L": "b"}}), new Response("B", {headers: {"Vary": "X-L"}}))).then(() => Promise.all([c.match(new Request("vx", {headers: {"X-L": "b"}})).then((r) => r.text()), c.match("vx").then((r) => String(r)), c.matchAll("vx", {ignoreVary: true}).then((rs) => rs.length), c.keys().then((ks) => ks.map((k) => k.headers.get("x-l")).join(""))]))).then((a) => a.join(" "))`, "B undefined 2 ab", "Cache API: Vary (one entry per varying request header), ignoreVary, the stored request headers")
	e2e.expect_eval(s, `caches.open("v1").then((c) => c.match("data.txt")).then((r) => new URL(r.url).pathname)`, "/site/sw/data.txt", "a response from the cache keeps its URL")
	e2e.expect_eval(s, `[typeof FetchEvent, typeof Clients, typeof ExtendableEvent, typeof ServiceWorkerGlobalScope, typeof ServiceWorker].join(" ")`, "undefined undefined undefined undefined function", "a page has none of the service worker realm interfaces")
	e2e.expect_eval(s, `navigator.serviceWorker.register("module-sw.js", {scope: "./module/", type: "module"}).then((r) => new Promise((ok) => { const go = () => { const w = r.active; if (!w) { setTimeout(go, 50); return; } const n = swMessages.length; w.postMessage("hi"); const t = setInterval(() => { if (swMessages.length > n) { clearInterval(t); ok(swMessages[swMessages.length - 1]); } }, 20); }; go(); }))`, "module:imported TypeError", `a module service worker ({type: "module"}): static import, no importScripts`)

	e2e.navigate(s, fmt.tprintf("%s/virtual-page.html", base))
	e2e.expect_eval(s, `document.getElementById("x") ? document.getElementById("x").textContent : document.body.textContent.slice(0, 80)`, "a page the service worker made", "a navigation in the scope answered by the worker")
	e2e.expect_eval(s, CONTROLLED, "true", "a page loaded in the scope after activation is controlled")
}

// Versions (tools/testserver/sw.go: /sw/ver.js changes after /sw/bump), clients, idle stop, navigation preload.
@(test)
service_worker_versions_clients_preload :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = SW_SIZE, url = e2e.url(server, "/sw/ver/page")})
	s.tab = e2e.targets(s).tabs[0].id
	e2e.expect_eval(s, `navigator.serviceWorker.register("/sw/ver.js", {scope: "/sw/ver/"}).then(() => navigator.serviceWorker.ready).then((r) => r.active.state === "activated" ? "activated" : new Promise((ok) => { r.active.onstatechange = () => { if (r.active.state === "activated") ok("activated"); }; }))`, "activated", "a registration of /sw/ver.js (version 1) activated")
	e2e.wait_js(s, CONTROLLED)
	e2e.eval(s, `window.ask = (m) => new Promise((ok) => { const n = swMessages.length; navigator.serviceWorker.controller.postMessage(m); const t = setInterval(() => { if (swMessages.length > n) { clearInterval(t); ok(swMessages[swMessages.length - 1]); } }, 20); setTimeout(() => ok("no answer"), 30000); }); 1`)
	e2e.expect_eval(s, `ask("types")`, "function function undefined undefined function", "a service worker has FetchEvent and Clients, not DedicatedWorkerGlobalScope nor SharedWorkerGlobalScope")
	e2e.expect_eval(s, `navigator.serviceWorker.getRegistration().then((r) => r.update()).then((r) => String(r.installing) + " " + String(r.waiting))`, "null null", "update() with an unchanged script installs nothing")
	e2e.eval(s, `fetch("/sw/bump").then((r) => r.text())`, await = true)
	e2e.expect_eval(s, `navigator.serviceWorker.getRegistration().then((r) => new Promise((ok) => { r.onupdatefound = () => { const w = r.installing; w.onstatechange = () => { if (w.state === "installed") ok("waiting " + (r.waiting === w) + " " + (r.active !== w)); }; }; r.update(); setTimeout(() => ok("timeout"), 30000); }))`, "waiting true true", "update() of a changed script: updatefound, the new version installs and waits (the page uses the old one)")
	e2e.expect_eval(s, `ask("who")`, "v1", "the waiting version does not control the page yet")
	e2e.expect_eval(s, `new Promise((ok) => { navigator.serviceWorker.oncontrollerchange = () => ok("changed"); navigator.serviceWorker.getRegistration().then((r) => r.waiting.postMessage("skip")); setTimeout(() => ok("timeout"), 30000); })`, "changed", "skipWaiting() in the waiting version: it activates, controllerchange")
	e2e.expect_eval(s, `ask("who")`, "v2", "the new version controls the page")
	e2e.expect_eval(s, `fetch("v.txt").then((r) => r.text())`, "v2", "requests go to the new version")
	e2e.expect_eval(s, `ask("state")`, "activated true", "the worker sees its own state and registration.active")
	e2e.expect_eval(s, `ask("clients")`, "1 window:/sw/ver/page", "clients.matchAll knows the open window clients of the scope")
	e2e.expect_eval(s, `ask("get")`, "got true top-level", "clients.get(id)")
	e2e.expect_eval(s, `ask("focus")`, "refused InvalidAccessError", "WindowClient.focus() without a user gesture in a window of the site is refused")
	e2e.eval(s, `window.wk = new Worker("data:text/javascript,setTimeout(() => 0, 1e9)"); 1`)
	workers := e2e.eval(s, `ask("workers")`, await = true)
	testing.expectf(t, strings.has_prefix(workers, "worker:"), `clients.matchAll({type: "worker"}) lists the dedicated workers of its clients: got %q`, workers)
	in_worker := e2e.eval(s, `new Promise((ok) => { const t0 = Date.now(); const src = "const c = navigator.serviceWorker; c.onmessage = (e) => postMessage(c.controller.state + \" \" + e.data + \" \" + (e.source instanceof ServiceWorker)); if (c.controller) c.controller.postMessage(\"who\"); else postMessage(\"no controller\");"; const w = new Worker(URL.createObjectURL(new Blob([src]))); w.onmessage = (e) => { ok(e.data); w.terminate(); }; w.onerror = (e) => ok("error " + e.message); setTimeout(() => ok("timeout " + (Date.now() - t0) + " ms"), 30000); })`, await = true)
	testing.expectf(t, strings.has_prefix(in_worker, "activated v") && strings.has_suffix(in_worker, " true"), "navigator.serviceWorker in a dedicated worker: its document's controller, messages both ways: got %q", in_worker)
	e2e.click(s, "#x")
	e2e.expect_eval(s, `ask("open")`, "opened /sw/ver/opened", "clients.openWindow opens a tab and resolves with its WindowClient")
	e2e.click(s, "#x")
	e2e.expect_eval(s, `ask("focus")`, "focused true", "WindowClient.focus() shows the client's tab")

	// an idle service worker stops, and what it remembered goes with it
	running := e2e.stats(s).workers_running
	e2e.pref_set(s, "service_workers.idle_ms", SHORT_IDLE_MS)
	e2e.expect_eval(s, `ask("remember")`, "ok", "the worker remembers")
	e2e.wait_until(s, running, proc(s: ^e2e.Session, running: int) -> bool { return e2e.stats(s).workers_running < running }, "the idle service worker to stop")
	e2e.pref_set(s, "service_workers.idle_ms", USUAL_IDLE_MS)
	e2e.expect_eval(s, `ask("recall")`, "nothing", "an idle service worker stops (service_workers.idle_ms) and starts again for the next event")

	e2e.pref_set(s, "service_workers.update_check_hours", "0")
	e2e.eval(s, `fetch("/sw/bump").then((r) => r.text())`, await = true)
	e2e.navigate(s, e2e.url(server, "/sw/ver/page"))
	e2e.expect_eval(s, `navigator.serviceWorker.getRegistration().then((r) => new Promise((ok) => { const go = () => (r.waiting || r.installing) ? ok("new version") : setTimeout(go, 50); go(); setTimeout(() => ok("none"), 30000); }))`, "new version", "a navigation in the scope checks the script (service_workers.update_check_hours) and installs a changed one")
	e2e.pref_set(s, "service_workers.update_check_hours", "24")
	e2e.expect_eval(s, `navigator.serviceWorker.register("/sw/preload.js", {scope: "/sw/pre/"}).then((r) => new Promise((ok) => { const go = () => r.active && r.active.state === "activated" ? r.navigationPreload.getState().then((s) => ok(s.enabled + " " + s.headerValue)) : setTimeout(go, 50); go(); }))`, "true wren-test", "navigationPreload.enable / setHeaderValue / getState")
	e2e.navigate(s, e2e.url(server, "/sw/pre/page"))
	e2e.expect_eval(s, `document.getElementById("x") ? document.getElementById("x").textContent : document.body.textContent`, "preloaded 200 header=wren-test", "FetchEvent.preloadResponse: the navigation's request, with Service-Worker-Navigation-Preload")
	e2e.navigate(s, e2e.url(server, "/sw/pre/fallback"))
	e2e.expect_eval(s, "document.body.textContent", "header=wren-test", "a navigation the worker does not answer gets the preload's response")
	e2e.expect_eval(s, `navigator.serviceWorker.getRegistration().then((r) => r.unregister()).then(async (ok) => ok + " " + !!navigator.serviceWorker.controller + " " + String(await navigator.serviceWorker.getRegistration()))`, "true true undefined", "unregister(): the page it controls stays controlled, the registration is no longer found")
	e2e.navigate(s, e2e.url(server, "/sw/pre/page"))
	e2e.expect_eval(s, `document.body.textContent + " " + !!navigator.serviceWorker.controller`, "header= false", "its last client gone, the registration is too (a new page is not controlled)")
	e2e.eval(s, UNREGISTER_SW_SCOPES, await = true)
}

// Frame navigations: a scope given to register() is resolved against the document (its query kept); the worker answers the navigations of an <iframe>
// and of a <frame> with destination "iframe" / "frame" and mode "navigate". Then a page outside every scope, and unregistering.
@(test)
service_worker_frame_navigations :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = SW_SIZE, url = e2e.url(server, "/sw/sub/host")})
	e2e.expect_eval(s, `navigator.serviceWorker.register("/sw/frames.js", {scope: "../frm/?q"}).then((r) => new Promise((ok) => { const go = () => r.active && r.active.state === "activated" ? ok(new URL(r.scope).pathname + new URL(r.scope).search) : setTimeout(go, 50); go(); }))`, "/sw/frm/?q", "register(): a given scope is parsed against the document's URL and keeps its query")
	e2e.expect_eval(s, `new Promise((ok) => { for (const [tag, q] of [["iframe", "?q=i"], ["frame", "?q=f"]]) { const f = document.createElement(tag); f.src = "/sw/frm/" + q; document.body.appendChild(f); } const go = () => said.length >= 2 ? ok(said.slice().sort().join(",")) : setTimeout(go, 50); go(); setTimeout(() => ok("timeout " + said.join(",")), 8000); })`, "frame navigate ?q=f,iframe navigate ?q=i", "the worker answers frame navigations in its scope (request.destination iframe / frame, mode navigate)")
	e2e.navigate(s, e2e.url(server, "/site/index.html"))
	e2e.expect_eval(s, "String(navigator.serviceWorker.controller)", "null", "a page outside the scope is not controlled")
	e2e.expect_eval(s, `navigator.serviceWorker.getRegistrations().then((rs) => Promise.all(rs.map((r) => r.unregister()))).then((x) => x.join(","))`, "true", "unregister()")
}
