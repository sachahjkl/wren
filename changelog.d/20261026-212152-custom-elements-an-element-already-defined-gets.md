type: Fixed

Custom elements: an element already defined gets its `connectedCallback` / `disconnectedCallback` in another document (a template's contents document, `createHTMLDocument`), where nothing is upgraded; `Range.cloneContents()` / `extractContents()` upgrade their clones.
