type: Fixed

**A blinking caret no longer repaints the page**: each toggle of a page field's caret redraws only the caret's pixels. Before, it redrew the whole page area. The status bar no longer draws a frame when its numbers come to rest with the same values. A caret's toggle while the status bar waits for a frame no longer starts its numbers again, so a focused field at rest makes only the caret's frames.
