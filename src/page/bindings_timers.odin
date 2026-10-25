package page

// Timers and the rendering-related scheduling of HTML (import module "timers"):
//   * setTimeout / setInterval with the HTML timer nesting clamp (a timer created from a timer task deeper than
//     timers.nesting_threshold gets at least timers.nested_min_delay_ms) and background throttling (hidden pages wake up
//     on a grid of timers.background_alignment_ms);
//   * requestAnimationFrame: callbacks run once per rendered frame, in order, each followed by a microtask checkpoint.
//     The shell calls run_animation_frames before painting a visible page, and asks wants_animation_frame whether
//     to render at all;
//   * requestIdleCallback: callbacks run when the event loop has nothing due, with a deadline, or on their timeout;
//   * page visibility (document.visibilityState, visibilitychange), set by the shell with set_page_visible.
//
// Timestamps given to guests (animation frames, idle deadlines) are on the performance.now() timeline of the page.

import "core:math"
import "wb:base"
import "wb:dom"
import "wb:host"

Frame_Callback :: struct {
	id:        u64,
	instance:  u32,
	callback:  u32,
	user:      u32,
	cancelled: bool,
}

Idle_Callback :: struct {
	id:          u64,
	instance:    u32,
	callback:    u32,
	user:        u32,
	timeout_ns:  i64,   // loop clock; 0 = no timeout
}

////////////////////////////////
// setTimeout / setInterval

// The delay a timer really gets: NaN and negatives are 0, and deeply nested timers are clamped (HTML timer
// initialization steps: "if nesting level is greater than 5 and timeout is less than 4, set timeout to 4").
timer_effective_delay :: proc(delay_ms: f64, nesting: int, s: Web_Settings) -> f64 {
	d := delay_ms
	if math.is_nan(d) || d < 0 { d = 0 }
	if math.is_inf(d) { d = f64(max(i32)) }   // the Web IDL long conversion caps it; avoid an overflowing deadline
	if nesting > s.timer_nesting_threshold && d < s.timer_nested_min_ms { d = s.timer_nested_min_ms }
	return d
}

// Milliseconds a timer of a hidden page waits for the next point of the background grid (0 = run now).
background_wait_ms :: proc(now_ms, align_ms: f64) -> f64 {
	if align_ms <= 0 { return 0 }
	next := math.ceil(now_ms / align_ms) * align_ms
	return max(next - now_ms, 0)
}

@(private)
timer_fire :: proc(data: rawptr) {
	t := (^Timer)(data)
	p := t.page
	t.handle = base.NIL_HANDLE   // the loop's one-shot is spent
	if p.web.frozen { append(&p.web.frozen_timers, t.self); return }   // in the back/forward cache: runs when thawed
	s := &p.settings.web
	if !p.web.visible && s.throttle_background && !t.throttled {
		if wait := background_wait_ms(f64(host.now_ns(p.loop)) / 1e6, s.background_align_ms); wait >= 1 {
			t.throttled = true
			t.handle = host.set_timer(p.loop, wait, 0, timer_fire, t, p.scope)
			return
		}
	}
	t.throttled = false
	cb, user, user64, wide, repeat, self, idx, nesting := t.callback, t.user, t.user64, t.wide, t.interval, t.self, t.instance, t.nesting

	saved := p.web.timer_nesting
	p.web.timer_nesting = nesting
	if inst := instance_by_index(p, idx); inst != nil {
		if wide {
			argv := [2]u32{u32(user64), u32(user64 >> 32)}
			call_guest(p, inst, cb, argv[:])
		} else {
			argv := [1]u32{user}
			call_guest(p, inst, cb, argv[:])
		}
	}
	if p.closed { return }
	p.web.timer_nesting = saved

	// the guest may have cleared the timer from its own callback
	cur := base.pool_get(&p.timers, self)
	if cur == nil { return }
	if !repeat { base.pool_remove(&p.timers, self); return }
	// an interval is a timer re-initialised from its own task: one nesting level deeper each time
	d := timer_effective_delay(cur.delay, cur.nesting, s^)
	cur.nesting += 1
	cur.handle = host.set_timer(p.loop, d, 0, timer_fire, cur, p.scope)
}

@(private)
timer_start :: proc(p: ^Page, inst: u32, cb: i32, user: u64, wide: bool, delay_ms: f64, repeat: bool) -> u64 {
	nesting := p.web.timer_nesting
	d := timer_effective_delay(delay_ms, nesting, p.settings.web)
	h, t := base.pool_insert(&p.timers, Timer{page = p, instance = inst, callback = u32(cb), user = u32(user), user64 = user,
		wide = wide, interval = repeat, delay = delay_ms, nesting = nesting + 1})
	t.self = h
	t.handle = host.set_timer(p.loop, d, 0, timer_fire, t, p.scope)
	return u64(h)
}

Timers_setTimeout :: proc(c: ^Call, callback: u32, user: i32, delay_ms: f64) -> u64 {
	return timer_start(c.page, c.owner, i32(callback), u64(u32(user)), false, delay_ms, false)
}
Timers_setInterval :: proc(c: ^Call, callback: u32, user: i32, delay_ms: f64) -> u64 {
	return timer_start(c.page, c.owner, i32(callback), u64(u32(user)), false, delay_ms, true)
}
// Same with a 64-bit user value: the callback is (user: i64).
Timers_setTimeout64 :: proc(c: ^Call, callback: u32, user: i64, delay_ms: f64) -> u64 {
	return timer_start(c.page, c.owner, i32(callback), u64(user), true, delay_ms, false)
}
Timers_setInterval64 :: proc(c: ^Call, callback: u32, user: i64, delay_ms: f64) -> u64 {
	return timer_start(c.page, c.owner, i32(callback), u64(user), true, delay_ms, true)
}
Timers_clear :: proc(c: ^Call, timer: Api_Timer) -> Api_Error {
	p := c.page
	t, _ := base.pool_remove(&p.timers, H(timer.handle))
	host.clear_timer(p.loop, t.handle)
	return .None
}// The loop clock (ms since the browser started). performance.now() is the page's own timeline.
Timers_now :: proc(c: ^Call) -> f64 { return f64(host.now_ns(c.page.loop)) / 1e6 }

////////////////////////////////
// requestAnimationFrame

requestAnimationFrame :: proc(c: ^Call, callback: u32, user: i32) -> u64 {
	p := c.page
	w := p.web
	if len(w.frames) >= p.settings.web.max_frame_callbacks { return 0 }
	w.next_frame_id += 1
	append(&w.frames, Frame_Callback{id = w.next_frame_id, instance = c.owner, callback = callback, user = u32(user)})
	return w.next_frame_id
}

cancelAnimationFrame :: proc(c: ^Call, id: u64) -> Api_Error {
	w := c.page.web
	for f, i in w.frames {
		if f.id == id { ordered_remove(&w.frames, i); return .None }
	}
	// cancelled from a callback of the frame being run: it must not run
	if w.running_frames != nil {
		for &f in w.running_frames^ { if f.id == id && !f.cancelled { f.cancelled = true; return .None } }
	}
	return .Not_Found
}

// True when the page has animation frame callbacks waiting and is visible: the shell renders a frame for it.
wants_animation_frame :: proc(p: ^Page) -> bool {
	return p != nil && !p.closed && p.web.visible && !p.web.frozen && (len(p.web.frames) > 0 || p.web.io_pending || p.web.ro_pending || p.web.scroll_pending)
}

// "Run the animation frame callbacks" of HTML's update-the-rendering step. `now_ms` is the frame time on the loop clock
// (host.now_ns / 1e6); callbacks receive it on the page's performance timeline. Callbacks requested while this runs wait
// for the next frame. Returns how many ran.
run_animation_frames :: proc(p: ^Page, now_ms: f64) -> int {
	if p == nil || p.closed || p.web.frozen { return 0 }
	run_scroll_steps(p)   // the step before: scroll events of what scrolled since the last frame (scroll_events.odin)
	if p.closed { return 0 }
	defer {   // the steps after the callbacks: resize observations, then intersection observations (HTML update the rendering)
		resize_observers_update(p)
		intersection_observers_update(p)
	}
	if len(p.web.frames) == 0 { return 0 }
	w := p.web
	ts := now_ms - f64(w.origin_ns) / 1e6
	batch := w.frames
	w.frames = make([dynamic]Frame_Callback)
	w.running_frames = &batch
	ran := 0
	for i in 0 ..< len(batch) {
		f := batch[i]
		if f.cancelled { continue }
		inst := instance_by_index(p, f.instance)
		if inst == nil { continue }
		bits := transmute(u64)ts
		argv := [3]u32{f.user, u32(bits), u32(bits >> 32)}   // (user: i32, timestamp: f64)
		call_guest(p, inst, f.callback, argv[:])
		ran += 1
		if p.closed { break }
	}
	if !p.closed { w.running_frames = nil }
	delete(batch)
	return ran
}

////////////////////////////////
// requestIdleCallback

requestIdleCallback :: proc(c: ^Call, callback: u32, user: i32, timeout_ms: f64) -> u64 {
	p := c.page
	w := p.web
	if len(w.idle) >= p.settings.web.max_idle_callbacks { return 0 }
	w.next_idle_id += 1
	ic := Idle_Callback{id = w.next_idle_id, instance = c.owner, callback = callback, user = u32(user)}
	if !math.is_nan(timeout_ms) && timeout_ms > 0 {
		ic.timeout_ns = host.now_ns(p.loop) + i64(min(timeout_ms, f64(max(i32))) * 1e6)
	}
	append(&w.idle, ic)
	idle_schedule(p)
	return w.next_idle_id
}

cancelIdleCallback :: proc(c: ^Call, id: u64) -> Api_Error {
	p := c.page
	for ic, i in p.web.idle {
		if ic.id == id { ordered_remove(&p.web.idle, i); idle_schedule(p); return .None }
	}
	return .Not_Found
}

// Time between two rendered frames: timers.frame_budget_ms, else the shell's frame period, else 60 Hz.
frame_interval_ms :: proc(s: Web_Settings) -> f64 {
	if s.frame_budget_ms > 0 { return s.frame_budget_ms }
	if s.frame_period_ms > 0 { return s.frame_period_ms }
	return 1000.0 / 60
}

// Arms the idle scan: soon (timers.idle_poll_ms), or at the earliest timeout when that comes first.
@(private)
idle_schedule :: proc(p: ^Page) {
	w := p.web
	if w.idle_timer != base.NIL_HANDLE { host.clear_timer(p.loop, w.idle_timer); w.idle_timer = base.NIL_HANDLE }
	if len(w.idle) == 0 || p.closed { return }
	delay := p.settings.web.idle_poll_ms
	now := host.now_ns(p.loop)
	for c in w.idle {
		if c.timeout_ns != 0 { delay = min(delay, max(f64(c.timeout_ns - now) / 1e6, 0)) }
	}
	w.idle_timer = host.set_timer(p.loop, delay, 0, idle_scan, p, p.scope)
}

@(private)
idle_scan :: proc(data: rawptr) {
	p := (^Page)(data)
	w := p.web
	w.idle_timer = base.NIL_HANDLE
	if p.closed || len(w.idle) == 0 || w.frozen { return }   // (frozen: page_thaw schedules the scan again)
	s := &p.settings.web
	now := host.now_ns(p.loop)

	// timed-out callbacks run now, each as its own task, whatever the loop is doing
	i := 0
	for i < len(w.idle) {
		c := w.idle[i]
		if c.timeout_ns == 0 || c.timeout_ns > now { i += 1; continue }
		ordered_remove(&w.idle, i)
		idle_invoke(p, c, page_now_ms(p), true)
		if p.closed { return }
	}

	// an idle period: nothing posted, no timer due, and no animation frame about to be rendered
	next := host.next_timeout_ms(p.loop)
	busy := next == 0
	if !busy && len(w.idle) > 0 {
		budget := s.idle_max_deadline_ms
		if next > 0 { budget = min(budget, f64(next)) }
		if wants_animation_frame(p) { budget = min(budget, frame_interval_ms(s^)) }
		deadline := page_now_ms(p) + budget
		// only the callbacks present when the period starts run in it
		count := len(w.idle)
		for k := 0; k < count && len(w.idle) > 0; k += 1 {
			if page_now_ms(p) >= deadline { break }
			c := w.idle[0]
			ordered_remove(&w.idle, 0)
			idle_invoke(p, c, deadline, false)
			if p.closed { return }
		}
	}
	idle_schedule(p)
}

@(private)
idle_invoke :: proc(p: ^Page, c: Idle_Callback, deadline_ms: f64, did_timeout: bool) {
	inst := instance_by_index(p, c.instance)
	if inst == nil { return }
	bits := transmute(u64)deadline_ms
	argv := [4]u32{c.user, u32(bits), u32(bits >> 32), did_timeout ? 1 : 0}   // (user: i32, deadline: f64, did_timeout: i32)
	call_guest(p, inst, c.callback, argv[:])
}

////////////////////////////////
// Visibility

// The shell tells the page whether it is shown (current tab of a window that is not minimized). Fires visibilitychange
// at the document when it changes; hidden pages get no animation frames and throttled timers.
set_page_visible :: proc(p: ^Page, visible: bool) {
	if p == nil || p.closed || p.web.visible == visible { return }
	p.web.visible = visible
	dispatch_event(p, p.doc.root, dom.Event{type = "visibilitychange", bubbles = true})
}

page_visible :: proc(p: ^Page) -> bool { return p.web.visible }

Document_visibilityState :: proc(c: ^Call) -> Api_VisibilityState { return c.page.web.visible ? .Visible : .Hidden }



