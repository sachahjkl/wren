package client

// Starting a Wren of its own: `wren ctl run` (one call: start, load, capture, close), `wren ctl start` / `stop` (a session
// that later commands connect to). The instance is this same executable, started with --remote=<name>; the client only ever
// ends the process it started, never one found by name: by the process it holds in `run`, and in `stop` by the process whose
// creation time and program are the ones written down at `start` (a pid alone is not an identity: the system gives the number
// of a process that ended to the next one that starts). Launching and connecting are the API's (wb:remote/api).

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:remote"
import "wb:remote/api"

@(private)
RUN_NAME_MS_MODULO :: 1_000_000

// The Wren of a command, as its options say. `profile` "": a folder made for the run in the temporary folder.
@(private)
launch :: proc(ctx: ^Context, name, profile: string, hidden: bool) -> (l: api.Launched, ok: bool) {
	dpi := 0.0
	if t := opt(&ctx.o, "dpi"); t != "" {
		if n, good := parse_float(t); good { dpi = n }
		if dpi <= 0 { errln("wren ctl: --dpi is a number (96 = 100 %, 144 = 150 %, 192 = 200 %)"); return l, false }
	}
	// --headless: no window at all (no desktop session needed); by default a window that exists and is never shown (UI Automation, the system's drag and hit test need a handle)
	mode := !hidden ? api.Window_Mode.Visible : flag(&ctx.o, "headless") ? .Headless : .Hidden
	r, err := api.launch({exe = ctx.exe, name = name, profile = profile, window = mode, dpi = dpi, prefs = ctx.o.prefs[:]})
	if err != "" {
		errln(fmt.tprintf("wren ctl: cannot start %s (%s)", ctx.exe, err))
		return r, false
	}
	return r, true
}

@(private)
connect_or_say :: proc(ctx: ^Context, l: ^api.Launched, wait_ms: int) -> bool {
	if e := api.connect_launched(&ctx.s, l, wait_ms); e != .None {
		errln(fmt.tprintf("wren ctl: %s", api.last_failure().message))
		return false
	}
	return true
}

// Ends the instance: asks it to close, waits, and as a last resort ends this very process (the one we hold).
@(private)
finish_launched :: proc(ctx: ^Context, l: ^api.Launched) -> int {
	_, forced := api.finish(&ctx.s, l, true)
	if forced { errln("wren ctl: Wren did not close in time: it was ended"); return EXIT_TIMEOUT }
	return 0
}

@(private)
set_size :: proc(ctx: ^Context, w, h: int) -> int {
	if _, e := api.set_window(&ctx.s, {size = [2]int{w, h}}); e != .None { return failed(ctx, e) }
	save_initial(ctx)
	return 0
}

cmd_run :: proc(ctx: ^Context, args: []string) -> int {
	timing := flag(&ctx.o, "timing")
	t0 := time.tick_now()
	lap :: proc(from: ^time.Tick) -> f64 { now := time.tick_now(); d := time.duration_milliseconds(time.tick_diff(from^, now)); from^ = now; return d }
	name := fmt.tprintf("run%d-%d", api.this_pid(), time.now()._nsec / 1_000_000 % RUN_NAME_MS_MODULO)
	l, ok := launch(ctx, name, opt(&ctx.o, "profile"), !flag(&ctx.o, "visible"))
	if !ok { return EXIT_FAILED }
	code := 0
	defer { fc := finish_launched(ctx, &l); if code == 0 { code = fc }; if timing { errln(fmt.tprintf("close %.0f ms", lap(&t0))) } }
	startup := ctx.s.timeout_ms > 0 ? ctx.s.timeout_ms : api.START_WAIT_MS
	if !connect_or_say(ctx, &l, startup) { code = EXIT_NO_SERVER; return code }
	if timing { errln(fmt.tprintf("start %.0f ms", lap(&t0))) }
	if s := opt(&ctx.o, "size"); s != "" {
		w, h, good := parse_size(s)
		if !good { code = usage("run", "--size WxH"); return code }
		if c := set_size(ctx, w, h); c != 0 { code = c; return code }
	}
	if len(args) > 0 {
		w, good := wait_option(ctx, "load")
		if !good { code = EXIT_USAGE; return code }
		if e := api.navigate(&ctx.s, args[0], w, NO_DEADLINE); e != .None { code = failed(ctx, e); return code }
		if timing { errln(fmt.tprintf("load %.0f ms", lap(&t0))) }
	}
	if js := opt(&ctx.o, "eval"); js != "" {
		if c := cmd_eval(ctx, {js}); c != 0 { code = c; return code }
	}
	if shot := opt(&ctx.o, "shot"); shot != "" {
		if c := cmd_shot(ctx, {shot}); c != 0 { code = c; return code }
		if timing { errln(fmt.tprintf("shot %.0f ms", lap(&t0))) }
	}
	return code
}

// The window has its size: that is the state `reset` puts back (the preferences are the ones the Wren started with).
@(private)
save_initial :: proc(ctx: ^Context) { _, _ = api.checkpoint_save(&ctx.s, "initial") }

////////////////////////////////
// A session

@(private)
state_file :: proc(name: string) -> string { return strings.concatenate({api.state_dir(), filepath.SEPARATOR_STRING, name, ".json"}, context.temp_allocator) }

cmd_start :: proc(ctx: ^Context, args: []string) -> int {
	name := opt(&ctx.o, "name")
	// (no clock alone: two starts of the same millisecond, tests in parallel, took one name and drove each other's window)
	if name == "" { name = fmt.tprintf("s%s", base.unique_name(context.temp_allocator)) }
	if !remote.valid_name(name) { return usage("start", "--name: letters, digits, '-', '_' and '.'") }
	l, ok := launch(ctx, name, opt(&ctx.o, "profile"), !flag(&ctx.o, "visible"))
	if !ok { return EXIT_FAILED }
	if !connect_or_say(ctx, &l, ctx.s.timeout_ms > 0 ? ctx.s.timeout_ms : api.START_WAIT_MS) {
		api.process_kill(&l.process)
		api.process_release(&l.process)
		return EXIT_NO_SERVER
	}
	_ = os.make_directory_all(api.state_dir())
	// (who the process is, now that it is held: `stop` ends nothing it cannot tell again by this)
	who, _ := api.identity_of(&l.process)
	state := fmt.tprintf(`{{"name":%s,"pid":%d,"created":%d,"image":%s,"profile":%s,"temp":%v}}`, remote.quote(name), l.pid, who.created, remote.quote(who.image), remote.quote(l.profile), l.temp)
	_ = os.write_entire_file(state_file(name), transmute([]byte)state)
	if s := opt(&ctx.o, "size"); s != "" {
		w, h, good := parse_size(s)
		if good { _ = set_size(ctx, w, h) }
	}
	if len(args) > 0 {
		w, good := wait_option(ctx, "load")
		if !good { return EXIT_USAGE }
		if e := api.navigate(&ctx.s, args[0], w, NO_DEADLINE); e != .None { return failed(ctx, e) }
	}
	api.process_detach(&l.process)
	outln(name)
	return 0
}

cmd_stop :: proc(ctx: ^Context, args: []string) -> int {
	name := len(args) > 0 ? args[0] : opt(&ctx.o, "remote")
	if name == "" { name, _ = os.lookup_env("WREN_REMOTE", context.temp_allocator) }
	if name == "" { return usage("stop", "usage: stop <name>   (the name `wren ctl start` printed)") }
	data, err := os.read_entire_file(state_file(name), context.temp_allocator)
	if err != nil { errln(fmt.tprintf("wren ctl: no session %q was started by wren ctl start", name)); return EXIT_FAILED }
	v, _ := json.parse(data, json.Specification.JSON, true, context.temp_allocator)
	st, _ := v.(json.Object)
	pid, _ := remote.param_int(st, "pid")
	created, _ := remote.param_int(st, "created")   // (FILETIME ticks fit an i64 until the year 30828)
	image, _ := remote.param_string(st, "image")
	profile, _ := remote.param_string(st, "profile")
	temp, _ := remote.param_bool(st, "temp")
	if api.connect(&ctx.s.conn, name, STOP_CONNECT_MS) {
		ctx.s.connected = true
		_ = api.browser_close(&ctx.s, 0, temp)
		api.close_session(&ctx.s)
	}
	code := 0
	// One process, opened once and checked to be the one `start` made: it is what is waited for and, as a last resort,
	// ended. The number alone may be another program's by now (the Wren ended long ago and the system reused it).
	if p, opened := api.process_open(pid); opened {
		p := p
		defer api.process_release(&p)
		now, readable := api.identity_of(&p)
		if !readable || !api.same_process({created = u64(created), image = image}, now) {
			errln(fmt.tprintf("wren ctl: process %d is not the Wren that %q started (it ended, and the number is another program's now): left alone", pid, name))
		} else if !api.process_wait(&p, api.CLOSE_WAIT_MS) {
			errln("wren ctl: Wren did not close in time: ending it")
			api.process_kill(&p)
			api.process_wait(&p, api.KILL_WAIT_MS)
			code = EXIT_TIMEOUT
		}
	}
	if temp && strings.contains(profile, "wren-ctl") { base.remove_tree(profile) }
	_ = os.remove(state_file(name))
	return code
}

// How long `stop` tries to reach the Wren (ms).
@(private)
STOP_CONNECT_MS :: 500

@(private)
parse_float :: proc(s: string) -> (f64, bool) {
	v := 0.0
	n := 0
	frac := 0.0
	scale := 0.1
	seen_dot := false
	for c in transmute([]byte)s {
		switch {
		case c >= '0' && c <= '9':
			if seen_dot { frac += f64(c - '0') * scale; scale /= 10 } else { v = v * 10 + f64(c - '0') }
			n += 1
		case c == '.' && !seen_dot: seen_dot = true
		case: return 0, false
		}
	}
	return v + frac, n > 0
}
