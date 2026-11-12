type: Changed

**Faster 2D canvas fills and drawImage**: a canvas drawn on the CPU paints rows of pixels at once, and an image drawn at its own size, or scaled or turned with smoothing, is sampled a row at a time. The pixels are the same as before (a smoothed, scaled image within one level of a channel).
