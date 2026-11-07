type: Fixed

**Incremental layout gives what a full pass gives in more cases**: a `<br>` hidden beside block children, an element with `display: contents` or a `<slot>` that gets a box, a block inserted after a `::before`, a box that stops clearing a float, an empty inline box past the end of a line, text in two empty neighbours, text in an inline-block that changes its baseline, a hidden `<option>` of a `<select>`, the markers of a page's only list shown after `display: none`; a `transform` animation on an inline box no longer makes it a stacking context.
