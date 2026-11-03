type: Fixed

**Form controls take a line height of their own**: `input`, `button`, `select` and `textarea` reset `line-height` to normal, the font's weight and style, `letter-spacing`, `word-spacing`, `text-transform`, `text-indent` and `text-shadow` (the whole font shorthand of `-webkit-small-control`, and the text properties of the HTML rendering section), instead of inheriting them; and a `<button>` sits on the baseline of its content also when its overflow is hidden. The 20 px link chips of Google's AI mode no longer made their lines 3 px taller.
