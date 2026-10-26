type: Added

**Service worker clients**: `clients.matchAll()` lists every window of the scope (`includeUncontrolled`: of the origin; not those in the back/forward cache), `clients.get`, `clients.openWindow` (a new tab, resolved with its `WindowClient`), `WindowClient.navigate` and `focus` (shows its tab), `visibilityState`, `focused`, `frameType`.
