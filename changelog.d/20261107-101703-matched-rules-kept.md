type: Changed

**Less style work when a value every element inherits changes** (a custom property written on the root element, a query container that changes size): an element restyled for what it inherits alone is no longer matched against the selectors again; what it matched is kept with its style, once for all the elements that matched the same rules (cnn.com: 11 000 elements a load, 170 KB). A class rewritten with the same names, and an element added far from where `:nth-child(3)` looks, restyle nothing more.
