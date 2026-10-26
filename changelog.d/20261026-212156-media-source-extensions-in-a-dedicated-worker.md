type: Added

Media Source Extensions in a dedicated worker: `MediaSource.canConstructInDedicatedWorker` is true, `mediaSource.handle` (a transferable `MediaSourceHandle`), `video.srcObject = handle` in the page; the worker's `MediaSource` and `SourceBuffer`s work as in a page (their state mirrors the page's, events included) while the page parses and plays; an object URL made in a worker names nothing.
