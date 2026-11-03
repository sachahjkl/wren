type: Fixed

**The interface's names and protocols match ASCII case alone** (gui_toolkit 0.73.0): the developer tools' server takes `Ho\u017Ft:` (a long s U+017F) for no Host header and `localho\u017Ft` for no localhost, nor `Sec-WebSocket-\u212Aey` (a Kelvin sign U+212A) for the WebSocket key; a font family written with a Kelvin sign or a long s is not the family whose name has a `k` or an `s` (on Linux fontconfig's default font is no longer taken for it). Searches, find in page and type-ahead still fold case by Unicode.
