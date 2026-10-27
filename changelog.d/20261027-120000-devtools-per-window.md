type: Added

**Developer tools for each window** (`Window_Own.devtools`, `devtools_follow_tab`) : every browser window has its own developer tools, docked in it or in a window of their own, showing its current tab. A tab they show that moves to a window without open developer tools takes them along; closing a window closes its developer tools' window. `wren ctl windows --json` gives each window's (`devtools`: visible, dock, panel, detached, hwnd) and its `dpiScale`; `wren ctl devtools --dock window` opens them in a window of their own.
