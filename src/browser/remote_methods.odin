package browser

// The methods of the remote control channel. Names follow the Chrome DevTools Protocol where Wren has the same thing, so a
// CDP or WebDriver BiDi adapter can translate onto them; the others are in the `Wren.` domain. docs/remote.md lists them all
// with their parameters.

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:cookies"
import "wb:fetch"
import "wb:host"
import "wb:httpcache"
import "wb:images"
import lay "wb:layout"
import "wb:page"
import "wb:remote"

ui_toast_remote :: proc(text: string) { ui.toast(.Warn, "%s", text) }
ui_needs_frame :: proc(app: ^App) -> bool { return ui.needs_frame(active_window(app).ui) }
render_capture_busy :: proc() -> bool { return the_app != nil && render.capture_pending(&the_app.r) }

////////////////////////////////
// Dispatch

// Methods that only read: they change nothing on screen, so answering one draws no frame. (Every answer used to ask for two, and the
// task that carried the request counted as work, so a poll of `stats` once a second kept a resting Wren drawing 3 to 8 frames per
// call: the test that asks whether an idle Wren draws read its own question.)
remote_reads_only :: proc(method: string) -> bool {
	switch method {
	case "Remote.ping", "Browser.getVersion", "Browser.getWindowBounds", "Browser.getWindows", "Target.getTargets", "Wren.stats", "Wren.getPref", "Wren.listPrefs", "Wren.listCommands":
		return true
	}
	return false
}

// A call is about one window: `windowId`, else the window of its `tabId`, else the front one (the active one inside the loop).
// The window is made the active one for the length of the call, then the one that was comes back.
remote_dispatch :: proc(app: ^App, c: ^Call) -> Reply {
	target := app.active
	if id, ok := remote.param_int(c.params, "windowId"); ok {
		target = window_by_id(app, id)
		if target == nil { return fail(remote.ERR_PARAMS, fmt.tprintf("no window %d", id)) }
	} else if tid, has := remote.param_int(c.params, "tabId"); has {
		if t := tab_by_id(app, u64(tid)); t != nil { target, _ = window_of_tab(app, t) }
	}
	if target == nil || target == app.active { return remote_dispatch_in_window(app, c) }
	prev := app.active
	window_activate(app, target)
	defer window_activate(app, prev)
	return remote_dispatch_in_window(app, c)
}

@(private = "file")
remote_dispatch_in_window :: proc(app: ^App, c: ^Call) -> Reply {
	switch c.method {
	case "Remote.ping":          return done(fmt.tprintf(`{{"protocol":%d,"version":%s,"pid":%d}}`, remote.PROTOCOL_VERSION, remote.quote(APP_VERSION), win.GetCurrentProcessId()))
	case "Remote.subscribe":     return m_subscribe(app, c, true)
	case "Remote.unsubscribe":   return m_subscribe(app, c, false)
	case "Browser.getVersion":   return done(fmt.tprintf(`{{"product":"Wren/%s","revision":%s,"toolkit":%s,"protocol":%d,"build":%s}}`, APP_VERSION, remote.quote(app_commit()), remote.quote(ui.VERSION), remote.PROTOCOL_VERSION, remote.quote(build_description())))
	case "Browser.close":        return m_close(app, c)
	case "Browser.getWindowBounds": return m_window_get(app)
	case "Browser.setWindowBounds": return m_window_set(app, c)
	case "Browser.getWindows":   return m_windows(app)
	case "Browser.activateWindow": return m_window_activate(app)
	case "Browser.closeWindow":  return m_window_close(app)
	case "Target.moveTarget":    return m_target_move(app, c)
	case "Target.getTargets":    return m_targets(app)
	case "Target.createTarget":  return m_target_create(app, c)
	case "Target.activateTarget": return m_target_activate(app, c)
	case "Target.closeTarget":   return m_target_close(app, c)
	case "Page.navigate":        return m_navigate(app, c)
	case "Page.reload":          return m_reload(app, c)
	case "Page.goBack":          return m_history(app, c, -1)
	case "Page.goForward":       return m_history(app, c, 1)
	case "Page.stopLoading":     return m_stop(app, c)
	case "Page.captureScreenshot": return m_capture(app, c)
	case "Runtime.evaluate":     return m_evaluate(app, c)
	case "DOM.getOuterHTML":     return m_outer_html(app, c)
	case "DOM.querySelectorAll": return m_query_all(app, c)
	case "DOM.getBoxModel":      return m_box_model(app, c)
	case "CSS.getComputedStyleForNode": return m_computed_style(app, c)
	case "Input.dispatchMouseEvent": return m_mouse_event(app, c)
	case "Input.dispatchKeyEvent": return m_key_event(app, c)
	case "Input.insertText":     return m_type(app, c)
	case "Wren.wait":            return m_wait(app, c)
	case "Wren.click":           return m_click(app, c)
	case "Wren.drag":            return m_drag(app, c)
	case "Wren.drop":            return m_drop(app, c)
	case "Wren.type":            return m_type(app, c)
	case "Wren.key":             return m_key(app, c)
	case "Wren.stats":           return m_stats(app, c)
	case "Wren.console":         return m_console(app, c)
	case "Wren.network":         return m_network(app, c)
	case "Wren.getPref":         return m_pref_get(app, c)
	case "Wren.setPref":         return m_pref_set(app, c)
	case "Wren.resetPref":       return m_pref_reset(app, c)
	case "Wren.reset":           return m_reset(app, c)
	case "Wren.checkpoint":      return m_checkpoint(app, c)
	case "Wren.listPrefs":       return m_pref_list(app, c)
	case "Wren.listCommands":    return m_commands(app)
	case "Wren.runCommand":      return m_command(app, c)
	case "Wren.openDevTools":    return m_devtools(app, c)
	case "Wren.openSetup":       setup_open(app, .Command); return done()
	case "Wren.recordInput":     return m_record(app, c)
	case "Wren.replayInput":     return m_replay(app, c)
	case "Wren.snapshot":        return m_snapshot(app, c)
	}
	return fail(remote.ERR_METHOD, fmt.tprintf("unknown method %s", c.method))
}

////////////////////////////////
// Helpers

@(private = "file")
tab_of :: proc(app: ^App, c: ^Call) -> (^Tab, Reply) {
	if id, ok := remote.param_int(c.params, "tabId"); ok {
		if t := tab_by_id(app, u64(id)); t != nil { return t, {} }
		return nil, fail(remote.ERR_PARAMS, fmt.tprintf("no tab %d", id))
	}
	t := current_tab(app)
	if t == nil { return nil, fail(remote.ERR_FAILED, "no tab") }
	return t, {}
}

need_string :: proc(c: ^Call, key: string) -> (string, Reply) {
	s, ok := remote.param_string(c.params, key)
	if !ok { return "", fail(remote.ERR_PARAMS, fmt.tprintf("parameter %q (a string) is missing", key)) }
	return s, {}
}

// Builds a JSON object: j_begin, then j_str / j_int / j_num / j_bool / j_raw (key "" inside an array), then j_end.
j_begin :: proc(b: ^strings.Builder, open: byte = '{') { strings.write_byte(b, open) }
j_end :: proc(b: ^strings.Builder, close: byte = '}') { strings.write_byte(b, close) }
j_key :: proc(b: ^strings.Builder, key: string) {
	s := strings.to_string(b^)
	if len(s) > 0 && s[len(s) - 1] != '{' && s[len(s) - 1] != '[' { strings.write_byte(b, ',') }
	if key != "" { remote.write_json_string(b, key); strings.write_byte(b, ':') }
}
j_str :: proc(b: ^strings.Builder, key, v: string) { j_key(b, key); remote.write_json_string(b, v) }
j_int :: proc(b: ^strings.Builder, key: string, v: i64) { j_key(b, key); fmt.sbprintf(b, "%d", v) }
j_num :: proc(b: ^strings.Builder, key: string, v: f64) { j_key(b, key); fmt.sbprintf(b, "%.3f", v) }
j_bool :: proc(b: ^strings.Builder, key: string, v: bool) { j_key(b, key); strings.write_string(b, v ? "true" : "false") }
j_raw :: proc(b: ^strings.Builder, key, v: string) { j_key(b, key); strings.write_string(b, v) }
j_rect :: proc(b: ^strings.Builder, key: string, r: draw.Rect) {
	j_raw(b, key, fmt.tprintf("[%d,%d,%d,%d]", int(r.min.x), int(r.min.y), int(r.max.x - r.min.x), int(r.max.y - r.min.y)))
}

// Where window `w`'s last frame drew the box `id` built under the box `parent` (window pixels); false: not drawn then.
chrome_box_rect :: proc(w: ^Browser_Window, parent: ui.Key, id: string) -> (r: draw.Rect, ok: bool) {
	if w.ui == nil || parent == 0 { return }
	b, found := w.ui.boxes[ui.key_from_string(parent, id)]
	if !found || b.last_build + 1 < w.ui.build_index { return }
	return b.rect, true
}

builder :: proc() -> strings.Builder { return strings.builder_make(context.temp_allocator) }

// The window rectangle (x, y, w, h) of a laid out element, whether or not it is in view.
element_window_rect :: proc(app: ^App, t: ^Tab, h: base.Handle) -> (rect: [4]f32, ok: bool) {
	wnd := active_window(app)
	if t.page == nil || !t.layout.valid { return {}, false }
	r, found := lay.box_of(&t.layout, h, draw.rect_size(wnd.page_rect), t.scroll)
	if !found { return {}, false }
	b := r.bounds   // where the border box is drawn (its transforms applied)
	// document coordinates, a position: fixed box's too (box_of adds the scroll to the fixed space's)
	x, y := wnd.page_rect.min.x + b.min.x, wnd.page_rect.min.y + b.min.y - t.scroll
	return {x, y, b.max.x - b.min.x, b.max.y - b.min.y}, true
}

// An element with a box that shows at least in part in the page's area.
element_visible :: proc(app: ^App, t: ^Tab, h: base.Handle) -> bool {
	r, ok := element_window_rect(app, t, h)
	if !ok || r[2] <= 0 || r[3] <= 0 { return false }
	pr := active_window(app).page_rect
	return r[0] < pr.max.x && r[0] + r[2] > pr.min.x && r[1] < pr.max.y && r[1] + r[3] > pr.min.y
}

@(private = "file")
frames_op :: proc(app: ^App, c: ^Call, t: ^Tab, n: int, result := "") -> Reply {
	op := op_new(app, c, .Frames, 10_000, "frames")
	op.tab = t != nil ? t.id : 0
	op.until = the_remote.frame_no + u64(max(n, 1))
	op.result = strings.clone(result)
	request_frames(app, 3)
	return Reply{deferred = true}
}

timeout_of :: proc(c: ^Call) -> int {
	ms, _ := remote.param_int(c.params, "timeout")
	return ms
}

////////////////////////////////
// Browser, Remote

@(private = "file")
m_subscribe :: proc(app: ^App, c: ^Call, on: bool) -> Reply {
	r := &the_remote
	for i := len(r.subs) - 1; i >= 0; i -= 1 { if r.subs[i] == c.conn { unordered_remove(&r.subs, i) } }
	if on {
		append(&r.subs, c.conn)
		for t in tabs_all(app) { r.loaded[t.id] = tab_loaded(app, t) }
	}
	return done(`{"events":["Page.loadEventFired","Runtime.consoleAPICalled"]}`)
}

@(private = "file")
m_close :: proc(app: ^App, c: ^Call) -> Reply {
	code, _ := remote.param_int(c.params, "exitCode")
	the_remote.exit_code = code
	the_remote.fast_exit, _ = remote.param_bool(c.params, "fast")
	remote_answer(c.conn, c.id, done())
	remote.close_client(c.conn)
	app.quitting = true
	platform.request_close(active_window(app).win)
	return Reply{deferred = true}
}

window_state :: proc(app: ^App) -> string {
	wnd := active_window(app)
	switch {
	case platform.is_fullscreen(wnd.win): return "fullscreen"
	case platform.is_minimized(wnd.win):  return "minimized"
	case platform.is_maximized(wnd.win):  return "maximized"
	}
	return "normal"
}

@(private = "file")
m_window_get :: proc(app: ^App) -> Reply {
	wnd := active_window(app)
	rc: win.RECT
	win.GetWindowRect(wnd.win.hwnd, &rc)
	b := builder()
	j_begin(&b)
	j_int(&b, "windowId", i64(app.active.id))
	j_int(&b, "left", i64(rc.left)); j_int(&b, "top", i64(rc.top))
	j_int(&b, "outerWidth", i64(rc.right - rc.left)); j_int(&b, "outerHeight", i64(rc.bottom - rc.top))
	j_int(&b, "width", i64(wnd.win.size.x)); j_int(&b, "height", i64(wnd.win.size.y))   // the client area, in pixels
	j_str(&b, "windowState", window_state(app))
	j_num(&b, "dpiScale", f64(wnd.win.dpi_scale)); j_num(&b, "uiScale", f64(ui_scale_of(app))); j_num(&b, "pageScale", f64(page_scale(app)))
	j_bool(&b, "visible", bool(win.IsWindowVisible(wnd.win.hwnd)))
	// the page area of its last frame and what was prepared for it (page_frame.odin)
	j_rect(&b, "pageRect", wnd.page_rect)
	PREP_NAMES := [Page_Prep_State]string{.None = "none", .Hold = "hold", .Ready = "ready"}
	j_str(&b, "pagePrep", PREP_NAMES[wnd.own.page_prep.state])
	j_end(&b)
	return done(strings.to_string(b))
}

// width / height: the client area in pixels (what a capture of the window measures); left / top: the window's corner.
@(private = "file")
m_window_set :: proc(app: ^App, c: ^Call) -> Reply {
	state, has_state := remote.param_string(c.params, "windowState")
	if has_state {
		switch state {
		case "normal", "minimized", "maximized", "fullscreen":
		case: return fail(remote.ERR_PARAMS, "windowState: normal, minimized, maximized or fullscreen")
		}
	}
	w, has_w := remote.param_int(c.params, "width")
	h, has_h := remote.param_int(c.params, "height")
	left, has_l := remote.param_int(c.params, "left")
	top, has_t := remote.param_int(c.params, "top")
	window_apply(app, state, has_state, w, h, left, top, has_w, has_h, has_l, has_t)
	if dpi, has_dpi := remote.param_int(c.params, "dpi"); has_dpi {
		if dpi < 48 || dpi > 960 { return fail(remote.ERR_PARAMS, "dpi: 48 to 960 (96 = 100 %)") }
		window_simulate_dpi(app, active_window(app), dpi)
	}
	return m_window_get(app)
}

// The window as if it had moved to a monitor of `dpi`: the system's WM_DPICHANGED, with the rectangle the system suggests (the same
// top left, the size in proportion), through the window procedure as the real one goes (wren ctl window --dpi n: a machine with
// one monitor tests a window that changes monitors, and two windows on monitors of different scales).
window_simulate_dpi :: proc(app: ^App, w: ^Browser_Window, dpi: int) {
	hwnd := w.win.hwnd
	rc: win.RECT
	win.GetWindowRect(hwnd, &rc)
	old := max(w.win.dpi_scale, 0.25) * 96
	k := f32(dpi) / old
	r := win.RECT{rc.left, rc.top, rc.left + i32(f32(rc.right - rc.left) * k + 0.5), rc.top + i32(f32(rc.bottom - rc.top) * k + 0.5)}
	win.SendMessageW(hwnd, win.WM_DPICHANGED, win.WPARAM(uint(dpi) | uint(dpi) << 16), win.LPARAM(uintptr(&r)))
	window_request(app, w, 4)
}

// The window's state and rectangle as asked (the parts that are not asked for stay): `Browser.setWindowBounds`, and the reset and
// the checkpoints of remote_state.odin.
window_apply :: proc(app: ^App, state: string, has_state: bool, w, h, left, top: int, has_w, has_h, has_l, has_t: bool) {
	wnd := active_window(app)
	hwnd := wnd.win.hwnd
	if has_state {
		switch state {
		case "normal":
			if platform.is_fullscreen(wnd.win) { toggle_fullscreen(app) }
			win.ShowWindow(hwnd, win.SW_SHOWNOACTIVATE)
			if platform.is_maximized(wnd.win) || platform.is_minimized(wnd.win) { win.ShowWindow(hwnd, win.SW_RESTORE) }
		case "minimized":  win.ShowWindow(hwnd, win.SW_SHOWMINNOACTIVE)
		case "maximized":  win.ShowWindow(hwnd, win.SW_SHOWMAXIMIZED)
		case "fullscreen": if !platform.is_fullscreen(wnd.win) { toggle_fullscreen(app) }
		}
	}
	if has_w || has_h || has_l || has_t {
		rc: win.RECT
		win.GetWindowRect(hwnd, &rc)
		dpi := win.GetDpiForWindow(hwnd)
		cw, ch := has_w ? w : wnd.win.size.x, has_h ? h : wnd.win.size.y
		frame := win.RECT{0, 0, i32(max(cw, 1)), i32(max(ch, 1))}
		win.AdjustWindowRectExForDpi(&frame, win.WS_OVERLAPPEDWINDOW, false, 0, dpi)
		if platform.is_integrated_title(wnd.win) { frame.top = 0 }
		flags: win.UINT = win.SWP_NOZORDER | win.SWP_NOACTIVATE
		if !(has_w || has_h) { flags |= win.SWP_NOSIZE }
		if !(has_l || has_t) { flags |= win.SWP_NOMOVE }
		win.SetWindowPos(hwnd, nil, i32(has_l ? left : int(rc.left)), i32(has_t ? top : int(rc.top)), frame.right - frame.left, frame.bottom - frame.top, flags)
	}
	request_frames(app, 4)
}

////////////////////////////////
// Targets (tabs)

@(private = "file")
m_targets :: proc(app: ^App) -> Reply {
	b := builder()
	j_begin(&b)
	j_key(&b, "targetInfos"); j_begin(&b, '[')
	for w in app.windows {
		for t, i in window_tabs(app, w)^ {
			if t.frame != nil { continue }
			j_key(&b, ""); j_begin(&b)
			j_int(&b, "targetId", i64(t.id)); j_str(&b, "type", "page"); j_str(&b, "title", t.title); j_str(&b, "url", t.url)
			j_int(&b, "windowId", i64(w.id))
			j_bool(&b, "active", i == window_current(app, w)^); j_bool(&b, "loading", !tab_loaded(app, t)); j_bool(&b, "attached", true)
			// the sidebar's state of the tab (tab_groups.odin), and where the last frame drew it in the tab bar
			j_bool(&b, "pinned", t.pinned); j_int(&b, "group", i64(t.group))
			j_bool(&b, "playing", t.sound.playing); j_bool(&b, "audible", tab_speaker(app, t) == .Sound); j_bool(&b, "muted", t.muted)   // tab_sound.odin
			if gi := group_index(w.groups[:], t.group); gi >= 0 {
				g := w.groups[gi]
				j_str(&b, "groupName", g.name); j_str(&b, "groupColor", GROUP_COLOR_NAMES[g.color]); j_bool(&b, "groupCollapsed", g.collapsed)
			}
			id := fmt.tprintf("###tab_%d", t.id)
			if r, ok := chrome_box_rect(w, t.pinned && favs.cfg.position != .Top ? w.own.sidebar.pins_key : w.own.strip.area_key, id); ok { j_rect(&b, "rect", r) }
			j_end(&b)
		}
	}
	j_end(&b, ']')
	j_key(&b, "tabGroups"); j_begin(&b, '[')
	for w in app.windows {
		for g in w.groups {
			j_key(&b, ""); j_begin(&b)
			j_int(&b, "windowId", i64(w.id)); j_int(&b, "id", i64(g.id)); j_str(&b, "name", g.name)
			j_str(&b, "color", GROUP_COLOR_NAMES[g.color]); j_bool(&b, "collapsed", g.collapsed)
			if r, ok := chrome_box_rect(w, w.own.strip.area_key, fmt.tprintf("###grp_%d", g.id)); ok { j_rect(&b, "rect", r) }
			j_end(&b)
		}
	}
	j_end(&b, ']'); j_end(&b)
	return done(strings.to_string(b))
}

@(private = "file")
m_target_create :: proc(app: ^App, c: ^Call) -> Reply {
	wnd := active_window(app)
	address, _ := remote.param_string(c.params, "url")
	background, _ := remote.param_bool(c.params, "background")
	was := wnd.current
	t := tab_open(app, address, origin = .User)
	if background && was >= 0 && was < len(wnd.tabs) - 1 {
		wnd.current = was
		if cur := current_tab(app); cur != nil { ui.field_set(&wnd.address, cur.url) }
	}
	if wait, ok := remote.param_string(c.params, "wait"); ok && wait != "none" && wait != "" { return start_wait(app, c, t, wait, fmt.tprintf(`{{"targetId":%d}}`, t.id)) }
	return done(fmt.tprintf(`{{"targetId":%d}}`, t.id))
}

// The windows: id, whether it is the front one, its tabs and the current one, its size and state.
@(private = "file")
m_windows :: proc(app: ^App) -> Reply {
	b := builder()
	j_begin(&b)
	j_key(&b, "windows"); j_begin(&b, '[')
	for w in app.windows {
		rc: win.RECT
		win.GetWindowRect(w.win.hwnd, &rc)
		j_key(&b, ""); j_begin(&b)
		j_int(&b, "windowId", i64(w.id)); j_bool(&b, "front", w == window_front(app)); j_int(&b, "tabs", i64(len(window_tabs(app, w))))
		j_int(&b, "hwnd", i64(uintptr(w.win.hwnd)))   // (a UI Automation client reads one window: tools\a11y_e2e.ps1)
		cur := window_current_tab(app, w)
		j_int(&b, "currentTabId", cur != nil ? i64(cur.id) : 0)
		j_int(&b, "left", i64(rc.left)); j_int(&b, "top", i64(rc.top)); j_int(&b, "width", i64(w.win.size.x)); j_int(&b, "height", i64(w.win.size.y))
		j_str(&b, "windowState", platform.is_fullscreen(w.win) ? "fullscreen" : platform.is_minimized(w.win) ? "minimized" : platform.is_maximized(w.win) ? "maximized" : "normal")
		j_num(&b, "dpiScale", f64(w.win.dpi_scale))
		co := platform.client_origin(w.win)
		j_int(&b, "clientLeft", i64(co[0])); j_int(&b, "clientTop", i64(co[1]))   // (where its client area is on the screen)
		// a tab carried over its tabs (tab_drag.odin): where it would go and where the mark is (client pixels, along the tabs)
		if w.dropping {
			z := w.zone
			j_key(&b, "drop"); j_begin(&b)
			j_int(&b, "index", i64(w.drop.index)); j_int(&b, "group", i64(w.drop.group)); j_bool(&b, "pinned", w.drop.pinned)
			j_num(&b, "mark", f64((z.vertical ? z.rect.min.y : z.rect.min.x) + w.drop.mark - z.offset))
			j_end(&b)
		}
		// its developer tools (devtools.odin: each window has its own)
		d := &w.own.devtools
		j_key(&b, "devtools"); j_begin(&b)
		j_bool(&b, "visible", d.visible); j_str(&b, "dock", DEV_DOCK_NAMES[d.dock]); j_str(&b, "panel", DEV_PANEL_NAMES[d.panel])
		j_bool(&b, "detached", d.win != nil || d.want_win)
		if d.win != nil {
			j_int(&b, "hwnd", i64(uintptr(d.win.win.hwnd))); j_str(&b, "title", d.win.title)
			j_num(&b, "dpiScale", f64(d.win.win.dpi_scale))
		}
		j_end(&b)
		j_end(&b)
	}
	j_end(&b, ']'); j_end(&b)
	return done(strings.to_string(b))
}

// The window becomes the front one: what the calls without a window act on.
@(private = "file")
m_window_activate :: proc(app: ^App) -> Reply {
	window_focus(app, app.active)
	// above the others (without taking the system's focus, shown or not): a drag across windows finds it on top
	win.SetWindowPos(app.active.win.hwnd, win.HWND_TOP, 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOACTIVATE)
	return done()
}

// The window closes with its tabs, at the end of the pass (the last window ends the browser: that is Browser.close).
@(private = "file")
m_window_close :: proc(app: ^App) -> Reply {
	if len(app.windows) <= 1 { return fail(remote.ERR_FAILED, "this is the only window: Browser.close ends the browser") }
	app.active.closing, app.active.closing_force = true, true
	return done()
}

// Target.moveTarget {targetId, to: "new" | a window id, index}: the tab goes to another window with its page as it is.
@(private = "file")
m_target_move :: proc(app: ^App, c: ^Call) -> Reply {
	id, ok := remote.param_int(c.params, "targetId")
	if !ok { return fail(remote.ERR_PARAMS, "parameter \"targetId\" is missing") }
	t := tab_by_id(app, u64(id))
	if t == nil { return fail(remote.ERR_PARAMS, fmt.tprintf("no tab %d", id)) }
	at := -1
	if v, has := remote.param_int(c.params, "index"); has { at = v }
	dest: ^Browser_Window
	if to, is_str := remote.param_string(c.params, "to"); is_str {
		if to != "new" { return fail(remote.ERR_PARAMS, "\"to\" is \"new\" or a window id") }
		dest = tab_detach(app, t)
		if dest == nil { return fail(remote.ERR_FAILED, "the tab is alone in its window (or the window could not be made)") }
	} else if wid, is_int := remote.param_int(c.params, "to"); is_int {
		dest = window_by_id(app, wid)
		if dest == nil { return fail(remote.ERR_PARAMS, fmt.tprintf("no window %d", wid)) }
		tab_move(app, t, dest, at)
	} else {
		return fail(remote.ERR_PARAMS, "parameter \"to\" is missing")
	}
	windows_spill(app, 3)
	return done(fmt.tprintf(`{{"targetId":%d,"windowId":%d}}`, t.id, dest.id))
}

@(private = "file")
m_target_activate :: proc(app: ^App, c: ^Call) -> Reply {
	id, ok := remote.param_int(c.params, "targetId")
	if !ok { return fail(remote.ERR_PARAMS, "parameter \"targetId\" is missing") }
	if t := tab_by_id(app, u64(id)); t != nil {
		tab_reveal(app, t)
		windows_spill(app, 3)
		request_frames(app, 3)
		return done()
	}
	return fail(remote.ERR_PARAMS, fmt.tprintf("no tab %d", id))
}

@(private = "file")
m_target_close :: proc(app: ^App, c: ^Call) -> Reply {
	id, ok := remote.param_int(c.params, "targetId")
	if !ok { return fail(remote.ERR_PARAMS, "parameter \"targetId\" is missing") }
	if t := tab_by_id(app, u64(id)); t != nil { tab_close_tab(app, t); return done(`{"success":true}`) }
	return fail(remote.ERR_PARAMS, fmt.tprintf("no tab %d", id))
}

////////////////////////////////
// Navigation and waiting

// A wait of kind `what` ("load", "idle", "stable") on `t`, answered with `result` (JSON) when it holds.
start_wait :: proc(app: ^App, c: ^Call, t: ^Tab, what: string, result := "") -> Reply {
	kind: Remote_Wait
	switch what {
	case "load":   kind = .Load
	case "idle":   kind = .Idle
	case "stable": kind = .Stable
	case "quiet":  kind = .Quiet
	case "none", "": return done(result == "" ? "{}" : result)
	case: return fail(remote.ERR_PARAMS, "wait: none, load, idle, stable or quiet")
	}
	op := op_new(app, c, .Wait, timeout_of(c), what)
	op.tab, op.wait = t.id, kind
	op.idle_ms, _ = remote.param_int(c.params, "idleMs")   // 0: browser.remote.idle_ms
	if kind == .Quiet {
		// (the window starts at the first look: a wait that begins in the middle of work does not count the work)
		op.quiet_ms, _ = remote.param_int(c.params, "quietMs", the_remote.cfg.quiet_ms)
		op.max_cpu, _ = remote.param_float(c.params, "maxCpuMs", f64(the_remote.cfg.quiet_cpu_ms))
		op.t0 = host.now_ns(&app.loop)
		op.cpu0, _, _ = process_cpu_ms()
	}
	op.result = strings.clone(result)
	return Reply{deferred = true}
}

@(private = "file")
m_navigate :: proc(app: ^App, c: ^Call) -> Reply {
	address, bad := need_string(c, "url")
	if bad.code != 0 { return bad }
	t, e := tab_of(app, c)
	if t == nil { return e }
	navigate(app, t, address, origin = .User)
	request_frames(app, 3)
	what, _ := remote.param_string(c.params, "wait")
	return start_wait(app, c, t, what, fmt.tprintf(`{{"tabId":%d,"url":%s}}`, t.id, remote.quote(t.url)))
}

@(private = "file")
m_reload :: proc(app: ^App, c: ^Call) -> Reply {
	t, e := tab_of(app, c)
	if t == nil { return e }
	ignore, _ := remote.param_bool(c.params, "ignoreCache")
	reload(app, t, ignore)
	what, _ := remote.param_string(c.params, "wait")
	return start_wait(app, c, t, what, fmt.tprintf(`{{"tabId":%d}}`, t.id))
}

@(private = "file")
m_history :: proc(app: ^App, c: ^Call, delta: int) -> Reply {
	t, e := tab_of(app, c)
	if t == nil { return e }
	go_history(app, t, delta)
	what, _ := remote.param_string(c.params, "wait")
	return start_wait(app, c, t, what, fmt.tprintf(`{{"tabId":%d}}`, t.id))
}

@(private = "file")
m_stop :: proc(app: ^App, c: ^Call) -> Reply {
	t, e := tab_of(app, c)
	if t == nil { return e }
	stop_loading(app, t)
	return done()
}

// Wren.wait {for: load|idle|stable|selector|function, selector, expression, visible, timeout}
@(private = "file")
m_wait :: proc(app: ^App, c: ^Call) -> Reply {
	t, e := tab_of(app, c)
	if t == nil { return e }
	what, _ := remote.param_string(c.params, "for", "load")
	switch what {
	case "selector":
		sel, bad := need_string(c, "selector")
		if bad.code != 0 { return bad }
		op := op_new(app, c, .Wait, timeout_of(c), fmt.tprintf("an element matching %s", sel))
		op.tab, op.wait, op.arg = t.id, .Selector, strings.clone(sel)
		op.visible, _ = remote.param_bool(c.params, "visible")
		return Reply{deferred = true}
	case "function":
		expr, bad := need_string(c, "expression")
		if bad.code != 0 { return bad }
		op := op_new(app, c, .Wait, timeout_of(c), "the script condition to hold")
		op.tab, op.wait, op.arg = t.id, .Function, strings.clone(expr)
		return Reply{deferred = true}
	case "frames":
		n, _ := remote.param_int(c.params, "frames", 2)
		return frames_op(app, c, t, n)
	}
	rep := start_wait(app, c, t, what)
	return rep
}

////////////////////////////////
// Script and the document

@(private = "file")
m_evaluate :: proc(app: ^App, c: ^Call) -> Reply {
	expr, bad := need_string(c, "expression")
	if bad.code != 0 { return bad }
	t, e := tab_of(app, c)
	if t == nil { return e }
	await, _ := remote.param_bool(c.params, "awaitPromise")
	r := &the_remote
	delete(r.stash_text); r.stash_text, r.stash_id = "", 0
	id, ran := eval_start(t, expr, await)
	if !ran { return fail(remote.ERR_FAILED, "the tab has no page, or JavaScript is off for it (javascript.* preferences)") }
	if r.stash_id == id {
		rep := eval_reply_text(r.stash_text)
		delete(r.stash_text); r.stash_text, r.stash_id = "", 0
		return rep
	}
	op := op_new(app, c, .Eval, timeout_of(c), "script")
	op.eval_id, op.tab = id, t.id   // (its answer counts from this tab only)
	return Reply{deferred = true}
}

@(private = "file")
m_outer_html :: proc(app: ^App, c: ^Call) -> Reply {
	t, e := tab_of(app, c)
	if t == nil { return e }
	if t.page == nil { return fail(remote.ERR_FAILED, "the tab has no document") }
	h := t.page.doc.root
	if sel, ok := remote.param_string(c.params, "selector"); ok {
		found, valid := page.query_first(t.page, sel)
		if !valid { return fail(remote.ERR_PARAMS, fmt.tprintf("invalid selector %q", sel)) }
		if found == base.NIL_HANDLE { return fail(remote.ERR_FAILED, fmt.tprintf("no element matches %q", sel)) }
		h = found
	}
	html := page.serialize_html(t.page.doc, h, true)
	return done(fmt.tprintf(`{{"outerHTML":%s}}`, remote.quote(html)))
}

@(private = "file")
m_query_all :: proc(app: ^App, c: ^Call) -> Reply {
	wnd := active_window(app)
	sel, bad := need_string(c, "selector")
	if bad.code != 0 { return bad }
	t, e := tab_of(app, c)
	if t == nil { return e }
	if t.page == nil { return fail(remote.ERR_FAILED, "the tab has no document") }
	limit, _ := remote.param_int(c.params, "limit", 100)
	hs, valid := page.query_all(t.page, sel, limit)
	if !valid { return fail(remote.ERR_PARAMS, fmt.tprintf("invalid selector %q", sel)) }
	all, _ := page.query_all(t.page, sel)
	b := builder()
	j_begin(&b)
	j_int(&b, "count", i64(len(all)))
	j_key(&b, "nodes"); j_begin(&b, '[')
	for h in hs {
		j_key(&b, ""); j_begin(&b)
		html := page.serialize_html(t.page.doc, h, true)
		j_str(&b, "outerHTML", html[:min(len(html), 300)])
		if r, ok := element_window_rect(app, t, h); ok {
			s := f64(page_scale(app))
			j_raw(&b, "box", fmt.tprintf("[%.2f,%.2f,%.2f,%.2f]", f64(r[0] - wnd.page_rect.min.x) / s, f64(r[1] - wnd.page_rect.min.y) / s, f64(r[2]) / s, f64(r[3]) / s))
		}
		j_end(&b)
	}
	j_end(&b, ']'); j_end(&b)
	return done(strings.to_string(b))
}

// The element's box: in CSS pixels from the page's top-left corner (what getBoundingClientRect says), and in window pixels.
@(private = "file")
m_box_model :: proc(app: ^App, c: ^Call) -> Reply {
	wnd := active_window(app)
	sel, bad := need_string(c, "selector")
	if bad.code != 0 { return bad }
	t, e := tab_of(app, c)
	if t == nil { return e }
	h, valid := page.query_first(t.page, sel)
	if !valid { return fail(remote.ERR_PARAMS, fmt.tprintf("invalid selector %q", sel)) }
	if h == base.NIL_HANDLE { return fail(remote.ERR_FAILED, fmt.tprintf("no element matches %q", sel)) }
	r, ok := element_window_rect(app, t, h)
	if !ok { return fail(remote.ERR_FAILED, "the element has no box (display: none, or the layout is not made yet)") }
	s := f64(page_scale(app))
	return done(fmt.tprintf(`{{"found":true,"visible":%v,"x":%.2f,"y":%.2f,"width":%.2f,"height":%.2f,"window":{{"x":%.1f,"y":%.1f,"width":%.1f,"height":%.1f}}}}`,
		element_visible(app, t, h), f64(r[0] - wnd.page_rect.min.x) / s, f64(r[1] - wnd.page_rect.min.y) / s, f64(r[2]) / s, f64(r[3]) / s, r[0], r[1], r[2], r[3]))
}

@(private = "file")
m_computed_style :: proc(app: ^App, c: ^Call) -> Reply {
	sel, bad := need_string(c, "selector")
	if bad.code != 0 { return bad }
	t, e := tab_of(app, c)
	if t == nil { return e }
	props := "null"
	if arr, ok := remote.param_array(c.params, "properties"); ok {
		b := builder()
		j_begin(&b, '[')
		for v in arr { if s, is_s := v.(json.String); is_s { j_str(&b, "", string(s)) } }
		j_end(&b, ']')
		props = strings.to_string(b)
	}
	expr := fmt.tprintf(`(function(S,P){{var e=document.querySelector(S);if(!e)return null;var c=getComputedStyle(e),o={{}};if(P){{for(var i=0;i<P.length;i++)o[P[i]]=c.getPropertyValue(P[i])}}else{{for(var i=0;i<c.length;i++){{var n=c[i];o[n]=c.getPropertyValue(n)}}}}return o}})(%s,%s)`, remote.quote(sel), props)
	v, _, err := eval_sync(t, expr)
	if err != "" { return fail(remote.ERR_FAILED, err) }
	if v == "null" { return fail(remote.ERR_FAILED, fmt.tprintf("no element matches %q", sel)) }
	return done(fmt.tprintf(`{{"computedStyle":%s}}`, v))
}

////////////////////////////////
// Capture

// Page.captureScreenshot {path, bytes, target: window|page|rect|selector, selector, clip {x,y,width,height} (window pixels, target
// rect), scale, settle (frames), timeout}
m_capture :: proc(app: ^App, c: ^Call) -> Reply {
	t, e := tab_of(app, c)
	if t == nil { return e }
	op := op_new(app, c, .Capture, timeout_of(c), "the capture")
	op.tab = t.id
	op.scale = 1
	if s, ok := remote.param_float(c.params, "scale"); ok && s > 0 { op.scale = f32(clamp(s, 0.01, 16)) }
	if p, ok := remote.param_string(c.params, "path"); ok { op.path = strings.clone(p) }
	op.bytes, _ = remote.param_bool(c.params, "bytes")
	if op.path == "" { op.bytes = true }
	tgt, _ := remote.param_string(c.params, "target", "window")
	switch tgt {
	case "window": op.target = .Window
	case "page":   op.target = .Page
	case "rect":
		op.target = .Rect
		clip, ok := remote.param_object(c.params, "clip")
		if !ok { op_finish(op, fail(remote.ERR_PARAMS, "target rect needs \"clip\": {x, y, width, height}")); return Reply{deferred = true} }
		x, _ := remote.param_float(clip, "x"); y, _ := remote.param_float(clip, "y")
		w, _ := remote.param_float(clip, "width"); h, _ := remote.param_float(clip, "height")
		op.rect = {f32(x), f32(y), f32(w), f32(h)}
	case "selector":
		op.target = .Selector
		sel, bad := need_string(c, "selector")
		if bad.code != 0 { op_finish(op, bad); return Reply{deferred = true} }
		op.arg = strings.clone(sel)
	case:
		op_finish(op, fail(remote.ERR_PARAMS, "target: window, page, rect or selector"))
		return Reply{deferred = true}
	}
	settle, has := remote.param_int(c.params, "settle")
	if !has { settle = the_remote.cfg.settle_frames }
	op.until = the_remote.frame_no + u64(max(settle, 0)) + 1
	// a window on the taskbar draws nothing: it comes back without taking the focus, and goes back after
	if platform.is_minimized(active_window(app).win) {
		win.ShowWindow(active_window(app).win.hwnd, win.SW_SHOWNOACTIVATE)
		op.stage = -1
	}
	request_frames(app, 3)
	return Reply{deferred = true}
}

capture_step :: proc(app: ^App, op: ^Remote_Op, t: ^Tab, timed_out: bool) {
	r := &the_remote
	finish :: proc(app: ^App, op: ^Remote_Op, rep: Reply) {
		if op.stage == -2 { win.ShowWindow(active_window(app).win.hwnd, win.SW_SHOWMINNOACTIVE) }
		if op.asked && rep.code != 0 { render.capture_cancel(&app.r) }   // (asked, not taken: the next capture may start)
		if op.asked { the_remote.capture_window = 0 }
		op_finish(op, rep)
	}
	if op.stage < 0 && op.stage != -2 { op.stage = -2 }   // (restored for this capture: minimized again at the end)
	if op.stage == -2 || op.stage == 0 {
		request_frames(app, 2)
		if r.frame_no < op.until || render.capture_pending(&app.r) || r.capture_window != 0 {
			if timed_out { finish(app, op, fail(remote.ERR_TIMEOUT, "timed out before the frame to capture was drawn (is the window hidden or minimized?)")) }
			return
		}
		rect: [4]int
		pr := active_window(app).page_rect
		switch op.target {
		case .Window:
		case .Page: rect = {int(pr.min.x), int(pr.min.y), int(pr.max.x - pr.min.x), int(pr.max.y - pr.min.y)}
		case .Rect: rect = {int(op.rect[0]), int(op.rect[1]), int(op.rect[2]), int(op.rect[3])}
		case .Selector:
			h, valid := page.query_first(t.page, op.arg)
			if !valid { finish(app, op, fail(remote.ERR_PARAMS, fmt.tprintf("invalid selector %q", op.arg))); return }
			if h == base.NIL_HANDLE { finish(app, op, fail(remote.ERR_FAILED, fmt.tprintf("no element matches %q", op.arg))); return }
			er, ok := element_window_rect(app, t, h)
			if !ok { finish(app, op, fail(remote.ERR_FAILED, "the element has no box")); return }
			if !op.scrolled && (er[1] < pr.min.y || er[1] + er[3] > pr.max.y) {
				// not all of it in view: scrolled to (its top for an element taller than the view, else its middle), then looked at again
				op.scrolled = true
				doc_top := er[1] - pr.min.y + t.scroll
				view := pr.max.y - pr.min.y
				scroll_document_to(app, t, max(er[3] > view ? doc_top : doc_top + er[3] / 2 - view / 2, 0), false)
				op.until = r.frame_no + 2
				return
			}
			x0, y0 := max(er[0], pr.min.x), max(er[1], pr.min.y)
			x1, y1 := min(er[0] + er[2], pr.max.x), min(er[1] + er[3], pr.max.y)
			if x1 <= x0 || y1 <= y0 { finish(app, op, fail(remote.ERR_FAILED, "the element is outside the page's visible area (scroll to it first)")); return }
			rect = {int(math.floor(x0)), int(math.floor(y0)), int(math.ceil(x1 - x0)), int(math.ceil(y1 - y0))}
		}
		when render.USE_WGPU { finish(app, op, fail(remote.ERR_FAILED, "this renderer cannot capture its frame (the wgpu backend)")); return }
		// the renderer copies the next frame it ends, whichever window's: asked for in this window's own frame (remote_capture_arm)
		r.capture_window, r.capture_rect = active_window(app).id, rect
		op.asked = true
		op.stage = op.stage == -2 ? 3 : 1
		request_frames(app, 2)
		return
	}
	// 1 (or 3: to be minimized again): the copy is made when the frame ends; the GPU reads it a moment later
	request_frames(app, 2)
	pixels, size, st := render.capture_poll(&app.r, context.allocator)
	if op.stage == 3 { op.stage = -2 }   // (finish() looks for -2)
	switch st {
	case .None, .Pending:
		if timed_out { finish(app, op, fail(remote.ERR_TIMEOUT, "timed out waiting for the frame's pixels")); return }
		if op.stage == -2 && (st == .Pending || r.capture_window != 0) { op.stage = 3 }   // (asked, its frame not drawn yet: remote_capture_arm)
	case .Failed: finish(app, op, fail(remote.ERR_FAILED, "the frame could not be read back (device lost, or an empty area)"))
	case .Ready:
		defer delete(pixels)
		rep := capture_reply(op, pixels, size)
		if rep.code == 0 && op.snapshot != "" { if msg := snapshot_files(app, t, op.snapshot); msg != "" { rep = fail(remote.ERR_FAILED, msg) } }
		finish(app, op, rep)
	}
}

capture_reply :: proc(op: ^Remote_Op, pixels: []u8, size: [2]int) -> Reply {
	w, h := size.x, size.y
	rgba := pixels
	if op.scale != 1 {
		rgba, w, h = scale_rgba(pixels, size.x, size.y, op.scale)
	}
	defer if op.scale != 1 { delete(rgba) }   // (not in the block above: a defer runs where its block ends, before the picture is encoded)
	png, ok := images.encode_rgba(rgba, w, h, .Png, 0, false)
	if !ok { return fail(remote.ERR_FAILED, "the PNG could not be written") }
	defer delete(png)
	b := builder()
	j_begin(&b)
	if op.path != "" {
		if i := strings.last_index_any(op.path, "\\/"); i > 0 { _ = os.make_directory_all(op.path[:i]) }
		if err := os.write_entire_file(op.path, png); err != nil { return fail(remote.ERR_FAILED, fmt.tprintf("cannot write %s", op.path)) }
		j_str(&b, "path", op.path)
	}
	j_int(&b, "width", i64(w)); j_int(&b, "height", i64(h)); j_int(&b, "size", i64(len(png)))
	if op.bytes {
		enc, _ := base64.encode(png, allocator = context.temp_allocator)
		j_str(&b, "data", enc)
	}
	j_end(&b)
	return done(strings.to_string(b))
}

// `scale` of the picture, by averaging the source pixels each new one covers (nearest when it grows).
scale_rgba :: proc(src: []u8, w, h: int, scale: f32) -> (out: []u8, nw, nh: int) {
	nw, nh = max(int(f32(w) * scale + 0.5), 1), max(int(f32(h) * scale + 0.5), 1)
	out = make([]u8, nw * nh * 4)
	for y in 0 ..< nh {
		sy0 := min(int(f32(y) / scale), h - 1)
		sy1 := clamp(int(math.ceil(f32(y + 1) / scale)), sy0 + 1, h)
		for x in 0 ..< nw {
			sx0 := min(int(f32(x) / scale), w - 1)
			sx1 := clamp(int(math.ceil(f32(x + 1) / scale)), sx0 + 1, w)
			sum: [4]int
			for yy in sy0 ..< sy1 {
				for xx in sx0 ..< sx1 {
					p := src[(yy * w + xx) * 4:][:4]
					sum += {int(p[0]), int(p[1]), int(p[2]), int(p[3])}
				}
			}
			n := (sy1 - sy0) * (sx1 - sx0)
			o := out[(y * nw + x) * 4:][:4]
			for k in 0 ..< 4 { o[k] = u8((sum[k] + n / 2) / n) }
		}
	}
	return
}

////////////////////////////////
// Input: the events go to the window's queue and take the path of a real device's

// the buttons held, as a real device's events carry them (e.buttons, a drag that needs the left button held)
@(private = "file")
inject_held: platform.Mouse_Buttons

@(private = "file")
inject :: proc(app: ^App, ev: platform.Event) {
	ev := ev
	#partial switch ev.kind {
	case .Mouse_Press: inject_held += {ev.button}
	case .Mouse_Release: inject_held -= {ev.button}
	}
	held := inject_held
	if ev.kind == .Mouse_Move || ev.kind == .Mouse_Press || ev.kind == .Mouse_Release { ev.buttons = held }
	platform.inject_event(active_window(app).win, ev)
	the_remote.inputs += 1
	request_frames(app, 4)
}

// A point given in the page's CSS pixels (from its top-left corner), or in window pixels (`"space": "window"`).
@(private = "file")
point_of :: proc(app: ^App, c: ^Call, xk, yk: string) -> (p: [2]f32, ok: bool) {
	x, hx := remote.param_float(c.params, xk)
	y, hy := remote.param_float(c.params, yk)
	if !hx || !hy { return {}, false }
	if space, _ := remote.param_string(c.params, "space"); space == "window" { return {f32(x), f32(y)}, true }
	s := page_scale(app)
	return active_window(app).page_rect.min + {f32(x) * s, f32(y) * s}, true
}

@(private = "file")
mods_of :: proc(c: ^Call) -> platform.Modifiers {
	m, _ := remote.param_int(c.params, "modifiers")
	mods: platform.Modifiers
	if m & 1 != 0 { mods += {.Alt} }
	if m & 2 != 0 { mods += {.Ctrl} }
	if m & 8 != 0 { mods += {.Shift} }
	return mods
}

@(private = "file")
button_of :: proc(c: ^Call) -> platform.Mouse_Button {
	s, _ := remote.param_string(c.params, "button", "left")
	switch s {
	case "right":  return .Right
	case "middle": return .Middle
	}
	return .Left
}

// Input.dispatchMouseEvent {type: mouseMoved|mousePressed|mouseReleased|mouseWheel, x, y, button, modifiers, deltaX, deltaY, notches}
@(private = "file")
m_mouse_event :: proc(app: ^App, c: ^Call) -> Reply {
	kind, bad := need_string(c, "type")
	if bad.code != 0 { return bad }
	pos, ok := point_of(app, c, "x", "y")
	if !ok { return fail(remote.ERR_PARAMS, "x and y are missing") }
	mods := mods_of(c)
	switch kind {
	case "mouseMoved":    inject(app, {kind = .Mouse_Move, pos = pos, mods = mods})
	case "mousePressed":  inject(app, {kind = .Mouse_Press, pos = pos, button = button_of(c), mods = mods})
	case "mouseReleased": inject(app, {kind = .Mouse_Release, pos = pos, button = button_of(c), mods = mods})
	case "mouseWheel":
		dx, _ := remote.param_float(c.params, "deltaX")
		dy, _ := remote.param_float(c.params, "deltaY")
		if n, has := remote.param_float(c.params, "notches"); has { dy = n * 100 }
		inject(app, {kind = .Scroll, pos = pos, delta = {f32(dx) / 100, f32(dy) / 100}, mods = mods})
	case: return fail(remote.ERR_PARAMS, "type: mouseMoved, mousePressed, mouseReleased or mouseWheel")
	}
	return frames_op(app, c, nil, the_remote.cfg.settle_frames)
}

// Wren.click {x, y | selector, button, count, space}
@(private = "file")
m_click :: proc(app: ^App, c: ^Call) -> Reply {
	t, e := tab_of(app, c)
	if t == nil { return e }
	count, _ := remote.param_int(c.params, "count", 1)
	if sel, ok := remote.param_string(c.params, "selector"); ok {
		op := op_new(app, c, .Click, timeout_of(c), fmt.tprintf("the element %s", sel))
		op.tab, op.arg, op.button, op.count = t.id, strings.clone(sel), button_of(c), max(count, 1)
		op.until = the_remote.frame_no
		request_frames(app, 3)
		return Reply{deferred = true}
	}
	pos, ok := point_of(app, c, "x", "y")
	if !ok { return fail(remote.ERR_PARAMS, "give x and y, or a selector") }
	click_at(app, pos, button_of(c), max(count, 1), mods_of(c))
	return frames_op(app, c, t, the_remote.cfg.settle_frames, fmt.tprintf(`{{"x":%.1f,"y":%.1f}}`, pos.x, pos.y))
}

@(private = "file")
click_at :: proc(app: ^App, pos: [2]f32, button: platform.Mouse_Button, count: int, mods: platform.Modifiers) {
	inject(app, {kind = .Mouse_Move, pos = pos, mods = mods})
	for _ in 0 ..< count {
		inject(app, {kind = .Mouse_Press, pos = pos, button = button, mods = mods})
		inject(app, {kind = .Mouse_Release, pos = pos, button = button, mods = mods})
	}
}

// A click on an element: it is scrolled into view first, and the click goes to the middle of its box once the page has
// scrolled.
click_step :: proc(app: ^App, op: ^Remote_Op, t: ^Tab, timed_out: bool) {
	wnd := active_window(app)
	r := &the_remote
	request_frames(app, 2)
	if r.frame_no < op.until { return }
	h, valid := page.query_first(t.page, op.arg)
	if !valid { op_finish(op, fail(remote.ERR_PARAMS, fmt.tprintf("invalid selector %q", op.arg))); return }
	er: [4]f32
	ok := false
	if h != base.NIL_HANDLE { er, ok = element_window_rect(app, t, h) }
	if !ok {
		if timed_out { op_finish(op, fail(remote.ERR_TIMEOUT, fmt.tprintf("timed out: no element with a box matches %q", op.arg))) }
		return
	}
	switch op.stage {
	case 0:
		pr := wnd.page_rect
		center_y := er[1] + er[3] / 2
		if center_y < pr.min.y || center_y > pr.max.y {
			// document coordinates of the element's middle, to the middle of the view
			doc_y := er[1] - wnd.page_rect.min.y + t.scroll
			scroll_document_to(app, t, max(doc_y + er[3] / 2 - (pr.max.y - pr.min.y) / 2, 0), false)
			op.until = r.frame_no + 2
		}
		op.stage = 1
	case 1:
		pos := [2]f32{er[0] + er[2] / 2, er[1] + er[3] / 2}
		click_at(app, pos, op.button, op.count, {})
		op.pos = pos
		op.stage = 2
		op.until = r.frame_no + u64(max(r.cfg.settle_frames, 1))
	case:
		op_finish(op, done(fmt.tprintf(`{{"x":%.1f,"y":%.1f}}`, op.pos.x, op.pos.y)))
	}
}

// Wren.drop {x, y, files: [paths], text, url, html, leave}: another application's drag over the window, through the
// toolkit's drop target path (platform.drop_inject): enter, over, then the drop at (x, y) (with `leave`: it leaves
// instead). The reply says what the window answered (the effect the app set).
@(private = "file")
m_drop :: proc(app: ^App, c: ^Call) -> Reply {
	wnd := active_window(app)
	pos, ok := point_of(app, c, "x", "y")
	if !ok { return fail(remote.ERR_PARAMS, "x and y are missing") }
	d: platform.Drag_Data
	defer delete(d.files)
	if arr, has := remote.param_array(c.params, "files"); has {
		for v in arr { if s, is := v.(json.String); is { append(&d.files, string(s)) } }
	}
	d.text, _ = remote.param_string(c.params, "text")
	d.url, _ = remote.param_string(c.params, "url")
	d.html, _ = remote.param_string(c.params, "html")
	if platform.drag_data_empty(d) { return fail(remote.ERR_PARAMS, "give files, text, url or html") }
	leave, _ := remote.param_bool(c.params, "leave")
	mods := mods_of(c)
	if !platform.drop_inject(wnd.win, .Drop_Enter, pos, &d, mods = mods) { return fail(remote.ERR_PARAMS, "this system has no drag and drop") }
	platform.drop_inject(wnd.win, .Drop_Over, pos, mods = mods)
	platform.drop_inject(wnd.win, leave ? .Drop_Leave : .Drop, pos, mods = mods)
	the_remote.inputs += 1
	request_frames(app, 4)
	return frames_op(app, c, nil, the_remote.cfg.settle_frames)
}

// Wren.drag {x, y, toX, toY, steps, button}
// Each step gets its own frame: injected at once, the frame's input pass would see the release before the page had
// the moves (the DOM's mousemove goes out once per frame, after the loop over the events; a press that waits for a
// fresh layout starts its selection gesture a frame later).
@(private = "file")
m_drag :: proc(app: ^App, c: ^Call) -> Reply {
	from, ok1 := point_of(app, c, "x", "y")
	to, ok2 := point_of(app, c, "toX", "toY")
	if !ok1 || !ok2 { return fail(remote.ERR_PARAMS, "x, y, toX and toY are needed") }
	steps, _ := remote.param_int(c.params, "steps", 8)
	op := op_new(app, c, .Drag, timeout_of(c), "drag")
	op.pos, op.to, op.count, op.button = from, to, clamp(steps, 1, 1000), button_of(c)
	// "via": points passed through on the way (window points may be outside the window: the drag leaves it and comes
	// back, through the window's own drop target, never the real mouse)
	if arr, has := remote.param_array(c.params, "via"); has {
		space, _ := remote.param_string(c.params, "space")
		s := page_scale(app)
		for v in arr {
			pt, is := v.(json.Array)
			if !is || len(pt) != 2 { continue }
			num :: proc(v: json.Value) -> (f32, bool) {
				#partial switch x in v {
				case json.Float: return f32(x), true
				case json.Integer: return f32(x), true
				}
				return 0, false
			}
			x, xok := num(pt[0])
			y, yok := num(pt[1])
			if !xok || !yok { continue }
			p := [2]f32{x, y}
			append(&op.via, space == "window" ? p : active_window(app).page_rect.min + p * s)
		}
	}
	// "hold": the button stays down at the end (a picture of the drag on its way: a tab carried over another window's bar);
	// "resume": a drag held before goes on from here (no press), and ends as asked
	op.hold, _ = remote.param_bool(c.params, "hold")
	if resume, _ := remote.param_bool(c.params, "resume"); resume {
		if op.button not_in inject_held { op_finish(op, fail(remote.ERR_FAILED, "no drag is held (drag --hold first)")); return Reply{deferred = true} }
		op.stage, op.idx = 1, 0
	}
	op.until = the_remote.frame_no
	request_frames(app, 3)
	return Reply{deferred = true}
}

// The drag's path: its start, the points it passes through, its end (temporary).
@(private = "file")
drag_path :: proc(op: ^Remote_Op) -> [][2]f32 {
	pts := make([dynamic][2]f32, context.temp_allocator)
	append(&pts, op.pos)
	append(&pts, ..op.via[:])
	append(&pts, op.to)
	return pts[:]
}

// Where step `k` (1-based, op.count steps per segment) of the drag's path is.
@(private = "file")
drag_point :: proc(op: ^Remote_Op, pts: [][2]f32, k: int) -> [2]f32 {
	segs := len(pts) - 1
	seg := min((k - 1) / op.count, segs - 1)
	f := f32((k - 1) - seg * op.count + 1) / f32(op.count)
	return pts[seg] + (pts[seg + 1] - pts[seg]) * f
}

// The drag left the window and the shell runs the system's drag (dnd_shell.odin hand_off): the rest of the path, as the
// steps of a scripted drag through the window's own drop target, the release included. The remote drag is then done.
remote_drag_steps :: proc(app: ^App) -> ([]platform.Drag_Step, bool) {
	for op in the_remote.ops {
		if op.kind != .Drag || (op.stage != 1 && op.stage != 2) { continue }
		pts := drag_path(op)
		total := op.count * (len(pts) - 1)
		steps := make([dynamic]platform.Drag_Step, context.temp_allocator)
		for k in op.idx + 1 ..= total { append(&steps, platform.Drag_Step{pos = drag_point(op, pts, k)}) }
		if len(steps) == 0 { append(&steps, platform.Drag_Step{pos = op.to}) }
		inject_held -= {op.button}   // (released in the system's drag: no release event follows)
		op.stage = 3
		op.until = the_remote.frame_no + u64(max(the_remote.cfg.settle_frames, 1))
		return steps[:], true
	}
	return nil, false
}

// Press (stage 0), one move per frame (stage 1, idx: the steps made), release at the last position (stage 2), settle.
drag_step :: proc(app: ^App, op: ^Remote_Op) {
	r := &the_remote
	request_frames(app, 2)
	if r.frame_no < op.until { return }
	switch op.stage {
	case 0:
		inject(app, {kind = .Mouse_Move, pos = op.pos})
		inject(app, {kind = .Mouse_Press, pos = op.pos, button = op.button})
		op.stage, op.idx = 1, 0
		op.until = r.frame_no + 2   // (a press may wait one frame for a fresh layout before its gesture starts)
	case 1:
		op.idx += 1
		pts := drag_path(op)
		inject(app, {kind = .Mouse_Move, pos = drag_point(op, pts, op.idx)})
		if op.idx >= op.count * (len(pts) - 1) { op.stage = 2 }
		op.until = r.frame_no + 1
	case 2:
		if !op.hold { inject(app, {kind = .Mouse_Release, pos = op.to, button = op.button}) }
		op.stage = 3
		op.until = r.frame_no + u64(max(r.cfg.settle_frames, 1))
	case:
		op_finish(op, done(fmt.tprintf(`{{"x":%.1f,"y":%.1f,"toX":%.1f,"toY":%.1f}}`, op.pos.x, op.pos.y, op.to.x, op.to.y)))
	}
}

// Wren.type {text}  /  Input.insertText {text}: each character as the keyboard's text input (a new line is the Enter key)
@(private = "file")
m_type :: proc(app: ^App, c: ^Call) -> Reply {
	text, bad := need_string(c, "text")
	if bad.code != 0 { return bad }
	for ch in text {
		switch ch {
		case '\n', '\r': emit_key(app, .Return, {}, 0)
		case '\t':       emit_key(app, .Tab, {}, 0)
		case:            inject(app, {kind = .Text, text = ch})
		}
	}
	return frames_op(app, c, nil, the_remote.cfg.settle_frames)
}

// Wren.key {keys: "Ctrl+L"}: the modifiers go down, the key goes down and up, the modifiers go up
@(private = "file")
m_key :: proc(app: ^App, c: ^Call) -> Reply {
	combo, bad := need_string(c, "keys")
	if bad.code != 0 { return bad }
	repeat, _ := remote.param_int(c.params, "repeat", 1)
	for part in strings.split(combo, " ", context.temp_allocator) {
		if part == "" { continue }
		key, mods, ok := parse_combo(part)
		if !ok { return fail(remote.ERR_PARAMS, fmt.tprintf("unknown key %q (examples: Enter, Ctrl+L, Shift+Tab, F5, a)", part)) }
		for _ in 0 ..< clamp(repeat, 1, 1000) { emit_key(app, key, mods, key_text(key, mods)) }
	}
	return frames_op(app, c, nil, the_remote.cfg.settle_frames)
}

// Input.dispatchKeyEvent {type: keyDown|keyUp|rawKeyDown|char, key, text, modifiers}
@(private = "file")
m_key_event :: proc(app: ^App, c: ^Call) -> Reply {
	kind, bad := need_string(c, "type")
	if bad.code != 0 { return bad }
	mods := mods_of(c)
	text, _ := remote.param_string(c.params, "text")
	name, _ := remote.param_string(c.params, "key")
	key, kmods, ok := parse_combo(name)
	mods += kmods
	switch kind {
	case "keyDown", "rawKeyDown":
		if ok { inject(app, {kind = .Key_Press, key = key, mods = mods}) }
		for ch in text { inject(app, {kind = .Text, text = ch, mods = mods}) }
	case "keyUp": if ok { inject(app, {kind = .Key_Release, key = key, mods = mods}) }
	case "char":  for ch in text { inject(app, {kind = .Text, text = ch, mods = mods}) }
	case: return fail(remote.ERR_PARAMS, "type: keyDown, keyUp, rawKeyDown or char")
	}
	return frames_op(app, c, nil, the_remote.cfg.settle_frames)
}

@(private = "file")
emit_key :: proc(app: ^App, key: platform.Key, mods: platform.Modifiers, text: rune) {
	held: platform.Modifiers
	down :: proc(app: ^App, held: ^platform.Modifiers, m: platform.Modifier, k: platform.Key, mods: platform.Modifiers) {
		if m in mods { held^ += {m}; inject(app, {kind = .Key_Press, key = k, mods = held^}) }
	}
	down(app, &held, .Ctrl, .Ctrl, mods); down(app, &held, .Alt, .Alt, mods); down(app, &held, .Shift, .Shift, mods)
	inject(app, {kind = .Key_Press, key = key, mods = held})
	if text != 0 { inject(app, {kind = .Text, text = text, mods = held}) }
	inject(app, {kind = .Key_Release, key = key, mods = held})
	up :: proc(app: ^App, held: ^platform.Modifiers, m: platform.Modifier, k: platform.Key) {
		if m in held^ { held^ -= {m}; inject(app, {kind = .Key_Release, key = k, mods = held^}) }
	}
	up(app, &held, .Shift, .Shift); up(app, &held, .Alt, .Alt); up(app, &held, .Ctrl, .Ctrl)
}

// The text a key types without Ctrl or Alt (US layout).
key_text :: proc(key: platform.Key, mods: platform.Modifiers) -> rune {
	if .Ctrl in mods || .Alt in mods { return 0 }
	shift := .Shift in mods
	#partial switch key {
	case .A ..= .Z:
		ch := 'a' + rune(int(key) - int(platform.Key.A))
		return shift ? ch - 32 : ch
	case .N0 ..= .N9:
		if shift { symbols := [10]rune{')', '!', '@', '#', '$', '%', '^', '&', '*', '('}; return symbols[int(key) - int(platform.Key.N0)] }
		return '0' + rune(int(key) - int(platform.Key.N0))
	case .Space:  return ' '
	case .Comma:  return shift ? '<' : ','
	case .Period: return shift ? '>' : '.'
	case .Slash:  return shift ? '?' : '/'
	case .Minus:  return shift ? '_' : '-'
	case .Equal:  return shift ? '+' : '='
	}
	return 0
}

// "Ctrl+Shift+T", "Enter", "F5", "a", "ArrowLeft"...
parse_combo :: proc(s: string) -> (key: platform.Key, mods: platform.Modifiers, ok: bool) {
	parts := strings.split(s, "+", context.temp_allocator)
	// (a lone "+" or "Ctrl++": the plus key)
	if len(parts) > 1 && parts[len(parts) - 1] == "" && len(parts) >= 2 {
		parts = parts[:len(parts) - 1]
		parts[len(parts) - 1] = "plus"
	}
	for p, i in parts {
		name := strings.to_lower(strings.trim_space(p), context.temp_allocator)
		if i < len(parts) - 1 {
			switch name {
			case "ctrl", "control": mods += {.Ctrl}
			case "alt", "option":   mods += {.Alt}
			case "shift":           mods += {.Shift}
			case "meta", "cmd", "win": mods += {.Ctrl}
			case: return {}, {}, false
			}
			continue
		}
		key, ok = key_from_name(name)
	}
	return
}

@(private = "file")
key_from_name :: proc(n: string) -> (platform.Key, bool) {
	if len(n) == 1 {
		c := n[0]
		switch c {
		case 'a' ..= 'z': return platform.Key(int(platform.Key.A) + int(c - 'a')), true
		case '0' ..= '9': return platform.Key(int(platform.Key.N0) + int(c - '0')), true
		case ',': return .Comma, true
		case '.': return .Period, true
		case '/': return .Slash, true
		case '-': return .Minus, true
		case '=', '+': return .Equal, true
		case ' ': return .Space, true
		}
		return .None, false
	}
	if len(n) >= 2 && n[0] == 'f' {
		num := 0
		for ch in n[1:] { if ch < '0' || ch > '9' { num = -1; break }; num = num * 10 + int(ch - '0') }
		if num >= 1 && num <= 12 { return platform.Key(int(platform.Key.F1) + num - 1), true }
	}
	switch n {
	case "enter", "return": return .Return, true
	case "esc", "escape": return .Escape, true
	case "tab": return .Tab, true
	case "space", "spacebar": return .Space, true
	case "backspace": return .Backspace, true
	case "delete", "del": return .Delete, true
	case "insert", "ins": return .Insert, true
	case "left", "arrowleft": return .Left, true
	case "right", "arrowright": return .Right, true
	case "up", "arrowup": return .Up, true
	case "down", "arrowdown": return .Down, true
	case "home": return .Home, true
	case "end": return .End, true
	case "pageup", "page_up", "pgup": return .Page_Up, true
	case "pagedown", "page_down", "pgdn": return .Page_Down, true
	case "comma": return .Comma, true
	case "period", "dot": return .Period, true
	case "slash": return .Slash, true
	case "minus": return .Minus, true
	case "equal", "plus": return .Equal, true
	case "menu": return .Menu, true
	case "ctrl", "control": return .Ctrl, true
	case "shift": return .Shift, true
	case "alt": return .Alt, true
	}
	return .None, false
}

////////////////////////////////
// Introspection

@(private = "file")
m_stats :: proc(app: ^App, c: ^Call) -> Reply {
	wnd := active_window(app)
	n := &hud.nums
	b := builder()
	reset_latency, _ := remote.param_bool(c.params, "resetLatency")
	reset_frames, _ := remote.param_bool(c.params, "resetFrames")
	gaps := frame_log_intervals()
	loops := platform.pump_stats(wnd.win)
	defer if reset_frames { frame_log_reset(); drag_probe_reset(); wnd.win.stats = {} }
	latency := render.latency_summary(&app.r)
	latency_on := render.latency_probe_on(&app.r)
	if reset_latency { render.latency_reset(&app.r) }
	j_begin(&b)
	if latency_on {
		j_key(&b, "latency"); j_begin(&b)
		j_bool(&b, "tearingSupported", render.tearing_supported(&app.r)); j_bool(&b, "tearing", render.present_mode(&app.r) == .Tearing)
		j_int(&b, "samples", i64(latency.samples)); j_num(&b, "refreshMs", f64(latency.period_ms))
		j_int(&b, "framesShown", i64(latency.frames)); j_int(&b, "framesShownFromInput", i64(latency.with_input))
		j_num(&b, "queueMean", f64(latency.queue_mean)); j_int(&b, "queueMax", i64(latency.queue_max))
		for st in ([?]struct { name: string, v: render.Latency_Stat }{{"waitMs", latency.wait}, {"workMs", latency.work}, {"presentMs", latency.present}, {"scanMs", latency.scan}, {"totalMs", latency.total}, {"totalRefreshes", latency.refreshes}}) {
			j_key(&b, st.name); j_begin(&b)
			j_num(&b, "p50", f64(st.v.p50)); j_num(&b, "p95", f64(st.v.p95)); j_num(&b, "max", f64(st.v.max)); j_num(&b, "mean", f64(st.v.mean))
			j_end(&b)
		}
		j_end(&b)
	}
	j_num(&b, "fps", f64(n.fps)); j_int(&b, "frames", i64(n.frames))
	j_num(&b, "cpuMs", f64(n.cpu_mean)); j_num(&b, "cpuP95Ms", f64(n.cpu_p95)); j_num(&b, "cpuP99Ms", f64(n.cpu_p99)); j_num(&b, "cpuMaxMs", f64(n.cpu_max))
	j_num(&b, "gpuMs", f64(n.gpu_mean)); j_bool(&b, "gpuMeasured", n.gpu_n > 0)
	j_int(&b, "workingSetBytes", i64(n.working_set)); j_int(&b, "privateBytes", i64(n.private_bytes))
	j_int(&b, "framesDrawn", i64(hud.serial)); j_int(&b, "framesRequested", i64(wnd.frames_requested))
	// the presents since resetFrames, the gaps between them, and how the window's frames were asked for (platform.Pump_Stats)
	j_int(&b, "framesPresented", i64(frame_log.presented)); j_int(&b, "frameGaps", i64(gaps.count))
	j_num(&b, "frameGapP50Ms", gaps.p50); j_num(&b, "frameGapP95Ms", gaps.p95); j_num(&b, "frameGapP99Ms", gaps.p99); j_num(&b, "frameGapMaxMs", gaps.max)
	j_int(&b, "paintFrames", i64(loops.paint_frames)); j_int(&b, "modalLoops", i64(loops.modal_loops)); j_int(&b, "ignoredSizeMoves", i64(loops.ignored_size_moves))
	// the frames of the thread through the frame gate (windows.odin): admitted, of which inside another, asked for where none
	// may begin (a repaint later), and the moves the state machine does not have (0, or a bug)
	{
		g := platform.frame_gate()
		j_key(&b, "frameGate"); j_begin(&b)
		j_int(&b, "begun", i64(g.begun)); j_int(&b, "nested", i64(g.nested)); j_int(&b, "deferred", i64(g.deferred))
		j_int(&b, "violations", i64(g.violations)); j_str(&b, "lastViolation", g.last_violation)
		j_end(&b)
	}
	j_bool(&b, "menuOpen", ui.ctx_menu_any_open())   // a menu of the chrome is open (the page's context menu, the tab menu...)
	pacer := &wnd.pacer   // (the window's pacing; the preferences are the process's)
	if app.pacing.cfg.drag_probe { j_key(&b, "dragSamples"); drag_probe_json(&b) }
	j_int(&b, "requestsInFlight", i64(fetch.in_flight(&app.loader))); j_int(&b, "tabs", i64(len(wnd.tabs)))
	// the back/forward cache since start-up (bfcache.odin): its coverage (traversals served from it) and what kept
	// pages out of it, by reason
	j_key(&b, "bfcache"); j_begin(&b)
	j_int(&b, "cached", i64(len(bf.entries))); j_int(&b, "stores", i64(bf.stores)); j_int(&b, "restores", i64(bf.restores))
	j_int(&b, "evictions", i64(bf.evictions)); j_int(&b, "refusals", i64(bf.refusals))
	j_int(&b, "traversals", i64(bf.traversals)); j_int(&b, "misses", i64(bf.misses))
	j_num(&b, "hitRate", bf.traversals > 0 ? f64(bf.traversals - bf.misses) / f64(bf.traversals) : 0)
	j_key(&b, "reasons"); j_begin(&b)
	for k, v in bf.reasons { j_int(&b, k, i64(v)) }
	j_end(&b)
	j_end(&b)
	j_int(&b, "inputEvents", i64(the_remote.inputs)); j_num(&b, "hz", f64(pacer.hz))
	// the screen: what the system reports (hzReported), its top mode (hzMax), the highest rate the compositor reported during the current
	// or last run of frames (hzNow; primary monitor only), the swap chain's (hzSwapChain), and whether frames aim for the top one (variableRefresh)
	j_num(&b, "hzReported", pacer.display.hz); j_num(&b, "hzMax", pacer.display.max_hz); j_num(&b, "hzNow", pacer.live_hz)
	j_num(&b, "hzSwapChain", render.measured_refresh_hz(&app.r)); j_bool(&b, "variableRefresh", pacer.variable)
	j_bool(&b, "frameCapStrict", pacer.cadence.slots.strict || pacer.cadence.slots.escalated); j_num(&b, "framePeriodMs", pacer.period_ms)
	{
		// the frames by state of the cadence model (toolkit platform/pacing.odin) since start-up, and the last one's
		sb := strings.builder_make(context.temp_allocator)
		for n, s in pacer.cadence.counts { if n > 0 { fmt.sbprintf(&sb, "%v=%d ", s, n) } }
		j_str(&b, "frameStates", strings.trim_space(strings.to_string(sb))); j_str(&b, "frameState", fmt.tprint(pacer.cadence.state))
	}
	// the picture of the last drag that went to the system (dnd_image.odin), as the system holds it: "WxH@x,y", "" for none
	j_bool(&b, "dropTarget", platform.drop_target_enabled(wnd.win))
	{
		lp := dnd_last_picture
		j_str(&b, "dragPicture", lp.size.x > 0 ? fmt.tprintf("%dx%d@%d,%d rgba=%d,%d,%d,%d", lp.size.x, lp.size.y, lp.hot.x, lp.hot.y, lp.middle[0], lp.middle[1], lp.middle[2], lp.middle[3]) : "")
	}
	j_int(&b, "resizeEchoesSkipped", i64(pacer.echoes_skipped))
	{
		// the frames of resize bursts that were made, by cause, and the events of those made for events
		sb := strings.builder_make(context.temp_allocator)
		for n, c in pacer.resize_causes { if n > 0 { fmt.sbprintf(&sb, "%v=%d ", c, n) } }
		for n, k in pacer.resize_event_kinds { if n > 0 { fmt.sbprintf(&sb, "ev.%v=%d ", k, n) } }
		j_str(&b, "resizeFrameCauses", strings.trim_space(strings.to_string(sb)))
	}
	if sz, hot, held := platform.drag_image_held(wnd.win); held { j_str(&b, "dragImage", fmt.tprintf("%dx%d@%d,%d", sz.x, sz.y, hot.x, hot.y)) } else { j_str(&b, "dragImage", "") }
	// how often the subsystems were configured again by preference writes (prefs_apply.odin)
	j_int(&b, "prefsNetApplied", i64(prefs_apply_counts[.Net])); j_int(&b, "prefsCacheApplied", i64(prefs_apply_counts[.Http_Cache])); j_int(&b, "prefsDownloadsApplied", i64(prefs_apply_counts[.Downloads]))
	if t := current_tab(app); t != nil && t.page != nil { j_int(&b, "nodes", i64(t.page.doc.nodes.count)); j_int(&b, "layoutItems", i64(len(t.layout.items))) }
	j_str(&b, "backend", render.backend_name())
	// the process and the state a reset empties (so that a test can see both the cost of what it did and that a reset worked)
	cpu, cpu_user, cpu_kernel := process_cpu_ms()
	pc := process_counters()
	j_int(&b, "pid", i64(win.GetCurrentProcessId())); j_num(&b, "uptimeMs", process_uptime_ms())
	// accessibility (a11y_chrome.odin): updates sent to the screen readers' adapter, refused by it, nodes of the last one
	if wnd.ui != nil {
		au, ar, an := ui.a11y_stats(wnd.ui)
		j_int(&b, "a11yUpdates", i64(au)); j_int(&b, "a11yRefused", i64(ar)); j_int(&b, "a11yLastNodes", i64(an))
		j_int(&b, "a11yNodes", i64(len(ui.a11y_tree(wnd.ui).nodes)))
		ps := page_a11y_stats(wnd)
		j_int(&b, "a11yPageBuilds", i64(ps.builds)); j_int(&b, "a11yPagePatches", i64(ps.patches)); j_int(&b, "a11yPageSends", i64(ps.sends))
		j_int(&b, "a11yPageRefused", i64(ps.refused)); j_int(&b, "a11yPageNodes", i64(ps.nodes)); j_int(&b, "a11yPageWritten", i64(ps.written))
		j_int(&b, "a11yPageFrames", i64(ps.frames)); j_int(&b, "a11yPageVerifyFailed", i64(ps.verify_failed)); j_str(&b, "a11yPageFallback", ps.fallback); j_str(&b, "a11yPageVerifyDiff", ps.verify_diff)
	}
	// the caret of a focused field of the page in this window: blinking (a timer of its own), and shown in this frame
	fv := forms_view(app)
	j_bool(&b, "caretBlinking", fv.blink_timer != base.NIL_HANDLE); j_bool(&b, "caretShown", fv.blink_on); j_bool(&b, "frontWindow", window_is_front(app))
	j_num(&b, "cpuTimeMs", cpu); j_num(&b, "cpuUserMs", cpu_user); j_num(&b, "cpuKernelMs", cpu_kernel)
	j_int(&b, "threads", i64(process_thread_count())); j_int(&b, "handles", pc.handles); j_int(&b, "gdiObjects", pc.gdi); j_int(&b, "userObjects", pc.user)
	j_int(&b, "cookies", i64(cookies.count(&app.profile.jar))); j_int(&b, "storageSites", i64(len(page.storage_sites(&app.storage))))
	j_int(&b, "cacheEntries", app.profile.cache != nil ? i64(httpcache.summary(app.profile.cache).entries) : 0)
	j_int(&b, "historyVisits", i64(len(ghist.visits))); j_int(&b, "closedTabs", i64(len(closed_tabs))); j_int(&b, "downloadsActive", i64(downloads_active()))
	j_int(&b, "checkpoints", i64(len(the_remote.checkpoints))); j_bool(&b, "devtools", dev().visible)
	j_int(&b, "pendingOps", i64(len(the_remote.ops)))   // the commands that wait (a wait, a navigation's load): a test sees one is registered before it acts on it
	j_int(&b, "devtoolsRoomChecks", i64(dev().room_checks)); j_int(&b, "devtoolsRoomWrong", i64(dev().room_wrong))   // devtools.odin: dev_width
	j_end(&b)
	return done(strings.to_string(b))
}

@(private = "file")
m_console :: proc(app: ^App, c: ^Call) -> Reply {
	t, e := tab_of(app, c)
	if t == nil { return e }
	since, _ := remote.param_int(c.params, "since", 0)
	first := int(t.console_added) - len(t.console)   // the number of console[0]
	b := builder()
	j_begin(&b)
	j_int(&b, "total", i64(t.console_added))
	j_key(&b, "lines"); j_begin(&b, '[')
	for l, i in t.console {
		if first + i < since { continue }
		level, text := "log", l
		switch {
		case strings.has_prefix(l, "error: "): level, text = "error", l[7:]
		case strings.has_prefix(l, "warn: "):  level, text = "warn", l[6:]
		}
		j_key(&b, ""); j_begin(&b)
		j_int(&b, "n", i64(first + i)); j_str(&b, "level", level); j_str(&b, "text", text)
		j_end(&b)
	}
	j_end(&b, ']'); j_end(&b)
	if clear, _ := remote.param_bool(c.params, "clear"); clear {
		for l in t.console { delete(l) }
		clear_dynamic(&t.console)
	}
	return done(strings.to_string(b))
}

@(private = "file")
clear_dynamic :: proc(a: ^[dynamic]string) { clear(a) }

@(private = "file")
m_network :: proc(app: ^App, c: ^Call) -> Reply {
	t, e := tab_of(app, c)
	if t == nil { return e }
	b := builder()
	j_begin(&b)
	j_int(&b, "bytes", t.net.bytes)
	j_key(&b, "requests"); j_begin(&b, '[')
	for en in t.net.entries {
		j_key(&b, ""); j_begin(&b)
		j_int(&b, "id", i64(en.id)); j_str(&b, "method", en.method); j_str(&b, "url", en.url)
		j_str(&b, "destination", strings.to_lower(fmt.tprintf("%v", en.dest), context.temp_allocator))
		j_int(&b, "status", i64(en.status)); j_str(&b, "mime", en.mime); j_int(&b, "bytes", i64(en.bytes))
		j_bool(&b, "finished", en.ms >= 0); if en.ms >= 0 { j_num(&b, "ms", f64(en.ms)) }
		j_str(&b, "cache", strings.to_lower(fmt.tprintf("%v", en.cache), context.temp_allocator))
		if en.failed { j_bool(&b, "failed", true); j_str(&b, "error", en.error) }
		j_end(&b)
	}
	j_end(&b, ']'); j_end(&b)
	if clear, _ := remote.param_bool(c.params, "clear"); clear { net_clear(&t.net) }
	return done(strings.to_string(b))
}

////////////////////////////////
// Preferences, commands, panels

pref_json :: proc(app: ^App, name: string) -> (string, bool) {
	i, ok := app.prefs.index[name]
	if !ok { return "", false }
	e := &app.prefs.entries[i]
	b := builder()
	j_begin(&b)
	j_str(&b, "name", e.def.name)
	switch e.def.kind {
	case .Bool:   j_bool(&b, "value", e.value.b)
	case .Int:    j_int(&b, "value", e.value.i)
	case .Float:  j_num(&b, "value", e.value.f)
	case .String: j_str(&b, "value", e.value.s)
	}
	j_str(&b, "text", config.value_string(&app.prefs, config.Ref(i)))
	j_str(&b, "default", config.default_string(&app.prefs, config.Ref(i)))
	j_str(&b, "source", strings.to_lower(fmt.tprintf("%v", e.source), context.temp_allocator))
	j_bool(&b, "locked", e.locked); j_bool(&b, "restart", e.def.restart)
	j_end(&b)
	return strings.to_string(b), true
}

@(private = "file")
m_pref_get :: proc(app: ^App, c: ^Call) -> Reply {
	name, bad := need_string(c, "name")
	if bad.code != 0 { return bad }
	s, ok := pref_json(app, name)
	if !ok { return fail(remote.ERR_PARAMS, fmt.tprintf("no preference %q", name)) }
	return done(s)
}

@(private = "file")
m_pref_set :: proc(app: ^App, c: ^Call) -> Reply {
	name, bad := need_string(c, "name")
	if bad.code != 0 { return bad }
	text := ""
	switch v in c.params["value"] {
	case json.String:  text = string(v)
	case json.Integer: text = fmt.tprintf("%d", i64(v))
	case json.Float:   text = fmt.tprintf("%v", f64(v))
	case json.Boolean: text = v ? "true" : "false"
	case json.Null, json.Array, json.Object: return fail(remote.ERR_PARAMS, "\"value\": a string, number or boolean")
	case: return fail(remote.ERR_PARAMS, "parameter \"value\" is missing")
	}
	// override: the command line's layer, which a value given with --pref (at the start of this run) has taken: it is changed, not refused
	override, _ := remote.param_bool(c.params, "override")
	if err := config.set_from_string(&app.prefs, name, text, override ? .Command_Line : .User); err != .None {
		return fail(remote.ERR_FAILED, fmt.tprintf("%s: %s", name, config.set_error_text(err)))
	}
	remote_reload_settings(app)
	request_frames(app, 3)
	s, _ := pref_json(app, name)
	return done(s)
}

@(private = "file")
m_pref_list :: proc(app: ^App, c: ^Call) -> Reply {
	prefix, _ := remote.param_string(c.params, "prefix")
	b := builder()
	j_begin(&b)
	j_key(&b, "prefs"); j_begin(&b, '[')
	for name in config.sorted_names(&app.prefs) {
		if !strings.has_prefix(name, prefix) { continue }
		s, _ := pref_json(app, name)
		j_raw(&b, "", s)
	}
	j_end(&b, ']'); j_end(&b)
	return done(strings.to_string(b))
}

@(private = "file")
m_commands :: proc(app: ^App) -> Reply {
	b := builder()
	j_begin(&b)
	j_key(&b, "commands"); j_begin(&b, '[')
	t := current_tab(app)
	for &cmd in commands() {
		j_key(&b, ""); j_begin(&b)
		j_str(&b, "name", cmd.name); j_str(&b, "title", cmd.title); j_str(&b, "category", cmd.category)
		j_str(&b, "shortcut", command_shortcut_text(&cmd)); j_bool(&b, "enabled", command_enabled(app, t, &cmd))
		j_end(&b)
	}
	j_end(&b, ']'); j_end(&b)
	return done(strings.to_string(b))
}

@(private = "file")
m_command :: proc(app: ^App, c: ^Call) -> Reply {
	name, bad := need_string(c, "name")
	if bad.code != 0 { return bad }
	cmd := command(name)
	if cmd == nil { return fail(remote.ERR_PARAMS, fmt.tprintf("no command %q (Wren.listCommands lists them)", name)) }
	t := current_tab(app)
	if !command_enabled(app, t, cmd) { return fail(remote.ERR_FAILED, fmt.tprintf("the command %s is not available now", name)) }
	command_run(app, t, cmd)
	return frames_op(app, c, t, the_remote.cfg.settle_frames)
}

@(private = "file")
m_devtools :: proc(app: ^App, c: ^Call) -> Reply {
	panel, _ := remote.param_string(c.params, "panel", "console")
	switch panel {
	case "console":  devtools_open(app, .Console)
	case "elements": devtools_open(app, .Elements)
	case "network":  devtools_open(app, .Network)
	case "none", "close": if dev().visible { devtools_toggle(app) }
	case: return fail(remote.ERR_PARAMS, "panel: console, elements, network or none")
	}
	if dock, ok := remote.param_string(c.params, "dock"); ok && dock != "" {
		if dock == "window" {   // a window of their own (devtools_window.odin)
			devtools_detach(app)
		} else {
			for d in Dev_Dock { if DEV_DOCK_NAMES[d] == dock { if devtools_detached() { devtools_attach(app) }; devtools_set_dock(app, d) } }
		}
	}
	return frames_op(app, c, nil, the_remote.cfg.settle_frames + 1)
}
