type: Added

**A finger scrolls the page** (`src/browser/touch_shell.odin`): a pan scrolls the scroller under it and a quick one glides on (`smooth_scroll`), two fingers zoom like Ctrl+wheel, a long press opens the context menu, a tap clicks; `touch-action` (`none`, `pan-x`, `pan-y`, `pinch-zoom`, `manipulation`) is a computed style and is respected; a cancelled `touchstart` / `touchmove` leaves the gesture to the page; the system's mouse emulation of a finger is dropped (no more text selected by a pan). Preferences `browser.touch.*`.
