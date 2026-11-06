package browser

// The methods of the remote control channel. Names follow the Chrome DevTools Protocol where Wren has the same thing, so a
// CDP or WebDriver BiDi adapter can translate onto them; the others are in the `Wren.` domain. docs/remote.md lists them all
// with their parameters.

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import "wb:base"
import "wb:images"
import lay "wb:layout"
import "wb:page"
import "wb:remote"
import "wb:remote/api"

ui_toast_remote :: proc(text: string) { ui.toast(.Warn, "%s", text) }
ui_needs_frame :: proc(app: ^App) -> bool { return ui.needs_frame(active_window(app).ui) }
render_capture_busy :: proc(app: ^App) -> bool { return render.capture_pending(&app.r) }

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
	case "Remote.ping":          return m_ping()
	case "Remote.subscribe":     return m_subscribe(app, c, true)
	case "Remote.unsubscribe":   return m_subscribe(app, c, false)
	case "Browser.getVersion":   return m_version()
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
	case "Wren.memoryTrim":      return m_memory_trim(app)
	case "Wren.memoryReport":    return m_memory_report(c)
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
	case "Wren.setupState":      return m_setup_state(app)
	case "Wren.updateState":     return done(fmt.tprintf(`{{"checking":%v}}`, control_update_checking(app)))
	case "Wren.recordInput":     return m_record(app, c)
	case "Wren.timeline":        return m_timeline(app, c)
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
	if key != "" { base.write_json_string(b, key); strings.write_byte(b, ':') }
}
j_str :: proc(b: ^strings.Builder, key, v: string) { j_key(b, key); base.write_json_string(b, v) }
j_int :: proc(b: ^strings.Builder, key: string, v: i64) { j_key(b, key); fmt.sbprintf(b, "%d", v) }
j_num :: proc(b: ^strings.Builder, key: string, v: f64) { j_key(b, key); fmt.sbprintf(b, "%.3f", v) }
j_bool :: proc(b: ^strings.Builder, key: string, v: bool) { j_key(b, key); strings.write_string(b, v ? "true" : "false") }
j_raw :: proc(b: ^strings.Builder, key, v: string) { j_key(b, key); strings.write_string(b, v) }
j_rect :: proc(b: ^strings.Builder, key: string, r: api.Rect) { j_raw(b, key, fmt.tprintf("[%d,%d,%d,%d]", int(r.x), int(r.y), int(r.w), int(r.h))) }

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
	p := wnd.page_rect.min + b.min - doc_scroll_vec(t)
	return {p.x, p.y, b.max.x - b.min.x, b.max.y - b.min.y}, true
}

// The document's horizontal offset that has the window rectangle `er` (element_window_rect) in the middle of the page area
// `pr`, or starting at its left for one wider than it; in the document's range.
@(private = "file")
document_x_centering :: proc(t: ^Tab, er: [4]f32, pr: draw.Rect) -> f32 {
	doc_left := er[0] - pr.min.x + doc_scroll_vec(t).x
	view := pr.max.x - pr.min.x
	lo, hi := lay.doc_scroll_x_range(&t.layout, view)
	return clamp(er[2] > view ? doc_left : doc_left + er[2] / 2 - view / 2, lo, hi)
}

// An element with a box that shows at least in part in the page's area.
element_visible :: proc(app: ^App, t: ^Tab, h: base.Handle) -> bool {
	r, ok := element_window_rect(app, t, h)
	if !ok || r[2] <= 0 || r[3] <= 0 { return false }
	pr := active_window(app).page_rect
	return r[0] < pr.max.x && r[0] + r[2] > pr.min.x && r[1] < pr.max.y && r[1] + r[3] > pr.min.y
}

frames_op :: proc(app: ^App, c: ^Call, t: ^Tab, n: int, result := "") -> Reply {
	op := op_new(app, c, .Frames, 10_000, "frames")
	op.tab = t != nil ? t.id : 0
	op.until = app.remote.frame_no + u64(max(n, 1))
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
m_ping :: proc() -> Reply {
	x := control_ping()
	return done(fmt.tprintf(`{{"protocol":%d,"version":%s,"pid":%d}}`, x.protocol, base.json_quote(x.version), x.pid))
}

@(private = "file")
m_version :: proc() -> Reply {
	x := control_version()
	return done(fmt.tprintf(`{{"product":%s,"revision":%s,"toolkit":%s,"protocol":%d,"build":%s}}`, base.json_quote(x.product), base.json_quote(x.revision), base.json_quote(x.toolkit), x.protocol, base.json_quote(x.build)))
}

@(private = "file")
m_setup_state :: proc(app: ^App) -> Reply {
	x := control_setup_state(app)
	box :: proc(r: api.Rect) -> string { return fmt.tprintf("[%v,%v,%v,%v]", r.x, r.y, r.w, r.h) }
	return done(fmt.tprintf(`{{"open":%v,"known":%v,"confirmUninstall":%v,"busy":%d,"note":%s,"primary":%s,"uninstall":%s,"secondary":%s}}`,
		x.open, x.known, x.confirm_uninstall, x.busy, base.json_quote(x.note), box(x.primary), box(x.uninstall), box(x.secondary)))
}

@(private = "file")
m_subscribe :: proc(app: ^App, c: ^Call, on: bool) -> Reply {
	control_subscribe(app, c.conn, on)
	return done(`{"events":["Page.loadEventFired","Runtime.consoleAPICalled"]}`)
}

@(private = "file")
m_close :: proc(app: ^App, c: ^Call) -> Reply {
	code, _ := remote.param_int(c.params, "exitCode")
	remote_answer(c.conn, c.id, done())   // (the client has its answer before the browser goes)
	remote.close_client(c.conn)
	control_close(app, code)
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
	x := control_bounds(app)
	b := builder()
	j_begin(&b)
	j_int(&b, "windowId", i64(x.window))
	j_int(&b, "left", i64(x.left)); j_int(&b, "top", i64(x.top))
	j_int(&b, "outerWidth", i64(x.outer_width)); j_int(&b, "outerHeight", i64(x.outer_height))
	j_int(&b, "width", i64(x.width)); j_int(&b, "height", i64(x.height))   // the client area, in pixels
	j_str(&b, "windowState", x.state)
	j_num(&b, "dpiScale", x.dpi_scale); j_num(&b, "uiScale", x.ui_scale); j_num(&b, "pageScale", x.page_scale)
	j_bool(&b, "headless", x.headless)
	j_bool(&b, "visible", x.visible)
	// the page area of its last frame and what was prepared for it (page_frame.odin)
	j_rect(&b, "pageRect", x.page_rect)
	j_str(&b, "pagePrep", x.page_prep)
	j_end(&b)
	return done(strings.to_string(b))
}

// width / height: the client area in pixels (what a capture of the window measures); left / top: the window's corner. What is left out stays.
@(private = "file")
m_window_set :: proc(app: ^App, c: ^Call) -> Reply {
	now := control_bounds(app)
	change: api.Window_Change
	change.state, _ = remote.param_string(c.params, "windowState")
	w, has_w := remote.param_int(c.params, "width")
	h, has_h := remote.param_int(c.params, "height")
	left, has_l := remote.param_int(c.params, "left")
	top, has_t := remote.param_int(c.params, "top")
	if has_w || has_h { change.size = [2]int{has_w ? w : now.width, has_h ? h : now.height} }
	if has_l || has_t { change.pos = [2]int{has_l ? left : now.left, has_t ? top : now.top} }
	change.dpi, _ = remote.param_int(c.params, "dpi")
	if why := control_set_window(app, change); why != "" { return fail(remote.ERR_PARAMS, why) }
	return m_window_get(app)
}

// The window as if it had moved to a monitor of `dpi`: the system's WM_DPICHANGED, with the rectangle the system suggests (the same
// top left, the size in proportion), through the window procedure as the real one goes (wren ctl window --dpi n: a machine with
// one monitor tests a window that changes monitors, and two windows on monitors of different scales).
window_simulate_dpi :: proc(app: ^App, w: ^Browser_Window, dpi: int) {
	if platform.is_offscreen(w.win) {
		// no monitor to move to: the emulated scale changes and the offscreen target follows (the renderer is resized in the frame)
		platform.set_offscreen_dpi(w.win, dpi)
		render.resize(&app.r, w.win.size)
		window_request(app, w, 4)
		return
	}
	// a real window: ask the window manager to change its DPI (remote_window_<os>.odin: WM_DPICHANGED on Windows; a
	// no-op on Linux, where a test drives DPI through an offscreen window instead).
	window_native_simulate_dpi(w.win, dpi)
	window_request(app, w, 4)
}

// The window's state and rectangle as asked (the parts that are not asked for stay): `Browser.setWindowBounds`, and the reset and
// the checkpoints of remote_state.odin.
// The state a headless window says it is in. (Each system's window keeps it in a field of its own.)
@(private = "file")
window_emulated_state :: proc(w: ^platform.Window, state: string) {
	when ODIN_OS == .Windows {
		switch state {
		case "normal":     w.off_state = .Normal
		case "minimized":  w.off_state = .Minimized
		case "maximized":  w.off_state = .Maximized
		case "fullscreen": w.off_state = .Fullscreen
		}
	} else {
		switch state {
		case "normal":     w.show = .Normal
		case "minimized":  w.show = .Minimized
		case "maximized":  w.show = .Maximized
		case "fullscreen": w.show = .Fullscreen
		}
	}
}

window_apply :: proc(app: ^App, state: string, has_state: bool, w, h, left, top: int, has_w, has_h, has_l, has_t: bool) {
	wnd := active_window(app)
	if platform.is_offscreen(wnd.win) {
		// a headless window: the state and the rectangle are emulated, the client size is set straight (no window frame)
		if has_state {
			if state == "normal" && platform.is_fullscreen(wnd.win) { toggle_fullscreen(app) }
			window_emulated_state(wnd.win, state)
		}
		if has_l || has_t { platform.move_window(wnd.win, has_l ? left : wnd.win.off_place[0], has_t ? top : wnd.win.off_place[1]) }
		if has_w || has_h {
			platform.set_size(wnd.win, {has_w ? w : wnd.win.size.x, has_h ? h : wnd.win.size.y})
			render.resize(&app.r, wnd.win.size)
		}
		request_frames(app, 4)
		return
	}
	if has_state {
		switch state {
		case "normal":
			if platform.is_fullscreen(wnd.win) { toggle_fullscreen(app) }
			window_native_restore(wnd.win)   // remote_window_<os>.odin: SW_SHOWNOACTIVATE + SW_RESTORE on Windows; un-maximize on Linux
		case "minimized":  platform.minimize(wnd.win)
		case "maximized":  if !platform.is_maximized(wnd.win) { platform.toggle_maximize(wnd.win) }
		case "fullscreen": if !platform.is_fullscreen(wnd.win) { toggle_fullscreen(app) }
		}
	}
	if has_w || has_h || has_l || has_t {
		// a real window: set its bounds through the window manager (remote_window_<os>.odin). The client size asked for is
		// turned into an outer rectangle for the frame on Windows; on Wayland the position cannot be set (move is a no-op).
		cw, ch := has_w ? w : wnd.win.size.x, has_h ? h : wnd.win.size.y
		window_native_set_bounds(wnd.win, left, top, cw, ch, has_w || has_h, has_l || has_t)
	}
	request_frames(app, 4)
}

////////////////////////////////
// Targets (tabs)

@(private = "file")
m_targets :: proc(app: ^App) -> Reply {
	x := control_tabs(app)
	b := builder()
	j_begin(&b)
	j_key(&b, "targetInfos"); j_begin(&b, '[')
	for t in x.tabs {
		j_key(&b, ""); j_begin(&b)
		j_int(&b, "targetId", i64(t.id)); j_str(&b, "type", "page"); j_str(&b, "title", t.title); j_str(&b, "url", t.url)
		j_int(&b, "windowId", i64(t.window))
		j_bool(&b, "active", t.active); j_bool(&b, "loading", t.loading); j_bool(&b, "attached", true)
		// the sidebar's state of the tab (tab_groups.odin), and where the last frame drew it in the tab bar
		j_bool(&b, "pinned", t.pinned); j_int(&b, "group", i64(t.group))
		j_bool(&b, "playing", t.playing); j_bool(&b, "audible", t.audible); j_bool(&b, "muted", t.muted)   // tab_sound.odin
		if t.group_color != "" { j_str(&b, "groupName", t.group_name); j_str(&b, "groupColor", t.group_color); j_bool(&b, "groupCollapsed", t.group_collapsed) }
		if t.has_rect { j_rect(&b, "rect", t.rect) }
		j_end(&b)
	}
	j_end(&b, ']')
	j_key(&b, "tabGroups"); j_begin(&b, '[')
	for g in x.groups {
		j_key(&b, ""); j_begin(&b)
		j_int(&b, "windowId", i64(g.window)); j_int(&b, "id", i64(g.id)); j_str(&b, "name", g.name)
		j_str(&b, "color", g.color); j_bool(&b, "collapsed", g.collapsed)
		if g.has_rect { j_rect(&b, "rect", g.rect) }
		j_end(&b)
	}
	j_end(&b, ']'); j_end(&b)
	return done(strings.to_string(b))
}

@(private = "file")
m_target_create :: proc(app: ^App, c: ^Call) -> Reply {
	address, _ := remote.param_string(c.params, "url")
	background, _ := remote.param_bool(c.params, "background")
	t := control_new_tab(app, address, background)
	if wait, ok := remote.param_string(c.params, "wait"); ok && wait != "none" && wait != "" { return start_wait(app, c, t, wait, fmt.tprintf(`{{"targetId":%d}}`, t.id)) }
	return done(fmt.tprintf(`{{"targetId":%d}}`, t.id))
}

// The windows: id, whether it is the front one, its tabs and the current one, its size and state.
@(private = "file")
m_windows :: proc(app: ^App) -> Reply {
	b := builder()
	j_begin(&b)
	j_key(&b, "windows"); j_begin(&b, '[')
	for w in control_windows(app) {
		j_key(&b, ""); j_begin(&b)
		j_int(&b, "windowId", i64(w.id)); j_bool(&b, "front", w.front); j_int(&b, "tabs", i64(w.tabs))
		j_int(&b, "hwnd", i64(w.hwnd))   // (a UI Automation client reads one window: src\tools\e2e\a11y_uia.odin; 0 where there is no HWND)
		j_bool(&b, "headless", w.headless)
		j_int(&b, "currentTabId", i64(w.current_tab))
		j_int(&b, "left", i64(w.left)); j_int(&b, "top", i64(w.top)); j_int(&b, "width", i64(w.width)); j_int(&b, "height", i64(w.height))
		j_str(&b, "windowState", w.state)
		j_num(&b, "dpiScale", w.dpi_scale)
		j_int(&b, "clientLeft", i64(w.client_left)); j_int(&b, "clientTop", i64(w.client_top))   // (where its client area is on the screen)
		// a tab carried over its tabs (tab_drag.odin): where it would go and where the mark is (client pixels, along the tabs)
		if w.dropping {
			j_key(&b, "drop"); j_begin(&b)
			j_int(&b, "index", i64(w.drop_index)); j_int(&b, "group", i64(w.drop_group)); j_bool(&b, "pinned", w.drop_pinned)
			j_num(&b, "mark", w.drop_mark)
			j_end(&b)
		}
		// its developer tools (devtools.odin: each window has its own)
		d := w.devtools
		j_key(&b, "devtools"); j_begin(&b)
		j_bool(&b, "visible", d.visible); j_str(&b, "dock", d.dock); j_str(&b, "panel", d.panel)
		j_bool(&b, "detached", d.detached)
		if d.has_window {
			j_int(&b, "hwnd", i64(d.hwnd)); j_str(&b, "title", d.title)
			j_bool(&b, "window", true)
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
	control_bring_to_front(app)   // (above the others, without the system's focus, shown or not: a drag across windows finds it on top)
	return done()
}

// The window closes with its tabs, at the end of the pass (the last window ends the browser: that is Browser.close).
@(private = "file")
m_window_close :: proc(app: ^App) -> Reply {
	if why := control_close_window(app); why != "" { return fail(remote.ERR_FAILED, why) }
	return done()
}

// Target.moveTarget {targetId, to: "new" | a window id, index}: the tab goes to another window with its page as it is.
@(private = "file")
m_target_move :: proc(app: ^App, c: ^Call) -> Reply {
	id, ok := remote.param_int(c.params, "targetId")
	if !ok { return fail(remote.ERR_PARAMS, "parameter \"targetId\" is missing") }
	at := -1
	if v, has := remote.param_int(c.params, "index"); has { at = v }
	to := -1
	if word, is_str := remote.param_string(c.params, "to"); is_str {
		if word != "new" { return fail(remote.ERR_PARAMS, "\"to\" is \"new\" or a window id") }
	} else if wid, is_int := remote.param_int(c.params, "to"); is_int {
		to = wid
	} else {
		return fail(remote.ERR_PARAMS, "parameter \"to\" is missing")
	}
	dest, why := control_move_tab(app, id, to, at)
	if dest == nil { return fail(to < 0 ? remote.ERR_FAILED : remote.ERR_PARAMS, why) }
	return done(fmt.tprintf(`{{"targetId":%d,"windowId":%d}}`, id, dest.id))
}

@(private = "file")
m_target_activate :: proc(app: ^App, c: ^Call) -> Reply {
	id, ok := remote.param_int(c.params, "targetId")
	if !ok { return fail(remote.ERR_PARAMS, "parameter \"targetId\" is missing") }
	if !control_activate_tab(app, id) { return fail(remote.ERR_PARAMS, fmt.tprintf("no tab %d", id)) }
	return done()
}

@(private = "file")
m_target_close :: proc(app: ^App, c: ^Call) -> Reply {
	id, ok := remote.param_int(c.params, "targetId")
	if !ok { return fail(remote.ERR_PARAMS, "parameter \"targetId\" is missing") }
	if control_close_tab(app, id) { return done(`{"success":true}`) }
	return fail(remote.ERR_PARAMS, fmt.tprintf("no tab %d", id))
}

////////////////////////////////
// Navigation and waiting

// A wait of kind `what` ("load", "idle", "stable") on `t`, answered with `result` (JSON) when it holds.
start_wait :: proc(app: ^App, c: ^Call, t: ^Tab, what: string, result := "") -> Reply {
	kind, ok := api.wait_by_name(what == "" ? "none" : what)
	if !ok { return fail(remote.ERR_PARAMS, "wait: none, load, idle, stable or quiet") }
	l := Wait_Limits{timeout_ms = timeout_of(c)}
	l.idle_ms, _ = remote.param_int(c.params, "idleMs")
	l.quiet_ms, _ = remote.param_int(c.params, "quietMs")
	l.max_cpu, _ = remote.param_float(c.params, "maxCpuMs")
	return control_wait(app, c, t, kind, l, result)
}

@(private = "file")
m_navigate :: proc(app: ^App, c: ^Call) -> Reply {
	address, bad := need_string(c, "url")
	if bad.code != 0 { return bad }
	t, e := tab_of(app, c)
	if t == nil { return e }
	control_navigate(app, t, address)
	what, _ := remote.param_string(c.params, "wait")
	return start_wait(app, c, t, what, fmt.tprintf(`{{"tabId":%d,"url":%s}}`, t.id, base.json_quote(t.url)))
}

@(private = "file")
m_reload :: proc(app: ^App, c: ^Call) -> Reply {
	t, e := tab_of(app, c)
	if t == nil { return e }
	ignore, _ := remote.param_bool(c.params, "ignoreCache")
	control_reload(app, t, ignore)
	what, _ := remote.param_string(c.params, "wait")
	return start_wait(app, c, t, what, fmt.tprintf(`{{"tabId":%d}}`, t.id))
}

@(private = "file")
m_history :: proc(app: ^App, c: ^Call, delta: int) -> Reply {
	t, e := tab_of(app, c)
	if t == nil { return e }
	control_history(app, t, delta)
	what, _ := remote.param_string(c.params, "wait")
	return start_wait(app, c, t, what, fmt.tprintf(`{{"tabId":%d}}`, t.id))
}

@(private = "file")
m_stop :: proc(app: ^App, c: ^Call) -> Reply {
	t, e := tab_of(app, c)
	if t == nil { return e }
	control_stop_loading(app, t)
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
		visible, _ := remote.param_bool(c.params, "visible")
		return control_wait_selector(app, c, t, sel, visible, timeout_of(c))
	case "function":
		expr, bad := need_string(c, "expression")
		if bad.code != 0 { return bad }
		return control_wait_js(app, c, t, expr, timeout_of(c))
	case "frames":
		n, _ := remote.param_int(c.params, "frames", 2)
		return frames_op(app, c, t, n)
	}
	return start_wait(app, c, t, what)
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
	return control_eval(app, c, t, expr, await, timeout_of(c))
}

@(private = "file")
m_outer_html :: proc(app: ^App, c: ^Call) -> Reply {
	t, e := tab_of(app, c)
	if t == nil { return e }
	sel, _ := remote.param_string(c.params, "selector")
	html, code, why := control_outer_html(t, sel)
	if code != 0 { return fail(code, why) }
	return done(fmt.tprintf(`{{"outerHTML":%s}}`, base.json_quote(html)))
}

@(private = "file")
m_query_all :: proc(app: ^App, c: ^Call) -> Reply {
	sel, bad := need_string(c, "selector")
	if bad.code != 0 { return bad }
	t, e := tab_of(app, c)
	if t == nil { return e }
	limit, _ := remote.param_int(c.params, "limit", QUERY_ALL_DEFAULT_LIMIT)
	x, code, why := control_query_all(app, t, sel, limit)
	if code != 0 { return fail(code, why) }
	b := builder()
	j_begin(&b)
	j_int(&b, "count", i64(x.count))
	j_key(&b, "nodes"); j_begin(&b, '[')
	for n in x.nodes {
		j_key(&b, ""); j_begin(&b)
		j_str(&b, "outerHTML", n.outer_html)
		if n.has_box { j_raw(&b, "box", fmt.tprintf("[%.2f,%.2f,%.2f,%.2f]", n.box.x, n.box.y, n.box.w, n.box.h)) }
		j_end(&b)
	}
	j_end(&b, ']'); j_end(&b)
	return done(strings.to_string(b))
}

// The element's box: in CSS pixels from the page's top-left corner (what getBoundingClientRect says), and in window pixels.
@(private = "file")
m_box_model :: proc(app: ^App, c: ^Call) -> Reply {
	sel, bad := need_string(c, "selector")
	if bad.code != 0 { return bad }
	t, e := tab_of(app, c)
	if t == nil { return e }
	x, code, why := control_box_model(app, t, sel)
	if code != 0 { return fail(code, why) }
	return done(fmt.tprintf(`{{"found":true,"visible":%v,"x":%.2f,"y":%.2f,"width":%.2f,"height":%.2f,"window":{{"x":%.1f,"y":%.1f,"width":%.1f,"height":%.1f}}}}`,
		x.visible, x.box.x, x.box.y, x.box.w, x.box.h, x.window.x, x.window.y, x.window.w, x.window.h))
}

@(private = "file")
m_computed_style :: proc(app: ^App, c: ^Call) -> Reply {
	sel, bad := need_string(c, "selector")
	if bad.code != 0 { return bad }
	t, e := tab_of(app, c)
	if t == nil { return e }
	names: []string
	if arr, ok := remote.param_array(c.params, "properties"); ok {
		list := make([dynamic]string, 0, len(arr), context.temp_allocator)
		for v in arr { if s, is_s := v.(json.String); is_s { append(&list, string(s)) } }
		names = list[:]
	}
	x, why := control_computed_style(t, sel, names)
	if why != "" { return fail(remote.ERR_FAILED, why) }
	b := builder()
	j_begin(&b)
	j_key(&b, "computedStyle"); j_begin(&b)
	for p in x { j_str(&b, p.name, p.value) }
	j_end(&b); j_end(&b)
	return done(strings.to_string(b))
}

////////////////////////////////
// Capture

// Page.captureScreenshot {path, bytes, target: window|page|rect|selector, selector, clip {x,y,width,height} (window pixels, target
// rect), scale, settle (frames), timeout}
@(private = "file")
capture_request_of :: proc(c: ^Call) -> (q: Capture_Request, bad: Reply) {
	q = {timeout_ms = timeout_of(c), settle = the_app.remote.cfg.settle_frames}
	if s, ok := remote.param_float(c.params, "scale"); ok && s > 0 { q.scale = f32(s) }
	q.path, _ = remote.param_string(c.params, "path")
	q.bytes, _ = remote.param_bool(c.params, "bytes")
	tgt, _ := remote.param_string(c.params, "target", "window")
	switch tgt {
	case "window": q.target = .Window
	case "page":   q.target = .Page
	case "rect":
		q.target = .Rect
		clip, ok := remote.param_object(c.params, "clip")
		if !ok { return q, fail(remote.ERR_PARAMS, "target rect needs \"clip\": {x, y, width, height}") }
		x, _ := remote.param_float(clip, "x"); y, _ := remote.param_float(clip, "y")
		w, _ := remote.param_float(clip, "width"); h, _ := remote.param_float(clip, "height")
		q.rect = {f32(x), f32(y), f32(w), f32(h)}
	case "selector":
		q.target = .Selector
		q.selector, bad = need_string(c, "selector")
		if bad.code != 0 { return }
	case:
		return q, fail(remote.ERR_PARAMS, "target: window, page, rect or selector")
	}
	if settle, has := remote.param_int(c.params, "settle"); has { q.settle = settle }
	return q, {}
}

@(private = "file")
m_capture :: proc(app: ^App, c: ^Call) -> Reply {
	t, e := tab_of(app, c)
	if t == nil { return e }
	q, bad := capture_request_of(c)
	if bad.code != 0 { return bad }
	return control_capture(app, c, t, q)
}

// Wren.snapshot {path, target, selector, scale}: <path>.png (as Page.captureScreenshot), <path>.html (the document as serialized),
// <path>.json (the page's url, title, size and the box of every element, in CSS pixels from the page's corner).
@(private = "file")
m_snapshot :: proc(app: ^App, c: ^Call) -> Reply {
	prefix, missing := need_string(c, "path")
	if missing.code != 0 { return missing }
	t, e := tab_of(app, c)
	if t == nil { return e }
	q, bad := capture_request_of(c)
	if bad.code != 0 { return bad }
	q.path = strings.concatenate({prefix, ".png"}, context.temp_allocator)
	q.snapshot = prefix
	return control_capture(app, c, t, q)
}

// A frame of the window read back: to a file, in the answer, or (a call of this process) as pixels. See capture_step.
Capture_Request :: struct {
	target:     Capture_Target,
	rect:       [4]f32,    // Rect: x, y, w, h (window pixels)
	selector:   string,
	scale:      f32,       // 0: 1
	path:       string,
	snapshot:   string,    // the document and its boxes too, beside the picture (snapshot_files): the files' prefix
	bytes:      bool,
	settle:     int,       // frames first
	timeout_ms: int,
}

control_capture :: proc(app: ^App, c: ^Call, t: ^Tab, q: Capture_Request) -> Reply {
	op := op_new(app, c, .Capture, q.timeout_ms, "the capture")
	op.tab, op.target, op.rect = t.id, q.target, q.rect
	op.scale = q.scale > 0 ? clamp(q.scale, CAPTURE_SCALE_LEAST, CAPTURE_SCALE_MOST) : 1
	if q.path != "" { op.path = strings.clone(q.path) }
	if q.selector != "" { op.arg = strings.clone(q.selector) }
	if q.snapshot != "" { op.snapshot = strings.clone(q.snapshot) }
	op.bytes = q.bytes || (q.path == "" && c.local == nil)
	op.until = app.remote.frame_no + u64(max(q.settle, 0)) + 1
	// a real window on the taskbar draws nothing: it comes back without taking the focus, and goes back after. A headless
	// window renders whatever its emulated state, so nothing to do there.
	if !platform.is_offscreen(active_window(app).win) && platform.is_minimized(active_window(app).win) {
		window_native_show_no_activate(active_window(app).win)
		op.stage = -1
	}
	request_frames(app, 3)
	return Reply{deferred = true}
}
@(private = "file") CAPTURE_SCALE_LEAST :: 0.01
@(private = "file") CAPTURE_SCALE_MOST :: 16

capture_step :: proc(app: ^App, op: ^Remote_Op, t: ^Tab, timed_out: bool) {
	r := &app.remote
	finish :: proc(app: ^App, op: ^Remote_Op, rep: Reply) {
		if op.stage == -2 && !platform.is_offscreen(active_window(app).win) { window_native_minimize_no_activate(active_window(app).win) }
		if op.asked && rep.code != 0 { render.capture_cancel(&app.r) }   // (asked, not taken: the next capture may start)
		if op.asked { app.remote.capture_window = 0 }
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
			if !op.scrolled && (er[1] < pr.min.y || er[1] + er[3] > pr.max.y || er[0] < pr.min.x || er[0] + er[2] > pr.max.x) {
				// not all of it in view: scrolled to (its top for an element taller than the view, else its middle), then looked at again
				op.scrolled = true
				doc_top := er[1] - pr.min.y + t.scroll
				view := pr.max.y - pr.min.y
				scroll_document_to(app, t, {document_x_centering(t, er, pr), max(er[3] > view ? doc_top : doc_top + er[3] / 2 - view / 2, 0)}, false)
				op.until = r.frame_no + 2
				return
			}
			x0, y0 := max(er[0], pr.min.x), max(er[1], pr.min.y)
			x1, y1 := min(er[0] + er[2], pr.max.x), min(er[1] + er[3], pr.max.y)
			if x1 <= x0 || y1 <= y0 { finish(app, op, fail(remote.ERR_FAILED, "the element is outside the page's visible area (scroll to it first)")); return }
			rect = {int(math.floor(x0)), int(math.floor(y0)), int(math.ceil(x1 - x0)), int(math.ceil(y1 - y0))}
		}
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
		if op.local != nil && op.path == "" {
			op.local.done, op.local.size = true, size
			if op.scale != 1 {
				op.local.rgba, op.local.size.x, op.local.size.y = scale_rgba(pixels, size.x, size.y, op.scale)
			} else {
				op.local.rgba = slice.clone(pixels)
			}
			op.local = nil
			if op.asked { app.remote.capture_window = 0 }
			op_finish_silent(op)
			return
		}
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

inject :: proc(app: ^App, ev: platform.Event) {
	ev := ev
	#partial switch ev.kind {
	case .Mouse_Press: app.inject_held += {ev.button}
	case .Mouse_Release: app.inject_held -= {ev.button}
	}
	held := app.inject_held
	if ev.kind == .Mouse_Move || ev.kind == .Mouse_Press || ev.kind == .Mouse_Release { ev.buttons = held }
	platform.inject_event(active_window(app).win, ev)
	app.remote.inputs += 1
	request_frames(app, 4)
}

// A point given in the page's CSS pixels (from its top-left corner), or in window pixels (`"space": "window"`).
@(private = "file")
point_of :: proc(app: ^App, c: ^Call, xk, yk: string) -> (p: [2]f32, ok: bool) {
	x, hx := remote.param_float(c.params, xk)
	y, hy := remote.param_float(c.params, yk)
	if !hx || !hy { return {}, false }
	return control_point(app, {x, y}, space_of(c)), true
}

@(private = "file")
space_of :: proc(c: ^Call) -> api.Space {
	space, _ := remote.param_string(c.params, "space")
	return space == "window" ? .Window : .Page
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
	case "back":   return .Back
	case "forward": return .Forward
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
	case "mouseMoved":    return control_hover(app, c, pos, mods)
	case "mousePressed":  return control_press(app, c, pos, button_of(c), mods)
	case "mouseReleased": return control_release(app, c, pos, button_of(c), mods)
	case "mouseWheel":
		dx, _ := remote.param_float(c.params, "deltaX")
		dy, _ := remote.param_float(c.params, "deltaY")
		if n, has := remote.param_float(c.params, "notches"); has { dy = n * 100 }
		return control_wheel(app, c, pos, {dx, dy}, mods)
	}
	return fail(remote.ERR_PARAMS, "type: mouseMoved, mousePressed, mouseReleased or mouseWheel")
}

// Wren.click {x, y | selector, button, count, space}
@(private = "file")
m_click :: proc(app: ^App, c: ^Call) -> Reply {
	t, e := tab_of(app, c)
	if t == nil { return e }
	count, _ := remote.param_int(c.params, "count", 1)
	if sel, ok := remote.param_string(c.params, "selector"); ok { return control_click(app, c, t, sel, button_of(c), count, timeout_of(c)) }
	pos, ok := point_of(app, c, "x", "y")
	if !ok { return fail(remote.ERR_PARAMS, "give x and y, or a selector") }
	return control_click_at(app, c, t, pos, button_of(c), count, mods_of(c))
}

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
	r := &app.remote
	request_frames(app, 2)
	if r.frame_no < op.until { return }
	// (the click is done and its frames are made: what it did to the element, which may have gone with it, is the page's)
	if op.stage == CLICK_DONE { op_finish(op, done(fmt.tprintf(`{{"x":%.1f,"y":%.1f}}`, op.pos.x, op.pos.y))); return }
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
		// the scroll boxes it is in first (a button below the fold of a dialog that scrolls: a consent banner), then the page
		if lay.reveal_in_scroll_containers(&t.layout, h) { op.until = r.frame_no + 2 }
		op.stage = 1
	case 1:
		pr := wnd.page_rect
		center_y := er[1] + er[3] / 2
		center_x := er[0] + er[2] / 2
		if center_y < pr.min.y || center_y > pr.max.y || center_x < pr.min.x || center_x > pr.max.x {
			// document coordinates of the element's middle, to the middle of the view
			doc_y := er[1] - wnd.page_rect.min.y + t.scroll
			scroll_document_to(app, t, {document_x_centering(t, er, pr), max(doc_y + er[3] / 2 - (pr.max.y - pr.min.y) / 2, 0)}, false)
			op.until = r.frame_no + 2
		}
		op.stage = 2
	case 2:
		pos := [2]f32{er[0] + er[2] / 2, er[1] + er[3] / 2}
		click_at(app, pos, op.button, op.count, {})
		op.pos = pos
		op.stage = CLICK_DONE
		op.until = r.frame_no + u64(max(r.cfg.settle_frames, 1))
	}
}
@(private = "file") CLICK_DONE :: 3

// Wren.drop {x, y, files: [paths], text, url, html, leave}: another application's drag over the window, through the
// toolkit's drop target path (platform.drop_inject): enter, over, then the drop at (x, y) (with `leave`: it leaves
// instead). The reply says what the window answered (the effect the app set).
@(private = "file")
m_drop :: proc(app: ^App, c: ^Call) -> Reply {
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
	leave, _ := remote.param_bool(c.params, "leave")
	return control_drop(app, c, pos, &d, leave, mods_of(c))
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
	r := Drag_Request{from = from, to = to, button = button_of(c), timeout_ms = timeout_of(c)}
	r.steps, _ = remote.param_int(c.params, "steps", api.DRAG_STEPS)
	// "via": points passed through on the way (window points may be outside the window: the drag leaves it and comes
	// back, through the window's own drop target, never the real mouse)
	via := make([dynamic][2]f32, context.temp_allocator)
	if arr, has := remote.param_array(c.params, "via"); has {
		for v in arr {
			pt, is := v.(json.Array)
			if !is || len(pt) != 2 { continue }
			num :: proc(v: json.Value) -> (f64, bool) {
				#partial switch x in v {
				case json.Float: return f64(x), true
				case json.Integer: return f64(x), true
				}
				return 0, false
			}
			x, xok := num(pt[0])
			y, yok := num(pt[1])
			if !xok || !yok { continue }
			append(&via, control_point(app, {x, y}, space_of(c)))
		}
	}
	r.via = via[:]
	// "hold": the button stays down at the end (a picture of the drag on its way: a tab carried over another window's bar);
	// "resume": a drag held before goes on from here (no press), and ends as asked
	r.hold, _ = remote.param_bool(c.params, "hold")
	r.resume, _ = remote.param_bool(c.params, "resume")
	return control_drag(app, c, r)
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
	for op in app.remote.ops {
		if op.kind != .Drag || (op.stage != 1 && op.stage != 2) { continue }
		pts := drag_path(op)
		total := op.count * (len(pts) - 1)
		steps := make([dynamic]platform.Drag_Step, context.temp_allocator)
		for k in op.idx + 1 ..= total { append(&steps, platform.Drag_Step{pos = drag_point(op, pts, k)}) }
		if len(steps) == 0 { append(&steps, platform.Drag_Step{pos = op.to}) }
		app.inject_held -= {op.button}   // (released in the system's drag: no release event follows)
		op.stage = 3
		op.until = app.remote.frame_no + u64(max(app.remote.cfg.settle_frames, 1))
		return steps[:], true
	}
	return nil, false
}

// Press (stage 0), one move per frame (stage 1, idx: the steps made), release at the last position (stage 2), settle.
drag_step :: proc(app: ^App, op: ^Remote_Op) {
	r := &app.remote
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
	return control_type(app, c, text)
}

// Wren.key {keys: "Ctrl+L"}: the modifiers go down, the key goes down and up, the modifiers go up
@(private = "file")
m_key :: proc(app: ^App, c: ^Call) -> Reply {
	combo, bad := need_string(c, "keys")
	if bad.code != 0 { return bad }
	repeat, _ := remote.param_int(c.params, "repeat", 1)
	return control_key(app, c, combo, repeat)
}

// Input.dispatchKeyEvent {type: keyDown|keyUp|rawKeyDown|char, key, text, modifiers}
@(private = "file")
m_key_event :: proc(app: ^App, c: ^Call) -> Reply {
	kind, bad := need_string(c, "type")
	if bad.code != 0 { return bad }
	text, _ := remote.param_string(c.params, "text")
	name, _ := remote.param_string(c.params, "key")
	switch kind {
	case "keyDown", "rawKeyDown": return control_key_event(app, c, .Down, name, text, mods_of(c))
	case "keyUp":                 return control_key_event(app, c, .Up, name, text, mods_of(c))
	case "char":                  return control_key_event(app, c, .Text, "", text, mods_of(c))
	}
	return fail(remote.ERR_PARAMS, "type: keyDown, keyUp, rawKeyDown or char")
}

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
		name := base.ascii_lower(strings.trim_space(p))
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
m_memory_trim :: proc(app: ^App) -> Reply {
	memory_trim(app)
	return done("{}")
}

// How many allocations a report the channel asks for lists: enough to see what the small ones add up to.
@(private = "file") MEMORY_REPORT_LINES :: 400

@(private = "file")
m_memory_report :: proc(c: ^Call) -> Reply {
	file, _ := remote.param_string(c.params, "file")
	if file == "" { return fail(remote.ERR_PARAMS, "file: where the report goes") }
	memory_map_report(file, MEMORY_REPORT_LINES)
	memory_heap_report(strings.concatenate({file, ".heap"}, context.temp_allocator), MEMORY_REPORT_LINES)
	base.mem_snapshot(strings.concatenate({file, ".live"}, context.temp_allocator))
	return done("{}")
}

@(private = "file")
m_stats :: proc(app: ^App, c: ^Call) -> Reply {
	reset_latency, _ := remote.param_bool(c.params, "resetLatency")
	reset_frames, _ := remote.param_bool(c.params, "resetFrames")
	s := control_stats_all(app)
	control_stats_reset(app, reset_frames, reset_latency)
	b := builder()
	j_begin(&b)
	stats_json(&b, s)
	j_end(&b)
	return done(strings.to_string(b))
}

// control_stats_all as the channel gives it.
@(private = "file")
stats_json :: proc(b: ^strings.Builder, s: api.Stats) {
	size :: proc(b: ^strings.Builder, key: string, v: [2]int) { j_raw(b, key, fmt.tprintf("[%d,%d]", v.x, v.y)) }
	surface :: proc(b: ^strings.Builder, key: string, x: api.Surface) {
		j_key(b, key); j_begin(b)
		j_bool(b, "fixed", x.fixed); size(b, "size", x.size); size(b, "buffers", x.buffers); size(b, "source", x.source)
		j_end(b)
	}
	j_int(b, "pid", i64(s.pid)); j_num(b, "uptimeMs", s.uptime_ms); j_num(b, "fps", s.fps)
	j_int(b, "workingSetBytes", i64(s.working_set_bytes)); j_int(b, "privateBytes", i64(s.private_bytes))
	m := s.memory
	j_key(b, "memory"); j_begin(b)
	j_int(b, "heapAllocated", i64(m.heap_allocated)); j_int(b, "heapCommitted", i64(m.heap_committed)); j_int(b, "vmRw", i64(m.vm_rw)); j_int(b, "vmExec", i64(m.vm_exec))
	j_int(b, "wasmModules", i64(m.wasm_modules)); j_int(b, "wasmCodeBytes", i64(m.wasm_code_bytes)); j_int(b, "wasmInstances", i64(m.wasm_instances))
	j_int(b, "wasmCompiles", i64(m.wasm_compiles)); j_int(b, "wasmShippedHits", i64(m.wasm_shipped_hits)); j_int(b, "wasmShippedRefused", i64(m.wasm_shipped_refused))
	j_int(b, "jsCacheEntries", i64(m.js_cache_entries)); j_int(b, "jsCacheBytes", i64(m.js_cache_bytes)); j_int(b, "imageEntries", i64(m.image_entries)); j_int(b, "imageBytes", i64(m.image_bytes))
	j_int(b, "fontEntries", i64(m.font_entries)); j_int(b, "fontBytes", i64(m.font_bytes)); j_int(b, "httpResidentBytes", i64(m.http_resident_bytes))
	j_int(b, "gpuImages", i64(m.gpu_images)); j_int(b, "gpuGlyphs", i64(m.gpu_glyphs)); j_int(b, "gpuTargets", i64(m.gpu_targets)); j_int(b, "gpuOutlines", i64(m.gpu_outlines)); j_int(b, "pagesBytes", i64(m.pages_bytes)); j_int(b, "bfcacheBytes", i64(m.bfcache_bytes)); j_int(b, "picturesBytes", i64(m.pictures_bytes)); j_int(b, "trims", i64(m.trims))
	j_end(b)
	loop_rates_json(b, s.loop)
	j_int(b, "framesDrawn", i64(s.frames_drawn)); j_int(b, "framesPresented", i64(s.frames_presented)); j_num(b, "framePeriodMs", s.frame_period_ms)
	j_int(b, "chromeFrames", i64(s.chrome_frames)); j_int(b, "fullFrames", i64(s.full_frames))
	j_int(b, "paintFrames", i64(s.paint_frames)); j_int(b, "modalLoops", i64(s.modal_loops))
	// the frames of the thread through the frame gate (windows.odin): admitted, of which inside another, asked for where none
	// may begin (a repaint later), and the moves the state machine does not have (0, or a bug)
	j_key(b, "frameGate"); j_begin(b)
	j_int(b, "begun", i64(s.frame_gate.begun)); j_int(b, "nested", i64(s.frame_gate.nested)); j_int(b, "deferred", i64(s.frame_gate.deferred))
	j_int(b, "violations", i64(s.frame_gate.violations)); j_str(b, "lastViolation", s.frame_gate.last_violation)
	j_end(b)
	j_bool(b, "menuOpen", s.menu_open)   // a menu of the chrome is open (the page's context menu, the tab menu...)
	j_int(b, "requestsInFlight", i64(s.requests_in_flight)); j_int(b, "tabs", i64(s.tabs)); j_int(b, "nodes", i64(s.nodes))
	j_int(b, "pendingOps", i64(s.pending_ops))   // the commands that wait (a wait, a navigation's load): a test sees one is registered before it acts on it
	j_int(b, "inputEvents", i64(s.input_events))
	// the back/forward cache since start-up (bfcache.odin): its coverage (traversals served from it) and what kept
	// pages out of it, by reason
	bc := s.bfcache
	j_key(b, "bfcache"); j_begin(b)
	j_int(b, "cached", i64(bc.cached)); j_int(b, "stores", i64(bc.stores)); j_int(b, "restores", i64(bc.restores))
	j_int(b, "evictions", i64(bc.evictions)); j_int(b, "refusals", i64(bc.refusals))
	j_int(b, "traversals", i64(bc.traversals)); j_int(b, "misses", i64(bc.misses))
	j_num(b, "hitRate", bc.traversals > 0 ? f64(bc.traversals - bc.misses) / f64(bc.traversals) : 0)
	j_key(b, "reasons"); j_begin(b)
	for r in bc.reasons { j_int(b, r.reason, i64(r.count)) }
	j_end(b)
	j_end(b)
	j_int(b, "workersRunning", i64(s.workers_running)); j_int(b, "sharedWorkers", i64(s.shared_workers)); j_bool(b, "historyRestoring", s.history_restoring)
	// the picture of the last drag that went to the system (dnd_image.odin), as the system holds it: "WxH@x,y", "" for none
	j_bool(b, "dropTarget", s.drop_target); j_str(b, "dragPicture", s.drag_picture); j_str(b, "dragImage", s.drag_image)
	j_int(b, "prefsNetApplied", i64(s.prefs_net_applied))
	j_bool(b, "chromeAnimating", s.chrome_animating)   // the interface has an animation under way (a sidebar opening...)
	j_bool(b, "groupNameFocused", s.group_name_focused)   // a tab group's name is being edited (tab_sidebar_list.odin)
	j_str(b, "backend", s.backend)
	// accessibility (a11y_chrome.odin): updates sent to the screen readers' adapter, refused by it, nodes of the last one
	a := s.a11y
	j_int(b, "a11yUpdates", i64(a.updates)); j_int(b, "a11yRefused", i64(a.refused)); j_int(b, "a11yLastNodes", i64(a.last_nodes)); j_int(b, "a11yNodes", i64(a.nodes))
	j_int(b, "a11yPageBuilds", i64(a.page_builds)); j_int(b, "a11yPagePatches", i64(a.page_patches)); j_int(b, "a11yPageSends", i64(a.page_sends))
	j_int(b, "a11yPageRefused", i64(a.page_refused)); j_int(b, "a11yPageNodes", i64(a.page_nodes)); j_int(b, "a11yPageWritten", i64(a.page_written))
	j_int(b, "a11yPageFrames", i64(a.page_frames)); j_int(b, "a11yPageVerifyFailed", i64(a.page_verify_failed)); j_str(b, "a11yPageFallback", a.page_fallback); j_str(b, "a11yPageVerifyDiff", a.page_verify_diff)
	// the caret of a focused field of the page in this window: blinking (a timer of its own), and shown in this frame
	j_bool(b, "caretBlinking", s.caret_blinking); j_bool(b, "caretShown", s.caret_shown); j_bool(b, "frontWindow", s.front_window)
	j_bool(b, "devtools", s.devtools); j_int(b, "devtoolsWindows", i64(s.devtools_windows))
	j_int(b, "devtoolsRoomChecks", i64(s.devtools_room_checks)); j_int(b, "devtoolsRoomWrong", i64(s.devtools_room_wrong))   // devtools.odin: dev_width
	j_int(b, "gpuProcessId", i64(s.gpu_process_id)); j_int(b, "gpuProcessStarts", i64(s.gpu_process_starts))
	j_key(b, "cursor"); j_begin(b)
	j_str(b, "name", s.cursor.name); j_bool(b, "custom", s.cursor.custom); j_str(b, "source", s.cursor.source); size(b, "size", s.cursor.size); size(b, "hotspot", s.cursor.hotspot)
	j_end(b)
	surface(b, "surface", s.surface); surface(b, "panelSurface", s.panel_surface)
	if s.has_latency {
		l := s.latency
		j_key(b, "latency"); j_begin(b)
		j_bool(b, "tearingSupported", l.tearing_supported); j_bool(b, "tearing", l.tearing)
		j_int(b, "samples", i64(l.samples)); j_num(b, "refreshMs", l.refresh_ms)
		j_int(b, "framesShown", i64(l.frames_shown)); j_int(b, "framesShownFromInput", i64(l.frames_shown_from_input))
		j_num(b, "queueMean", l.queue_mean); j_int(b, "queueMax", i64(l.queue_max))
		for st in ([?]struct { name: string, v: api.Latency_Stat }{{"waitMs", l.wait}, {"workMs", l.work}, {"presentMs", l.present}, {"scanMs", l.scan}, {"totalMs", l.total}, {"totalRefreshes", l.total_refreshes}}) {
			j_key(b, st.name); j_begin(b)
			j_num(b, "p50", st.v.p50); j_num(b, "p95", st.v.p95); j_num(b, "max", st.v.max); j_num(b, "mean", st.v.mean)
			j_end(b)
		}
		j_end(b)
	}
	j_int(b, "frames", i64(s.frames))
	j_num(b, "cpuMs", s.cpu_ms); j_num(b, "cpuP95Ms", s.cpu_p95_ms); j_num(b, "cpuP99Ms", s.cpu_p99_ms); j_num(b, "cpuMaxMs", s.cpu_max_ms)
	j_num(b, "gpuMs", s.gpu_ms); j_bool(b, "gpuMeasured", s.gpu_measured)
	j_int(b, "framesRequested", i64(s.frames_requested))
	// the presents since resetFrames, the gaps between them, and how the window's frames were asked for (platform.Pump_Stats)
	j_int(b, "framesAtOnce", i64(s.frames_at_once)); j_int(b, "frameGaps", i64(s.frame_gaps))
	j_num(b, "frameGapP50Ms", s.frame_gap_p50_ms); j_num(b, "frameGapP95Ms", s.frame_gap_p95_ms); j_num(b, "frameGapP99Ms", s.frame_gap_p99_ms); j_num(b, "frameGapMaxMs", s.frame_gap_max_ms)
	j_int(b, "ignoredSizeMoves", i64(s.ignored_size_moves))
	if s.has_drag_samples {
		// [read, shown, mouse_x, finger_x, dt, moves, done, waited ms, page_w, area_w] (ticks in microseconds)
		j_key(b, "dragSamples"); j_begin(b, '[')
		for x in s.drag_samples {
			j_raw(b, "", fmt.tprintf("[%d,%d,%.2f,%.2f,%.5f,%d,%d,%.3f,%.1f,%.1f]", x.read_us, x.shown_us, x.pointer, x.edge, x.dt, x.moves, x.done_us, x.waited_ms, x.page_width, x.area_width))
		}
		j_end(b, ']')
	}
	j_num(b, "hz", s.hz); j_num(b, "hzReported", s.hz_reported); j_num(b, "hzMax", s.hz_max); j_num(b, "hzNow", s.hz_now); j_num(b, "hzSwapChain", s.hz_swap_chain)
	j_bool(b, "variableRefresh", s.variable_refresh); j_bool(b, "frameCapStrict", s.frame_cap_strict)
	j_str(b, "frameStates", s.frame_states); j_str(b, "frameState", s.frame_state)
	j_int(b, "resizeEchoesSkipped", i64(s.resize_echoes_skipped)); j_str(b, "resizeFrameCauses", s.resize_frame_causes)
	// how often the subsystems were configured again by preference writes (prefs_apply.odin)
	j_int(b, "prefsCacheApplied", i64(s.prefs_cache_applied)); j_int(b, "prefsDownloadsApplied", i64(s.prefs_downloads_applied))
	if s.layout_items > 0 { j_int(b, "layoutItems", i64(s.layout_items)) }
	// the process and the state a reset empties (so that a test can see both the cost of what it did and that a reset worked)
	j_num(b, "cpuTimeMs", s.cpu_time_ms); j_num(b, "cpuUserMs", s.cpu_user_ms); j_num(b, "cpuKernelMs", s.cpu_kernel_ms)
	j_num(b, "jsFirstRealmMs", s.js_first_realm_ms)
	j_int(b, "threads", i64(s.threads)); j_int(b, "handles", i64(s.handles)); j_int(b, "gdiObjects", i64(s.gdi_objects)); j_int(b, "userObjects", i64(s.user_objects))
	j_int(b, "cookies", i64(s.cookies)); j_int(b, "storageSites", i64(s.storage_sites)); j_int(b, "cacheEntries", i64(s.cache_entries))
	j_int(b, "historyVisits", i64(s.history_visits)); j_int(b, "closedTabs", i64(s.closed_tabs)); j_int(b, "downloadsActive", i64(s.downloads_active))
	j_int(b, "checkpoints", i64(s.checkpoints))
}

@(private = "file")
m_console :: proc(app: ^App, c: ^Call) -> Reply {
	t, e := tab_of(app, c)
	if t == nil { return e }
	since, _ := remote.param_int(c.params, "since", 0)
	clear_after, _ := remote.param_bool(c.params, "clear")
	total := control_console_total(t)
	b := builder()
	j_begin(&b)
	j_int(&b, "total", i64(total))
	j_key(&b, "lines"); j_begin(&b, '[')
	for l in control_console(t, since, clear_after) {
		j_key(&b, ""); j_begin(&b)
		j_int(&b, "n", i64(l.n)); j_str(&b, "level", l.level); j_str(&b, "text", l.text)
		j_end(&b)
	}
	j_end(&b, ']'); j_end(&b)
	return done(strings.to_string(b))
}

@(private = "file")
m_network :: proc(app: ^App, c: ^Call) -> Reply {
	t, e := tab_of(app, c)
	if t == nil { return e }
	clear_after, _ := remote.param_bool(c.params, "clear")
	x := control_network(t, clear_after)
	b := builder()
	j_begin(&b)
	j_int(&b, "bytes", i64(x.bytes))
	j_num(&b, "interactive", x.doc.interactive); j_num(&b, "dcl", x.doc.dcl); j_num(&b, "load", x.doc.load); j_num(&b, "paint", x.doc.paint); j_num(&b, "contentful", x.doc.contentful)
	j_key(&b, "requests"); j_begin(&b, '[')
	for en in x.requests {
		j_key(&b, ""); j_begin(&b)
		j_int(&b, "id", i64(en.id)); j_str(&b, "method", en.method); j_str(&b, "url", en.url)
		j_str(&b, "destination", en.destination)
		j_int(&b, "status", i64(en.status)); j_str(&b, "mime", en.mime); j_int(&b, "bytes", i64(en.bytes))
		j_bool(&b, "finished", en.has_ms); if en.has_ms { j_num(&b, "ms", en.ms) }
		j_str(&b, "cache", en.cache)
		if en.failed { j_bool(&b, "failed", true); j_str(&b, "error", en.error) }
		j_str(&b, "protocol", en.protocol); j_num(&b, "startMs", en.start_ms)
		if en.has_timing {
			j_bool(&b, "hasTiming", true)
			j_num(&b, "queued", en.queued); j_num(&b, "dnsStart", en.dns_start); j_num(&b, "dnsEnd", en.dns_end); j_num(&b, "connectStart", en.connect_start); j_num(&b, "connectEnd", en.connect_end)
			j_num(&b, "sending", en.sending); j_num(&b, "response", en.response); j_num(&b, "done", en.done)
		}
		j_end(&b)
	}
	j_end(&b, ']'); j_end(&b)
	return done(strings.to_string(b))
}

////////////////////////////////
// Preferences, commands, panels

pref_json :: proc(p: api.Pref) -> string {
	b := builder()
	j_begin(&b)
	j_str(&b, "name", p.name)
	switch v in p.value {
	case bool:   j_bool(&b, "value", v)
	case i64:    j_int(&b, "value", v)
	case f64:    j_num(&b, "value", v)
	case string: j_str(&b, "value", v)
	}
	j_str(&b, "text", p.text)
	j_str(&b, "default", p.default_text)
	j_str(&b, "source", p.source)
	j_bool(&b, "locked", p.locked); j_bool(&b, "restart", p.restart)
	j_end(&b)
	return strings.to_string(b)
}

@(private = "file")
m_pref_get :: proc(app: ^App, c: ^Call) -> Reply {
	name, bad := need_string(c, "name")
	if bad.code != 0 { return bad }
	p, ok := control_pref(app, name)
	if !ok { return fail(remote.ERR_PARAMS, fmt.tprintf("no preference %q", name)) }
	return done(pref_json(p))
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
	if why := control_pref_set(app, name, text, override); why != "" { return fail(remote.ERR_FAILED, why) }
	p, _ := control_pref(app, name)
	return done(pref_json(p))
}

@(private = "file")
m_pref_list :: proc(app: ^App, c: ^Call) -> Reply {
	prefix, _ := remote.param_string(c.params, "prefix")
	b := builder()
	j_begin(&b)
	j_key(&b, "prefs"); j_begin(&b, '[')
	for p in control_prefs(app, prefix) { j_raw(&b, "", pref_json(p)) }
	j_end(&b, ']'); j_end(&b)
	return done(strings.to_string(b))
}

@(private = "file")
m_commands :: proc(app: ^App) -> Reply {
	b := builder()
	j_begin(&b)
	j_key(&b, "commands"); j_begin(&b, '[')
	for cmd in control_commands(app) {
		j_key(&b, ""); j_begin(&b)
		j_str(&b, "name", cmd.name); j_str(&b, "title", cmd.title); j_str(&b, "category", cmd.category)
		j_str(&b, "shortcut", cmd.shortcut); j_bool(&b, "enabled", cmd.enabled)
		j_end(&b)
	}
	j_end(&b, ']'); j_end(&b)
	return done(strings.to_string(b))
}

@(private = "file")
m_command :: proc(app: ^App, c: ^Call) -> Reply {
	name, bad := need_string(c, "name")
	if bad.code != 0 { return bad }
	t := current_tab(app)
	if why := control_command(app, t, name); why != "" { return fail(strings.has_prefix(why, "no command") ? remote.ERR_PARAMS : remote.ERR_FAILED, why) }
	return frames_op(app, c, t, app.remote.cfg.settle_frames)
}

@(private = "file")
m_devtools :: proc(app: ^App, c: ^Call) -> Reply {
	panel, _ := remote.param_string(c.params, "panel", "console")
	dock, _ := remote.param_string(c.params, "dock")
	if why := control_devtools(app, panel, dock); why != "" { return fail(remote.ERR_PARAMS, why) }
	return frames_op(app, c, nil, app.remote.cfg.settle_frames + 1)
}
