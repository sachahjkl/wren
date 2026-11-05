package browser

import "core:time"
import "toolkit:draw"
import "toolkit:platform"
import "toolkit:render"

// A probe of the tab drag, for `wren ctl stats` (field `dragSamples`, browser.frame.drag_probe): what each frame built while
// a tab was held drew, against the pointer it was built from and the refresh that showed it. src/e2e window.odin reads the samples: it moves the
// pointer along a known line and turns the samples into the lag of the tab behind the pointer and
// the evenness of its steps per refresh. Nothing is recorded with the preference off.
DRAG_PROBE_CAP :: 4096

Drag_Sample :: struct {
	read:     i64,   // tick the frame had read its input (render.set_frame_read): the key a displayed frame is matched by
	shown:    i64,   // tick of the refresh that showed it (0: never shown: a later frame replaced it)
	mouse_x:  f32,   // pointer x the frame was built from
	finger_x: f32,   // where the dragged tab holds the pointer on the screen
	dt:       f32,   // seconds the animations were advanced by
	moves:    i32,   // pointer moves the frame consumed
	done:     i64,   // tick Present returned
	waited:   f32,   // ms the frame waited for the screen's slot (pacer_wait)
	page_w:   f32,   // width the page was laid out and painted at in this frame (px; 0: no page)
	area_w:   f32,   // width of the page's area in this frame (px): page_w differs while a frame shows another width
}

Drag_Probe :: struct {
	ring: [DRAG_PROBE_CAP]Drag_Sample,
	n:    int,
}


drag_probe_count_moves :: proc(app: ^App, events: []platform.Event) {
	app.drag_probe_moves = 0
	if !app.pacing.cfg.drag_probe { return }
	for e in events { if e.kind == .Mouse_Move { app.drag_probe_moves += 1 } }
}

// The dragged tab was built for this frame (tab_box): `finger_x` is the pointer position the tab's left edge implies.
drag_probe_note :: proc(app: ^App, mouse_x, finger_x: f32) {
	if !app.pacing.cfg.drag_probe { return }
	pacer := pacer_of(app)
	app.drag_probe.ring[app.drag_probe.n % DRAG_PROBE_CAP] = {read = pacer.read_tick, mouse_x = mouse_x, finger_x = finger_x, dt = pacer.dt, moves = app.drag_probe_moves, waited = f32(pacer.waited_ms)}
	app.drag_probe.n += 1
}

// Present returned (pacer_end_frame).
drag_probe_presented :: proc(app: ^App) {
	if !app.pacing.cfg.drag_probe || app.drag_probe.n == 0 { return }
	s := &app.drag_probe.ring[(app.drag_probe.n - 1) % DRAG_PROBE_CAP]
	if s.read != pacer_of(app).read_tick { return }
	s.done = time.tick_now()._nsec
	s.area_w = draw.rect_size(active_window(app).page_rect).x
	// (a chrome frame, made while the frame's layout runs on the page thread or its styles take long, paints no page: the width of the pass under way is not its own, and the area has the handle's newer one)
	if shell_nested() { return }
	if t, pp := current_tab(app), &window_own(app).page_prep; t != nil && pp.tab == t && pp.frame == app.chrome_frames.frame_no { s.page_w = pp.size.x }
}

// A frame reached the screen: the sample made for it learns when.
drag_probe_displayed :: proc(app: ^App, d: render.Displayed_Frame) {
	if !app.pacing.cfg.drag_probe || d.read._nsec == 0 { return }
	for i := app.drag_probe.n - 1; i >= 0 && i >= app.drag_probe.n - 64; i -= 1 {
		s := &app.drag_probe.ring[i % DRAG_PROBE_CAP]
		if s.read == d.read._nsec { s.shown = d.shown._nsec; return }
	}
}

drag_probe_reset :: proc() { the_app.drag_probe.n = 0 }
