type: Fixed

**`document.open()`, `write()` and `close()` on a document of its own** (DOMParser's, createHTMLDocument's, a response's) act on it, not on the page, which they replaced.
