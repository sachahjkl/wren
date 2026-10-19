package browser

// Page zoom, per tab: the page is laid out with `ui.scale() * tab.zoom` device pixels per CSS pixel (its viewport in
// CSS pixels shrinks as the zoom grows, so it reflows, as in Chromium). Ctrl+Plus / Ctrl+Minus step through
// browser.zoom.levels, Ctrl+0 resets, Ctrl+wheel over the page steps too. The browser's own interface keeps its size
// (browser.ui.font_size sets that).

import "toolkit:ui"

// Device pixels per CSS pixel of the current tab's page.
page_scale :: proc(app: ^App) -> f32 {
	z: f32 = 1
	if t := current_tab(app); t != nil && t.zoom > 0 { z = t.zoom }
	return ui.scale() * z
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
	app.frames_requested = max(app.frames_requested, 3)
}

// "110 %" (for the address bar's zoom indicator).
zoom_percent :: proc(t: ^Tab) -> int { return t == nil || t.zoom <= 0 ? 100 : int(t.zoom * 100 + 0.5) }
