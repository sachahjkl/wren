type: Added

**The drag picture of any element, wherever it is** (toolkit 0.35.2 `draw.offscreen_begin` / `render.readback_poll`): the element `setDragImage` names, or the dragged element's ghost, is painted alone into an offscreen target and read back, so an element placed off the page (`top: -1000px`), scrolled away or under others gives its picture; an element that is not rendered (`display: none`) gives the dragged element's ghost, as in other browsers. `wren ctl stats`: `dragPicture` (size, hot spot, middle pixel).
