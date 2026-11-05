type: Added

**CSS Custom Highlight API**: `Highlight`, `HighlightRegistry`, `CSS.highlights` and `::highlight(name)`, painted with the selection's machinery: the background and the color of the rules over the ranges, in order of priority, following the registry and the ranges as they change. The syntax highlighters that use it (microlighter on css-tricks.com) no longer stop on a ReferenceError. Inside a frame the API works and paints nothing yet.
