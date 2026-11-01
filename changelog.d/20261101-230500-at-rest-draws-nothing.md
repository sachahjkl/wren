type: Fixed

**A browser at rest draws nothing**: on a page that changes nothing it drew 4 to 5 frames a second for good; now none, and a process's own wakes fall to the odd one.
  - The status bar's settling timer counted as work of the page: two frames, which were samples, which put the settling off and armed it again.
  - Background work (the autosave, the crash snapshot, the history's writes, the content blocker's rounds and its lists arriving, 8 frames a second while they did) no longer draws.
  - A caret's toggle in a page's field is one frame at its own period, drawing only the caret's pixels; it does not count as activity for the status bar or for giving memory back. The caret of the address bar wakes at its flips, not twice as often.
  - The accessibility trees' rate no longer asks for a frame at every frame.
  - `wren ctl stats` has `loop`: turns, sleeps, wakes that drew nothing, frames by cause, and who asked for the last ones.
