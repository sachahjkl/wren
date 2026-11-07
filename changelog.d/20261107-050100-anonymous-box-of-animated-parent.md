type: Fixed

**Crash on animated containers**: the anonymous box around the text of an animated element (a flex container, a block with blocks beside its text) kept a pointer into the styles of an earlier pass, freed by a full restyle.
