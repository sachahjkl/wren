// The service worker of tools\sw_e2e.ps1: caches data.txt at install, answers virtual.txt and virtual-page.html
// itself, serves data.txt from its cache, and answers messages.
self.addEventListener("install", (e) => {
  e.waitUntil(caches.open("v1")
    .then((c) => c.addAll(["data.txt"]).then(() => c.put("cached-only.txt", new Response("put by the worker"))))
    .then(() => self.skipWaiting()));
});
self.addEventListener("activate", (e) => {
  e.waitUntil(self.clients.claim());
});
self.addEventListener("fetch", (e) => {
  const u = new URL(e.request.url);
  if (u.pathname.endsWith("/virtual.txt")) {
    e.respondWith(new Response("from the service worker", { headers: { "content-type": "text/plain" } }));
  } else if (u.pathname.endsWith("/virtual-page.html")) {
    e.respondWith(new Response('<!doctype html><p id="x">a page the service worker made</p>', { headers: { "content-type": "text/html" } }));
  } else if (u.pathname.endsWith("/data.txt") || u.pathname.endsWith("/cached-only.txt")) {
    e.respondWith(caches.match(e.request).then((r) => r || fetch(e.request)));
  }
});
self.addEventListener("message", (e) => {
  e.source.postMessage("pong:" + e.data);
});
