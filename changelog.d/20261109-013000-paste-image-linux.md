type: Fixed

**Pasting an image on Linux** (gui_toolkit 0.107.0): an image copied in another program (PNG, or JPEG or BMP when it offers no PNG) reaches the page, and a list of files copied in a file manager does too; the toolkit had no PNG codec off Windows, so a pasted image never arrived. The reftest runner writes its pictures with the toolkit's PNG codec, not one of its own.
