package browser

// Giving memory back when the browser is idle. Closing a tab frees its objects, but memory is not necessarily returned
// to the system:
//   * the renderer keeps its layer targets (fp16 render targets of effects, filters, backdrops; a full-window one is
//     tens of MB) until 120 frames have gone by without using them, and an idle browser draws no frame: they stayed for
//     good (hundreds of MB after a few tabs of effects);
//   * Direct3D destroys resources lazily, the driver keeps them in its pools until the context is flushed and the device
//     trimmed (IDXGIDevice3::Trim, what the system asks of an application that stops drawing);
//   * the process heaps keep their free blocks committed (HeapCompact).
// memory_trim does all three; the main loop calls it once the browser has been idle for browser.memory.trim_idle_ms
// (memory_trim_tick), and again only after it has drawn something. The next frame after a trim makes its layer targets
// again, so the price is one slower first frame.

import "core:time"
import "toolkit:render"
import "wb:config"

MEMORY_PREFS := [?]config.Def{
	{name = "browser.memory.trim_idle_ms", kind = .Int, default = {i = 5000}, bounded = true, min = 0, max = 3_600_000, unit = "ms",
		description = "How long the browser must be idle (nothing drawn, nothing asked for) before it gives memory back to the system: the renderer's layer targets and the graphics driver's pools, the free blocks of the heaps. The next frame after that remakes its layer targets, so it is a little slower. 0 = never."},
}

register_memory_prefs :: proc(p: ^config.Prefs) { config.register(p, MEMORY_PREFS[:]) }

@(private = "file")
Trim_State :: struct {
	idle_ms: int,
	active:  time.Tick,   // the last turn of the loop that had something to draw
	done:    bool,        // trimmed since then
	count:   int,
}

@(private = "file")
trim_state: Trim_State

memory_trim_settings :: proc(p: ^config.Prefs) {
	trim_state.idle_ms = int(config.int_of(p, "browser.memory.trim_idle_ms"))
	trim_state.active = time.tick_now()
}

// The longest the loop may sleep: it wakes when a trim is due.
memory_trim_wake :: proc(timeout: int) -> int {
	t := &trim_state
	if t.idle_ms <= 0 || t.done { return timeout }
	left := max(t.idle_ms - int(time.duration_milliseconds(time.tick_since(t.active))), 1)
	return timeout <= 0 ? left : min(timeout, left)
}

// A frame that did something (input, a task, a page change, an animation) is under way: the idle time starts again.
// (A wake that brought nothing does not come here: frame() returns before.)
memory_trim_active :: proc() {
	trim_state.active, trim_state.done = time.tick_now(), false
}

// After every turn of the loop.
memory_trim_tick :: proc(app: ^App) {
	t := &trim_state
	if t.idle_ms <= 0 || t.done { return }
	if int(time.duration_milliseconds(time.tick_since(t.active))) >= t.idle_ms {
		t.done = true
		memory_trim(app)
	}
}

// UI thread only (the device's immediate context is not thread-safe). Releases the renderer's layer targets (neutral),
// then asks the system to give back what it holds lazily: on Windows the Direct3D device's pools (IDXGIDevice3::Trim
// after a context flush) and the process heaps' free blocks (memory_trim_native, memory_trim_<os>.odin); nothing more
// is reclaimable that way on wgpu / Linux (the driver manages its own pools).
memory_trim :: proc(app: ^App) {
	trim_state.count += 1
	render.release_targets(&app.r)
	memory_trim_native(app)
}

// How many times the browser trimmed (the check build's statistics).
memory_trim_count :: proc() -> int { return trim_state.count }
