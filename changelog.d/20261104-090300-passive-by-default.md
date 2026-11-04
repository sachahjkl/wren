type: Changed

**Wheel and touch listeners on the window, the document and its root are passive by default**: a `wheel`, `mousewheel`, `touchstart` or `touchmove` listener added there without `{passive: false}` cannot cancel the event (DOM's default passive value), so a page whose listener calls `preventDefault()` scrolls as it does in Chrome and Firefox.
