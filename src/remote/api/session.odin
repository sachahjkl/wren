// Package api: controlling a Wren from an Odin program, typed. `wren ctl` (src/remote/client) is a layer over it that parses
// arguments and prints; the end-to-end tests (src/tools/e2e, through src/e2e) call it directly. Nothing here knows about a
// command line, and what uses it knows nothing of method names or JSON.
//
//   s: api.Session
//   l, err := api.launch({exe = path, window = .Headless})
//   api.connect_launched(&s, &l, api.START_WAIT_MS)
//   api.navigate(&s, "http://example.test/")
//   title, e := api.eval(&s, "document.title")
//   api.finish(&s, &l, true)
//
// The transport is the system's channel to a Wren of another process (conn*.odin): a launch, a crash and an exit code are part
// of what is controlled. What a call returns lives in the thread's temporary memory. A call that fails returns its Error and
// says why in last_failure().
package api

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:remote"

// How long a Wren may take to open its channel (ms), to answer the request to close, to close (and then, ended by force, to be gone).
START_WAIT_MS :: 30_000
CLOSE_ANSWER_MS :: 5000
CLOSE_WAIT_MS :: 15_000
KILL_WAIT_MS :: 5000
// One try of the connection while a Wren starts (ms): how soon its end is noticed.
CONNECT_TRY_MS :: 100
// What a call may wait with no limit of its own (ms), and what is added to a limit, for the server's own timeout error to come first.
CALL_WAIT_MS :: 60_000
CALL_MARGIN_MS :: 5000

// 96 dots per inch: a scale of 1.
DPI_ONE :: 96.0

// Who a process is, for telling it again later: when it was created (Windows: FILETIME; Linux: its start after boot, in
// clock ticks) and the program it runs (full path).
Identity :: struct {
	created: u64,
	image:   string,
}

// The window of a Wren that is started. Headless has no window of the system at all and renders all the same (a real render, on
// an offscreen target that captures read); Hidden makes a window and never shows it (what needs a handle: UI Automation, the
// system's hit test); Visible is for a person.
Window_Mode :: enum u8 { Hidden, Headless, Visible }

Launch_Options :: struct {
	exe:        string,        // the program (wren.exe)
	name:       string,        // of the channel ("": a unique one)
	profile:    string,        // "": a folder made for this Wren, removed by finish
	window:     Window_Mode,
	dpi:        f64,           // 0: the system's (96 = 100 %)
	prefs:      []string,      // "name=value", as the command line's --pref (they stay above what is set later)
	extra:      []string,      // more arguments of the command line
	no_address: bool,          // no address on the command line (a session is restored only then)
}

Launched :: struct {
	process: Process,
	pid:     int,
	name:    string,
	profile: string,
	temp:    bool,   // the profile folder is ours (made for this run): removed at the end
}

// A connection to a Wren, and what its calls are about.
Session :: struct {
	conn:            Conn,
	connected:       bool,
	name:            string,   // the channel a first call connects to
	connect_wait_ms: int,
	window:          int,      // the window calls are about (0: the front one): `in_window` for a stretch of calls
	tab:             int,      // the tab calls that take one are about (0: the window's current one)
	timeout_ms:      int,      // the limit given to every call without one of its own (0: the server's default)
	idle_ms:         int,      // how long the network must stay quiet for a wait for idle (0: browser.remote.idle_ms)
	result:          string,   // the answer of the last call, as the server wrote it (JSON: what `wren ctl --json` prints)
	// A call has failed (its Error is returned as well; why: last_failure): nil, nothing more happens, `wren ctl` prints it and
	// exits with its code. A test has this end it there, with who called (src/e2e), so that a scenario checks no return.
	on_failure:      proc(s: ^Session, e: Error, what: string, loc: runtime.Source_Code_Location),
	user:            rawptr,   // on_failure's
}

// The folder of what a Wren's client keeps: the session files of `wren ctl start`, the throwaway profiles.
state_dir :: proc() -> string {
	tmp := base.temp_dir(context.temp_allocator)
	if tmp == "" { tmp = "." }
	return strings.concatenate({tmp, filepath.SEPARATOR_STRING, "wren-ctl"}, context.temp_allocator)
}

// Starts a Wren with a remote channel. err "": started. The strings of the result are in `allocator`.
launch :: proc(o: Launch_Options, allocator := context.temp_allocator) -> (l: Launched, err: string) {
	name := o.name != "" ? o.name : fmt.tprintf("s%s", base.unique_name(context.temp_allocator))
	profile := o.profile
	if profile == "" {
		profile = strings.concatenate({state_dir(), filepath.SEPARATOR_STRING, "profile-", name}, context.temp_allocator)
		l.temp = true
	}
	l.name = strings.clone(name, allocator)
	l.profile = strings.clone(profile, allocator)
	_ = os.make_directory_all(profile)
	args := make([dynamic]string, context.temp_allocator)
	append(&args, o.exe, "--profile", profile, fmt.tprintf("--remote=%s", name), "--no-single-instance")
	switch o.window {
	case .Headless: append(&args, "--headless")
	case .Hidden:   append(&args, "--hidden")
	case .Visible:
	}
	if o.dpi > 0 { append(&args, "--pref", fmt.tprintf("browser.ui.scale=%.4f", o.dpi / DPI_ONE)) }
	// a Wren of a throwaway profile is for automation: it does not download the content blocker's lists (24 MB from the
	// internet, 15 s after the start, a few seconds of CPU that a measure of an idle Wren takes for its own); a --pref given may turn it on
	if l.temp { append(&args, "--pref", "blocker.update.enabled=false", "--pref", "blocker.welcome_toast=false") }
	for p in o.prefs { append(&args, "--pref", p) }
	for e in o.extra { append(&args, e) }
	if !o.no_address { append(&args, "about:blank") }
	p, pid, started := process_start(args[:])
	if started != "" { return l, started }
	l.process, l.pid = p, pid
	return l, ""
}

// Connects to a Wren we started, giving up when it has ended or after `wait_ms`. Says why in last_failure.
connect_launched :: proc(s: ^Session, l: ^Launched, wait_ms: int) -> Error {
	s.name = l.name
	deadline := time.tick_add(time.tick_now(), time.Duration(wait_ms) * time.Millisecond)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if connect(&s.conn, l.name, CONNECT_TRY_MS) { s.connected = true; return .None }
		if !process_alive(&l.process) {
			set_failure("Wren ended before it was ready")
			return .No_Server
		}
	}
	set_failure(fmt.tprintf("Wren did not open %s in %d ms", remote.pipe_path(l.name), wait_ms))
	return .No_Server
}

// Ends a Wren we started: asks it to close, waits, and as a last resort ends this very process (the one we hold); removes
// a profile that was made for it. `forced`: it had to be ended; `exit_code`: what it ended with (-1: not known).
finish :: proc(s: ^Session, l: ^Launched, ask: bool) -> (exit_code: int, forced: bool) {
	if ask && s.connected { _ = browser_close(s, 0, l.temp) }
	if s.connected { disconnect(&s.conn); s.connected = false }
	if !process_wait(&l.process, CLOSE_WAIT_MS) {
		process_kill(&l.process)
		process_wait(&l.process, KILL_WAIT_MS)
		forced = true
	}
	exit_code = process_exit_code(&l.process)
	process_release(&l.process)
	// (only a folder of state_dir: what a caller named is never removed)
	if l.temp && strings.contains(l.profile, "wren-ctl") { base.remove_tree(l.profile) }
	return
}

// Closes the connection. A Wren ended by `quit`, or that goes on, stays as it is.
close_session :: proc(s: ^Session) {
	if s.connected { disconnect(&s.conn); s.connected = false }
}

// For a stretch of calls about one window: `api.in_window(s, id)` until the end of the scope.
@(deferred_out = window_restore)
in_window :: proc(s: ^Session, id: int) -> (^Session, int) {
	was := s.window
	s.window = id
	return s, was
}

@(private)
window_restore :: proc(s: ^Session, was: int) { s.window = was }
