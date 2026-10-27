type: Fixed

**`document.open()` erases the listeners and handlers of the document and of its Window** (HTML "erase all event listeners and handlers"): a `DOMContentLoaded` listener that opened and rewrote the document no longer runs again for the new document, forever (WPT `navigation-api/navigate-event/document-open-after-replaceState.html` crashed).
