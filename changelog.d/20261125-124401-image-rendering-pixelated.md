type: Fixed

**CSS `image-rendering` (`pixelated`, `crisp-edges`)**: pixel art and crisp icons styled with `image-rendering: pixelated` or `crisp-edges` (including inherited values and `-moz-crisp-edges` / `-webkit-optimize-contrast`) now render with nearest-neighbour sampling on `<img>`, `<canvas>`, `<video>`, inline `<svg>`, and CSS `background-image` / `mask-image` layers instead of blurring when upscaled.
