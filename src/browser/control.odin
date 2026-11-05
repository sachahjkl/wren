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
import "wb:cookies"
import "wb:fetch"
import "wb:host"
import "wb:httpcache"
import "wb:page"
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
	r := &app.remote
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
		op.quiet_ms = l.quiet_ms > 0 ? l.quiet_ms : app.remote.cfg.quiet_ms
		op.max_cpu = l.max_cpu > 0 ? l.max_cpu : f64(app.remote.cfg.quiet_cpu_ms)
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
	r := &app.remote
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
	return frames_op(app, c, t, app.remote.cfg.settle_frames, fmt.tprintf(`{{"x":%.1f,"y":%.1f}}`, pos.x, pos.y))
}

// A click on an element: scrolled into view first, on the middle of its box.
control_click :: proc(app: ^App, c: ^Call, t: ^Tab, selector: string, button: platform.Mouse_Button, count: int, timeout_ms := 0) -> Reply {
	op := op_new(app, c, .Click, timeout_ms, fmt.tprintf("the element %s", selector))
	op.tab, op.arg, op.button, op.count = t.id, strings.clone(selector), button, max(count, 1)
	op.until = app.remote.frame_no
	request_frames(app, 3)
	return Reply{deferred = true}
}

control_hover :: proc(app: ^App, c: ^Call, pos: [2]f32, mods: platform.Modifiers = {}) -> Reply {
	inject(app, {kind = .Mouse_Move, pos = pos, mods = mods})
	return frames_op(app, c, nil, app.remote.cfg.settle_frames)
}

// A button goes down, and stays down until control_release (a press held over frames: autoscroll, a splitter).
control_press :: proc(app: ^App, c: ^Call, pos: [2]f32, button: platform.Mouse_Button, mods: platform.Modifiers = {}) -> Reply {
	inject(app, {kind = .Mouse_Press, pos = pos, button = button, mods = mods})
	return frames_op(app, c, nil, app.remote.cfg.settle_frames)
}

control_release :: proc(app: ^App, c: ^Call, pos: [2]f32, button: platform.Mouse_Button, mods: platform.Modifiers = {}) -> Reply {
	inject(app, {kind = .Mouse_Release, pos = pos, button = button, mods = mods})
	return frames_op(app, c, nil, app.remote.cfg.settle_frames)
}

// The wheel: `delta` in pixels.
control_wheel :: proc(app: ^App, c: ^Call, pos: [2]f32, delta: [2]f64, mods: platform.Modifiers = {}) -> Reply {
	inject(app, {kind = .Scroll, pos = pos, delta = {f32(delta.x) / 100, f32(delta.y) / 100}, mods = mods})
	return frames_op(app, c, nil, app.remote.cfg.settle_frames)
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
		if op.button not_in app.inject_held { op_finish(op, fail(remote.ERR_FAILED, "no drag is held (drag --hold first)")); return Reply{deferred = true} }
		op.stage, op.idx = 1, 0
	}
	op.until = app.remote.frame_no
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
	app.remote.inputs += 1
	request_frames(app, 4)
	return frames_op(app, c, nil, app.remote.cfg.settle_frames)
}

control_type :: proc(app: ^App, c: ^Call, text: string) -> Reply {
	for ch in text {
		switch ch {
		case '\n', '\r': emit_key(app, .Return, {}, 0)
		case '\t':       emit_key(app, .Tab, {}, 0)
		case:            inject(app, {kind = .Text, text = ch})
		}
	}
	return frames_op(app, c, nil, app.remote.cfg.settle_frames)
}

// Keys: "Ctrl+L", several separated by spaces.
control_key :: proc(app: ^App, c: ^Call, combo: string, repeat := 1) -> Reply {
	for part in strings.split(combo, " ", context.temp_allocator) {
		if part == "" { continue }
		key, mods, ok := parse_combo(part)
		if !ok { return fail(remote.ERR_PARAMS, fmt.tprintf("unknown key %q (examples: Enter, Ctrl+L, Shift+Tab, F5, a)", part)) }
		for _ in 0 ..< clamp(repeat, 1, KEY_REPEAT_MOST) { emit_key(app, key, mods, key_text(key, mods)) }
	}
	return frames_op(app, c, nil, app.remote.cfg.settle_frames)
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
			if r, ok := chrome_box_rect(w, t.pinned && app.favs.cfg.position != .Top ? w.own.sidebar.pins_key : w.own.strip.area_key, id); ok {
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
	PREP_NAMES := [Page_Prep_State]string{.None = "none", .Hold = "hold", .Ready = "ready"}
	return {
		window = app.active.id, left = outer[0], top = outer[1], outer_width = outer[2], outer_height = outer[3],
		width = wnd.win.size.x, height = wnd.win.size.y, state = window_state(app),
		dpi_scale = f64(wnd.win.dpi_scale), ui_scale = f64(ui_scale_of(app)), page_scale = f64(page_scale(app)),
		headless = platform.is_offscreen(wnd.win), visible = !platform.is_offscreen(wnd.win) && platform.is_window_visible(wnd.win),
		page_rect = api_rect(pr), page_prep = PREP_NAMES[wnd.own.page_prep.state],
	}
}

// The active window goes, with its tabs, at the end of the pass. "": it will, else why not (the last window ends the browser: control_close).
control_close_window :: proc(app: ^App) -> string {
	if len(app.windows) <= 1 { return "this is the only window: Browser.close ends the browser" }
	app.active.closing, app.active.closing_force = true, true
	return ""
}

// The browser ends, with this exit code.
control_close :: proc(app: ^App, exit_code: int) {
	app.remote.exit_code = exit_code
	app.quitting = true
	platform.request_close(active_window(app).win)
}

control_ping :: proc() -> api.Ping { return {remote.PROTOCOL_VERSION, APP_VERSION, int(current_pid())} }

control_version :: proc() -> api.Version {
	return {fmt.tprintf("Wren/%s", APP_VERSION), app_commit(), ui.VERSION, build_description(), remote.PROTOCOL_VERSION}
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
		case .History: rows[i].url = strings.clone(app.ub.idx.entries[r.entry].url, allocator)
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
api_rect :: proc(r: draw.Rect) -> api.Rect { return {f64(int(r.min.x)), f64(int(r.min.y)), f64(int(r.max.x - r.min.x)), f64(int(r.max.y - r.min.y))} }

// A command of the interface by name. "": it ran, else why not.
control_command :: proc(app: ^App, t: ^Tab, name: string) -> string {
	cmd := command(app, name)
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
	r := &app.remote
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

// All of them as they were; how many were not. "": done, else why not.
control_pref_reset_all :: proc(app: ^App) -> (restored: int, why: string) {
	r := &app.remote
	if r.baseline == nil { return 0, "no baseline" }
	restored = config.restore(&app.prefs, r.baseline.prefs)
	remote_reload_settings(app)
	request_frames(app, 3)
	return restored, ""
}

// A preference, all that is known of it; false: there is none of this name.
control_pref :: proc(app: ^App, name: string, allocator := context.temp_allocator) -> (p: api.Pref, ok: bool) {
	i, has := app.prefs.index[name]
	if !has { return }
	e := &app.prefs.entries[i]
	p = {
		name = strings.clone(e.def.name, allocator), text = strings.clone(config.value_string(&app.prefs, config.Ref(i)), allocator),
		default_text = strings.clone(config.default_string(&app.prefs, config.Ref(i)), allocator),
		source = base.ascii_lower_clone(fmt.tprintf("%v", e.source), allocator), locked = e.locked, restart = e.def.restart,
	}
	switch e.def.kind {
	case .Bool:   p.value = e.value.b
	case .Int:    p.value = e.value.i
	case .Float:  p.value = e.value.f
	case .String: p.value = strings.clone(e.value.s, allocator)
	}
	return p, true
}

// The preferences whose name begins so, by name.
control_prefs :: proc(app: ^App, prefix := "", allocator := context.temp_allocator) -> []api.Pref {
	list := make([dynamic]api.Pref, allocator)
	for name in config.sorted_names(&app.prefs) {
		if !strings.has_prefix(name, prefix) { continue }
		p, _ := control_pref(app, name, allocator)
		append(&list, p)
	}
	return list[:]
}

// The commands of the interface, and which can run now.
control_commands :: proc(app: ^App, allocator := context.temp_allocator) -> []api.Command {
	t := current_tab(app)
	all := commands(app)
	list := make([]api.Command, len(all), allocator)
	for &cmd, i in all {
		list[i] = {
			name = strings.clone(cmd.name, allocator), title = strings.clone(cmd.title, allocator), category = strings.clone(cmd.category, allocator),
			shortcut = strings.clone(command_shortcut_text(&cmd), allocator), enabled = command_enabled(app, t, &cmd),
		}
	}
	return list
}

////////////////////////////////
// The document

// How many matches a query describes when it says no limit, and how much of the markup of each.
QUERY_ALL_DEFAULT_LIMIT :: 100
@(private = "file") QUERY_NODE_HTML_MOST :: 300

// A rectangle of the window (element_window_rect) in CSS pixels from the page's corner.
@(private = "file")
page_box :: proc(app: ^App, r: [4]f32) -> api.Rect {
	pr := active_window(app).page_rect
	s := f64(page_scale(app))
	return {f64(r[0] - pr.min.x) / s, f64(r[1] - pr.min.y) / s, f64(r[2]) / s, f64(r[3]) / s}
}

// The elements `selector` finds in the tab's document. `code`: 0, or what is wrong, said in `why`.
control_query_all :: proc(app: ^App, t: ^Tab, selector: string, limit := QUERY_ALL_DEFAULT_LIMIT, allocator := context.temp_allocator) -> (r: api.Query_Result, code: int, why: string) {
	if t.page == nil { return {}, remote.ERR_FAILED, "the tab has no document" }
	first, valid := page.query_all(t.page, selector, limit)
	if !valid { return {}, remote.ERR_PARAMS, fmt.tprintf("invalid selector %q", selector) }
	all, _ := page.query_all(t.page, selector)
	r.count = len(all)
	r.nodes = make([]api.Query_Node, len(first), allocator)
	for h, i in first {
		html := page.serialize_html(t.page.doc, h, true)
		r.nodes[i].outer_html = strings.clone(html[:min(len(html), QUERY_NODE_HTML_MOST)], allocator)
		if box, ok := element_window_rect(app, t, h); ok { r.nodes[i].box, r.nodes[i].has_box = page_box(app, box), true }
	}
	return r, 0, ""
}

// The box of the element `selector` finds. `code`: 0, or what is wrong, said in `why`.
control_box_model :: proc(app: ^App, t: ^Tab, selector: string) -> (r: api.Box_Model, code: int, why: string) {
	box, h, c, w := control_element_box(app, t, selector)
	if c != 0 { return {}, c, w }
	return {element_visible(app, t, h), page_box(app, box), {f64(box[0]), f64(box[1]), f64(box[2]), f64(box[3])}}, 0, ""
}

// The computed style of the element `selector` finds, as a script of the page reads it (`properties` nil: all of it). "": fine, else what is wrong.
control_computed_style :: proc(t: ^Tab, selector: string, properties: []string = nil, allocator := context.temp_allocator) -> (list: []api.Style_Property, why: string) {
	names := "null"
	if properties != nil {
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		for name, i in properties { if i > 0 { strings.write_byte(&b, ',') }; base.write_json_string(&b, name) }
		strings.write_byte(&b, ']')
		names = strings.to_string(b)
	}
	expr := fmt.tprintf(`(function(S,P){{var e=document.querySelector(S);if(!e)return null;var c=getComputedStyle(e),o=[];if(!P){{P=[];for(var i=0;i<c.length;i++)P.push(c[i])}}for(var i=0;i<P.length;i++)o.push([P[i],c.getPropertyValue(P[i])]);return o}})(%s,%s)`, base.json_quote(selector), names)
	text, _, err := eval_sync(t, expr)
	if err != "" { return nil, err }
	v, perr := json.parse(transmute([]byte)text, json.Specification.JSON, true, context.temp_allocator)
	pairs, is_list := v.(json.Array)
	if perr != .None || !is_list { return nil, fmt.tprintf("no element matches %q", selector) }
	list = make([]api.Style_Property, len(pairs), allocator)
	for x, i in pairs {
		pair := x.(json.Array)
		list[i] = {strings.clone(string(pair[0].(json.String)), allocator), strings.clone(string(pair[1].(json.String)), allocator)}
	}
	return list, ""
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
		append(&lines, api.Console_Line{level, strings.clone(text, allocator), first + i})
	}
	if clear_after {
		for l in t.console { delete(l) }
		clear(&t.console)
	}
	return lines[:]
}

// How many lines the tab's page has said in all.
control_console_total :: proc(t: ^Tab) -> int { return int(t.console_added) }

// What the tab's page fetched (the Network tab's log). `clear_after`: the log is empty after this.
control_network :: proc(t: ^Tab, clear_after := false, allocator := context.temp_allocator) -> api.Network {
	r := api.Network{bytes = int(t.net.bytes), requests = make([]api.Net_Request, len(t.net.entries), allocator)}
	if t.page != nil && t.page.scripts != nil {
		tm := &t.page.scripts.timing
		mark :: proc(ms, t0: f64) -> f64 { return ms > 0 ? ms - t0 : 0 }
		r.doc = {mark(tm.parsed_ms, t.net.t0_ms), mark(tm.dcl_ms, t.net.t0_ms), mark(tm.load_ms, t.net.t0_ms), mark(tm.paint_ms, t.net.t0_ms)}
	}
	for en, i in t.net.entries {
		r.requests[i] = {
			id = int(en.id), url = strings.clone(en.url, allocator), method = strings.clone(en.method, allocator), mime = strings.clone(en.mime, allocator), error = strings.clone(en.error, allocator),
			destination = base.ascii_lower_clone(fmt.tprintf("%v", en.dest), allocator), cache = base.ascii_lower_clone(fmt.tprintf("%v", en.cache), allocator),
			status = en.status, bytes = en.bytes, ms = f64(en.ms), has_ms = en.ms >= 0, failed = en.failed, protocol = strings.clone(en.protocol, allocator), start_ms = en.start_ms - t.net.t0_ms, has_timing = en.has_timing,
			queued = f64(en.timing.started), dns_start = f64(en.timing.dns_start), dns_end = f64(en.timing.dns_end), connect_start = f64(en.timing.connect_start), connect_end = f64(en.timing.connect_end),
			sending = f64(en.timing.sending), response = f64(en.timing.response), done = f64(en.timing.done),
		}
	}
	if clear_after { net_clear(&t.net) }
	return r
}

// The back/forward cache's numbers (bfcache.odin).
control_bfcache :: proc(app: ^App, allocator := context.temp_allocator) -> api.Bfcache_Stats {
	reasons := make([dynamic]api.Bfcache_Reason, 0, len(app.bf.reasons), allocator)
	for k, v in app.bf.reasons { append(&reasons, api.Bfcache_Reason{strings.clone(k, allocator), v}) }
	return {
		cached = len(app.bf.entries), stores = app.bf.stores, restores = app.bf.restores, evictions = app.bf.evictions,
		refusals = app.bf.refusals, traversals = app.bf.traversals, misses = app.bf.misses, reasons = reasons[:],
	}
}

// The current tab is still putting back what its history entry showed.
control_history_restoring :: proc(app: ^App) -> bool {
	t := current_tab(app)
	return t != nil && t.nav_state.restore.active
}

// Every number of a window (Wren.stats): control_stats, and what takes a look at the process, a sort or a walk of a store.
control_stats_all :: proc(app: ^App, allocator := context.temp_allocator) -> api.Stats {
	st := control_stats(app, allocator)
	wnd := active_window(app)
	n := &app.hud.nums
	gaps := frame_log_intervals(app)
	pacer := &wnd.pacer   // (the window's pacing; the preferences are the process's)
	st.frames, st.cpu_ms, st.cpu_p95_ms, st.cpu_p99_ms, st.cpu_max_ms = int(n.frames), f64(n.cpu_mean), f64(n.cpu_p95), f64(n.cpu_p99), f64(n.cpu_max)
	st.gpu_ms, st.gpu_measured = f64(n.gpu_mean), n.gpu_n > 0
	st.frames_requested, st.frames_at_once, st.frame_gaps = int(wnd.frames_requested), int(app.frame_log.at_once), int(gaps.count)
	st.frame_gap_p50_ms, st.frame_gap_p95_ms, st.frame_gap_p99_ms, st.frame_gap_max_ms = gaps.p50, gaps.p95, gaps.p99, gaps.max
	st.ignored_size_moves = int(platform.pump_stats(wnd.win).ignored_size_moves)
	if app.pacing.cfg.drag_probe { st.drag_samples, st.has_drag_samples = control_drag_samples(allocator), true }
	if render.latency_probe_on(&app.r) {
		l := render.latency_summary(&app.r)
		lat :: proc(x: render.Latency_Stat) -> api.Latency_Stat { return {f64(x.p50), f64(x.p95), f64(x.max), f64(x.mean)} }
		st.has_latency = true
		st.latency = {
			tearing_supported = render.tearing_supported(&app.r), tearing = render.present_mode(&app.r) == .Tearing,
			samples = int(l.samples), refresh_ms = f64(l.period_ms), frames_shown = int(l.frames), frames_shown_from_input = int(l.with_input), queue_mean = f64(l.queue_mean), queue_max = int(l.queue_max),
			wait = lat(l.wait), work = lat(l.work), present = lat(l.present), scan = lat(l.scan), total = lat(l.total), total_refreshes = lat(l.refreshes),
		}
	}
	st.hz, st.hz_reported, st.hz_max, st.hz_now, st.hz_swap_chain = f64(pacer.hz), pacer.display.hz, pacer.display.max_hz, pacer.live_hz, render.measured_refresh_hz(&app.r)
	st.variable_refresh, st.frame_cap_strict = pacer.variable, pacer.cadence.slots.strict || pacer.cadence.slots.escalated
	states := strings.builder_make(context.temp_allocator)
	for count, state in pacer.cadence.counts { if count > 0 { fmt.sbprintf(&states, "%v=%d ", state, count) } }
	st.frame_states, st.frame_state = strings.clone(strings.trim_space(strings.to_string(states)), allocator), fmt.aprint(pacer.cadence.state, allocator = allocator)
	st.resize_echoes_skipped = int(pacer.echoes_skipped)
	causes := strings.builder_make(context.temp_allocator)
	for count, cause in pacer.resize_causes { if count > 0 { fmt.sbprintf(&causes, "%v=%d ", cause, count) } }
	for count, kind in pacer.resize_event_kinds { if count > 0 { fmt.sbprintf(&causes, "ev.%v=%d ", kind, count) } }
	st.resize_frame_causes = strings.clone(strings.trim_space(strings.to_string(causes)), allocator)
	st.prefs_cache_applied, st.prefs_downloads_applied = int(app.prefs_apply_counts[.Http_Cache]), int(app.prefs_apply_counts[.Downloads])
	if t := current_tab(app); t != nil && t.page != nil { st.layout_items = len(t.layout.items) }
	st.cpu_time_ms, st.cpu_user_ms, st.cpu_kernel_ms = process_cpu_ms()
	pc := process_counters()
	st.threads, st.handles, st.gdi_objects, st.user_objects = process_thread_count(), int(pc.handles), int(pc.gdi), int(pc.user)
	st.cookies, st.storage_sites = cookies.count(&app.profile.jar), len(page.storage_sites(&app.storage))
	if app.profile.cache != nil { st.cache_entries = int(httpcache.summary(app.profile.cache).entries) }
	st.history_visits, st.closed_tabs, st.downloads_active, st.checkpoints = len(app.ghist.visits), len(app.closed_tabs), downloads_active(app), len(app.remote.checkpoints)
	return st
}

// What the frames' numbers count from now on: `frames` the presents and a window's loops, `latency` the probe's.
control_stats_reset :: proc(app: ^App, frames, latency: bool) {
	if latency { render.latency_reset(&app.r) }
	if frames {
		frame_log_reset(app)
		drag_probe_reset()
		active_window(app).win.stats = {}
	}
}

// What a window's numbers say to a test, cheap enough for a poll (control_stats_all says more).
control_stats :: proc(app: ^App, allocator := context.temp_allocator) -> api.Stats {
	wnd := active_window(app)
	g := platform.frame_gate()
	fv := forms_view(app)
	lp := app.dnd_last_picture
	st := api.Stats{
		pid = int(current_pid()), frames_drawn = app.rates.frames, loop = loop_rates_stats(&app.rates, allocator), pending_ops = len(app.remote.ops), input_events = app.remote.inputs,
		requests_in_flight = int(fetch.in_flight(&app.loader)), tabs = len(wnd.tabs), uptime_ms = process_uptime_ms(), frame_period_ms = wnd.pacer.period_ms,
		frame_gate = {int(g.begun), int(g.nested), int(g.deferred), int(g.violations), strings.clone(g.last_violation, allocator)},
		menu_open = ui.ctx_menu_any_open(), devtools = dev().visible, front_window = window_is_front(app),
		caret_blinking = fv.blink_timer != base.NIL_HANDLE, caret_shown = fv.blink_on, drop_target = platform.drop_target_enabled(wnd.win),
		chrome_animating = ui.needs_frame(wnd.ui), backend = strings.clone(render.backend_name(), allocator),
		prefs_net_applied = int(app.prefs_apply_counts[.Net]), bfcache = control_bfcache(app, allocator),
		workers_running = page.workers_running(), shared_workers = page.shared_workers_live(), history_restoring = control_history_restoring(app),
	}
	if lp.size.x > 0 {
		st.drag_picture = fmt.aprintf("%dx%d@%d,%d rgba=%d,%d,%d,%d", lp.size.x, lp.size.y, lp.hot.x, lp.hot.y, lp.middle[0], lp.middle[1], lp.middle[2], lp.middle[3], allocator = allocator)
	}
	if sz, hot, held := platform.drag_image_held(wnd.win); held { st.drag_image = fmt.aprintf("%dx%d@%d,%d", sz.x, sz.y, hot.x, hot.y, allocator = allocator) }
	st.group_name_focused = window_own(app).sidebar.rename_focused
	st.devtools_room_checks, st.devtools_room_wrong = dev().room_checks, dev().room_wrong
	if t := current_tab(app); t != nil && t.page != nil { st.nodes = int(t.page.doc.nodes.count) }
	for w in app.windows { if w.own.devtools.win != nil { st.devtools_windows += 1 } }
	control_stats_window(app, &st, allocator)
	return st
}

// The next press starts a click of its own, whatever the system's double-click time and the time gone by: a program in this process
// clicks twice in a row far sooner than a person does.
control_forget_clicks :: proc(app: ^App) { active_window(app).ui.last_click_key = 0 }

// The browser's list of downloads.
control_downloads :: proc(app: ^App, allocator := context.temp_allocator) -> []api.Download {
	list := make([]api.Download, len(app.dls.list), allocator)
	for d, i in app.dls.list {
		list[i] = {name = strings.clone(d.name, allocator), error = strings.clone(d.error, allocator), finished = download_finished(d) && !d.moving, saved = d.state == .Done}
	}
	return list
}

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

// The size, place, state and scale of the active window: what is left out stays. "": done, else what is wrong with what was asked.
control_set_window :: proc(app: ^App, c: api.Window_Change) -> string {
	switch c.state {
	case "", "normal", "minimized", "maximized", "fullscreen":
	case: return "windowState: normal, minimized, maximized or fullscreen"
	}
	if c.dpi != 0 && (c.dpi < WINDOW_DPI_LEAST || c.dpi > WINDOW_DPI_MOST) { return "dpi: 48 to 960 (96 = 100 %)" }
	size, has_size := c.size.?
	pos, has_pos := c.pos.?
	window_apply(app, c.state, c.state != "", size.x, size.y, pos.x, pos.y, has_size, has_size, has_pos, has_pos)
	if c.dpi != 0 { window_simulate_dpi(app, active_window(app), c.dpi) }
	return ""
}
@(private = "file") WINDOW_DPI_LEAST :: 48
@(private = "file") WINDOW_DPI_MOST :: 960

// A key's own events, one at a time (Input.dispatchKeyEvent), as against control_key's whole press and release.
Key_Event_Kind :: enum u8 { Down, Up, Text }

control_key_event :: proc(app: ^App, c: ^Call, kind: Key_Event_Kind, name, text: string, mods: platform.Modifiers) -> Reply {
	key, kmods, ok := parse_combo(name)
	all := mods + kmods
	if kind == .Down && ok { inject(app, {kind = .Key_Press, key = key, mods = all}) }
	if kind == .Up && ok { inject(app, {kind = .Key_Release, key = key, mods = all}) }
	if kind != .Up { for ch in text { inject(app, {kind = .Text, text = ch, mods = all}) } }
	return frames_op(app, c, nil, app.remote.cfg.settle_frames)
}

// The tab's page stops loading.
control_stop_loading :: proc(app: ^App, t: ^Tab) { stop_loading(app, t) }

// The events of Page.loadEventFired and Runtime.consoleAPICalled go to this client from now on, or not.
control_subscribe :: proc(app: ^App, conn: u64, on: bool) {
	r := &app.remote
	for i := len(r.subs) - 1; i >= 0; i -= 1 { if r.subs[i] == conn { unordered_remove(&r.subs, i) } }
	if on {
		append(&r.subs, conn)
		for t in tabs_all(app) { r.loaded[t.id] = tab_loaded(app, t) }
	}
}

// The Setup dialog as the last frame showed it.
control_setup_state :: proc(app: ^App, allocator := context.temp_allocator) -> api.Setup_State {
	rect :: proc(r: draw.Rect) -> api.Rect { return {f64(r.min.x), f64(r.min.y), f64(r.max.x - r.min.x), f64(r.max.y - r.min.y)} }
	return {
		open = app.stp.open, known = app.stp.known, confirm_uninstall = app.stp.confirm_uninstall, busy = app.stp.busy, note = strings.clone(app.stp.note, allocator),
		primary = rect(app.stp.at_primary), uninstall = rect(app.stp.at_uninstall), secondary = rect(app.stp.at_secondary),
	}
}

// The daily update check has a request out (update_check.odin).
control_update_checking :: proc(app: ^App) -> bool { return update_checking(app) }

////////////////////////////////
// Recording, playing back, the timeline

// A recording begins: the events the window receives, from any source, with their times.
control_record_start :: proc(app: ^App) {
	r := &app.remote.rec
	clear(&r.events)
	r.on, r.t0 = true, host.now_ns(&app.loop)
}

// It ends; what it has (the browser's until the next one).
control_record_stop :: proc() -> []Rec_Event {
	the_app.remote.rec.on = false
	return the_app.remote.rec.events[:]
}

control_record_state :: proc() -> (recording: bool, events: int) { return the_app.remote.rec.on, len(the_app.remote.rec.events) }

// The events go in at their recorded times (divided by `speed`): answered when the last is in and its frames are drawn.
control_replay :: proc(app: ^App, c: ^Call, events: []Rec_Event, speed := 1.0, timeout_ms := 0) -> Reply {
	op := op_new(app, c, .Replay, timeout_ms, "the replay")
	op.speed = max(speed, REPLAY_SPEED_LEAST)
	op.t0 = host.now_ns(&app.loop)
	last := 0.0
	for e in events { append(&op.events, e); last = max(last, e.t_ms) }
	// (the whole replay must fit in its time: the deadline is the last event's time, plus what the command allows)
	op.deadline += i64(last / op.speed * NS_PER_MS)
	request_frames(app, 3)
	return Reply{deferred = true}
}
@(private = "file") REPLAY_SPEED_LEAST :: 0.01
@(private = "file") NS_PER_MS :: 1e6

// The timeline starts: a picture of each frame of the window, or of its page, at this scale, up to `most`.
control_timeline_start :: proc(app: ^App, scale: f64, most: int, page_only := false) -> (kept_scale: f64, kept_most: int) {
	rect: [4]int
	if page_only {
		pr := active_window(app).page_rect
		rect = {int(pr.min.x), int(pr.min.y), int(pr.max.x - pr.min.x), int(pr.max.y - pr.min.y)}
	}
	timeline_begin(app, f32(scale), most, rect)
	return f64(app.remote.tl.scale), app.remote.tl.max
}

control_timeline_state :: proc() -> (recording: bool, frames: int) { return the_app.remote.tl.on, len(the_app.remote.tl.frames) }

// It ends: its pictures to `dir`. `document`: the timeline.json written there; `why`: what went wrong, or "".
control_timeline_stop :: proc(app: ^App, dir: string, cols: int, all: bool) -> (document, why: string) {
	tl := &app.remote.tl
	timeline_end(app)
	document, why = timeline_write(tl, dir, clamp(cols, 1, TIMELINE_COLS_MOST), all)
	timeline_free(tl)
	return
}
@(private = "file") TIMELINE_COLS_MOST :: 24

// A capture as the API's options say it.
control_shot :: proc(app: ^App, o: api.Shot_Options) -> Capture_Request {
	q := Capture_Request{scale = f32(o.scale), selector = o.selector, settle = o.has_settle ? o.settle : app.remote.cfg.settle_frames}
	switch o.target {
	case .Window:
	case .Page:     q.target = .Page
	case .Rect:     q.target, q.rect = .Rect, {f32(o.rect.x), f32(o.rect.y), f32(o.rect.w), f32(o.rect.h)}
	case .Selector: q.target = .Selector
	}
	return q
}
