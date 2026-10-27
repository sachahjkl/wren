type: Fixed

**Emoji on canvas no longer re-uploaded each frame** (`font.color_glyphs`) : the shell now caches rasterized color glyphs (emoji, COLR / sbix / CBDT / SVG) by face, glyph, size and text colour, with a stable identity the GPU source cache keys on. An animation that draws the same emoji every frame rasterizes and uploads it once instead of once per frame. The cache clears when the fonts change or it fills up (bounded by `canvas.glyph_cache_entries`).
