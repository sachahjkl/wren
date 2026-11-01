package e2e

// A Wren of its own, in another process, for what is about a process: a launch, an exit code, a crash, a second start, the console
// launcher. Everything else runs in the test's process (e2e.odin). It is driven over the channel, with the typed API of wb:remote/api
// (api.navigate(p.s, url), api.eval(p.s, js)...): a failed call ends the test there, as in this package, and what comes back of the
// process is its exit code.
//
//   p := e2e.launch(t, {prefs = {"browser.tabs.position=left"}})
//   api.navigate(p.s, url)
//   code := e2e.quit(p)
//
// By default it has no window of the system either (--headless); `window = .Hidden` makes one and never shows it, for the few things
// that need a handle. It ends with the test, however the test ends, and a throwaway profile goes with it.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:remote/api"

Process_Options :: struct {

	hidden:     bool,               // a window that exists and is never shown (needs a desktop session: test_all's own)
	profile:    string,             // "": a throwaway one
	dpi:        f64,
	prefs:      []string,
	extra:      []string,           // more arguments of the command line
	no_address: bool,
}

Wren_Process :: struct {
	t:     ^testing.T,
	s:     ^api.Session,
	wren:  api.Launched,
	ended: bool,
	code:  int,
}

// The program a launch starts.
wren_exe :: proc() -> string { return fmt.tprintf("%s/build/wren%s", repo_root(), ODIN_OS == .Windows ? ".exe" : "") }

// A Wren in a process of its own, its channel open.
launch :: proc(t: ^testing.T, o := Process_Options{}, loc := #caller_location) -> ^Wren_Process {
	testing.set_fail_timeout(t, TEST_LIMIT, loc)
	p := new(Wren_Process)
	p.t = t
	s := new(api.Session)
	p.s = s
	s.user = p
	s.on_failure = proc(s: ^api.Session, e: api.Error, what: string, loc: runtime.Source_Code_Location) {
		p := (^Wren_Process)(s.user)
		f := api.last_failure()
		stop_test(p.t, fmt.tprintf("%s: %v: %s", what, e, f.message), loc)
	}
	testing.cleanup(t, proc(ptr: rawptr) {
		p := (^Wren_Process)(ptr)
		if !p.ended { p.s.on_failure = nil; api.finish(p.s, &p.wren, true) }
		delete(p.wren.name)
		delete(p.wren.profile)
		free(p.s)
		free(p)
	}, p)
	l, err := api.launch({exe = wren_exe(), window = o.hidden ? .Hidden : .Headless, profile = o.profile, dpi = o.dpi, prefs = o.prefs, extra = o.extra, no_address = o.no_address}, context.allocator)
	p.wren = l
	if err != "" { stop_test(t, strings.concatenate({"the program could not start: ", err}, context.temp_allocator), loc) }
	if api.connect_launched(s, &p.wren, api.START_WAIT_MS) != .None { stop_test(t, api.last_failure().message, loc) }
	return p
}

// The Wren is told to close, with this exit code, and has ended: the process's exit code. (A test that ends without this: the same, at its end.)
quit :: proc(p: ^Wren_Process, exit_code := 0, loc := #caller_location) -> int {
	if p.ended { return p.code }
	p.s.on_failure = nil
	code, forced := api.finish(p.s, &p.wren, true)
	p.ended, p.code = true, code
	if forced { stop_test(p.t, "the Wren did not close in time: it was ended", loc) }
	return code
}

