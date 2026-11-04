type: Added

**Synchronous XMLHttpRequest in documents**: `send()` waits on a network stack of its own, so that no page runs under the waiting script; the interface keeps its turns (`javascript.xhr.sync_timeout_ms` bounds the wait).
