type: Added

**HTML drag and drop for pages**: `dragstart`, `drag`, `dragenter`, `dragover`, `dragleave`, `drop`, `dragend` with a native `DataTransfer` (items, `types`, `files`, `getData` / `setData` / `clearData`, `dropEffect`, `effectAllowed`, `setDragImage`, the protected / read-only / read-write modes), `DataTransferItemList`, `DataTransferItem`, `DragEvent`, `FileList`; drags start from `draggable="true"` elements, links, images and the selection, and go to another application when the pointer leaves the window (toolkit 0.35.0 `platform.drag_start`).
