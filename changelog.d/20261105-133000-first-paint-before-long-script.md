type: Fixed

**A long script no longer leaves a loading page blank** (`javascript.load.paint_wait_ms`, `javascript.load.slice_per_frame`): the parser stops before a script when what it attached can paint, and gives the loop a turn between inline scripts; once the page painted, scripts and the parser run in proportion to what its frames cost. cnn.com shows text at 1.3 s instead of about 5.5 s, whichever way the race went before.
