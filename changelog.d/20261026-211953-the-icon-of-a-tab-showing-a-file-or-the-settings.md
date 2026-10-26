type: Fixed

**The icon of a tab showing a file (or the settings) sits in its square** (`tab_strip.odin` `tab_icon_draw`, toolkit 0.40.2 `font.glyph`): in the sidebar, the row of tabs and the icons-only sidebar the document was drawn a glyph lower than its row, larger than its 16 px square, cut by the row and over the title. The native text backend gave `font.glyph` an ink box twice as high (fixed in the toolkit), and the glyph is now fitted into the square (`icon_glyph_fit`).
