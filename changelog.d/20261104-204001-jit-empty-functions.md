type: Changed

**Empty functions are compiled** (`src/engine/jsrt/jit.odin`): a function without an operand stack (`function Empty() {}`, a no-op callback) is compiled whole and called directly, so a loop that calls or constructs one is compiled too; `new Empty()` 188 -> 42 ns.
