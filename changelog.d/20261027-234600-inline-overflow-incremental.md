type: Fixed

**An incremental layout no longer disagrees with a full one on an inline box that has `overflow` set** : a `display: inline` box with `overflow: auto` (`<span class="scroll">`) is never a scroll container, so finishing now leaves its scrollable overflow empty in both the full and the incremental paths instead of seeding it to its padding box in the full pass only; the value is never read for inline boxes, and the two layouts agree again (`layout.incremental.verify`).
