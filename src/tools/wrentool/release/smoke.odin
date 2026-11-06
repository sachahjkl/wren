package release

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:remote/api"
import "wb:tools/tooling"
import "wb:tools/wrentool/bench"

// The packaged executable end to end, as a user unpacks it: it starts, makes a window, runs script and draws a page; WebGL on the machine's driver, its GPU process lost and restored, and gone with a killed browser. It needs a
// display (xvfb-run on a machine without one) and a Vulkan or GL driver.

SMOKE_SIZE :: [2]int{1000, 700}
SMOKE_SECOND_SIZE :: [2]int{400, 300}
SMOKE_CAPTURE_MIN_BYTES :: 1000
SMOKE_LIMIT :: 120 * time.Second
SMOKE_LOOK :: 100 * time.Millisecond
SMOKE_PAGE :: "<!doctype html><title>hello</title><h1 id=a>Wren</h1>"
SMOKE_WEBGL :: "(function(){ var c=document.createElement('canvas'), g=c.getContext('webgl'); if(!g) return 'no adapter'; g.clearColor(0,1,0,1); g.clear(g.COLOR_BUFFER_BIT); var p=new Uint8Array(4); g.readPixels(0,0,1,1,g.RGBA,g.UNSIGNED_BYTE,p); return 'pixel '+p.join(); })()"
SMOKE_RECURSION :: "(function(){ function f(){ return f() + 1 } try { f() } catch (e) { return e.name } })()"
SMOKE_WATCH_CONTEXT :: "window.gl_events = []; window.glc = document.createElement('canvas'); glc.addEventListener('webglcontextlost', function (e) { gl_events.push('lost'); e.preventDefault(); }); glc.addEventListener('webglcontextrestored', function () { gl_events.push('restored'); }); window.gl = glc.getContext('webgl'); gl.clearColor(0,1,0,1); 1"
SMOKE_DRAWS :: "(function(){ gl.clearColor(0,1,0,1); gl.clear(gl.COLOR_BUFFER_BIT); var p=new Uint8Array(4); gl.readPixels(0,0,1,1,gl.RGBA,gl.UNSIGNED_BYTE,p); return p.join(); })()"

Smoke :: struct { failed: int }

@(private)
check_has :: proc(s: ^Smoke, name, want, got: string) {
	if strings.contains(got, want) { fmt.printfln("PASS %s", name); return }
	fmt.printfln("FAIL %s: expected '%s', got '%s'", name, want, got)
	s.failed += 1
}

@(private)
kill_pid :: proc(pid: int) -> bool {
	when ODIN_OS == .Windows {
		return false   // (Linux's: what it says of a process has no use on Windows, where the e2e scenarios cover this)
	} else {
		return tooling.run({command = {"kill", "-9", fmt.tprint(pid)}}) == 0
	}
}

@(private)
pid_gone :: proc(pid: int) -> bool {
	status, err := os.read_entire_file(fmt.tprintf("/proc/%d/status", pid), context.temp_allocator)
	if err != nil { return true }
	for line in strings.split_lines(string(status), context.temp_allocator) {
		if strings.has_prefix(line, "State:") { return strings.contains(line, "Z") || strings.contains(line, "X") }
	}
	return true
}

run_smoke :: proc(args: []string) -> int {
	if len(args) != 1 { fmt.eprintln("wrentool smoke <wren executable>"); return EXIT_USAGE }
	exe, _ := filepath.abs(args[0], context.temp_allocator)
	s: Smoke
	version, _ := tooling.capture({exe, "--version"}, allocator = context.temp_allocator)
	check_has(&s, "the version", "Wren", version)
	dir := fmt.tprintf("%s/wren-smoke-%s", base.temp_dir(context.temp_allocator), base.unique_name(context.temp_allocator))
	_ = os.make_directory_all(dir)
	defer base.remove_tree(dir)
	page := fmt.tprintf("%s/page.html", dir)
	_ = os.write_entire_file(page, SMOKE_PAGE)

	w: bench.Wren
	if !bench.start(&w, {exe = exe, window = .Hidden, size = SMOKE_SIZE, url = bench.file_url(page)}) { return 1 }
	defer bench.stop(&w)
	ses := &w.session
	if api.wait_load(ses, SMOKE_LIMIT) != .None { fmt.eprintln(api.last_failure().message); return 1 }
	eval :: proc(ses: ^api.Session, script: string) -> string {
		text, e := api.eval(ses, script, deadline = SMOKE_LIMIT)
		return e == .None ? text : api.last_failure().message
	}
	check_has(&s, "script runs", "Wren 4", eval(ses, "document.getElementById('a').textContent + ' ' + (2 + 2)"))
	if st, _ := api.stats(ses); st.memory.wasm_shipped_hits == 1 && st.memory.wasm_compiles == 0 {
		fmt.println("PASS the engine's code is the program's: nothing compiled")
	} else {
		fmt.printfln("FAIL the engine's code: %d taken from the program, %d refused, %d compiled", st.memory.wasm_shipped_hits, st.memory.wasm_shipped_refused, st.memory.wasm_compiles)
		s.failed += 1
	}
	check_has(&s, "layout", "true", eval(ses, "document.getElementById('a').getBoundingClientRect().height > 10"))
	// deep recursion on the main thread: the same limits as on Windows, without a ulimit from the caller
	check_has(&s, "deep recursion", "RangeError", eval(ses, SMOKE_RECURSION))
	// WebGL, on the machine's Vulkan (Mesa's lavapipe on a runner): a clear read back (no adapter is said, not failed)
	webgl := eval(ses, SMOKE_WEBGL)
	check_has(&s, "WebGL", "pixel 0,255,0,255", webgl)
	if strings.contains(webgl, "pixel") {
		// The GPU process: a child of the browser that a kill costs contexts and nothing else.
		st, _ := api.stats(ses)
		if st.gpu_process_id != 0 { fmt.printfln("PASS a GPU process (%d)", st.gpu_process_id) } else { fmt.println("FAIL no GPU process"); s.failed += 1 }
		_ = eval(ses, SMOKE_WATCH_CONTEXT)
		if st.gpu_process_id != 0 { _ = kill_pid(st.gpu_process_id) }
		events := ""
		end := time.tick_add(time.tick_now(), SMOKE_LIMIT)
		for time.tick_diff(time.tick_now(), end) > 0 {
			events = eval(ses, "gl_events.join()")
			if strings.contains(events, "restored") { break }
			if api.wait_frames(ses, 1) != .None { break }
		}
		check_has(&s, "the GPU process killed: lost, then restored", "lost,restored", events)
		check_has(&s, "the page carries on", "Wren", eval(ses, "document.getElementById('a').textContent"))
		check_has(&s, "it draws again", "0,255,0,255", eval(ses, SMOKE_DRAWS))
	}
	shot := fmt.tprintf("%s/shot.png", dir)
	_, _ = api.screenshot(ses, shot)
	fi, err := os.stat(shot, context.temp_allocator)
	size := err == nil ? fi.size : 0
	if size > SMOKE_CAPTURE_MIN_BYTES { fmt.printfln("PASS a capture (%d bytes)", size) } else { fmt.printfln("FAIL a capture (%d bytes)", size); s.failed += 1 }

	// a Wren of its own, killed: its GPU process must not stay
	second: bench.Wren
	if bench.start(&second, {exe = exe, window = .Hidden, size = SMOKE_SECOND_SIZE}) {
		if eval(&second.session, "String(document.createElement('canvas').getContext('webgl') !== null)") == "true" {
			st, _ := api.stats(&second.session)
			api.process_kill(&second.launched.process)
			gone := false
			end := time.tick_add(time.tick_now(), SMOKE_LIMIT)
			for time.tick_diff(time.tick_now(), end) > 0 {
				if st.gpu_process_id != 0 && pid_gone(st.gpu_process_id) { gone = true; break }
				_ = api.process_wait(&w.launched.process, int(time.duration_milliseconds(SMOKE_LOOK)))
			}
			if gone { fmt.println("PASS the GPU process ends with a killed browser") } else { fmt.printfln("FAIL the GPU process %d is not gone", st.gpu_process_id); s.failed += 1 }
		}
		_, _ = api.finish(&second.session, &second.launched, false)
	}
	fmt.printfln("%d failure(s)", s.failed)
	return s.failed
}

////////////////////////////////
// The crash reports of Linux

CRASH_EXE :: "build/linux/crashmodes"
Crash_Wants :: enum { Report, Unclean, Either }
Crash_Case :: struct { mode: string, wants: Crash_Wants }
CRASH_CASES := []Crash_Case{{"access", .Report}, {"bounds", .Report}, {"assert", .Report}, {"overflow", .Report}, {"heap", .Report}, {"failfast", .Report}, {"overflow_thread", .Either}, {"exit", .Unclean}}

// src/tools/crashmodes dies in each way a Wren has died, and each death must leave its report (the stack, the build) or, for a death no handler sees, an "unclean exit" report at the next start. What src/tools/e2e/crash_reports.odin checks on Windows.
run_crash_e2e :: proc(args: []string) -> int {
	when ODIN_OS == .Windows {
		fmt.eprintln("on Windows: src/tools/e2e/crash_reports.odin")
		return EXIT_USAGE
	}
	_ = os.make_directory_all("build/linux")
	if tooling.run({command = {tooling.odin_program(), "build", "src/tools/crashmodes", "-collection:wb=src", "-vet", "-debug", "-o:speed", "-out:" + CRASH_EXE, "-extra-linker-flags:-Wl,--build-id"}}) != 0 { fmt.eprintln("crashmodes did not build"); return 1 }
	failed := 0
	for c in CRASH_CASES {
		dir := fmt.tprintf("%s/wren-crash-%s", base.temp_dir(context.temp_allocator), base.unique_name(context.temp_allocator))
		_ = os.make_directory_all(dir)
		defer base.remove_tree(dir)
		out_log := fmt.tprintf("%s/out.txt", dir)
		code := tooling.run({command = {CRASH_EXE, c.mode, dir}, log = out_log})
		// the next start: a session left behind becomes an "unclean exit" report
		_ = tooling.run({command = {CRASH_EXE, "clean", dir}, log = fmt.tprintf("%s/clean.txt", dir)})
		report, unclean := "", ""
		entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		for e in entries {
			if strings.has_prefix(e.name, "crash") && strings.has_suffix(e.name, ".txt") { report = e.fullpath }
			if strings.has_prefix(e.name, "unclean") && strings.has_suffix(e.name, ".txt") { unclean = e.fullpath }
		}
		text := ""
		if report != "" { data, _ := os.read_entire_file(report, context.temp_allocator); text = string(data) }
		good := false
		switch c.wants {
		case .Report: good = report != "" && (strings.has_prefix(text, "*** crash:") || strings.contains(text, "\n*** crash:")) && strings.contains(text, "end of the stack") && strings.contains(text, "crashmodes") && strings.contains(text, "\n  build crashmodes")
		case .Unclean: good = unclean != "" && report == ""
		case .Either: good = report != "" || unclean != ""
		}
		if good {
			fmt.printfln("ok    %s (exit %d, %d frames%s)", c.mode, code, strings.count(text, "\n  #"), unclean != "" ? ", unclean exit" : "")
		} else {
			said, _ := os.read_entire_file(out_log, context.temp_allocator)
			fmt.printfln("FAIL  %s (exit %d): want %v\n%s\n%s", c.mode, code, c.wants, string(said), text)
			failed += 1
		}
	}
	return failed > 0 ? 1 : 0
}
