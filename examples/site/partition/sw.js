// A service worker that does nothing (tools/partition_e2e.ps1: where its registration is seen).
self.addEventListener("install", () => self.skipWaiting());
