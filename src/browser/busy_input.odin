package browser

// Input while a page keeps the thread, for tests (src/e2e `while_busy`): steps taken one per chrome frame (shell_frames.odin),
// in order, so that what a test does during a long script depends on the frames made under it and not on when the script runs.
// A step is an event (injected before the chrome frame polls, as a device's would come), a capture of the frame (its pixels
// kept for the test; the next step waits for them), a wait (chrome frames until that long has passed: what moves by the clock
// moves meanwhile), or a new size of the window (what a script holding the thread until innerWidth changes waits for).
// Nothing happens outside chrome frames: steps left when the page lets go wait for the next long script.

import "core:time"
import "toolkit:platform"
import "toolkit:render"

Busy_Step_Kind :: enum u8 { Event, Capture, Wait, Resize }

Busy_Step :: struct {
	kind: Busy_Step_Kind,
	ev:   platform.Event,   // Event (window pixels)
	size: [2]int,           // Resize: the window's new client size
	ms:   f64,              // Wait
}

// What a Capture step saw: the window as that chrome frame drew it (rgba nil: it could not be read).
Busy_Shot :: struct {
	rgba: []u8,
	size: [2]int,
}

Busy_Input :: struct {
	steps: [dynamic]Busy_Step,
	next:  int,
	arm:   bool,   // the Capture step is asked of the renderer at the end of this chrome frame
	asked: bool,   // ... it was: its pixels are read at the next one
	since: time.Tick,   // the Wait step under way began then (0: none)
	shots: [dynamic]Busy_Shot,
}

// Steps for the next chrome frames (after those still waiting).
control_busy_input :: proc(app: ^App, steps: []Busy_Step) {
	append(&app.remote.busy.steps, ..steps)
	request_frames(app, 2)
}

// Steps not taken yet.
control_busy_left :: proc(app: ^App) -> int { return len(app.remote.busy.steps) - app.remote.busy.next }

// The pictures of the Capture steps taken, in order; the caller owns them and the list starts again.
control_busy_shots :: proc(app: ^App) -> []Busy_Shot {
	b := &app.remote.busy
	shots := b.shots[:]
	b.shots = {}
	return shots
}

busy_input_pending :: proc(app: ^App) -> bool { return control_busy_left(app) > 0 || app.remote.busy.asked }

// A chrome frame, before it polls: the picture asked for at the end of the last one, then the next step.
busy_input_step :: proc(app: ^App) {
	b := &app.remote.busy
	if b.asked {
		pixels, size, st := render.capture_poll(&app.r)
		if st == .Pending { return }
		append(&b.shots, Busy_Shot{rgba = pixels, size = size})
		b.asked = false
		b.next += 1
	}
	if b.next >= len(b.steps) { return }
	step := b.steps[b.next]
	switch step.kind {
	case .Event:
		inject(app, step.ev)
		b.next += 1
	case .Capture:
		b.arm = true
	case .Wait:
		if b.since == {} { b.since = time.tick_now() }
		if time.duration_milliseconds(time.tick_since(b.since)) >= step.ms { b.since, b.next = {}, b.next + 1 }
	case .Resize:
		window_apply(app, "", false, step.size.x, step.size.y, 0, 0, true, true, false, false)
		b.next += 1
	}
}

// A chrome frame, before it ends: the copy of the window, when a Capture step asked for it.
busy_input_arm :: proc(app: ^App) {
	b := &app.remote.busy
	if !b.arm { return }
	b.arm = false
	if render.capture_request(&app.r) {
		b.asked = true
		return
	}
	append(&b.shots, Busy_Shot{})   // (another copy is under way: this step saw nothing)
	b.next += 1
}

busy_input_destroy :: proc(b: ^Busy_Input) {
	for s in b.shots { delete(s.rgba) }
	delete(b.shots)
	delete(b.steps)
	b^ = {}
}
