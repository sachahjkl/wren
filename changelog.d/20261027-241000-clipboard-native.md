type: Changed

**`ClipboardItem` and `navigator.clipboard.read` / `write` are native** : they come from the engine (`runtime/web_clipboard.c`) on top of the browser's `writeText` / `readText` instead of prelude JavaScript (`prelude/clipboard.js`), trimming the realm image. Behaviour is unchanged: only `text/plain` goes through the system clipboard, `write()` keeps text/plain and rejects `NotAllowedError` otherwise, `read()` returns one item with the clipboard's text.
