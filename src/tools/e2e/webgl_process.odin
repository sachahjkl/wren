#+build windows
package e2e_scenarios

// The GPU process's life in the real browser (docs/js/webgl.md), on whatever adapter the machine has (none: said, not failed): a page without WebGL starts no
// process; the first context starts one, of the same program; killed while a page draws, the page gets webglcontextlost and webglcontextrestored and goes on;
// one that does nothing any more is killed by the watcher; a browser that is killed takes its process along.

import "core:fmt"
import win "core:sys/windows"
import "core:testing"
import "wb:e2e"
import "wb:remote/api"
import "wb:webgl"

@(private = "file") HANG_MS :: 10_000     // webgl.gpu_hang_ms: a hung process does not take half a minute, and a device being made with every core busy is not taken for one (at 1 s, and at 3 s under load, the watcher killed the process during its first context)
@(private = "file") RESTARTS :: 100       // webgl.gpu_max_restarts: what is killed on purpose
@(private = "file") HANG_PREF :: "webgl.gpu_hang_ms=%d"
@(private = "file") RESTARTS_PREF :: "webgl.gpu_max_restarts=%d"
@(private = "file") GREEN_PIXEL :: "0,255,0,255"

@(private = "file") PLAIN_PAGE :: `<!doctype html><title>plain</title><h1 id=a>no WebGL here</h1><canvas id=c></canvas><script>document.getElementById("c").getContext("2d")</script>`
@(private = "file") GL_PAGE :: `<!doctype html><title>gl</title><canvas id=c width=64 height=64></canvas><script>
window.events = [];
const c = document.getElementById("c");
c.addEventListener("webglcontextlost", e => { events.push("lost"); e.preventDefault(); });
c.addEventListener("webglcontextrestored", () => events.push("restored"));
window.gl = c.getContext("webgl", { antialias: false });
window.has = gl !== null;
window.pixel = () => { gl.clearColor(0, 1, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT); const p = new Uint8Array(4); gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, p); return p.join(); };
(function spin() { if (has && !gl.isContextLost()) { gl.clear(gl.COLOR_BUFFER_BIT); gl.drawArrays(gl.TRIANGLES, 0, 0); } requestAnimationFrame(spin); })();
</script>`

foreign import ntdll "system:ntdll.lib"
@(default_calling_convention = "system", private = "file")
foreign ntdll {
	NtSuspendProcess :: proc(h: win.HANDLE) -> i32 ---
}

foreign import kernel32 "system:kernel32.lib"
@(default_calling_convention = "system", private = "file")
foreign kernel32 {
	QueryFullProcessImageNameW :: proc(h: win.HANDLE, flags: win.DWORD, name: [^]u16, size: ^win.DWORD) -> win.BOOL ---
}

// A process of this machine, to act on from outside as a crash or a debugger would. nil: it is gone.
@(private = "file")
process_handle :: proc(pid: int) -> win.HANDLE { return win.OpenProcess(win.SYNCHRONIZE | win.PROCESS_TERMINATE | win.PROCESS_SUSPEND_RESUME | win.PROCESS_QUERY_LIMITED_INFORMATION, false, win.DWORD(pid)) }

@(private = "file")
ended :: proc(h: win.HANDLE) -> bool { return win.WaitForSingleObject(h, 0) == win.WAIT_OBJECT_0 }

// The program a process runs.
@(private = "file")
program_of :: proc(h: win.HANDLE) -> string {
	buf: [win.MAX_PATH_WIDE]u16
	n := win.DWORD(len(buf))
	if !QueryFullProcessImageNameW(h, 0, &buf[0], &n) { return "" }
	s, _ := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	return s
}

@(private = "file")
own_program :: proc() -> string { return program_of(win.GetCurrentProcess()) }

// A page got no context. That passes only if the machine says the same when asked on its own: a true skip, printed and counted. Anything else fails.
@(private = "file")
machine_has_no_adapter :: proc(t: ^testing.T, loc := #caller_location) {
	verdict, why := webgl.adapter_probe(PROBE_SETTINGS)
	if verdict == .Absent {
		fmt.printfln("SKIP [webgl_process] %s: %s", loc.procedure, why)
		return
	}
	testing.expectf(t, false, "the page got no WebGL context, and the machine does not say it has no adapter: %v: %s", verdict, why, loc = loc)
}
@(private = "file") PROBE_SETTINGS :: webgl.Settings{max_bytes = 64 << 20, gpu_hang_ms = webgl.DEFAULT_GPU_HANG_MS, gpu_max_restarts = webgl.DEFAULT_GPU_MAX_RESTARTS, gpu_restart_window_ms = webgl.DEFAULT_GPU_RESTART_WINDOW_S * webgl.MS_PER_S, gpu_idle_exit_ms = webgl.DEFAULT_GPU_IDLE_EXIT_S * webgl.MS_PER_S}

@(test)
gpu_process_lives_and_comes_back :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	s := e2e.start(t, {prefs = {fmt.tprintf(HANG_PREF, HANG_MS), fmt.tprintf(RESTARTS_PREF, RESTARTS)}})
	starts := e2e.stats(s).gpu_process_starts   // (the program's: on a machine with no adapter, the test before this one has asked it)
	e2e.navigate(s, e2e.file_page(dir, "plain.html", PLAIN_PAGE))
	testing.expect_value(t, e2e.eval(s, "document.querySelector('h1').textContent"), "no WebGL here")   // a page without WebGL runs
	testing.expect_value(t, e2e.stats(s).gpu_process_starts, starts)                                    // and starts no process

	page := e2e.file_page(dir, "gl.html", GL_PAGE)
	e2e.navigate(s, page)
	if e2e.eval(s, "String(window.has)") != "true" {
		machine_has_no_adapter(t)
		return
	}
	testing.expect_value(t, e2e.eval(s, "pixel()"), GREEN_PIXEL)   // the context draws
	st := e2e.stats(s)
	testing.expect_value(t, st.gpu_process_starts, starts + 1)     // one process, started by the first context
	first := process_handle(st.gpu_process_id)
	defer win.CloseHandle(first)
	testing.expect_value(t, program_of(first), own_program())      // the same program

	e2e.navigate(s, page)
	testing.expect_value(t, e2e.eval(s, "pixel()"), GREEN_PIXEL)   // a second page has the same process
	testing.expect_value(t, e2e.stats(s).gpu_process_id, st.gpu_process_id)
	testing.expect_value(t, e2e.stats(s).gpu_process_starts, starts + 1)

	// killed: the page loses its context and gets it back
	win.TerminateProcess(first, 1)
	e2e.wait_js(s, "events.join() == 'lost,restored'")
	testing.expect_value(t, e2e.eval(s, "document.title"), "gl")   // the browser and its page carry on
	testing.expect_value(t, e2e.eval(s, "pixel()"), GREEN_PIXEL)   // it draws again
	again := e2e.stats(s)
	testing.expect(t, again.gpu_process_id != 0 && again.gpu_process_id != st.gpu_process_id, "in a new process")
	testing.expect_value(t, again.gpu_process_starts, starts + 2)

	// A process that does nothing any more (suspended from outside: what a deadlock in a driver looks like from here): the page's frames have work for it,
	// and at webgl.gpu_hang_ms the watcher kills it.
	second := process_handle(again.gpu_process_id)
	defer win.CloseHandle(second)
	NtSuspendProcess(second)
	e2e.wait_until(s, second, proc(s: ^e2e.Session, h: win.HANDLE) -> bool { return ended(h) }, "the watcher to kill the process that hangs")
	e2e.wait_js(s, "events.join() == 'lost,restored,lost,restored'")   // the page gets its context back
	testing.expect_value(t, e2e.eval(s, "pixel()"), GREEN_PIXEL)       // and draws

	// the machine has an adapter, then: what a page without a context would be told is the same
	verdict, why := webgl.adapter_probe(PROBE_SETTINGS)
	testing.expectf(t, verdict == .Present, "the probe of an adapter says what this page found: %v: %s", verdict, why)
}

// A process of its own: what is killed here is the browser.
@(test)
a_killed_browser_takes_its_gpu_process_along :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	p := e2e.launch(t, {prefs = {fmt.tprintf(HANG_PREF, HANG_MS), fmt.tprintf(RESTARTS_PREF, RESTARTS)}})
	api.navigate(p.s, e2e.file_page(dir, "gl.html", GL_PAGE))
	if has, _ := api.eval(p.s, "String(window.has)"); has != "true" {
		machine_has_no_adapter(t)
		return
	}
	api.eval(p.s, "pixel()")
	st, _ := api.stats(p.s)
	gpu := process_handle(st.gpu_process_id)
	browser := process_handle(st.pid)
	defer { win.CloseHandle(gpu); win.CloseHandle(browser) }
	testing.expect(t, gpu != nil && browser != nil, "both processes are there")
	win.TerminateProcess(browser, 1)
	testing.expect_value(t, win.WaitForSingleObject(gpu, u32(e2e.DEFAULT_DEADLINE / 1e6)), win.WAIT_OBJECT_0)
}
