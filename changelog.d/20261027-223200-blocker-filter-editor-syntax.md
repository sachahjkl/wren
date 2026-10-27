type: Added

**The "My filters" editor colours the filter syntax and underlines invalid lines** (`about:blocker`, `src/browser/blocker_filter_syntax.odin`): comments and headers, `@@` exceptions, `$options`, the `##` / `#@#` / `#?#` / `##^` / `+js(…)` cosmetic separators and the `||` `^` `*` `|` anchors are each in their own theme tone; a line the engine's own parser would drop is underlined in red, with its reason on hover. Built on the toolkit's new `ui.text_edit` highlighter (`ui.Text_Highlight`), so only the visible lines are classified.
