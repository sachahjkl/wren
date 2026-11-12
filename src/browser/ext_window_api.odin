package browser

// What extensions do with tabs and windows (docs/extensions.md, sections 2.2 and 3.8), the shell's half: the router
// (src/page/ext_tabs.odin) checks a call, then asks here from a task of the loop of its own.
//
//   * tabs.create / update / remove, windows.create / update / remove (page.Ext_Embedder);
//   * the popout window: windows.create({type: "popup"}) makes a window with one tab and no tab strip and no toolbar
//     (build_ui asks ext_is_popout);
//   * offscreen documents: a tab that belongs to no window (it is in App.tab_ids, never in a strip): navigate loads it as
//     any tab, nothing paints it, its scripts run;
//   * the events reported back: tabs.onCreated (tab_new, a task later: the tab has its window and address then),
//     tabs.onUpdated (nav_to: loading, complete), tabs.onRemoved (tab_free); and, from ext_watch at each window's frame,
//     what changes without one place to hook: a window made or closed, the front window, a window's selected tab;
//   * the time since the last input in a window (idle.*), from the same frames' events.
// ext_watch compares a few numbers per window with what it reported last (Ext_Seen): no work in proportion to tabs.

import "core:slice"
import "core:strings"
import "toolkit:platform"
import "toolkit:ui"
import "wb:host"
import "wb:page"

// What ext_watch reported last.
Ext_Seen :: struct {
	primed:  bool,              // the first look only records (nothing changed before it)
	windows: [dynamic]int,      // the ids of the windows
	current: [dynamic][2]u64,   // per window: its id, its selected tab's id
	front:   int,               // the front window's id (-1: none)
}

// A popout window's size when the extension gives none (logical px).
EXT_POPOUT_SIZE :: [2]int{420, 640}

ext_windows_destroy :: proc(app: ^App) {
	for k, t in app.ext.offscreen {
		tab_discard(app, t)
		delete(k)
	}
	delete(app.ext.offscreen)
	for _, id in app.ext.popouts { delete(id) }
	delete(app.ext.popouts)
	delete(app.ext.seen.windows)
	delete(app.ext.seen.current)
}

// Whether `w` is a popout window of an extension: no tab strip, no toolbar (build_ui).
ext_is_popout :: proc(app: ^App, w: ^Browser_Window) -> bool {
	if !app.ext.started || len(app.ext.popouts) == 0 || w == nil { return false }
	return w.id in app.ext.popouts
}

// Whether `t` is the tab of an extension's offscreen document (it belongs to no window).
ext_is_offscreen_tab :: proc(app: ^App, t: ^Tab) -> bool {
	for _, x in app.ext.offscreen { if x == t { return true } }
	return false
}

ext_offscreen_page :: proc(app: ^App, p: ^page.Page) -> bool {
	for _, x in app.ext.offscreen { if x.page == p { return true } }
	return false
}

ext_window_info :: proc(app: ^App, w: ^Browser_Window) -> page.Ext_Window_Info {
	front := window_front(app)
	scale := w.win != nil ? max(w.win.dpi_scale, 0.5) : 1
	size := w.win != nil ? w.win.size : [2]int{}
	return page.Ext_Window_Info{
		id = i64(w.id), focused = w == front, popup = ext_is_popout(app, w),
		width = int(f32(size.x) / scale), height = int(f32(size.y) / scale), state = w.minimized ? "minimized" : "normal",
	}
}

// A tab as the router describes it (false: it belongs to no window).
ext_tab_info :: proc(app: ^App, t: ^Tab) -> (page.Ext_Tab_Info, bool) {
	w, i := window_of_tab(app, t)
	if w == nil { return {}, false }
	return page.Ext_Tab_Info{
		id = i64(t.id), window = i64(w.id), index = i64(i), url = t.url, title = t.title,
		active = i == w.current, pinned = t.pinned, loading = ext_tab_loading(t), page = t.page != nil ? page.page_id(t.page) : 0,
	}, true
}

// "loading" until its document's load event (Tab.load stays set after it: it is the navigation's record).
ext_tab_loading :: proc(t: ^Tab) -> bool {
	if nav_pending(t) { return true }
	return t.page != nil && page.document_ready_state(t.page) != .Complete
}

// Makes `w` the active window (tab_open and tab_new work in the active one); the caller makes `prev` active again.
@(private = "file")
ext_in_window :: proc(app: ^App, w: ^Browser_Window) -> (prev: ^Browser_Window) {
	prev = app.active
	if w != nil { window_activate(app, w) }
	return
}

////////////////////////////////
// What the router asks (page.Ext_Embedder)

ext_tab_create :: proc(user: rawptr, ext: string, spec: page.Ext_Tab_Spec) -> i64 {
	app := (^App)(user)
	w := spec.window >= 0 ? window_by_id(app, int(spec.window)) : window_front(app)
	if w == nil { return -1 }
	prev := ext_in_window(app, w)
	defer window_activate(app, prev)
	was := w.current
	t := tab_open(app, spec.url, origin = .User)
	if t == nil { return -1 }
	if !spec.active { w.current = clamp(was, 0, len(w.tabs) - 1) }
	if spec.index >= 0 { tab_move(app, t, w, at = int(spec.index), devtools_follow = false) }
	window_request(app, w, 2)
	return i64(t.id)
}

ext_tab_update :: proc(user: rawptr, tab: i64, u: string, activate: bool) -> bool {
	app := (^App)(user)
	t := tab_find(app, u64(tab))
	if t == nil { return false }
	w, _ := window_of_tab(app, t)
	if w == nil { return false }
	if u != "" {
		prev := ext_in_window(app, w)
		navigate(app, t, u, origin = .User)
		window_activate(app, prev)
	}
	if activate { tab_reveal(app, t) }
	window_request(app, w, 2)
	return true
}

ext_tab_remove :: proc(user: rawptr, tab: i64) -> bool {
	app := (^App)(user)
	t := tab_find(app, u64(tab))
	if t == nil { return false }
	w, _ := window_of_tab(app, t)
	if w == nil { return false }
	prev := ext_in_window(app, w)
	tab_close_tab(app, t)
	window_activate(app, prev)
	return true
}

ext_window_create :: proc(user: rawptr, ext: string, spec: page.Ext_Window_Spec) -> i64 {
	app := (^App)(user)
	src := window_front(app)
	if src == nil { return -1 }
	first := len(spec.urls) > 0 ? spec.urls[0] : ""
	size := EXT_POPOUT_SIZE
	if !spec.popup {
		scale := max(src.win.dpi_scale, 0.5)
		size = {int(f32(src.win.size.x) / scale), int(f32(src.win.size.y) / scale)}
	}
	if spec.width > 0 { size.x = clamp(spec.width, 100, 8192) }
	if spec.height > 0 { size.y = clamp(spec.height, 100, 8192) }
	at: Maybe([2]int)
	if spec.has_position { at = [2]int{spec.left, spec.top} }
	// the first tab is made in the front window, then moved (as Ctrl+N does: window_new)
	prev := ext_in_window(app, src)
	was := src.current
	t := tab_open(app, first, origin = .User)
	nw := t != nil ? window_open(app, size, at) : nil
	if nw == nil {
		if t != nil { tab_close_tab(app, t) }
		window_activate(app, prev)
		return -1
	}
	tab_move(app, t, nw, devtools_follow = false)
	src.current = clamp(was, 0, max(len(src.tabs) - 1, 0))
	if spec.popup {
		app.ext.popouts[nw.id] = strings.clone(ext)
	} else if len(spec.urls) > 1 {
		window_activate(app, nw)
		for u in spec.urls[1:] { tab_open(app, u, origin = .User) }
		nw.current = 0
	}
	window_activate(app, prev)
	if spec.focused { window_focus(app, nw, true) }
	window_request(app, nw, 4)
	// reported now (ext_watch would see it at the window's first frame)
	append(&app.ext.seen.windows, nw.id)
	page.ext_window_event_created(ext_window_info(app, nw))
	return i64(nw.id)
}

ext_window_update :: proc(user: rawptr, window: i64, focus: bool, left, top: int, move: bool) -> bool {
	app := (^App)(user)
	w := window_by_id(app, int(window))
	if w == nil { return false }
	if move && w.win != nil { platform.move_window(w.win, left, top) }
	if focus { window_focus(app, w, true) }
	window_request(app, w, 2)
	return true
}

ext_window_remove :: proc(user: rawptr, window: i64) -> bool {
	app := (^App)(user)
	w := window_by_id(app, int(window))
	if w == nil || len(app.windows) <= 1 { return false }   // (the last window is the browser: an extension does not end it)
	w.closing, w.closing_force = true, true   // (closed at the end of the pass, with its tabs: windows_pass)
	window_request(app, w, 2)
	return true
}

ext_offscreen_open :: proc(user: rawptr, ext, u: string) -> bool {
	app := (^App)(user)
	ext_offscreen_close(user, ext)
	// a tab of no window: made in the front window's list (tab_new appends there), then taken out of it at once
	prev := ext_in_window(app, window_front(app))
	t := tab_new(app)
	list := window_tabs(app, active_window(app))
	if len(list) > 0 && list[len(list) - 1] == t { pop(list) }
	window_activate(app, prev)
	app.ext.offscreen[strings.clone(ext)] = t
	if !navigate(app, t, u, origin = .User) {
		ext_offscreen_close(user, ext)
		return false
	}
	return true
}

ext_offscreen_close :: proc(user: rawptr, ext: string) {
	app := (^App)(user)
	t, ok := app.ext.offscreen[ext]
	if !ok { return }
	tab_discard(app, t)   // (still in the map while it goes: ext_tab_closed reports no tabs.onRemoved for it)
	k, _ := delete_key(&app.ext.offscreen, ext)
	delete(k)
}

ext_idle_seconds :: proc(user: rawptr) -> f64 {
	app := (^App)(user)
	return f64(max(host.now_ns(&app.loop) - app.ext.last_input_ns, 0)) / 1e9
}

ext_reload_from_runtime :: proc(user: rawptr, ext: string) {
	ext_reload((^App)(user), ext)
}

////////////////////////////////
// Events

// A tab was made (tab_new): reported from a task, once it has its window and its address.
ext_tab_created :: proc(app: ^App, t: ^Tab) {
	if !app.ext.started || len(ext_reg(app).list) == 0 { return }
	host.post(&app.loop, proc(data: rawptr) {
		app := the_app
		if app == nil || !app.ext.started { return }
		t := tab_find(app, u64(uintptr(data)))
		if t == nil { return }
		if info, ok := ext_tab_info(app, t); ok { page.ext_tab_event_created(info) }
	}, rawptr(uintptr(t.id)))
}

// A tab's navigation moved (nav_to): it started (loading), or it stopped with no document (complete). Reported from a
// task: the tab's address is set after nav_to.
ext_tab_nav :: proc(app: ^App, t: ^Tab, to: Nav_Phase) {
	if !app.ext.started || t.view != nil || len(ext_reg(app).list) == 0 { return }
	loading: bool
	#partial switch to {
	case .Requested: loading = true
	case .Idle:      loading = false   // (stopped, or a view of the browser; a document's load says "complete": page.ext_page_loaded)
	case: return
	}
	Job :: struct { tab: u64, loading: bool }
	j := new(Job)
	j^ = {t.id, loading}
	host.post(&app.loop, proc(data: rawptr) {
		j := (^Job)(data)
		defer free(j)
		app := the_app
		if app == nil || !app.ext.started { return }
		t := tab_find(app, j.tab)
		if t == nil { return }
		info, ok := ext_tab_info(app, t)
		if !ok { return }
		info.loading = j.loading
		page.ext_tab_event_updated(info, j.loading)
	}, j)
}

// Once per window's frame (build_ui): the input of the frame (idle.*), then the windows, the front window and the
// selected tabs compared with what was reported last.
ext_watch :: proc(app: ^App) {
	if !app.ext.started || shell_nested() { return }
	for ev in ui.build_events(active_window(app).ui) {
		#partial switch ev.kind {
		case .Key_Press, .Text, .Mouse_Move, .Mouse_Press, .Scroll, .Pointer_Down, .Pointer_Move:
			app.ext.last_input_ns = host.now_ns(&app.loop)
		}
	}
	sn := &app.ext.seen
	report := sn.primed
	sn.primed = true
	for w in app.windows {
		if slice.contains(sn.windows[:], w.id) { continue }
		append(&sn.windows, w.id)
		if report { page.ext_window_event_created(ext_window_info(app, w)) }
	}
	for i := len(sn.windows) - 1; i >= 0; i -= 1 {
		id := sn.windows[i]
		if window_by_id(app, id) != nil { continue }
		unordered_remove(&sn.windows, i)
		if pid, ok := app.ext.popouts[id]; ok { delete(pid); delete_key(&app.ext.popouts, id) }
		if report { page.ext_window_event_removed(i64(id)) }
	}
	front := window_front(app)
	fid := front != nil ? front.id : -1
	if fid != sn.front {
		sn.front = fid
		if report { page.ext_window_event_focus(i64(fid)) }
	}
	for i := len(sn.current) - 1; i >= 0; i -= 1 {
		if window_by_id(app, int(sn.current[i][0])) == nil { unordered_remove(&sn.current, i) }
	}
	for w in app.windows {
		t := window_current_tab(app, w)
		tid := t != nil ? t.id : 0
		at := -1
		for c, i in sn.current { if c[0] == u64(w.id) { at = i; break } }
		if at >= 0 && sn.current[at][1] == tid { continue }
		if at >= 0 { sn.current[at][1] = tid } else { append(&sn.current, [2]u64{u64(w.id), tid}) }
		if report && tid != 0 { page.ext_tab_event_activated(i64(tid), i64(w.id)) }
	}
}
