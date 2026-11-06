package api

// Every call of the channel, one typed procedure each (docs/remote.md says what the browser does with them). Names of methods and
// JSON stop here.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:remote"

////////////////////////////////
// The request

Failure :: struct {
	message: string,
	data:    string,   // an error's data (JSON text)
	code:    int,
}

@(private, thread_local) failure_now: Failure

// Why the last call of this thread failed.
last_failure :: proc() -> Failure { return failure_now }

@(private)
set_failure :: proc(message: string, data := "", code := 0) { failure_now = {message = message, data = data, code = code} }

// A call has failed: what the session's owner asked to happen then (a test ends there: src/e2e).
@(private)
call_failed :: proc(s: ^Session, e: Error, what: string, loc: runtime.Source_Code_Location) {
	if s.on_failure != nil { s.on_failure(s, e, what, loc) }
}

// A request's parameters on their way.
@(private)
Params :: struct {
	b:          strings.Builder,
	timeout_ms: int,   // this call's limit, when it has one of its own
	loc:        runtime.Source_Code_Location,   // who called
}

@(private)
params :: proc(loc: runtime.Source_Code_Location) -> Params {
	p := Params{loc = loc}
	p.b = strings.builder_make(context.temp_allocator)
	strings.write_byte(&p.b, '{')
	return p
}

@(private)
p_key :: proc(p: ^Params, name: string) {
	if strings.builder_len(p.b) > 1 { strings.write_byte(&p.b, ',') }
	base.write_json_string(&p.b, name)
	strings.write_byte(&p.b, ':')
}
@(private) p_str :: proc(p: ^Params, name, v: string) { p_key(p, name); base.write_json_string(&p.b, v) }
@(private) p_int :: proc(p: ^Params, name: string, v: int) { p_key(p, name); fmt.sbprintf(&p.b, "%d", v) }
@(private) p_num :: proc(p: ^Params, name: string, v: f64) { p_key(p, name); fmt.sbprintf(&p.b, "%v", v) }
@(private) p_bool :: proc(p: ^Params, name: string, v: bool) { p_key(p, name); strings.write_string(&p.b, v ? "true" : "false") }
@(private) p_raw :: proc(p: ^Params, name, v: string) { p_key(p, name); strings.write_string(&p.b, v) }
@(private) p_tab :: proc(p: ^Params, s: ^Session) { if s.tab != 0 { p_int(p, "tabId", s.tab) } }
@(private) p_limit :: proc(p: ^Params, limit: time.Duration) {
	if limit > 0 {
		p.timeout_ms = int(time.duration_milliseconds(limit))
		p_int(p, "timeout", p.timeout_ms)
	}
}

// Sends the request (connecting first when the session has not yet), and gives its answer parsed.
@(private)
request :: proc(s: ^Session, method: string, p: ^Params) -> (json.Object, Error) {
	limit := p.timeout_ms
	if limit == 0 && s.timeout_ms > 0 {
		limit = s.timeout_ms
		p_int(p, "timeout", limit)
	}
	if s.window != 0 { p_int(p, "windowId", s.window) }
	if s.idle_ms != 0 { p_int(p, "idleMs", s.idle_ms) }
	strings.write_byte(&p.b, '}')
	o, e := call_raw(s, method, strings.to_string(p.b), limit)
	if e != .None { call_failed(s, e, method, p.loc) }
	return o, e
}

// A request whose parameters are JSON text, for what has no procedure here (`wren ctl raw`, an adapter): a test uses the others.
call_raw :: proc(s: ^Session, method, params_json: string, limit_ms := 0) -> (json.Object, Error) {
	s.result = ""
	if !s.connected {
		if s.name == "" || !connect(&s.conn, s.name, s.connect_wait_ms) {
			set_failure(fmt.tprintf("no Wren answers on %s", remote.pipe_path(s.name)))
			return {}, .No_Server
		}
		s.connected = true
	}
	r, e := call(&s.conn, method, params_json, limit_ms > 0 ? limit_ms + CALL_MARGIN_MS : CALL_WAIT_MS)
	switch e {
	case .None:
	case .Server:
		set_failure(r.message, r.data, r.code)
		return {}, r.code == remote.ERR_TIMEOUT ? .Timeout : .Server
	case .Timeout:
		set_failure(fmt.tprintf("%s: no answer in time", method))
		return {}, .Timeout
	case .Closed, .No_Server, .Script, .Bad_Answer:
		set_failure(fmt.tprintf("%s: the connection to Wren ended", method))
		return {}, .Closed
	}
	s.result = r.result
	v, perr := json.parse(transmute([]byte)r.result, json.Specification.JSON, true, context.temp_allocator)
	o, is_object := v.(json.Object)
	if perr != .None || !is_object { return {}, .None }   // (an answer that is not an object: `result` has it)
	return o, .None
}

// The fields of an answer.
@(private) s_of :: proc(o: json.Object, name: string) -> string { v, _ := remote.param_string(o, name); return v }
@(private) i_of :: proc(o: json.Object, name: string) -> int { v, _ := remote.param_int(o, name); return v }
@(private) f_of :: proc(o: json.Object, name: string) -> f64 { v, _ := remote.param_float(o, name); return v }
@(private) b_of :: proc(o: json.Object, name: string) -> bool { v, _ := remote.param_bool(o, name); return v }

// A rectangle of an answer: [x, y, w, h], window pixels.
Rect :: struct { x, y, w, h: f64 }
Point :: [2]f64

// Its middle.
center :: proc(r: Rect) -> Point { return {f64(int(r.x + r.w / 2)), f64(int(r.y + r.h / 2))} }

@(private)
rect_of :: proc(o: json.Object, name: string) -> (r: Rect, ok: bool) {
	a, has := remote.param_array(o, name)
	if !has || len(a) != 4 { return }
	num :: proc(v: json.Value) -> f64 {
		#partial switch x in v {
		case json.Integer: return f64(x)
		case json.Float:   return f64(x)
		}
		return 0
	}
	return {num(a[0]), num(a[1]), num(a[2]), num(a[3])}, true
}

// A field of the last answer, for a client that prints it.
answer_string :: proc(s: ^Session, name: string, loc := #caller_location) -> (string, bool) {
	v, perr := json.parse(transmute([]byte)s.result, json.Specification.JSON, true, context.temp_allocator)
	o, is_object := v.(json.Object)
	if perr != .None || !is_object { return "", false }
	return remote.param_string(o, name)
}

////////////////////////////////
// The browser

Ping :: struct { protocol: int, version: string, pid: int }

// The browser gives back now what it would when left alone (browser.memory.trim_idle_ms).
memory_trim :: proc(s: ^Session, loc := #caller_location) -> Error {
	p := params(loc)
	_, e := request(s, "Wren.memoryTrim", &p)
	return e
}

// Writes where the private bytes are in the file (the biggest allocations) and the file.heap (the heap blocks by size).
memory_report :: proc(s: ^Session, file: string, loc := #caller_location) -> Error {
	p := params(loc)
	p_str(&p, "file", file)
	_, e := request(s, "Wren.memoryReport", &p)
	return e
}

ping :: proc(s: ^Session, loc := #caller_location) -> (r: Ping, e: Error) {
	p := params(loc)
	o := request(s, "Remote.ping", &p) or_return
	return {i_of(o, "protocol"), s_of(o, "version"), i_of(o, "pid")}, .None
}

Version :: struct { product, revision, toolkit, build: string, protocol: int }

version :: proc(s: ^Session, loc := #caller_location) -> (r: Version, e: Error) {
	p := params(loc)
	o := request(s, "Browser.getVersion", &p) or_return
	return {s_of(o, "product"), s_of(o, "revision"), s_of(o, "toolkit"), s_of(o, "build"), i_of(o, "protocol")}, .None
}

// Asks the browser to close (the answer comes before it does).
browser_close :: proc(s: ^Session, exit_code := 0, loc := #caller_location) -> Error {
	p := params(loc)
	p_int(&p, "exitCode", exit_code)
	_, e := request(s, "Browser.close", &p)
	return e
}

// The browser closes; waits for its process to end, within `limit`. The process's exit code.
quit :: proc(s: ^Session, exit_code := 0, limit := time.Duration(QUIT_WAIT_MS * time.Millisecond), loc := #caller_location) -> (code: int, e: Error) {
	who := ping(s, loc) or_return
	browser_close(s, exit_code, loc) or_return
	close_session(s)
	c, ended := wait_process_exit(who.pid, int(time.duration_milliseconds(limit)))
	if !ended {
		// (what it was doing, read while it still hangs: the failure of an intermittent run is the only look anyone gets)
		stuck, _ := process_stacks(who.pid)
		set_failure(fmt.tprintf("Wren did not end within %v", limit), stuck)
		call_failed(s, .Timeout, "quit", loc)
		return 0, .Timeout
	}
	return c, .None
}
// How long `quit` waits for a Wren to end (ms).
QUIT_WAIT_MS :: 20_000

////////////////////////////////
// Navigation and waiting

// How long a barrier may take before the run is said to have failed.
DEFAULT_DEADLINE :: 60 * time.Second

// What a call that loads something waits for before it answers.
Wait :: enum u8 { None, Load, Idle, Stable, Quiet }

WAIT_NAMES := [Wait]string{.None = "none", .Load = "load", .Idle = "idle", .Stable = "stable", .Quiet = "quiet"}

wait_by_name :: proc(name: string) -> (Wait, bool) {
	for n, w in WAIT_NAMES { if n == name { return w, true } }
	return .None, false
}

@(private)
navigation :: proc(s: ^Session, method: string, p: ^Params, wait: Wait, deadline: time.Duration, loc := #caller_location) -> Error {
	p_tab(p, s)
	p_str(p, "wait", WAIT_NAMES[wait])
	p_limit(p, deadline)
	_, e := request(s, method, p)
	return e
}

navigate :: proc(s: ^Session, url: string, wait := Wait.Load, deadline := DEFAULT_DEADLINE, loc := #caller_location) -> Error {
	p := params(loc)
	p_str(&p, "url", url)
	return navigation(s, "Page.navigate", &p, wait, deadline)
}

reload :: proc(s: ^Session, wait := Wait.Load, ignore_cache := false, deadline := DEFAULT_DEADLINE, loc := #caller_location) -> Error {
	p := params(loc)
	if ignore_cache { p_bool(&p, "ignoreCache", true) }
	return navigation(s, "Page.reload", &p, wait, deadline)
}

go_back :: proc(s: ^Session, wait := Wait.Load, deadline := DEFAULT_DEADLINE, loc := #caller_location) -> Error {
	p := params(loc)
	return navigation(s, "Page.goBack", &p, wait, deadline)
}

go_forward :: proc(s: ^Session, wait := Wait.Load, deadline := DEFAULT_DEADLINE, loc := #caller_location) -> Error {
	p := params(loc)
	return navigation(s, "Page.goForward", &p, wait, deadline)
}

stop_loading :: proc(s: ^Session, loc := #caller_location) -> Error {
	p := params(loc)
	p_tab(&p, s)
	_, e := request(s, "Page.stopLoading", &p)
	return e
}

@(private)
wait_for :: proc(s: ^Session, what: string, p: ^Params, deadline: time.Duration, loc := #caller_location) -> Error {
	p_tab(p, s)
	p_str(p, "for", what)
	p_limit(p, deadline)
	_, e := request(s, "Wren.wait", p)
	return e
}

// The barriers. A deadline only ends a failing run (nothing waits for it to pass): what ran out comes back as .Timeout. 0: the browser's own limit.

// The page has loaded.
wait_load :: proc(s: ^Session, deadline := DEFAULT_DEADLINE, loc := #caller_location) -> Error { p := params(loc); return wait_for(s, "load", &p, deadline) }
// It has loaded and the network has been quiet (Session.idle_ms).
wait_idle :: proc(s: ^Session, deadline := DEFAULT_DEADLINE, loc := #caller_location) -> Error { p := params(loc); return wait_for(s, "idle", &p, deadline) }
// It has loaded and nothing moves any more.
wait_stable :: proc(s: ^Session, deadline := DEFAULT_DEADLINE, loc := #caller_location) -> Error { p := params(loc); return wait_for(s, "stable", &p, deadline) }

// The process has been quiet: `quiet_ms` (0: the default) using at most `max_cpu_ms` (0: the default) of the processor.
wait_quiet :: proc(s: ^Session, quiet_ms := 0, max_cpu_ms := 0.0, deadline := DEFAULT_DEADLINE, loc := #caller_location) -> Error {
	p := params(loc)
	if quiet_ms > 0 { p_int(&p, "quietMs", quiet_ms) }
	if max_cpu_ms > 0 { p_num(&p, "maxCpuMs", max_cpu_ms) }
	return wait_for(s, "quiet", &p, deadline)
}

// An element matches (and with `visible`, shows).
wait_selector :: proc(s: ^Session, selector: string, visible := false, deadline := DEFAULT_DEADLINE, loc := #caller_location) -> Error {
	p := params(loc)
	p_str(&p, "selector", selector)
	p_bool(&p, "visible", visible)
	return wait_for(s, "selector", &p, deadline)
}

// A script's expression, in the page, holds.
wait_js :: proc(s: ^Session, expression: string, deadline := DEFAULT_DEADLINE, loc := #caller_location) -> Error {
	p := params(loc)
	p_str(&p, "expression", expression)
	return wait_for(s, "function", &p, deadline)
}

// `n` more frames have been made (a headless Wren makes them as fast as they are asked for).
wait_frames :: proc(s: ^Session, n := 2, deadline := DEFAULT_DEADLINE, loc := #caller_location) -> Error {
	p := params(loc)
	p_int(&p, "frames", n)
	return wait_for(s, "frames", &p, deadline)
}

////////////////////////////////
// Script and the document

// What a script gave: `kind` is JavaScript's type name; `text` a string's value, else its JSON.
Script_Value :: struct { kind, text: string }

eval_value :: proc(s: ^Session, expression: string, await := false, deadline := DEFAULT_DEADLINE, loc := #caller_location) -> (v: Script_Value, e: Error) {
	p := params(loc)
	p_tab(&p, s)
	p_str(&p, "expression", expression)
	p_bool(&p, "awaitPromise", await)
	p_limit(&p, deadline)
	o := request(s, "Runtime.evaluate", &p) or_return
	if ex, has := remote.param_object(o, "exceptionDetails"); has {
		ob, _ := remote.param_object(ex, "exception")
		d := s_of(ob, "description")
		set_failure(d != "" ? d : s_of(ex, "text"))
		call_failed(s, .Script, expression, loc)
		return {}, .Script
	}
	res, _ := remote.param_object(o, "result")
	v.kind = s_of(res, "type")
	switch v.kind {
	case "undefined":
	case "string": v.text = s_of(res, "value")
	case:
		t, _ := json.marshal(res["value"], {}, context.temp_allocator)
		v.text = string(t)
	}
	return v, .None
}

// The value of a script's expression, as text.
eval :: proc(s: ^Session, expression: string, await := false, deadline := DEFAULT_DEADLINE, loc := #caller_location) -> (string, Error) {
	v, e := eval_value(s, expression, await, deadline, loc)
	return v.text, e
}

// ... as a number (.Bad_Answer: it is not one).
eval_f64 :: proc(s: ^Session, expression: string, loc := #caller_location) -> (f64, Error) {
	t, e := eval(s, expression, loc = loc)
	if e != .None { return 0, e }
	f, ok := strconv.parse_f64(t)
	if !ok { set_failure(fmt.tprintf("%s gave %q, not a number", expression, t))
		call_failed(s, .Bad_Answer, expression, loc)
		return 0, .Bad_Answer }
	return f, .None
}

outer_html :: proc(s: ^Session, selector := "", loc := #caller_location) -> (html: string, e: Error) {
	p := params(loc)
	p_tab(&p, s)
	if selector != "" { p_str(&p, "selector", selector) } else { p_raw(&p, "selector", "null") }
	o := request(s, "DOM.getOuterHTML", &p) or_return
	return s_of(o, "outerHTML"), .None
}

// An element that matched: the beginning of its markup, and its box in CSS pixels from the page's corner, when it has one.
Query_Node :: struct {
	outer_html: string,
	box:        Rect,
	has_box:    bool,
}

// `count`: all that match; `nodes`: the first of them, up to the limit.
Query_Result :: struct {
	count: int,
	nodes: []Query_Node,
}

// The elements that match (`limit` 0: none is described, only counted).
query_all :: proc(s: ^Session, selector: string, limit := 0, loc := #caller_location) -> (r: Query_Result, e: Error) {
	p := params(loc)
	p_tab(&p, s)
	p_str(&p, "selector", selector)
	p_int(&p, "limit", limit)
	o := request(s, "DOM.querySelectorAll", &p) or_return
	a, _ := remote.param_array(o, "nodes")
	r.count = i_of(o, "count")
	r.nodes = make([]Query_Node, len(a), context.temp_allocator)
	for item, i in a {
		x, _ := item.(json.Object)
		box, has := rect_of(x, "box")
		r.nodes[i] = {s_of(x, "outerHTML"), box, has}
	}
	return r, .None
}

// An element's box: in CSS pixels from the page's corner (what getBoundingClientRect says), and in window pixels.
Box_Model :: struct {
	visible: bool,
	box:     Rect,
	window:  Rect,
}

box_model :: proc(s: ^Session, selector: string, loc := #caller_location) -> (r: Box_Model, e: Error) {
	p := params(loc)
	p_tab(&p, s)
	p_str(&p, "selector", selector)
	o := request(s, "DOM.getBoxModel", &p) or_return
	w, _ := remote.param_object(o, "window")
	return {b_of(o, "visible"), {f_of(o, "x"), f_of(o, "y"), f_of(o, "width"), f_of(o, "height")}, {f_of(w, "x"), f_of(w, "y"), f_of(w, "width"), f_of(w, "height")}}, .None
}

Style_Property :: struct { name, value: string }

// An element's computed style: `properties` nil: all of it.
computed_style :: proc(s: ^Session, selector: string, properties: []string = nil, loc := #caller_location) -> (r: []Style_Property, e: Error) {
	p := params(loc)
	p_tab(&p, s)
	p_str(&p, "selector", selector)
	if properties == nil {
		p_raw(&p, "properties", "null")
	} else {
		p_key(&p, "properties")
		strings.write_byte(&p.b, '[')
		for name, i in properties { if i > 0 { strings.write_byte(&p.b, ',') }; base.write_json_string(&p.b, name) }
		strings.write_byte(&p.b, ']')
	}
	o := request(s, "CSS.getComputedStyleForNode", &p) or_return
	style, _ := remote.param_object(o, "computedStyle")
	list := make([dynamic]Style_Property, 0, len(style), context.temp_allocator)
	for name in style { append(&list, Style_Property{name, s_of(style, name)}) }
	return list[:], .None
}

// The value of a property, from what computed_style gave ("": it has none).
style_of :: proc(list: []Style_Property, name: string) -> string {
	for x in list { if x.name == name { return x.value } }
	return ""
}

////////////////////////////////
// Input: Wren's own path (platform.inject_event), never the machine's mouse or keyboard

Button :: enum u8 { Left, Right, Middle, Back, Forward }
BUTTON_NAMES := [Button]string{.Left = "left", .Right = "right", .Middle = "middle", .Back = "back", .Forward = "forward"}

// What a point is measured from: the page's corner in CSS pixels, or the window's in its pixels.
Space :: enum u8 { Page, Window }
@(private) SPACE_NAMES := [Space]string{.Page = "page", .Window = "window"}

// Each answers once the frames that take the input are made.

click_at :: proc(s: ^Session, at: Point, space := Space.Page, button := Button.Left, count := 1, loc := #caller_location) -> Error {
	p := params(loc)
	p_tab(&p, s)
	p_str(&p, "button", BUTTON_NAMES[button])
	p_int(&p, "count", count)
	p_num(&p, "x", at.x)
	p_num(&p, "y", at.y)
	if space == .Window { p_str(&p, "space", "window") }
	_, e := request(s, "Wren.click", &p)
	return e
}

click :: proc(s: ^Session, selector: string, button := Button.Left, count := 1, loc := #caller_location) -> Error {
	p := params(loc)
	p_tab(&p, s)
	p_str(&p, "button", BUTTON_NAMES[button])
	p_int(&p, "count", count)
	p_str(&p, "selector", selector)
	_, e := request(s, "Wren.click", &p)
	return e
}

hover :: proc(s: ^Session, at: Point, space := Space.Page, loc := #caller_location) -> Error {
	p := params(loc)
	p_str(&p, "type", "mouseMoved")
	p_num(&p, "x", at.x)
	p_num(&p, "y", at.y)
	p_str(&p, "space", SPACE_NAMES[space])
	_, e := request(s, "Input.dispatchMouseEvent", &p)
	return e
}

// The wheel, at a point of the page: `notches` positive goes down (one is 100 px).
scroll :: proc(s: ^Session, notches: f64, at := Point{SCROLL_X, SCROLL_Y}, loc := #caller_location) -> Error {
	p := params(loc)
	p_str(&p, "type", "mouseWheel")
	p_num(&p, "x", at.x)
	p_num(&p, "y", at.y)
	p_num(&p, "notches", notches)
	p_str(&p, "space", "page")
	_, e := request(s, "Input.dispatchMouseEvent", &p)
	return e
}
// Where the wheel turns when no point is given.
SCROLL_X :: 200.0
SCROLL_Y :: 200.0

Drag_Options :: struct {
	via:    []Point,   // points passed through (window points may be outside the window: it leaves and comes back)
	steps:  int,       // moves per segment, one per frame (0: DRAG_STEPS)
	space:  Space,
	hold:   bool,      // the button stays down at the end
	resume: bool,      // a drag held before goes on from here
}
DRAG_STEPS :: 8

// A press, moves (one per frame), a release.
drag :: proc(s: ^Session, from, to: Point, o := Drag_Options{}, loc := #caller_location) -> Error {
	p := params(loc)
	p_num(&p, "x", from.x)
	p_num(&p, "y", from.y)
	p_num(&p, "toX", to.x)
	p_num(&p, "toY", to.y)
	p_key(&p, "via")
	strings.write_byte(&p.b, '[')
	for v, i in o.via {
		if i > 0 { strings.write_byte(&p.b, ',') }
		fmt.sbprintf(&p.b, "[%v,%v]", v.x, v.y)
	}
	strings.write_byte(&p.b, ']')
	p_int(&p, "steps", o.steps > 0 ? o.steps : DRAG_STEPS)
	p_str(&p, "space", SPACE_NAMES[o.space])
	p_bool(&p, "hold", o.hold)
	p_bool(&p, "resume", o.resume)
	_, e := request(s, "Wren.drag", &p)
	return e
}

// What another application's drag carries.
Drop_Data :: struct {
	files: []string,   // absolute paths
	text, url, html: string,
}

// Another application's drag over the window: enter, over, then the drop (with `leave`, it leaves instead).
drop :: proc(s: ^Session, at: Point, data: Drop_Data, space := Space.Page, leave := false, loc := #caller_location) -> Error {
	p := params(loc)
	p_num(&p, "x", at.x)
	p_num(&p, "y", at.y)
	p_str(&p, "space", SPACE_NAMES[space])
	p_key(&p, "files")
	strings.write_byte(&p.b, '[')
	for f, i in data.files { if i > 0 { strings.write_byte(&p.b, ',') }; base.write_json_string(&p.b, f) }
	strings.write_byte(&p.b, ']')
	p_str(&p, "text", data.text)
	p_str(&p, "url", data.url)
	p_str(&p, "html", data.html)
	p_bool(&p, "leave", leave)
	_, e := request(s, "Wren.drop", &p)
	return e
}

// Text, as the keyboard's text input.
type_text :: proc(s: ^Session, text: string, loc := #caller_location) -> Error {
	p := params(loc)
	p_str(&p, "text", text)
	_, e := request(s, "Wren.type", &p)
	return e
}

// Keys: "Ctrl+L", "Enter", "Shift+Tab", several separated by spaces.
key :: proc(s: ^Session, keys: string, repeat := 1, loc := #caller_location) -> Error {
	p := params(loc)
	p_str(&p, "keys", keys)
	p_int(&p, "repeat", repeat)
	_, e := request(s, "Wren.key", &p)
	return e
}

////////////////////////////////
// Captures

Shot_Target :: enum u8 { Window, Page, Rect, Selector }

Shot_Options :: struct {
	target:     Shot_Target,
	rect:       Rect,          // of .Rect: window pixels
	selector:   string,        // of .Selector
	scale:      f64,           // 0: 1
	settle:     int,           // frames first (0 with has_settle unset: the browser's default)
	has_settle: bool,
}

Shot :: struct { path: string, width, height: int }

@(private)
p_shot :: proc(p: ^Params, o: Shot_Options) {
	switch o.target {
	case .Window:
	case .Page: p_str(p, "target", "page")
	case .Rect:
		p_str(p, "target", "rect")
		p_key(p, "clip")
		fmt.sbprintf(&p.b, `{{"x":%v,"y":%v,"width":%v,"height":%v}}`, o.rect.x, o.rect.y, o.rect.w, o.rect.h)
	case .Selector:
		p_str(p, "target", "selector")
		p_str(p, "selector", o.selector)
	}
	if o.scale > 0 { p_num(p, "scale", o.scale) }
	if o.has_settle { p_int(p, "settle", o.settle) }
}

// The frame's pixels to a PNG file (`path` absolute): covered, hidden or headless, it is the renderer's real picture.
screenshot :: proc(s: ^Session, path: string, o := Shot_Options{}, loc := #caller_location) -> (r: Shot, e: Error) {
	p := params(loc)
	p_tab(&p, s)
	p_str(&p, "path", path)
	p_shot(&p, o)
	a := request(s, "Page.captureScreenshot", &p) or_return
	return {s_of(a, "path"), i_of(a, "width"), i_of(a, "height")}, .None
}

// A snapshot: `prefix`.png, .html and .json (`path` absolute). `page`: of the page, not the window.
snapshot :: proc(s: ^Session, prefix: string, page := false, loc := #caller_location) -> Error {
	p := params(loc)
	p_tab(&p, s)
	p_str(&p, "path", prefix)
	p_str(&p, "target", page ? "page" : "window")
	_, e := request(s, "Wren.snapshot", &p)
	return e
}

////////////////////////////////
// What the page said, and what it fetched

// `n`: its number among all that the tab's page said.
Console_Line :: struct { level, text: string, n: int }

console :: proc(s: ^Session, since := 0, clear := false, loc := #caller_location) -> (lines: []Console_Line, e: Error) {
	p := params(loc)
	p_tab(&p, s)
	p_int(&p, "since", since)
	p_bool(&p, "clear", clear)
	o := request(s, "Wren.console", &p) or_return
	a, _ := remote.param_array(o, "lines")
	lines = make([]Console_Line, len(a), context.temp_allocator)
	for item, i in a {
		l, _ := item.(json.Object)
		lines[i] = {s_of(l, "level"), s_of(l, "text"), i_of(l, "n")}
	}
	return lines, .None
}

Net_Request :: struct {
	id:     int,
	url, method, mime, error, destination, cache: string,
	status, bytes: int,
	ms:     f64,
	has_ms: bool,     // it has ended
	failed: bool,
	protocol: string,
	start_ms: f64,    // from the first request of the page
	// where it went, in ms from `start_ms` (net.Timing; -1: that step did not happen; has_timing false: nothing went over the network)
	has_timing: bool,
	queued, dns_start, dns_end, connect_start, connect_end, sending, response, done: f64,
}

// When the page got there, in ms from its first request (0: not yet).
Doc_Marks :: struct { interactive, dcl, load, paint, contentful: f64 }

// What a tab's page fetched: `bytes` transferred in all.
Network :: struct {
	bytes:    int,
	requests: []Net_Request,
	doc:      Doc_Marks,
}

network :: proc(s: ^Session, clear := false, loc := #caller_location) -> (r: Network, e: Error) {
	p := params(loc)
	p_tab(&p, s)
	p_bool(&p, "clear", clear)
	o := request(s, "Wren.network", &p) or_return
	a, _ := remote.param_array(o, "requests")
	r.bytes = i_of(o, "bytes")
	r.doc = {f_of(o, "interactive"), f_of(o, "dcl"), f_of(o, "load"), f_of(o, "paint"), f_of(o, "contentful")}
	r.requests = make([]Net_Request, len(a), context.temp_allocator)
	for item, i in a {
		x, _ := item.(json.Object)
		ms, has_ms := remote.param_float(x, "ms")
		r.requests[i] = {
			id = i_of(x, "id"), url = s_of(x, "url"), method = s_of(x, "method"), mime = s_of(x, "mime"), error = s_of(x, "error"), destination = s_of(x, "destination"), cache = s_of(x, "cache"),
			status = i_of(x, "status"), bytes = i_of(x, "bytes"), ms = ms, has_ms = has_ms, failed = b_of(x, "failed"), protocol = s_of(x, "protocol"), start_ms = f_of(x, "startMs"), has_timing = b_of(x, "hasTiming"),
			queued = f_of(x, "queued"), dns_start = f_of(x, "dnsStart"), dns_end = f_of(x, "dnsEnd"), connect_start = f_of(x, "connectStart"), connect_end = f_of(x, "connectEnd"),
			sending = f_of(x, "sending"), response = f_of(x, "response"), done = f_of(x, "done"),
		}
	}
	return r, .None
}

////////////////////////////////
// The numbers of a window

Frame_Gate :: struct { begun, nested, deferred, violations: int, last_violation: string }

// The back/forward cache since start-up: what it kept and gave back, and why pages stayed out of it.
Bfcache_Reason :: struct { reason: string, count: int }
Bfcache_Stats :: struct {
	cached, stores, restores, evictions, refusals, traversals, misses: int,
	reasons: []Bfcache_Reason,
}

// A download of the browser's list (src/browser/download.odin).
Download :: struct {
	name, error: string,
	finished:    bool,      // it has ended, whichever way, and its file is where it will stay
	saved:       bool,      // ... whole
}

// The cursor a window shows (control_cursor): a CSS keyword, and what the system is given for it: its own cursor, one drawn in its style, none.
Cursor_Shown :: struct {
	name:    string,      // the keyword: the page's fallback when `custom`
	custom:  bool,        // an image of the page
	source:  string,      // "system", "drawn", "hidden"
	size:    [2]int,      // its bitmap, device pixels
	hotspot: [2]int,
}

// What a window shows on the screen is cut from (browser.window.fixed_surface: buffers that keep their size while the window resizes: 1:1, clipped by the window).
Surface :: struct {
	fixed:   bool,
	size:    [2]int,      // the window's client area
	buffers: [2]int,      // the swap chain's: 0 for a window with none
	source:  [2]int,      // the region of them the compositor takes
}

// A frame of a drag held: where it drew the edge against the pointer it was built from, and the page's width against its area's (window pixels);
// when its input was read and shown (microseconds), the moves it took, when it was done, how long it waited (ms).
Drag_Sample :: struct {
	pointer, edge, page_width, area_width: f64,
	read_us, shown_us, done_us: i64,
	dt, waited_ms: f64,
	moves: int,
}

// One measure of the time from input to the screen (ms, or refreshes), browser.frame.latency_probe.
Latency_Stat :: struct { p50, p95, max, mean: f64 }

Latency :: struct {
	tearing_supported, tearing: bool,
	samples, frames_shown, frames_shown_from_input, queue_max: int,
	refresh_ms, queue_mean: f64,
	wait, work, present, scan, total, total_refreshes: Latency_Stat,
}

// What a window's screen readers are told, and how (a11y_chrome.odin, a11y_page.odin).
A11y_Stats :: struct {
	updates, refused, last_nodes, nodes: int,                                                     // the chrome's tree
	page_builds, page_patches, page_sends, page_refused, page_nodes, page_written, page_frames: int,   // the page's
	page_verify_failed: int,                                                                     // accessibility.page.verify
	page_fallback, page_verify_diff: string,
}

// Why a frame was made (src/browser/loop_rates.odin). A frame counts once, under the first of its causes in this order.
Frame_Cause :: enum u8 {
	Input,                // events of the window
	Task,                 // a task or a timer of the loop ran and did not say it was quiet
	Page,                 // the document changed, a requestAnimationFrame, a running animation
	Asked,                // frames asked for by name (request_frames)
	Interface_Animation,  // the toolkit has an animation under way, or work left for the next build
	Interface_Wake,       // the timed wake the toolkit asked for is due: a tooltip's delay, a scrollbar fading out, a caret's blink
	Repaint,              // the system asked (uncovered, a loop of the system)
}

Loop_Reason :: struct {
	at_ms:  f64,
	causes: string,
	by:     string,   // the place in the sources of who asked
}

// The loop's own account since it started: what at rest stays still.
Loop_Stats :: struct {
	turns:   int,      // passes of the loop
	sleeps:  int,      // of them, the loop slept first: a wake
	barren:  int,      // wakes after which no window drew
	frames:  int,      // frames made, of every window
	causes:  [Frame_Cause]int,
	reasons: []Loop_Reason,   // the last frames, oldest first
}

// The numbers of a window: every one Wren.stats says. A number anyone needs goes here, filled in src/browser/control.odin.
Stats :: struct {
	pid:                 int,
	fps:                 f64,
	frames_drawn:        int,
	loop:                Loop_Stats,
	frames_presented:    int,
	pending_ops:         int,
	input_events:        int,
	requests_in_flight:  int,
	tabs:                int,
	nodes:               int,
	working_set_bytes:   int,
	private_bytes:       int,
	uptime_ms:           f64,
	frame_period_ms:     f64,
	frame_gate:          Frame_Gate,
	menu_open:           bool,
	devtools:            bool,
	devtools_windows:    int,      // windows of their own the developer tools have, every window's
	front_window:        bool,
	caret_blinking:      bool,
	caret_shown:         bool,
	drop_target:         bool,
	chrome_animating:   bool,      // the interface has an animation under way
	group_name_focused: bool,      // a tab group's name is being edited, its field has the keyboard
	backend:             string,
	drag_image:          string,
	drag_picture:        string,
	prefs_net_applied:   int,
	devtools_room_checks: int,     // frames whose panel width, as taken for its content, was compared with its layout's
	devtools_room_wrong:  int,     // ... and differed
	bfcache:             Bfcache_Stats,
	memory:              Memory_Stats,
	workers_running:     int,      // the process's: dedicated, shared and service workers holding a thread
	shared_workers:      int,      // shared workers alive in the process
	history_restoring:   bool,     // the current tab is still putting back what its history entry showed (history_restore.odin)
	gpu_process_id:      int,      // the process of the pages' WebGL (0: none)
	gpu_process_starts:  int,      // ... how many this browser has started
	chrome_frames:       int,      // frames of the chrome alone, made while a page holds the thread (shell_frames.odin)
	full_frames:         int,      // full frames begun
	paint_frames:        int,      // frames asked for by the window procedure (a loop of the system)
	modal_loops:         int,      // loops of the system the window has been in
	cursor:              Cursor_Shown,
	surface:             Surface,
	panel_surface:       Surface,  // of the developer tools' window
	a11y:                A11y_Stats,
	// The rest takes a look at the process or a walk of a store (control_stats_all; control_stats, what a poll calls, leaves them out):
	// the frames as a person or a measuring script reads them
	frames:              int,
	cpu_ms, cpu_p95_ms, cpu_p99_ms, cpu_max_ms, gpu_ms: f64,
	gpu_measured:        bool,
	frames_requested:    int,
	frames_at_once:      int,      // of the presents since a reset, without waiting for a refresh: a resize, an answer to input, a drag on a variable screen
	frame_gaps:          int,      // the gaps between them
	frame_gap_p50_ms, frame_gap_p95_ms, frame_gap_p99_ms, frame_gap_max_ms: f64,
	ignored_size_moves:  int,
	drag_samples:        []Drag_Sample,   // browser.frame.drag_probe
	has_drag_samples:    bool,
	latency:             Latency,  // browser.frame.latency_probe
	has_latency:         bool,
	// the screen: what the system reports, its top mode, the highest rate the compositor reported lately, the swap chain's, whether frames aim for the top one
	hz, hz_reported, hz_max, hz_now, hz_swap_chain: f64,
	variable_refresh, frame_cap_strict: bool,
	frame_states, frame_state: string,   // the frames by state of the cadence model, and the last one's
	resize_echoes_skipped: int,
	resize_frame_causes: string,   // the frames of resize bursts, by cause
	prefs_cache_applied, prefs_downloads_applied: int,
	layout_items:        int,
	// the process, and what a reset takes away
	cpu_time_ms, cpu_user_ms, cpu_kernel_ms: f64,
	js_first_realm_ms:   f64,      // what the process's first realm held its thread for (0: none yet)
	threads, handles, gdi_objects, user_objects: int,
	cookies, storage_sites, cache_entries, history_visits, closed_tabs, downloads_active, checkpoints: int,
}

// Where the private bytes are: the system's view of the process (heaps, private pages outside them), and what each store of the browser says it holds.
Memory_Stats :: struct {
	heap_allocated, heap_committed:  int,   // the process heaps: blocks in use, pages they hold
	vm_rw, vm_exec:                  int,   // private committed pages, by kind
	wasm_modules, wasm_code_bytes:   int,   // compiled modules kept
	wasm_instances:                  int,   // instances alive: pages, workers
	wasm_compiles:                   int,   // modules compiled in this process
	wasm_shipped_hits, wasm_shipped_refused: int,   // modules taken from the code in the program; that code refused
	js_cache_entries, js_cache_bytes: int,  // bytecode in memory
	image_entries, image_bytes:      int,   // decoded images kept
	font_entries, font_bytes:        int,   // decoded web fonts
	http_resident_bytes:             int,   // bodies the HTTP cache holds in memory
	gpu_images, gpu_glyphs, gpu_targets, gpu_outlines: int,
	pages_bytes, bfcache_bytes:      int,   // what the pages of the tabs hold, what the kept ones are counted for (page.memory_held)
	pictures_bytes:                  int,   // display lists the compositor keeps
	trims:                           int,   // how many times the browser gave memory back
}

stats :: proc(s: ^Session, reset_latency := false, reset_frames := false, loc := #caller_location) -> (r: Stats, e: Error) {
	p := params(loc)
	p_bool(&p, "resetLatency", reset_latency)
	p_bool(&p, "resetFrames", reset_frames)
	o := request(s, "Wren.stats", &p) or_return
	g, _ := remote.param_object(o, "frameGate")
	drag_samples, has_samples := remote.param_array(o, "dragSamples")
	samples := make([]Drag_Sample, len(drag_samples), context.temp_allocator)
	for item, i in drag_samples {
		x, _ := item.(json.Array)
		if len(x) != DRAG_SAMPLE_COLUMNS { continue }
		num :: proc(v: json.Value) -> f64 {
			#partial switch n in v {
			case json.Integer: return f64(n)
			case json.Float:   return f64(n)
			}
			return 0
		}
		samples[i] = {
			read_us = i64(num(x[0])), shown_us = i64(num(x[1])), pointer = num(x[2]), edge = num(x[3]), dt = num(x[4]), moves = int(num(x[5])), done_us = i64(num(x[6])),
			waited_ms = num(x[7]), page_width = num(x[8]), area_width = num(x[9]),
		}
	}
	la, has_latency := remote.param_object(o, "latency")
	lat :: proc(o: json.Object, name: string) -> Latency_Stat {
		x, _ := remote.param_object(o, name)
		return {f_of(x, "p50"), f_of(x, "p95"), f_of(x, "max"), f_of(x, "mean")}
	}
	bf, _ := remote.param_object(o, "bfcache")
	mem, _ := remote.param_object(o, "memory")
	why, _ := remote.param_object(bf, "reasons")
	reasons := make([dynamic]Bfcache_Reason, 0, len(why), context.temp_allocator)
	for k in why { append(&reasons, Bfcache_Reason{k, i_of(why, k)}) }
	cur, _ := remote.param_object(o, "cursor")
	lo, _ := remote.param_object(o, "loop")
	lc, _ := remote.param_object(lo, "causes")
	loop := Loop_Stats{turns = i_of(lo, "turns"), sleeps = i_of(lo, "sleeps"), barren = i_of(lo, "barren"), frames = i_of(lo, "frames")}
	for c in Frame_Cause { loop.causes[c] = i_of(lc, fmt.tprint(c)) }
	if kept, ok := remote.param_array(lo, "reasons"); ok {
		list := make([]Loop_Reason, len(kept), context.temp_allocator)
		for k, i in kept {
			e, _ := k.(json.Object)
			list[i] = {at_ms = f_of(e, "atMs"), causes = s_of(e, "causes"), by = s_of(e, "by")}
		}
		loop.reasons = list
	}
	size_in :: proc(o: json.Object, name: string) -> (v: [2]int) {
		if a, ok := remote.param_array(o, name); ok && len(a) == 2 {
			x, _ := a[0].(json.Integer)
			y, _ := a[1].(json.Integer)
			v = {int(x), int(y)}
		}
		return
	}
	surface_of :: proc(o: json.Object, name: string) -> Surface {
		x, _ := remote.param_object(o, name)
		return {fixed = b_of(x, "fixed"), size = size_in(x, "size"), buffers = size_in(x, "buffers"), source = size_in(x, "source")}
	}
	return {
		pid = i_of(o, "pid"), fps = f_of(o, "fps"), frames_drawn = i_of(o, "framesDrawn"), loop = loop, frames_presented = i_of(o, "framesPresented"),
		pending_ops = i_of(o, "pendingOps"), input_events = i_of(o, "inputEvents"), requests_in_flight = i_of(o, "requestsInFlight"),
		tabs = i_of(o, "tabs"), nodes = i_of(o, "nodes"), working_set_bytes = i_of(o, "workingSetBytes"), private_bytes = i_of(o, "privateBytes"),
		uptime_ms = f_of(o, "uptimeMs"), frame_period_ms = f_of(o, "framePeriodMs"),
		frame_gate = {i_of(g, "begun"), i_of(g, "nested"), i_of(g, "deferred"), i_of(g, "violations"), s_of(g, "lastViolation")},
		menu_open = b_of(o, "menuOpen"), devtools = b_of(o, "devtools"), front_window = b_of(o, "frontWindow"),
		caret_blinking = b_of(o, "caretBlinking"), caret_shown = b_of(o, "caretShown"), drop_target = b_of(o, "dropTarget"),
		chrome_animating = b_of(o, "chromeAnimating"), group_name_focused = b_of(o, "groupNameFocused"), backend = s_of(o, "backend"), drag_image = s_of(o, "dragImage"), drag_picture = s_of(o, "dragPicture"),
		prefs_net_applied = i_of(o, "prefsNetApplied"), devtools_room_checks = i_of(o, "devtoolsRoomChecks"), devtools_room_wrong = i_of(o, "devtoolsRoomWrong"),
		memory = {
			heap_allocated = i_of(mem, "heapAllocated"), heap_committed = i_of(mem, "heapCommitted"), vm_rw = i_of(mem, "vmRw"), vm_exec = i_of(mem, "vmExec"),
			wasm_modules = i_of(mem, "wasmModules"), wasm_code_bytes = i_of(mem, "wasmCodeBytes"), wasm_instances = i_of(mem, "wasmInstances"),
			wasm_compiles = i_of(mem, "wasmCompiles"), wasm_shipped_hits = i_of(mem, "wasmShippedHits"), wasm_shipped_refused = i_of(mem, "wasmShippedRefused"),
			js_cache_entries = i_of(mem, "jsCacheEntries"), js_cache_bytes = i_of(mem, "jsCacheBytes"), image_entries = i_of(mem, "imageEntries"), image_bytes = i_of(mem, "imageBytes"),
			font_entries = i_of(mem, "fontEntries"), font_bytes = i_of(mem, "fontBytes"), http_resident_bytes = i_of(mem, "httpResidentBytes"),
			gpu_images = i_of(mem, "gpuImages"), gpu_glyphs = i_of(mem, "gpuGlyphs"), gpu_targets = i_of(mem, "gpuTargets"), gpu_outlines = i_of(mem, "gpuOutlines"), pages_bytes = i_of(mem, "pagesBytes"), bfcache_bytes = i_of(mem, "bfcacheBytes"), pictures_bytes = i_of(mem, "picturesBytes"), trims = i_of(mem, "trims"),
		},
		bfcache = {
			cached = i_of(bf, "cached"), stores = i_of(bf, "stores"), restores = i_of(bf, "restores"), evictions = i_of(bf, "evictions"),
			refusals = i_of(bf, "refusals"), traversals = i_of(bf, "traversals"), misses = i_of(bf, "misses"), reasons = reasons[:],
		},
		workers_running = i_of(o, "workersRunning"), shared_workers = i_of(o, "sharedWorkers"), history_restoring = b_of(o, "historyRestoring"),
		gpu_process_id = i_of(o, "gpuProcessId"), gpu_process_starts = i_of(o, "gpuProcessStarts"), chrome_frames = i_of(o, "chromeFrames"), full_frames = i_of(o, "fullFrames"),
		paint_frames = i_of(o, "paintFrames"), modal_loops = i_of(o, "modalLoops"),
		cursor = {name = s_of(cur, "name"), custom = b_of(cur, "custom"), source = s_of(cur, "source"), size = size_in(cur, "size"), hotspot = size_in(cur, "hotspot")},
		surface = surface_of(o, "surface"), panel_surface = surface_of(o, "panelSurface"), devtools_windows = i_of(o, "devtoolsWindows"),
		a11y = {
			updates = i_of(o, "a11yUpdates"), refused = i_of(o, "a11yRefused"), last_nodes = i_of(o, "a11yLastNodes"), nodes = i_of(o, "a11yNodes"),
			page_builds = i_of(o, "a11yPageBuilds"), page_patches = i_of(o, "a11yPagePatches"), page_sends = i_of(o, "a11yPageSends"), page_refused = i_of(o, "a11yPageRefused"),
			page_nodes = i_of(o, "a11yPageNodes"), page_written = i_of(o, "a11yPageWritten"), page_frames = i_of(o, "a11yPageFrames"), page_verify_failed = i_of(o, "a11yPageVerifyFailed"),
			page_fallback = s_of(o, "a11yPageFallback"), page_verify_diff = s_of(o, "a11yPageVerifyDiff"),
		},
		frames = i_of(o, "frames"), cpu_ms = f_of(o, "cpuMs"), cpu_p95_ms = f_of(o, "cpuP95Ms"), cpu_p99_ms = f_of(o, "cpuP99Ms"), cpu_max_ms = f_of(o, "cpuMaxMs"), gpu_ms = f_of(o, "gpuMs"), gpu_measured = b_of(o, "gpuMeasured"),
		frames_requested = i_of(o, "framesRequested"), frames_at_once = i_of(o, "framesAtOnce"), frame_gaps = i_of(o, "frameGaps"),
		frame_gap_p50_ms = f_of(o, "frameGapP50Ms"), frame_gap_p95_ms = f_of(o, "frameGapP95Ms"), frame_gap_p99_ms = f_of(o, "frameGapP99Ms"), frame_gap_max_ms = f_of(o, "frameGapMaxMs"),
		ignored_size_moves = i_of(o, "ignoredSizeMoves"), drag_samples = samples, has_drag_samples = has_samples,
		latency = {
			tearing_supported = b_of(la, "tearingSupported"), tearing = b_of(la, "tearing"), samples = i_of(la, "samples"), refresh_ms = f_of(la, "refreshMs"),
			frames_shown = i_of(la, "framesShown"), frames_shown_from_input = i_of(la, "framesShownFromInput"), queue_mean = f_of(la, "queueMean"), queue_max = i_of(la, "queueMax"),
			wait = lat(la, "waitMs"), work = lat(la, "workMs"), present = lat(la, "presentMs"), scan = lat(la, "scanMs"), total = lat(la, "totalMs"), total_refreshes = lat(la, "totalRefreshes"),
		},
		has_latency = has_latency,
		hz = f_of(o, "hz"), hz_reported = f_of(o, "hzReported"), hz_max = f_of(o, "hzMax"), hz_now = f_of(o, "hzNow"), hz_swap_chain = f_of(o, "hzSwapChain"),
		variable_refresh = b_of(o, "variableRefresh"), frame_cap_strict = b_of(o, "frameCapStrict"), frame_states = s_of(o, "frameStates"), frame_state = s_of(o, "frameState"),
		resize_echoes_skipped = i_of(o, "resizeEchoesSkipped"), resize_frame_causes = s_of(o, "resizeFrameCauses"),
		prefs_cache_applied = i_of(o, "prefsCacheApplied"), prefs_downloads_applied = i_of(o, "prefsDownloadsApplied"), layout_items = i_of(o, "layoutItems"),
		cpu_time_ms = f_of(o, "cpuTimeMs"), cpu_user_ms = f_of(o, "cpuUserMs"), cpu_kernel_ms = f_of(o, "cpuKernelMs"), js_first_realm_ms = f_of(o, "jsFirstRealmMs"),
		threads = i_of(o, "threads"), handles = i_of(o, "handles"), gdi_objects = i_of(o, "gdiObjects"), user_objects = i_of(o, "userObjects"),
		cookies = i_of(o, "cookies"), storage_sites = i_of(o, "storageSites"), cache_entries = i_of(o, "cacheEntries"), history_visits = i_of(o, "historyVisits"), closed_tabs = i_of(o, "closedTabs"),
		downloads_active = i_of(o, "downloadsActive"), checkpoints = i_of(o, "checkpoints"),
	}, .None
}
// The columns of a drag sample on the channel (the array is what the measuring scripts read).
DRAG_SAMPLE_COLUMNS :: 10

////////////////////////////////
// Preferences

// Each gives the preference's value as text.

pref_get :: proc(s: ^Session, name: string, loc := #caller_location) -> (text: string, e: Error) {
	p := params(loc)
	p_str(&p, "name", name)
	o := request(s, "Wren.getPref", &p) or_return
	return s_of(o, "text"), .None
}

// As the user sets it. `override`: above what the user sets, as the command line's --pref.
pref_set :: proc(s: ^Session, name, value: string, override := false, loc := #caller_location) -> (text: string, e: Error) {
	p := params(loc)
	p_str(&p, "name", name)
	p_str(&p, "value", value)
	p_bool(&p, "override", override)
	o := request(s, "Wren.setPref", &p) or_return
	return s_of(o, "text"), .None
}

pref_reset :: proc(s: ^Session, name: string, loc := #caller_location) -> (text: string, e: Error) {
	p := params(loc)
	p_str(&p, "name", name)
	o := request(s, "Wren.resetPref", &p) or_return
	return s_of(o, "text"), .None
}

// Every preference back; how many were.
pref_reset_all :: proc(s: ^Session, loc := #caller_location) -> (restored: int, e: Error) {
	p := params(loc)
	p_bool(&p, "all", true)
	o := request(s, "Wren.resetPref", &p) or_return
	return i_of(o, "restored"), .None
}

// A preference's value in its own type (nil on a client when the channel gave none).
Pref_Value :: union { bool, i64, f64, string }

// `source`: which layer set it (default, user, command_line...).
Pref :: struct {
	name, text, default_text, source: string,
	value:           Pref_Value,
	locked, restart: bool,
}

pref_list :: proc(s: ^Session, prefix := "", loc := #caller_location) -> (prefs: []Pref, e: Error) {
	p := params(loc)
	p_str(&p, "prefix", prefix)
	o := request(s, "Wren.listPrefs", &p) or_return
	a, _ := remote.param_array(o, "prefs")
	prefs = make([]Pref, len(a), context.temp_allocator)
	for item, i in a {
		x, _ := item.(json.Object)
		v: Pref_Value
		#partial switch y in x["value"] {
		case json.Boolean: v = bool(y)
		case json.Integer: v = i64(y)
		case json.Float:   v = f64(y)
		case json.String:  v = string(y)
		}
		prefs[i] = {name = s_of(x, "name"), text = s_of(x, "text"), default_text = s_of(x, "default"), source = s_of(x, "source"), value = v, locked = b_of(x, "locked"), restart = b_of(x, "restart")}
	}
	return prefs, .None
}

////////////////////////////////
// Tabs

Tab :: struct {
	id, window, group: int,
	title, url:        string,
	active, loading, pinned, playing, audible, muted: bool,
	group_name, group_color: string,
	group_collapsed:   bool,
	rect:              Rect,   // where the last frame drew it in the tab bar
	has_rect:          bool,
}

Tab_Group :: struct {
	id, window: int,
	name, color: string,
	collapsed:  bool,
	rect:       Rect,
	has_rect:   bool,
}

Targets :: struct { tabs: []Tab, groups: []Tab_Group }

// Every window's tabs and tab groups.
targets :: proc(s: ^Session, loc := #caller_location) -> (r: Targets, e: Error) {
	p := params(loc)
	o := request(s, "Target.getTargets", &p) or_return
	infos, _ := remote.param_array(o, "targetInfos")
	r.tabs = make([]Tab, len(infos), context.temp_allocator)
	for item, i in infos {
		x, _ := item.(json.Object)
		rect, has_rect := rect_of(x, "rect")
		r.tabs[i] = {
			id = i_of(x, "targetId"), window = i_of(x, "windowId"), group = i_of(x, "group"), title = s_of(x, "title"), url = s_of(x, "url"),
			active = b_of(x, "active"), loading = b_of(x, "loading"), pinned = b_of(x, "pinned"), playing = b_of(x, "playing"), audible = b_of(x, "audible"), muted = b_of(x, "muted"),
			group_name = s_of(x, "groupName"), group_color = s_of(x, "groupColor"), group_collapsed = b_of(x, "groupCollapsed"), rect = rect, has_rect = has_rect,
		}
	}
	groups, _ := remote.param_array(o, "tabGroups")
	r.groups = make([]Tab_Group, len(groups), context.temp_allocator)
	for item, i in groups {
		x, _ := item.(json.Object)
		rect, has_rect := rect_of(x, "rect")
		r.groups[i] = {id = i_of(x, "id"), window = i_of(x, "windowId"), name = s_of(x, "name"), color = s_of(x, "color"), collapsed = b_of(x, "collapsed"), rect = rect, has_rect = has_rect}
	}
	return r, .None
}

// A new tab; its id. The window's current tab unless `background`.
new_tab :: proc(s: ^Session, url := "", wait := Wait.None, background := false, deadline := DEFAULT_DEADLINE, loc := #caller_location) -> (id: int, e: Error) {
	p := params(loc)
	p_str(&p, "url", url)
	p_str(&p, "wait", WAIT_NAMES[wait])
	if background { p_bool(&p, "background", true) }
	p_limit(&p, deadline)
	o := request(s, "Target.createTarget", &p) or_return
	return i_of(o, "targetId"), .None
}

activate_tab :: proc(s: ^Session, id: int, loc := #caller_location) -> Error {
	p := params(loc)
	p_int(&p, "targetId", id)
	_, e := request(s, "Target.activateTarget", &p)
	return e
}

close_tab :: proc(s: ^Session, id: int, loc := #caller_location) -> Error {
	p := params(loc)
	p_int(&p, "targetId", id)
	_, e := request(s, "Target.closeTarget", &p)
	return e
}

// The tab goes to window `to` (at `index`, -1: the end) with its page as it is; the window it is in then.
move_tab :: proc(s: ^Session, id, to: int, index := -1, loc := #caller_location) -> (window: int, e: Error) {
	p := params(loc)
	p_int(&p, "targetId", id)
	p_int(&p, "to", to)
	p_int(&p, "index", index)
	o := request(s, "Target.moveTarget", &p) or_return
	return i_of(o, "windowId"), .None
}

// The tab goes to a new window of its own; that window's id.
move_tab_to_new_window :: proc(s: ^Session, id: int, index := -1, loc := #caller_location) -> (window: int, e: Error) {
	p := params(loc)
	p_int(&p, "targetId", id)
	p_str(&p, "to", "new")
	p_int(&p, "index", index)
	o := request(s, "Target.moveTarget", &p) or_return
	return i_of(o, "windowId"), .None
}

////////////////////////////////
// Windows

// The developer tools of a window.
Devtools_State :: struct {
	visible, detached: bool,
	has_window:        bool,   // they have a window of their own right now (a headless Wren's has no window of the system: hwnd 0)
	hwnd:              int,
	dock, panel, title: string,
}

Window :: struct {
	id, tabs, current_tab: int,
	front, headless:   bool,
	hwnd:              int,      // 0 where there is no window of the system
	left, top, width, height: int,
	client_left, client_top:  int,
	state:             string,   // normal, minimized, maximized, fullscreen
	dpi_scale:         f64,
	devtools:          Devtools_State,
	dropping:          bool,     // a tab is carried over its tabs
	drop_index, drop_group: int,
	drop_pinned:       bool,
	drop_mark:         f64,
}

windows :: proc(s: ^Session, loc := #caller_location) -> (r: []Window, e: Error) {
	p := params(loc)
	o := request(s, "Browser.getWindows", &p) or_return
	a, _ := remote.param_array(o, "windows")
	r = make([]Window, len(a), context.temp_allocator)
	for item, i in a {
		x, _ := item.(json.Object)
		d, _ := remote.param_object(x, "devtools")
		_, own := d["hwnd"]
		drop, dropping := remote.param_object(x, "drop")
		r[i] = {
			id = i_of(x, "windowId"), tabs = i_of(x, "tabs"), current_tab = i_of(x, "currentTabId"), front = b_of(x, "front"), headless = b_of(x, "headless"), hwnd = i_of(x, "hwnd"),
			left = i_of(x, "left"), top = i_of(x, "top"), width = i_of(x, "width"), height = i_of(x, "height"), client_left = i_of(x, "clientLeft"), client_top = i_of(x, "clientTop"),
			state = s_of(x, "windowState"), dpi_scale = f_of(x, "dpiScale"),
			devtools = {visible = b_of(d, "visible"), detached = b_of(d, "detached"), has_window = own, hwnd = i_of(d, "hwnd"), dock = s_of(d, "dock"), panel = s_of(d, "panel"), title = s_of(d, "title")},
			dropping = dropping, drop_index = i_of(drop, "index"), drop_group = i_of(drop, "group"), drop_pinned = b_of(drop, "pinned"), drop_mark = f_of(drop, "mark"),
		}
	}
	return r, .None
}

// A row of the address bar's list: its address ("" when it is what was typed), where it is, the cross that removes it (a row of the history).
Urlbar_Row :: struct {
	url:         string,
	rect, cross: Rect,
	has_cross:   bool,
}

// The address bar of a window, in window pixels.
Urlbar :: struct {
	open:  bool,
	text:  string,   // what the field holds
	field: Rect,
	rows:  []Urlbar_Row,
}

// The one with this id, from a list `windows` gave.
window_with_id :: proc(list: []Window, id: int) -> (Window, bool) {
	for w in list { if w.id == id { return w, true } }
	return {}, false
}

Bounds :: struct {
	window:                   int,
	left, top, width, height: int,      // width and height: the client area, in pixels
	outer_width, outer_height: int,
	state:                    string,
	dpi_scale, ui_scale, page_scale: f64,
	headless, visible:        bool,
	page_rect:                Rect,     // the page's area in the last frame
	page_prep:                string,   // what was prepared for it: none, hold, ready (page_frame.odin)
}

@(private)
bounds_of :: proc(o: json.Object) -> Bounds {
	pr, _ := rect_of(o, "pageRect")
	return {
		window = i_of(o, "windowId"), left = i_of(o, "left"), top = i_of(o, "top"), width = i_of(o, "width"), height = i_of(o, "height"),
		outer_width = i_of(o, "outerWidth"), outer_height = i_of(o, "outerHeight"), state = s_of(o, "windowState"),
		dpi_scale = f_of(o, "dpiScale"), ui_scale = f_of(o, "uiScale"), page_scale = f_of(o, "pageScale"), headless = b_of(o, "headless"), visible = b_of(o, "visible"), page_rect = pr, page_prep = s_of(o, "pagePrep"),
	}
}

window_bounds :: proc(s: ^Session, loc := #caller_location) -> (b: Bounds, e: Error) {
	p := params(loc)
	o := request(s, "Browser.getWindowBounds", &p) or_return
	return bounds_of(o), .None
}

// What to change of a window (Maybe: what is left out stays).
Window_Change :: struct {
	size:  Maybe([2]int),   // the client area, in pixels
	pos:   Maybe([2]int),
	state: string,          // normal, minimized, maximized, fullscreen; "": unchanged
	dpi:   int,             // as if moved to a monitor of that scale (96 = 100 %); 0: unchanged
}

set_window :: proc(s: ^Session, c: Window_Change, loc := #caller_location) -> (b: Bounds, e: Error) {
	p := params(loc)
	if size, ok := c.size.?; ok { p_int(&p, "width", size.x); p_int(&p, "height", size.y) }
	if pos, ok := c.pos.?; ok { p_int(&p, "left", pos.x); p_int(&p, "top", pos.y) }
	if c.state != "" { p_str(&p, "windowState", c.state) }
	if c.dpi != 0 { p_int(&p, "dpi", c.dpi) }
	o := request(s, "Browser.setWindowBounds", &p) or_return
	return bounds_of(o), .None
}

// The window becomes the front one (never the machine's: nothing takes the system's focus).
bring_to_front :: proc(s: ^Session, loc := #caller_location) -> Error {
	p := params(loc)
	_, e := request(s, "Browser.activateWindow", &p)
	return e
}

close_window :: proc(s: ^Session, loc := #caller_location) -> Error {
	p := params(loc)
	_, e := request(s, "Browser.closeWindow", &p)
	return e
}

////////////////////////////////
// State: reset, checkpoints

Reset_Report :: struct {
	closed_tabs, cookies, sites, cache_entries, history_visits, prefs_restored, cancelled_ops: int,
	window_restored: bool,
	tab:  int,   // the tab a reset left (0: it kept the tabs and has none to say)
	tabs: int,   // the tabs a checkpoint's restore opened
}

@(private)
reset_of :: proc(o: json.Object) -> Reset_Report {
	return {i_of(o, "closedTabs"), i_of(o, "cookies"), i_of(o, "sites"), i_of(o, "cacheEntries"), i_of(o, "historyVisits"), i_of(o, "prefsRestored"), i_of(o, "cancelledOps"), b_of(o, "windowRestored"), i_of(o, "tabId"), i_of(o, "tabs")}
}

// Back to the state of the start. `keep`: "tabs,data,prefs,window,history", what stays.
reset :: proc(s: ^Session, keep := "", url := "", wait := Wait.Load, loc := #caller_location) -> (r: Reset_Report, e: Error) {
	p := params(loc)
	p_str(&p, "wait", WAIT_NAMES[wait])
	if keep != "" { p_str(&p, "keep", keep) }
	if url != "" { p_str(&p, "url", url) }
	o := request(s, "Wren.reset", &p) or_return
	return reset_of(o), .None
}

Checkpoint :: struct { name: string, tabs, cookies, storage_origins: int }

checkpoint_save :: proc(s: ^Session, name: string, loc := #caller_location) -> (r: Checkpoint, e: Error) {
	p := params(loc)
	p_str(&p, "action", "save")
	p_str(&p, "name", name)
	o := request(s, "Wren.checkpoint", &p) or_return
	return {name, i_of(o, "tabs"), i_of(o, "cookies"), i_of(o, "storageOrigins")}, .None
}

checkpoint_restore :: proc(s: ^Session, name: string, wait := Wait.Load, loc := #caller_location) -> (r: Reset_Report, e: Error) {
	p := params(loc)
	p_str(&p, "action", "restore")
	p_str(&p, "name", name)
	p_str(&p, "wait", WAIT_NAMES[wait])
	o := request(s, "Wren.checkpoint", &p) or_return
	return reset_of(o), .None
}

checkpoint_delete :: proc(s: ^Session, name: string, loc := #caller_location) -> Error {
	p := params(loc)
	p_str(&p, "action", "delete")
	p_str(&p, "name", name)
	_, e := request(s, "Wren.checkpoint", &p)
	return e
}

checkpoint_list :: proc(s: ^Session, loc := #caller_location) -> (r: []Checkpoint, e: Error) {
	p := params(loc)
	p_str(&p, "action", "list")
	o := request(s, "Wren.checkpoint", &p) or_return
	a, _ := remote.param_array(o, "checkpoints")
	r = make([]Checkpoint, len(a), context.temp_allocator)
	for item, i in a {
		x, _ := item.(json.Object)
		r[i] = {s_of(x, "name"), i_of(x, "tabs"), i_of(x, "cookies"), i_of(x, "storageOrigins")}
	}
	return r, .None
}

////////////////////////////////
// Commands of the interface

Command :: struct { name, title, category, shortcut: string, enabled: bool }

commands :: proc(s: ^Session, loc := #caller_location) -> (r: []Command, e: Error) {
	p := params(loc)
	o := request(s, "Wren.listCommands", &p) or_return
	a, _ := remote.param_array(o, "commands")
	r = make([]Command, len(a), context.temp_allocator)
	for item, i in a {
		x, _ := item.(json.Object)
		r[i] = {s_of(x, "name"), s_of(x, "title"), s_of(x, "category"), s_of(x, "shortcut"), b_of(x, "enabled")}
	}
	return r, .None
}

// A command of the interface, by name (tab.pin, window.new...).
run_command :: proc(s: ^Session, name: string, loc := #caller_location) -> Error {
	p := params(loc)
	p_str(&p, "name", name)
	_, e := request(s, "Wren.runCommand", &p)
	return e
}

// The developer tools: `panel` console, elements, network, none; `dock` "": as they are, window: a window of their own.
open_devtools :: proc(s: ^Session, panel := "console", dock := "", loc := #caller_location) -> Error {
	p := params(loc)
	p_str(&p, "panel", panel)
	p_str(&p, "dock", dock)
	_, e := request(s, "Wren.openDevTools", &p)
	return e
}

open_setup :: proc(s: ^Session, loc := #caller_location) -> Error {
	p := params(loc)
	_, e := request(s, "Wren.openSetup", &p)
	return e
}

// The Setup dialog as the last frame showed it, and what happens in it: its buttons in window pixels.
Setup_State :: struct {
	open, known, confirm_uninstall: bool,
	busy:                           int,      // jobs out: 0 once what was asked for has been done, and after the start, once it has decided whether to offer it
	note:                           string,   // the outcome of the last action
	primary, uninstall, secondary:  Rect,
}

setup_state :: proc(s: ^Session, loc := #caller_location) -> (r: Setup_State, e: Error) {
	p := params(loc)
	o := request(s, "Wren.setupState", &p) or_return
	r = {open = b_of(o, "open"), known = b_of(o, "known"), confirm_uninstall = b_of(o, "confirmUninstall"), busy = i_of(o, "busy"), note = s_of(o, "note")}
	r.primary, _ = rect_of(o, "primary")
	r.uninstall, _ = rect_of(o, "uninstall")
	r.secondary, _ = rect_of(o, "secondary")
	return r, .None
}

// The daily update check: whether a request is out (update_check.odin).
update_checking :: proc(s: ^Session, loc := #caller_location) -> (checking: bool, e: Error) {
	p := params(loc)
	o := request(s, "Wren.updateState", &p) or_return
	return b_of(o, "checking"), .None
}

////////////////////////////////
// Recording and the timeline (their answers are files: `Session.result`)

record_start :: proc(s: ^Session, loc := #caller_location) -> Error {
	p := params(loc)
	p_str(&p, "action", "start")
	_, e := request(s, "Wren.recordInput", &p)
	return e
}

// The recording, as the text a file keeps; how many events.
record_stop :: proc(s: ^Session, loc := #caller_location) -> (text: string, count: int, e: Error) {
	p := params(loc)
	p_str(&p, "action", "stop")
	o := request(s, "Wren.recordInput", &p) or_return
	return s.result, i_of(o, "count"), .None
}

// `events`: the "events" of a recording, as its JSON text.
replay :: proc(s: ^Session, events_json: string, speed := 1.0, loc := #caller_location) -> Error {
	p := params(loc)
	p_raw(&p, "events", events_json)
	p_num(&p, "speed", speed)
	_, e := request(s, "Wren.replayInput", &p)
	return e
}

timeline_start :: proc(s: ^Session, scale: f64, count: int, page := false, loc := #caller_location) -> Error {
	p := params(loc)
	p_str(&p, "action", "start")
	p_num(&p, "scale", scale)
	p_int(&p, "max", count)
	p_str(&p, "target", page ? "page" : "window")
	_, e := request(s, "Wren.timeline", &p)
	return e
}

Timeline :: struct { count, chrome, aba: int, sheet: string }

timeline_stop :: proc(s: ^Session, folder: string, cols: int, all := false, loc := #caller_location) -> (r: Timeline, e: Error) {
	p := params(loc)
	p_str(&p, "action", "stop")
	p_str(&p, "dir", folder)
	p_int(&p, "cols", cols)
	p_bool(&p, "all", all)
	o := request(s, "Wren.timeline", &p) or_return
	return {i_of(o, "count"), i_of(o, "chrome"), i_of(o, "aba"), s_of(o, "sheet")}, .None
}

timeline_status :: proc(s: ^Session, loc := #caller_location) -> Error {
	p := params(loc)
	p_str(&p, "action", "status")
	_, e := request(s, "Wren.timeline", &p)
	return e
}
