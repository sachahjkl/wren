type: Fixed

**The caret of a focused field blinks only in the window the user is in** (`Forms_View.blink_timer`, `ui.Build_Params.inactive`) : with several windows, the caret of a page's field and of the chrome's fields (address bar, find bar) is hidden in the windows in the back, and each window's blinking runs on a timer of its own (one timer of the process blinked every window at the phase of the first). `wren ctl stats` gives `caretBlinking`, `caretShown` and `frontWindow`; `wren ctl window --front` / `--close` make a window the front one or close it.
