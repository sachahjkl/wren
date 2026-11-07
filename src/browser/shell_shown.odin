package browser

// What a chrome frame shows of a busy page over the layout of its last frame (shell_frames.odin shell_paint_layout), besides
// the document's scroll and a drag's selection:
//   * CSS animations and transitions of transform and opacity go on without the page: their values at the chrome frame's time
//     are taken from the page's timeline without moving it (style.timeline_compositor_values: the keyframes the page resolved,
//     the clock its ticks follow) and set as the matrix of the box's transform space and the alpha of its opacity group, which
//     the compositor applies to its pictures (nothing is recorded again). At the page's turn its own tick reaches the same
//     instant on the same clock: no jump. Only where the last layout has that space or group (an opacity that was 1 has no
//     group: it waits for the page), not for a box in a 3D plane, not for an element a script animates;
//   * a scroll container scrolled by the wheel or the thumb of its bar (Shell_Frames.boxes) shows at that offset; the layout
//     takes it at the page's turn (shell_frames.odin shell_take_scroll), whose frame fires its scroll event as for any scroll;
//   * the focused field's caret blinks by the clock (forms_shell.odin caret_phase);
//   * a scroll-driven animation stands at the offset its scroller is shown at (style.Shown_Offset), whatever it changes;
//   * colours, shadows, radii, filters, clip-paths (style.RECORD_PROPS) are written in the style record the box and its items hold, an
//     overlay of the timeline's (Compositor_Value.record), and the compositor records the chunks they are in again; descendants that
//     inherit such a value get it the same way;
//   * values that change the layout (width, height, font-size...), when a whole pass of this page is cheap enough
//     (browser.shell.shown_layout_max_ms): written in the records as well, and laid out in a whole pass over a layout of the tab's own
//     (Tab.shown, shell_shown_layout), never the one scripts read. The display items of that pass hold strings of the document as the
//     tab's do: it only runs, and is only painted, while nothing changed since the tab's was painted (shell_layout_paintable).
// These values are set on the layout for one use (a paint, a hit test) and put back at once (Shown): nothing of the page runs
// meanwhile, and what its scripts read stays what their turn left (getComputedStyle, getAnimations, scrollTop, the boxes).

import "base:runtime"
import "core:time"
import "toolkit:draw"
import "wb:base"
import "wb:config"
import lay "wb:layout"
import "wb:page"
import "wb:style"

// A scroll container of a busy page shown at an offset (device px, within its range in the last layout).
Box_Scroll :: struct {
	node: base.Handle,
	to:   draw.Vec2,
}

// What the layout had where a chrome frame set what it shows (shell_shown_set), to put back (shell_shown_put).
Shown :: struct {
	t:       ^Tab,
	set:     bool,
	scroll:  f32,   // the tab's scroll (hit tests read it: the document is shown at shell_shown_scroll)
	mats:    [dynamic]Shown_Mat,
	alphas:  [dynamic]Shown_Alpha,
	scrolls: [dynamic]Shown_Scroll,
	records: [dynamic]Shown_Record,
	radii:   [dynamic]Shown_Radii,
	relayout: bool,   // the values set change the layout: painted from a pass of its own (shell_shown_layout)
}

// The layout a chrome frame paints when it shows animated layout values (Tab.shown).
Shown_Layout :: struct {
	layout: Layout,
	page:   ^page.Page,   // the page it was last made for
	ms:     f64,          // how long that pass took
}

SHELL_SHOWN_PREFS := [?]config.Def{
	{name = "browser.shell.shown_layout_max_ms", kind = .Float, default = {f = 4}, bounded = true, min = 0, max = 100, unit = "ms",
		description = "While a page keeps the interface thread busy, its animations of layout properties (width, height, font-size...) go on when a whole layout of the page takes less than this: it is made in each interface frame, on a copy, without touching what scripts read. 0: they wait for the page."},
}

register_shell_shown_prefs :: proc(p: ^config.Prefs) { config.register(p, SHELL_SHOWN_PREFS[:]) }

Shown_Mat :: struct { space: i32, mat: lay.Matrix }
Shown_Alpha :: struct { group: i32, alpha: f32 }
Shown_Scroll :: struct { node: base.Handle, off: draw.Vec2, had: bool }
Shown_Record :: struct { record: ^style.Computed, was: style.Computed }
Shown_Radii :: struct { clip: i32, radii: [4]f32 }

// Sets on the tab's layout what the chrome frame shows (its animations at the frame's time, the containers scrolled); the
// caller puts it back with shell_shown_put before anything of the page can run. Nothing is set when the layout cannot be read
// (the page thread has it).
shell_shown_set :: proc(app: ^App, t: ^Tab, painting := false) -> (sh: Shown) {
	sh.t = t
	l := &t.layout
	if app.chrome_frames.page_work == .Layout || t.page == nil || !l.valid { return }
	sh.set = true
	sh.scroll = t.scroll
	sh.mats = make([dynamic]Shown_Mat, context.temp_allocator)
	sh.alphas = make([dynamic]Shown_Alpha, context.temp_allocator)
	sh.scrolls = make([dynamic]Shown_Scroll, context.temp_allocator)
	sh.records = make([dynamic]Shown_Record, context.temp_allocator)
	sh.radii = make([dynamic]Shown_Radii, context.temp_allocator)
	vals := make([dynamic]style.Compositor_Value, context.temp_allocator)
	shell_animated(app, t, painting && shell_shown_lays_out(app, t), &vals)
	t.scroll = shell_shown_scroll(t).y   // (after those: what the chrome frames scrolled is added to the tab's offset, once)
	for v in vals { if style.compositor_lays_out(v.props) { sh.relayout = true } }
	for v in vals {
		if sh.relayout {
			if v.record != nil {
				append(&sh.records, Shown_Record{v.record, v.record^})
				v.record^ = v.cs^
			}
			continue
		}
		bi := lay.box_index(l, v.node)
		if bi == lay.NONE || .Foreign in l.boxes[bi].flags { continue }
		records := style.compositor_record_props(v.props)
		if !style.ps_empty(records) && v.record != nil {
			append(&sh.records, Shown_Record{v.record, v.record^})
			v.record^ = v.cs^
			shell_shown_radii(&sh, l, bi)
		}
		moves := style.compositor_moves(v.props)
		if !style.ps_empty(moves) {
			for &sp, i in l.spaces {
				if sp.kind != .Transform || sp.box != bi || sp.proj { continue }
				append(&sh.mats, Shown_Mat{i32(i), sp.mat})
				sp.mat = lay.box_matrix_of(l, &l.boxes[bi], v.cs)
			}
		}
		if style.ps_has(v.props, .Opacity) {
			for &g, i in l.groups {
				if g.box != bi || .Opacity not_in g.effects { continue }
				append(&sh.alphas, Shown_Alpha{i32(i), g.alpha})
				g.alpha = max(v.cs.opacity, 0)
			}
		}
	}
	if len(sh.records) > 0 { l.passes[.Refresh] += 1 }   // (the compositor looks at the paint values of its pictures again, and again once they are put back)
	if app.chrome_frames.pending_tab == t.id {
		for b in app.chrome_frames.boxes {
			off, had := l.scroll[b.node]
			append(&sh.scrolls, Shown_Scroll{b.node, off, had})
			l.scroll[b.node] = b.to
		}
	}
	return
}

// A chrome frame may lay out what its animations change: a whole pass of the page is cheap enough to pay in a frame, and it has not been too long lately.
@(private = "file")
shell_shown_lays_out :: proc(app: ^App, t: ^Tab) -> bool {
	limit := config.float_of(&app.prefs, "browser.shell.shown_layout_max_ms")
	if limit <= 0 || t.full_layout_ms <= 0 || t.full_layout_ms > limit { return false }
	return t.shown.page != t.page || t.shown.ms <= limit
}

// The layout to paint: the tab's, or when values that lay out are set (Shown.relayout) a whole pass over its own layout from the same document and styles
// (shell_shown_set wrote those values in the records of their boxes for this paint). What it reads is the tab's: nothing changed since it
// was painted (shell_layout_paintable: the document's strings are those the tab's layout holds). Nothing of it outlives the paint.
shell_shown_layout :: proc(app: ^App, t: ^Tab, sh: ^Shown, size: draw.Vec2) -> ^lay.Layout {
	if !sh.relayout { return &t.layout }
	t0 := time.tick_now()
	s := &t.shown
	s.page = t.page
	clear(&s.layout.scroll)
	for node, off in t.layout.scroll { s.layout.scroll[node] = off }
	lay.set_doc_scroll_x(&s.layout, t.layout.doc_scroll_x)
	input := layout_input(t.page.doc, t.page.styled, &app.measure, &app.page_settings.style, size, page_scale(app), app.cfg.layout_band_px, t.image_sizes, u64(t.web_fonts))
	lay.run_shown(&s.layout, input)
	s.ms = time.duration_milliseconds(time.tick_since(t0))
	return &s.layout
}

// The clips of a box whose record changed for this paint take its radii.
@(private = "file")
shell_shown_radii :: proc(sh: ^Shown, l: ^lay.Layout, bi: i32) {
	for &cl, i in l.clips {
		if cl.box != bi { continue }
		append(&sh.radii, Shown_Radii{i32(i), cl.radii})
		cl.radii = lay.clip_radii(l, &l.boxes[bi])
	}
}

// The layout as the page's turn left it.
shell_shown_put :: proc(sh: ^Shown) {
	if !sh.set { return }
	l := &sh.t.layout
	sh.t.scroll = sh.scroll
	for m in sh.mats { l.spaces[m.space].mat = m.mat }
	for a in sh.alphas { l.groups[a.group].alpha = a.alpha }
	for r in sh.records { r.record^ = r.was }
	for r in sh.radii { l.clips[r.clip].radii = r.radii }
	if len(sh.records) > 0 { l.passes[.Refresh] += 1 }
	for s in sh.scrolls {
		if s.had { l.scroll[s.node] = s.off } else { delete_key(&l.scroll, s.node) }
	}
	sh.set = false
}

// The chrome frame has something of its own to show of the tab's page over its last layout: an animation the compositor runs,
// a container it scrolled, a blinking caret. `moving`: it changes by itself (the next chrome frame shows something new).
shell_shown_wanted :: proc(app: ^App, t: ^Tab) -> (wanted, moving: bool) {
	if t.page == nil || app.chrome_frames.page_work == .Layout { return }
	tmp := runtime.default_temp_allocator_temp_begin()   // (also asked between two instructions of the guest: shell_preempt)
	defer runtime.default_temp_allocator_temp_end(tmp)
	any: bool
	moving, any = shell_animated(app, t, shell_shown_lays_out(app, t), nil)
	wanted = any || (app.chrome_frames.pending_tab == t.id && len(app.chrome_frames.boxes) > 0)
	if f := t.page.formctl != nil ? page.page_forms(t.page) : nil; f != nil {
		if on, caret, period := caret_phase(app, f); caret && period > 0 {
			wanted = true
			if on != forms_view(app).blink_on { moving = true }   // (a toggle the screen does not show yet)
		}
	}
	return
}

// The values at the chrome frame's time of the page's animations the compositor runs (none while a style pass's threads write the
// styles they are read from). True: one moves at every frame.
@(private = "file")
shell_animated :: proc(app: ^App, t: ^Tab, lays_out: bool, out: ^[dynamic]style.Compositor_Value) -> (moving, any: bool) {
	if app.chrome_frames.page_work == .Styles { return }
	return page.animations_compositor_values(t.page, busy_clock_wall(app, t.page), shell_shown_offsets(app, t), lays_out, out)
}

// Where this frame shows the scrollers it moved (CSS px), for the animations those drive.
@(private = "file")
shell_shown_offsets :: proc(app: ^App, t: ^Tab) -> []style.Shown_Offset {
	if app.chrome_frames.pending_tab != t.id { return nil }
	scale := f64(page_scale(app))
	out := make([dynamic]style.Shown_Offset, 0, len(app.chrome_frames.boxes) + 1, context.temp_allocator)
	if app.chrome_frames.pending_scroll != {} {
		doc := shell_shown_scroll(t)
		append(&out, style.Shown_Offset{base.NIL_HANDLE, {f64(doc.x) / scale, f64(doc.y) / scale}})
	}
	for b in app.chrome_frames.boxes { append(&out, style.Shown_Offset{b.node, {f64(b.to.x) / scale, f64(b.to.y) / scale}}) }
	return out[:]
}

// A chrome frame painting the page from its layout: the caret as the clock has it (the shell's own state: the next full frame
// sets it again).
shell_shown_caret :: proc(app: ^App, t: ^Tab) {
	f := t.page != nil && t.page.formctl != nil ? page.page_forms(t.page) : nil
	if f == nil { return }
	if on, caret, _ := caret_phase(app, f); caret { forms_view(app).blink_on = on }
}

// Where a container of the tab's page is shown (its offset in the layout, or the one a chrome frame gave it).
shell_box_shown :: proc(app: ^App, t: ^Tab, node: base.Handle) -> draw.Vec2 {
	if app.chrome_frames.pending_tab == t.id {
		for b in app.chrome_frames.boxes { if b.node == node { return b.to } }
	}
	off, _ := lay.scroll_of(&t.layout, node)
	return off
}

// A container of a busy page shown at `to` (clamped to its range in the last layout), and scrolled there at the page's turn.
shell_box_scroll_to :: proc(app: ^App, t: ^Tab, node: base.Handle, to: draw.Vec2) {
	shell_pending_for(app, t)
	hi, ok := lay.scroll_max(&t.layout, node)
	if !ok { return }
	lo := lay.scroll_min(&t.layout, node)
	v := draw.Vec2{clamp(to.x, lo.x, hi.x), clamp(to.y, lo.y, hi.y)}
	for &b in app.chrome_frames.boxes {
		if b.node == node { b.to = v; return }
	}
	append(&app.chrome_frames.boxes, Box_Scroll{node, v})
}

// A busy page moved by `d` device px from container `node` out (NIL: the document), as scroll_chain_by: what a container has no room
// for goes to those around it, then to the document. A container waits when the page cannot be painted from its layout.
shell_chain_by :: proc(app: ^App, t: ^Tab, node: base.Handle, d: draw.Vec2) {
	rest := d
	if node != base.NIL_HANDLE {
		if !shell_layout_paintable(app, t) { return }
		l := &t.layout
		if bi := lay.box_index(l, node); bi != lay.NONE {
			for sp := l.boxes[bi].scroll_space; sp != lay.NONE && rest != {}; sp = l.spaces[sp].parent {
				if l.spaces[sp].kind != .Scroll { continue }
				box := l.boxes[l.spaces[sp].box].node
				from := shell_box_shown(app, t, box)
				shell_box_scroll_to(app, t, box, from + rest)
				rest -= shell_box_shown(app, t, box) - from
			}
		}
	}
	if rest != {} { shell_async_scroll_to(app, t, shell_shown_scroll(t) + rest) }
}

// The wheel over a busy page at `p` (page-area px), `d` device px: the container under the pointer that can still move that
// way takes it (shown at once when the page can be painted from its layout, else it waits for the page), else the document.
// False: the document's.
shell_wheel_box :: proc(app: ^App, t: ^Tab, p, d: draw.Vec2) -> (taken, wait: bool) {
	if app.chrome_frames.page_work == .Layout || !t.layout.valid { return false, false }
	sh := shell_shown_set(app, t)
	node := wheel_scroller(app, t, p, d)
	shell_shown_put(&sh)
	if node == base.NIL_HANDLE { return false, false }
	if !shell_layout_paintable(app, t) { return true, true }
	shell_box_scroll_to(app, t, node, shell_box_shown(app, t, node) + d)
	return true, false
}

// A press on the thumb of a container's bar of a busy page that can be painted from its layout: the drag is the shell's, as
// in a full frame (the gesture's owner is Thumb: a frame of the other kind goes on with it).
shell_box_bar_press :: proc(app: ^App, t: ^Tab, p: draw.Vec2) -> bool {
	if !shell_layout_paintable(app, t) { return false }
	sh := shell_shown_set(app, t)
	hit, ok := scrollbar_at(app, t, p)
	shell_shown_put(&sh)
	if !ok || hit.node == base.NIL_HANDLE || hit.limit <= hit.lo { return false }
	ax := hit.vertical ? 1 : 0
	if p[ax] < hit.thumb.min[ax] || p[ax] >= hit.thumb.max[ax] { return false }   // (the track and the arrows: the page's turn)
	gesture_take(app, t, .Thumb, .Left).thumb = Scrollbar_Drag{node = hit.node, vertical = hit.vertical, grab = p[ax] - hit.thumb.min[ax],
		track_min = hit.rail.min[ax], travel = (hit.rail.max[ax] - hit.rail.min[ax]) - (hit.thumb.max[ax] - hit.thumb.min[ax]), lo = hit.lo, limit = hit.limit}
	bar_over_set(app, {&t.layout, hit.node, hit.vertical, {.Thumb, true}})
	return true
}
