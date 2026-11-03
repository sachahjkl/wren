package browser

// Smooth scrolling of the document and of scroll containers, as Chromium and Edge do it: a wheel notch, an arrow key,
// Page Up / Down, Space, Home / End, a click in a scroll bar's track or (with scroll-behavior: smooth) a link to a
// fragment moves the scroller along a curve sampled at every frame (pacer.frame_ms: whole refresh periods), instead of
// jumping.
//   * Notches and key repeats add up: the end moves on by the new distance and the animation goes on from where it is,
//     at the speed it has (no stop and restart), so a fast wheel spin glides.
//   * The curve (browser.scroll.smooth.curve): impulse (a strong push, then a long deceleration) or ease-out (cubic).
//     Both end exactly on the target, with zero speed, and never go past it nor past the scroller's ends.
//   * High-resolution wheels and touchpads (deltas that are not whole notches) already come as a smooth stream: they
//     move at once (browser.scroll.smooth.precise_wheel animates them too).
//   * No animation when smooth scrolling is off, or the system asks for less motion (browser.scroll.smooth.reduced_motion).
//   * Anything else that moves a scroller (find in page, focus, a script) wins: the animation of that scroller stops.
// Scroll bars: dragging a thumb moves the scroller with the pointer, at once; a press in the track pages towards it; a
// press on an arrow of a classic bar scrolls a line (browser.scroll.key_line_px), held it repeats.

import "core:fmt"
import "core:math"
import "toolkit:draw"

_ :: fmt   // PACING_DEBUG only
import "toolkit:platform"
import "wb:base"
import "wb:config"
import lay "wb:layout"

SCROLL_PREFS := [?]config.Def{
	{name = "browser.scroll.smooth.enabled", kind = .Bool, default = {b = true},
		description = "The wheel, the keyboard and clicks in scroll bars scroll the page with an animation drawn at every frame, instead of jumping."},
	{name = "browser.scroll.smooth.curve", kind = .String, default = {s = "impulse"}, choices = {"impulse", "ease-out"},
		description = "Shape of smooth scrolling. impulse: a strong start that slows down gradually (like Edge). ease-out: a cubic deceleration (like Chromium's programmatic smooth scrolling)."},
	{name = "browser.scroll.smooth.impulse", kind = .Float, default = {f = 5}, bounded = true, min = 0.5, max = 30,
		description = "Strength of the impulse curve: higher starts faster and decelerates longer."},
	{name = "browser.scroll.smooth.wheel_ms", kind = .Float, default = {f = 180}, bounded = true, min = 0, max = 2000, unit = "ms",
		description = "Duration of the animation of a wheel notch. Notches coming during it add up. 0 = no animation."},
	{name = "browser.scroll.smooth.key_ms", kind = .Float, default = {f = 140}, bounded = true, min = 0, max = 2000, unit = "ms",
		description = "Duration of the animation of an arrow key (repeats add up). 0 = no animation."},
	{name = "browser.scroll.smooth.page_ms", kind = .Float, default = {f = 260}, bounded = true, min = 0, max = 4000, unit = "ms",
		description = "Duration of the animation of Page Up / Page Down / Space / Home / End, of a click in a scroll bar's track and of scroll-behavior: smooth. 0 = no animation."},
	{name = "browser.scroll.smooth.precise_wheel", kind = .Bool, default = {b = false},
		description = "Animate high-resolution wheels and touchpads too (deltas that are not whole notches). Off: they move at once, as their own stream of small steps is already smooth."},
	{name = "browser.scroll.smooth.reduced_motion", kind = .Bool, default = {b = true},
		description = "No smooth scrolling when the system asks for less motion (Windows: Settings > Accessibility > Visual effects > Animation effects off) or style.prefers_reduced_motion is on."},
}

register_scroll_prefs :: proc(p: ^config.Prefs) { config.register(p, SCROLL_PREFS[:]) }

Scroll_Curve :: enum u8 { Impulse, Ease_Out }

Smooth_Settings :: struct {
	enabled:        bool,
	curve:          Scroll_Curve,
	impulse:        f64,
	wheel_ms, key_ms, page_ms: f64,
	precise_wheel:  bool,
	reduced_motion: bool,
}

smooth_settings_from_prefs :: proc(p: ^config.Prefs) -> Smooth_Settings {
	return Smooth_Settings{
		enabled = config.bool_of(p, "browser.scroll.smooth.enabled"),
		curve = config.string_of(p, "browser.scroll.smooth.curve") == "ease-out" ? .Ease_Out : .Impulse,
		impulse = config.float_of(p, "browser.scroll.smooth.impulse"),
		wheel_ms = config.float_of(p, "browser.scroll.smooth.wheel_ms"),
		key_ms = config.float_of(p, "browser.scroll.smooth.key_ms"),
		page_ms = config.float_of(p, "browser.scroll.smooth.page_ms"),
		precise_wheel = config.bool_of(p, "browser.scroll.smooth.precise_wheel"),
		reduced_motion = config.bool_of(p, "browser.scroll.smooth.reduced_motion"),
	}
}

////////////////////////////////
// The curve (pure: smooth_scroll_test.odin)

// One axis of one scroller moving from `from` to `to` in `dur` ms from `start` (ms, the frame clock).
Axis_Anim :: struct {
	from, to:   f64,
	start, dur: f64,
	curve:      Scroll_Curve,
	k:          f64,    // Impulse: strength
	active:     bool,
}

// Position along the curve (0..1) at `s` (0..1), and its slope.
curve_eval :: proc(curve: Scroll_Curve, k, at: f64) -> (p, dp: f64) {
	s := clamp(at, 0, 1)
	switch curve {
	case .Impulse:
		// an exponential decay of the speed, less its value at the end so that the speed reaches 0 exactly there:
		// f' ~ e^-ks - e^-k (k -> 0: the quadratic ease-out)
		kk := max(k, 1e-2)
		ek := math.exp(-kk)
		den := 1 - ek * (1 + kk)
		e := math.exp(-kk * s)
		return (1 - e - kk * ek * s) / den, kk * (e - ek) / den
	case .Ease_Out:
		u := 1 - s
		return 1 - u * u * u, 3 * u * u
	}
	return s, 1
}

// The slope a curve starts with (its speed at the start, in distances per duration).
curve_start_slope :: proc(curve: Scroll_Curve, k: f64) -> f64 {
	_, d := curve_eval(curve, k, 0)
	return d
}

// Where the axis is at `now`, its speed (units per ms) and whether it is done (then pos == to exactly).
axis_sample :: proc(a: ^Axis_Anim, now: f64) -> (pos, vel: f64, done: bool) {
	if !a.active { return a.to, 0, true }
	if a.dur <= 0 || now >= a.start + a.dur { return a.to, 0, true }
	s := max(now - a.start, 0) / a.dur
	p, dp := curve_eval(a.curve, a.k, s)
	return a.from + (a.to - a.from) * p, (a.to - a.from) * dp / a.dur, false
}

// Starts (or continues) toward `to` from `pos` at speed `vel` (units per ms) at `now`, for `dur` ms. The curve keeps
// the speed it is given when that is faster than its own start: the duration shortens so that the start slope matches
// (a notch arriving near the end of a fast glide does not brake it), never past `to`.
axis_retarget :: proc(a: ^Axis_Anim, pos, vel, to, now, dur: f64, curve: Scroll_Curve, k: f64) {
	a.from, a.to, a.start, a.dur, a.curve, a.k, a.active = pos, to, now, dur, curve, k, true
	dist := to - pos
	if abs(dist) < 1e-6 || dur <= 0 { a.from, a.dur = to, 0; return }
	if vel * dist > 0 {   // moving toward the new end already
		need := abs(vel) * dur / abs(dist)   // slope that keeps the speed
		natural := curve_start_slope(curve, k)
		if need > natural { a.dur = natural * abs(dist) / abs(vel) }
	}
}

////////////////////////////////
// Scrollers of a tab

Scroller_Anim :: struct {
	node:    base.Handle,     // NIL: the document
	axis:    [2]Axis_Anim,
	applied: [2]f32,          // what the animation last set: a different offset means someone else moved it
}

Scrollbar_Drag :: struct {
	active:   bool,
	node:     base.Handle,    // NIL: the document's bar
	vertical: bool,
	grab:     f32,            // pointer to thumb start, along the bar
	track_min, travel: f32,   // where the thumb can go (viewport px)
	lo, limit: f32,           // the scroller's offsets, smallest and largest
}

// An arrow button of a classic scroll bar held down: its scroller steps again by the clock while the pointer is on it.
Arrow_Hold :: struct {
	active, over: bool,
	node:     base.Handle,    // NIL: the document
	button:   lay.Rect,       // viewport px
	step:     [2]f32,         // device px, each time
	next_ms:  f64,            // the frame clock's time of the next step
}

Smooth_Scroll :: struct {
	page:  rawptr,            // the page the offsets belong to (another one: forgotten)
	anims: [dynamic]Scroller_Anim,
	drag:  Scrollbar_Drag,
	arrow: Arrow_Hold,
}

// A held arrow steps again after this long, then this often (Blink's timings).
ARROW_REPEAT_DELAY_MS :: 250
ARROW_REPEAT_MS :: 50

// How long (device px) a document's range must be for a middle press to start an autoscroll it cannot use yet.
AUTOSCROLL_MIN_RANGE :: 0.5

smooth_init :: proc(app: ^App) {
	app.smooth_cfg = smooth_settings_from_prefs(&app.prefs)
	app.watches[.Smooth_Scroll] = config.watch(&app.prefs, "browser.scroll.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		app := (^App)(user)
		app.smooth_cfg = smooth_settings_from_prefs(p)
	}, app)
}

smooth_shutdown :: proc(app: ^App) { config.unwatch(&app.prefs, app.watches[.Smooth_Scroll]) }

smooth_destroy :: proc(s: ^Smooth_Scroll) {
	delete(s.anims)
	s^ = {}
}

// Animations wanted now (preferences, reduced motion).
@(private = "file")
smooth_allowed :: proc(app: ^App) -> bool {
	if !app.smooth_cfg.enabled { return false }
	if app.smooth_cfg.reduced_motion && (app.page_settings.style.reduced_motion || !os_animations_enabled(app)) { return false }
	return true
}

@(private = "file")
smooth_of :: proc(t: ^Tab) -> ^Smooth_Scroll {
	s := &t.smooth
	if s.page != rawptr(t.page) {
		clear(&s.anims)
		s.drag, s.arrow = {}, {}
		s.page = t.page
	}
	return s
}

@(private = "file")
find_anim :: proc(s: ^Smooth_Scroll, node: base.Handle) -> ^Scroller_Anim {
	for &a in s.anims { if a.node == node { return &a } }
	return nil
}

// Current offset and largest offset of a scroller (NIL: the document).
scroller_state :: proc(app: ^App, t: ^Tab, node: base.Handle) -> (cur, limit: [2]f32, ok: bool) {
	wnd := active_window(app)
	if node == base.NIL_HANDLE {
		size := draw.rect_size(wnd.page_rect)
		_, hi := lay.doc_scroll_x_range(&t.layout, size.x)
		_, hi_y := lay.doc_scroll_y_range(&t.layout, size.y)
		return {t.layout.doc_scroll_x, t.scroll}, {hi, hi_y}, t.layout.valid
	}
	m, mok := lay.scroll_max(&t.layout, node)
	if !mok { return }
	c, _ := lay.scroll_of(&t.layout, node)
	return c, m, true
}

// Its smallest offset: 0, but in an axis of a document whose scroll origin is at the end (lay.doc_min_x, lay.doc_min_y).
scroller_low :: #force_inline proc(t: ^Tab, node: base.Handle) -> [2]f32 {
	if node == base.NIL_HANDLE { return {t.layout.doc_min_x, t.layout.doc_min_y} }
	return lay.scroll_min(&t.layout, node)
}

@(private = "file")
scroller_set :: proc(t: ^Tab, node: base.Handle, v: [2]f32) -> [2]f32 {
	if node == base.NIL_HANDLE {
		t.scroll = v.y
		lay.set_doc_scroll_x(&t.layout, v.x)
		return v
	}
	got, _ := lay.set_scroll(&t.layout, node, v)
	return got
}

// Where a scroller is going: the end of its animation, else where it is.
smooth_pending :: proc(app: ^App, t: ^Tab, node: base.Handle) -> [2]f32 {
	cur, _, _ := scroller_state(app, t, node)
	if a := find_anim(smooth_of(t), node); a != nil {
		for k in 0 ..< 2 { if a.axis[k].active { cur[k] = f32(a.axis[k].to) } }
	}
	return cur
}

// Moves a scroller to `target` (clamped to its range), animated over `dur_ms` when smooth scrolling is allowed, else at
// once. Returns false when it cannot move (already there).
smooth_scroll_to :: proc(app: ^App, t: ^Tab, node: base.Handle, target: [2]f32, dur_ms: f64) -> bool {
	cur, limit, ok := scroller_state(app, t, node)
	if !ok { return false }
	lo := scroller_low(t, node)
	to := [2]f32{clamp(target.x, lo.x, limit.x), clamp(target.y, lo.y, limit.y)}
	s := smooth_of(t)
	a := find_anim(s, node)
	request_frames(app, 2)
	if !smooth_allowed(app) || dur_ms <= 0 {
		if a != nil { a.axis = {} }
		if to == cur { return false }
		scroller_set(t, node, to)
		return true
	}
	if a == nil {
		append(&s.anims, Scroller_Anim{node = node, applied = cur})
		a = &s.anims[len(s.anims) - 1]
	}
	pacer := pacer_of(app)
	now := pacer.frame_ms
	moved := false
	for k in 0 ..< 2 {
		ax := &a.axis[k]
		pos, vel := f64(cur[k]), 0.0
		start := now
		if ax.active {
			p, v, done := axis_sample(ax, now)
			if !done { pos, vel = p, v }
		} else {
			start = now - pacer.period_ms   // this frame already shows the first step
		}
		if f64(to[k]) == (ax.active ? ax.to : f64(cur[k])) { continue }
		axis_retarget(ax, pos, vel, f64(to[k]), start, dur_ms, app.smooth_cfg.curve, app.smooth_cfg.impulse)
		moved = true
	}
	return moved
}

// By `delta` from where the scroller is going (notches and key repeats add up).
smooth_scroll_by :: proc(app: ^App, t: ^Tab, node: base.Handle, delta: [2]f32, dur_ms: f64) -> bool {
	return smooth_scroll_to(app, t, node, smooth_pending(app, t, node) + delta, dur_ms)
}

// Stops the animations of a tab where they are (a new document, a jump).
smooth_stop :: proc(t: ^Tab) {
	clear(&t.smooth.anims)
	t.smooth.drag, t.smooth.arrow = {}, {}
}

// Every frame, before the page is drawn: moves the animated scrollers to their place at the frame's time. True while
// some still move (the loop draws the next frame).
smooth_tick :: proc(app: ^App, t: ^Tab) -> bool {
	if t == nil || t.page == nil || t.kind != .Web { return false }
	page_world_check("smooth_tick: scrollers moved in a chrome frame, or during a page thread pass")
	s := smooth_of(t)
	now := pacer_of(app).frame_ms
	if s.arrow.active && s.arrow.over && now >= s.arrow.next_ms {
		smooth_scroll_by(app, t, s.arrow.node, s.arrow.step, app.smooth_cfg.key_ms)
		s.arrow.next_ms = now + ARROW_REPEAT_MS
	}
	for i := len(s.anims) - 1; i >= 0; i -= 1 {
		a := &s.anims[i]
		cur, limit, ok := scroller_state(app, t, a.node)
		// gone, or moved by someone else: that wins
		if !ok || abs(cur.x - a.applied.x) > 0.5 || abs(cur.y - a.applied.y) > 0.5 {
			when PACING_DEBUG { fmt.eprintln("smooth: dropped", ok, cur, a.applied) }
			unordered_remove(&s.anims, i)
			continue
		}
		when PACING_DEBUG { fmt.eprintln("smooth: tick", now, cur, a.axis[1]) }
		lo := scroller_low(t, a.node)
		next := cur
		busy := false
		for k in 0 ..< 2 {
			ax := &a.axis[k]
			if !ax.active { continue }
			// the range may have shrunk (a layout pass): the end follows
			ax.to = clamp(ax.to, f64(lo[k]), f64(limit[k]))
			p, _, done := axis_sample(ax, now)
			next[k] = clamp(f32(p), lo[k], limit[k])
			if done { ax.active = false } else { busy = true }
		}
		a.applied = scroller_set(t, a.node, next)
		if !busy { unordered_remove(&s.anims, i) }
	}
	return len(s.anims) > 0 || s.arrow.active
}

////////////////////////////////
// Wheel

// A wheel event over the page: `p` relative to the page area, `d` in device px (+ = toward the end). The scroller under
// the pointer that can still move that way (counting where it is already going) takes it, else the document.
smooth_wheel :: proc(app: ^App, t: ^Tab, p, d: draw.Vec2, precise: bool) {
	if !t.layout.valid { return }
	node := wheel_scroller(app, t, p, d)
	dur := app.smooth_cfg.wheel_ms
	if precise && !app.smooth_cfg.precise_wheel { dur = 0 }
	smooth_scroll_by(app, t, node, d, dur)
}

// A wheel's turn in notches, per axis. Shift turns a vertical wheel into a horizontal one, as in other browsers.
wheel_axes :: proc(ev: platform.Event) -> draw.Vec2 {
	if .Shift in ev.mods && ev.delta.x == 0 { return {ev.delta.y, 0} }
	return ev.delta
}

// A finger's pan over the page (touch_shell.odin): at once (the content follows the finger), the scroller under `p`
// that can move that way, else the document. Returns the scroller (NIL: the document), for the fling after it.
touch_scroll :: proc(app: ^App, t: ^Tab, p, d: draw.Vec2) -> base.Handle {
	if !t.layout.valid { return base.NIL_HANDLE }
	node := wheel_scroller(app, t, p, d)
	smooth_scroll_by(app, t, node, d, 0)
	return node
}

// The scroller under `p` (page-area px) that can move by `d` device px (chained to the parent, as the wheel does): a
// container with room that way, else the document (NIL). For middle-click autoscroll (page_autoscroll.odin).
scroller_under :: proc(app: ^App, t: ^Tab, p, d: draw.Vec2) -> base.Handle {
	return wheel_scroller(app, t, p, d)
}

// For middle-click autoscroll: the scroller under `p` (page-area px) and which axes it can move, so the marker and the
// velocity use only the directions that scroll. `found` is false when nothing under the pointer (nor the document) can
// scroll. `is_doc` tells the document (NIL node) from a NIL that is no scroller.
scroller_axes_under :: proc(app: ^App, t: ^Tab, p: draw.Vec2) -> (node: base.Handle, can_x, can_y, is_doc, found: bool) {
	can_axis :: proc(app: ^App, t: ^Tab, node: base.Handle, d: draw.Vec2) -> bool {
		_, limit, ok := scroller_state(app, t, node)
		if !ok { return false }
		pend := smooth_pending(app, t, node)
		lo := scroller_low(t, node)
		nx, ny := clamp(pend.x + d.x, lo.x, limit.x), clamp(pend.y + d.y, lo.y, limit.y)
		return abs(nx - pend.x) >= 0.01 || abs(ny - pend.y) >= 0.01
	}
	l := &t.layout
	h := lay.hit_test(l, p, draw.rect_size(active_window(app).page_rect), t.scroll)
	// walk the hit element's box and its scroll spaces, as wheel_scroller does, taking the first that can move anywhere
	consider :: proc(app: ^App, t: ^Tab, node: base.Handle) -> (bool, bool, bool) {
		x := can_axis(app, t, node, {1, 0}) || can_axis(app, t, node, {-1, 0})
		y := can_axis(app, t, node, {0, 1}) || can_axis(app, t, node, {0, -1})
		return x, y, x || y
	}
	if h.item != lay.NONE {
		if b := &l.boxes[h.box]; b.scroll_space != lay.NONE {
			if x, y, any := consider(app, t, b.node); any { return b.node, x, y, false, true }
		}
		for s := l.items[h.item].space; s != lay.NONE; s = l.spaces[s].parent {
			if l.spaces[s].kind != .Scroll { continue }
			sn := l.boxes[l.spaces[s].box].node
			if x, y, any := consider(app, t, sn); any { return sn, x, y, false, true }
		}
	}
	// the document
	if x, y, any := consider(app, t, base.NIL_HANDLE); any || y {
		return base.NIL_HANDLE, x, y, true, (x || y)
	}
	// nothing moves yet, but allow a document Y session when the page can grow taller than the view
	_, limit, ok := scroller_state(app, t, base.NIL_HANDLE)
	if ok && limit.y > AUTOSCROLL_MIN_RANGE { return base.NIL_HANDLE, false, true, true, true }
	return base.NIL_HANDLE, false, false, true, false
}

@(private = "file")
wheel_scroller :: proc(app: ^App, t: ^Tab, p, d: draw.Vec2) -> base.Handle {
	l := &t.layout
	h := lay.hit_test(l, p, draw.rect_size(active_window(app).page_rect), t.scroll)
	if h.item == lay.NONE { return base.NIL_HANDLE }
	can :: proc(app: ^App, t: ^Tab, node: base.Handle, d: draw.Vec2) -> bool {
		_, limit, ok := scroller_state(app, t, node)
		if !ok { return false }
		pend := smooth_pending(app, t, node)
		lo := scroller_low(t, node)
		nx, ny := clamp(pend.x + d.x, lo.x, limit.x), clamp(pend.y + d.y, lo.y, limit.y)
		return abs(nx - pend.x) >= 0.01 || abs(ny - pend.y) >= 0.01
	}
	if b := &l.boxes[h.box]; b.scroll_space != lay.NONE && can(app, t, b.node, d) { return b.node }
	for s := l.items[h.item].space; s != lay.NONE; s = l.spaces[s].parent {
		if l.spaces[s].kind != .Scroll { continue }
		node := l.boxes[l.spaces[s].box].node
		if can(app, t, node, d) { return node }
	}
	return base.NIL_HANDLE
}

// Whether a wheel event is a fraction of a notch (high-resolution wheel, touchpad).
wheel_is_precise :: proc(delta: draw.Vec2) -> bool {
	frac :: proc(v: f32) -> bool { return abs(v - math.round(v)) > 0.001 }
	return frac(delta.x) || frac(delta.y)
}

////////////////////////////////
// The document's own scrolling

// The document to `to` for a fragment or a script: animated when the page asks for it, else at once (stopping any animation).
scroll_document_to :: proc(app: ^App, t: ^Tab, to: [2]f32, smooth: bool) {
	if smooth && smooth_scroll_to(app, t, base.NIL_HANDLE, to, app.smooth_cfg.page_ms) { return }
	if a := find_anim(smooth_of(t), base.NIL_HANDLE); a != nil { a.axis = {} }
	t.scroll = max(to.y, t.layout.doc_min_y)
	lay.set_doc_scroll_x(&t.layout, max(to.x, t.layout.doc_min_x))
}

// Where a scroller at `cur` showing `port` px of an axis goes to have `lo`..`hi` in view, nearest edge first; where it is
// when that shows already (scrollIntoView's "nearest"; a fragment's inline axis).
scroll_nearest :: proc(lo, hi, port, cur: f32) -> f32 {
	if lo >= cur && hi <= cur + port { return cur }
	if hi - lo > port || lo < cur { return lo }
	return hi - port
}

////////////////////////////////
// Scroll bars

Bar_Hit :: struct {
	node:       base.Handle,   // NIL: the document's bar
	vertical:   bool,
	track, thumb: lay.Rect,    // viewport px (relative to the page area); a classic bar's track takes its arrows in
	rail:       lay.Rect,      // where the thumb runs: the track less the arrows of a classic bar
	arrows:     [2]lay.Rect,   // a classic bar's arrow buttons, at the start and at the end (empty: none)
	lo, limit:  f32,           // the scroller's offsets on that axis, smallest and largest
	port:       f32,           // visible length along the bar's axis
}

// A bar's hit from its track and thumb: its arrows and rail.
@(private = "file")
bar_hit :: proc(l: ^Layout, node: base.Handle, vertical: bool, track, thumb: lay.Rect, lo, limit, port: f32) -> Bar_Hit {
	h := Bar_Hit{node = node, vertical = vertical, track = track, thumb = thumb, rail = track, lo = lo, limit = limit, port = port}
	if !l.settings.scrollbar_overlay { h.arrows[0], h.arrows[1], h.rail = lay.classic_parts(track, vertical) }
	return h
}

// The scroll bar under `p` (page-area coordinates): the document's first (drawn over everything), then the topmost
// container's.
scrollbar_at :: proc(app: ^App, t: ^Tab, p: draw.Vec2) -> (hit: Bar_Hit, ok: bool) {
	l := &t.layout
	if !l.valid { return }
	size := draw.rect_size(active_window(app).page_rect)
	port := lay.doc_port(l, size)
	slop := l.settings.scrollbar_overlay ? l.settings.scrollbar_margin * l.scale : 0   // the margin around a thin bar takes the press too
	grow :: proc(r: lay.Rect, by: f32) -> lay.Rect { return {r.min - by, r.max + by} }
	inside :: proc(r: lay.Rect, p: draw.Vec2) -> bool { return p.x >= r.min.x && p.x < r.max.x && p.y >= r.min.y && p.y < r.max.y }
	if track, thumb, dok := lay.doc_scrollbar(l, size, t.scroll); dok && inside(grow(track, slop), p) {
		lo, hi := lay.doc_scroll_y_range(l, size.y)
		return bar_hit(l, base.NIL_HANDLE, true, track, thumb, lo, hi, port.y), true
	}
	if track, thumb, dok := lay.doc_scrollbar_x(l, size); dok && inside(grow(track, slop), p) {
		lo, hi := lay.doc_scroll_x_range(l, size.x)
		return bar_hit(l, base.NIL_HANDLE, false, track, thumb, lo, hi, port.x), true
	}
	v := lay.view_make(l, size, t.scroll, cull = false)
	for i := len(l.items) - 1; i >= 0; i -= 1 {
		it := &l.items[i]
		if it.kind != .Scrollbar || l.spaces[it.space].xform != lay.NONE { continue }
		track := lay.item_rect(l, &v, it)
		if !inside(grow(track, slop), p) { continue }
		if it.clip != lay.NONE && !lay.clip_contains(l, &v, it.clip, p) { continue }
		b := &l.boxes[it.box]
		if b.scroll_space == lay.NONE { continue }
		sp := &l.spaces[b.scroll_space]
		vertical := .Vertical in it.flags
		ax := vertical ? 1 : 0
		sport := sp.port.max - sp.port.min
		return bar_hit(l, b.node, vertical, track, lay.scrollbar_thumb(l, &v, it), sp.min_scroll[ax], sp.max_scroll[ax], sport[ax]), true
	}
	return
}

// Pointer events for the scroll bars of the page (`ev.pos` in window coordinates). True when the event was theirs: a
// press on a bar, the moves and the release of a thumb drag.
scrollbar_event :: proc(app: ^App, t: ^Tab, ev: platform.Event) -> bool {
	wnd := active_window(app)
	if t.page == nil || !t.layout.valid { return false }
	s := smooth_of(t)
	p := ev.pos - wnd.page_rect.min
	#partial switch ev.kind {
	case .Mouse_Press:
		if ev.button != .Left || !draw.rect_contains(wnd.page_rect, ev.pos) { return false }
		hit, ok := scrollbar_at(app, t, p)
		when PACING_DEBUG { fmt.eprintln("scrollbar press", p, ok, hit) }
		if !ok { return false }
		if hit.limit <= hit.lo { return true }   // a classic bar with nothing to scroll still takes its press
		ax := hit.vertical ? 1 : 0
		for r, i in hit.arrows {
			if !lay.rect_contains(r, p) { continue }
			// an arrow: a line that way, again and again while it is held (smooth_tick)
			s.arrow = Arrow_Hold{active = true, over = true, node = hit.node, button = r, next_ms = pacer_of(app).frame_ms + ARROW_REPEAT_DELAY_MS}
			s.arrow.step[ax] = (i == 0 ? -1 : 1) * app.cfg.key_line_px * t.layout.scale
			smooth_scroll_by(app, t, hit.node, s.arrow.step, app.smooth_cfg.key_ms)
			return true
		}
		if p[ax] >= hit.thumb.min[ax] && p[ax] < hit.thumb.max[ax] {
			// the thumb follows the pointer from where it was grabbed
			s.drag = Scrollbar_Drag{active = true, node = hit.node, vertical = hit.vertical, grab = p[ax] - hit.thumb.min[ax],
				track_min = hit.rail.min[ax], travel = (hit.rail.max[ax] - hit.rail.min[ax]) - (hit.thumb.max[ax] - hit.thumb.min[ax]), lo = hit.lo, limit = hit.limit}
			if a := find_anim(s, hit.node); a != nil { a.axis = {} }
		} else {
			// a page toward the pointer
			step := max(hit.port * app.cfg.key_page_fraction, app.cfg.key_line_px * t.layout.scale)
			d: [2]f32
			d[ax] = p[ax] < hit.thumb.min[ax] ? -step : step
			smooth_scroll_by(app, t, hit.node, d, app.smooth_cfg.page_ms)
		}
		return true
	case .Mouse_Move:
		if s.arrow.active {
			s.arrow.over = lay.rect_contains(s.arrow.button, p)
			return true
		}
		if !s.drag.active { return false }
		dr := s.drag
		ax := dr.vertical ? 1 : 0
		f := dr.travel > 0 ? clamp((p[ax] - dr.grab - dr.track_min) / dr.travel, 0, 1) : 0
		cur, _, ok := scroller_state(app, t, dr.node)
		if !ok { s.drag = {}; return false }
		cur[ax] = dr.lo + f * (dr.limit - dr.lo)
		scroller_set(t, dr.node, cur)
		when PACING_DEBUG { fmt.eprintln("scrollbar drag", p, f, cur) }
		request_frames(app, 2)
		return true
	case .Mouse_Release:
		if ev.button != .Left || (!s.drag.active && !s.arrow.active) { return false }
		s.drag, s.arrow = {}, {}
		return true
	}
	return false
}

////////////////////////////////
// The wheel's step

// CSS pixels one wheel notch scrolls, vertically and horizontally: browser.scroll.step_px, or with 0 what Windows says,
// as Chromium does (the Mouse settings' lines per notch times 100/3 px: 3 lines = 100 px; "one screen at a time" = a
// page, `page_css` when known). Read at each wheel event: the setting may change while Wren runs, and the call is cheap.
wheel_step :: proc(app: ^App, page_css: [2]f32 = {}) -> [2]f32 {
	if app.cfg.scroll_step > 0 { return {app.cfg.scroll_step, app.cfg.scroll_step} }
	LINE :: f32(100.0 / 3.0)
	WHEEL_PAGESCROLL :: max(u32)
	lines, chars := system_wheel_scroll()   // scroll_steps_<os>.odin: the desktop's lines / chars per notch (Windows), else 3 / 3
	step: [2]f32
	step.y = lines == WHEEL_PAGESCROLL ? (page_css.y > 0 ? page_css.y * 0.875 : 20 * LINE) : f32(lines) * LINE
	step.x = chars == WHEEL_PAGESCROLL ? (page_css.x > 0 ? page_css.x * 0.875 : 20 * LINE) : f32(chars) * LINE
	return step
}
