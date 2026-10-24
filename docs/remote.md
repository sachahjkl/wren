# Remote control: `wren ctl`

Drive a running Wren from a script: navigate, wait, run script, send mouse and keyboard input, read the console and the
network log, and **capture the window without the screen**. The client is a sub-command of `wren.exe` itself (one file, so
client and server always speak the same protocol version).

```powershell
build\wren.exe ctl run --size 1280x800 --shot out.png https://example.com/     # one call: start, load, capture, close
```

About 0.5 s for the whole call on a development build (process start 55 ms, first frame and load 215 ms, capture 70 ms,
close 110 ms), against 2 to 3 s for starting Wren, waiting a fixed time and capturing the screen. No window is shown, no
`desktop.lock` is needed, and the monitor, its scale and the windows above do not matter.

## Seeing what Wren does without launching it forty times

| You want | Do |
|---|---|
| a picture of a page | `wren ctl run --shot out.png <url>` (`--size WxH`, `--dpi 144`, `--wait idle`) |
| several things on one page | `wren ctl start`, then `nav`, `shot`, `eval`, `click`... with `WREN_REMOTE=<name>`, then `wren ctl stop <name>` |
| the same from PowerShell | `. tools\wrenctl.ps1; Start-Wren; Wren-Nav $u; Wren-Shot a.png; Wren-Eval 'document.title'; Stop-Wren` |
| an existing script (screenshot.ps1) | add `-Remote` (or set `WREN_SHOT_REMOTE=1`): same call, no screen, no lock |
| to compare two builds | `wren ctl snapshot out\a` with each build (`.png`, `.html`, `.json` of boxes), then `wren ctl diff a.png b.png --out d.png` |
| to know what a window shows | `wren ctl shot` of the page (`--tab`), a rectangle (`--rect x,y,w,h`) or an element (`--selector css`) |
| a Wren the user (or another agent) already runs | do not touch it: start your own (`run` / `start` use a throwaway profile and a name of their own) |
| many scenarios, one after the other (tests) | one `start`, then `wren ctl reset` between two scenarios (see "Reusing one Wren" below): a start and a close are 0.6 s and the CPU of a start-up that has to settle |

`wren ctl help` lists the commands, `wren ctl help <command>` gives one's usage. `wren ctl cmds` lists the browser's commands
(the registry that the menu, the palette and the shortcuts use) and `wren ctl cmd <name>` runs one: everything the user can
trigger in the interface (open the developer tools, change the dock, zoom, Setup, a new tab...) can be triggered the same way.

### Commands

```
run [--profile dir] [--size WxH] [--dpi n] [--wait load|idle|stable|none] [--eval js] [--shot file [--tab|--rect x,y,w,h|--selector css] [--scale n]] [--visible] [--timing] [--pref n=v] [url]
start [--name n] [--profile dir] [--size WxH] [--dpi n] [--visible] [url]      stop <name>
nav <url> [--wait load|idle|stable|none]     reload   back   forward   cancel
shot <file.png> [--tab|--window|--rect x,y,w,h|--selector css] [--scale n] [--settle frames] [--count n [--interval ms]]
eval <js> [--await]                          click x,y | --selector css [--right] [--double] [--window]
drag x,y x2,y2 [--steps n]                   scroll <notches> [x,y]     type <text>     key <combo>... [--repeat n]
wait load|idle|stable|quiet | selector <css> [--visible] | function <js> | frames [n]   [--timeout ms] [--idle-ms ms] [--quiet-ms ms] [--max-cpu ms]
console [--clear] [--since n]   network [--clear]   stats   tabs   tab new|activate|close
pref get <n> | set <n> <v> [--override] | reset <n> | reset --all | list [prefix]
reset [--keep tabs,data,prefs,window,history] [--url address] [--wait ...]
checkpoint save|restore|delete <name> | list
window [--size WxH] [--pos x,y] [--state normal|minimized|maximized|fullscreen]    cmds [filter]   cmd <name>
devtools [console|elements|network|none] [--dock ...]   setup   html [sel]   query sel   box sel   style sel [props]
snapshot <prefix>   record start|stop <file>   replay <file> [--speed n]   diff a.png b.png [--tolerance n] [--out d.png] [--max-percent p]
quit [--code n]     raw '<json request>'     ping     version
```

Options of every command: `--remote <name>` (or `WREN_REMOTE`), `--profile <dir>` (finds the Wren by its profile folder),
`--timeout <ms>`, `--tab-id <id>`, `--json` (the raw answer), `--quiet`. Exit codes: **0** done, **1** failed (an error
answer, a script exception), **2** timed out, **3** no Wren answers or the connection ended, **4** wrong usage.

`ctl` is a command **only as the first argument**. To open a file or a host named ctl, write `./ctl`.

### Reusing one Wren: `reset`, `checkpoint`, `wait quiet`

A Wren that is started for every scenario costs its start (about 0.3 s to a first frame), its close (0.3 s), and the CPU of a
start-up that must settle before anything at rest can be measured. A script that drives many scenarios starts one and puts it back
between them:

```powershell
. tools\wrenctl.ps1
Start-Wren -Size 1000x700            # the window it has now is the one `reset` returns to
Wren-Nav $a; ...; Wren-Ctl reset     # scenario 1, then a clean Wren
Wren-Nav $b; ...; Wren-Ctl reset     # scenario 2
Stop-Wren
```

`reset [--keep tabs,data,prefs,window,history] [--url address] [--wait load|idle|stable|quiet|none]` (about 60 ms)

| It does | Unless `--keep` names |
|---|---|
| ends the commands other clients are waiting on, with the error "cancelled by a reset" | |
| closes developer tools (docked or in their window), the search bar, the command palette, the element picker, full screen, downloads in progress; stops a recording | |
| leaves one blank tab (or `--url`): every other tab closes, with its zoom, scroll, history, console and network log | `tabs` |
| empties cookies, localStorage, sessionStorage, IndexedDB, the HTTP cache, HSTS and the CORS preflight cache | `data` |
| empties the browsing history (about:history) and the list of closed tabs | `history` |
| puts every preference back as it was when the Wren started (the user layer, the command line layer, the defaults; policy is never touched) | `prefs` |
| puts the window back (size, place, state) as it was when `start` / `run` had set `--size` | `window` |

It prints what was removed (`--json`: `cancelledOps`, `closedTabs`, `cookies`, `sites`, `cacheEntries`, `historyVisits`,
`prefsRestored`, `windowRestored`, `tabId`) and answers once the blank tab has loaded. `stats` shows the same counts (`cookies`,
`storageSites`, `cacheEntries`, `historyVisits`, `closedTabs`, `devtools`...), which is how a test sees that a reset worked.
`checkpoint save initial` makes the present window the one `reset` returns to (the preferences are those of the start of the run).
Not reset: the blocker's per-site settings, the favicon cache, the files a download already wrote, anything a page left on the
disk outside the profile.

`checkpoint save <name>` keeps the preferences, the window, the tabs (address, zoom, which is current), the cookies (session ones
too) and the localStorage of every origin, in memory (at most `browser.remote.max_checkpoints`); `checkpoint restore <name>` closes
the tabs, puts all that back, opens the tabs again and waits for the current one to load. IndexedDB, the HTTP cache and
sessionStorage are not part of a checkpoint (a restore empties them); a restored tab loads its address again, so what a page kept
only in memory is not back. `checkpoint list`, `checkpoint delete <name>`.

`pref set` refuses a value that `--pref` fixed when the Wren started ("set by policy or on the command line for this run"):
`--override` changes that layer too. `pref reset <name>` (or `--all`) puts a preference back as it was at the start.

`wait quiet` waits for the **process** to be at rest, which a script cannot see without sampling its CPU for seconds: nothing
loading in any tab, and at most `browser.remote.quiet_cpu_ms` (20) of CPU time, all threads, during `browser.remote.quiet_ms`
(400); `--quiet-ms` and `--max-cpu` for one call. It answers with how long it waited and the CPU it saw. (`wait idle` is about
the network of a page; `--idle-ms n` shortens or lengthens its quiet time for one call.) To measure an idle process, read `stats`
twice: `cpuTimeMs` is the process's CPU time (the system adds it up in ticks of about 15.6 ms); `threads`, `handles`,
`gdiObjects`, `userObjects`, `uptimeMs` and `pid` are there too.

`shot <file> --count n [--interval ms]` takes n pictures over the one connection (a `%d` in the name takes the number, else
`-<n>` goes before the extension) instead of a process, and its 100 ms of start, for each.

## Starting a Wren that listens

The channel is **off by default**; a Wren that was not asked for it has no pipe, no thread and no timer.

- `wren --remote` or `wren --remote=<name>`, or `WREN_REMOTE=<name>` in the environment, or the preference
  `browser.remote.enabled` (about:config, applied at the next start).
- `wren ctl run` and `wren ctl start` start a Wren of this same executable with `--remote=<name> --headless --no-single-instance`
  and a throwaway profile (removed afterwards; a profile given by `--profile` is never removed). A throwaway profile starts with
  `blocker.update.enabled=false` (a Wren that lives 15 s would download the content blocker's lists, 24 MB, from the internet),
  unless `--pref blocker.update.enabled=...` says otherwise.
- `--headless`: the window is never shown. It renders all the same (the capture reads the renderer's frame).
- A driven Wren never hands its addresses to the user's running Wren (`--remote` implies `--no-single-instance`).
- A status bar item "remote" shows that the channel listens (`browser.remote.indicator`).

The pipe is `\\.\pipe\wren-remote-<name>`. The name is given, or `p` + a hash of the profile folder, so the same folder always
gives the same name and two instances with different profiles never meet. `<profile>\remote.json` has the name, the pipe, the
pid and the protocol version; a client does not need it (`wren ctl ping` answers with the pid).

## The traps

**A program without a console window.** `wren.exe` is a Windows GUI program. Started from cmd or PowerShell the plain way, it
gives the prompt back at once: a script sees neither its end nor its exit code, and a redirection needs care. `wren ctl` writes to
the standard handles when the caller redirected them (a file or a pipe: never around the redirection), else to the console of the
parent process. Reliable forms for scripts:

```powershell
# the long way
Start-Process -Wait -NoNewWindow -FilePath build\wren.exe -ArgumentList 'ctl','shot','out.png' -RedirectStandardOutput out.txt
# or, which also returns the exit code and is 80 ms quicker (System.Diagnostics.Process): tools\wrenctl.ps1
. tools\wrenctl.ps1
$text = Wren-Ctl shot out.png ; $WrenExit ; $WrenErr
```

Typed in a terminal, `build\wren.exe ctl ping` works too (the output appears after the prompt returns, the exit code is not
available). A console launcher (`wren.com` beside `wren.exe`, which waits for `ctl` and hands its own standard handles over) is a
later addition: nothing in `wren ctl` will change for it.

**Relative paths** are the caller's: `wren ctl` resolves them against its own current folder. In PowerShell, `Set-Location` does not
change the process's folder: the wrapper (`Resolve-PathHere`) resolves against the PowerShell location; with a raw call give
absolute paths.

**Sizes.** A capture is in the renderer's pixels: `window` is the client area, which `window --size WxH` (and `run --size`) sets in
pixels; the page area, a rectangle or an element are parts of it. The interface scale follows the display (`--dpi 144` sets
`browser.ui.scale=1.5` for that run). `shot --scale 0.5` averages, `--scale 2` repeats pixels.

**Settling.** A capture is taken after `browser.remote.settle_frames` frames (2) so that hover, focus and transitions started by the
previous command are in it; `--settle n` changes that for one call. For a page that loads things, `nav` waits for the load, then
`wait idle` (network quiet for `browser.remote.idle_ms`) or `wait stable` (idle, no frame wanted, every image in).

**One capture at a time** per window; others queue. A minimized window is restored without taking the focus for the capture and
minimized again. The wgpu render backend cannot read its frame back: `shot` answers an error there.

**Elements** are found with the document's own selector engine, with no script engine involved (a Wasm-only page works); `eval`,
`style` and the `readyState` check need the page's JavaScript.

## Security

- The pipe's DACL has one entry: the current user's SID. Other users, other machines (`PIPE_REJECT_REMOTE_CLIENTS`) and sandboxed
  processes cannot open it. The first instance is created with `FILE_FLAG_FIRST_PIPE_INSTANCE`: a name taken by another process is an
  error reported on stderr, in the console of the first tab and by a notice, not a second server.
- A page cannot reach the channel: it has no way to open a pipe or to send a line. The results of scripts that the channel runs come
  back through the page's console on a line that starts with a secret prefix made at each start (`BCryptGenRandom`), taken before the
  tab's console sees it; a page that knows nothing of the prefix cannot make one up.
- A request line longer than `browser.remote.max_message_bytes` (8 MiB) is answered with an error and the connection is closed. At
  most `browser.remote.max_clients` (8) are served at once.
- Everything a client does is what the user could do in the window; there is no way into the file system but the paths a client
  gives to `shot` / `snapshot` (written with the user's rights).

## Protocol

One JSON object per line (UTF-8, `\n`), over the pipe.

```
→ {"id": 1, "method": "Page.navigate", "params": {"url": "https://example.com/", "wait": "load"}}
← {"id": 1, "result": {"tabId": 1, "url": "https://example.com/"}}
← {"id": 2, "error": {"code": -32001, "message": "timed out waiting for load"}}
← {"event": "Page.loadEventFired", "params": {"tabId": 1, "url": "..."}}      (after Remote.subscribe)
```

`id` is any JSON number or string, given back as it came. Answers of different requests may come in another order (a wait
answers when its condition holds). Codes: -32700 parse error, -32600 invalid request, -32601 unknown method, -32602 invalid
parameters, -32000 the command failed, -32001 a wait timed out.

**Commands run on the interface thread, between frames.** The server's threads only read and write the pipe (overlapped I/O,
blocked in the kernel) and wake the event loop with `host.post`: nothing runs while no client sends anything. Waits are looked at
after each frame and by one timer that exists only while a wait or a capture needs looking at.

**Names follow the Chrome DevTools Protocol** where Wren has the same thing, so that an adapter that speaks CDP or WebDriver BiDi to a
test framework can be put in front of this channel later without redrawing it (it translates; it does not add a second control
path). The rest is in the `Wren.` domain.

| Method | Parameters → result |
|---|---|
| `Remote.ping` | → `{protocol, version, pid}` |
| `Remote.subscribe` / `unsubscribe` | events `Page.loadEventFired {tabId, url}`, `Runtime.consoleAPICalled {tabId, type, text}` |
| `Browser.getVersion` | → product, revision, toolkit, protocol |
| `Browser.close` | `{exitCode, fast}` (fast: end at once, no teardown: for a throwaway profile) |
| `Browser.getWindowBounds` / `setWindowBounds` | `{left, top, width, height, windowState}`: width and height are the client area in pixels; state normal, minimized, maximized, fullscreen |
| `Target.getTargets` / `createTarget {url, wait, background}` / `activateTarget {targetId}` / `closeTarget {targetId}` | tabs |
| `Page.navigate {url, wait, tabId, timeout}` | wait: none, load, idle, stable |
| `Page.reload {ignoreCache, wait}` / `goBack` / `goForward` / `stopLoading` | |
| `Page.captureScreenshot {path, bytes, target, selector, clip, scale, settle}` | target window, page, rect (clip x,y,width,height in window pixels) or selector; → `{path, width, height, size, data?}` (PNG; `data` is base64 when `bytes` or no path) |
| `Runtime.evaluate {expression, awaitPromise, tabId}` | → `{result: {type, value}}`, or `exceptionDetails` with the stack |
| `DOM.getOuterHTML {selector}` / `querySelectorAll {selector, limit}` / `getBoxModel {selector}` | no script engine needed |
| `CSS.getComputedStyleForNode {selector, properties}` | needs the page's JavaScript |
| `Input.dispatchMouseEvent {type, x, y, button, modifiers, deltaX, deltaY, notches, space}` | type mouseMoved, mousePressed, mouseReleased, mouseWheel; x and y in page CSS pixels, `"space":"window"` for window pixels |
| `Input.dispatchKeyEvent {type, key, text, modifiers}` / `Input.insertText {text}` | through the same events as a real keyboard |
| `Wren.wait {for, selector, expression, visible, frames, timeout, idleMs, quietMs, maxCpuMs}` | for: load, idle, stable, quiet, selector, function, frames; `quiet` answers `{waitedMs, cpuMs}` |
| `Wren.click {x, y \| selector, button, count}` | an element is scrolled into view, then clicked in the middle |
| `Wren.drag`, `Wren.type {text}`, `Wren.key {keys, repeat}` | |
| `Wren.stats`, `Wren.console {since, clear}`, `Wren.network {clear}` | the status bar's numbers and the process's (pid, uptimeMs, cpuTimeMs, threads, handles...); the tab's console and request logs |
| `Wren.getPref {name}` / `setPref {name, value, override}` / `resetPref {name \| all}` / `listPrefs {prefix}` | about:config |
| `Wren.reset {keep, url, wait}` / `Wren.checkpoint {action: save\|restore\|list\|delete, name, wait}` | put the running Wren back to a clean or a saved state (see above) |
| `Wren.listCommands` / `runCommand {name}` / `openDevTools {panel, dock}` / `openSetup` | the command registry |
| `Wren.snapshot {path}` | `<path>.png`, `.html`, `.json` (url, size, the box of every element) |
| `Wren.recordInput {action}` / `replayInput {events, speed}` | macros of the input a window receives (real or sent), with times |

Input events are queued with `platform.inject_event` (toolkit 0.22.0) and read by the next `poll_events`: hover, focus,
shortcuts, text input and the page's DOM events behave as for a real device. A command that sends input answers after the frames
that carry it have been drawn.

### Capture

The toolkit's `render.capture_request(r, rect)` marks the next frame; `frame_end` copies that frame's render target (or a part of
it) into a staging texture just before the present, and `render.capture_poll` maps it once the GPU is done, with
`D3D11_MAP_FLAG_DO_NOT_WAIT` (never a stall; a timer looks again every `browser.remote.poll_ms`). The copy costs one GPU command
in that one frame. It works with the window covered, off the screen, hidden or minimized, and does not depend on the monitor's DPI.

## Preferences

`browser.remote.enabled`, `.name`, `.max_message_bytes`, `.max_clients`, `.indicator`, `.timeout_ms` (30 s, waits),
`.settle_frames` (2), `.poll_ms` (4), `.idle_ms` (400), `.quiet_ms` (400), `.quiet_cpu_ms` (20), `.max_checkpoints` (16).

## Tests

`tools\remote_e2e.ps1` (also a step of `test_all`; it prints the seconds of each of its sections at the end): off by default and idle at no cost, a driven session with pixel checks, window
off the screen and minimized, vanishing and oversized clients, the pipe's ACL, two instances, a taken name, quit with a client
connected, and on that same Wren, one after the other with a `reset` between: the reset itself (everything it names is back, a page sees no cookie or storage), the checkpoints, the video planes, the layout read after a navigation; `-Check` runs a session on the check build (`wren_check.exe`) that must exit with nothing allocated. Unit tests:
`src/remote` (protocol; the server against raw pipe clients), `src/remote/client`, `src/browser/remote_test.odin`.
`tools\remote_e2e.ps1 -Stress -1` saturates every logical processor with busy loops and checks that `wren ctl quit` (with a client connected) and a `WM_CLOSE` to the window, each with a video playing, end within 8 s without the watchdog forcing the exit; `test_all` runs it last and alone. With 16 busy loops on 16 processors the close went from a median of 8.8 s (p95 40 s, nine of sixteen over 8 s) to 0.75 s (p95 under 1 s in 80 closings, longest 5.9 s). What was waiting: threads of lower priority that the teardown joins (the disk cache, the image decoders, the Wasm compile threads), every hand-over of the teardown behind other programs' busy loops (the process now runs above normal priority while it closes), a compile in flight (no longer waited for), and the compositor releasing the swap chain (`browser.shell.shutdown_surface_wait_ms`). `shutdown.log` in the profile names the slowest steps of a close that took a second or more.
`tools\remote_bench.ps1` measures "load a page, wait, capture" the old way and the new way.
