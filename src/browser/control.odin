package browser

// Controlling the browser from code, typed: what the remote methods do (remote_methods.odin only decodes a request's JSON and
// calls these) and what a program in this process calls directly (src/e2e). A call that must wait for frames, a load or a script
// becomes a Remote_Op answered through its Call: to a client of the channel, or into a Control_Outcome the caller runs the loop
// for (control_run). What is read comes back in the types of wb:remote/api, whichever side reads it.

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:render"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:fetch"
import "wb:host"
import "wb:remote"
import "wb:remote/api"

// How long a wait of an in-process call looks again at what it waits for (ms): the loop sleeps in between.
CONTROL_POLL_MS :: 1

// The answer of an op started by a program in this process. Its strings are its own: control_outcome_free.
Control_Outcome :: struct {
	done:      bool,
	code:      int,      // 0: success
	message:   string,
	// of a script
	has_value: bool,
	kind:      string,   // JavaScript's type name
	text:      string,   // a string's value, else its JSON
	// of a capture with no file
	rgba:      []u8,
	size:      [2]int,
}

control_outcome_free :: proc(o: ^Control_Outcome) {
	delete(o.message); delete(o.kind); delete(o.text); delete(o.rgba)
	o^ = {}
}

// A program in this process drives this browser: no channel, the same machinery (the ops are looked at after each frame), and
// frames made as soon as they are asked for.
control_begin :: proc(app: ^App) {
	r := &the_remote
	r.active = true
	r.timer = base.NIL_HANDLE
	r.cfg.poll_ms = CONTROL_POLL_MS
	app.frames_at_once = true
	remote_take_baseline(app)
}

// Runs the loop until the call has its answer. false: the browser was told to end meanwhile.
control_run :: proc(app: ^App, o: ^Control_Outcome) -> bool {
	for !o.done { if !app_turn(app) { return false } }
	return true
}

// The call of a program in this process.
control_call :: proc(o: ^Control_Outcome) -> Call { return Call{local = o} }

// The window a stretch of calls is about (0: the one that is active). What it gives back goes to control_leave.
control_enter :: proc(app: ^App, window: int) -> ^Browser_Window {
	prev := app.active
	if window != 0 { if w := window_by_id(app, window); w != nil { window_activate(app, w) } }
	return prev
}

control_leave :: proc(app: ^App, prev: ^Browser_Window) {
	if prev != nil && prev != app.active && slice.contains(app.windows[:], prev) { window_activate(app, prev) }
}

// The tab of a call: by id, else the active window's current one (nil: no such tab).
control_tab :: proc(app: ^App, id: int) -> ^Tab {
	if id != 0 { return tab_by_id(app, u64(id)) }
	return current_tab(app)
}

////////////////////////////////
// Waiting

// What a wait may also say (0: the channel's defaults).
Wait_Limits :: struct {
	timeout_ms: int,
	idle_ms:    int,      // how long the network stays quiet for a wait for idle or stable
	quiet_ms:   int,
	max_cpu:    f64,
}

// A wait on `t`, answered with `result` (JSON, for a client) when it holds.
control_wait :: proc(app: ^App, c: ^Call, t: ^Tab, what: api.Wait, l: Wait_Limits = {}, result := "") -> Reply {
	kind: Remote_Wait
	switch what {
	case .None:   return done(result == "" ? "{}" : result)
	case .Load:   kind = .Load
	case .Idle:   kind = .Idle
	case .Stable: kind = .Stable
	case .Quiet:  kind = .Quiet
	}
	op := op_new(app, c, .Wait, l.timeout_ms, api.WAIT_NAMES[what])
	op.tab, op.wait = t.id, kind
	op.idle_ms = l.idle_ms   // 0: browser.remote.idle_ms
	if kind == .Quiet {
		// (the window starts at the first look: a wait that begins in the middle of work does not count the work)
		op.quiet_ms = l.quiet_ms > 0 ? l.quiet_ms : the_remote.cfg.quiet_ms
		op.max_cpu = l.max_cpu > 0 ? l.max_cpu : f64(the_remote.cfg.quiet_cpu_ms)
		op.t0 = host.now_ns(&app.loop)
		op.cpu0, _, _ = process_cpu_ms()
	}
	op.result = strings.clone(result)
	return Reply{deferred = true}
}

control_wait_selector :: proc(app: ^App, c: ^Call, t: ^Tab, selector: string, visible: bool, timeout_ms := 0) -> Reply {
	op := op_new(app, c, .Wait, timeout_ms, fmt.tprintf("an element matching %s", selector))
	op.tab, op.wait, op.arg = t.id, .Selector, strings.clone(selector)
	op.visible = visible
	return Reply{deferred = true}
}

control_wait_js :: proc(app: ^App, c: ^Call, t: ^Tab, expression: string, timeout_ms := 0) -> Reply {
	op := op_new(app, c, .Wait, timeout_ms, "the script condition to hold")
	op.tab, op.wait, op.arg = t.id, .Function, strings.clone(expression)
	return Reply{deferred = true}
}

// `n` more frames have been made.
control_wait_frames :: proc(app: ^App, c: ^Call, t: ^Tab, n: int, result := "") -> Reply { return frames_op(app, c, t, n, result) }

////////////////////////////////
// Scripts

// What came back of a script, read from its console line (remote_take_console).
@(private = "file")
eval_into_outcome :: proc(o: ^Control_Outcome, obj: json.Object) {
	o.done = true
	if ok, _ := remote.param_int(obj, "ok"); ok == 0 {
		e, _ := remote.param_object(obj, "e")
		name, _ := remote.param_string(e, "name")
		msg, _ := remote.param_string(e, "message")
		stack, _ := remote.param_string(e, "stack")
		text := name == "" ? msg : fmt.tprintf("%s: %s", name, msg)
		o.code = remote.ERR_FAILED
		o.message = strings.clone(stack == "" ? text : fmt.tprintf("%s\n%s", text, stack))
		return
	}
	t, _ := remote.param_string(obj, "t")
	v, has := remote.param_string(obj, "v")
	o.has_value = true
	o.kind = strings.clone(t)
	if !has || t == "undefined" { return }
	if t == "string" {
		parsed, err := json.parse(transmute([]byte)v, json.Specification.JSON, true, context.temp_allocator)
		if text, is_text := parsed.(json.String); err == .None && is_text { o.text = strings.clone(string(text)); return }
	}
	o.text = strings.clone(v)
}

// A script's answer that came for an op: to whom it asked.
op_finish_eval :: proc(op: ^Remote_Op, obj: json.Object) {
	if op.local != nil {
		eval_into_outcome(op.local, obj)
		op.local = nil
		op_finish_silent(op)
		return
	}
	op_finish(op, eval_reply(obj))
}

// Runs `expression` in the tab's page; its answer comes at once or, for a promise it waits for, later.
control_eval :: proc(app: ^App, c: ^Call, t: ^Tab, expression: string, await: bool, timeout_ms := 0) -> Reply {
	r := &the_remote
	delete(r.stash_text); r.stash_text, r.stash_id = "", 0
	id, ran := eval_start(t, expression, await)
	if !ran { return fail(remote.ERR_FAILED, "the tab has no page, or JavaScript is off for it (javascript.* preferences)") }
	if r.stash_id == id {
		text := r.stash_text
		defer { delete(text); r.stash_text, r.stash_id = "", 0 }
		if c.local != nil {
			v, err := json.parse(transmute([]byte)text, json.Specification.JSON, true, context.temp_allocator)
			obj, ok := v.(json.Object)
			if err != .None || !ok { return fail(remote.ERR_FAILED, "unreadable script answer") }
			eval_into_outcome(c.local, obj)
			return Reply{deferred = true}
		}
		return eval_reply_text(text)
	}
	op := op_new(app, c, .Eval, timeout_ms, "script")
	op.eval_id, op.tab = id, t.id   // (its answer counts from this tab only)
	return Reply{deferred = true}
}

////////////////////////////////
// Input

// A point of a call in window pixels: from the page's CSS pixels, or as it is.
control_point :: proc(app: ^App, p: api.Point, space: api.Space) -> [2]f32 {
	if space == .Window { return {f32(p.x), f32(p.y)} }
	s := page_scale(app)
	return active_window(app).page_rect.min + {f32(p.x) * s, f32(p.y) * s}
}

control_button :: proc(b: api.Button) -> platform.Mouse_Button {
	switch b {
	case .Left:   return .Left
	case .Right:  return .Right
	case .Middle: return .Middle
	}
	return .Left
}

// A click at a point (window pixels).
control_click_at :: proc(app: ^App, c: ^Call, t: ^Tab, pos: [2]f32, button: platform.Mouse_Button, count: int, mods: platform.Modifiers = {}) -> Reply {
	click_at(app, pos, button, max(count, 1), mods)
	return frames_op(app, c, t, the_remote.cfg.settle_frames, fmt.tprintf(`{{"x":%.1f,"y":%.1f}}`, pos.x, pos.y))
}

// A click on an element: scrolled into view first, on the middle of its box.
control_click :: proc(app: ^App, c: ^Call, t: ^Tab, selector: string, button: platform.Mouse_Button, count: int, timeout_ms := 0) -> Reply {
	op := op_new(app, c, .Click, timeout_ms, fmt.tprintf("the element %s", selector))
	op.tab, op.arg, op.button, op.count = t.id, strings.clone(selector), button, max(count, 1)
	op.until = the_remote.frame_no
	request_frames(app, 3)
	return Reply{deferred = true}
}

control_hover :: proc(app: ^App, c: ^Call, pos: [2]f32, mods: platform.Modifiers = {}) -> Reply {
	inject(app, {kind = .Mouse_Move, pos = pos, mods = mods})
	return frames_op(app, c, nil, the_remote.cfg.settle_frames)
}

// A button goes down, and stays down until control_release (a press held over frames: autoscroll, a splitter).
control_press :: proc(app: ^App, c: ^Call, pos: [2]f32, button: platform.Mouse_Button, mods: platform.Modifiers = {}) -> Reply {
	inject(app, {kind = .Mouse_Press, pos = pos, button = button, mods = mods})
	return frames_op(app, c, nil, the_remote.cfg.settle_frames)
}

control_release :: proc(app: ^App, c: ^Call, pos: [2]f32, button: platform.Mouse_Button, mods: platform.Modifiers = {}) -> Reply {
	inject(app, {kind = .Mouse_Release, pos = pos, button = button, mods = mods})
	return frames_op(app, c, nil, the_remote.cfg.settle_frames)
}

// The wheel: `delta` in pixels.
control_wheel :: proc(app: ^App, c: ^Call, pos: [2]f32, delta: [2]f64, mods: platform.Modifiers = {}) -> Reply {
	inject(app, {kind = .Scroll, pos = pos, delta = {f32(delta.x) / 100, f32(delta.y) / 100}, mods = mods})
	return frames_op(app, c, nil, the_remote.cfg.settle_frames)
}

Drag_Request :: struct {
	from, to: [2]f32,
	via:      [][2]f32,
	steps:    int,
	button:   platform.Mouse_Button,
	hold:     bool,
	resume:   bool,
	timeout_ms: int,
}

// Press, moves (one per frame), release: see drag_step.
control_drag :: proc(app: ^App, c: ^Call, d: Drag_Request) -> Reply {
	op := op_new(app, c, .Drag, d.timeout_ms, "drag")
	op.pos, op.to, op.count, op.button = d.from, d.to, clamp(d.steps, 1, DRAG_STEPS_MOST), d.button
	for v in d.via { append(&op.via, v) }
	op.hold = d.hold
	if d.resume {
		if op.button not_in inject_held { op_finish(op, fail(remote.ERR_FAILED, "no drag is held (drag --hold first)")); return Reply{deferred = true} }
		op.stage, op.idx = 1, 0
	}
	op.until = the_remote.frame_no
	request_frames(app, 3)
	return Reply{deferred = true}
}
@(private = "file") DRAG_STEPS_MOST :: 1000

// Another application's drag over the window: enter, over, the drop (or it leaves).
control_drop :: proc(app: ^App, c: ^Call, pos: [2]f32, d: ^platform.Drag_Data, leave: bool, mods: platform.Modifiers = {}) -> Reply {
	wnd := active_window(app)
	if platform.drag_data_empty(d^) { return fail(remote.ERR_PARAMS, "give files, text, url or html") }
	if !platform.drop_inject(wnd.win, .Drop_Enter, pos, d, mods = mods) { return fail(remote.ERR_PARAMS, "this system has no drag and drop") }
	platform.drop_inject(wnd.win, .Drop_Over, pos, mods = mods)
	platform.drop_inject(wnd.win, leave ? .Drop_Leave : .Drop, pos, mods = mods)
	the_remote.inputs += 1
	request_frames(app, 4)
	return frames_op(app, c, nil, the_remote.cfg.settle_frames)
}

control_type :: proc(app: ^App, c: ^Call, text: string) -> Reply {
	for ch in text {
		switch ch {
		case '\n', '\r': emit_key(app, .Return, {}, 0)
		case '\t':       emit_key(app, .Tab, {}, 0)
		case:            inject(app, {kind = .Text, text = ch})
		}
	}
	return frames_op(app, c, nil, the_remote.cfg.settle_frames)
}

// Keys: "Ctrl+L", several separated by spaces.
control_key :: proc(app: ^App, c: ^Call, combo: string, repeat := 1) -> Reply {
	for part in strings.split(combo, " ", context.temp_allocator) {
		if part == "" { continue }
		key, mods, ok := parse_combo(part)
		if !ok { return fail(remote.ERR_PARAMS, fmt.tprintf("unknown key %q (examples: Enter, Ctrl+L, Shift+Tab, F5, a)", part)) }
		for _ in 0 ..< clamp(repeat, 1, KEY_REPEAT_MOST) { emit_key(app, key, mods, key_text(key, mods)) }
	}
	return frames_op(app, c, nil, the_remote.cfg.settle_frames)
}
@(private = "file") KEY_REPEAT_MOST :: 1000

////////////////////////////////
// Tabs, windows

control_tabs :: proc(app: ^App, allocator := context.temp_allocator) -> api.Targets {
	s :: proc(v: string, a: mem.Allocator) -> string { return strings.clone(v, a) }
	tabs := make([dynamic]api.Tab, allocator)
	groups := make([dynamic]api.Tab_Group, allocator)
	for w in app.windows {
		for t, i in window_tabs(app, w)^ {
			if t.frame != nil { continue }
			x := api.Tab{
				id = int(t.id), window = w.id, group = int(t.group), title = s(t.title, allocator), url = s(t.url, allocator),
				active = i == window_current(app, w)^, loading = !tab_loaded(app, t), pinned = t.pinned,
				playing = t.sound.playing, audible = tab_speaker(app, t) == .Sound, muted = t.muted,
			}
			if gi := group_index(w.groups[:], t.group); gi >= 0 {
				g := w.groups[gi]
				x.group_name, x.group_color, x.group_collapsed = s(g.name, allocator), GROUP_COLOR_NAMES[g.color], g.collapsed
			}
			id := fmt.tprintf("###tab_%d", t.id)
			if r, ok := chrome_box_rect(w, t.pinned && favs.cfg.position != .Top ? w.own.sidebar.pins_key : w.own.strip.area_key, id); ok {
				x.rect, x.has_rect = api_rect(r), true
			}
			append(&tabs, x)
		}
		for g in w.groups {
			x := api.Tab_Group{id = int(g.id), window = w.id, name = s(g.name, allocator), color = GROUP_COLOR_NAMES[g.color], collapsed = g.collapsed}
			if r, ok := chrome_box_rect(w, w.own.strip.area_key, fmt.tprintf("###grp_%d", g.id)); ok {
				x.rect, x.has_rect = api_rect(r), true
			}
			append(&groups, x)
		}
	}
	return {tabs[:], groups[:]}
}

// A new tab. `background`: the window's current tab stays.
control_new_tab :: proc(app: ^App, address: string, background := false) -> ^Tab {
	wnd := active_window(app)
	was := wnd.current
	t := tab_open(app, address, origin = .User)
	if background && was >= 0 && was < len(wnd.tabs) - 1 {
		wnd.current = was
		if cur := current_tab(app); cur != nil { ui.field_set(&wnd.address, cur.url) }
	}
	return t
}

// The tab shows, in its window. false: there is none with this id.
control_activate_tab :: proc(app: ^App, id: int) -> bool {
	t := tab_by_id(app, u64(id))
	if t == nil { return false }
	tab_reveal(app, t)
	windows_spill(app, 3)
	request_frames(app, 3)
	return true
}

control_close_tab :: proc(app: ^App, id: int) -> bool {
	t := tab_by_id(app, u64(id))
	if t == nil { return false }
	tab_close_tab(app, t)
	return true
}

// The tab goes to window `to` (-1: a new one of its own), with its page as it is. nil, and why.
control_move_tab :: proc(app: ^App, id, to, index: int) -> (dest: ^Browser_Window, why: string) {
	t := tab_by_id(app, u64(id))
	if t == nil { return nil, fmt.tprintf("no tab %d", id) }
	if to < 0 {
		dest = tab_detach(app, t)
		if dest == nil { return nil, "the tab is alone in its window (or the window could not be made)" }
	} else {
		dest = window_by_id(app, to)
		if dest == nil { return nil, fmt.tprintf("no window %d", to) }
		tab_move(app, t, dest, index)
	}
	windows_spill(app, 3)
	return dest, ""
}

control_windows :: proc(app: ^App, allocator := context.temp_allocator) -> []api.Window {
	list := make([]api.Window, len(app.windows), allocator)
	for w, i in app.windows {
		outer := platform.outer_rect(w.win)   // emulated for a headless window (no HWND)
		cur := window_current_tab(app, w)
		co := platform.client_origin(w.win)
		d := &w.own.devtools
		list[i] = {
			id = w.id, front = w == window_front(app), tabs = len(window_tabs(app, w)), hwnd = int(window_native_handle(w.win)), headless = platform.is_offscreen(w.win),
			current_tab = cur != nil ? int(cur.id) : 0, left = outer[0], top = outer[1], width = w.win.size.x, height = w.win.size.y,
			state = platform.is_fullscreen(w.win) ? "fullscreen" : platform.is_minimized(w.win) ? "minimized" : platform.is_maximized(w.win) ? "maximized" : "normal",
			dpi_scale = f64(w.win.dpi_scale), client_left = co[0], client_top = co[1],
			devtools = {visible = d.visible, dock = DEV_DOCK_NAMES[d.dock], panel = DEV_PANEL_NAMES[d.panel], detached = d.win != nil || d.want_win, has_window = d.win != nil},
		}
		if d.win != nil {
			list[i].devtools.hwnd = int(window_native_handle(d.win.win))
			list[i].devtools.title = strings.clone(d.win.title, allocator)
		}
		// a tab carried over its tabs (tab_drag.odin): where it would go and where the mark is (client pixels, along the tabs)
		if w.dropping {
			z := w.zone
			list[i].dropping, list[i].drop_index, list[i].drop_group, list[i].drop_pinned = true, w.drop.index, int(w.drop.group), w.drop.pinned
			list[i].drop_mark = f64((z.vertical ? z.rect.min.y : z.rect.min.x) + w.drop.mark - z.offset)
		}
	}
	return list
}

// The bounds of the active window.
control_bounds :: proc(app: ^App) -> api.Bounds {
	wnd := active_window(app)
	// a headless window has no HWND: its outer rectangle and visibility are emulated (platform.outer_rect / is_offscreen)
	outer := platform.outer_rect(wnd.win)
	pr := wnd.page_rect
	return {
		window = app.active.id, left = outer[0], top = outer[1], outer_width = outer[2], outer_height = outer[3],
		width = wnd.win.size.x, height = wnd.win.size.y, state = window_state(app),
		dpi_scale = f64(wnd.win.dpi_scale), ui_scale = f64(ui_scale_of(app)), page_scale = f64(page_scale(app)),
		headless = platform.is_offscreen(wnd.win), visible = !platform.is_offscreen(wnd.win) && platform.is_window_visible(wnd.win),
		page_rect = api_rect(pr),
	}
}

// The active window becomes the one the user is in; `raise`: above the others (a headless window has no z-order; nothing takes the system's focus).
control_bring_to_front :: proc(app: ^App) {
	window_focus(app, app.active)
	if !platform.is_offscreen(app.active.win) { window_native_raise_top(app.active.win) }
}

// The developer tools of the active window. `panel`: console, elements, network, none; `dock`: "", window, bottom, right...
// "": fine, else what is wrong.
control_devtools :: proc(app: ^App, panel, dock: string) -> string {
	switch panel {
	case "console":  devtools_open(app, .Console)
	case "elements": devtools_open(app, .Elements)
	case "network":  devtools_open(app, .Network)
	case "none", "close": if dev().visible { devtools_toggle(app) }
	case: return "panel: console, elements, network or none"
	}
	if dock == "window" {   // a window of their own (devtools_window.odin)
		devtools_detach(app)
	} else if dock != "" {
		for d in Dev_Dock { if DEV_DOCK_NAMES[d] == dock { if devtools_detached() { devtools_attach(app) }; devtools_set_dock(app, d) } }
	}
	return ""
}

// The address bar of the active window as the last frame laid it out: its field, and the rows of its list while it is open.
control_urlbar :: proc(app: ^App, allocator := context.temp_allocator) -> api.Urlbar {
	w := app.active
	uv := urlbar_view(app)
	bar := api.Urlbar{open = uv.open}
	if b, ok := w.ui.boxes[window_own(app).address_key]; ok { bar.field = api_rect(b.rect) }
	if !uv.open { return bar }
	rows := make([]api.Urlbar_Row, len(uv.rows), allocator)
	list := ui.key_from_string(w.ui.root.key, URLBAR_POPUP)
	for r, i in uv.rows {
		#partial switch r.kind {
		case .History: rows[i].url = strings.clone(ub.idx.entries[r.entry].url, allocator)
		case .Tab:     if x := tab_by_id(app, r.tab_id); x != nil { rows[i].url = strings.clone(x.url, allocator) }
		}
		outer := ui.key_from_string(list, fmt.tprintf("###ubo_%d", i))
		id := fmt.tprintf("###ubr_%d", i)
		if b, ok := chrome_box_rect(w, outer, id); ok { rows[i].rect = api_rect(b) }
		if b, ok := chrome_box_rect(w, ui.key_from_string(outer, id), "###ubx"); ok { rows[i].cross, rows[i].has_cross = api_rect(b), true }
	}
	bar.rows = rows
	return bar
}

// A rectangle of the interface as a call gives it: whole pixels.
@(private = "file")
api_rect :: proc(r: draw.Rect) -> api.Rect { return {f64(int(r.min.x)), f64(int(r.min.y)), f64(int(r.max.x - r.min.x)), f64(int(r.max.y - r.min.y))} }

// A command of the interface by name. "": it ran, else why not.
control_command :: proc(app: ^App, t: ^Tab, name: string) -> string {
	cmd := command(name)
	if cmd == nil { return fmt.tprintf("no command %q (Wren.listCommands lists them)", name) }
	if !command_enabled(app, t, cmd) { return fmt.tprintf("the command %s is not available now", name) }
	command_run(app, t, cmd)
	return ""
}

////////////////////////////////
// Preferences

// A preference's value as text; false: there is none of this name.
control_pref_get :: proc(app: ^App, name: string) -> (string, bool) {
	i, ok := app.prefs.index[name]
	if !ok { return "", false }
	return config.value_string(&app.prefs, config.Ref(i)), true
}

// As the user sets it; `override`: the command line's layer (a value given with --pref at the start of this run is changed, not refused).
// "": set, else why not.
control_pref_set :: proc(app: ^App, name, text: string, override := false) -> string {
	if err := config.set_from_string(&app.prefs, name, text, override ? .Command_Line : .User); err != .None {
		return fmt.tprintf("%s: %s", name, config.set_error_text(err))
	}
	remote_reload_settings(app)
	request_frames(app, 3)
	return ""
}

// As it was when the channel started (control_begin for a program in this process). "": done, else why not.
control_pref_reset :: proc(app: ^App, name: string) -> string {
	r := &the_remote
	if r.baseline == nil { return "no baseline" }
	for st, i in r.baseline.prefs {
		if st.name != name { continue }
		config.restore(&app.prefs, r.baseline.prefs[i:i + 1])
		remote_reload_settings(app)
		request_frames(app, 3)
		return ""
	}
	return fmt.tprintf("no preference %q", name)
}

////////////////////////////////
// The numbers

control_console :: proc(t: ^Tab, since := 0, clear_after := false, allocator := context.temp_allocator) -> []api.Console_Line {
	first := int(t.console_added) - len(t.console)   // the number of console[0]
	lines := make([dynamic]api.Console_Line, allocator)
	for l, i in t.console {
		if first + i < since { continue }
		level, text := "log", l
		switch {
		case strings.has_prefix(l, "error: "): level, text = "error", l[7:]
		case strings.has_prefix(l, "warn: "):  level, text = "warn", l[6:]
		}
		append(&lines, api.Console_Line{level, strings.clone(text, allocator)})
	}
	if clear_after {
		for l in t.console { delete(l) }
		clear(&t.console)
	}
	return lines[:]
}

// What a window's numbers say to a test (Wren.stats says more).
control_stats :: proc(app: ^App, allocator := context.temp_allocator) -> api.Stats {
	wnd := active_window(app)
	g := platform.frame_gate()
	fv := forms_view(app)
	lp := dnd_last_picture
	st := api.Stats{
		pid = int(current_pid()), frames_drawn = int(hud.serial), pending_ops = len(the_remote.ops), input_events = the_remote.inputs,
		requests_in_flight = int(fetch.in_flight(&app.loader)), tabs = len(wnd.tabs), uptime_ms = process_uptime_ms(), frame_period_ms = wnd.pacer.period_ms,
		frame_gate = {int(g.begun), int(g.nested), int(g.deferred), int(g.violations), strings.clone(g.last_violation, allocator)},
		menu_open = ui.ctx_menu_any_open(), devtools = dev().visible, front_window = window_is_front(app),
		caret_blinking = fv.blink_timer != base.NIL_HANDLE, caret_shown = fv.blink_on, drop_target = platform.drop_target_enabled(wnd.win),
		chrome_animating = ui.needs_frame(wnd.ui), backend = strings.clone(render.backend_name(), allocator),
		prefs_net_applied = int(prefs_apply_counts[.Net]),
	}
	if lp.size.x > 0 {
		st.drag_picture = fmt.aprintf("%dx%d@%d,%d rgba=%d,%d,%d,%d", lp.size.x, lp.size.y, lp.hot.x, lp.hot.y, lp.middle[0], lp.middle[1], lp.middle[2], lp.middle[3], allocator = allocator)
	}
	if sz, hot, held := platform.drag_image_held(wnd.win); held { st.drag_image = fmt.aprintf("%dx%d@%d,%d", sz.x, sz.y, hot.x, hot.y, allocator = allocator) }
	st.group_name_focused = window_own(app).sidebar.rename_focused
	st.devtools_room_checks, st.devtools_room_wrong = dev().room_checks, dev().room_wrong
	if t := current_tab(app); t != nil && t.page != nil { st.nodes = int(t.page.doc.nodes.count) }
	for w in app.windows { if w.own.devtools.win != nil { st.devtools_windows += 1 } }
	return st
}

// The next press starts a click of its own, whatever the system's double-click time and the time gone by: a program in this process
// clicks twice in a row far sooner than a person does.
control_forget_clicks :: proc(app: ^App) { active_window(app).ui.last_click_key = 0 }

// Goes there (nothing waits for it: control_wait).
control_navigate :: proc(app: ^App, t: ^Tab, address: string) {
	navigate(app, t, address, origin = .User)
	request_frames(app, 3)
}

// The tab's page again (F5; `bypass_cache`: Ctrl+F5); nothing waits for it: control_wait.
control_reload :: proc(app: ^App, t: ^Tab, bypass_cache := false) { reload(app, t, bypass_cache) }

// Back (-1) or forward (1) in the tab's history; nothing waits for it.
control_history :: proc(app: ^App, t: ^Tab, delta: int) { go_history(app, t, delta) }

// What another application's drag carries: the system's form (its `files` are the caller's to delete).
control_drop_data :: proc(d: api.Drop_Data) -> platform.Drag_Data {
	x: platform.Drag_Data
	for f in d.files { append(&x.files, f) }
	x.text, x.url, x.html = d.text, d.url, d.html
	return x
}

// The size, place, state and scale of the active window: what is left out stays.
control_set_window :: proc(app: ^App, c: api.Window_Change) {
	size, has_size := c.size.?
	pos, has_pos := c.pos.?
	window_apply(app, c.state, c.state != "", size.x, size.y, pos.x, pos.y, has_size, has_size, has_pos, has_pos)
	if c.dpi != 0 { window_simulate_dpi(app, active_window(app), c.dpi) }
}

// A capture as the API's options say it.
control_shot :: proc(app: ^App, o: api.Shot_Options) -> Capture_Request {
	q := Capture_Request{scale = f32(o.scale), selector = o.selector, settle = o.has_settle ? o.settle : the_remote.cfg.settle_frames}
	switch o.target {
	case .Window:
	case .Page:     q.target = .Page
	case .Rect:     q.target, q.rect = .Rect, {f32(o.rect.x), f32(o.rect.y), f32(o.rect.w), f32(o.rect.h)}
	case .Selector: q.target = .Selector
	}
	return q
}
