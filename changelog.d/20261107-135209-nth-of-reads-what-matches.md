type: Changed

**Less style work when elements come and go beside `:nth-child(... of S)`, `:nth-of-type()`, `:first-of-type`, `:only-of-type` and the like**: an element added, removed or given another class restyles only the siblings whose index among those that match S (or are of its type) moved, counted from the end the selector reads, instead of every sibling past it (cnn.com: 1 800 elements a load restyled to no effect, now 30).
