type: Added

**CSS module scripts**: `import sheet from "./x.css" with {type: "css"}` (and `import()` with it) gives a `CSSStyleSheet` of the file's rules, to adopt with `adoptedStyleSheets`, as web component libraries do. A URL imported with one type and then another fails as in other browsers.
