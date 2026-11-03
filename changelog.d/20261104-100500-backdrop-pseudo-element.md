type: Added

**`::backdrop`** of the top layer: a modal dialog, a showing popover and the fullscreen element get a box the size of the viewport just under them, above the page (the UA's faint grey behind a modal dialog, black behind a fullscreen element, styled by the page); a click on a dialog's backdrop is the dialog's, a popover's lets it through. `getComputedStyle(el, "::backdrop")` and `"::placeholder"` answer, and `::part()::backdrop` is a valid selector.
