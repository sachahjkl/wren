type: Added

**Emoji and color glyphs in canvas text** (`fillText`, `strokeText`, `measureText`): a glyph a font draws in color (COLR / CPAL, sbix, CBDT, SVG) is now drawn in color, as an image at its placed position, instead of its outline or nothing. It goes through the same color-glyph rasterizer the chrome uses (`font.color_glyph_rgba`), takes the canvas transform, global alpha, shadow, filter and clip like any `drawImage`, and works on the software and the GPU path. `measureText` returns the glyph's bitmap box for emoji. The text color reaches a glyph's foreground / text-color layers.
