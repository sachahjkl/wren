#+build windows
package client

// Starting a Wren of its own: `wren ctl run` (one call: start, load, capture, close), `wren ctl start` / `stop` (a session
// that later commands connect to). The instance is this same executable, started with --remote=<name>; the client only ever
// ends the process it started (by its pid and handle), never one found by name.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import win "core:sys/windows"
import "wb:remote"

Launched :: struct {
	process:   win.HANDLE,
	pid:       int,
	name:      string,
	profile:   string,
	temp:      bool,   // the profile folder is ours (made for this run): removed at the end
}

// Waits for process `pid` to end. `ended` false: still running after `ms`. A process that is already gone has no code to give.
wait_process_exit :: proc(pid: int, ms: int) -> (code: int, ended: bool) {
	if pid <= 0 { return 0, true }
	h := win.OpenProcess(win.SYNCHRONIZE | win.PROCESS_QUERY_LIMITED_INFORMATION, false, win.DWORD(pid))
	if h == nil { return 0, true }
	defer win.CloseHandle(h)
	if win.WaitForSingleObject(h, win.DWORD(ms)) != win.WAIT_OBJECT_0 { return 0, false }
	c: win.DWORD
	win.GetExitCodeProcess(h, &c)
	return int(c), true
}

@(private)
alive :: proc(h: win.HANDLE) -> bool { return win.WaitForSingleObject(h, 0) == win.WAIT_TIMEOUT }

@(private)
quote_arg :: proc(s: string) -> string {
	if s != "" && !strings.contains_any(s, " \t\"") { return s }
	return strings.concatenate({`"`, strings.trim_right(s, `\`), `"`}, context.temp_allocator)
}

// Starts this program with a remote channel. `profile` "": a folder made for the run in the temporary folder.
launch :: proc(ctx: ^Context, name, profile: string, hidden: bool, extra: []string) -> (l: Launched, ok: bool) {
	l.name = name
	l.profile = profile
	if l.profile == "" {
		tmp := os.get_env("TEMP", context.temp_allocator)
		if tmp == "" { tmp = "." }
		l.profile = fmt.aprintf("%s\\wren-ctl\\profile-%s", tmp, name, allocator = context.temp_allocator)
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
	for p in ctx.o.prefs { append(&args, "--pref", p) }
	for e in extra { append(&args, e) }
	append(&args, "about:blank")
	line := strings.builder_make(context.temp_allocator)
	for a, i in args { if i > 0 { strings.write_byte(&line, ' ') }; strings.write_string(&line, quote_arg(a)) }
	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW)}
	pi: win.PROCESS_INFORMATION
	wline := win.utf8_to_wstring(strings.to_string(line), context.temp_allocator)
	if !win.CreateProcessW(nil, cstring16(wline), nil, nil, false, 0, nil, nil, &si, &pi) {
		errln(fmt.tprintf("wren ctl: cannot start %s (error %d)", ctx.exe, win.GetLastError()))
		return l, false
	}
	win.CloseHandle(pi.hThread)
	l.process, l.pid = pi.hProcess, int(pi.dwProcessId)
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
		if !alive(l.process) { errln("wren ctl: Wren ended before it was ready"); return false }
	}
	errln(fmt.tprintf("wren ctl: Wren did not open %s in %d ms", remote.pipe_path(l.name), wait_ms))
	return false
}

// Ends the instance: asks it to close, waits, and as a last resort ends this very process (the handle we hold).
@(private)
finish_launched :: proc(ctx: ^Context, l: ^Launched, ask: bool) -> int {
	code := 0
	if ask && ctx.connected { _, _ = call(&ctx.conn, "Browser.close", `{"exitCode":0}`, 5000) }
	if ctx.connected { disconnect(&ctx.conn); ctx.connected = false }
	if win.WaitForSingleObject(l.process, 15_000) != win.WAIT_OBJECT_0 {
		errln("wren ctl: Wren did not close in time: ending it")
		win.TerminateProcess(l.process, 1)
		win.WaitForSingleObject(l.process, 5000)
		code = EXIT_TIMEOUT
	}
	win.CloseHandle(l.process)
	if l.temp && strings.contains(l.profile, "wren-ctl") { _ = os.remove_all(l.profile) }
	return code
}

cmd_run :: proc(ctx: ^Context, args: []string) -> int {
	timing := flag(&ctx.o, "timing")
	t0 := time.tick_now()
	lap :: proc(from: ^time.Tick) -> f64 { now := time.tick_now(); d := time.duration_milliseconds(time.tick_diff(from^, now)); from^ = now; return d }
	name := fmt.tprintf("run%d-%d", win.GetCurrentProcessId(), time.now()._nsec / 1_000_000 % 1_000_000)
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

////////////////////////////////
// A session

@(private)
state_dir :: proc() -> string {
	tmp := os.get_env("TEMP", context.temp_allocator)
	if tmp == "" { tmp = "." }
	return strings.concatenate({tmp, "\\wren-ctl"}, context.temp_allocator)
}

@(private)
state_file :: proc(name: string) -> string { return strings.concatenate({state_dir(), "\\", name, ".json"}, context.temp_allocator) }

cmd_start :: proc(ctx: ^Context, args: []string) -> int {
	name := opt(&ctx.o, "name")
	if name == "" { name = fmt.tprintf("s%d", time.now()._nsec / 1_000_000 % 10_000_000) }
	if !remote.valid_name(name) { return usage("start", "--name: letters, digits, '-', '_' and '.'") }
	l, ok := launch(ctx, name, opt(&ctx.o, "profile"), !flag(&ctx.o, "visible"), nil)
	if !ok { return EXIT_FAILED }
	if !connect_launched(ctx, &l, opt_int(&ctx.o, "timeout", 30_000)) {
		win.TerminateProcess(l.process, 1)
		win.CloseHandle(l.process)
		return EXIT_NO_SERVER
	}
	_ = os.make_directory_all(state_dir())
	state := fmt.tprintf(`{{"name":%s,"pid":%d,"profile":%s,"temp":%v}}`, q(name), l.pid, q(l.profile), l.temp)
	_ = os.write_entire_file(state_file(name), transmute([]byte)state)
	if s := opt(&ctx.o, "size"); s != "" {
		w, h, good := parse_size(s)
		if good { _, _ = request(ctx, "Browser.setWindowBounds", fmt.tprintf(`{{"width":%d,"height":%d}}`, w, h)) }
	}
	if len(args) > 0 {
		if _, c := request(ctx, "Page.navigate", fmt.tprintf(`{{"url":%s,"wait":%s}}`, q(args[0]), q(opt(&ctx.o, "wait", "load")))); c != 0 { return c }
	}
	win.CloseHandle(l.process)
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
	profile, _ := remote.param_string(st, "profile")
	temp, _ := remote.param_bool(st, "temp")
	if connect(&ctx.conn, name, 500) {
		ctx.connected = true
		_, _ = call(&ctx.conn, "Browser.close", `{"exitCode":0}`, 5000)
		disconnect(&ctx.conn)
		ctx.connected = false
	}
	code := 0
	if _, ended := wait_process_exit(pid, 15_000); !ended {
		// the pid we started and wrote down: nothing else is ended
		h := win.OpenProcess(win.PROCESS_TERMINATE | win.SYNCHRONIZE, false, win.DWORD(pid))
		if h != nil {
			errln("wren ctl: Wren did not close in time: ending it")
			win.TerminateProcess(h, 1)
			win.WaitForSingleObject(h, 5000)
			win.CloseHandle(h)
		}
		code = EXIT_TIMEOUT
	}
	if temp && strings.contains(profile, "wren-ctl") { _ = os.remove_all(profile) }
	_ = os.remove(state_file(name))
	return code
}
