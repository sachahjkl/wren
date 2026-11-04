type: Fixed

**An inline `<svg>` no longer blinks out when its colour changes** (`src/page/inline_svg.odin`): an icon in `currentColor` given a new colour (`:hover`, a class, a mutation) is new markup, parsed and rasterised on the decoding threads, and until its picture was there the icon was drawn as nothing: the painting start page's shortcut icons disappeared for a frame or more at a hover, the first time each colour was asked for. The picture drawn last now stands for it until the new one is made.
