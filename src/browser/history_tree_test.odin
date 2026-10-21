package browser

import "core:fmt"
import "core:testing"
import "core:time"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:ui"
import "wb:page"

// A tree with branches: a b c / b d / a e, plus a long chain under e.
@(private = "file")
sample_tree :: proc(sh: ^page.Session_History, chain := 0) {
	page.session_set_limits(sh, 100, 100_000)
	page.session_push(sh, "a", 0)
	page.session_push(sh, "b", 0)
	page.session_push(sh, "c", 0)
	page.session_go(sh, -1)
	page.session_push(sh, "d", 0)
	page.session_go(sh, -2)
	page.session_push(sh, "e", 0, max_entries = 100)
	for i in 0 ..< chain { page.session_push(sh, fmt.tprintf("x%d", i), 0, max_entries = 100) }
}

@(private = "file")
overlap :: proc(a, b: [2]f32) -> bool {
	return a.x < b.x + NODE_SIZE.x && b.x < a.x + NODE_SIZE.x && a.y < b.y + NODE_SIZE.y && b.y < a.y + NODE_SIZE.y
}

// Both layouts: no two nodes overlap, a child is after its parent along time, a later lane is below (horizontal) or to
// the right (vertical), everything is inside the extent.
@(test)
tree_layouts_place_without_overlap :: proc(t: ^testing.T) {
	sh: page.Session_History
	defer page.session_destroy(&sh)
	sample_tree(&sh, 6)
	m: Tree_Model
	defer delete(m.nodes)
	tree_model_build(&m, &sh)
	testing.expect_value(t, len(m.nodes), 11)
	for l in Tree_Layout {
		ext := tree_extent(l, m.rows, m.cols)
		for a, i in m.nodes {
			pa := tree_node_pos(l, a.col, a.row)
			testing.expect(t, pa.x >= 0 && pa.y >= 0 && pa.x + NODE_SIZE.x <= ext.x + 0.001 && pa.y + NODE_SIZE.y <= ext.y + 0.001)
			for b, j in m.nodes {
				if j <= i { continue }
				testing.expect(t, !overlap(pa, tree_node_pos(l, b.col, b.row)), fmt.tprint(l, a.entry.url, b.entry.url))
			}
			if a.parent >= 0 {
				pp := tree_node_pos(l, m.nodes[a.parent].col, m.nodes[a.parent].row)
				switch l {
				case .Horizontal: testing.expect(t, pa.x > pp.x && pa.y >= pp.y)
				case .Vertical:   testing.expect(t, pa.y > pp.y && pa.x >= pp.x)
				}
			}
		}
	}
	// the current entry and the active path
	testing.expect(t, m.current >= 0 && m.nodes[m.current].entry.url == "x5")
	for n in m.nodes {
		on := n.entry.url != "b" && n.entry.url != "c" && n.entry.url != "d"
		testing.expect(t, n.on_path == on, n.entry.url)
	}
}

@(test)
tree_camera_math :: proc(t: ^testing.T) {
	em: f32 = 15
	vc := [2]f32{400, 300}
	c := Tree_Camera{{20, 10}, 1}
	// the world point under the pointer stays under it through a zoom
	p := [2]f32{620, 120}
	w := cam_to_world(c, vc, em, p)
	for z in ([]f32{0.1, 0.5, 2, 3.7}) {
		c2 := cam_zoom_at(c, vc, em, p, z)
		back := cam_to_screen(c2, vc, em, w)
		testing.expect(t, abs(back.x - p.x) < 0.01 && abs(back.y - p.y) < 0.01, fmt.tprint(z, back))
	}
	// a pan moves the content with the pointer
	c3 := cam_pan(c, em, {30, -12})
	s0 := cam_to_screen(c, vc, em, {5, 5})
	s1 := cam_to_screen(c3, vc, em, {5, 5})
	testing.expect(t, abs(s1.x - s0.x - 30) < 0.01 && abs(s1.y - s0.y + 12) < 0.01)
	// fit: the whole extent inside the view, centered, within the bounds
	ext := [2]f32{300, 40}
	f := cam_fit(ext, {800, 600}, em, 1, 0.01, 1)
	testing.expect(t, f.center == ext * 0.5)
	testing.expect(t, (ext.x + 2) * em * f.zoom <= 800.01 && f.zoom < 1)
	small := cam_fit({10, 3}, {800, 600}, em, 1, 0.01, 1)
	testing.expect_value(t, small.zoom, 1)   // never past the fit maximum
	fit_clear_cases(t)
	// clamp, reveal, lerp
	cl := cam_clamp({{-50, 500}, 9}, ext, 0.1, 4)
	testing.expect(t, cl.center == {0, 40} && cl.zoom == 4)
	r := cam_reveal(c, {800, 600}, em, {100, 0}, {111.5, 2.6}, 1)
	half := 800 / em * 0.5
	testing.expect(t, abs(r.center.x - (112.5 - half)) < 0.01 && r.center.y == c.center.y)
	inside := cam_reveal(c, {800, 600}, em, {18, 9}, {19, 10}, 0)
	testing.expect(t, inside == c)
	// contain: a long tree shows no empty space past its end; a short one is centered across
	ct := cam_contain({{300, 20}, 1}, {300, 40}, {800, 600}, em, {1, 1}, {1, 1})
	testing.expect(t, abs(ct.center.x - (301 - 800 / em * 0.5)) < 0.01 && ct.center.y == 20)
	short := cam_contain({{5, 0}, 1}, {10, 3}, {800, 600}, em, {1, 1}, {1, 5})
	testing.expect(t, short.center == {5, 3.5})   // centered in what the bottom margin leaves
	mid := cam_lerp({{0, 0}, 1}, {{10, 0}, 4}, 0.5)
	testing.expect(t, abs(mid.zoom - 2) < 0.001 && mid.center.x == 5)
	testing.expect(t, ease_out(0) == 0 && ease_out(1) == 1 && ease_out(0.5) > 0.5)
}

@(test)
tree_click_or_drag :: proc(t: ^testing.T) {
	testing.expect(t, !drag_started({10, 10}, {13, 12}, 4))
	testing.expect(t, drag_started({10, 10}, {15, 10}, 4))
	testing.expect(t, !drag_started({10, 10}, {10, 10}, 0))
	testing.expect(t, drag_started({10, 10}, {10.5, 10}, 0))
}

@(test)
tree_culling_and_detail :: proc(t: ^testing.T) {
	sh: page.Session_History
	defer page.session_destroy(&sh)
	sample_tree(&sh, 200)
	m: Tree_Model
	defer delete(m.nodes)
	tree_model_build(&m, &sh)
	out := make([dynamic]i32)
	defer delete(out)
	for l in Tree_Layout {
		ext := tree_extent(l, m.rows, m.cols)
		tree_cull(m.nodes[:], l, {-1, -1}, ext + 1, &out)
		testing.expect_value(t, len(out), len(m.nodes))
		// a small window: exactly the nodes that meet it
		lo, hi := [2]f32{20, 0}, [2]f32{60, 12}
		tree_cull(m.nodes[:], l, lo, hi, &out)
		testing.expect(t, len(out) > 0 && len(out) < len(m.nodes))
		k := 0
		for n, i in m.nodes {
			p := tree_node_pos(l, n.col, n.row)
			meets := !(p.x > hi.x || p.y > hi.y || p.x + NODE_SIZE.x < lo.x || p.y + NODE_SIZE.y < lo.y)
			if meets { testing.expect(t, k < len(out) && out[k] == i32(i)); k += 1 }
		}
		testing.expect_value(t, k, len(out))
		tree_cull(m.nodes[:], l, {-500, -500}, {-400, -400}, &out)
		testing.expect_value(t, len(out), 0)
	}
	// text sizes: exact at a zoom of 1, never above the ideal, few distinct sizes over a continuous zoom
	testing.expect_value(t, text_size_step(15, 15), 15)
	testing.expect_value(t, text_size_step(30, 15), 30)
	sizes := make(map[f32]bool, 64, context.temp_allocator)
	prev: f32 = 0
	for px := f32(6); px < 60; px += 0.1 {
		fs := text_size_step(px, 15)
		testing.expect(t, fs <= px + 0.01 && fs >= prev, fmt.tprint(px, fs, prev))
		prev = fs
		sizes[fs] = true
	}
	testing.expect(t, len(sizes) < 40, fmt.tprint(len(sizes)))   // (54 whole pixels in that range)
	testing.expect_value(t, tree_detail(15), Tree_Detail.Full)
	testing.expect_value(t, tree_detail(9), Tree_Detail.Title)
	testing.expect_value(t, tree_detail(5), Tree_Detail.Icon)
	testing.expect_value(t, tree_detail(1), Tree_Detail.Block)
}

// The canvas takes the wheel over it and the zoom keys (Ctrl+Plus / Minus / 0), only while about:history shows the
// tree and nothing else has the keyboard; the rest of the frame's events go on to the chrome.
@(test)
tree_takes_its_events :: proc(t: ^testing.T) {
	page_render_test_lock()
	defer page_render_test_unlock()
	app := new(App)
	defer free(app)
	ui.init(&app.ui_state, nil, nil)
	defer ui.destroy(&app.ui_state)
	tab := new(Tab)
	defer free(tab)
	tab.kind = .History
	append(&app.tabs, tab)
	defer delete(app.tabs)
	saved_mode := hview.mode
	defer hview.mode = saved_mode
	defer history_tree_destroy()   // the canvas's state, as about:history's closing leaves it
	hview.mode = 1
	tview.built = app.ui_state.build_index
	tview.view_rect = {{0, 100}, {800, 600}}
	events := []platform.Event{
		{kind = .Scroll, pos = {400, 300}, delta = {0, 1}},
		{kind = .Scroll, pos = {400, 50}, delta = {0, 1}},           // over the toolbar: not the canvas's
		{kind = .Key_Press, key = .Equal, mods = {.Ctrl}},
		{kind = .Key_Press, key = .N0, mods = {.Ctrl}},
		{kind = .Key_Press, key = .T, mods = {.Ctrl}},               // a shortcut of the chrome
		{kind = .Mouse_Move, pos = {10, 10}},
	}
	rest := history_tree_events(app, events)
	testing.expect_value(t, len(tview.pending), 3)
	testing.expect_value(t, len(rest), 3)
	// another part of about:history, or a field with the keyboard: nothing is taken
	hview.mode = 0
	testing.expect_value(t, len(history_tree_events(app, events)), len(events))
	hview.mode = 1
	ui.set_focus(12345)
	rest = history_tree_events(app, events)
	testing.expect_value(t, len(rest), 5)   // the wheel still, not the keys
	ui.set_focus(0)
	tab.kind = .Web
	testing.expect_value(t, len(history_tree_events(app, events)), len(events))
}

// 5000 entries in branches: building the model and culling it per frame stay far below a frame at 180 Hz.
@(test)
tree_large_model_is_cheap :: proc(t: ^testing.T) {
	sh: page.Session_History
	defer page.session_destroy(&sh)
	page.session_set_limits(&sh, 100, 100_000)
	for i in 0 ..< 5000 {
		page.session_push(&sh, fmt.tprintf("https://site%d.example/%d", i % 37, i), 0, max_entries = 100)
		if i % 9 == 8 { page.session_go(&sh, -3) }   // a new branch now and then
		free_all(context.temp_allocator)
	}
	m: Tree_Model
	defer delete(m.nodes)
	start := time.tick_now()
	tree_model_build(&m, &sh)
	build_ms := time.duration_milliseconds(time.tick_since(start))
	testing.expect_value(t, len(m.nodes), 5000)
	out := make([dynamic]i32)
	defer delete(out)
	start = time.tick_now()
	for _ in 0 ..< 100 { tree_cull(m.nodes[:], .Horizontal, {100, 100}, {180, 140}, &out) }
	cull_ms := time.duration_milliseconds(time.tick_since(start)) / 100
	fmt.printf("history tree, 5000 entries: model %.3f ms, cull %.4f ms (%d in view)\n", build_ms, cull_ms, len(out))
	testing.expect(t, cull_ms < 1)
}

// "Fit" fills the view and keeps clear of the controls in its bottom-left corner (the vertical layout used to stop at
// about two thirds of the height: the controls' band was taken off at the top too).
@(private = "file")
fit_clear_cases :: proc(t: ^testing.T) {
	em := f32(27.8)
	view := [2]f32{1780, 710}
	under := draw.Rect{{22, 620}, {470, 690}}
	screen_rect :: proc(c: Tree_Camera, extent, view: [2]f32, em: f32) -> draw.Rect {
		vc := view * 0.5
		return {cam_to_screen(c, vc, em, {0, 0}), cam_to_screen(c, vc, em, extent)}
	}
	overlaps :: proc(a, b: draw.Rect) -> bool { return a.min.x < b.max.x && a.max.x > b.min.x && a.min.y < b.max.y && a.max.y > b.min.y }
	// a tall tree (the vertical layout): the whole height, beside the controls
	tall := [2]f32{52, 50.6}
	c, need := cam_fit_clear(tall, view, em, em, under, 0.01, 4)
	r := screen_rect(c, tall, view, em)
	testing.expectf(t, r.max.y - r.min.y >= 0.9 * view.y, "tall tree fills the height: %v", r)
	testing.expectf(t, !overlaps(r, under), "clear of the controls: %v", r)
	testing.expectf(t, r.min.x >= 0 && r.min.y >= 0 && r.max.x <= view.x && r.max.y <= view.y, "inside the view: %v", r)
	testing.expect(t, need == c.zoom)
	// a long flat tree (horizontal): the whole width, centered (it does not reach the controls)
	flat := [2]f32{170, 14}
	c, _ = cam_fit_clear(flat, view, em, em, under, 0.01, 4)
	r = screen_rect(c, flat, view, em)
	testing.expectf(t, r.max.x - r.min.x >= 0.95 * view.x, "flat tree fills the width: %v", r)
	testing.expect(t, abs(c.center.x - flat.x * 0.5) < 0.01 && abs(c.center.y - flat.y * 0.5) < 0.01, "centered")
	// a tree that would reach the controls and is wide: above them
	wide := [2]f32{120, 30}
	c, _ = cam_fit_clear(wide, view, em, em, under, 0.01, 4)
	r = screen_rect(c, wide, view, em)
	testing.expectf(t, !overlaps(r, under) && r.max.y <= under.min.y, "above the controls: %v", r)
	// a small tree: the fit maximum, centered
	c, need = cam_fit_clear({10, 3}, view, em, em, under, 0.01, 1)
	testing.expect(t, c.zoom == 1 && need > 1 && c.center == [2]f32{5, 1.5}, "small tree at the maximum, centered")
	// no controls: the whole view
	c, _ = cam_fit_clear(tall, view, em, em, {}, 0.01, 4)
	r = screen_rect(c, tall, view, em)
	testing.expectf(t, abs((r.max.y - r.min.y) - (view.y - 2 * em)) < 0.5, "whole height but the margins: %v", r)
}