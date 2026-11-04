type: Added

**CSS animations of transform and opacity go on while a page's script is busy** (`src/browser/shell_shown.odin`): the interface's frames drawn under a long script take their values from the page's timeline at their own time, without moving it, and the compositor applies them; the page's turn goes on from the same clock (nothing jumps, `getAnimations()` reads what it would have). Animations of other properties, of elements a script animates, and an opacity that was 1 at the last layout wait for the page as before.
