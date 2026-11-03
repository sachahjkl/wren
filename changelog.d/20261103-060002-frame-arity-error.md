type: Fixed

**A method of a frame's node given too few arguments throws the frame's `TypeError`** (`e instanceof frame.contentWindow.TypeError`), as in other browsers; it was the caller's since each window has its own built-ins.
