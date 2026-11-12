package browser

import "toolkit:draw"

// A program in this process that reads no pixel of its headless window (an end-to-end test of the cursor, the preferences, the
// address bar) has their rasterization skipped: on a machine with no GPU a frame costs 15 to 22 ms of a processor in the system's
// software rasterizer, for pixels that nobody reads. Everything up to the display list is made as usual (layout, paint, the
// interface's tree and its hit regions), so what such a test reads is what a real frame makes. Set by that program on its thread
// before app_start, as headless_software (e2e.Options.pixels).
@(thread_local)
headless_no_pixels: bool

// The frames of this thread's headless window draw nothing.
pixels_skipped :: proc(app: ^App) -> bool { return headless_no_pixels && app.headless }

// Before a frame's submit: with no pixels asked for, the frame is a partial one with a region of nothing, which the renderer
// neither rasterizes nor presents (render/damage.odin). The interface's own partial redraw is off in such a window (frame), so
// nothing adds to that region; the first frame is whole, as every renderer's first frame is.
pixels_skip_frame :: proc(app: ^App) {
	if !pixels_skipped(app) { return }
	draw.set_partial_redraw(&app.dc, true)
	draw.damage_begin(&app.dc)
}
