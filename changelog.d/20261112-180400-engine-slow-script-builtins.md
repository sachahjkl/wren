type: Fixed

**Long built-in loops stop at the slow-script limit**: `fill`, `indexOf`, `includes`, `join`, `reverse`, `sort`, `repeat`, `padStart` and the same methods of typed arrays over huge lengths now stop when a script runs too long.
