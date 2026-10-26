# SharedArrayBuffer between realms: the trial of tranche 4

Question: can a page and its workers share a `SharedArrayBuffer`? That means `postMessage` sends the same bytes, not a copy, and `Atomics.wait` / `Atomics.notify` work between them. Wren would expose it under COOP/COEP (`crossOriginIsolated`).

## What was tried

The test is `src/wasm/shared_memory_test.odin` (`two_stores_share_a_memory_and_wait_for_each_other`). The setup is the one a page and a worker would have: two Wasm instances, each in its own Wasmtime store and on its own thread. Wasmtime 49 has the threads proposal and shared memories turned on.

- Both instances import one `wasmtime_sharedmemory`.
- One thread blocks in `memory.atomic.wait32`, the instruction behind `Atomics.wait`.
- The other thread does `i32.atomic.store`, then `memory.atomic.notify`.

Result: the test passes. The waiting thread wakes up and reads the other thread's write. `notify` reports one woken waiter. The host sees the same bytes through `wasmtime_sharedmemory_data`. **The Wasmtime side works.**

## Why it stops there for now: the JavaScript engine

Each realm is an instance of the JavaScript engine image (`build/js/wren_js.wasm`, QuickJS compiled to `wasm32`). Its objects, including an `ArrayBuffer`'s bytes, live in **its own linear memory, memory 0**. C code in Wasm can only point into memory 0:

- clang has no pointers into a second memory (multi-memory);
- a typed array reads `ptr[i]`.

So the bytes of a `SharedArrayBuffer` must be in memory 0 of **every** realm that sees them. QuickJS has hooks for this (`JS_SetSharedArrayBufferFunctions`), but they only choose where the bytes go *within* memory 0.

The only way is for all the realms of an agent cluster (a page and its dedicated workers) to have **the same memory 0**: one engine image built for `wasm32-wasip1-threads`, run as one instance per thread on one shared memory. That costs:

1. **Building the engine for threads.** `tools/build_js.ps1` would target `wasm32-wasip1-threads`:
   - wasi-libc with locks in `malloc`;
   - `CONFIG_ATOMICS` in QuickJS, with `Atomics.wait` on a pthread condition;
   - a stack and thread-local storage per thread.
2. **Pre-initialization.** The image is pre-initialized (`preinit`: the snapshot of an engine already started, copied on write). A shared memory is initialized once (passive segments, `__wasm_init_memory`), not per instance. The snapshot and its copy-on-write start-up (which makes a realm start in about 1 ms) would have to be redone.
3. **Host functions.** Every browser function reads and writes guest memory through the instance's exported memory (`wasmtime_memory_data`). With a shared memory, every access path would change (`wasmtime_sharedmemory_data`), including the generated glue (bindgen).
4. **Isolation.** A trap or a memory corruption in one realm would reach every realm of the cluster, page included. Today a worker that crashes loses only its own memory. The `wasm32` limit of 4 GiB would also apply to the whole cluster instead of each realm.
5. **Memory accounting.** The per-realm limits and the memory tracking of the check build would have to count a shared heap.

## Conclusion

Feasible, but not at a reasonable cost now. It is a rewrite of how the JavaScript engine is built and started (items 1 to 3), and it weakens isolation (item 4). That is out of proportion to what pages gain from it today: the sites that need `SharedArrayBuffer` (Wasm threads, some codecs) also require COOP/COEP, which is rare.

What stays as it is:

- `crossOriginIsolated` is `false`;
- a `SharedArrayBuffer` sent by `postMessage` (or `structuredClone`) is not shared: the receiver gets a copy of its bytes, as it already does.

The trial and its test stay as a base if the decision is made later. The order would be items 1, 2, 3, then the COOP/COEP checks.
