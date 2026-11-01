// A service worker that does nothing (src/tools/e2e/partition.odin: where its registration is seen).
self.addEventListener("install", () => self.skipWaiting());
