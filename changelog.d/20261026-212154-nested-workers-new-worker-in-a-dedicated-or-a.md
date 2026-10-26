type: Added

Nested workers: `new Worker()` in a dedicated or a shared worker (classic, module, blob: and data: scripts), messages with buffers and ports both ways, the child's errors as `error` events in its parent, `terminate()` and the end of a worker taking its children along; `workers.max_depth` bounds the nesting.
