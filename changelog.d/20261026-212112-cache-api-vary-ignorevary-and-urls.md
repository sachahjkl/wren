type: Added

**Cache API: `Vary`, `ignoreVary` and URLs**: an entry matches only a request with the same values of the headers its response varies on (`Vary: *` never), `put` replaces only what its request matches, `ignoreVary` lifts it; `cache.keys()` gives the stored requests' headers; a response from the cache keeps its `url`.
