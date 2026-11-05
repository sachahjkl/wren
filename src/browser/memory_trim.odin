package browser

// Giving memory back when the browser is idle. Closing a tab frees its objects, but memory is not necessarily returned
// to the system:
//   * the renderer keeps its layer targets (fp16 render targets of effects, filters, backdrops; a full-window one is
//     tens of MB) until 120 frames have gone by without using them, and an idle browser draws no frame: they stayed for
//     good (hundreds of MB after a few tabs of effects);
//   * Direct3D destroys resources lazily, the driver keeps them in its pools until the context is flushed and the device
//     trimmed (IDXGIDevice3::Trim, what the system asks of an application that stops drawing);
//   * the process heaps keep their free blocks committed (HeapCompact);
//   * the page thread's arena keeps the size of the largest page laid out (40 MB after a news site).
// memory_trim does all that; the main loop calls it once the browser has been idle for browser.memory.trim_idle_ms
// (memory_trim_tick), and again only after it has drawn something; and TRIM_AFTER_PAGE_MS after a tab closed or a kept page
// went (memory_trim_soon), even when another page goes on drawing: what they held is free then, and a browser with an
// animation on screen is never idle. The next frame after a trim makes its layer targets again, so the price is one
// slower frame.

import "core:sync"
import "toolkit:render"
import "wb:config"

// A page gone: the trim that follows, once what it started has ended, and at most this often when pages go one after the other.
TRIM_AFTER_PAGE_MS :: 1000
TRIM_PAGE_GAP_MS :: 10_000

MEMORY_PREFS := [?]config.Def{
	{name = "browser.memory.trim_idle_ms", kind = .Int, default = {i = 5000}, bounded = true, min = 0, max = 3_600_000, unit = "ms",
		description = "How long the browser must be idle (nothing drawn, nothing asked for) before it gives memory back to the system: the renderer's layer targets and the graphics driver's pools, the free blocks of the heaps. The next frame after that remakes its layer targets, so it is a little slower. 0 = never."},
}

register_memory_prefs :: proc(p: ^config.Prefs) { config.register(p, MEMORY_PREFS[:]) }

@(private)
Trim_State :: struct {
	idle_ms: int,
	active:  i64,         // (the loop's clock, ns) the last turn of the loop that had something to draw
	done:    bool,        // trimmed since then
	count:   int,
	page_gone: bool,      // a page went since the last trim
	gone_at: i64,         // (the loop's clock, ns) when
	last:    i64,         // (the loop's clock, ns) the last trim
}

memory_trim_settings :: proc(app: ^App, p: ^config.Prefs) {
	app.trim_state.idle_ms = int(config.int_of(p, "browser.memory.trim_idle_ms"))
	app.trim_state.active = shell_now_ns()
}

// A tab closed or a kept page went: what it held is given back shortly.
memory_trim_soon :: proc(app: ^App) {
	t := &app.trim_state
	if t.idle_ms <= 0 || t.page_gone { return }
	t.page_gone, t.gone_at = true, shell_now_ns()
}

// How long until the trim a page's end asks for.
@(private = "file")
trim_page_left :: proc(t: ^Trim_State) -> int {
	since_last := t.count == 0 ? TRIM_PAGE_GAP_MS : int(shell_elapsed_ms(t.last))
	return max(TRIM_AFTER_PAGE_MS - int(shell_elapsed_ms(t.gone_at)), TRIM_PAGE_GAP_MS - since_last, 0)
}

// The longest the loop may sleep: it wakes when a trim is due.
memory_trim_wake :: proc(app: ^App, timeout: int) -> int {
	t := &app.trim_state
	left := -1
	if t.page_gone { left = max(trim_page_left(t), 1) }
	if t.idle_ms > 0 && !t.done {
		idle := max(t.idle_ms - int(shell_elapsed_ms(t.active)), 1)
		left = left < 0 ? idle : min(left, idle)
	}
	if left < 0 { return timeout }
	return timeout <= 0 ? left : min(timeout, left)
}

// A frame that did something (input, a task, a page change, an animation) is under way: the idle time starts again.
// (A wake that brought nothing does not come here: frame() returns before.)
memory_trim_active :: proc(app: ^App) {
	app.trim_state.active, app.trim_state.done = shell_now_ns(), false
}

// After every turn of the loop.
memory_trim_tick :: proc(app: ^App) {
	t := &app.trim_state
	if t.page_gone && trim_page_left(t) == 0 {
		memory_trim(app)
		return
	}
	if t.idle_ms <= 0 || t.done { return }
	if int(shell_elapsed_ms(t.active)) >= t.idle_ms {
		t.done = true
		memory_trim(app)
	}
}

// UI thread only (the device's immediate context is not thread-safe). Releases the renderer's layer targets (neutral),
// then asks the system to give back what it holds lazily: on Windows the Direct3D device's pools (IDXGIDevice3::Trim
// after a context flush) and the process heaps' free blocks (memory_trim_native, memory_trim_<os>.odin); nothing more
// is reclaimable that way on wgpu / Linux (the driver manages its own pools).
memory_trim :: proc(app: ^App) {
	app.trim_state.count += 1
	app.trim_state.last, app.trim_state.page_gone = shell_now_ns(), false
	render.release_targets(&app.r)
	sync.atomic_store(&app.pt.shrink_temp, true)
	memory_trim_native(app)
}

// How many times the browser trimmed (the check build's statistics).
memory_trim_count :: proc(app: ^App) -> int { return app.trim_state.count }
