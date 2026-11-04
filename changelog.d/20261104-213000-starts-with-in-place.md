type: Fixed

**`startsWith` and `endsWith` compare in place** (`src/engine/jsrt/b_string.odin`): they searched the rest of the string for their argument, so a test that missed on a long string read all of it; WPT's `html/dom/idlharness.https.html` spent half its time there and was stopped by the 10 s script limit on a busy machine, with the JIT on or off.
