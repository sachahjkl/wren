type: Changed

**Compiled bitwise operations take undefined, null and booleans** (`src/engine/jsrt/jit.odin`): `m.get(k) | 0` of a key a map does not have, or a flag xor-ed with a number, no longer sends a compiled loop back to the interpreter at each such value until it gives up; macro.js's Map set/get 288 -> 163 ns.
