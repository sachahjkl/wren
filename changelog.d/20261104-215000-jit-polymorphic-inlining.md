type: Changed

**Compiled code inlines calls that reach several functions** (`src/engine/jsrt/jit.odin`): a method call whose objects are of up to four classes (`shapes[i].area()`) inlines each class's method behind a check of the function, where it used to inline one and call the others; `poly[i & 3].area()` over four classes 79 -> 13 ns.
