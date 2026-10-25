package client

import "core:fmt"
import "core:strings"

Help_Entry :: struct {
	name:  string,
	usage: string,
	text:  string,
}

HELP := [?]Help_Entry{
	{"run", "run [--profile dir] [--size WxH] [--dpi n] [--wait load|idle|stable|none] [--eval js] [--shot file.png [--tab|--rect x,y,w,h|--selector css] [--scale n]] [--visible] [--timing] [--pref name=value] [url]",
		"One call for most needs: starts a Wren of its own (a throwaway profile unless --profile; no window shown unless --visible), loads the address, waits, runs the script, captures, closes it and gives the exit code. --size is the window's client area in pixels, --dpi the interface scale (96 = 100 %, 175 = 182 %)."},
	{"start", "start [--name n] [--profile dir] [--size WxH] [--dpi n] [--visible] [url]",
		"Starts a Wren in the background (with a throwaway profile unless --profile, which does not download the blocker's lists: --pref blocker.update.enabled=true turns that on) and prints its name; later commands reach it with --remote <name> or WREN_REMOTE=<name>. End it with `stop`."},
	{"stop", "stop <name>", "Closes a Wren started by `start` (and ends that process only if it does not close). Removes its throwaway profile."},
	{"nav", "nav <url> [--wait load|idle|stable|none] [--tab-id id]", "Navigates the current tab and waits (load by default). Prints the address."},
	{"reload", "reload [--wait ...]", "Reloads the current tab."},
	{"back", "back [--wait ...]", "History: back."},
	{"forward", "forward [--wait ...]", "History: forward."},
	{"cancel", "cancel", "Stops the load in progress."},
	{"shot", "shot <file.png> [--tab|--window|--rect x,y,w,h|--selector css] [--scale n] [--settle frames] [--count n [--interval ms]]",
		"Captures the window (default), the page area (--tab), a window rectangle or an element, as a PNG file. Read from the renderer's frame, not from the screen: it works with the window covered, hidden or off the screen, and does not depend on the monitor. Prints the path and the size. With --count n it takes n pictures in a row over this one connection (--interval ms between them) and numbers the files: a %d in the name takes the number, else -<n> goes before the extension."},
	{"eval", "eval <javascript> [--await]", "Runs script in the page and prints the value (a string as it is, anything else as JSON). A script error goes to stderr, exit code 1. --await waits for a promise."},
	{"click", "click x,y | click --selector css [--right] [--double] [--window]", "A click as a mouse would make it. x,y are page pixels (CSS pixels from the page's corner; --window: window pixels). With --selector the element is scrolled into view and clicked in the middle."},
	{"drag", "drag x,y x2,y2 [--steps n] [--window]", "Press, move in steps, release."},
	{"hover", "hover x,y [--window]", "Moves the pointer there (one synthetic move: hover states, tooltips, menus) without touching the real mouse."},
	{"scroll", "scroll <notches> [x,y]", "The mouse wheel (positive: down)."},
	{"type", "type <text>", "Types text as the keyboard would (into the focused field or control)."},
	{"key", "key <combo>... [--repeat n]", "Keys: Enter, Escape, Tab, F5, ArrowLeft, a, Ctrl+L, Ctrl+Shift+T. Several combos separated by spaces go one after another."},
	{"wait", "wait load|idle|stable|quiet | wait selector <css> [--visible] | wait function <js> | wait frames [n]  [--timeout ms] [--idle-ms ms] [--quiet-ms ms] [--max-cpu ms]",
		"Waits for the page to load, the network to be quiet (idle: --idle-ms, else browser.remote.idle_ms), the picture to stop changing (stable), an element, a script condition (true), or n frames. `wait quiet` waits for the whole process to be at rest: nothing loading in any tab, and at most --max-cpu ms (browser.remote.quiet_cpu_ms) of CPU time used by any thread during --quiet-ms (browser.remote.quiet_ms); it prints how long it waited and the CPU it saw. Exit code 2 on timeout."},
	{"console", "console [--clear] [--since n]", "The console of the current tab (page messages and errors)."},
	{"network", "network [--clear]", "The requests of the current document: status, method, type, size, time, address."},
	{"stats", "stats [--json] [--reset-latency]", "With WREN_LATENCY=1 (or browser.frame.latency_probe) the `latency` field: input -> screen p50 / p95 / max / mean per stage (waitMs, workMs, presentMs, scanMs, totalMs, totalRefreshes); --reset-latency starts a new measure after reading. Frames per second, CPU and GPU time of a frame, memory, requests in flight (the status bar's numbers), and the process: pid, uptimeMs, cpuTimeMs (all threads: read it twice to measure what happened between), threads, handles, GDI and USER objects; and what a reset empties: cookies, storageSites, cacheEntries, historyVisits, closedTabs, downloadsActive, checkpoints."},
	{"pref", "pref get <name> | pref set <name> <value> [--override] | pref reset <name> | pref reset --all | pref list [prefix]", "Reads and writes preferences (about:config). A value given with --pref when the Wren started cannot be changed by `set` (the command line decides for the run): --override takes that layer too. `reset` puts one preference (or --all) back to what it was when the Wren started."},
	{"reset", "reset [--keep tabs,data,prefs,window,history] [--url address] [--wait load|idle|stable|quiet|none]", "Puts the running Wren back to a clean state without starting it again: commands waiting end with an error, developer tools, search bar, palette, full screen and downloads close, every tab but one blank tab (or --url) closes (zoom, scroll, history of the tabs and console go with them), cookies, localStorage, sessionStorage, IndexedDB, the HTTP cache, HSTS, the CORS preflight cache, the browsing history and the closed tabs list are emptied, the preferences return to the ones the Wren started with and the window to the size it had when `start` or `run` set it. --keep leaves some of that alone. Prints what was removed."},
	{"checkpoint", "checkpoint save <name> | checkpoint restore <name> [--wait ...] | checkpoint delete <name> | checkpoint list", "Saves the state of the Wren under a name and goes back to it later: preferences, window, tabs (address and zoom), cookies (session ones too) and localStorage. A restore closes the tabs, puts all that back, opens the tabs again and waits for the current one to load. IndexedDB, the HTTP cache and sessionStorage are not saved: a restore empties them. `save initial` makes the present window the one a reset returns to."},
	{"tabs", "tabs", "Lists the tabs (id, * for the current one)."},
	{"tab", "tab new [url] | tab activate <id> | tab close <id>", "Opens, selects or closes a tab."},
	{"window", "window [--size WxH] [--pos x,y] [--state normal|minimized|maximized|fullscreen]", "Reads or changes the window (size is the client area in pixels)."},
	{"cmds", "cmds [filter]", "The browser's commands (the registry the menu, the palette and the shortcuts use), with their shortcuts."},
	{"cmd", "cmd <name>", "Runs any of those commands: tab.new, devtools.toggle, zoom.in... as the interface would."},
	{"devtools", "devtools [console|elements|network|none] [--dock bottom|right|floating]", "Opens the developer tools."},
	{"setup", "setup", "Opens the Setup dialog."},
	{"html", "html [selector]", "The document's (or an element's) outer HTML."},
	{"query", "query <selector> [--limit n]", "The elements a selector matches (count, markup, box)."},
	{"box", "box <selector>", "An element's box in page and window pixels."},
	{"style", "style <selector> [property...]", "An element's computed style (needs the page's script engine)."},
	{"snapshot", "snapshot <path-prefix> [--tab]", "One call for comparing two builds: <prefix>.png, <prefix>.html and <prefix>.json (url, size and the box of every element)."},
	{"record", "record start | record stop <file.json>", "Records the input the window receives (real or sent), with times."},
	{"replay", "replay <file.json> [--speed n]", "Plays a recording back through the same path as real input."},
	{"diff", "diff <a.png> <b.png> [--tolerance n] [--out diff.png] [--max-percent p]", "Compares two pictures: the share of pixels that differ and an image of the differences. Needs no Wren. Exit 0 when within --max-percent."},
	{"quit", "quit [--code n]", "Closes Wren cleanly and waits for it to end."},
	{"raw", `raw '{"method":"Page.navigate","params":{"url":"about:blank"}}'`, "Sends one request of the protocol and prints its answer (docs/remote.md lists the methods)."},
	{"ping", "ping", "Protocol version, program version and process id."},
	{"version", "version", "The browser's version."},
}

GLOBAL_HELP :: `Options of every command: --remote <name> (or WREN_REMOTE) names the Wren to drive; --profile <dir> finds it by its profile
folder (the default name is derived from it); --timeout <ms>; --tab-id <id>; --json prints the raw answer; --quiet.
Exit codes: 0 done, 1 failed, 2 timed out, 3 no Wren answers, 4 wrong usage.
A Wren listens only when started with --remote[=name] (or browser.remote.enabled): wren.exe --remote, or wren ctl start / run.
"ctl" is a command only as the first argument: to open a file or host named ctl, write ./ctl.`

help_main :: proc(args: []string) -> int {
	if len(args) > 0 {
		for e in HELP {
			if e.name == args[0] {
				outln(fmt.tprintf("wren ctl %s\n\n%s", e.usage, e.text))
				return 0
			}
		}
		errln(fmt.tprintf("wren ctl: no command %q (wren ctl help)", args[0]))
		return EXIT_USAGE
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "wren ctl <command> [options]: drives a running Wren (docs/remote.md)\n\n")
	for e in HELP { fmt.sbprintf(&b, "  %-9s %s\n", e.name, first_sentence(e.text)) }
	strings.write_string(&b, "\n")
	strings.write_string(&b, GLOBAL_HELP)
	strings.write_string(&b, "\n`wren ctl help <command>` gives a command's usage.\n")
	outln(strings.to_string(b))
	return 0
}

@(private)
first_sentence :: proc(s: string) -> string {
	if i := strings.index(s, ". "); i > 0 { return s[:i + 1] }
	return s
}
