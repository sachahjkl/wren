package main

// Endpoints for the service worker test (tools/sw_e2e.ps1), where a static file cannot do:
//
//	/sw/ver.js        a service worker whose script changes when /sw/bump is fetched (update, waiting, skipWaiting)
//	/sw/bump          the next /sw/ver.js is another version
//	/sw/ver/page      a page in ver.js's scope (/sw/ver/)
//	/sw/preload.js    a service worker of scope /sw/pre/ enabling navigation preload with the header value "wren-test"
//	/sw/pre/page      text: the Service-Worker-Navigation-Preload header it got
//	/sw/frames.js     a service worker (registered with scope "../frm/?q" from /sw/sub/host) answering the navigations of
//	                  frames with a document that tells its parent the request's destination and mode
//	/sw/sub/host      a page outside that scope, to put the frames in
//	/sw/frm/          what the network says when the worker did not answer

import (
	"fmt"
	"io"
	"net/http"
	"sync/atomic"
)

var swVersion atomic.Int64

const swVerScript = `// version %d (tools/testserver/sw.go)
const V = %d;
let remembered = "nothing";
self.addEventListener("install", (e) => { if (V === 1) self.skipWaiting(); });
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", (e) => {
  if (new URL(e.request.url).pathname.endsWith("/v.txt")) e.respondWith(new Response("v" + V));
});
self.addEventListener("message", (e) => {
  const say = (x) => e.source.postMessage(x);
  const d = e.data;
  if (d === "skip") { self.skipWaiting(); say("skipping"); }
  else if (d === "who") say("v" + V);
  else if (d === "types") say([typeof FetchEvent, typeof Clients, typeof DedicatedWorkerGlobalScope, typeof SharedWorkerGlobalScope, typeof ServiceWorkerGlobalScope].join(" "));
  else if (d === "clients") self.clients.matchAll({includeUncontrolled: true}).then((cs) => say(cs.length + " " + cs.map((c) => c.type + ":" + new URL(c.url).pathname).join(",")));
  else if (d === "get") self.clients.get(e.source.id).then((c) => say(c ? "got " + (c.id === e.source.id) + " " + c.frameType : "none"));
  else if (d === "focus") self.clients.get(e.source.id).then((c) => c.focus()).then((c) => say("focused " + c.focused), (x) => say("refused " + x.name));
  else if (d === "open") self.clients.openWindow("/sw/ver/opened").then((c) => say(c ? "opened " + new URL(c.url).pathname : "null"), (x) => say("refused " + x.name));
  else if (d === "workers") self.clients.matchAll({type: "worker"}).then((cs) => say(cs.map((c) => c.type + ":" + (c instanceof WindowClient)).join(",")));
  else if (d === "remember") { remembered = "kept"; say("ok"); }
  else if (d === "recall") say(remembered);
  else if (d === "state") say(self.serviceWorker.state + " " + (self.registration.active === self.serviceWorker));
});
`

const swPreloadScript = `// navigation preload (tools/testserver/sw.go)
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.registration.navigationPreload.enable()
  .then(() => self.registration.navigationPreload.setHeaderValue("wren-test")).then(() => self.clients.claim())));
self.addEventListener("fetch", (e) => {
  if (e.request.mode !== "navigate") return;
  if (new URL(e.request.url).pathname.endsWith("/fallback")) return;   // not answered: the preload's response is used
  e.respondWith(e.preloadResponse.then((r) => r ? r.text().then((t) => "preloaded " + r.status + " " + t) : "no preload")
    .then((s) => new Response("<p id=x>" + s + "</p>", {headers: {"content-type": "text/html"}})));
});
`

const swFramesScript = `// frame navigations (tools/testserver/sw.go)
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("fetch", (e) => {
  if (e.request.mode !== "navigate") return;
  const said = e.request.destination + " " + e.request.mode + " " + new URL(e.request.url).search;
  e.respondWith(new Response("<!doctype html><script>parent.postMessage(" + JSON.stringify(said) + ", '*');</script>", {headers: {"content-type": "text/html"}}));
});
`

func registerSWHandlers(mux *http.ServeMux) {
	mux.HandleFunc("/sw/frames.js", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/javascript")
		io.WriteString(w, swFramesScript)
	})
	mux.HandleFunc("/sw/sub/host", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		io.WriteString(w, `<!doctype html><meta charset="utf-8"><body><script>window.said = []; addEventListener("message", (e) => said.push(String(e.data)));</script></body>`)
	})
	mux.HandleFunc("/sw/frm/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		io.WriteString(w, `<!doctype html><script>parent.postMessage("network", "*");</script>`)
	})
	swVersion.Store(1)
	mux.HandleFunc("/sw/ver.js", func(w http.ResponseWriter, r *http.Request) {
		v := swVersion.Load()
		w.Header().Set("Content-Type", "text/javascript")
		w.Header().Set("Cache-Control", "max-age=3600")   // update() must bypass the HTTP cache anyway
		fmt.Fprintf(w, swVerScript, v, v)
	})
	mux.HandleFunc("/sw/bump", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "%d", swVersion.Add(1))
	})
	mux.HandleFunc("/sw/ver/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		io.WriteString(w, `<!doctype html><meta charset="utf-8"><p id="x">`+r.URL.Path+`</p><script>window.swMessages = []; if (navigator.serviceWorker) navigator.serviceWorker.addEventListener("message", (e) => swMessages.push(String(e.data)));</script>`)
	})
	mux.HandleFunc("/sw/preload.js", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/javascript")
		io.WriteString(w, swPreloadScript)
	})
	mux.HandleFunc("/sw/pre/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		io.WriteString(w, "header="+r.Header.Get("Service-Worker-Navigation-Preload"))
	})
}
