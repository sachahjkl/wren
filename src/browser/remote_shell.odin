package browser

// Remote control (src/remote, `wren ctl`): the shell's side. The pipe server (src/remote) hands each request line to
// `remote_handle` on the interface thread, inside the event loop's turn between frames; methods are in remote_methods.odin.
//
//   * Nothing exists unless the channel was asked for (`--remote[=name]`, WREN_REMOTE, browser.remote.enabled): no pipe,
//     no thread, no timer. After a frame `remote_after_frame` does one comparison and returns.
//   * A command that must wait (a load, the network going quiet, an element, a script's condition, a capture, the frames
//     that carry an input) becomes an `Remote_Op`. Ops are looked at after each frame and when their one timer fires; the
//     timer exists only while an op needs to be looked at without anything else waking the loop (a deadline, a GPU copy
//     to read), and does not draw a frame.
//   * Script runs in the page through its console: the wrapper prints one line with a secret prefix that
//     `remote_take_console` takes before the tab's console sees it (so a result cannot be forged by a page without knowing
//     the prefix of this run, and never shows in the console).

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "toolkit:platform"
import "wb:base"
import "wb:desktop"
import "wb:fetch"
import "wb:host"
import "wb:i18n"
import "wb:page"
import "wb:remote"
import "wb:remote/client"

Remote_Wait :: enum u8 { Load, Idle, Stable, Selector, Function }
Remote_Op_Kind :: enum u8 { Wait, Capture, Frames, Eval, Click, Replay }
Capture_Target :: enum u8 { Window, Page, Rect, Selector }

Remote_Op :: struct {
	kind:     Remote_Op_Kind,
	conn:     u64,
	id:       string,     // the request's id as JSON text (owned)
	tab:      u64,
	deadline: i64,        // loop clock, ns
	what:     string,     // for the timeout message (owned)
	result:   string,     // JSON merged into the answer of a wait that follows a navigation (owned)
	// Wait
	wait:     Remote_Wait,
	arg:      string,     // selector or expression (owned)
	visible:  bool,
	quiet_at: i64,        // when the network went quiet (0: not now)
	// Frames, Capture, Click
	until:    u64,        // frame number to reach
	stage:    int,
	// Eval
	eval_id:  int,
	// Capture
	target:   Capture_Target,
	path:     string,     // owned
	bytes:    bool,       // the answer carries the PNG (base64)
	scale:    f32,
	rect:     [4]f32,     // Rect: x, y, w, h (window pixels); Selector: filled when the element is found
	// Click
	button:   platform.Mouse_Button,
	count:    int,
	pos:      [2]f32,
	// Replay
	events:   [dynamic]Rec_Event,
	idx:      int,
	t0:       i64,
	speed:    f64,
	snapshot: string,     // Capture: also write <snapshot>.html and .json (owned)
}

Remote :: struct {
	active:     bool,
	started:    bool,       // the server was started (stop must undo it)
	name:       string,     // owned
	error:      string,     // why it did not start (owned)
	cfg:        remote.Settings,
	ops:        [dynamic]^Remote_Op,
	subs:       [dynamic]u64,
	loaded:     map[u64]bool,   // tab id -> what the last look at it said (the load event)
	timer:      base.Handle,
	timer_at:   i64,
	frame_no:   u64,
	prefix:     string,     // owned: what an eval result's console line starts with
	eval_next:  int,
	sync_id:    int,        // an eval whose answer is wanted at once, and what it said
	sync_text:  string,
	sync_done:  bool,
	stash_id:   int,        // an answer that came while its command was still starting
	stash_text: string,
	exit_code:  int,
	inputs:     int,        // events injected (macro and statistics)
	rec:        Remote_Recording,
}

the_remote: Remote
remote_exit_code: int   // what Browser.close asked for: the process ends with it (main.odin)

// `wren ctl ...` (src/remote/client): the profile folder a Wren without --profile uses decides the pipe's name there.
ctl_main :: proc(args: []string) -> int {
	cfg_dir := platform.config_dir(context.temp_allocator)
	profile := cfg_dir == "" ? "build/profile" : strings.concatenate({cfg_dir, "/", APP_NAME}, context.temp_allocator)
	if dir := portable_profile_dir(); dir != "" { profile = dir }
	return client.run(args, profile, desktop.executable_path())
}

// `--remote` or `--remote=<name>`: taken out of the arguments.
extract_remote :: proc(args: []string) -> (requested: bool, name: string, rest: [dynamic]string) {
	rest = make([dynamic]string, context.temp_allocator)
	for a in args {
		switch {
		case a == "--remote": requested = true
		case strings.has_prefix(a, "--remote="): requested, name = true, a[len("--remote="):]
		case: append(&rest, a)
		}
	}
	return
}

////////////////////////////////
// Lifecycle

// `requested`: --remote on the command line; `arg_name` its name ("" for none). Called once the loop and the first tab exist.
remote_start :: proc(app: ^App, requested: bool, arg_name: string) {
	r := &the_remote
	r.cfg = remote.settings_from_prefs(&app.prefs)
	env, _ := os.lookup_env("WREN_REMOTE", context.temp_allocator)
	if !requested && !r.cfg.enabled && env == "" { return }
	name := arg_name
	if name == "" { name = env }
	if name == "" { name = r.cfg.name }
	if name == "" { name = remote.profile_name(app.profile_dir) }
	r.cfg.name = ""
	if err := remote.start(&app.loop, name, r.cfg.max_message, r.cfg.max_clients, remote_handle, remote_closed, nil); err != "" {
		r.error = strings.clone(fmt.tprintf("remote control: %s (%s)", err, name))
		desktop.console_error(strings.concatenate({r.error, "\n"}, context.temp_allocator))   // (a script that redirected stderr sees it)
		return
	}
	r.active, r.started = true, true
	r.name = strings.clone(name)
	nonce: [12]byte
	crypto.rand_bytes(nonce[:])
	r.prefix = strings.clone(fmt.tprintf("\x01wren-remote:%x:", nonce[:]))
	r.timer = base.NIL_HANDLE
	if !remote.write_info(app.profile_dir, name, APP_VERSION) { r.error = strings.clone("remote control: cannot write remote.json in the profile") }
}

// The notice of a start that failed, once the interface exists.
remote_notice :: proc(app: ^App) {
	r := &the_remote
	if r.error == "" { return }
	ui_toast_remote(r.error)
	if t := current_tab(app); t != nil { tab_log(t, .Warn, r.error) }
	delete(r.error)
	r.error = ""
}

remote_stop :: proc(app: ^App) {
	r := &the_remote
	if r.started {
		remote.stop()
		remote.remove_info(app.profile_dir)
	}
	if r.timer != base.NIL_HANDLE { host.clear_timer(&app.loop, r.timer) }
	for op in r.ops { op_free(op) }
	delete(r.ops)
	delete(r.subs)
	delete(r.loaded)
	delete(r.name); delete(r.prefix); delete(r.error); delete(r.sync_text)
	delete(r.stash_text)
	remote_recording_destroy(&r.rec)
	remote_exit_code = r.exit_code
	r^ = {}
}

remote_indicator :: proc() -> bool { return the_remote.active && the_remote.cfg.indicator }

remote_indicator_text :: proc() -> string { return i18n.tr("remote") }

remote_indicator_tip :: proc() -> string {
	return fmt.tprintf(i18n.tr("Remote control is listening (%s): `wren ctl` can drive this window"), remote.pipe_path(the_remote.name))
}

@(private = "file")
remote_closed :: proc(user: rawptr, conn: u64) {
	r := &the_remote
	for i := len(r.subs) - 1; i >= 0; i -= 1 { if r.subs[i] == conn { unordered_remove(&r.subs, i) } }
	for i := len(r.ops) - 1; i >= 0; i -= 1 {
		if r.ops[i].conn == conn { op_free(r.ops[i]); unordered_remove(&r.ops, i) }
	}
}

////////////////////////////////
// Requests

Call :: struct {
	conn:   u64,
	id:     string,
	method: string,
	params: json.Object,
}

Reply :: struct {
	result:   string,   // JSON text
	code:     int,      // 0: success
	message:  string,
	data:     string,
	deferred: bool,     // an op will answer
}

done :: proc(result := "{}") -> Reply { return Reply{result = result} }
fail :: proc(code: int, message: string, data := "") -> Reply { return Reply{code = code, message = message, data = data} }

@(private = "file")
remote_handle :: proc(user: rawptr, conn: u64, line: []byte) {
	app := the_app
	if app == nil { return }
	req, code, message := remote.parse_request(line)
	if code != 0 { remote_send(conn, remote.response_error(req.id, code, message)); return }
	c := Call{conn = conn, id = req.id, method = req.method, params = req.params}
	rep := remote_dispatch(app, &c)
	if rep.deferred { return }
	remote_answer(conn, c.id, rep)
	app.frames_requested = max(app.frames_requested, 2)
}

remote_answer :: proc(conn: u64, id: string, rep: Reply) {
	if rep.code != 0 { remote_send(conn, remote.response_error(id, rep.code, rep.message, rep.data)) } else { remote_send(conn, remote.response_ok(id, rep.result)) }
}

remote_send :: proc(conn: u64, line: string) { remote.send(conn, line) }

// To the clients that asked for events (Remote.subscribe).
remote_event :: proc(name: string, params: string) {
	r := &the_remote
	if len(r.subs) == 0 { return }
	line := remote.event_line(name, params)
	for c in r.subs { remote.send(c, line) }
}

remote_subscribed :: proc() -> bool { return len(the_remote.subs) > 0 }

////////////////////////////////
// Ops

op_new :: proc(app: ^App, c: ^Call, kind: Remote_Op_Kind, timeout_ms: int, what: string) -> ^Remote_Op {
	op := new(Remote_Op)
	op.kind = kind
	op.conn = c.conn
	op.id = strings.clone(c.id)
	op.what = strings.clone(what)
	ms := timeout_ms > 0 ? timeout_ms : the_remote.cfg.timeout_ms
	op.deadline = host.now_ns(&app.loop) + i64(ms) * 1_000_000
	append(&the_remote.ops, op)
	return op
}

op_free :: proc(op: ^Remote_Op) {
	delete(op.id); delete(op.what); delete(op.result); delete(op.arg); delete(op.path); delete(op.events); delete(op.snapshot)
	free(op)
}

// Ends `op` with its answer.
op_finish :: proc(op: ^Remote_Op, rep: Reply) {
	remote_answer(op.conn, op.id, rep)
	for o, i in the_remote.ops { if o == op { unordered_remove(&the_remote.ops, i); break } }
	op_free(op)
}

// The pending ops are looked at (after a frame, when the timer fires, after a command that made one).
remote_tick :: proc(app: ^App) {
	r := &the_remote
	if !r.active { return }
	now := host.now_ns(&app.loop)
	// (an op may finish, and finishing removes it: work from a copy of the list)
	list := make([]^Remote_Op, len(r.ops), context.temp_allocator)
	copy(list, r.ops[:])
	for op in list { op_step(app, op, now) }
	remote_loaded_events(app)
	remote_arm(app)
}

// After each loop turn's frame (main loop): the cost when nothing is asked is this comparison.
remote_after_frame :: proc(app: ^App) {
	r := &the_remote
	if !r.active { return }
	r.frame_no += 1
	if len(r.ops) > 0 || len(r.subs) > 0 { remote_tick(app) }
}

@(private = "file")
remote_arm :: proc(app: ^App) {
	r := &the_remote
	if len(r.ops) == 0 {
		if r.timer != base.NIL_HANDLE { host.clear_timer(&app.loop, r.timer); r.timer = base.NIL_HANDLE }
		return
	}
	now := host.now_ns(&app.loop)
	next := max(i64)
	for op in r.ops {
		next = min(next, op.deadline)
		if op_polls(op) { next = min(next, now + i64(r.cfg.poll_ms) * 1_000_000) }
	}
	if r.timer != base.NIL_HANDLE {
		if r.timer_at <= next { return }   // (it fires early enough: the tick arms again)
		host.clear_timer(&app.loop, r.timer)
	}
	ms := max(f64(next - now) / 1e6, 0)
	r.timer_at = next
	r.timer = host.set_timer(&app.loop, ms, 0, remote_timer, nil)
}

@(private = "file")
remote_timer :: proc(_: rawptr) {
	r := &the_remote
	r.timer = base.NIL_HANDLE
	app := the_app
	if app == nil { return }
	host.quiet_note(&app.loop)   // looking at an op draws nothing by itself (what it asks for, it asks)
	remote_tick(app)
}

// Does the op need to be looked at on a timer (nothing else tells when its condition becomes true)?
@(private = "file")
op_polls :: proc(op: ^Remote_Op) -> bool {
	switch op.kind {
	case .Wait:    return true
	case .Capture: return op.stage != 0 || render_capture_busy()
	case .Replay:  return true
	case .Frames, .Eval, .Click: return false
	}
	return false
}

// A tab's load events, for the clients that subscribed.
@(private = "file")
remote_loaded_events :: proc(app: ^App) {
	r := &the_remote
	if len(r.subs) == 0 { return }
	for t in app.tabs {
		now := tab_loaded(app, t)
		was := r.loaded[t.id]
		if now != was {
			r.loaded[t.id] = now
			if now { remote_event("Page.loadEventFired", fmt.tprintf(`{{"tabId":%d,"url":%s}}`, t.id, remote.quote(t.url))) }
		}
	}
}

////////////////////////////////
// Script through the console

// `message` came from a page's console: is it the answer of one of our scripts?
remote_take_console :: proc(message: string) -> bool {
	r := &the_remote
	if !r.active || r.prefix == "" || !strings.has_prefix(message, r.prefix) { return false }
	payload := message[len(r.prefix):]
	v, err := json.parse(transmute([]byte)payload, json.Specification.JSON, true, context.temp_allocator)
	if err != .None { return true }
	obj, is_obj := v.(json.Object)
	if !is_obj { return true }
	id, _ := remote.param_int(obj, "id")
	if id == r.sync_id && !r.sync_done {
		r.sync_text, r.sync_done = strings.clone(payload), true
		return true
	}
	for op in r.ops {
		if op.kind == .Eval && op.eval_id == id {
			op_finish(op, eval_reply(obj))
			return true
		}
	}
	delete(r.stash_text)
	r.stash_id, r.stash_text = id, strings.clone(payload)   // (its command is still starting: it picks this up)
	return true
}

eval_reply_text :: proc(payload: string) -> Reply {
	v, err := json.parse(transmute([]byte)payload, json.Specification.JSON, true, context.temp_allocator)
	obj, ok := v.(json.Object)
	if err != .None || !ok { return fail(remote.ERR_FAILED, "unreadable script answer") }
	return eval_reply(obj)
}

// The answer a script's result makes (Chrome's Runtime.evaluate shape).
eval_reply :: proc(obj: json.Object) -> Reply {
	if ok, _ := remote.param_int(obj, "ok"); ok == 0 {
		e, _ := remote.param_object(obj, "e")
		name, _ := remote.param_string(e, "name")
		msg, _ := remote.param_string(e, "message")
		stack, _ := remote.param_string(e, "stack")
		text := name == "" ? msg : fmt.tprintf("%s: %s", name, msg)
		return done(fmt.tprintf(`{{"result":{{"type":"object","subtype":"error","className":%s,"description":%s}},"exceptionDetails":{{"text":%s,"exception":{{"className":%s,"description":%s}}}}}}`,
			remote.quote(name), remote.quote(stack == "" ? text : stack), remote.quote(text), remote.quote(name), remote.quote(stack == "" ? text : stack)))
	}
	t, _ := remote.param_string(obj, "t")
	v, has := remote.param_string(obj, "v")
	if !has || t == "undefined" { return done(fmt.tprintf(`{{"result":{{"type":"undefined"}}}}`)) }
	return done(fmt.tprintf(`{{"result":{{"type":%s,"value":%s}}}}`, remote.quote(t), v))
}

// The JavaScript that runs `expression` (indirect eval, so its completion value is the result) and prints the outcome with
// the secret prefix. With `await`, a promise is waited for.
@(private = "file")
eval_source :: proc(id: int, expression: string, await: bool) -> string {
	return fmt.tprintf(`(function(){{var N=%s,I=%d;function E(e){{var r={{name:"Error",message:"",stack:""}};try{{if(e&&typeof e==="object"){{r.name=String(e.name||"Error");r.message=String(e.message===undefined?"":e.message);r.stack=String(e.stack||"")}}else{{r.message=String(e)}}}}catch(x){{r.message="(unprintable)"}}return r}}function S(v){{var t=typeof v;if(v===undefined)return{{t:"undefined"}};if(t==="function"||t==="symbol"||t==="bigint")return{{t:t,v:JSON.stringify(String(v))}};try{{var j=JSON.stringify(v);if(j===undefined)return{{t:t,v:"null"}};return{{t:v===null?"null":Array.isArray(v)?"array":t,v:j}}}}catch(x){{return{{t:"object",v:JSON.stringify(String(v))}}}}}}function O(o){{o.id=I;console.log(N+JSON.stringify(o))}}try{{var r=(0,eval)(%s);if(%v&&r&&typeof r.then==="function"){{r.then(function(v){{var s=S(v);s.ok=1;O(s)}},function(e){{O({{ok:0,e:E(e)}})}})}}else{{var s=S(r);s.ok=1;O(s)}}}}catch(e){{O({{ok:0,e:E(e)}})}}}})()`,
		remote.quote(the_remote.prefix), id, remote.quote(expression), await)
}

// Runs `expression` in the tab's page. The answer is the console line `remote_take_console` takes: at once for a plain value
// (`done`), later for a promise. `ran` false: the page has no script engine (off, or no page).
eval_start :: proc(t: ^Tab, expression: string, await: bool) -> (id: int, ran: bool) {
	r := &the_remote
	if t == nil || t.page == nil || t.kind != .Web { return 0, false }
	r.eval_next += 1
	id = r.eval_next
	src := eval_source(id, expression, await)
	if st := page.js_run(t.page, transmute([]byte)src, "wren-remote", 1); st == .Trapped { return id, false }
	page.js_checkpoint(t.page)
	return id, true
}

// The value of `expression` as JSON text, at once (not for promises). `error` says why not.
eval_sync :: proc(t: ^Tab, expression: string) -> (value: string, type: string, error: string) {
	r := &the_remote
	if t == nil || t.page == nil { return "", "", "the tab has no page" }
	r.eval_next += 1
	id := r.eval_next
	r.sync_id, r.sync_done = id, false
	delete(r.sync_text); r.sync_text = ""
	src := eval_source(id, expression, false)
	st := page.js_run(t.page, transmute([]byte)src, "wren-remote", 1)
	r.sync_id = 0
	if !r.sync_done {
		return "", "", st == .Trapped ? "JavaScript is off for this page or its engine stopped" : "the script did not answer"
	}
	v, err := json.parse(transmute([]byte)r.sync_text, json.Specification.JSON, true, context.temp_allocator)
	obj, _ := v.(json.Object)
	if err != .None { return "", "", "unreadable answer" }
	if ok, _ := remote.param_int(obj, "ok"); ok == 0 {
		e, _ := remote.param_object(obj, "e")
		msg, _ := remote.param_string(e, "message")
		return "", "", msg
	}
	ty, _ := remote.param_string(obj, "t")
	val, _ := remote.param_string(obj, "v")
	return val == "" ? "null" : val, ty, ""
}

// Does the page have a script engine running already (asking it something must not start one)?
page_has_script :: proc(t: ^Tab) -> bool {
	return t != nil && t.page != nil && t.page.js != nil && t.page.js.inst != nil && !t.page.js.failed
}

////////////////////////////////
// What a wait looks at

// Has the tab's document finished loading (the document, its modules, its parse; its own load event when it has a
// script engine)?
tab_loaded :: proc(app: ^App, t: ^Tab) -> bool {
	if t == nil { return false }
	if t.kind != .Web { return true }   // about:config, about:history: made at once
	if t.lazy { return false }
	load := t.load
	if load != nil && load.task != base.NIL_HANDLE { return false }
	if t.page == nil { return load == nil }
	if load != nil {
		for s in load.slots { if s.state == .Pending || s.state == .Ready { return false } }
		if load.bytes > 0 && !t.page.render.adopted { return false }   // (still being parsed)
	}
	if page_has_script(t) {
		if v, _, err := eval_sync(t, `document.readyState`); err == "" && v != `"complete"` { return false }
	}
	return true
}

// Network quiet and nothing left to draw: a wait for `idle` ends when this has held for browser.remote.idle_ms.
tab_idle :: proc(app: ^App, t: ^Tab) -> bool {
	if !tab_loaded(app, t) { return false }
	if fetch.in_flight(&app.loader) > 0 { return false }
	return true
}

// Idle, and the picture is no longer changing: no frame wanted, the layout is the document's, the images are in.
tab_stable :: proc(app: ^App, t: ^Tab) -> bool {
	if !tab_idle(app, t) { return false }
	if app.frames_requested > 1 || ui_needs_frame(app) { return false }
	if t.page != nil && t.kind == .Web {
		if t.layout.mutations != t.page.doc.mutations { return false }
		if page_has_script(t) {
			if v, _, err := eval_sync(t, `Array.prototype.every.call(document.images,function(i){return i.complete})`); err == "" && v != "true" { return false }
		}
	}
	return true
}

// The tab an op is about (nil: it was closed).
op_tab :: proc(app: ^App, id: u64) -> ^Tab {
	for t in app.tabs { if t.id == id { return t } }
	return nil
}

@(private = "file")
op_step :: proc(app: ^App, op: ^Remote_Op, now: i64) {
	r := &the_remote
	t := op_tab(app, op.tab)
	if t == nil && op.kind != .Eval && op.kind != .Frames && op.kind != .Replay {
		op_finish(op, fail(remote.ERR_FAILED, "the tab was closed"))
		return
	}
	timed_out := now >= op.deadline
	switch op.kind {
	case .Frames:
		app.frames_requested = max(app.frames_requested, 2)
		if r.frame_no >= op.until { op_finish(op, done(op.result == "" ? "{}" : op.result)) }
	case .Eval:
		if timed_out { op_finish(op, fail(remote.ERR_TIMEOUT, "timed out waiting for the script's promise")) }
	case .Wait:
		ok := false
		switch op.wait {
		case .Load:     ok = tab_loaded(app, t)
		case .Idle, .Stable:
			good := op.wait == .Idle ? tab_idle(app, t) : tab_stable(app, t)
			if !good { op.quiet_at = 0 } else if op.quiet_at == 0 { op.quiet_at = now }
			ok = good && now - op.quiet_at >= i64(r.cfg.idle_ms) * 1_000_000
		case .Selector:
			if t.page != nil {
				h, valid := page.query_first(t.page, op.arg)
				if !valid { op_finish(op, fail(remote.ERR_PARAMS, fmt.tprintf("invalid selector %q", op.arg))); return }
				ok = h != base.NIL_HANDLE
				if ok && op.visible { ok = element_visible(app, t, h) }
			}
		case .Function:
			if page_has_script(t) {
				if v, _, err := eval_sync(t, op.arg); err == "" { ok = v != "false" && v != "null" && v != "0" && v != `""` }
			}
		}
		if ok {
			op_finish(op, done(op.result == "" ? `{"waited":true}` : op.result))
		} else if timed_out {
			op_finish(op, fail(remote.ERR_TIMEOUT, fmt.tprintf("timed out waiting for %s", op.what)))
		} else if op.wait == .Idle || op.wait == .Stable {
			app.frames_requested = max(app.frames_requested, 0)   // (nothing is asked of the loop: the timer looks again)
		}
	case .Capture: capture_step(app, op, t, timed_out)
	case .Replay:  replay_step(app, op, now)
	case .Click:   click_step(app, op, t, timed_out)
	}
}
