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
		"Starts a Wren in the background and prints its name; later commands reach it with --remote <name> or WREN_REMOTE=<name>. End it with `stop`."},
	{"stop", "stop <name>", "Closes a Wren started by `start` (and ends that process only if it does not close). Removes its throwaway profile."},
	{"nav", "nav <url> [--wait load|idle|stable|none] [--tab-id id]", "Navigates the current tab and waits (load by default). Prints the address."},
	{"reload", "reload [--wait ...]", "Reloads the current tab."},
	{"back", "back [--wait ...]", "History: back."},
	{"forward", "forward [--wait ...]", "History: forward."},
	{"cancel", "cancel", "Stops the load in progress."},
	{"shot", "shot <file.png> [--tab|--window|--rect x,y,w,h|--selector css] [--scale n] [--settle frames]",
		"Captures the window (default), the page area (--tab), a window rectangle or an element, as a PNG file. Read from the renderer's frame, not from the screen: it works with the window covered, hidden or off the screen, and does not depend on the monitor. Prints the path and the size."},
	{"eval", "eval <javascript> [--await]", "Runs script in the page and prints the value (a string as it is, anything else as JSON). A script error goes to stderr, exit code 1. --await waits for a promise."},
	{"click", "click x,y | click --selector css [--right] [--double] [--window]", "A click as a mouse would make it. x,y are page pixels (CSS pixels from the page's corner; --window: window pixels). With --selector the element is scrolled into view and clicked in the middle."},
	{"drag", "drag x,y x2,y2 [--steps n] [--window]", "Press, move in steps, release."},
	{"scroll", "scroll <notches> [x,y]", "The mouse wheel (positive: down)."},
	{"type", "type <text>", "Types text as the keyboard would (into the focused field or control)."},
	{"key", "key <combo>... [--repeat n]", "Keys: Enter, Escape, Tab, F5, ArrowLeft, a, Ctrl+L, Ctrl+Shift+T. Several combos separated by spaces go one after another."},
	{"wait", "wait load|idle|stable | wait selector <css> [--visible] | wait function <js> | wait frames [n]  [--timeout ms]",
		"Waits for the page to load, the network to be quiet (idle), the picture to stop changing (stable), an element, a script condition (true), or n frames. Exit code 2 on timeout."},
	{"console", "console [--clear] [--since n]", "The console of the current tab (page messages and errors)."},
	{"network", "network [--clear]", "The requests of the current document: status, method, type, size, time, address."},
	{"stats", "stats", "Frames per second, CPU and GPU time of a frame, memory, requests in flight (the status bar's numbers)."},
	{"pref", "pref get <name> | pref set <name> <value> | pref list [prefix]", "Reads and writes preferences (about:config)."},
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
