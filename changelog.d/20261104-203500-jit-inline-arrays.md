type: Changed

**Compiled code allocates array literals itself** (`src/engine/jsrt/jit.odin`): `[a, b, c]` in a compiled loop or function is made from the engine's own pool (the array, its slot and its values) without a call to the engine, as object literals already were; `[i, i + 1, i + 2]` 82 -> 35 ns, `[]` 60 -> 25 ns.
