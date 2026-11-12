type: Fixed

**Long selectors on deep pages no longer stall the style pass.** A selector such as `.a .b .c .d` on an element deep in a page that has no `.a` was tried against every combination of ancestors; it now stops as soon as no ancestor can match, so its cost grows with the depth instead of a power of it. `:has()` no longer looks above its own element. A new preference, `style.selector_match.max_steps`, bounds what one selector may cost on one element.
