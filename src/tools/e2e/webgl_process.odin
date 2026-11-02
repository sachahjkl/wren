#+build windows
package e2e_scenarios

// The GPU process's life in the real browser (docs/js/webgl.md), on whatever adapter the machine has (none: said, not failed), and nothing of it asked of the program: what a crash
// and a deadlock in a driver are is done to the process from outside. A page without WebGL starts no process; the first context starts one, of the same program; killed while a page
// draws, every context of the page and of its workers gets webglcontextlost and webglcontextrestored and goes on, unless it does not ask for it back; one that does nothing any more
// answers no question, is killed by the watcher, and the page goes on; a browser that is killed takes its process along.

import "core:fmt"
import win "core:sys/windows"
import "core:testing"
import "core:time"
import "wb:e2e"
import "wb:remote/api"
import "wb:webgl"

@(private = "file") HANG_MS :: 10_000     // webgl.gpu_hang_ms: a hung process does not take half a minute, and a device being made with every core busy is not taken for one (at 1 s, and at 3 s under load, the watcher killed the process during its first context)
@(private = "file") RESTARTS :: 100       // webgl.gpu_max_restarts: what is killed on purpose
@(private = "file") HANG_PREF :: "webgl.gpu_hang_ms=%d"
@(private = "file") RESTARTS_PREF :: "webgl.gpu_max_restarts=%d"
@(private = "file") GREEN_PIXEL :: "0,255,0,255"
// Above the longest a question waits on the slowest adapter (twice webgl.gpu_hang_ms on a software one): it says the question does not wait for ever.
@(private = "file") HUNG_ANSWER_WITHIN_MS :: 60_000

@(private = "file") PLAIN_PAGE :: `<!doctype html><title>plain</title><h1 id=a>no WebGL here</h1><canvas id=c></canvas><script>document.getElementById("c").getContext("2d")</script>`
// `context()`: a context whose page asks for it back when it is lost (`asks`), and what it was told.
@(private = "file") GL_PAGE :: `<!doctype html><title>gl</title><script>
window.context = (asks = true) => {
  const c = document.createElement("canvas");
  c.width = c.height = 8;
  const state = { c, gl: c.getContext("webgl", { antialias: false }), lost: 0, restored: 0 };
  c.addEventListener("webglcontextlost", e => { state.lost++; if (asks) e.preventDefault(); });
  c.addEventListener("webglcontextrestored", () => state.restored++);
  return state;
};
window.green = gl => { gl.clearColor(0, 1, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT); const p = new Uint8Array(4); gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, p); return p.join(); };
window.a = context();
window.b = context();
window.has = a.gl !== null;
window.pageWorks = () => { const d = document.createElement("div"); d.textContent = "x"; document.body.appendChild(d); const ok = document.body.lastChild.textContent === "x"; d.remove(); return ok; };
window.draw = () => { for (let i = 0; i < 100; i++) { a.gl.clear(a.gl.COLOR_BUFFER_BIT); a.gl.flush(); } };
(function spin() { if (has && !a.gl.isContextLost()) { a.gl.clear(a.gl.COLOR_BUFFER_BIT); a.gl.drawArrays(a.gl.TRIANGLES, 0, 0); } requestAnimationFrame(spin); })();
</script><body>`
// A worker's context: it hears of the end of the process too, on its own loop.
@(private = "file") WORKER_SCRIPT :: `
window.said = [];
const worker = new Worker("data:text/javascript," + encodeURIComponent(` + "`" + `
  const c = new OffscreenCanvas(8, 8);
  const gl = c.getContext("webgl", { antialias: false });
  c.addEventListener("webglcontextlost", e => { e.preventDefault(); postMessage("lost"); });
  c.addEventListener("webglcontextrestored", () => {
    gl.clearColor(0, 1, 0, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    const p = new Uint8Array(4);
    gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, p);
    postMessage("restored " + p.join());
  });
  gl.clear(gl.COLOR_BUFFER_BIT);
  postMessage("ready " + gl.getError());
` + "`" + `));
worker.onmessage = e => said.push(e.data);
worker.onerror = e => said.push("error " + e.message);
1`

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

// Ended: the exit code the system gives a process it ends, at once. Not its handle signalled: a process killed with its graphics device is left to the system to tear down,
// which took 60 s and more with every core busy (a whole test_all run) and seconds otherwise; a wait on that measured the system, not the browser.
@(private = "file")
ended :: proc(h: win.HANDLE) -> bool {
	code: win.DWORD
	return bool(win.GetExitCodeProcess(h, &code)) && code != STILL_ACTIVE
}
@(private = "file") STILL_ACTIVE :: 259

@(private = "file")
signalled :: proc(h: win.HANDLE) -> bool { return win.WaitForSingleObject(h, 0) == win.WAIT_OBJECT_0 }

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

// A browser on the limits of these tests, on a page with two contexts that draw. false: the machine has no adapter, it has said so.
@(private = "file")
open_gl_page :: proc(t: ^testing.T, loc := #caller_location) -> (s: ^e2e.Session, page: string, ok: bool) {
	s = e2e.start(t, {prefs = {fmt.tprintf(HANG_PREF, HANG_MS), fmt.tprintf(RESTARTS_PREF, RESTARTS)}}, loc)
	page = e2e.file_page(e2e.temp_folder(t), "gl.html", GL_PAGE, loc)
	e2e.navigate(s, page, loc = loc)
	if e2e.eval(s, "String(window.has)", loc = loc) != "true" {
		machine_has_no_adapter(t, loc)
		return s, page, false
	}
	testing.expect_value(t, e2e.eval(s, "green(a.gl)", loc = loc), GREEN_PIXEL, loc = loc)   // a context draws
	return s, page, true
}

@(test)
gpu_process_lives_and_comes_back :: proc(t: ^testing.T) {
	dir := e2e.temp_folder(t)
	s := e2e.start(t, {prefs = {fmt.tprintf(HANG_PREF, HANG_MS), fmt.tprintf(RESTARTS_PREF, RESTARTS)}})
	// (the process is the program's: the test before this one has left its own, idle, and on a machine with no adapter it has asked)
	if left := e2e.stats(s).gpu_process_id; left != 0 {
		h := process_handle(left)
		defer win.CloseHandle(h)
		win.TerminateProcess(h, 1)
		e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return e2e.stats(s).gpu_process_id == 0 }, "the process of the test before to be gone")
	}
	starts := e2e.stats(s).gpu_process_starts
	e2e.navigate(s, e2e.file_page(dir, "plain.html", PLAIN_PAGE))
	testing.expect_value(t, e2e.eval(s, "document.querySelector('h1').textContent"), "no WebGL here")   // a page without WebGL runs
	testing.expect_value(t, e2e.stats(s).gpu_process_starts, starts)                                    // and starts no process

	page := e2e.file_page(dir, "gl.html", GL_PAGE)
	e2e.navigate(s, page)
	if e2e.eval(s, "String(window.has)") != "true" {
		machine_has_no_adapter(t)
		return
	}
	testing.expect_value(t, e2e.eval(s, "green(a.gl)"), GREEN_PIXEL)   // a context draws
	testing.expect_value(t, e2e.eval(s, "green(b.gl)"), GREEN_PIXEL)   // another too
	st := e2e.stats(s)
	testing.expect_value(t, st.gpu_process_starts, starts + 1)     // one process, started by the first context of two
	first := process_handle(st.gpu_process_id)
	defer win.CloseHandle(first)
	testing.expect_value(t, program_of(first), own_program())      // the same program

	e2e.navigate(s, page)
	testing.expect_value(t, e2e.eval(s, "green(a.gl)"), GREEN_PIXEL)   // a second page has the same process
	testing.expect_value(t, e2e.stats(s).gpu_process_id, st.gpu_process_id)
	testing.expect_value(t, e2e.stats(s).gpu_process_starts, starts + 1)

	// killed with draws on their way: every context is lost and gets back
	e2e.eval(s, "draw(); 1")
	win.TerminateProcess(first, 1)
	e2e.eval(s, "draw(); 1")
	e2e.wait_js(s, "a.lost === 1 && b.lost === 1")
	testing.expect_value(t, e2e.eval(s, "a.gl.getError() === a.gl.CONTEXT_LOST_WEBGL || a.restored === 1"), "true")   // says so, for as long as it is lost
	testing.expect_value(t, e2e.eval(s, "pageWorks()"), "true")    // the browser and its page carry on
	e2e.wait_js(s, "a.restored === 1 && b.restored === 1")
	testing.expect_value(t, e2e.eval(s, "a.gl.isContextLost() || b.gl.isContextLost()"), "false")
	testing.expect_value(t, e2e.eval(s, "green(a.gl)"), GREEN_PIXEL)   // it draws again
	testing.expect_value(t, e2e.eval(s, "green(b.gl)"), GREEN_PIXEL)
	again := e2e.stats(s)
	testing.expect(t, again.gpu_process_id != 0 && again.gpu_process_id != st.gpu_process_id, "in a new process")
	testing.expect_value(t, again.gpu_process_starts, starts + 2)
	// what a page does after restored: a program made anew, a new context
	testing.expect_value(t, e2e.eval(s, `(() => { const gl = a.gl, s = gl.createShader(gl.VERTEX_SHADER); gl.shaderSource(s, "attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }"); gl.compileShader(s); return gl.getShaderParameter(s, gl.COMPILE_STATUS); })()`), "true")
	testing.expect_value(t, e2e.eval(s, `document.createElement("canvas").getContext("webgl") !== null`), "true")

	// the machine has an adapter, then: what a page without a context would be told is the same
	verdict, why := webgl.adapter_probe(PROBE_SETTINGS)
	testing.expectf(t, verdict == .Present, "the probe of an adapter says what this page found: %v: %s", verdict, why)
}

// A page that does not ask for its context back does not get it; another of the same process does.
@(test)
gpu_process_killed_a_context_not_asked_back_stays_lost :: proc(t: ^testing.T) {
	s, _, ok := open_gl_page(t)
	if !ok { return }
	e2e.eval(s, "window.gone = context(false); green(gone.gl); 1")
	h := process_handle(e2e.stats(s).gpu_process_id)
	defer win.CloseHandle(h)
	win.TerminateProcess(h, 1)
	e2e.wait_js(s, "gone.lost === 1 && a.restored === 1")   // (when the one that asks has it back, the other would have)
	testing.expect_value(t, e2e.eval(s, "gone.restored"), "0")
	testing.expect_value(t, e2e.eval(s, "gone.gl.isContextLost()"), "true")
}

@(test)
gpu_process_killed_a_workers_context_comes_back :: proc(t: ^testing.T) {
	s, _, ok := open_gl_page(t)
	if !ok { return }
	e2e.eval(s, WORKER_SCRIPT)
	e2e.wait_js(s, "said.length > 0")
	testing.expect_value(t, e2e.eval(s, "said[0]"), "ready 0")
	h := process_handle(e2e.stats(s).gpu_process_id)
	defer win.CloseHandle(h)
	win.TerminateProcess(h, 1)
	e2e.wait_js(s, "said.length >= 3")
	testing.expect_value(t, e2e.eval(s, "said[1]"), "lost")
	testing.expect_value(t, e2e.eval(s, "said[2]"), fmt.tprintf("restored %s", GREEN_PIXEL))
}

// A process that does nothing any more (suspended from outside: what a deadlock in a driver looks like from here): a question of the page is let go at its deadline, the watcher kills it.
@(test)
gpu_process_hung_is_killed_and_the_page_goes_on :: proc(t: ^testing.T) {
	s, _, ok := open_gl_page(t)
	if !ok { return }
	st := e2e.stats(s)
	h := process_handle(st.gpu_process_id)
	defer win.CloseHandle(h)
	NtSuspendProcess(h)
	testing.expect_value(t, e2e.eval(s, "(() => { window.asked = performance.now(); const e = a.gl.getError(); window.took = performance.now() - asked; return e === a.gl.CONTEXT_LOST_WEBGL; })()"), "true")
	took := e2e.eval_f64(s, "took")
	testing.expectf(t, took < HUNG_ANSWER_WITHIN_MS, "the question is let go at its deadline: %.0f ms", took)
	testing.expect_value(t, e2e.eval(s, "pageWorks()"), "true")
	e2e.wait_until(s, h, proc(s: ^e2e.Session, h: win.HANDLE) -> bool { return ended(h) }, "the watcher to kill the process that hangs")
	e2e.wait_js(s, "b.lost === 1")                                 // the other context hears of it
	e2e.wait_js(s, "a.restored === 1 && b.restored === 1")         // and they get their contexts back
	testing.expect_value(t, e2e.eval(s, "green(a.gl)"), GREEN_PIXEL)   // and draw
	testing.expect(t, e2e.stats(s).gpu_process_id != st.gpu_process_id, "in a new process")
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
	api.eval(p.s, "green(a.gl)")
	st, _ := api.stats(p.s)
	gpu := process_handle(st.gpu_process_id)
	browser := process_handle(st.pid)
	defer { win.CloseHandle(gpu); win.CloseHandle(browser) }
	testing.expect(t, gpu != nil && browser != nil, "both processes are there")
	win.TerminateProcess(browser, 1)
	killed := time.tick_now()
	// (taken along: the system ends it when the browser's job closes, native/webgl ipc: KILL_ON_JOB_CLOSE)
	e2e.wait_for(t, gpu, ended, "the GPU process to be ended with its browser")
	fmt.printfln("webgl_process: the GPU process ended with its browser in %.0f ms; its handle signalled by then: %v", time.duration_milliseconds(time.tick_since(killed)), signalled(gpu))
}
