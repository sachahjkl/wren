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
// By default it has no window of the system either (--headless); `hidden` makes one and never shows it, for the few things that need a
// handle. It ends with the test, however the test ends, and a throwaway profile goes with it.
//
// Any other program (a Wren with no channel, wren.com, what the test built) is a `program`: its outputs, its exit code. `run` starts one and
// waits for its end.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:remote/api"

// How often what another process does is looked at (nothing here can run its loop).
OTHER_PROCESS_POLL :: 5 * time.Millisecond

Process_Options :: struct {
	exe:             string,             // "": build/wren
	hidden:          bool,               // a window that exists and is never shown (needs a desktop session: test_all's own)
	profile:         string,             // "": a throwaway one
	own_profile:     bool,               // no --profile: it finds its own folder (APPDATA in `start.env`, a portable copy)
	single_instance: bool,               // it takes part in the hand-over of second starts (with WREN_SINGLE_INSTANCE=on in `start.env`)
	name:            string,             // of the channel ("": a unique one)
	dpi:             f64,
	prefs:           []string,
	extra:           []string,           // more arguments of the command line
	no_address:      bool,
	start:           api.Start_Options,  // its environment, its folder, its outputs
}

Wren_Process :: struct {
	t:     ^testing.T,
	s:     ^api.Session,
	wren:  api.Launched,
	ended: bool,
	code:  int,
}

// The program a launch starts.
wren_exe :: proc() -> string { return build_path("wren", ".exe") }

// A program of the build folder.
build_path :: proc(name: string, extension := "") -> string { return fmt.tprintf("%s/build/%s%s", repo_root(), name, ODIN_OS == .Windows ? extension : "") }

// A Wren in a process of its own, its channel open.
launch :: proc(t: ^testing.T, o := Process_Options{}, loc := #caller_location) -> ^Wren_Process {
	p := launch_begin(t, o, loc)
	if api.connect_launched(p.s, &p.wren, api.START_WAIT_MS) != .None { stop_test(t, api.last_failure().message, loc) }
	return p
}

// The same, not waited for: `connect` is the barrier, or what it does instead (a name taken, a hand-over: it ends).
launch_begin :: proc(t: ^testing.T, o := Process_Options{}, loc := #caller_location) -> ^Wren_Process {
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
	exe := o.exe != "" ? o.exe : wren_exe()
	// (nothing of the internet's in a test: the content blocker's lists stay where they are)
	prefs := make([dynamic]string, context.temp_allocator)
	append(&prefs, "blocker.update.enabled=false", "blocker.welcome_toast=false")
	append(&prefs, ..o.prefs)
	l, err := api.launch({exe = exe, name = o.name, window = o.hidden ? .Hidden : .Headless, profile = o.profile, own_profile = o.own_profile, single_instance = o.single_instance, dpi = o.dpi, prefs = prefs[:], extra = o.extra, no_address = o.no_address, start = o.start}, context.allocator)
	p.wren = l
	if err != "" { stop_test(t, strings.concatenate({"the program could not start: ", err}, context.temp_allocator), loc) }
	return p
}

// The Wren is told to close, with this exit code, and has ended: the process's exit code. (A test that ends without this: the same, at its end.)
quit :: proc(p: ^Wren_Process, exit_code := 0, loc := #caller_location) -> int {
	if p.ended { return p.code }
	p.s.on_failure = nil
	code, forced := api.finish(p.s, &p.wren, true, exit_code)
	p.ended, p.code = true, code
	if forced { stop_test(p.t, "the Wren did not close in time: it was ended", loc) }
	return code
}

// Its process is ended, the way a crash ends it (what its profile holds stays as it is). It has its exit code at once; the system may go on for seconds over a process killed
// with its graphics device (what starts next does not wait for that either).
kill :: proc(p: ^Wren_Process, loc := #caller_location) {
	p.s.on_failure = nil
	api.close_session(p.s)
	api.process_kill(&p.wren.process)
	wait_for(p.t, &p.wren.process, proc(process: ^api.Process) -> bool { return api.process_ended(process) }, "the killed Wren's exit code", loc = loc)
	p.ended, p.code = true, api.process_exit_code(&p.wren.process)
	if p.wren.temp { api.remove_folder_of(&p.wren.process, p.wren.profile) }
	api.process_release(&p.wren.process)
}

////////////////////////////////
// Any other program

Program :: struct {
	t:        ^testing.T,
	process:  api.Process,
	pid:      int,
	out, err: strings.Builder,
}

// A program in a process of its own, what it prints read through pipes unless `o` says where it goes; it ends with the test.
program :: proc(t: ^testing.T, args: []string, o := api.Start_Options{}, loc := #caller_location) -> ^Program {
	testing.set_fail_timeout(t, TEST_LIMIT, loc)
	p := new(Program)
	p.t = t
	o := o
	if o.stdout == {} { o.stdout.pipe = true }
	if o.stderr == {} && !o.merged { o.stderr.pipe = true }
	process, pid, err := api.process_start(args, o)
	if err != "" { stop_test(t, fmt.tprintf("%s could not start: %s", args[0], err), loc) }
	p.process, p.pid = process, pid
	strings.builder_init(&p.out)
	strings.builder_init(&p.err)
	testing.cleanup(t, proc(ptr: rawptr) {
		p := (^Program)(ptr)
		if api.process_alive(&p.process) { api.process_kill(&p.process); api.process_wait(&p.process, ms_of(DEFAULT_DEADLINE)) }
		api.process_release(&p.process)
		strings.builder_destroy(&p.out)
		strings.builder_destroy(&p.err)
		free(p)
	}, p)
	return p
}

// What it has printed so far.
program_output :: proc(p: ^Program) -> (out, err: string) {
	o, e := api.process_output(&p.process)
	strings.write_string(&p.out, o)
	strings.write_string(&p.err, e)
	return strings.to_string(p.out), strings.to_string(p.err)
}

// It has ended: its exit code.
program_wait :: proc(p: ^Program, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) -> int {
	// (what it prints is taken as it comes: a program that fills its pipe waits)
	end := time.tick_add(time.tick_now(), deadline)
	for !api.process_wait(&p.process, ms_of(OTHER_PROCESS_POLL)) {
		program_output(p)
		if time.tick_diff(time.tick_now(), end) <= 0 {
			out, err := program_output(p)
			stacks, _ := api.process_stacks(p.pid)
			stop_test(p.t, fmt.tprintf("the program did not end within %v; it printed:\n%s\n%s\n%s", deadline, out, err, stacks), loc)
		}
	}
	program_output(p)
	return api.process_exit_code(&p.process)
}

Run :: struct { code: int, out, err: string }

// A program, to its end: its exit code, what it printed.
run :: proc(t: ^testing.T, args: []string, o := api.Start_Options{}, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) -> Run {
	p := program(t, args, o, loc)
	code := program_wait(p, deadline, loc)
	out, err := program_output(p)
	return {code, strings.clone(out, context.temp_allocator), strings.clone(err, context.temp_allocator)}
}

////////////////////////////////
// What another process does

// `ready(data)` holds: looked at until it does (what another process does to the disk, the registry, the list of processes).
wait_for :: proc(t: ^testing.T, data: $D, ready: proc(data: D) -> bool, what: string, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) {
	end := time.tick_add(time.tick_now(), deadline)
	for !ready(data) {
		if time.tick_diff(time.tick_now(), end) <= 0 { stop_test(t, fmt.tprintf("%v passed waiting for %s", deadline, what), loc) }
		time.sleep(OTHER_PROCESS_POLL)
	}
}

// A file or a folder exists (`text` too: it holds that text).
wait_file :: proc(t: ^testing.T, path: string, text := "", deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) {
	wait_for(t, [2]string{path, text}, proc(d: [2]string) -> bool {
		if !os.exists(d[0]) { return false }
		return d[1] == "" || strings.contains(read_text(d[0]), d[1])
	}, fmt.tprintf("%s %s", path, text), deadline, loc)
}

// A file or a folder is gone.
wait_gone :: proc(t: ^testing.T, path: string, deadline: time.Duration = DEFAULT_DEADLINE, loc := #caller_location) {
	wait_for(t, path, proc(p: string) -> bool { return !os.exists(p) }, fmt.tprintf("%s to go", path), deadline, loc)
}
