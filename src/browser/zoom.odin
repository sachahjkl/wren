package browser

// Page zoom, per tab: the page is laid out with `ui.scale() * tab.zoom` device pixels per CSS pixel (its viewport in
// CSS pixels shrinks as the zoom grows, so it reflows, as in Chromium). Ctrl+Plus / Ctrl+Minus step through
// browser.zoom.levels, Ctrl+0 resets, Ctrl+wheel over the page steps too. The browser's own interface keeps its size
// (browser.ui.font_size sets that).

import "toolkit:ui"

// Device pixels per CSS pixel of the current tab's page: the window's scale (its monitor's: ui_scale_of, at once when the window
// changes monitor, not the scale of the last build) times the tab's zoom. Without a window (a test's App), the toolkit's.
page_scale :: proc(app: ^App) -> f32 {
	z: f32 = 1
	if t := current_tab(app); t != nil && t.zoom > 0 { z = t.zoom }
	if active_window(app).win == nil { return ui.scale() * z }
	return ui_scale_of(app) * z
}

// The tab's document scroll (t.scroll: device pixels) follows its window's scale: a window that changed monitor (WM_DPICHANGED), a
// tab moved to a window on a monitor of another scale, keep the same place of the document (as zoom_set does for the zoom).
// Called at the start of a frame, before the page's input and layout, for the window's current tab.
tab_scale_follow :: proc(app: ^App, t: ^Tab) {
	if t == nil || active_window(app).win == nil { return }
	now := ui_scale_of(app)
	if t.scroll_dpi > 0 && abs(now - t.scroll_dpi) > 1e-4 {
		k := now / t.scroll_dpi
		t.scroll *= k
		clear(&t.smooth.anims)   // (an animation's ends were in the old pixels)
		t.smooth.drag.active = false
		request_frames(app, 2)
	}
	t.scroll_dpi = now
}

zoom_step :: proc(app: ^App, t: ^Tab, dir: int) {
	if t == nil { return }
	cur := t.zoom > 0 ? t.zoom : 1
	next := cur
	if dir > 0 {
		next = ix.zoom_max
		for z in ix.zoom_levels { if z > cur + 0.001 { next = z; break } }
	} else {
		next = ix.zoom_min
		for i := len(ix.zoom_levels) - 1; i >= 0; i -= 1 { if ix.zoom_levels[i] < cur - 0.001 { next = ix.zoom_levels[i]; break } }
	}
	zoom_set(app, t, next)
}

zoom_set :: proc(app: ^App, t: ^Tab, z: f32) {
	if t == nil { return }
	nz := clamp(z, ix.zoom_min, ix.zoom_max)
	if nz == t.zoom { return }
	// keep the same part of the document at the top
	old := t.zoom > 0 ? t.zoom : 1
	t.scroll *= nz / old
	t.zoom = nz
	request_frames(app, 3)
}

// "110 %" (for the address bar's zoom indicator).
zoom_percent :: proc(t: ^Tab) -> int { return t == nil || t.zoom <= 0 ? 100 : int(t.zoom * 100 + 0.5) }
