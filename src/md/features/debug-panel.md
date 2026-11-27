# The debug panel

## Purpose

A developer of Wren needs to see the browser's own state while it runs: how many pages are alive, what the image
cache holds, how the frames go, how much memory the process takes. The developer also needs to act on it: give memory
back, reload every tab, switch a subsystem off to isolate a bug. Before this panel, these values were in `wren ctl
stats` (a JSON dump on request), in the status bar (a few numbers) and in about: pages. None of them shows the values
live beside the page, and none of them can be driven by the same names from a script.

The toolkit's debug surface (`ext/gui_toolkit/docs/debug.md`, `toolkit:debug`) gives this: a dense window
(Ctrl+Alt+Shift+D) and the tools' `Toolkit.debugPanels`, `debugSet` and `debugPress` (`tk cdp debug`). Wren registers
one panel, **Wren**, in `src/browser/debug_panel.odin`.

## What it shows

Each value is a count that Wren already keeps. The panel makes no new count.

| Path | What | Why |
|---|---|---|
| `Wren/pages/windows`, `tabs_window`, `tabs` | the windows, the tabs of the window shown, the tabs of every window | a tab that does not close, a window that does not go |
| `Wren/pages/pages` | the documents alive on this thread (`page.pages_alive`, the length of `live_pages`: tabs, frames, kept pages) | a page that leaks after its tab closed |
| `Wren/pages/wasm_instances` | the Wasm instances alive in the process (atomic) | one per realm: a realm that leaks |
| `Wren/pages/workers` | the workers that hold a slot in the process (atomic) | a worker that does not end |
| `Wren/tab/*` | the current tab: its address, its title, whether it loads, its zoom, its last layout time | the page that the other numbers are about |
| `Wren/images/*` | the image cache: entries, bytes, limit; the decoder: jobs decoded and failed, the busy time, the longest job | a cache over its limit, a decoder that falls behind |
| `Wren/frames/*` | the status bar's numbers: frames per second, CPU and GPU time, frames over the budget; the window's rate; the chrome frames made and skipped | the frame pacing at a glance |
| `Wren/memory/*` | the working set and the private bytes, the trims done | memory that grows |
| `Wren/Preferences/<name>` | a few switches that a developer flips to isolate a bug | see below |
| `Wren/Trim memory` | `memory_trim`: what an idle browser does | check that memory comes back |
| `Wren/Reload all tabs` | `reload` of every web tab | reproduce a load |
| `Wren/Print` | the values above as Odin text on the standard output | paste them into a bug report or a test |

The values are one struct (`Debug_State`), made in one pass when the panel runs and shown read only by reflection.
So `Print` writes the same values as the window shows, and a new value is one field.

## The thread rule

The panel's procedure runs on the interface thread, each frame while its tab shows. So it reads only:

- fields of the App and of the window: the length of a list, a number;
- atomics: `wasm.instances_alive`, `page.workers_running`;
- `images.decoder_stats`: a copy of 40 bytes under the decoder's mutex. The decoding threads hold that mutex only to
  move a job in or out of the queue, never while they decode, so the wait is a few instructions.

It reads no file, makes no system call, and walks no collection.

- The memory numbers are the status bar's snapshot (`app.hud.nums`), refreshed every `browser.status_bar.refresh_ms`.
  `base.process_memory` reads `/proc` on Linux: the panel does not call it each frame. While the status bar and the
  title show no statistics, nothing refreshes the snapshot: `frames/measured` says so.
- A chrome frame (`shell_frames.odin`) builds the window while a page holds the thread: a guest call, a style pass, or
  a layout on the page thread. Then the page's layout and its document are not Wren's to read, and an act that
  reloads or trims would run inside that work. In a chrome frame the panel shows one note and nothing else. The tools'
  passes run in `ui_cdp_frame`, at the start of a full frame, so they always see the whole panel.

## Where it is registered

`views_attach` (`views.odin`) is where every browser window's `ui.State` gets the program's views: the first window in
`app_ui_init`, each other window in `window_open`. The panel is registered there, once per State, with the App as its
data. The App outlives every State: a window's State is destroyed (`ui.destroy`, which ends the surface) before the
window and long before the App. So `data` never dangles.

The panel shows the window being framed (`active_window`): the window whose debug window is built.

## Preferences

A switch reads its value from the preferences at each run (`config.bool_of`: one lookup). A change goes through
`set_pref_bool`, the path of the status bar's own toggle: the binding applies it at once, and the profile writes the
user's layer as for any other change. The switches:

- `browser.status_bar.visible`: it also turns the frame and memory snapshot on;
- `browser.shell.page_thread`, `browser.shell.preempt`: the page thread and the chrome frames;
- `render.compositor.enabled`, `paint.effects.cache.enabled`: the compositor and the effects cache;
- `history.bfcache.enabled`, `browser.paint_holding.enabled`.

## Builds

The surface is compiled in when `TOOLKIT_DEVTOOLS` is true: a build with `-debug` (dev, quick, debug, check, profile)
and a test. The release has none of it, so the panel has no changelog entry.

## Refused

- **The HTTP cache, the bytecode cache, the Wasm module cache, the decoded fonts.** Their counts are behind locks that
  other threads share. `wren ctl stats` reads them on request.
- **The memory read at each frame** (`base.process_memory`): a read of `/proc` on Linux, a system call on Windows.
- **A JavaScript garbage collection of the active page.** The engine has no collection that the browser can run on
  request.
- **A panel per tab or per page.** A tab's state is large and its page owns it. The panel shows the current tab only.
- **A history of the frame times in the panel.** The toolkit's View tab already plots them.
