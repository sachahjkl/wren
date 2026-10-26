type: Added

**Text dropped on a field or on `contenteditable` is inserted where the drop caret is** (`src/page/dnd_default.odin`): a caret follows the pointer while text is dragged over it; a selection dragged out of a field or an editing host of the page is moved (Ctrl copies), with `beforeinput` / `input` of `deleteByDrag` at the source then `insertFromDrop` at the target (cancelable), the dropped text selected; the selection of a field can now be dragged.
