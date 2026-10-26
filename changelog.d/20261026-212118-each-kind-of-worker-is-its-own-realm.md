type: Added

**Each kind of worker is its own realm**: `FetchEvent`, `Clients`, `ExtendableEvent`... exist in service workers only, `SharedWorkerGlobalScope` in shared workers only, `DedicatedWorkerGlobalScope` in dedicated workers only (the bindings generator knows `[Exposed=DedicatedWorker / SharedWorker / ServiceWorker]`); a service worker's global is a real `ServiceWorkerGlobalScope`.
