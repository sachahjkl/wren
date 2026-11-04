type: Changed

**The JIT reads `document`** (`src/engine/jsrt/jit.odin`): compiled code calls the native getter of an own accessor of the global object (`window.document`) when its value is read from at once (`document.createElement(...)`), an exception exact through the next read, which throws it; a call whose callee the translation cannot tell learns it at its first exit. The building loop of nodes10k is compiled: `build()` 9.0 -> 7.9 ms a frame with the JIT (the same without it).
