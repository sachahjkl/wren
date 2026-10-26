type: Added

**`MessageEvent.data` after an `await`**: a message from a worker or a port is deserialized when its event is dispatched, so a listener that reads `data`, `origin` or `ports` later still sees them.
