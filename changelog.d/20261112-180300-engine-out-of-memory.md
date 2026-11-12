type: Fixed

**Large strings and arrays past the memory limit throw**: `repeat`, `padStart`, `join`, `toReversed` and array growth past the page's script memory limit throw a `RangeError` that the script can catch, instead of stopping the page's scripts.
