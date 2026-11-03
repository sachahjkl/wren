type: Changed

**Text on several threads waits less**: a word's shape is read under a shared lock, and the glyphs of a run take the atlas lock once (`font.glyph_images`, `font.slug_glyphs`); the toolkit's helpers (the emoji font, wgpu-native) are fetched by its Odin tool `tools/tk`.
