type: Added

`text.renderer` (`atlas`, the default, or `slug`): with `slug`, text is drawn on the GPU from the glyph outlines (Eric Lengyel's Slug algorithm, credited in `THIRD_PARTY.md`): sharp at any page zoom, rotation or transform, with exact subpixel positions and nothing to re-rasterize when the zoom changes. Emoji stay bitmaps. `text.slug.pages` (video memory budget) and `text.slug.tolerance`.
