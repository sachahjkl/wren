package browser

import "core:os"
import "toolkit:draw"
import "toolkit:ui"
import "wb:config"

// Partial redraw (damage regions) for the window. When only a small part of the window changed since the last frame
// (a blinking caret, a hovered control, a progress bar, a <video> in a corner, a local CSS animation), the toolkit can
// repaint and present only the changed rectangles instead of the whole window (toolkit render/damage.odin, draw/damage.odin).
//
// What feeds the damage this frame:
//   * the chrome (tabs, toolbar, dialogs): the UI tree knows which boxes changed (hover, focus, caret, value, running
//     animation); its changed boxes are marked;
//   * the page: the retained-picture compositor (compositor.odin) knows which chunks it recorded again and which items
//     it draws directly (immediate) this frame; the screen bounds of those are the page's damage;
//   * a scrolled view: its rectangle and the pixels it moved by (presented as a block copy where the backend allows).
//
// A frame that marks nothing redraws and presents nothing (the window keeps its pixels; the browser is already at 0 %
// CPU at rest). off: the whole window is drawn and presented every frame, exactly as before.
//
// The preference is browser.gpu.partial_redraw (auto | on | off). auto = on where the backend can present partially
// (Direct3D 11 / DXGI Present1 always; WebGPU through a persistent target). The diagnostic browser.gpu.partial_redraw_verify
// renders every frame in full too and compares (render.damage.verify): for development, it costs a full extra frame.

GPU_PREFS := [?]config.Def{
	{name = "browser.gpu.partial_redraw", kind = .String, default = {s = "auto"}, choices = {"auto", "on", "off"},
		description = "Repaint and present only the parts of the window that changed since the last frame (a caret, a hover, a progress bar, a video, a local animation), instead of the whole window. auto: on where the GPU backend supports it (Direct3D 11 always; WebGPU through a kept render target). on: force it. off: draw and present the whole window every frame (the behaviour before this setting). A frame with nothing changed draws nothing either way."},
	{name = "browser.gpu.partial_redraw_verify", kind = .Bool, default = {b = false},
		description = "For development: render every frame both partially and in full and report the first pixel that differs (a missing damage rectangle). Costs a full extra frame; leave off. The environment variable TOOLKIT_DAMAGE_VERIFY=1 does the same for one run."},
}

register_gpu_prefs :: proc(p: ^config.Prefs) { config.register(p, GPU_PREFS[:]) }

@(private)
Gpu_Settings :: struct {
	partial_redraw: bool,   // resolved from auto | on | off
	verify:         bool,
}

@(private) gpu_settings: Gpu_Settings

// Applies browser.gpu.* to the renderer (apply_prefs). `auto` and `on` turn partial redraw on; the backend falls back
// to a whole frame on its own when it cannot present partially right now (a resize whose buffers lost their content).
gpu_apply_prefs :: proc(app: ^App) {
	p := &app.prefs
	mode := config.string_of(p, "browser.gpu.partial_redraw")
	gpu_settings.partial_redraw = mode != "off"   // auto and on: on (every backend here supports it)
	gpu_settings.verify = config.bool_of(p, "browser.gpu.partial_redraw_verify") || os.get_env("TOOLKIT_DAMAGE_VERIFY", context.temp_allocator) == "1"
	draw.set_partial_redraw(&app.dc, gpu_settings.partial_redraw)
	draw.set_damage_verify(&app.dc, gpu_settings.verify)
}

// Whether partial redraw is on for the window this frame.
partial_redraw_enabled :: proc() -> bool { return gpu_settings.partial_redraw }

// Opens a damage region for the window frame (call right after draw.begin_frame when partial redraw is on). After it,
// the chrome and the page mark their changed boxes with partial_redraw_mark / partial_redraw_scroll; a frame that marks
// nothing redraws and presents nothing.
partial_redraw_frame_begin :: proc(app: ^App) {
	if !gpu_settings.partial_redraw { return }
	draw.damage_begin(&app.dc)
}

// Marks a changed box of the window (screen pixels). A no-op when partial redraw is off.
partial_redraw_mark :: proc(app: ^App, r: draw.Rect) {
	if !gpu_settings.partial_redraw { return }
	draw.damage(&app.dc, r)
}

// Marks a changed box grown by `pad` pixels (a drop shadow, a glow, a focus ring that paints past its element).
partial_redraw_mark_padded :: proc(app: ^App, r: draw.Rect, pad: f32) {
	if !gpu_settings.partial_redraw { return }
	draw.damage_padded(&app.dc, r, pad)
}

// Marks the whole window as changed (a theme change, a resize, the first frame, or anything the damage tracking cannot
// account for): the frame is then a full redraw. Safe to call when partial redraw is off.
partial_redraw_mark_all :: proc(app: ^App) {
	if !gpu_settings.partial_redraw { return }
	s := app.dc.size
	draw.damage(&app.dc, {{0, 0}, s})
}

// The content of `rect` moved by `delta` screen pixels since the last frame (a scrolled view): the backend presents it
// as a block copy where it can. The newly exposed band must still be marked with partial_redraw_mark.
partial_redraw_scroll :: proc(app: ^App, rect: draw.Rect, delta: draw.Vec2) {
	if !gpu_settings.partial_redraw { return }
	draw.damage_scrolled(&app.dc, rect, delta)
}

// Marks the chrome (everything outside the page's rectangle: the tab strip, the toolbar, scroll bars, dialogs) as
// changed. The page's own damage is marked precisely by the compositor (compositor.odin); the chrome does not track
// its damage per widget yet, so it is marked whole here: a chrome-only change (a hovered button, a caret in the URL
// bar) still redraws only the chrome bands, not the page, which is the larger surface. When there is no page the whole
// window is chrome and the frame is a full redraw.
//
// INTEGRATION POINT for the lead: when the UI tree reports the boxes it changed (hover, focus, caret, value, running
// animation), replace this with per-box marking (partial_redraw_mark) so a chrome-only change repaints only that box.
partial_redraw_mark_chrome :: proc(app: ^App) {
	if !gpu_settings.partial_redraw { return }
	wnd := active_window(app)
	s := app.dc.size
	win := draw.Rect{{0, 0}, s}
	pr := wnd.page_rect
	// anything that draws over the page (a menu, a drag image, an autoscroll marker, any overlay not confined to the
	// chrome bands) is not tracked here: mark the whole window so those pixels are always correct.
	if draw.rect_size(pr).x <= 0 || draw.rect_size(pr).y <= 0 || ui.ctx_menu_any_open() || dnd_active() || autoscroll_running_page(app) {
		draw.damage(&app.dc, win)
		return
	}
	// the four bands of chrome around the page rectangle (any may be empty)
	if pr.min.y > 0 { draw.damage(&app.dc, {{0, 0}, {s.x, pr.min.y}}) }                 // top (tabs, toolbar)
	if pr.max.y < s.y { draw.damage(&app.dc, {{0, pr.max.y}, {s.x, s.y}}) }             // bottom (status, find bar)
	if pr.min.x > 0 { draw.damage(&app.dc, {{0, pr.min.y}, {pr.min.x, pr.max.y}}) }     // left
	if pr.max.x < s.x { draw.damage(&app.dc, {{pr.max.x, pr.min.y}, {s.x, pr.max.y}}) } // right
}
