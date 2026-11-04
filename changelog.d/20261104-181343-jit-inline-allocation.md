type: Changed

**Compiled code allocates objects itself** (`src/engine/jsrt/jit.odin`): an object literal and the object of `new F()` (the constructor's `prototype` guarded) are made by the code, from the engine's own pool and list of cells, without a call to the engine; the collector's contract is unchanged (allocation never collects). `new Point(i, i)` 110 -> 51 ns, `{a, b, c}` 57 -> 28 ns.
