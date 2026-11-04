type: Changed

**The JIT calls the script's getters and setters** (`src/engine/jsrt/jit.odin`): a loop that reads a property through a getter of the script's (`get x() {...}`, a class's) or writes one through a setter, native or the script's, stays compiled, the accessor called as compiled code calls a function, an exception unwinding exactly once. A getter read in a loop 151 -> 78 ns, a setter 145 -> 81 ns, `getter access` of macro.js 184 -> 92 ns.
