// The Clipboard API's browser side (module navigator; the engine side is native/js/odin/web_clipboard.odin): the
// system clipboard's text, read and written asynchronously. A browser promise is a handle of module async.
package api_decl

import "../abi"

// navigator.clipboard.readText(): a browser promise of the text (NotAllowedError without permission).
Clipboard_readText  :: #type proc() -> abi.Handle
// navigator.clipboard.writeText(data): a browser promise.
Clipboard_writeText :: #type proc(data: string) -> abi.Handle
// window.isSecureContext (module window)
Window_isSecureContext :: #type proc() -> bool
