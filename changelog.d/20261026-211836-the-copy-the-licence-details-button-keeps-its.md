type: Changed

**The "Copy the licence details" button keeps its width and has an icon** (`copy_details_html`, `about:wren`): its label used to be replaced by `Copied` / `Copy failed`, so the button shrank and jumped under the pointer. The three labels now share one grid cell and a state attribute (`data-state` on the button, set by the click handler) decides which shows, so the width is that of the longest one in any language (`i18n.tr` still gives every text); a Lucide icon in `currentColor`, 1em, sits left of the text (two rectangles, a tick once copied), inline in the page.
