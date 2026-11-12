type: Changed

**Canvases with transparency cost less per frame**: on Direct3D a 2D canvas drawn on the CPU is uploaded as it is (premultiplied), without a conversion per pixel; elsewhere the conversion uses a table of reciprocals instead of three divisions per pixel.
