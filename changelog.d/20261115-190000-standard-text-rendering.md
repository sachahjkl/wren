type: Removed

**Wren's own text and colour-mixing settings**: the toolkit's standard text and rendering settings, which already applied at once, now take their place. Wren keeps its defaults (Slug text, colours mixed on sRGB values, Chromium's text correction). about:settings has new Text and fonts and Rendering pages.
  - `render.blend_space`, `render.text.curve`, `render.text.gamma`, `render.text.contrast` and `render.text.coverage_exponent`: use `appearance.text.blend_space`, `appearance.text.curve`, `appearance.text.gamma`, `appearance.text.contrast` and `appearance.text.coverage_exponent`.
  - `text.emoji`: Wren draws the emoji from its built-in font, or from the file that `appearance.text.emoji_font` names. The system draws them only when Wren has no emoji font.
  - `text.emoji.raster_samples` and `text.emoji.outline_cache`: the toolkit's values (8 samples, 8 MiB).
  - `text.backend`: the build chooses the text backend (`WREN_TEXT=dwrite` for DirectWrite).
