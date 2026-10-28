package page

// Long Animation Frames (long-animation-frame, PerformanceLongAnimationFrameTiming) and the scripts they ran
// (PerformanceScriptTiming), measured natively from the shell's task and render loops — no JavaScript, no polling. A long
// animation frame is a period that monopolised the main thread for 50 ms or more and is a better proxy for user-perceived
// jank than a bare Long Task, because it spans a whole task-plus-render cycle and attributes the scripts inside it.
//
// Wren's model (one window per page, the shell owns the loop) maps the specification's "frame timing info" to a single
// accumulator on the page timeline (Loaf_Frame):
//
//   * loaf_frame_begin  — called when a depth-0 task of the page begins (objects.odin, around the outermost call_guest),
//     once, when no frame is open yet. It records the task start and opens the frame.
//   * loaf_script_begin / loaf_script_end — bracket each depth-0 guest call (a timer, an animation-frame callback, an
//     event listener, a module's top-level script, an idle callback). The caller says what invoked it (Loaf_Invoker) so
//     the PerformanceScriptTiming carries invokerType, invoker, sourceURL and sourceFunctionName. A script that ran at
//     least performance.long_animation_frame_script_min_ms (5 ms) becomes an entry in the frame's scripts list.
//   * loaf_render — called by the shell after it has run the animation-frame callbacks and laid the page out for a frame
//     it is about to present (render.odin), with the time style and layout began. It marks renderStart /
//     styleAndLayoutStart so the entry can separate script time from rendering time.
//   * loaf_frame_end — called when the depth-0 task (and the render it triggered) is finished. When the whole frame took
//     50 ms or more it becomes a PerformanceLongAnimationFrameTiming entry; otherwise the accumulator is reset.
//
// All timestamps are on the page's performance.now() timeline (ms since the time origin); spans are plain milliseconds.
// Script source URLs come from the realm's document (the only script source Wren can attribute without probing the JS
// stack); the finer per-callback function name and character position are left 0 / "" (honest: not known natively).

import "core:strings"
import "wb:host"

// What invoked a depth-0 script, so the PerformanceScriptTiming can name it (the ScriptInvokerType enum of the spec).
Loaf_Invoker :: enum u8 {
	Classic_Script,   // a module's top-level script running (the page's own code)
	Module_Script,
	Event_Listener,   // a DOM event listener (invoker = the event type, e.g. "window.onclick")
	User_Callback,    // a timer, requestAnimationFrame, requestIdleCallback or similar callback
	Resolve_Promise,
	Reject_Promise,
}

@(private)
loaf_invoker_type :: proc(k: Loaf_Invoker) -> string {
	switch k {
	case .Classic_Script:  return "classic-script"
	case .Module_Script:   return "module-script"
	case .Event_Listener:  return "event-listener"
	case .User_Callback:   return "user-callback"
	case .Resolve_Promise: return "resolve-promise"
	case .Reject_Promise:  return "reject-promise"
	}
	return "user-callback"
}

// One script invocation being timed (pushed by loaf_script_begin, closed by loaf_script_end). Spans forced by the script
// (synchronous style / layout from getComputedStyle, getBoundingClientRect...) are attributed here while it is on top.
@(private)
Loaf_Script :: struct {
	kind:        Loaf_Invoker,
	invoker:     string,   // owned: the name of the invoker (event type, callback name) — "" when unknown
	name:        string,   // owned: a human name, used when `invoker` is empty
	source_url:  string,   // owned: the script's source URL (the realm's document URL for the page's own scripts)
	start_ns:    i64,      // loop clock
	exec_ns:     i64,      // when the script actually began executing (loop clock); 0 if same as start
	duration_ms: f64,      // the measured length, filled by loaf_script_end
	forced_style_ms:  f64,
	forced_layout_ms: f64,
}

// The frame being accumulated. A frame is open from the first depth-0 task after idle until the task (and its render)
// finishes. Only one is open at a time (Wren's loop is single-threaded and one window per page).
@(private)
Loaf_Frame :: struct {
	open:          bool,
	start_ns:      i64,         // loop clock: when the task that opened the frame began
	task_ms_sum:   f64,         // the frame's longest task durations are blocking; here the sum is informational
	longest_task_ms: f64,       // the single longest script/task duration (for blockingDuration)
	render_start_ns:  i64,      // loop clock: when the rendering update began (0: no render this frame)
	style_layout_ns:  i64,      // loop clock: when style and layout began (0: none)
	style_ms:      f64,
	layout_ms:     f64,
	first_ui_ns:   i64,         // loop clock: the first UI event of the frame (0: none)
	scripts:       [dynamic]Loaf_Script,   // the scripts run in the frame that were long enough to report
	depth:         int,         // open script-timing scopes (nesting of depth-0 is impossible, but guards re-entry)
	cur:           Loaf_Script, // the script currently being timed (valid when depth > 0)
}

// Whether Long Animation Frames are measured for this page (a window, not a worker, and the pref is non-zero).
@(private)
loaf_enabled :: proc(p: ^Page) -> bool {
	return p.worker == nil && p.web != nil && p.settings.timeline.long_animation_frame_entries > 0
}

// A depth-0 task of the page begins: open the frame if none is open yet. Returns whether this call opened it (the caller
// closes only the frame it opened, so nested loop events do not each end the frame).
loaf_frame_begin :: proc(p: ^Page) -> bool {
	if !loaf_enabled(p) { return false }
	t := tl_of(p)
	if t == nil || t.loaf.open { return false }
	t.loaf = Loaf_Frame{open = true, start_ns = host.now_ns(p.loop)}
	return true
}

// A caller (timer, animation frame, event listener, idle callback, module script) tells the frame what will invoke the
// next depth-0 guest call. Read once by loaf_script_in and reset. `invoker` and `source_url` may be temporary (they are
// cloned when the script is kept). Safe to call when no frame is open (it is simply ignored).
loaf_set_invoker :: proc(p: ^Page, kind: Loaf_Invoker, invoker: string = "", source_url: string = "") {
	p.objects.loaf_kind = kind
	p.objects.loaf_invoker = invoker
	p.objects.loaf_source_url = source_url
}

// Open the script timing for the next depth-0 call, using the invoker the caller set (or a bare user-callback). Resets the
// pending invoker so the next call starts fresh. Returns the start clock (0 when no frame is open), passed to the end.
@(private)
loaf_script_in :: proc(p: ^Page) -> i64 {
	kind := p.objects.loaf_kind
	invoker := p.objects.loaf_invoker
	src := p.objects.loaf_source_url
	if src == "" && p.web != nil { src = p.env.location.href }   // the realm's document URL for the page's own scripts
	p.objects.loaf_kind = .User_Callback
	p.objects.loaf_invoker = ""
	p.objects.loaf_source_url = ""
	return loaf_script_begin(p, kind, invoker, "", src)
}

// Begin timing a depth-0 script of the given kind. `invoker` and `name` name it (copied); `source_url` is where it came
// from (copied). Does nothing when no frame is open. Returns the start clock (0 when not timed), passed back to the end.
loaf_script_begin :: proc(p: ^Page, kind: Loaf_Invoker, invoker: string, name: string, source_url: string) -> i64 {
	t := p.timeline
	if t == nil || !t.loaf.open || t.loaf.depth > 0 { return 0 }
	now := host.now_ns(p.loop)
	t.loaf.depth += 1
	t.loaf.cur = Loaf_Script{
		kind = kind,
		invoker = strings.clone(invoker),
		name = strings.clone(name),
		source_url = strings.clone(source_url),
		start_ns = now,
		exec_ns = now,
	}
	return now
}

// End timing the current depth-0 script (begun by loaf_script_begin returning `begin`). A script at least
// performance.long_animation_frame_script_min_ms long joins the frame's scripts list; its duration feeds blockingDuration.
loaf_script_end :: proc(p: ^Page, begin: i64) {
	if begin == 0 { return }
	t := p.timeline
	if t == nil || !t.loaf.open || t.loaf.depth == 0 { return }
	t.loaf.depth -= 1
	end := host.now_ns(p.loop)
	dur := f64(end - begin) / 1e6
	t.loaf.task_ms_sum += dur
	if dur > t.loaf.longest_task_ms { t.loaf.longest_task_ms = dur }
	s := t.loaf.cur
	t.loaf.cur = {}
	min_ms := p.settings.timeline.loaf_script_min_ms
	if dur < min_ms {
		// too short to report on its own: drop its strings, keep only its duration in the frame totals
		delete(s.invoker); delete(s.name); delete(s.source_url)
		return
	}
	// close the script timing: store the measured length; executionStart is the script start (Wren runs guest code as
	// soon as it is invoked, so there is no compile-then-run gap to report).
	s.exec_ns = begin
	s.duration_ms = dur
	append(&t.loaf.scripts, s)
}

// The shell is about to present a frame it has laid out: mark when the rendering update and its style/layout began, so the
// entry separates script time (before renderStart) from rendering time. `style_layout_now_ns` is the loop clock when style
// and layout began; the current clock is the render start. Does nothing when no frame is open.
loaf_render :: proc(p: ^Page, style_layout_now_ns: i64, style_ms: f64, layout_ms: f64) {
	t := p.timeline
	if t == nil || !t.loaf.open { return }
	if t.loaf.render_start_ns == 0 { t.loaf.render_start_ns = host.now_ns(p.loop) }
	t.loaf.style_layout_ns = style_layout_now_ns
	t.loaf.style_ms += style_ms
	t.loaf.layout_ms += layout_ms
}

// The shell's wrapper for loaf_render: it measured the style and layout of the frame it is about to present (ms) but
// does not hold the page's loop clock. The render began now; style and layout began `style_ms + layout_ms` before that.
// Called from src/browser/page_frame.odin next to timeline_present. Does nothing when no frame is open or no page realm.
timeline_loaf_render :: proc(p: ^Page, style_ms: f64, layout_ms: f64) {
	t := p.timeline
	if t == nil || !t.loaf.open { return }
	now := host.now_ns(p.loop)
	style_layout_ns := now - i64((style_ms + layout_ms) * 1e6)
	loaf_render(p, style_layout_ns, style_ms, layout_ms)
}

// A UI event (a pointer or key event) was dispatched in the current frame: the first one's time is firstUIEventTimestamp.
loaf_note_ui_event :: proc(p: ^Page) {
	t := p.timeline
	if t == nil || !t.loaf.open { return }
	if t.loaf.first_ui_ns == 0 { t.loaf.first_ui_ns = host.now_ns(p.loop) }
}

// The depth-0 task (and the render it triggered) is finished. A frame of 50 ms or more becomes a
// PerformanceLongAnimationFrameTiming entry; a shorter one is discarded. Called only by the caller that opened the frame.
loaf_frame_end :: proc(p: ^Page) {
	t := p.timeline
	if t == nil || !t.loaf.open { return }
	f := t.loaf
	t.loaf = {}
	defer loaf_frame_discard(&f)   // free any script strings not moved into the entry
	if p.closed || p.web == nil { return }
	end_ns := host.now_ns(p.loop)
	dur_ms := f64(end_ns - f.start_ns) / 1e6
	if dur_ms < LONG_TASK_MS { return }   // not a long animation frame

	w := p.web
	to_ms :: proc(w: ^Web_State, clk: i64) -> f64 { return clk > 0 ? max(f64(clk - w.origin_ns) / 1e6, 0) : 0 }

	e := Tl_Entry{
		name = strings.clone("long-animation-frame"),
		start = to_ms(w, f.start_ns),
		duration = dur_ms,
		render_start = to_ms(w, f.render_start_ns),
		style_layout_start = to_ms(w, f.style_layout_ns),
		style_duration = f.style_ms,
		layout_duration = f.layout_ms,
		blocking_duration = loaf_blocking_duration(&f, dur_ms),
		first_ui_event = to_ms(w, f.first_ui_ns),
	}
	if len(f.scripts) > 0 {
		scripts := make([]Tl_Script, len(f.scripts))
		for s, i in f.scripts {
			scripts[i] = Tl_Script{   // (window_attribution is always "self": Wren has one window per page)
				invoker_type = strings.clone(loaf_invoker_type(s.kind)),
				invoker = strings.clone(loaf_script_invoker(s)),
				name = strings.clone("script"),
				start = to_ms(w, s.start_ns),
				duration = s.duration_ms,
				execution_start = to_ms(w, s.exec_ns),
				source_url = strings.clone(s.source_url),
				source_char = 0,
				source_line = 0,
				source_column = 0,
				forced_style = s.forced_style_ms,
				forced_layout = s.forced_layout_ms,
				window_attribution = strings.clone("self"),
			}
		}
		e.scripts = scripts
	}
	timeline_add(p, .Long_Animation_Frame, e)
}

// The invoker string of a script: the explicit invoker, else the name, else the invoker-type.
@(private)
loaf_script_invoker :: proc(s: Loaf_Script) -> string {
	if s.invoker != "" { return s.invoker }
	if s.name != "" { return s.name }
	return loaf_invoker_type(s.kind)
}

// blockingDuration (the spec): the sum, over the frame's task durations (the longest absorbing the render time), of each
// duration above 50 ms. Wren times the frame as one span here, so the frame's own duration is the single task; a frame of
// `dur_ms` contributes dur_ms - 50 when it is long.
@(private)
loaf_blocking_duration :: proc(f: ^Loaf_Frame, dur_ms: f64) -> f64 {
	longest := max(f.longest_task_ms, dur_ms)
	return longest > LONG_TASK_MS ? longest - LONG_TASK_MS : 0
}

@(private)
loaf_frame_discard :: proc(f: ^Loaf_Frame) {
	delete(f.cur.invoker); delete(f.cur.name); delete(f.cur.source_url)
	for &s in f.scripts { delete(s.invoker); delete(s.name); delete(s.source_url) }
	delete(f.scripts)
}
