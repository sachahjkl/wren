type: Fixed

**Marking what a DOM change restyles stops when a full pass is shorter**: thousands of elements attached under `:has()` anchors took 8.7 s of answers on cnn.com to find that a full pass of 0.2 s was due. A batch of mutations larger than `style.incremental.max_ratio` of the document goes to the full pass at once.
