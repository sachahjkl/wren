package browser

// Remote control, the parts that go beyond one command: recording the input a window receives and playing it back
// (a macro for tests), and the snapshot (the document, its boxes and the picture, in one call, to compare two builds).

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "toolkit:platform"
import "wb:base"
import "wb:dom"
import "wb:host"
import "wb:page"
import "wb:remote"

Rec_Event :: struct {
	t_ms: f64,
	ev:   platform.Event,
}

Remote_Recording :: struct {
	on:     bool,
	t0:     i64,   // loop clock, ns
	events: [dynamic]Rec_Event,
}

remote_recording_destroy :: proc(r: ^Remote_Recording) {
	delete(r.events)
	r^ = {}
}

// Every event the window took this frame, real or injected, while a recording runs (main.odin's frame, after the poll).
remote_record_events :: proc(app: ^App, events: []platform.Event) {
	r := &the_remote.rec
	if !r.on || len(events) == 0 { return }
	now := host.now_ns(&app.loop)
	for e in events {
		#partial switch e.kind {
		case .Mouse_Move, .Mouse_Press, .Mouse_Release, .Scroll, .Key_Press, .Key_Release, .Text:
			append(&r.events, Rec_Event{t_ms = f64(now - r.t0) / 1e6, ev = e})
		}
	}
}

@(private = "file")
kind_name :: proc(k: platform.Event_Kind) -> string {
	#partial switch k {
	case .Mouse_Move:    return "mouseMove"
	case .Mouse_Press:   return "mousePress"
	case .Mouse_Release: return "mouseRelease"
	case .Scroll:        return "scroll"
	case .Key_Press:     return "keyPress"
	case .Key_Release:   return "keyRelease"
	case .Text:          return "text"
	}
	return ""
}

@(private = "file")
event_json :: proc(b: ^strings.Builder, re: Rec_Event) {
	e := re.ev
	fmt.sbprintf(b, `{{"t":%.2f,"kind":"%s"`, re.t_ms, kind_name(e.kind))
	switch e.kind {
	case .Mouse_Move:  fmt.sbprintf(b, `,"x":%.1f,"y":%.1f`, e.pos.x, e.pos.y)
	case .Mouse_Press, .Mouse_Release: fmt.sbprintf(b, `,"x":%.1f,"y":%.1f,"button":"%v"`, e.pos.x, e.pos.y, e.button)
	case .Scroll:      fmt.sbprintf(b, `,"x":%.1f,"y":%.1f,"dx":%.3f,"dy":%.3f`, e.pos.x, e.pos.y, e.delta.x, e.delta.y)
	case .Key_Press, .Key_Release: fmt.sbprintf(b, `,"key":"%v"`, e.key)
	case .Text:        strings.write_string(b, `,"text":`); remote.write_json_string(b, fmt.tprintf("%c", e.text))
	case .Pointer_Down, .Pointer_Move, .Pointer_Up, .Pointer_Cancel, .Drop_Enter, .Drop_Over, .Drop: fmt.sbprintf(b, `,"x":%.1f,"y":%.1f`, e.pos.x, e.pos.y)
	case .None, .Mouse_Leave, .Close, .Activate, .Drop_Leave:
	}
	if e.mods != {} { fmt.sbprintf(b, `,"mods":%d`, (.Ctrl in e.mods ? 1 : 0) | (.Shift in e.mods ? 2 : 0) | (.Alt in e.mods ? 4 : 0)) }
	strings.write_byte(b, '}')
}

@(private = "file")
event_from_json :: proc(o: json.Object) -> (re: Rec_Event, ok: bool) {
	kind, _ := remote.param_string(o, "kind")
	re.t_ms, _ = remote.param_float(o, "t")
	e := &re.ev
	x, _ := remote.param_float(o, "x"); y, _ := remote.param_float(o, "y")
	e.pos = {f32(x), f32(y)}
	m, _ := remote.param_int(o, "mods")
	if m & 1 != 0 { e.mods += {.Ctrl} }
	if m & 2 != 0 { e.mods += {.Shift} }
	if m & 4 != 0 { e.mods += {.Alt} }
	switch kind {
	case "mouseMove": e.kind = .Mouse_Move
	case "mousePress", "mouseRelease":
		e.kind = kind == "mousePress" ? .Mouse_Press : .Mouse_Release
		name, _ := remote.param_string(o, "button", "Left")
		for b in platform.Mouse_Button { if fmt.tprintf("%v", b) == name { e.button = b } }
	case "scroll":
		e.kind = .Scroll
		dx, _ := remote.param_float(o, "dx"); dy, _ := remote.param_float(o, "dy")
		e.delta = {f32(dx), f32(dy)}
	case "keyPress", "keyRelease":
		e.kind = kind == "keyPress" ? .Key_Press : .Key_Release
		name, _ := remote.param_string(o, "key")
		found := false
		for k in platform.Key { if fmt.tprintf("%v", k) == name { e.key, found = k, true } }
		if !found { return {}, false }
	case "text":
		e.kind = .Text
		s, _ := remote.param_string(o, "text")
		for ch in s { e.text = ch; break }
	case: return {}, false
	}
	return re, true
}

// Wren.recordInput {action: start|stop|status}: start begins a recording (the events the window receives, from any source,
// with their times); stop ends it and returns them.
m_record :: proc(app: ^App, c: ^Call) -> Reply {
	action, _ := remote.param_string(c.params, "action", "status")
	r := &the_remote.rec
	switch action {
	case "start":
		clear(&r.events)
		r.on, r.t0 = true, host.now_ns(&app.loop)
		return done(`{"recording":true}`)
	case "stop", "status":
		was := r.on
		if action == "stop" { r.on = false }
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, `{{"recording":%v,"count":%d`, r.on, len(r.events))
		if action == "stop" || was && action == "status" && false {
			strings.write_string(&b, `,"events":[`)
			for ev, i in r.events {
				if i > 0 { strings.write_byte(&b, ',') }
				event_json(&b, ev)
			}
			strings.write_byte(&b, ']')
		}
		strings.write_byte(&b, '}')
		return done(strings.to_string(b))
	}
	return fail(remote.ERR_PARAMS, "action: start, stop or status")
}

// Wren.replayInput {events, speed}: the events go in at their recorded times (divided by `speed`); answers when the last is
// in and its frames are drawn.
m_replay :: proc(app: ^App, c: ^Call) -> Reply {
	arr, ok := remote.param_array(c.params, "events")
	if !ok { return fail(remote.ERR_PARAMS, "\"events\": the array Wren.recordInput returned") }
	speed, _ := remote.param_float(c.params, "speed", 1)
	op := op_new(app, c, .Replay, timeout_of(c), "the replay")
	op.speed = max(speed, 0.01)
	op.t0 = host.now_ns(&app.loop)
	// (the whole replay must fit in its time: the deadline is the last event's time, plus what the command allows)
	last := 0.0
	for v in arr {
		o, is_o := v.(json.Object)
		if !is_o { continue }
		if re, good := event_from_json(o); good { append(&op.events, re); last = max(last, re.t_ms) }
	}
	op.deadline += i64(last / op.speed * 1e6)
	app.frames_requested = max(app.frames_requested, 3)
	return Reply{deferred = true}
}

replay_step :: proc(app: ^App, op: ^Remote_Op, now: i64) {
	elapsed := f64(now - op.t0) / 1e6 * op.speed
	for op.idx < len(op.events) && op.events[op.idx].t_ms <= elapsed {
		inject_raw(app, op.events[op.idx].ev)
		op.idx += 1
	}
	app.frames_requested = max(app.frames_requested, 2)
	if op.idx >= len(op.events) {
		if op.until == 0 { op.until = the_remote.frame_no + u64(max(the_remote.cfg.settle_frames, 1)) + 1 }
		if the_remote.frame_no >= op.until { op_finish(op, done(fmt.tprintf(`{{"events":%d}}`, len(op.events)))) }
	}
}

inject_raw :: proc(app: ^App, ev: platform.Event) {
	platform.inject_event(app.win, ev)
	the_remote.inputs += 1
	app.frames_requested = max(app.frames_requested, 4)
}

// Wren.snapshot {path, target, selector, scale}: <path>.png (as Page.captureScreenshot), <path>.html (the document as serialized),
// <path>.json (the page's url, title, size and the box of every element, in CSS pixels from the page's corner).
m_snapshot :: proc(app: ^App, c: ^Call) -> Reply {
	prefix, bad := need_string_extra(c, "path")
	if bad.code != 0 { return bad }
	c.params["path"] = json.String(strings.concatenate({prefix, ".png"}, context.temp_allocator))
	rep := m_capture(app, c)
	if rep.deferred && len(the_remote.ops) > 0 {
		op := the_remote.ops[len(the_remote.ops) - 1]
		if op.kind == .Capture { op.snapshot = strings.clone(prefix) }
	}
	return rep
}

@(private = "file")
need_string_extra :: proc(c: ^Call, key: string) -> (string, Reply) {
	s, ok := remote.param_string(c.params, key)
	if !ok { return "", fail(remote.ERR_PARAMS, fmt.tprintf("parameter %q (a string) is missing", key)) }
	return s, {}
}

// The HTML and the boxes next to a snapshot's picture.
snapshot_files :: proc(app: ^App, t: ^Tab, prefix: string) -> string {
	if t == nil || t.page == nil { return "" }
	html := page.serialize_html(t.page.doc, t.page.doc.root, false)
	if err := os.write_entire_file(strings.concatenate({prefix, ".html"}, context.temp_allocator), transmute([]byte)html); err != nil { return "cannot write the .html" }
	s := f64(page_scale(app))
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"url":%s,"title":%s,"width":%d,"height":%d,"scale":%.3f,"scroll":%.1f,"elements":[`, remote.quote(t.url), remote.quote(t.title), int(app.page_rect.max.x - app.page_rect.min.x), int(app.page_rect.max.y - app.page_rect.min.y), s, f64(t.scroll) / s)
	hs, _ := page.query_all(t.page, "*", 5000)
	first := true
	for h in hs {
		r, ok := element_window_rect(app, t, h)
		if !ok { continue }
		n := dom.get(t.page.doc, h)
		if n == nil { continue }
		id, _ := dom.get_attribute(t.page.doc, h, "id")
		if !first { strings.write_byte(&b, ',') }
		first = false
		fmt.sbprintf(&b, `{{"tag":%s,"id":%s,"x":%.1f,"y":%.1f,"w":%.1f,"h":%.1f}}`, remote.quote(n.name), remote.quote(id), f64(r[0] - app.page_rect.min.x) / s, f64(r[1] - app.page_rect.min.y + t.scroll) / s, f64(r[2]) / s, f64(r[3]) / s)
	}
	strings.write_string(&b, "]}\n")
	if err := os.write_entire_file(strings.concatenate({prefix, ".json"}, context.temp_allocator), transmute([]byte)strings.to_string(b)); err != nil { return "cannot write the .json" }
	return ""
}

_ :: base
