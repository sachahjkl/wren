type: Fixed

**A content script's `window.postMessage` reaches the page.** A message that an extension's content script posts to the window now fires in the page's scripts and in every content script world of the document, as in Chrome. Before, only the content script itself received it.
