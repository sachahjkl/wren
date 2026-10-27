package browser

// The tab's history tree of about:history#tree, as a canvas one moves around in, like a graph tool:
//   * moving: drag with the left button (on the background, or on a node once past a few pixels: a click stays a
//     click) or with the middle button anywhere; the wheel scrolls vertically, Shift+wheel horizontally, a touchpad's
//     two-finger scroll both ways; the arrow keys (Shift: farther), Page Up / Page Down; a drag that is let go while
//     moving glides on a little (browser.history.tree_inertia);
//   * zoom: Ctrl+wheel (and a touchpad's pinch, which Windows sends as one) around the pointer, Ctrl+Plus / Minus / 0
//     and + / - / 0 while the canvas has the keyboard, the "−  100 %  +" buttons; "Fit" shows the whole tree, "Current"
//     centers the tab's current entry. Text is laid out again at each zoom (sharp, never a stretched bitmap) and nodes
//     simplify as they get small: icon and title, then the icon alone, then a plain block;
//   * two layouts: horizontal (the root on the left, time going right, branches below) and vertical (the root at the
//     top, time going down, branches to the right), switched by the toolbar's control or L, remembered in
//     browser.history.tree_layout; the nodes slide to their new places (not when Windows' animations are off);
//   * a minimap in the corner when the tree is larger than the view: the view's rectangle, a click or a drag moves it;
//   * a node: click = make it the tab's current entry, middle click = open it in a new tab, right click = its menu
//     (open, open in a new tab, copy the address, forget the branch), hover = its title, address and visit time.
// Only what is in view is drawn (the model is rebuilt only when the tree changes), in one custom box: thousands of
// entries cost a loop over plain structs per frame, and nothing is drawn at rest.

import "core:fmt"
import "core:math"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:platform"
import "toolkit:ui"
import "wb:config"
import "wb:page"

HISTORY_TREE_PREFS := [?]config.Def{
	{name = "browser.history.tree_layout", kind = .String, default = {s = "horizontal"}, choices = {"horizontal", "vertical"},
		description = "Layout of the tab's history tree (about:history#tree): horizontal puts the first entry on the left with time going right and branches below; vertical puts it at the top with time going down and branches to the right. The tree's toolbar and the L key switch it."},
	{name = "browser.history.tree_zoom_min", kind = .Float, default = {f = 0.05}, bounded = true, min = 0.005, max = 1,
		description = "Smallest zoom of the history tree (1 = the interface's size)."},
	{name = "browser.history.tree_zoom_max", kind = .Float, default = {f = 4}, bounded = true, min = 1, max = 16,
		description = "Largest zoom of the history tree."},
	{name = "browser.history.tree_zoom_step", kind = .Float, default = {f = 1.15}, bounded = true, min = 1.01, max = 4,
		description = "Zoom factor of one wheel notch with Ctrl, of Ctrl+Plus / Ctrl+Minus and of the tree's - and + buttons."},
	{name = "browser.history.tree_fit_max_zoom", kind = .Float, default = {f = 1}, bounded = true, min = 0.05, max = 16,
		description = "\"Fit\" (and the first view of a tree that fits) never zooms in past this: a small tree keeps the interface's size."},
	{name = "browser.history.tree_drag_threshold_px", kind = .Float, default = {f = 4}, bounded = true, min = 0, max = 100, unit = "px",
		description = "A press on the history tree that moves less than this before it is released is a click (on a node: go there); farther, it moves the view."},
	{name = "browser.history.tree_transition_ms", kind = .Float, default = {f = 220}, bounded = true, min = 0, max = 3000, unit = "ms",
		description = "Length of the history tree's animated moves: switching layouts (the nodes slide to their new places), Fit, Current, the zoom buttons and keys. 0, or Windows' animations turned off, jumps at once."},
	{name = "browser.history.tree_inertia", kind = .Bool, default = {b = true},
		description = "A drag of the history tree let go while moving glides on and slows down (off, or Windows' animations turned off: it stops where it is let go)."},
	{name = "browser.history.tree_inertia_friction", kind = .Float, default = {f = 6}, bounded = true, min = 0.5, max = 100, unit = "1/s",
		description = "How fast the glide after a drag of the history tree slows down (its speed is divided by e every 1/friction seconds)."},
	{name = "browser.history.tree_key_step_px", kind = .Float, default = {f = 60}, bounded = true, min = 1, max = 5000, unit = "px",
		description = "Distance the arrow keys move the history tree (Shift: four times as far)."},
	{name = "browser.history.tree_minimap", kind = .Bool, default = {b = true},
		description = "Show a minimap of the history tree in its corner when the tree is larger than the view."},
	{name = "browser.history.tree_tooltip_ms", kind = .Float, default = {f = 450}, bounded = true, min = 0, max = 10_000, unit = "ms",
		description = "How long the pointer rests on a node of the history tree before its title, address and visit time show."},
}

Tree_Layout :: enum u8 { Horizontal, Vertical }

Tree_Settings :: struct {
	layout:          Tree_Layout,
	zoom_min, zoom_max, zoom_step, fit_max: f32,
	drag_threshold:  f32,
	transition_ms:   f64,
	inertia:         bool,
	friction:        f32,
	key_step:        f32,
	minimap:         bool,
	tooltip_ms:      f64,
}

tree_settings_from_prefs :: proc(p: ^config.Prefs) -> Tree_Settings {
	zmin := f32(config.float_of(p, "browser.history.tree_zoom_min"))
	return Tree_Settings{
		layout = config.string_of(p, "browser.history.tree_layout") == "vertical" ? .Vertical : .Horizontal,
		zoom_min = zmin,
		zoom_max = max(f32(config.float_of(p, "browser.history.tree_zoom_max")), zmin),
		zoom_step = f32(config.float_of(p, "browser.history.tree_zoom_step")),
		fit_max = f32(config.float_of(p, "browser.history.tree_fit_max_zoom")),
		drag_threshold = f32(config.float_of(p, "browser.history.tree_drag_threshold_px")),
		transition_ms = config.float_of(p, "browser.history.tree_transition_ms"),
		inertia = config.bool_of(p, "browser.history.tree_inertia"),
		friction = f32(config.float_of(p, "browser.history.tree_inertia_friction")),
		key_step = f32(config.float_of(p, "browser.history.tree_key_step_px")),
		minimap = config.bool_of(p, "browser.history.tree_minimap"),
		tooltip_ms = config.float_of(p, "browser.history.tree_tooltip_ms"),
	}
}

tcfg: Tree_Settings
@(private = "file") tree_watch: int

// (history_settings_init / _shutdown)
history_tree_settings_init :: proc(app: ^App) {
	tcfg = tree_settings_from_prefs(&app.prefs)
	tree_watch = config.watch(&app.prefs, "browser.history.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		tcfg = tree_settings_from_prefs(p)
		request_frames((^App)(user), 2)
	}, app)
}

history_tree_settings_shutdown :: proc(app: ^App) { config.unwatch(&app.prefs, tree_watch) }

////////////////////////////////
// Geometry (pure: history_tree_test.odin). World units are em of the interface: a zoom of 1 draws the tree at the
// interface's size.

Tree_Node :: struct {
	entry:   ^page.History_Entry,
	id:      u64,
	col, row: i32,      // depth, lane (tree_place)
	parent:  i32,       // index in the model, -1 for a top-level entry
	on_path: bool,      // on the path back and forward walk
	current: bool,
}

Tree_Metrics :: struct { node, pitch: [2]f32 }

NODE_SIZE :: [2]f32{11.5, 2.6}

tree_metrics :: proc(l: Tree_Layout) -> Tree_Metrics {
	switch l {
	case .Horizontal: return {NODE_SIZE, NODE_SIZE + {1.8, 0.8}}
	case .Vertical:   return {NODE_SIZE, NODE_SIZE + {1.2, 1.4}}
	}
	return {}
}

// Top-left corner of a node.
tree_node_pos :: proc(l: Tree_Layout, col, row: i32) -> [2]f32 {
	m := tree_metrics(l)
	switch l {
	case .Horizontal: return {f32(col) * m.pitch.x, f32(row) * m.pitch.y}
	case .Vertical:   return {f32(row) * m.pitch.x, f32(col) * m.pitch.y}
	}
	return {}
}

// Size of the whole tree (its top-left corner is the origin).
tree_extent :: proc(l: Tree_Layout, rows, cols: int) -> [2]f32 {
	if rows <= 0 || cols <= 0 { return {} }
	m := tree_metrics(l)
	gap := m.pitch - m.node
	n := l == .Horizontal ? [2]f32{f32(cols), f32(rows)} : [2]f32{f32(rows), f32(cols)}
	return n * m.pitch - gap
}

// Where the camera looks: the world point at the view's center, and the zoom (screen pixels per world unit = em * zoom).
Tree_Camera :: struct { center: [2]f32, zoom: f32 }

cam_to_screen :: proc(c: Tree_Camera, view_center: [2]f32, em: f32, w: [2]f32) -> [2]f32 { return view_center + (w - c.center) * (em * c.zoom) }
cam_to_world :: proc(c: Tree_Camera, view_center: [2]f32, em: f32, p: [2]f32) -> [2]f32 { return c.center + (p - view_center) / (em * c.zoom) }

// Zooms to `zoom` keeping the world point under the screen point `p` where it is.
cam_zoom_at :: proc(c: Tree_Camera, view_center: [2]f32, em: f32, p: [2]f32, zoom: f32) -> Tree_Camera {
	w := cam_to_world(c, view_center, em, p)
	return {w - (p - view_center) / (em * zoom), zoom}
}

// The content follows a pointer that moved by `d` screen pixels.
cam_pan :: proc(c: Tree_Camera, em: f32, d: [2]f32) -> Tree_Camera { return {c.center - d / (em * c.zoom), c.zoom} }

// The whole tree in a view of `view` pixels, `pad` world units around it, the zoom within [zmin, zmax].
cam_fit :: proc(extent, view: [2]f32, em, pad, zmin, zmax: f32) -> Tree_Camera {
	e := extent + pad * 2
	z := zmax
	if e.x > 0 && e.y > 0 && view.x > 0 && view.y > 0 { z = min(view.x / (e.x * em), view.y / (e.y * em)) }
	return {extent * 0.5, clamp(z, zmin, zmax)}
}

// The whole tree as large as it fits in a view of `view` pixels, `margin` pixels from its edges, without going under
// `under` (view pixels: the controls over the view's bottom-left corner; an empty rect: nothing). The tree stays
// centered when it clears `under` that way; else it goes in the larger of the band above `under` and the part of the
// view beside it, centered there. `need` is the zoom before [zmin, zmax] (does the tree fit at the zoom wanted?).
cam_fit_clear :: proc(extent, view: [2]f32, em, margin: f32, under: draw.Rect, zmin, zmax: f32) -> (cam: Tree_Camera, need: f32) {
	if extent.x <= 0 || extent.y <= 0 || view.x <= 0 || view.y <= 0 || em <= 0 { return {extent * 0.5, clamp(zmax, zmin, zmax)}, zmax }
	zoom_in :: proc(extent, room: [2]f32, em: f32) -> f32 { return max(min(room.x / (extent.x * em), room.y / (extent.y * em)), 0) }
	// the tree's screen rectangle at zoom z, centered on the point c of the view
	rect_at :: proc(extent: [2]f32, em, z: f32, c: [2]f32) -> draw.Rect { h := extent * em * z * 0.5; return {c - h, c + h} }
	clear_of :: proc(r, o: draw.Rect, margin: f32) -> bool {
		return r.max.x <= o.min.x - margin || r.min.x >= o.max.x + margin || r.max.y <= o.min.y - margin || r.min.y >= o.max.y + margin
	}
	full := view - 2 * margin
	z := zoom_in(extent, full, em)
	center := view * 0.5
	has_under := under.max.x > under.min.x && under.max.y > under.min.y
	if has_under && !clear_of(rect_at(extent, em, min(z, zmax), center), under, margin) {
		// above: the band from the top margin to the controls
		above := [2]f32{full.x, under.min.y - 2 * margin}
		za := above.y > 0 ? zoom_in(extent, above, em) : 0
		ca := [2]f32{view.x * 0.5, margin + above.y * 0.5}
		// beside: right of the controls, the whole height
		beside := [2]f32{view.x - under.max.x - 2 * margin, full.y}
		zb := beside.x > 0 ? zoom_in(extent, beside, em) : 0
		cb := [2]f32{under.max.x + margin + beside.x * 0.5, view.y * 0.5}
		// (a tree that is too small to reach the controls at the zoom allowed stays centered)
		z, center = za >= zb ? za : zb, za >= zb ? ca : cb
	}
	zc := clamp(z, zmin, zmax)
	// the world point at the view's center puts the tree's center at `center`
	return {extent * 0.5 - (center - view * 0.5) / (em * zc), zc}, z
}

// The view's center stays over the tree, the zoom within its bounds.
cam_clamp :: proc(c: Tree_Camera, extent: [2]f32, zmin, zmax: f32) -> Tree_Camera {
	return {{clamp(c.center.x, 0, max(extent.x, 0)), clamp(c.center.y, 0, max(extent.y, 0))}, clamp(c.zoom, zmin, zmax)}
}

// The view kept over the tree: along an axis where the tree (with `lo` / `hi` world units of margin before / after it)
// is larger than the view, no empty space past its ends; where it is smaller, centered in the space the margins leave.
cam_contain :: proc(c: Tree_Camera, extent, view: [2]f32, em: f32, lo, hi: [2]f32) -> Tree_Camera {
	half := view / (em * c.zoom) * 0.5
	out := c
	for i in 0 ..< 2 {
		if extent[i] + lo[i] + hi[i] > half[i] * 2 {
			out.center[i] = clamp(c.center[i], half[i] - lo[i], extent[i] + hi[i] - half[i])
		} else {
			out.center[i] = (extent[i] + hi[i] - lo[i]) * 0.5
		}
	}
	return out
}

// The smallest move that brings the world rectangle [a, b] (with `margin` world units) into a view of `view` pixels.
cam_reveal :: proc(c: Tree_Camera, view: [2]f32, em: f32, a, b: [2]f32, margin: f32) -> Tree_Camera {
	half := view / (em * c.zoom) * 0.5
	out := c
	for i in 0 ..< 2 {
		lo, hi := a[i] - margin, b[i] + margin
		if hi - lo > half[i] * 2 { out.center[i] = (a[i] + b[i]) * 0.5; continue }   // larger than the view: centered
		if lo < c.center[i] - half[i] { out.center[i] = lo + half[i] }
		if hi > c.center[i] + half[i] { out.center[i] = hi - half[i] }
	}
	return out
}

// Between two cameras: the center straight, the zoom geometrically (a zoom feels even that way).
cam_lerp :: proc(a, b: Tree_Camera, t: f32) -> Tree_Camera {
	z := a.zoom > 0 && b.zoom > 0 ? math.exp(math.lerp(math.ln(a.zoom), math.ln(b.zoom), t)) : b.zoom
	return {a.center + (b.center - a.center) * t, z}
}

ease_out :: proc(t: f32) -> f32 { u := 1 - clamp(t, 0, 1); return 1 - u * u * u }

// A press became a drag: the pointer went farther than the threshold from where it was pressed.
drag_started :: proc(start, now: [2]f32, threshold: f32) -> bool {
	d := now - start
	return d.x * d.x + d.y * d.y > threshold * threshold
}

// The nodes whose rectangle meets the world rectangle [lo, hi], in model order.
tree_cull :: proc(nodes: []Tree_Node, l: Tree_Layout, lo, hi: [2]f32, out: ^[dynamic]i32) {
	clear(out)
	n := tree_metrics(l).node
	for nd, i in nodes {
		p := tree_node_pos(l, nd.col, nd.row)
		if p.x > hi.x || p.y > hi.y || p.x + n.x < lo.x || p.y + n.y < lo.y { continue }
		append(out, i32(i))
	}
}

// The font size text is laid out at for an ideal size `px`: steps of about 8 % from `base` (the size at a zoom of 1,
// which is thus exact), never above the ideal, in whole pixels. Each size is rasterized once; during a zoom the steps
// keep that to a few dozen sizes instead of one per pixel.
text_size_step :: proc(px, base: f32) -> f32 {
	if px <= 0 || base <= 0 { return 1 }
	k := math.floor(math.ln(px / base) / math.ln(f32(1.08)) + 0.001)
	return max(min(math.round(base * math.pow(f32(1.08), k)), math.floor(px + 0.001)), 1)
}

// How much of a node is drawn, from the size of an em on screen.
Tree_Detail :: enum u8 { Block, Icon, Title, Full }

tree_detail :: proc(em_px: f32) -> Tree_Detail {
	switch {
	case em_px * 0.8 >= 9: return .Full     // the second line (time, host) is still readable
	case em_px >= 8:       return .Title
	case em_px * NODE_SIZE.y >= 10: return .Icon
	}
	return .Block
}

////////////////////////////////
// The model: the tree's nodes in place, rebuilt when the tree changes

Tree_Model :: struct {
	tab:     u64,
	serial:  u64,
	root:    rawptr,
	count:   int,
	nodes:   [dynamic]Tree_Node,
	rows, cols: int,
	current: i32,   // index of the current entry, -1
}

tree_model_build :: proc(m: ^Tree_Model, sh: ^page.Session_History) {
	clear(&m.nodes)
	places, rows, cols := tree_place(sh)
	m.rows, m.cols, m.current = rows, cols, -1
	path := make(map[^page.History_Entry]bool, 64, context.temp_allocator)
	if cur := page.session_current(sh); cur != nil {
		for a := cur; a != nil; a = a.parent { path[a] = true }
		for d := page.session_active_child(cur); d != nil; d = page.session_active_child(d) { path[d] = true }
	}
	cur := page.session_current(sh)
	reserve(&m.nodes, len(places))
	for p, i in places {
		append(&m.nodes, Tree_Node{entry = p.entry, id = p.entry.id, col = i32(p.col), row = i32(p.row), parent = i32(p.parent), on_path = p.entry in path, current = p.entry == cur})
		if p.entry == cur { m.current = i32(i) }
	}
}

@(private = "file")
tree_model_update :: proc(m: ^Tree_Model, t: ^Tab) {
	sh := &t.session
	if m.tab == t.id && m.serial == sh.serial && m.root == rawptr(sh.root) && m.count == sh.count { return }
	m.tab, m.serial, m.root, m.count = t.id, sh.serial, rawptr(sh.root), sh.count
	tree_model_build(m, sh)
}

////////////////////////////////
// The view's state

@(private = "file")
Saved_Camera :: struct { cam: Tree_Camera, layout: Tree_Layout }

@(private = "file")
Drag :: struct {
	on:      bool,
	button:  platform.Mouse_Button,
	panning: bool,
	start, last: [2]f32,
	node:    u64,               // the entry pressed (0: the background)
	samples: [6][3]f64,         // (x, y, ms) of the last moves: the glide's speed
	n:       int,
}

Tree_View_State :: struct {
	model:      Tree_Model,
	cams:       map[u64]Saved_Camera,   // per tab, for this session
	cam:        Tree_Camera,
	cam_tab:    u64,
	cam_ok:     bool,
	go_from, go_to: Tree_Camera,         // animated move
	go_start:   f64,
	go_ms:      f64,
	going:      bool,
	layout:     Tree_Layout,             // shown (tcfg.layout is the wanted one)
	layout_from: Tree_Layout,
	layout_start: f64,
	layout_t:   f32,                     // 1: settled
	layout_ok:  bool,
	drag:       Drag,
	vel:        [2]f32,                  // glide, screen px per second
	gliding:    bool,
	last_ms:    f64,
	hover:      u64,
	hover_ms:   f64,
	menu_entry: u64,
	pending:    [dynamic]platform.Event, // wheel and zoom keys taken from the frame's events (history_tree_events)
	view_key:   ui.Key,
	view_rect:  draw.Rect,
	built:      u64,                     // ui build index of the last frame the canvas was built in
	revealed:   u64,                     // the current entry last brought into view
	visible:    [dynamic]i32,            // scratch: the nodes in view
	controls:   draw.Rect,               // the zoom / Fit / Current bar of the last layout, in view pixels
}

tview: Tree_View_State

history_tree_destroy :: proc() {
	delete(tview.model.nodes)
	delete(tview.cams)
	delete(tview.pending)
	delete(tview.visible)
	tview = {}
}

// The frame's wheel events over the canvas and, while it has the keyboard (or nothing has), Ctrl+Plus / Minus / 0:
// the canvas takes them before the chrome (whose shortcuts would zoom a page) and the toolkit (which would scroll)
// see them. Called by main.odin's frame with the events of the frame; returns the others.
history_tree_events :: proc(app: ^App, events: []platform.Event) -> []platform.Event {
	clear(&tview.pending)
	t := current_tab(app)
	if t == nil || t.kind != .History || hview.mode != 1 || tview.built != active_window(app).ui.build_index || ui.ctx_menu_any_open() { return events }
	r := tview.view_rect
	focus := ui.focus_key()
	out := make([dynamic]platform.Event, 0, len(events), context.temp_allocator)
	for e in events {
		take := false
		#partial switch e.kind {
		case .Scroll:
			take = draw.rect_contains(r, e.pos)
		case .Key_Press:
			if e.mods == {.Ctrl} || e.mods == {.Ctrl, .Shift} {
				#partial switch e.key {
				case .Equal, .Num_Add, .Minus, .Num_Subtract, .N0: take = focus == 0 || focus == tview.view_key
				}
			}
		}
		if take { append(&tview.pending, e) } else { append(&out, e) }
	}
	return out[:]
}

////////////////////////////////
// Toolbar

// The layout switch of about:history's toolbar (history_ui.odin tree_toolbar).
history_tree_toolbar :: proc(app: ^App) {
	em := ui.font_size()
	ui.next({width = ui.px(em * 13), height = ui.px(ui.dense(em * 2))})
	sel := int(tcfg.layout)
	if ui.segmented("###h_tree_layout", []string{"Horizontal", "Vertical"}, &sel) { tree_set_layout(app, Tree_Layout(sel)) }
}

tree_set_layout :: proc(app: ^App, l: Tree_Layout) {
	if l == tcfg.layout { return }
	// (locked by a policy, the preference stays: the layout changes for this session only)
	_ = config.set_from_string(&app.prefs, "browser.history.tree_layout", l == .Vertical ? "vertical" : "horizontal", .User)
	tcfg.layout = l
	request_frames(app, 2)
}

////////////////////////////////
// The canvas

@(private = "file")
Node_Colors :: struct { bg, border, text, sub: draw.Color }

@(private = "file")
Tree_Draw :: struct {
	cam:          Tree_Camera,
	em:           f32,
	from, to:     Tree_Layout,
	t:            f32,            // eased layout transition (1: `to` only)
	face:         font.Font_Id,
	fonts:        ^font.State,
	kinds:        [3]Node_Colors, // current, on the path, a branch
	edge_strong, edge_weak, accent, hover_tint: draw.Color,
	hover:        u64,
	scale:        f32,
	rounding:     f32,
	icon_px:      f32,
	cached:       map[u64]bool,   // entries in the back/forward cache (frame memory)
}

// Where node `n` is drawn now (between the two layouts while they switch).
@(private = "file")
node_pos :: proc(d: ^Tree_Draw, n: Tree_Node) -> [2]f32 {
	b := tree_node_pos(d.to, n.col, n.row)
	if d.t >= 1 { return b }
	a := tree_node_pos(d.from, n.col, n.row)
	return a + (b - a) * d.t
}

@(private = "file")
snap :: proc(r: draw.Rect) -> draw.Rect { return {{math.round(r.min.x), math.round(r.min.y)}, {math.round(r.max.x), math.round(r.max.y)}} }

// `s` shortened with an ellipsis to fit `avail` pixels.
@(private = "file")
fit_text :: proc(fonts: ^font.State, id: font.Font_Id, size: f32, s: string, avail: f32) -> string {
	if avail <= 0 { return "" }
	if font.text_width(fonts, id, size, s) <= avail { return s }
	ell := "\u2026"
	x := font.text_width(fonts, id, size, ell)
	end := 0
	for r, i in s {
		w := font.glyph(fonts, id, size, r).advance
		if x + w > avail { break }
		x += w
		end = i + utf8.rune_size(r)
	}
	if end == 0 { return "" }
	return strings.concatenate({s[:end], ell}, context.temp_allocator)
}

@(private = "file")
tree_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Tree_Draw)(user)
	m := &tview.model
	if len(m.nodes) == 0 { return }
	view := b.rect
	vc := draw.rect_center(view)
	s := d.em * d.cam.zoom
	lo := cam_to_world(d.cam, vc, d.em, view.min)
	hi := cam_to_world(d.cam, vc, d.em, view.max)
	node := NODE_SIZE
	in_view :: proc(p, size, lo, hi: [2]f32) -> bool { return !(p.x > hi.x || p.y > hi.y || p.x + size.x < lo.x || p.y + size.y < lo.y) }
	detail := tree_detail(s)
	vertical := d.to == .Vertical

	// edges (under the nodes): an elbow from the parent's exit side to the child's entry side
	lw := max(1, math.round(d.scale * clamp(d.cam.zoom, 0.6, 1.6)))
	for n in m.nodes {
		if n.parent < 0 { continue }
		pn := m.nodes[n.parent]
		pa, pz := node_pos(d, pn), node_pos(d, n)
		lo2 := [2]f32{min(pa.x, pz.x), min(pa.y, pz.y)}
		hi2 := [2]f32{max(pa.x, pz.x), max(pa.y, pz.y)} + node
		if !in_view(lo2, hi2 - lo2, lo, hi) { continue }
		c := n.on_path && pn.on_path ? d.edge_strong : d.edge_weak
		w := n.on_path && pn.on_path ? lw * 1.5 : lw
		a, z: [2]f32
		if vertical {
			a = cam_to_screen(d.cam, vc, d.em, pa + {node.x * 0.5, node.y})
			z = cam_to_screen(d.cam, vc, d.em, pz + {node.x * 0.5, 0})
			a.x, z.x = math.round(a.x), math.round(z.x)
			mid := math.round(a.y + (z.y - a.y) * 0.5)
			if abs(a.x - z.x) < 0.5 {
				draw.rect(dc, {{a.x - w * 0.5, a.y}, {a.x + w * 0.5, z.y}}, c)
			} else {
				draw.rect(dc, {{a.x - w * 0.5, a.y}, {a.x + w * 0.5, mid + w * 0.5}}, c)
				draw.rect(dc, {{min(a.x, z.x) - w * 0.5, mid - w * 0.5}, {max(a.x, z.x) + w * 0.5, mid + w * 0.5}}, c)
				draw.rect(dc, {{z.x - w * 0.5, mid - w * 0.5}, {z.x + w * 0.5, z.y}}, c)
			}
		} else {
			a = cam_to_screen(d.cam, vc, d.em, pa + {node.x, node.y * 0.5})
			z = cam_to_screen(d.cam, vc, d.em, pz + {0, node.y * 0.5})
			a.y, z.y = math.round(a.y), math.round(z.y)
			mid := math.round(a.x + (z.x - a.x) * 0.5)
			if abs(a.y - z.y) < 0.5 {
				draw.rect(dc, {{a.x, a.y - w * 0.5}, {z.x, a.y + w * 0.5}}, c)
			} else {
				draw.rect(dc, {{a.x, a.y - w * 0.5}, {mid + w * 0.5, a.y + w * 0.5}}, c)
				draw.rect(dc, {{mid - w * 0.5, min(a.y, z.y) - w * 0.5}, {mid + w * 0.5, max(a.y, z.y) + w * 0.5}}, c)
				draw.rect(dc, {{mid - w * 0.5, z.y - w * 0.5}, {z.x, z.y + w * 0.5}}, c)
			}
		}
	}

	// nodes
	fs := text_size_step(s, d.em)
	fs2 := text_size_step(s * 0.8, d.em * 0.8)
	m1 := font.metrics(d.fonts, d.face, fs)
	m2 := font.metrics(d.fonts, d.face, fs2)
	radius := detail == .Block ? min(0.35 * s, 2 * d.scale) : 0.35 * s * d.rounding
	bw := max(1, math.round(d.scale))
	for n in m.nodes {
		p := node_pos(d, n)
		if !in_view(p, node, lo, hi) { continue }
		r := snap({cam_to_screen(d.cam, vc, d.em, p), cam_to_screen(d.cam, vc, d.em, p + node)})
		k := n.current ? 0 : n.on_path ? 1 : 2
		col := d.kinds[k]
		fade := k == 2
		if fade { draw.push_alpha(dc, 0.62) }
		hovered := n.id == d.hover
		if detail == .Block {
			draw.rect(dc, r, n.current ? d.accent : col.border, radius)
			if fade { draw.pop_alpha(dc) }
			continue
		}
		draw.rect(dc, r, col.bg, radius)
		if hovered { draw.rect(dc, r, d.hover_tint, radius) }
		draw.rect(dc, r, hovered ? d.accent : col.border, radius, hovered ? bw * 1.5 : bw)
		e := n.entry
		h := r.max.y - r.min.y
		icon := min(1.15 * s, d.icon_px * 2)
		x := r.min.x + 0.5 * s
		if detail == .Icon { x = r.min.x + (r.max.x - r.min.x) * 0.5 - icon * 0.5 }
		cy := r.min.y + h * 0.5
		if tex, ok := favicon_texture(e.icon); ok && e.icon != "" {
			draw.image(dc, tex, snap({{x, cy - icon * 0.5}, {x + icon, cy + icon * 0.5}}))
		} else {
			dot := icon * 0.42
			draw.rect(dc, {{x + icon * 0.5 - dot * 0.5, cy - dot * 0.5}, {x + icon * 0.5 + dot * 0.5, cy + dot * 0.5}}, col.sub, dot * 0.5)
		}
		if detail == .Icon { if fade { draw.pop_alpha(dc) }; continue }
		tx := x + icon + 0.4 * s
		avail := r.max.x - 0.45 * s - tx
		title := fit_text(d.fonts, d.face, fs, entry_label(e), avail)
		if detail == .Title {
			draw.text(dc, d.face, fs, {math.round(tx), math.round(cy + (m1.ascent - m1.descent) * 0.5)}, col.text, title)
		} else {
			top := r.min.y + (h - (m1.line_height + m2.line_height)) * 0.5
			draw.text(dc, d.face, fs, {math.round(tx), math.round(top + m1.ascent)}, col.text, title)
			lt := local_time(e.visited_ms != 0 ? e.visited_ms : e.created_ms)
			sub := fit_text(d.fonts, d.face, fs2, fmt.tprintf("%02d:%02d  \u00b7  %s", lt.hour, lt.minute, address_host(e.url)), avail)
			draw.text(dc, d.face, fs2, {math.round(tx), math.round(top + m1.line_height + m2.ascent)}, col.sub, sub)
		}
		if fade { draw.pop_alpha(dc) }
	}
}

@(private = "file")
now_unix_ms_tree :: proc() -> i64 { return time.time_to_unix_nano(time.now()) / 1e6 }

@(private = "file")
Minimap_Draw :: struct {
	layout:  Tree_Layout,
	k:       f32,             // minimap pixels per world unit
	origin:  [2]f32,          // where the tree's origin is, from the box's top-left
	view_lo, view_hi: [2]f32, // the view, in world units
	bg, border, branch, path, accent, frame_fill: draw.Color,
	radius:  f32,
	px:      f32,
}

// The tree in small: each lane's run of nodes one bar (a lane is consecutive in the model: tree_place continues a
// parent's lane with its first child), the view a rectangle.
@(private = "file")
minimap_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Minimap_Draw)(user)
	m := &tview.model
	r := b.rect
	draw.rect(dc, r, d.bg, d.radius)
	draw.rect(dc, r, d.border, d.radius, d.px)
	draw.push_clip(dc, draw.rect_pad(r, -d.px))
	o := r.min + d.origin
	node := NODE_SIZE * d.k
	run_start := -1
	flush :: proc(dc: ^draw.Context, d: ^Minimap_Draw, o, node: [2]f32, m: ^Tree_Model, from, to: int) {
		a := tree_node_pos(d.layout, m.nodes[from].col, m.nodes[from].row) * d.k + o
		z := tree_node_pos(d.layout, m.nodes[to].col, m.nodes[to].row) * d.k + o + node
		z = {max(z.x, a.x + 1), max(z.y, a.y + 1)}
		c := m.nodes[from].on_path ? d.path : d.branch
		draw.rect(dc, {a, z}, c)
	}
	for n, i in m.nodes {
		if run_start >= 0 {
			prev := m.nodes[i - 1]
			if n.row == prev.row && n.col == prev.col + 1 && n.on_path == prev.on_path { continue }
			flush(dc, d, o, node, m, run_start, i - 1)
		}
		run_start = i
	}
	if run_start >= 0 { flush(dc, d, o, node, m, run_start, len(m.nodes) - 1) }
	if m.current >= 0 {
		cn := m.nodes[m.current]
		a := tree_node_pos(d.layout, cn.col, cn.row) * d.k + o
		z := a + node
		pad := max(1.5 * d.px, 0)
		draw.rect(dc, {a - pad, {max(z.x, a.x + 1), max(z.y, a.y + 1)} + pad}, d.accent)
	}
	vr := draw.Rect{o + d.view_lo * d.k, o + d.view_hi * d.k}
	draw.rect(dc, vr, d.frame_fill)
	draw.rect(dc, snap(vr), d.accent, 0, d.px)
	draw.pop_clip(dc)
}

// about:history's tab tree part.
history_tree_view :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	st := active_window(app).ui
	now := st.frame_ms
	dt := f32(clamp((now - tview.last_ms) / 1000, 0, 0.1))
	tview.last_ms = now
	m := &tview.model
	tree_model_update(m, t)
	if !tview.layout_ok { tview.layout, tview.layout_from, tview.layout_t, tview.layout_ok = tcfg.layout, tcfg.layout, 1, true }
	anims := os_animations_enabled(app) && tcfg.transition_ms > 0

	if len(m.nodes) == 0 {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 4))})
		if ui.tags("weak") { if ui.style({text_align = .Center}) { ui.label("This tab has no history yet.###h_tree_none") } }
		return
	}

	ui.next({width = ui.fill(), height = ui.fill(), cursor = .Arrow})
	view := ui.build_box({.Clickable, .Focusable, .Clip}, "###h_tree")
	sig := ui.signal(view)
	// (history_tree_events runs before the next build: the index it sees then is this one)
	tview.view_key, tview.view_rect, tview.built = view.key, view.rect, st.build_index
	if ui.focus_key() == 0 { ui.set_focus(view.key) }   // the canvas has the keyboard unless something else took it
	rect := view.rect
	size := draw.rect_size(rect)
	vc := draw.rect_center(rect)
	busy := false

	// the layout wanted changed: the nodes slide over, the node nearest the view's center stays where it is
	if tcfg.layout != tview.layout {
		old := tview.layout
		if size.x > 0 && tview.cam_ok {
			best, best_d := -1, max(f32)
			for n, i in m.nodes {
				c := tree_node_pos(old, n.col, n.row) + NODE_SIZE * 0.5 - tview.cam.center
				dd := c.x * c.x + c.y * c.y
				if dd < best_d { best, best_d = i, dd }
			}
			if best >= 0 {
				n := m.nodes[best]
				off := tview.cam.center - tree_node_pos(old, n.col, n.row)
				to := Tree_Camera{tree_node_pos(tcfg.layout, n.col, n.row) + off, tview.cam.zoom}
				tree_go(to, anims, now)
			}
		}
		tview.layout_from, tview.layout = old, tcfg.layout
		tview.layout_start, tview.layout_t = now, anims ? 0 : 1
	}
	l := tview.layout
	extent := tree_extent(l, m.rows, m.cols)

	// the camera of this tab: kept from earlier in the session, else the current entry centered (the whole tree when it fits)
	if size.x > 1 && size.y > 1 && (!tview.cam_ok || tview.cam_tab != t.id) {
		if tview.cam_ok { tview.cams[tview.cam_tab] = {tview.going ? tview.go_to : tview.cam, l} }
		tview.going, tview.gliding, tview.drag = false, false, {}
		if sc, ok := tview.cams[t.id]; ok && sc.layout == l {
			tview.cam = sc.cam
		} else {
			tview.cam = tree_initial_camera(m, l, size, em)
		}
		tview.cam_ok, tview.cam_tab = true, t.id
		tview.revealed = m.current >= 0 ? m.nodes[m.current].id : 0
	}
	if !tview.cam_ok { request_frames(app, 2) }

	if tview.cam_ok {
		zstep := tcfg.zoom_step
		// wheel, touchpad, pinch, Ctrl+Plus / Minus / 0 (taken from the frame's events: history_tree_events)
		for e in tview.pending {
			#partial switch e.kind {
			case .Scroll:
				tview.going, tview.gliding = false, false
				if .Ctrl in e.mods {
					if e.delta.y != 0 { tview.cam = cam_zoom_at(tview.cam, vc, em, e.pos, clamp(tview.cam.zoom * math.pow(zstep, -e.delta.y), tcfg.zoom_min, tcfg.zoom_max)) }
				} else {
					dv := e.delta
					if .Shift in e.mods && dv.x == 0 { dv = {dv.y, 0} }
					tview.cam = cam_pan(tview.cam, em, -dv * wheel_step(app) * ui.scale())
				}
			case .Key_Press:
				#partial switch e.key {
				case .Equal, .Num_Add: tree_zoom_by(zstep, vc, em, anims, now)
				case .Minus, .Num_Subtract: tree_zoom_by(1 / zstep, vc, em, anims, now)
				case .N0: tree_zoom_by(1 / tree_target().zoom, vc, em, anims, now)
				}
			}
		}
		clear(&tview.pending)

		// keyboard (the canvas has the focus)
		if sig.focused && !ui.ctx_menu_any_open() {
			step := tcfg.key_step * ui.scale()
			move: [2]f32
			if ui.key_press(.Left) { move.x -= step }
			if ui.key_press(.Right) { move.x += step }
			if ui.key_press(.Up) { move.y -= step }
			if ui.key_press(.Down) { move.y += step }
			if ui.key_press(.Left, {.Shift}) { move.x -= step * 4 }
			if ui.key_press(.Right, {.Shift}) { move.x += step * 4 }
			if ui.key_press(.Up, {.Shift}) { move.y -= step * 4 }
			if ui.key_press(.Down, {.Shift}) { move.y += step * 4 }
			if ui.key_press(.Page_Up) { move.y -= size.y * 0.85 }
			if ui.key_press(.Page_Down) { move.y += size.y * 0.85 }
			if move != {} { tree_go(cam_pan(tree_target(), em, -move), anims, now, ms = min(tcfg.transition_ms, 140)) }
			if ui.key_press(.Equal) || ui.key_press(.Num_Add) || ui.key_press(.Equal, {.Shift}) { tree_zoom_by(zstep, vc, em, anims, now) }
			if ui.key_press(.Minus) || ui.key_press(.Num_Subtract) { tree_zoom_by(1 / zstep, vc, em, anims, now) }
			if ui.key_press(.N0) { tree_zoom_by(1 / tree_target().zoom, vc, em, anims, now) }
			if ui.key_press(.F) { tree_fit(extent, size, em, anims, now) }
			if ui.key_press(.C) || ui.key_press(.Home) { tree_center_current(m, l, anims, now) }
			if ui.key_press(.L) { tree_set_layout(app, l == .Horizontal ? .Vertical : .Horizontal) }
		}

		// pointer: a press on the canvas is a click until it moves past the threshold, then it drags the view
		threshold := tcfg.drag_threshold * ui.scale()
		mouse := ui.mouse_pos()
		for btn in ([]platform.Mouse_Button{.Left, .Middle}) {
			if st.pressed_key[btn] == view.key && !tview.drag.on {
				hit := tree_hit(m, l, tview.cam, vc, em, mouse)
				tview.drag = {on = true, button = btn, start = mouse, last = mouse, node = hit >= 0 ? m.nodes[hit].id : 0}
				tview.going, tview.gliding = false, false
			}
		}
		if tview.drag.on {
			dr := &tview.drag
			if st.active_key[dr.button] == view.key {
				if !dr.panning && drag_started(dr.start, mouse, threshold) { dr.panning = true }
				if dr.panning && mouse != dr.last {
					tview.cam = cam_pan(tview.cam, em, mouse - dr.last)
					dr.last = mouse
				}
				if dr.panning {
					dr.samples[dr.n % len(dr.samples)] = {f64(mouse.x), f64(mouse.y), now}
					dr.n += 1
				}
				busy = true
			} else {
				// released
				if !dr.panning && dr.node != 0 {
					if e := page.session_find(&t.session, dr.node); e != nil {
						if dr.button == .Left {
							tview.drag = {}
							tab_reveal(app, t)
							go_entry(app, t, e)
							return
						}
						open_in_new_tab(app, e.url, origin = .Replay)
						tview.drag = {}
						return
					}
				}
				if dr.panning && tcfg.inertia && anims { tree_glide_start(dr, now) }
				tview.drag = {}
			}
		}
		if sig.right_clicked {
			hit := tree_hit(m, l, tview.cam, vc, em, mouse)
			tview.menu_entry = hit >= 0 ? m.nodes[hit].id : 0
			ui.ctx_menu_open(ui.key_from_string(0, "###h_tree_menu"), mouse)
		}

		// the glide after a drag, the animated moves, the layout transition
		if tview.gliding {
			tview.cam = cam_pan(tview.cam, em, tview.vel * dt)
			tview.vel *= math.exp(-tcfg.friction * dt)
			if tview.vel.x * tview.vel.x + tview.vel.y * tview.vel.y < (20 * ui.scale()) * (20 * ui.scale()) { tview.gliding = false }
			busy = true
		}
		if tview.going {
			k := f32((now - tview.go_start) / max(tview.go_ms, 1))
			tview.cam = cam_lerp(tview.go_from, tview.go_to, ease_out(k))
			if k >= 1 { tview.going = false; tview.cam = tview.go_to }
			busy = true
		}
		if tview.layout_t < 1 {
			tview.layout_t = f32((now - tview.layout_start) / max(tcfg.transition_ms, 1))
			if tview.layout_t >= 1 { tview.layout_t = 1 }
			busy = true
		}

		// a new current entry (a click here, back / forward in that tab) comes into view
		if m.current >= 0 && m.nodes[m.current].id != tview.revealed && size.x > 0 && tview.layout_t >= 1 {
			n := m.nodes[m.current]
			p := tree_node_pos(l, n.col, n.row)
			tree_go(cam_reveal(tree_target(), size, em, p, p + NODE_SIZE, 1.5), anims, now)
			tview.revealed = n.id
		}
		if tview.layout_t >= 1 && !tview.going { tview.cam = cam_clamp(tview.cam, extent, tcfg.zoom_min, tcfg.zoom_max) }
		tview.cams[t.id] = {tree_target(), l}
	}

	// hover: the node under the pointer, its tooltip after a rest
	hover: u64
	if sig.hovering && !tview.drag.panning && tview.layout_t >= 1 && !tview.going {
		if hit := tree_hit(m, l, tview.cam, vc, em, ui.mouse_pos()); hit >= 0 { hover = m.nodes[hit].id }
	}
	if hover != tview.hover { tview.hover, tview.hover_ms = hover, now }
	// an open hand over the background (it can be dragged), a closed one while it is (a press on the background, or a
	// press on a node that went past the threshold), the pointing hand over a node (a click goes there)
	switch {
	case tview.drag.on && (tview.drag.panning || tview.drag.node == 0): st.cursor_request = .Grabbing
	case tview.drag.on:                                                  st.cursor_request = .Hand
	case hover != 0:                                                     st.cursor_request = .Hand
	case sig.hovering:                                                   st.cursor_request = .Grab
	}

	// what the canvas draws (its custom draw runs after the layout, with this frame's rectangle)
	d := ui.frame_new(Tree_Draw)
	d.cam, d.em, d.from, d.to, d.t = tview.cam, em, tview.layout_from, tview.layout, ease_out(tview.layout_t)
	d.face, d.fonts = app.ui_font, &app.fonts
	tag_colors :: proc(tag: string, out: ^Node_Colors) {
		if ui.tags(tag) {
			out.bg, out.border, out.text = ui.color("background"), ui.color("border"), ui.color("text")
			if ui.tags("weak") { out.sub = ui.color("text") }
		}
	}
	tag_colors("selected", &d.kinds[0])
	tag_colors("button", &d.kinds[1])
	tag_colors("card", &d.kinds[2])
	d.edge_strong = ui.color("text")
	d.edge_strong.a *= 0.7
	d.edge_weak = ui.color("border")
	d.accent = ui.color("accent")
	d.hover_tint = d.accent
	d.hover_tint.a = 0.10
	d.hover_tint = ui.tuned(d.hover_tint)
	d.hover = hover
	d.scale = ui.scale()
	d.rounding = st.rounding
	d.icon_px = f32(tab_icon_px(app))
	if tview.cam_ok { view.custom, view.custom_user = tree_draw, d }   // (no camera before the view has a size)

	if ui.parent(view) {
		tree_controls(m, l, extent, size, em, anims, now)
		if tcfg.minimap { tree_minimap(app, m, l, extent, size, em) }
	}
	tree_menu(app, t)
	tree_tooltip(app, t, m, now)
	if busy { request_frames(app, 2) }
}

// Height the canvas's controls take along its bottom edge (with their margins).
@(private = "file")
tree_overlay_px :: proc(em: f32) -> f32 { return ui.dense(em * 2.2) + em * 1.6 }

// "Fit": the whole tree as large as the view allows, clear of the controls in its corner (tree_controls records where
// they were last laid out; before that, where they will be).
@(private = "file")
tree_fit_camera :: proc(extent, size: [2]f32, em: f32) -> (Tree_Camera, f32) {
	under := tview.controls
	if under.max.x <= under.min.x {
		h := ui.dense(em * 2.2)
		under = {{em * 0.8, size.y - h - em * 0.8}, {em * 17, size.y - em * 0.8}}
	}
	return cam_fit_clear(extent, size, em, em, under, tcfg.zoom_min, tcfg.fit_max)
}

@(private = "file")
tree_initial_camera :: proc(m: ^Tree_Model, l: Tree_Layout, size: [2]f32, em: f32) -> Tree_Camera {
	extent := tree_extent(l, m.rows, m.cols)
	fit, need := tree_fit_camera(extent, size, em)
	if need >= min(1, tcfg.fit_max) { return fit }
	c := Tree_Camera{extent * 0.5, clamp(1, tcfg.zoom_min, tcfg.zoom_max)}
	if m.current >= 0 {
		n := m.nodes[m.current]
		c.center = tree_node_pos(l, n.col, n.row) + NODE_SIZE * 0.5
	}
	// (the current entry is often the last one: the rest of the tree fills the view rather than empty space; the
	// controls and the minimap along the bottom cover none of it)
	under := tree_overlay_px(em) / (em * c.zoom)
	return cam_contain(c, extent, size, em, {1.2, 1.2}, {1.2, 1.2 + under})
}

// Where the camera is going (the end of the move in progress, else where it is).
@(private = "file")
tree_target :: proc() -> Tree_Camera { return tview.going ? tview.go_to : tview.cam }

// Moves the camera to `to` from where it is now, animated unless animations are off.
@(private = "file")
tree_go :: proc(to: Tree_Camera, anims: bool, now: f64, ms := -1.0) {
	tview.gliding = false
	if !anims {
		tview.cam, tview.going = to, false
		return
	}
	tview.go_from, tview.go_to, tview.go_start = tview.cam, to, now
	tview.go_ms = ms >= 0 ? ms : tcfg.transition_ms
	tview.going = true
}

@(private = "file")
tree_zoom_by :: proc(f: f32, vc: [2]f32, em: f32, anims: bool, now: f64) {
	target := tree_target()
	z := clamp(target.zoom * f, tcfg.zoom_min, tcfg.zoom_max)
	tree_go(cam_zoom_at(target, vc, em, vc, z), anims, now)
}

@(private = "file")
tree_fit :: proc(extent, size: [2]f32, em: f32, anims: bool, now: f64) {
	if size.x <= 0 { return }
	fit, _ := tree_fit_camera(extent, size, em)
	tree_go(fit, anims, now)
}

@(private = "file")
tree_center_current :: proc(m: ^Tree_Model, l: Tree_Layout, anims: bool, now: f64) {
	if m.current < 0 { return }
	n := m.nodes[m.current]
	target := tree_target()
	z := max(target.zoom, min(1, tcfg.zoom_max))   // (readable: at least the interface's size)
	tree_go({tree_node_pos(l, n.col, n.row) + NODE_SIZE * 0.5, z}, anims, now)
}

// The speed of the last moves of a drag (those of the last 80 ms) starts the glide; a pointer that stopped before
// being let go does not glide.
@(private = "file")
tree_glide_start :: proc(dr: ^Drag, now: f64) {
	count := min(dr.n, len(dr.samples))
	if count < 2 { return }
	last := dr.samples[(dr.n - 1) % len(dr.samples)]
	if now - last[2] > 60 { return }
	first := last
	for i in 1 ..< count {
		s := dr.samples[(dr.n - 1 - i) % len(dr.samples)]
		if last[2] - s[2] > 80 { break }
		first = s
	}
	span := (last[2] - first[2]) / 1000
	if span <= 0.004 { return }
	tview.vel = {f32((last[0] - first[0]) / span), f32((last[1] - first[1]) / span)}
	tview.gliding = true
}

// The node under the screen point `p` (-1: none).
@(private = "file")
tree_hit :: proc(m: ^Tree_Model, l: Tree_Layout, cam: Tree_Camera, vc: [2]f32, em: f32, p: [2]f32) -> int {
	w := cam_to_world(cam, vc, em, p)
	for n, i in m.nodes {
		a := tree_node_pos(l, n.col, n.row)
		if w.x >= a.x && w.y >= a.y && w.x < a.x + NODE_SIZE.x && w.y < a.y + NODE_SIZE.y { return i }
	}
	return -1
}

// "−  100 %  +   Fit   Current" over the canvas's bottom-left corner.
@(private = "file")
tree_controls :: proc(m: ^Tree_Model, l: Tree_Layout, extent, size: [2]f32, em: f32, anims: bool, now: f64) {
	h := ui.dense(em * 2.2)
	bh := ui.dense(em * 1.7)
	pad := em * 0.25
	ui.next({fixed_x = em * 0.8, fixed_y = max(size.y - h - em * 0.8, 0), width = ui.children_sum(), height = ui.px(h), axis = .X, cross = .Center, radius = em * CHROME_BUTTON_RADIUS})
	if ui.tags("card") {
		bar := ui.build_box({.Draw_Background, .Draw_Border}, "###h_tree_controls")
		// (its rectangle of the last layout, in the view: what "Fit" keeps the tree clear of)
		if bar.rect.max.x > bar.rect.min.x { tview.controls = {bar.rect.min - tview.view_rect.min, bar.rect.max - tview.view_rect.min} }
		if ui.parent(bar) {
			vc := size * 0.5 + tview.view_rect.min
			ui.spacer(ui.px(pad))
			ui.next({width = ui.px(em * 2), height = ui.px(bh), radius = em * CHROME_BUTTON_RADIUS})
			b := ui.button("\u2212###h_tree_zout")
			tip(b, "Zoom out (Ctrl+Minus, Ctrl+wheel)")
			if b.clicked { tree_zoom_by(1 / tcfg.zoom_step, vc, em, anims, now) }
			ui.next({width = ui.px(em * 4), height = ui.px(bh), radius = em * CHROME_BUTTON_RADIUS})
			b = ui.button(fmt.tprintf("%d %%###h_tree_zpct", int(tree_target().zoom * 100 + 0.5)))
			tip(b, "Actual size (Ctrl+0)")
			if b.clicked { tree_zoom_by(1 / tree_target().zoom, vc, em, anims, now) }
			ui.next({width = ui.px(em * 2), height = ui.px(bh), radius = em * CHROME_BUTTON_RADIUS})
			b = ui.button("+###h_tree_zin")
			tip(b, "Zoom in (Ctrl+Plus, Ctrl+wheel)")
			if b.clicked { tree_zoom_by(tcfg.zoom_step, vc, em, anims, now) }
			ui.spacer(ui.px(pad * 2))
			ui.next({width = ui.text_size(em * 0.5), height = ui.px(bh), radius = em * CHROME_BUTTON_RADIUS})
			b = ui.button("Fit###h_tree_fit")
			tip(b, "Show the whole tree (F)")
			if b.clicked { tree_fit(extent, size, em, anims, now) }
			ui.next({width = ui.text_size(em * 0.5), height = ui.px(bh), radius = em * CHROME_BUTTON_RADIUS})
			b = ui.button("Current###h_tree_cur")
			tip(b, "Center the current page of the tab (C)")
			if b.clicked { tree_center_current(m, l, anims, now) }
			ui.spacer(ui.px(pad))
		}
	}
}

// The minimap, in the bottom-right corner while the tree is larger than the view.
@(private = "file")
tree_minimap :: proc(app: ^App, m: ^Tree_Model, l: Tree_Layout, extent, size: [2]f32, em: f32) {
	wnd := active_window(app)
	if len(m.nodes) < 2 || size.x <= 0 || extent.x <= 0 || extent.y <= 0 { return }
	s := em * tview.cam.zoom
	if extent.x * s <= size.x && extent.y * s <= size.y { return }
	limit := [2]f32{min(em * 13, size.x * 0.3), min(em * 8.5, size.y * 0.3)}
	if limit.x < em * 4 || limit.y < em * 2.5 { return }
	k := min(limit.x / extent.x, limit.y / extent.y)
	pad := em * 0.4
	inner := [2]f32{max(extent.x * k, em * 3), max(extent.y * k, em * 1.2)}
	box := inner + pad * 2
	pos := size - box - em * 0.8
	d := ui.frame_new(Minimap_Draw)
	d.layout, d.k = l, k
	d.origin = pad + (inner - extent * k) * 0.5
	vc := size * 0.5
	d.view_lo, d.view_hi = cam_to_world(tview.cam, vc, em, {0, 0}), cam_to_world(tview.cam, vc, em, size)
	if ui.tags("card") { d.bg, d.border = ui.color("background"), ui.color("border") }
	d.branch = ui.color("border")
	if ui.tags("weak") { d.path = ui.color("text") }
	d.accent = ui.color("accent")
	d.frame_fill = d.accent
	d.frame_fill.a = 0.12
	d.frame_fill = ui.tuned(d.frame_fill)
	d.radius = em * CHROME_BUTTON_RADIUS * wnd.ui.rounding
	d.px = max(1, math.round(ui.scale()))
	ui.next({fixed_x = pos.x, fixed_y = pos.y, width = ui.px(box.x), height = ui.px(box.y), cursor = .Hand})
	mb := ui.custom("###h_tree_minimap", minimap_draw, d, {.Clickable})
	sig := ui.signal(mb)
	if sig.pressed || sig.dragging {
		w := (sig.mouse - d.origin) / k
		tview.going, tview.gliding = false, false
		tview.cam.center = w
		tview.cam = cam_clamp(tview.cam, extent, tcfg.zoom_min, tcfg.zoom_max)
		request_frames(app, 2)
	}
	// (a click moves the view there, a drag carries it)
	if sig.dragging { wnd.ui.cursor_request = .Grabbing } else if sig.hovering { wnd.ui.cursor_request = .Hand }
}

@(private = "file")
tree_menu :: proc(app: ^App, t: ^Tab) {
	if ui.ctx_menu(ui.key_from_string(0, "###h_tree_menu")) { tree_menu_items(app, t) }
}

@(private = "file")
tree_menu_items :: proc(app: ^App, t: ^Tab) {
	m := &tview.model
	em := ui.font_size()
	size := draw.rect_size(tview.view_rect)
	anims := os_animations_enabled(app) && tcfg.transition_ms > 0
	now := active_window(app).ui.frame_ms
	l := tview.layout
	if tview.menu_entry != 0 {
		e := page.session_find(&t.session, tview.menu_entry)
		if e == nil { ui.ctx_menu_close(); return }
		address := strings.clone(e.url, context.temp_allocator)
		if ui.menu_item("Go to this page", enabled = e != page.session_current(&t.session)).clicked {
			ui.ctx_menu_close()
			tab_reveal(app, t)
			go_entry(app, t, e)
			return
		}
		if ui.menu_item("Open in a new tab", "Middle click").clicked { ui.ctx_menu_close(); open_in_new_tab(app, address, origin = .Replay); return }
		if ui.menu_item("Copy address", icon = GLYPH_COPY).clicked { clip_set(address); ui.ctx_menu_close() }
		ui.menu_separator()
		holds_current := false
		for a := page.session_current(&t.session); a != nil; a = a.parent { if a == e { holds_current = true } }
		if ui.menu_item("Forget this branch", enabled = !holds_current).clicked {
			ids := page.session_forget(&t.session, e)
			for id in ids { bfcache_forget(t, id) }
			sync_history(t)
			ui.ctx_menu_close()
		}
		return
	}
	extent := tree_extent(l, m.rows, m.cols)
	if ui.menu_item("Fit the whole tree", "F").clicked { tree_fit(extent, size, em, anims, now); ui.ctx_menu_close() }
	if ui.menu_item("Center the current page", "C").clicked { tree_center_current(m, l, anims, now); ui.ctx_menu_close() }
	if ui.menu_item("Actual size", "Ctrl+0").clicked { tree_zoom_by(1 / tree_target().zoom, tview.view_rect.min + size * 0.5, em, anims, now); ui.ctx_menu_close() }
	ui.menu_separator()
	if ui.menu_item("Horizontal layout", "L", checked = tcfg.layout == .Horizontal).clicked { tree_set_layout(app, .Horizontal); ui.ctx_menu_close() }
	if ui.menu_item("Vertical layout", "L", checked = tcfg.layout == .Vertical).clicked { tree_set_layout(app, .Vertical); ui.ctx_menu_close() }
	if ui.menu_item("Minimap", checked = tcfg.minimap).clicked {
		if config.set_from_string(&app.prefs, "browser.history.tree_minimap", tcfg.minimap ? "false" : "true", .User) != .None { tcfg.minimap = !tcfg.minimap }
		ui.ctx_menu_close()
	}
}

@(private = "file")
tree_tooltip :: proc(app: ^App, t: ^Tab, m: ^Tree_Model, now: f64) {
	if tview.hover == 0 || ui.ctx_menu_any_open() { return }
	waited := now - tview.hover_ms
	if waited < tcfg.tooltip_ms {
		active_window(app).ui.wake_ms = max(1, int(tcfg.tooltip_ms - waited) + 5)
		return
	}
	e := page.session_find(&t.session, tview.hover)
	if e == nil { return }
	em := ui.font_size()
	if ui.tooltip() {
		ui.next({width = ui.text_size(em * 0.7), height = ui.px(ui.dense(em * 1.8))})
		ui.label(fmt.tprintf("%s###h_tt_title", safe_label(entry_label(e), 120)))
		if ui.tags("weak") {
			ui.next({width = ui.text_size(em * 0.7), height = ui.px(ui.dense(em * 1.5))})
			ui.label(fmt.tprintf("%s###h_tt_url", safe_label(e.url, 140)))
			at := e.visited_ms != 0 ? e.visited_ms : e.created_ms
			nowl := now_unix_ms_tree()
			tl := local_time(nowl)
			yl := local_time(local_midnight(nowl) - 1000)
			lt := local_time(at)
			when_ := fmt.tprintf("Visited %s, %02d:%02d", day_heading(lt, tl.year * 10000 + tl.month * 100 + tl.day, yl.year * 10000 + yl.month * 100 + yl.day), lt.hour, lt.minute)
			if bfcache_has(t, e.id) { when_ = fmt.tprintf("%s  \u00b7  kept in the back/forward cache", when_) }
			ui.next({width = ui.text_size(em * 0.7), height = ui.px(ui.dense(em * 1.5))})
			ui.label(fmt.tprintf("%s###h_tt_when", when_))
		}
		ui.spacer(ui.px(em * 0.2))
	}
	_ = m
}

