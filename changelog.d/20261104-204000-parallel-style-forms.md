Type: Fixed

**A crash while styling a page with radio buttons on several threads** (`src/page/bindings_forms.odin`, `style.Control_Provider.settle`): the style threads of a parallel pass asked the forms model for `:checked`, and the model filled itself in lazily (a control made, checkedness synced, a radio group's list rebuilt): two threads rebuilding the list at once freed it twice, and Wren aborted (seen on Linux on Wikipedia). The pass's thread now settles every control before the threads start, and their queries only read.
