type: Changed

**A full style pass with many `:has()` rules**: the elements that match their arguments were looked for by testing every element against every argument, on the window thread, after each full pass. Each element is now tested against the rules of its own classes, id, attributes and tag: cnn.com's full pass 286 -> 140 ms.
