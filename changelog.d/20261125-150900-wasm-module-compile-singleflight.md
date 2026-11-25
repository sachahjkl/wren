type: Fixed

**WebAssembly module compilation deduplication**: Concurrent tabs and workers loading the same WebAssembly module now share one compilation instead of compiling duplicate copies in parallel and starving worker startup.
