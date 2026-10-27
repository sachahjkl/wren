package client

// Starting a Wren of its own: `wren ctl run` (one call: start, load, capture, close), `wren ctl start` / `stop` (a session
// that later commands connect to). The instance is this same executable, started with --remote=<name>; the client only ever
// ends the process it started, never one found by name: by the process it holds in `run`, and in `stop` by the process whose
// creation time and program are the ones written down at `start` (a pid alone is not an identity: the system gives the number
// of a process that ended to the next one that starts). The process itself is the system's (spawn_<os>.odin: Process,
// process_start, process_alive, process_wait, process_kill, process_release, process_open, identity_of, same_process,
// wait_process_exit, this_pid).

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:remote"

// Who a process is, for telling it again later: when it was created (Windows: FILETIME; Linux: its start after boot, in
// clock ticks) and the program it runs (full path).
Identity :: struct {
	created: u64,
	image:   string,
}

Launched :: struct {
	process:   Process,
	pid:       int,
	name:      string,
	profile:   string,
	temp:      bool,   // the profile folder is ours (made for this run): removed at the end
}

// Starts this program with a remote channel. `profile` "": a folder made for the run in the temporary folder.
launch :: proc(ctx: ^Context, name, profile: string, hidden: bool, extra: []string) -> (l: Launched, ok: bool) {
	l.name = name
	l.profile = profile
	if l.profile == "" {
		l.profile = strings.concatenate({state_dir(), filepath.SEPARATOR_STRING, "profile-", name}, context.temp_allocator)
		l.temp = true
	}
	_ = os.make_directory_all(l.profile)
	args := make([dynamic]string, context.temp_allocator)
	append(&args, ctx.exe, "--profile", l.profile, fmt.tprintf("--remote=%s", name), "--no-single-instance")
	if hidden { append(&args, "--headless") }
	if dpi := opt(&ctx.o, "dpi"); dpi != "" {
		v := 0.0
		if n, good := parse_float(dpi); good { v = n }
		if v <= 0 { errln("wren ctl: --dpi is a number (96 = 100 %, 144 = 150 %, 192 = 200 %)"); return l, false }
		append(&args, "--pref", fmt.tprintf("browser.ui.scale=%.4f", v / 96))
	}
	// a Wren of a throwaway profile is for automation: it does not download the content blocker's lists (a few seconds of CPU a little after
	// the start, which a measure of an idle Wren takes for the Wren's own, and a request in flight at the end); --pref below may turn it on
	if l.temp { append(&args, "--pref", "blocker.update.enabled=false", "--pref", "blocker.welcome_toast=false") }
	for p in ctx.o.prefs { append(&args, "--pref", p) }
	// a throwaway profile has no lists and no reason to download them (24 MB from the internet, 15 s after the start, in a Wren that
	// lives long enough: a test session that reuses its Wren): unless --pref says otherwise
	if l.temp {
		asked := false
		for p in ctx.o.prefs { if strings.has_prefix(p, "blocker.update.enabled=") { asked = true } }
		if !asked { append(&args, "--pref", "blocker.update.enabled=false") }
	}
	for e in extra { append(&args, e) }
	append(&args, "about:blank")
	p, pid, err := process_start(args[:])
	if err != "" {
		errln(fmt.tprintf("wren ctl: cannot start %s (%s)", ctx.exe, err))
		return l, false
	}
	l.process, l.pid = p, pid
	return l, true
}

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

// Connects to a Wren we started, giving up when it has ended or after `wait_ms`.
@(private)
connect_launched :: proc(ctx: ^Context, l: ^Launched, wait_ms: int) -> bool {
	deadline := time.tick_add(time.tick_now(), time.Duration(wait_ms) * time.Millisecond)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		if connect(&ctx.conn, l.name, 100) { ctx.connected = true; return true }
		if !process_alive(&l.process) { errln("wren ctl: Wren ended before it was ready"); return false }
	}
	errln(fmt.tprintf("wren ctl: Wren did not open %s in %d ms", remote.pipe_path(l.name), wait_ms))
	return false
}

// Ends the instance: asks it to close, waits, and as a last resort ends this very process (the one we hold).
@(private)
finish_launched :: proc(ctx: ^Context, l: ^Launched, ask: bool) -> int {
	code := 0
	if ask && ctx.connected { _, _ = call(&ctx.conn, "Browser.close", l.temp ? `{"exitCode":0,"fast":true}` : `{"exitCode":0}`, 5000) }
	if ctx.connected { disconnect(&ctx.conn); ctx.connected = false }
	if !process_wait(&l.process, 15_000) {
		errln("wren ctl: Wren did not close in time: ending it")
		process_kill(&l.process)
		process_wait(&l.process, 5000)
		code = EXIT_TIMEOUT
	}
	process_release(&l.process)
	if l.temp && strings.contains(l.profile, "wren-ctl") { _ = os.remove_all(l.profile) }
	return code
}

cmd_run :: proc(ctx: ^Context, args: []string) -> int {
	timing := flag(&ctx.o, "timing")
	t0 := time.tick_now()
	lap :: proc(from: ^time.Tick) -> f64 { now := time.tick_now(); d := time.duration_milliseconds(time.tick_diff(from^, now)); from^ = now; return d }
	name := fmt.tprintf("run%d-%d", this_pid(), time.now()._nsec / 1_000_000 % 1_000_000)
	l, ok := launch(ctx, name, opt(&ctx.o, "profile"), !flag(&ctx.o, "visible"), nil)
	if !ok { return EXIT_FAILED }
	code := 0
	defer { fc := finish_launched(ctx, &l, true); if code == 0 { code = fc }; if timing { errln(fmt.tprintf("close %.0f ms", lap(&t0))) } }
	startup := opt_int(&ctx.o, "timeout", 0) > 0 ? opt_int(&ctx.o, "timeout", 0) : 30_000
	if !connect_launched(ctx, &l, startup) { code = EXIT_NO_SERVER; return code }
	if timing { errln(fmt.tprintf("start %.0f ms", lap(&t0))) }
	if s := opt(&ctx.o, "size"); s != "" {
		w, h, good := parse_size(s)
		if !good { code = usage("run", "--size WxH"); return code }
		if _, c := request(ctx, "Browser.setWindowBounds", fmt.tprintf(`{{"width":%d,"height":%d}}`, w, h)); c != 0 { code = c; return code }
		save_initial(ctx)
	}
	if len(args) > 0 {
		wait := opt(&ctx.o, "wait", "load")
		rep, c := request(ctx, "Page.navigate", fmt.tprintf(`{{"url":%s,"wait":%s}}`, q(args[0]), q(wait)))
		if c != 0 { code = c; return code }
		_ = rep
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
save_initial :: proc(ctx: ^Context) { _, _ = call(&ctx.conn, "Wren.checkpoint", `{"action":"save","name":"initial"}`, 5000) }

////////////////////////////////
// A session

@(private)
state_dir :: proc() -> string {
	tmp := base.temp_dir(context.temp_allocator)
	if tmp == "" { tmp = "." }
	return strings.concatenate({tmp, filepath.SEPARATOR_STRING, "wren-ctl"}, context.temp_allocator)
}

@(private)
state_file :: proc(name: string) -> string { return strings.concatenate({state_dir(), filepath.SEPARATOR_STRING, name, ".json"}, context.temp_allocator) }

cmd_start :: proc(ctx: ^Context, args: []string) -> int {
	name := opt(&ctx.o, "name")
	if name == "" { name = fmt.tprintf("s%d", time.now()._nsec / 1_000_000 % 10_000_000) }
	if !remote.valid_name(name) { return usage("start", "--name: letters, digits, '-', '_' and '.'") }
	l, ok := launch(ctx, name, opt(&ctx.o, "profile"), !flag(&ctx.o, "visible"), nil)
	if !ok { return EXIT_FAILED }
	if !connect_launched(ctx, &l, opt_int(&ctx.o, "timeout", 30_000)) {
		process_kill(&l.process)
		process_release(&l.process)
		return EXIT_NO_SERVER
	}
	_ = os.make_directory_all(state_dir())
	// (who the process is, now that it is held: `stop` ends nothing it cannot tell again by this)
	who, _ := identity_of(&l.process)
	state := fmt.tprintf(`{{"name":%s,"pid":%d,"created":%d,"image":%s,"profile":%s,"temp":%v}}`, q(name), l.pid, who.created, q(who.image), q(l.profile), l.temp)
	_ = os.write_entire_file(state_file(name), transmute([]byte)state)
	if s := opt(&ctx.o, "size"); s != "" {
		w, h, good := parse_size(s)
		if good {
			_, _ = request(ctx, "Browser.setWindowBounds", fmt.tprintf(`{{"width":%d,"height":%d}}`, w, h))
			save_initial(ctx)
		}
	}
	if len(args) > 0 {
		if _, c := request(ctx, "Page.navigate", fmt.tprintf(`{{"url":%s,"wait":%s}}`, q(args[0]), q(opt(&ctx.o, "wait", "load")))); c != 0 { return c }
	}
	process_detach(&l.process)
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
	if connect(&ctx.conn, name, 500) {
		ctx.connected = true
		_, _ = call(&ctx.conn, "Browser.close", temp ? `{"exitCode":0,"fast":true}` : `{"exitCode":0}`, 5000)
		disconnect(&ctx.conn)
		ctx.connected = false
	}
	code := 0
	// One process, opened once and checked to be the one `start` made: it is what is waited for and, as a last resort,
	// ended. The number alone may be another program's by now (the Wren ended long ago and the system reused it).
	if p, opened := process_open(pid); opened {
		p := p
		defer process_release(&p)
		now, readable := identity_of(&p)
		if !readable || !same_process({created = u64(created), image = image}, now) {
			errln(fmt.tprintf("wren ctl: process %d is not the Wren that %q started (it ended, and the number is another program's now): left alone", pid, name))
		} else if !process_wait(&p, 15_000) {
			errln("wren ctl: Wren did not close in time: ending it")
			process_kill(&p)
			process_wait(&p, 5000)
			code = EXIT_TIMEOUT
		}
	}
	if temp && strings.contains(profile, "wren-ctl") { _ = os.remove_all(profile) }
	_ = os.remove(state_file(name))
	return code
}
