type: Fixed

**No crash when a frame is removed during an event of its document**: a parent's listener on a node of a frame (an image's `load` or `error`...) that removes the frame no longer frees the frame's document under the event being dispatched; it is closed once the dispatch is over.
