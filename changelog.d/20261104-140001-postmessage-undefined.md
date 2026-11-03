type: Fixed

**`postMessage(undefined)` arrives as `undefined`**: a message's data was taken for a missing one and became `null` (the default of `new MessageEvent()` and `initMessageEvent`, which keep it).
