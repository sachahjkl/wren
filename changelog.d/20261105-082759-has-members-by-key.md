type: Changed

**A full style pass with many `:has()` rules**: the elements that match their arguments were looked for by testing every element against every argument, on the window thread, after each full pass. Each element is now tested against the rules of its own classes, id, attributes and tag: 300 such rules and 8 000 elements, ten passes: 1 396 -> 267 ms with the classes' bits.
