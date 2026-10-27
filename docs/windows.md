# Several windows

One Wren process can have several windows. A tab moves from one window to another with its page as it is: the document is not
loaded again, its scripts, timers, videos, forms, history, zoom and (when open) its developer tools go on.

## Using it

| What | How |
|---|---|
| New window | `Ctrl+N`, the command `window.new` |
| Tab to a window of its own | the tab's menu `Move tab to a new window`, the command `tab.move_to_new_window`, or drag the tab away from the tab bar |
| Tab to another window | the tab's menu `Move to window` (windows are named by the title of their current tab), or drag the tab onto the tab bar of that window (a mark shows where it will go) |
| From a script | `wren ctl windows`, `wren ctl tab move <id> --to new|<window id> [--index n]`, `--win-id <id>` on any command |

Dragging: while a tab is dragged along the bar it reorders. Further from the bar than `browser.tabs.detach_distance_em` (above or
below a row of tabs, beside a sidebar) it leaves for a window of its own, which follows the pointer; a tab alone in its window
carries that window. Released over another window's tab bar it joins that window and the empty window closes. `browser.tabs.drag_detach`
turns this off.

A window that loses its last tab closes. Closing a window closes its tabs (they can be reopened). Closing the last window ends the
browser. Tabs opened by the browser itself (a link, `window.open`, the address bar, a download's page, `about:` pages) open in the
window the user is in (the front one).

## How it works

* `Browser_Window` (`src/browser/windows.odin`): a native window, its swap chain (the first is the renderer's own, the others are
  `render.Surface` values swapped in for the length of their frame), its toolkit `ui.State` (`ui`), and its `Window_Ctx` (`tabs`,
  `current`, `address`, `page_rect`, `frames_requested`, `presented`, `focus_address`, embedded: `w.tabs`). None of it is copied
  into the `App`: the shell reads the window being framed (or the front one between frames) as `active_window(app)`
  (`active_window(app).tabs`, `.win`, `.ui`; `request_frames(app, n)` asks it for frames), any other window as `w.tabs`
  (`window_request(app, w, n)`). `window_activate` only makes a window the one framed (`app.active`), its toolkit state the
  toolkit's, its surface the renderer's, and adopts its pacing. An `App` with no window (the tests') has a bare one (`App.bare`).
  What the chrome keeps of a window (tab strip, sidebar, find bar, form controls, selection, cursors, address bar suggestions, full
  screen, context menu, frames' pointer, touch input, page preparation) is `Browser_Window.own` (`Window_Own`), read through
  `window_own(app)`; `tools\lint_globals.ps1` fails on a new global of a window.
* Everything that meant "every tab" reads `tabs_all(app)` or `tab_by_id`; `tab_reveal`, `tab_close_tab`, `address_set` and
  `window_of_tab` find a tab's own window.
* The loop (`windows_pass`) sleeps when no window has a cause, then makes a frame for each window (the front one first: it runs the
  tasks of the loop). A minimized window does not draw. The pacer (`pacing.odin`) is the window's (`Browser_Window.pacer`, read by `pacer_of(app)`: its monitor's rate, the cadence model's state, its frame clock); its preferences and timer are the process's (`App.pacing`). Nothing of it is exchanged by `window_activate`.
* Moves (`tab_move`, `tab_detach`) and the choice of the drop target (`drop_index`, `pick_drop`, `detach_wanted`) are pure and tested in
  `windows_test.odin` and `tab_drag_test.odin`.
* Session: `wren-session 3` lists the windows (`window left top width height state`, then their tabs); a one-window session is the old
  file. `browser.session.max_windows` caps what a restore reopens.

## Limits

* The developer tools' detached window follows the front window's current tab; the docked panel belongs to one window.
* Chrome frames while a page's script holds the thread (`shell_frames.odin`) exist for the window whose frame runs it; the others
  wait for it.
* The caret blink and the validation bubble timers of forms are the process's: two windows with a focused field blink together.
