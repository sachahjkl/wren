type: Changed

**Faster style computation**: keywords, lengths and plain colors of a stylesheet are compiled once, when the sheet is read, instead of being read again for every element they apply to; CSS-wide keywords and enum keywords are found with no per-element text comparison.
