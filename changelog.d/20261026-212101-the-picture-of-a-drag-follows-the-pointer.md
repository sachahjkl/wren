type: Added

**The picture of a drag follows the pointer** (`src/browser/dnd_image.odin`): what `setDragImage` gave (an `<img>` or a `<canvas>`: their pixels; another element: how it is drawn, read back from the frame) at its hot spot, else a translucent ghost of the dragged element grabbed where the pointer took it (`browser.dnd.image_opacity`, `browser.dnd.image_max_px`); drawn over the window, and handed to the system's drag when the pointer leaves it, so other applications show it too (toolkit 0.35.1).
