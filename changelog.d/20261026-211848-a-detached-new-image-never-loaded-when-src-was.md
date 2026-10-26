type: Fixed

A detached `new Image()` never loaded when `src` was set before it was attached to the document; it now starts loading at once (needed by `drawImage`).
