package browser

// The Fullscreen API in the shell (page/fullscreen.odin keeps the document's side): when the shown tab's document has an
// element in full screen, the window fills the screen like F11 does, with no tabs, address bar, status bar nor find bar
// (and no reveal at the top edge: the page owns the whole window); Escape or F11 leave, as do showing another tab, a
// navigation and closing the tab. The window comes back as it was: a window already in full screen by F11 stays so.

import draw "toolkit:draw"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import "wb:page"

@(private = "file")
Fullscreen_Shell :: struct {
	page_id:    u64,    // the document of the tab in element full screen (0: none)
	tab_id:     u64,
	window_was: bool,   // the window was in full screen (F11) when the page asked
	scroll:     f32,    // the tab's scroll offset then
}

@(private = "file")
fshell: Fullscreen_Shell

// While an element covers the page, the page below is laid out at the window's size and its offset is clamped to that
// document; Blink gives the offset back on exit, and so does this: once the window has its old size again (the first
// frame after leaving still has the full screen's).
@(private = "file")
Scroll_Back :: struct {
	active:  bool,
	tab_id:  u64,
	page_id: u64,
	scroll:  f32,
	w, h:    int,    // the window's size when leaving
	resized: bool,   // the window changes size (it was not in full screen before)
	laid_out: bool,  // the frame after the window got its size has been laid out
	frames:  int,
}

@(private = "file")
sback: Scroll_Back

fullscreen_shell_init :: proc(app: ^App) {
	page.fullscreen_embedder = {set = fullscreen_set, deferred = true}
}

fullscreen_shell_destroy :: proc(app: ^App) {
	page.fullscreen_embedder = {}
	fshell, sback, settle = {}, {}, {}
}

// The events of a change of full screen wait for the page to have been laid out at the window's new size (the page's
// handlers read it, and a player resizes its video from them): the page area changes when the window does, else a
// couple of frames (the interface going or coming), at the latest a second.
@(private = "file")
Settle :: struct {
	armed:   bool,
	page_id: u64,
	tab_id:  u64,
	area:    draw.Vec2,   // the page area when the change began
	changes: bool,        // the window changes size
	frames:  int,
}

@(private = "file")
settle: Settle

@(private = "file")
fullscreen_settle_arm :: proc(app: ^App, top: ^page.Page, tab_id: u64, changes: bool) {
	settle = {armed = true, page_id = page.page_id(top), tab_id = tab_id, area = draw.rect_size(app.page_rect), changes = changes}
}

@(private = "file")
fullscreen_settle_tick :: proc(app: ^App) {
	if !settle.armed { return }
	tab_of: ^Tab
	for tab in app.tabs { if tab.id == settle.tab_id { tab_of = tab; break } }
	if tab_of == nil || tab_of.page == nil || page.page_id(tab_of.page) != settle.page_id || !page.fullscreen_waiting(tab_of.page) {
		settle.armed = false
		return
	}
	settle.frames += 1
	ready := settle.frames >= 60 || (settle.changes ? draw.rect_size(app.page_rect) != settle.area : settle.frames >= 2)
	if !ready { app.frames_requested = max(app.frames_requested, 2); return }
	settle.armed = false
	page.fullscreen_settled(tab_of.page)
	app.frames_requested = max(app.frames_requested, 2)
}

// An element of the shown tab's document is in full screen.
fullscreen_shell_active :: proc() -> bool { return fshell.page_id != 0 }

// page.Fullscreen_Embedder.set
@(private = "file")
fullscreen_set :: proc(top: ^page.Page, on: bool, navigation: page.Api_FullscreenNavigation) -> bool {
	app := the_app
	if app == nil || app.win == nil { return true }
	id := page.page_id(top)
	if on {
		t := current_tab(app)
		if t == nil || t.page != top || t.kind != .Web || id == 0 { return false }
		if fshell.page_id == 0 {
			fshell.window_was = platform.is_fullscreen(app.win)
			if wchrome.cfg.fullscreen_hint { ui.toast(.Info, "Press Esc to exit full screen") }
		}
		if fshell.page_id == 0 { fshell.scroll = t.scroll }
		fshell.page_id, fshell.tab_id = id, t.id
		fullscreen_settle_arm(app, top, t.id, !platform.is_fullscreen(app.win))
		window_fullscreen(app, true)
		return true
	}
	if fshell.page_id == 0 || fshell.page_id != id { return true }   // not this tab's (already left)
	fullscreen_scroll_arm(app)
	fullscreen_settle_arm(app, top, fshell.tab_id, !fshell.window_was)
	fshell.page_id = 0
	if !fshell.window_was { window_fullscreen(app, false) }
	wchrome.revealed = false
	app.frames_requested = max(app.frames_requested, 3)
	return true
}

@(private = "file")
fullscreen_scroll_arm :: proc(app: ^App) {
	sback = {active = true, tab_id = fshell.tab_id, page_id = fshell.page_id, scroll = fshell.scroll, w = int(app.win.size.x), h = int(app.win.size.y), resized = !fshell.window_was}
}

@(private = "file")
fullscreen_scroll_tick :: proc(app: ^App) {
	if !sback.active { return }
	sback.frames += 1
	tab_of: ^Tab
	for tab in app.tabs { if tab.id == sback.tab_id { tab_of = tab; break } }
	if tab_of == nil || tab_of.page == nil || page.page_id(tab_of.page) != sback.page_id || sback.frames > 60 { sback.active = false; return }
	// (the page is laid out at the window's size of the frame before: one frame after the window changed)
	if sback.resized && sback.frames < 30 {
		if int(app.win.size.x) == sback.w && int(app.win.size.y) == sback.h { app.frames_requested = max(app.frames_requested, 2); return }
		if !sback.laid_out { sback.laid_out = true; app.frames_requested = max(app.frames_requested, 2); return }
	}
	smooth_stop(tab_of)
	tab_of.scroll = sback.scroll
	sback.active = false
	app.frames_requested = max(app.frames_requested, 2)
}

@(private = "file")
window_fullscreen :: proc(app: ^App, on: bool) {
	if platform.is_fullscreen(app.win) != on {
		platform.set_fullscreen(app.win, on)
		render.resize(&app.r, app.win.size)
	}
	wchrome.revealed = false
	app.frames_requested = max(app.frames_requested, 3)
}

// Leaves element full screen on the user's behalf (Escape, F11). False when the shown tab has none.
fullscreen_shell_leave :: proc(app: ^App) -> bool {
	if fshell.page_id == 0 { return false }
	t := current_tab(app)
	if t != nil && t.page != nil && page.page_id(t.page) == fshell.page_id && page.fullscreen_exit(t.page) { return true }
	fullscreen_shell_reset(app)   // the document is not there any more: only the window is left to restore
	return true
}

// The Escape key, before the page sees it (browsers keep it for themselves in full screen). True when it was used.
fullscreen_shell_escape :: proc(app: ^App, ev: platform.Event) -> bool {
	return ev.kind == .Key_Press && ev.key == .Escape && fshell.page_id != 0 && fullscreen_shell_leave(app)
}

// Each frame, before the build: the tab that went full screen must still be the shown one with the same document.
fullscreen_shell_frame :: proc(app: ^App) {
	fullscreen_scroll_tick(app)
	fullscreen_settle_tick(app)
	if fshell.page_id == 0 { return }
	t := current_tab(app)
	if t != nil && t.id == fshell.tab_id && t.page != nil && page.page_id(t.page) == fshell.page_id && page.fullscreen_active(t.page) { return }
	// another tab is shown, or the document was replaced, closed or dropped it
	for tab in app.tabs {
		if tab.id == fshell.tab_id && tab.page != nil && page.page_id(tab.page) == fshell.page_id { page.fullscreen_exit(tab.page); break }
	}
	fullscreen_shell_reset(app)
}

@(private = "file")
fullscreen_shell_reset :: proc(app: ^App) {
	if fshell.page_id == 0 { return }
	was := fshell.window_was
	fullscreen_scroll_arm(app)
	fshell = {}
	if !was { window_fullscreen(app, false) }
}
