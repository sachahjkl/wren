package browser

// The Fullscreen API in the shell (page/fullscreen.odin keeps the document's side): when the shown tab's document has an
// element in full screen, the window fills the screen like F11 does, with no tabs, address bar, status bar nor find bar
// (and no reveal at the top edge: the page owns the whole window); Escape or F11 leave, as do showing another tab, a
// navigation and closing the tab. The window comes back as it was: a window already in full screen by F11 stays so.
// A page's full screen is a window's: its state is the window's (Browser_Window.own.fullscreen).

import draw "toolkit:draw"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import "wb:page"

Fullscreen_Shell :: struct {
	page_id:    u64,    // the document of the tab in element full screen (0: none)
	tab_id:     u64,
	window_was: bool,   // the window was in full screen (F11) when the page asked
	scroll:     f32,    // the tab's scroll offset then
}

// While an element covers the page, the page below is laid out at the window's size and its offset is clamped to that
// document; Blink gives the offset back on exit, and so does this: once the window has its old size again (the first
// frame after leaving still has the full screen's).
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

// The events of a change of full screen wait for the page to have been laid out at the window's new size (the page's
// handlers read it, and a player resizes its video from them): the page area changes when the window does, else a
// couple of frames (the interface going or coming), at the latest a second.
Settle :: struct {
	armed:   bool,
	page_id: u64,
	tab_id:  u64,
	area:    draw.Vec2,   // the page area when the change began
	changes: bool,        // the window changes size
	frames:  int,
}

// A window's page full screen.
Window_Fullscreen :: struct {
	shell:  Fullscreen_Shell,
	back:   Scroll_Back,
	settle: Settle,
}

fullscreen_shell_init :: proc(app: ^App) {
	page.fullscreen_embedder = {set = fullscreen_set, deferred = true}
}

fullscreen_shell_destroy :: proc(app: ^App) {
	page.fullscreen_embedder = {}
	for w in app.windows { w.own.fullscreen = {} }
}

@(private = "file")
fullscreen_settle_arm :: proc(app: ^App, fs: ^Window_Fullscreen, top: ^page.Page, tab_id: u64, changes: bool) {
	fs.settle = {armed = true, page_id = page.page_id(top), tab_id = tab_id, area = draw.rect_size(app.page_rect), changes = changes}
}

// Each frame of the window `w` (the active one), before the animation frames: once the page has been laid out for the
// window's new size, the change's events and promise run (then the frame's resize event, which comes after them as in
// other browsers).
fullscreen_shell_settle :: proc(app: ^App, w: ^Browser_Window) {
	if w == nil || !w.own.fullscreen.settle.armed { return }
	settle := &w.own.fullscreen.settle
	tab_of: ^Tab
	for tab in tabs_all(app) { if tab.id == settle.tab_id { tab_of = tab; break } }
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

// An element of the document shown in the window `w` is in full screen.
fullscreen_shell_active :: proc(w: ^Browser_Window) -> bool { return w != nil && w.own.fullscreen.shell.page_id != 0 }

// page.Fullscreen_Embedder.set (the page asks from its script: the window it is shown in is the active one)
@(private = "file")
fullscreen_set :: proc(top: ^page.Page, on: bool, navigation: page.Api_FullscreenNavigation) -> bool {
	app := the_app
	if app == nil || app.win == nil || app.active == nil { return true }
	fs := &app.active.own.fullscreen
	id := page.page_id(top)
	if on {
		t := current_tab(app)
		if t == nil || t.page != top || t.kind != .Web || id == 0 { return false }
		if fs.shell.page_id == 0 {
			fs.shell.window_was = platform.is_fullscreen(app.win)
			if wchrome.cfg.fullscreen_hint { ui.toast(.Info, "Press Esc to exit full screen") }
		}
		if fs.shell.page_id == 0 { fs.shell.scroll = t.scroll }
		fs.shell.page_id, fs.shell.tab_id = id, t.id
		fullscreen_settle_arm(app, fs, top, t.id, !platform.is_fullscreen(app.win))
		window_fullscreen(app, true)
		return true
	}
	if fs.shell.page_id == 0 || fs.shell.page_id != id { return true }   // not this tab's (already left)
	fullscreen_scroll_arm(app, fs)
	fullscreen_settle_arm(app, fs, top, fs.shell.tab_id, !fs.shell.window_was)
	fs.shell.page_id = 0
	if !fs.shell.window_was { window_fullscreen(app, false) }
	app.active.own.full.revealed = false
	app.frames_requested = max(app.frames_requested, 3)
	return true
}

@(private = "file")
fullscreen_scroll_arm :: proc(app: ^App, fs: ^Window_Fullscreen) {
	fs.back = {active = true, tab_id = fs.shell.tab_id, page_id = fs.shell.page_id, scroll = fs.shell.scroll, w = int(app.win.size.x), h = int(app.win.size.y), resized = !fs.shell.window_was}
}

@(private = "file")
fullscreen_scroll_tick :: proc(app: ^App, fs: ^Window_Fullscreen) {
	sback := &fs.back
	if !sback.active { return }
	sback.frames += 1
	tab_of: ^Tab
	for tab in tabs_all(app) { if tab.id == sback.tab_id { tab_of = tab; break } }
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
	window_own(app).full.revealed = false
	app.frames_requested = max(app.frames_requested, 3)
}

// Leaves element full screen on the user's behalf (Escape, F11) in the active window. False when the shown tab has none.
fullscreen_shell_leave :: proc(app: ^App) -> bool {
	w := app.active
	if w == nil || w.own.fullscreen.shell.page_id == 0 { return false }
	t := current_tab(app)
	if t != nil && t.page != nil && page.page_id(t.page) == w.own.fullscreen.shell.page_id && page.fullscreen_exit(t.page) { return true }
	fullscreen_shell_reset(app, &w.own.fullscreen)   // the document is not there any more: only the window is left to restore
	return true
}

// The Escape key, before the page sees it (browsers keep it for themselves in full screen). True when it was used.
fullscreen_shell_escape :: proc(app: ^App, ev: platform.Event) -> bool {
	return ev.kind == .Key_Press && ev.key == .Escape && fullscreen_shell_active(app.active) && fullscreen_shell_leave(app)
}

// Each frame of the window `w` (the active one), before the build: the tab that went full screen must still be the shown
// one with the same document.
fullscreen_shell_frame :: proc(app: ^App, w: ^Browser_Window) {
	if w == nil { return }
	fs := &w.own.fullscreen
	fullscreen_scroll_tick(app, fs)
	if fs.shell.page_id == 0 { return }
	t := current_tab(app)
	if t != nil && t.id == fs.shell.tab_id && t.page != nil && page.page_id(t.page) == fs.shell.page_id && page.fullscreen_active(t.page) { return }
	// another tab is shown, or the document was replaced, closed or dropped it
	for tab in tabs_all(app) {
		if tab.id == fs.shell.tab_id && tab.page != nil && page.page_id(tab.page) == fs.shell.page_id { page.fullscreen_exit(tab.page); break }
	}
	fullscreen_shell_reset(app, fs)
}

@(private = "file")
fullscreen_shell_reset :: proc(app: ^App, fs: ^Window_Fullscreen) {
	if fs.shell.page_id == 0 { return }
	was := fs.shell.window_was
	fullscreen_scroll_arm(app, fs)
	fs.shell = {}
	if !was { window_fullscreen(app, false) }
}
