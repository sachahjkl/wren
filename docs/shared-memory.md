# SharedArrayBuffer and WebAssembly threads

A page and its workers can share memory: `postMessage` of a `SharedArrayBuffer` or of a shared `WebAssembly.Memory` gives the
same bytes, `Atomics.wait` and `Atomics.notify` work between them and with `memory.atomic.wait` and `notify` of a module, and a
`WebAssembly.Module` goes to a worker without being compiled again. An Emscripten build with pthreads needs all of that.

## Where the bytes are

Each realm is an instance of the JavaScript engine image, whose objects live in its own linear memory; no pointer in it can reach
another's. So a shared buffer's bytes are outside every realm: a Wasmtime shared memory (`src/wasm/user_shared.odin`).

- A module reaches them by its instructions, at full speed.
- A script reaches them through a host buffer (`Buffer_Host` in `src/engine/jsrt`): `data == nil`, one element is one call to
  the browser, and the JIT and the fast paths step aside. `new SharedArrayBuffer` makes such a memory too (`Host_Shared`,
  `config.host_shared`), a whole number of pages holding a length in bytes.
- `test262`'s image keeps the engine's own SharedArrayBuffers: its agents are not realms.

So the JavaScript engine's image did not have to be built with threads, and a realm that crashes still loses only itself.

## What a script sees of another agent's writes

Reads go through the same cache of 4 KiB pages as an ordinary memory's (`host_line`). It holds nothing after an `Atomics`
operation or a message, the points that order a program without data races, and at most for 256 reads, so a loop on a flag
without `Atomics` ends too. Writes go to the bytes at once (`host_shared_write`): a page written back later would overwrite what
another agent wrote beside it. A builtin working on a range pins only that range, for the same reason.

## Waiting

The place where waiters park belongs to the memory inside Wasmtime, which only the wait and notify instructions reach, so each
store has a small module importing the memory (`WAIT_MODULE`), through which `Atomics.wait` and `Atomics.notify` pass.

Nothing can interrupt a `memory.atomic.wait` in Wasmtime: a worker waiting without a timeout could never be stopped, and closing
its page waits for it. So a module with a shared memory is rewritten when it is compiled (`src/wasm/shared_waits.odin`): each wait
calls a function added at the end of the module, which waits for 50 ms at a time in a loop, and the epoch is checked at a loop's
back edge. `Atomics.wait` checks the stop flag between the same slices.

A window may not block (`[[CanBlock]]`): `Atomics.wait` throws there, and in a service worker. A module's own wait in a window
does block its thread, where browsers trap; Emscripten does not do it (it spins on the main thread), and the page can still be stopped.

## Between agents

A message carries a token, not the memory (`Clone_Tag.Shared_Buffer`, `Wasm_Memory`, `Wasm_Module`). Messages pass through the
engine's memory, so a token is 64 random bits, good only in its agent cluster: a page, its dedicated workers and frames of its
origin. Elsewhere it does not resolve, and the message fails to deserialize. What was sent goes when the last realm of the
cluster goes. A store keeps the memories its script has; a `SharedArrayBuffer` collected gives its use back.

Serializing for storage (IndexedDB, history) refuses all of these; a SharedArrayBuffer or a shared memory is sent only from a
cross-origin isolated realm.

## Cross-origin isolation

`Cross-Origin-Opener-Policy: same-origin` with `Cross-Origin-Embedder-Policy: require-corp` or `credentialless`, in a secure context,
gives a document `crossOriginIsolated` and the global `SharedArrayBuffer` (`apply_isolation_headers` in `src/page/page.odin`). A
frame has it from its parent when of the same origin; a dedicated worker from its creator.

- The embedder policy holds on what the document loads (`resource_policy_refuses` in `src/fetch/loader.odin`, the check of Fetch
  that also applies `Cross-Origin-Resource-Policy` to every page): a cross-origin response to a request without CORS needs that
  header, or under `credentialless` the request goes without credentials. A frame must have a policy of its own.
- Other browsers rely on the opener policy to put the document in a process of its own. Here a realm cannot read another's memory
  at all, being a Wasm instance, whichever the process.

## Limits

- `Atomics.waitAsync` does not exist; Emscripten has its own fallback.
- A growable `SharedArrayBuffer` grown by another agent is seen at the next `byteLength`, not on the next index.
- A shared memory is not counted against `wasm.max_pages` of a store: only its own declared maximum holds it.
