package browser

// What a program in this process reads of a window beyond control.odin: what the system would hear from its window procedure, the edge a drag
// drew in each frame, the cursor the page asked for, the surface a resize keeps, what a screen reader is told.

import "core:fmt"
import "core:strings"
import "toolkit:platform"
import "toolkit:ui"
import "wb:base"
import "wb:page"
import "wb:remote"
import "wb:remote/api"
import "wb:webgl"

// What a point of the active window (window pixels) is to the system: what the window procedure answers WM_NCHITTEST from, for a window that has
// no system's frame around it too.
control_hit_test :: proc(app: ^App, p: [2]f32) -> platform.Hit {
	wnd := active_window(app)
	border := f32(platform.resize_border(wnd.win))
	sides: platform.Sides = platform.is_maximized(wnd.win) ? {} : {.Top}
	return platform.hit_test_chrome(ui.chrome_regions(wnd.ui), p, {f32(wnd.win.size.x), f32(wnd.win.size.y)}, border, border * 2, sides)
}

// What each frame of a drag held drew, oldest first, since control_drag_samples_reset (browser.frame.drag_probe).
control_drag_samples :: proc(allocator := context.temp_allocator) -> []api.Drag_Sample {
	kept := min(drag_probe.n, DRAG_PROBE_CAP)
	list := make([]api.Drag_Sample, kept, allocator)
	for i in 0 ..< kept {
		s := drag_probe.ring[(drag_probe.n - kept + i) % DRAG_PROBE_CAP]
		list[i] = {
			pointer = f64(s.mouse_x), edge = f64(s.finger_x), page_width = f64(s.page_w), area_width = f64(s.area_w),
			read_us = i64(s.read / 1000), shown_us = i64(s.shown / 1000), done_us = i64(s.done / 1000), dt = f64(s.dt), waited_ms = f64(s.waited), moves = int(s.moves),
		}
	}
	return list
}

control_drag_samples_reset :: proc() { drag_probe_reset() }

// The cursor the active window shows: the page's over the page area, else the chrome's.
control_cursor :: proc(app: ^App, allocator := context.temp_allocator) -> api.Cursor_Shown {
	wnd := active_window(app)
	shown := window_own(app).cursor.shown
	SOURCES := [platform.Cursor_Source]string{.System = "system", .Drawn = "drawn", .Hidden = "hidden"}
	c := api.Cursor_Shown{name = strings.clone(platform.cursor_css_name(shown.keyword), allocator)}
	info: platform.Cursor_Info
	if shown.custom != 0 && platform.custom_cursor_valid(wnd.win, shown.custom) {
		info = platform.custom_cursor_info(wnd.win, shown.custom, shown.scale)
		c.custom = true
	} else {
		info = platform.cursor_info(wnd.win, shown.keyword)
	}
	c.source, c.size, c.hotspot = SOURCES[info.source], info.size, info.hot
	return c
}

// The surface of the active window, and of its developer tools' window when they have one: what the window shows and of what size.
control_surfaces :: proc(app: ^App) -> (window, panel: api.Surface) {
	window = surface_of(app.r.fixed_surface, app.r.size, app.r.buffer_size, app.r.source_size)
	if d := active_window(app).own.devtools.win; d != nil { panel = surface_of(d.surf.fixed_surface, d.surf.size, d.surf.buffer_size, d.surf.source_size) }
	return
}

@(private = "file")
surface_of :: proc(fixed: bool, size, buffers, source: [2]int) -> api.Surface { return {fixed = fixed, size = size, buffers = buffers, source = source} }

// The HTML of the element `selector` finds ("": of the document). `code`: 0, or what is wrong, said in `why`.
control_outer_html :: proc(t: ^Tab, selector: string) -> (html: string, code: int, why: string) {
	if t.page == nil { return "", remote.ERR_FAILED, "the tab has no document" }
	h := t.page.doc.root
	if selector != "" {
		found, valid := page.query_first(t.page, selector)
		if !valid { return "", remote.ERR_PARAMS, fmt.tprintf("invalid selector %q", selector) }
		if found == base.NIL_HANDLE { return "", remote.ERR_FAILED, fmt.tprintf("no element matches %q", selector) }
		h = found
	}
	return page.serialize_html(t.page.doc, h, true), 0, ""
}

// The box of the element `selector` finds: x, y, width, height in window pixels. `code`: 0, or what is wrong, said in `why`.
control_element_box :: proc(app: ^App, t: ^Tab, selector: string) -> (box: [4]f32, element: base.Handle, code: int, why: string) {
	h, valid := page.query_first(t.page, selector)
	if !valid { return {}, h, remote.ERR_PARAMS, fmt.tprintf("invalid selector %q", selector) }
	if h == base.NIL_HANDLE { return {}, h, remote.ERR_FAILED, fmt.tprintf("no element matches %q", selector) }
	r, ok := element_window_rect(app, t, h)
	if !ok { return {}, h, remote.ERR_FAILED, "the element has no box (display: none, or the layout is not made yet)" }
	return r, h, 0, ""
}

// The numbers of control_stats that are about one subject of this file.
control_stats_window :: proc(app: ^App, st: ^api.Stats, allocator := context.temp_allocator) {
	wnd := active_window(app)
	st.cursor = control_cursor(app, allocator)
	st.surface, st.panel_surface = control_surfaces(app)
	st.gpu_process_id, st.gpu_process_starts = webgl.gpu_process_id(), webgl.gpu_process_starts()
	st.chrome_frames, st.full_frames = int(chrome_frames.frames), int(chrome_frames.frame_no)
	st.fps, st.frames_presented = f64(hud.nums.fps), app.frame_log.presented
	st.working_set_bytes, st.private_bytes = int(hud.nums.working_set), int(hud.nums.private_bytes)
	loops := platform.pump_stats(wnd.win)
	st.paint_frames, st.modal_loops = loops.paint_frames, loops.modal_loops
	if wnd.ui != nil {
		au, ar, an := ui.a11y_stats(wnd.ui)
		ps := page_a11y_stats(wnd)
		st.a11y = {
			updates = au, refused = ar, last_nodes = an, nodes = len(ui.a11y_tree(wnd.ui).nodes), page_builds = ps.builds, page_patches = ps.patches, page_sends = ps.sends,
			page_refused = ps.refused, page_nodes = ps.nodes, page_written = ps.written, page_frames = ps.frames, page_verify_failed = ps.verify_failed,
			page_fallback = strings.clone(ps.fallback, allocator), page_verify_diff = strings.clone(ps.verify_diff, allocator),
		}
	}
}

////////////////////////////////
// What a screen reader is told

// A node of what the active window tells a screen reader, flat: the chrome's, its page's and its frames' documents.
A11y_Entry :: struct {
	id:       u64,
	tree:     platform.A11y_Tree_Id,   // the zero one: the chrome's
	depth:    int,                     // 0: the chrome, 1: the page, 2: a frame of it
	role:     platform.A11y_Role,
	name:     string,
	value:    string,
	flags:    platform.A11y_Flags,
	toggled:  platform.A11y_Toggled,
	has_toggled: bool,
	bounds:   [4]f64,
}

// From now on the active window makes its tree whether or not a screen reader reads it: it can be read at the next frame.
control_a11y_capture :: proc(app: ^App, on: bool) {
	ui.a11y_capture(active_window(app).ui, on)
	request_frames(app, 2)
}

// The tree as the last frame made it (control_a11y_capture first).
control_a11y_tree :: proc(app: ^App, allocator := context.temp_allocator) -> []A11y_Entry {
	wnd := active_window(app)
	list := make([dynamic]A11y_Entry, allocator)
	a11y_update_entries(ui.a11y_tree(wnd.ui), 0, &list, allocator)
	pa := &window_own(app).a11y
	if pa.top != nil { a11y_update_entries(&pa.top.full, 1, &list, allocator) }
	for d in pa.frames { a11y_update_entries(&d.full, 2, &list, allocator) }
	return list[:]
}

@(private = "file")
a11y_update_entries :: proc(u: ^platform.A11y_Update, depth: int, out: ^[dynamic]A11y_Entry, allocator := context.temp_allocator) {
	for n in u.nodes {
		e := A11y_Entry{id = n.id, tree = u.tree, depth = depth, role = platform.A11y_Role(n.role), flags = n.flags, bounds = n.bounds}
		for p in u.props[n.props_off:][:n.props_len] {
			text := p.len > 0 && int(p.a) + int(p.len) <= len(u.bytes) ? string(u.bytes[p.a:][:p.len]) : ""
			#partial switch p.kind {
			case .Label: e.name = strings.clone(text, allocator)
			case .Value: e.value = strings.clone(text, allocator)
			case .Toggled: e.toggled, e.has_toggled = platform.A11y_Toggled(p.a), true
			}
		}
		append(out, e)
	}
}

// As if a screen reader had asked it of that node: the next frame takes it.
control_a11y_act :: proc(app: ^App, c: ^Call, e: A11y_Entry, r: platform.A11y_Request) -> Reply {
	x := r
	x.target, x.tree = e.id, e.tree
	ui.a11y_inject(active_window(app).ui, x)
	return frames_op(app, c, nil, the_remote.cfg.settle_frames)
}
