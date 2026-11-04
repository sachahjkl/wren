type: Fixed

**Closures are made as fast as before the JIT's round 21** (`src/engine/jsrt/object.odin`): the search of a shape's transitions is inlined in `add_property` again, which it had left when the JIT began appending properties itself; with the JIT off, a closure made and called in a loop 565 -> 540 ns (531 before round 21). try/catch in a loop was not slower: 68.4 before round 21, 69.3 after, the same within its range.
