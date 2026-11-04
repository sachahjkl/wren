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
//   * the focused field's caret blinks by the clock (forms_shell.odin caret_phase).
// These values are set on the layout for one use (a paint, a hit test) and put back at once (Shown): nothing of the page runs
// meanwhile, and what its scripts read stays what their turn left (getComputedStyle, getAnimations, scrollTop, the boxes).

import "base:runtime"
import "toolkit:draw"
import "wb:base"
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
}

Shown_Mat :: struct { space: i32, mat: lay.Matrix }
Shown_Alpha :: struct { group: i32, alpha: f32 }
Shown_Scroll :: struct { node: base.Handle, off: draw.Vec2, had: bool }

// Sets on the tab's layout what the chrome frame shows (its animations at the frame's time, the containers scrolled); the
// caller puts it back with shell_shown_put before anything of the page can run. Nothing is set when the layout cannot be read
// (the page thread has it).
shell_shown_set :: proc(app: ^App, t: ^Tab) -> (sh: Shown) {
	sh.t = t
	l := &t.layout
	if app.chrome_frames.page_locked || t.page == nil || !l.valid { return }
	sh.set = true
	sh.scroll = t.scroll
	t.scroll = shell_shown_scroll(t).y
	sh.mats = make([dynamic]Shown_Mat, context.temp_allocator)
	sh.alphas = make([dynamic]Shown_Alpha, context.temp_allocator)
	sh.scrolls = make([dynamic]Shown_Scroll, context.temp_allocator)
	vals := make([dynamic]style.Compositor_Value, context.temp_allocator)
	shell_animated(app, t, &vals)
	for v in vals {
		bi := lay.box_index(l, v.node)
		if bi == lay.NONE || .Foreign in l.boxes[bi].flags { continue }
		moves := v.props
		style.ps_remove(&moves, .Opacity)
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
	if app.chrome_frames.pending_tab == t.id {
		for b in app.chrome_frames.boxes {
			off, had := l.scroll[b.node]
			append(&sh.scrolls, Shown_Scroll{b.node, off, had})
			l.scroll[b.node] = b.to
		}
	}
	return
}

// The layout as the page's turn left it.
shell_shown_put :: proc(sh: ^Shown) {
	if !sh.set { return }
	l := &sh.t.layout
	sh.t.scroll = sh.scroll
	for m in sh.mats { l.spaces[m.space].mat = m.mat }
	for a in sh.alphas { l.groups[a.group].alpha = a.alpha }
	for s in sh.scrolls {
		if s.had { l.scroll[s.node] = s.off } else { delete_key(&l.scroll, s.node) }
	}
	sh.set = false
}

// The chrome frame has something of its own to show of the tab's page over its last layout: an animation the compositor runs,
// a container it scrolled, a blinking caret. `moving`: it changes by itself (the next chrome frame shows something new).
shell_shown_wanted :: proc(app: ^App, t: ^Tab) -> (wanted, moving: bool) {
	if t.page == nil || app.chrome_frames.page_locked { return }
	tmp := runtime.default_temp_allocator_temp_begin()   // (also asked between two instructions of the guest: shell_preempt)
	defer runtime.default_temp_allocator_temp_end(tmp)
	vals := make([dynamic]style.Compositor_Value, context.temp_allocator)
	moving = shell_animated(app, t, &vals)
	wanted = len(vals) > 0 || (app.chrome_frames.pending_tab == t.id && len(app.chrome_frames.boxes) > 0)
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
shell_animated :: proc(app: ^App, t: ^Tab, out: ^[dynamic]style.Compositor_Value) -> bool {
	if app.chrome_frames.styling { return false }
	return page.animations_compositor_values(t.page, pacer_of(app).frame_ms, out)
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

// The wheel over a busy page at `p` (page-area px), `d` device px: the container under the pointer that can still move that
// way takes it (shown at once when the page can be painted from its layout, else it waits for the page), else the document.
// False: the document's.
shell_wheel_box :: proc(app: ^App, t: ^Tab, p, d: draw.Vec2) -> (taken, wait: bool) {
	if app.chrome_frames.page_locked || !t.layout.valid { return false, false }
	sh := shell_shown_set(app, t)
	node := wheel_scroller(app, t, p, d)
	shell_shown_put(&sh)
	if node == base.NIL_HANDLE { return false, false }
	if !shell_layout_paintable(app, t) { return true, true }
	shell_box_scroll_to(app, t, node, shell_box_shown(app, t, node) + d)
	return true, false
}

// A press on the thumb of a container's bar of a busy page that can be painted from its layout: the drag is the shell's, as
// in a full frame (smooth_scroll.odin scrollbar_event: the same Scrollbar_Drag, which a frame of the other kind goes on with).
shell_box_bar_press :: proc(app: ^App, t: ^Tab, p: draw.Vec2) -> bool {
	if !shell_layout_paintable(app, t) { return false }
	sh := shell_shown_set(app, t)
	hit, ok := scrollbar_at(app, t, p)
	shell_shown_put(&sh)
	if !ok || hit.node == base.NIL_HANDLE || hit.limit <= hit.lo { return false }
	ax := hit.vertical ? 1 : 0
	if p[ax] < hit.thumb.min[ax] || p[ax] >= hit.thumb.max[ax] { return false }   // (the track and the arrows: the page's turn)
	smooth_of(t).drag = Scrollbar_Drag{active = true, node = hit.node, vertical = hit.vertical, grab = p[ax] - hit.thumb.min[ax],
		track_min = hit.rail.min[ax], travel = (hit.rail.max[ax] - hit.rail.min[ax]) - (hit.thumb.max[ax] - hit.thumb.min[ax]), lo = hit.lo, limit = hit.limit}
	return true
}
