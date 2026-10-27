type: Changed

**Tab-strip view virtualization moved to the toolkit** (`toolkit:ui.reorder_visible`) : the pure helper that picks which tabs to build (the ones in view, two on either side) now lives beside the rest of the reorderable-list geometry in the toolkit; `strip_visible_tabs` stays as a thin alias, the tab strip and the sidebar do not change.
