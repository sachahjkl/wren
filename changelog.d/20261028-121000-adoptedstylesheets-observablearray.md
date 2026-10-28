type: Fixed

**Constructable stylesheets** (`Document.adoptedStyleSheets`, `ShadowRoot.adoptedStyleSheets`) : the ObservableArray is again a `Proxy` over a real array, so `Array.isArray()` returns true, the IDL type check passes, and `defineProperty` re-runs the descriptor conversion (an accessor that becomes non-callable mid-conversion is rejected with a TypeError). An exotic class could satisfy none of these; the index/length/delete checks and the browser commit stay native (C-trapped Proxy, no prelude JavaScript).
