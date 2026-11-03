type: Fixed

**A frame keeps the Window of its initial about:blank**: when a frame's first document is of the same origin as the blank one it replaces, what a script set on the frame's window before it loaded (`iframe.contentWindow.foo = ...`, its listeners, `contentWindow.navigation.onnavigate`) is still there for that document, as HTML says; `history`, `customElements` and `navigation.activation` are the new document's.
