type: Fixed

**A frame of its parent's origin shares its agent cluster on plain http too** (a `WebAssembly.Module` posted to it arrived nowhere outside a secure context), and **the cross-origin resource policy check compares the request's own origin**: a no-cors fetch redirected through another origin back to the page's own origin is no longer refused by `Cross-Origin-Resource-Policy: same-origin`.
