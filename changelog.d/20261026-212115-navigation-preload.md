type: Added

**Navigation preload**: `registration.navigationPreload` (`enable`, `disable`, `setHeaderValue`, `getState`), the navigation's request starts at once with `Service-Worker-Navigation-Preload`, `FetchEvent.preloadResponse` resolves with it, and a navigation the worker does not answer gets it instead of a second request.
