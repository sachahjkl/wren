type: Added

**Shared Wasm memory between realms, tried**: two Wasmtime stores on two threads share a memory and wait for each other (`src/wasm/shared_memory_test.odin`). Sharing a `SharedArrayBuffer` would also need the JavaScript engine rebuilt for Wasm threads, a new start-up snapshot and weaker isolation between a page and its workers; `docs/shared-memory.md` explains why it is not done now.
