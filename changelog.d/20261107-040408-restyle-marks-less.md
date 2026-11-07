type: Changed

**Pages that change their DOM while loading restyle less**: an element added to a list no longer makes every sibling look again for `:first-child` or `:last-child`, a `:has()` inside `:not()` or `:is()` is only asked of the elements its selector can match, and `:has(+ x)` looks at the next element alone (cnn.com loads 18 % sooner).
