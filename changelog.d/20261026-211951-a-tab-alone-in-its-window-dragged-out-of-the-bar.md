type: Fixed

**A tab alone in its window, dragged out of the bar, no longer sends its window off the screen** (`tab_drag.odin`): the window that took the press is the one that moves, and its pointer position was taken from the event plus the window origin read after it had moved, so each move added the error of the one before and the window ran away, invisible, still in the task bar. The pointer is read from the system now, and the window is kept partly on a monitor.
