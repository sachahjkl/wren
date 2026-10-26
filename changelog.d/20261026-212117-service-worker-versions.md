type: Added

**Service worker versions**: installing, waiting and active versions, `updatefound` and `statechange`; a changed script waits while the active version has clients, `skipWaiting()` promotes it, the clients get the new one (`controllerchange`); each version keeps the script it installed (`<profile>/service_workers/<version>.js`).
