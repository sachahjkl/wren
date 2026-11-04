Type: Fixed

**The developer tools' highlight of an element lets the page show through** (`src/browser/devtools_elements.odin` `elements_overlay`): its margin, border, padding and content areas were painted one over the other, so the content got four layers of color and hid the page; each area is now a ring around the next, one light layer per pixel, in Chromium's hues.
A comment or the doctype chosen in the DOM tree highlights nothing (it highlighted its parent); a text node still shows its parent's box.
