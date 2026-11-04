type: Added

**CSS Nesting's nested declarations** (`CSSNestedDeclarations`): declarations after a nested rule apply after it, as their own rule in `cssRules` with its `style` and `cssText`; a nested selector without `&`, or one starting with a combinator, reads back with its implied `& ` (`.b` is `& .b`), and `&div` is invalid.
