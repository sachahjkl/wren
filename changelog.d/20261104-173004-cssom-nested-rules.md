type: Fixed

**Rules inside rules can be edited from scripts**: `insertRule` and `deleteRule` of `@media`, `@supports`, `@container`, `@layer` and nested style rules (CSS Nesting: `& .x`, declarations alone), a nested rule's `selectorText` and `style` written, and an outer rule's selector set all restyle the page; `cssRules` of a grouping rule is live, the rules removed or replaced leave their sheet (`parentStyleSheet` null), and `addRule`/`removeRule` work as in other browsers.
