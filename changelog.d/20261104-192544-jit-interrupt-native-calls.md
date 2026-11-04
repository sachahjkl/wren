type: Fixed

**A compiled loop of slow native calls is stopped like a slow script** (`src/engine/jsrt/jit.odin`): the compiled code gives the interrupt its turn once its native calls count for a poll, as the interpreter does; a `document.write` flood compiled by the JIT could run past `wasm.max_call_ms` before it, and the page lost its JavaScript engine.
