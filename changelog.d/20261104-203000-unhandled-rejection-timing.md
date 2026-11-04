type: Fixed

**`unhandledrejection` at the right moment**: it is fired from a task queued when the microtask checkpoint ends, one for each checkpoint's rejections, so a task queued before it can still handle a rejection; `rejectionhandled` from a task queued when the handler is attached.
