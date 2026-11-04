type: Added

**Scroll boxes follow the wheel and their scroll bar's thumb while a page's script is busy** (`src/browser/shell_shown.odin`): the box under the pointer scrolls at once, painted from the page's last layout, and takes the offset at the page's turn with its `scroll` event; the wheel over a box no longer scrolls the document under it.
