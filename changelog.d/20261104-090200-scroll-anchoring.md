type: Added

**Scroll anchoring** (CSS Scroll Anchoring, `overflow-anchor`): when content above what you are reading changes size (an image that loads late, a banner inserted or removed), the page keeps showing the same content instead of jumping; not at the top of a page, not where `overflow-anchor: none` says so. Reading `scrollX` / `scrollY` from a script gives the offsets after the layout the script's changes call for.
