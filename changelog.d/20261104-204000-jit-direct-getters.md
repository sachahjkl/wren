type: Changed

**Compiled code calls the script's getters directly** (`src/engine/jsrt/jit.odin`): a getter of the script's read in a compiled loop or function (`get area() {...}`) is called as compiled code calls a function, its frame pushed by the code, without a call to the engine; `o.g` of a getter 79 -> 28 ns.
