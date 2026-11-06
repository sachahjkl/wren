type: Fixed

**A script before the first paint waits for the frame, not for a fixed time**: a frame later than 24 ms no longer lost its turn to the script, and deferred scripts, modules and async scripts that come once the document is parsed get that turn too (`javascript.load.paint_deadline_ms` replaces `javascript.load.paint_wait_ms`).
