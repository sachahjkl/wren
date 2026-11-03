type: Fixed

**A document made by `createHTMLDocument` (or `DOMParser`) checks what is inserted into it as the page's does**: a text node, a second element, a fragment with text or two elements, a document, or an element before its doctype throw `HierarchyRequestError` instead of being inserted; `replaceChildren` on a document checks the new children as if the old ones were gone.
