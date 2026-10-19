package page

// The scripts of a parsed document (HTML "scripting" model): <script> elements of type JavaScript or module, inline or
// external, run in the order and at the moment HTML gives them:
//   * classic scripts without async or defer: in document order, each after the previous one (an external one blocks
//     those after it until it arrives); they are all fetched at once (what a preload scanner does);
//   * defer scripts and modules without async: in document order, after those;
//   * async scripts (classic or module): as soon as they arrive;
//   * then document.readyState becomes "interactive", DOMContentLoaded fires at the document, readyState becomes
//     "complete" and load fires at the window.
// A script runs with document.currentScript set (classic scripts only), through js_run (bytecode cache, slow-script
// interruption). Modules run as module scripts of the realm (their imports are resolved by the engine's module loader).

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:url"

Script_Kind :: enum u8 { Classic, Module }

Script_State :: enum u8 { Fetching, Ready, Failed, Done }

Page_Script :: struct {
	page:     ^Page,
	element:  base.Handle,
	kind:     Script_Kind,
	external: bool,
	async_:   bool,
	defer_:   bool,
	state:    Script_State,
	url:      string,             // owned: the script's URL (the document's for inline scripts)
	source:   [dynamic]byte,
	line:     i32,                // first line of an inline script in its document (1 when unknown)
	task:     base.Handle,
	bad_status: bool,
}

Ready_State :: enum u8 { Loading, Interactive, Complete }

Page_Scripts :: struct {
	list:          [dynamic]^Page_Script,
	next_blocking: int,              // next classic blocking script to run
	next_deferred: int,              // next defer / module script to run
	current:       base.Handle,      // document.currentScript
	ready_state:   Ready_State,
	started:       bool,
	content_loaded: bool,
}

@(private)
js_mime_types := [?]string{
	"application/ecmascript", "application/javascript", "application/x-ecmascript", "application/x-javascript",
	"text/ecmascript", "text/javascript", "text/javascript1.0", "text/javascript1.1", "text/javascript1.2",
	"text/javascript1.3", "text/javascript1.4", "text/javascript1.5", "text/jscript", "text/livescript",
	"text/x-ecmascript", "text/x-javascript",
}

// The kind of script a <script> element is, from its type (and language) attribute; false for data blocks and other
// languages (application/wasm is the shell's).
script_kind_of :: proc(d: ^dom.Document, el: base.Handle) -> (Script_Kind, bool) {
	ty, has_type := dom.get_attribute(d, el, "type")
	if has_type {
		t := strings.to_lower(strings.trim_space(ty), context.temp_allocator)
		if t == "" { return .Classic, true }
		if t == "module" { return .Module, true }
		for m in js_mime_types { if t == m { return .Classic, true } }
		return .Classic, false
	}
	if lang, ok := dom.get_attribute(d, el, "language"); ok && lang != "" {
		l := strings.to_lower(lang, context.temp_allocator)
		for m in js_mime_types { if strings.concatenate({"text/", l}, context.temp_allocator) == m { return .Classic, true } }
		return .Classic, false
	}
	return .Classic, true
}

// Starts the scripts of the document just adopted. Nothing happens when JavaScript is off for the page.
scripts_start :: proc(p: ^Page) {
	if p.worker != nil || !js_enabled(p) { return }
	if p.scripts == nil {
		p.scripts = new(Page_Scripts)
		base.on_close(p.scope, scripts_free, p)
	}
	s := p.scripts
	if s.started { return }
	s.started = true
	d := p.doc
	stack := make([dynamic]base.Handle, context.temp_allocator)
	append(&stack, d.root)
	for len(stack) > 0 {
		cur := pop(&stack)
		n := dom.get(d, cur)
		if n == nil { continue }
		if n.kind == .Element && n.name == "script" { script_prepare(p, cur) }
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).prev { append(&stack, ch) }
	}
	scripts_pump(p)
}

@(private)
scripts_free :: proc(data: rawptr) {
	p := (^Page)(data)
	s := p.scripts
	if s == nil { return }
	for sc in s.list {
		delete(sc.url)
		delete(sc.source)
		free(sc)
	}
	delete(s.list)
	free(s)
	p.scripts = nil
}

// HTML "prepare the script element" for a parser-inserted script.
@(private)
script_prepare :: proc(p: ^Page, el: base.Handle) {
	d := p.doc
	kind, ok := script_kind_of(d, el)
	if !ok { return }
	if _, nomodule := dom.get_attribute(d, el, "nomodule"); nomodule && kind == .Classic { return }
	sc := new(Page_Script)
	sc.page = p
	sc.element = el
	sc.kind = kind
	sc.line = 1
	_, sc.async_ = dom.get_attribute(d, el, "async")
	_, sc.defer_ = dom.get_attribute(d, el, "defer")
	if kind == .Module { sc.defer_ = true }
	src, has_src := dom.get_attribute(d, el, "src")
	if has_src {
		sc.external = true
		resolved, okurl := url.parse(src, &p.env.location, context.temp_allocator)
		if !okurl || src == "" {
			log(p, .Error, fmt.tprintf("invalid script URL %q", src))
			sc.state = .Failed
			sc.url = strings.clone(src)
		} else {
			sc.url = strings.clone(resolved.href)
			nonce, _ := dom.get_attribute(d, el, "nonce")
			_, cors := dom.get_attribute(d, el, "crossorigin")
			mode := kind == .Module || cors ? fetch.Mode.Cors : fetch.Mode.No_Cors
			sc.state = .Fetching
			sc.task = fetch.start(p.loader, {
				request = {url = sc.url, mode = mode, credentials = kind == .Module ? .Same_Origin : .Include, destination = .Script, initiator = &p.env, nonce = nonce},
				on_event = script_event, user = sc, scope = p.scope, collect = true,
			})
		}
	} else {
		sc.async_ = sc.async_ && kind == .Module   // async means nothing for an inline classic script
		if kind == .Classic { sc.defer_ = false }
		sc.url = strings.clone(p.env.location.href)
		text := dom.text_content(d, el, context.temp_allocator)
		append(&sc.source, ..transmute([]byte)text)
		sc.state = .Ready
	}
	append(&p.scripts.list, sc)
}

@(private)
script_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	sc := (^Page_Script)(user)
	p := sc.page
	#partial switch ev.kind {
	case .Response:
		r := ev.response
		if r.status != 0 && (r.status < 200 || r.status >= 300) && r.type != .Opaque {
			sc.bad_status = true
			log(p, .Error, fmt.tprintf("script %s: HTTP %d", sc.url, r.status))
		}
	case .Done:
		sc.task = base.NIL_HANDLE
		if sc.bad_status { sc.state = .Failed } else { append(&sc.source, ..ev.data); sc.state = .Ready }
		scripts_pump(p)
	case .Failed:
		sc.task = base.NIL_HANDLE
		log(p, .Error, fmt.tprintf("script %s: %s", sc.url, ev.detail))
		sc.state = .Failed
		scripts_pump(p)
	}
}

// Fires error (a script that could not be fetched) or load (an external script that ran) at its element.
@(private)
script_fire :: proc(p: ^Page, sc: ^Page_Script, type: string) {
	if !sc.external && type == "load" { return }
	dispatch_event(p, sc.element, dom.Event{type = type})
}

@(private)
script_run :: proc(p: ^Page, sc: ^Page_Script) {
	if sc.state == .Failed {
		sc.state = .Done
		script_fire(p, sc, "error")
		return
	}
	sc.state = .Done
	if dom.get(p.doc, sc.element) == nil { return }
	s := p.scripts
	prev := s.current
	if sc.kind == .Classic { s.current = sc.element }
	js_run(p, sc.source[:], sc.url, sc.line, module = sc.kind == .Module)
	s.current = prev
	delete(sc.source)
	sc.source = nil
	script_fire(p, sc, "load")
}

Document_readyState :: proc(c: ^Call) -> string {
	s := c.page.scripts
	if s == nil { return c.page.render.adopted ? "complete" : "loading" }
	switch s.ready_state {
	case .Loading: return "loading"
	case .Interactive: return "interactive"
	case .Complete: return "complete"
	}
	return "complete"
}

Window_document :: proc(c: ^Call) -> u64 {
	d := call_doc(c)
	return d == nil ? 0 : u64(d.root)
}

Document_resolveURL :: proc(c: ^Call, u: string) -> (string, Api_Error) {
	resolved, ok := url.parse(u, &c.page.env.location, context.temp_allocator)
	if !ok { return "", fail(c, .Syntax, "not a valid URL") }
	return resolved.href, .None
}

Document_currentScript :: proc(c: ^Call) -> u64 {
	s := c.page.scripts
	return s == nil ? 0 : u64(s.current)
}

// Runs what may run now, in HTML's order; then the document's life cycle events once every script ran.
scripts_pump :: proc(p: ^Page) {
	s := p.scripts
	if s == nil || p.closed { return }
	// async scripts: whenever they are ready
	for sc in s.list {
		if sc.async_ && (sc.state == .Ready || sc.state == .Failed) { script_run(p, sc) }
	}
	// blocking classic scripts, in order
	for s.next_blocking < len(s.list) {
		sc := s.list[s.next_blocking]
		if sc.async_ || sc.defer_ { s.next_blocking += 1; continue }
		if sc.state == .Fetching { return }
		if sc.state != .Done { script_run(p, sc) }
		s.next_blocking += 1
	}
	// the parser is done (the document was parsed as a whole): defer scripts and modules, in order
	for s.next_deferred < len(s.list) {
		sc := s.list[s.next_deferred]
		if sc.async_ || !sc.defer_ { s.next_deferred += 1; continue }
		if sc.state == .Fetching { return }
		if sc.state != .Done { script_run(p, sc) }
		s.next_deferred += 1
	}
	if !s.content_loaded {
		s.content_loaded = true
		s.ready_state = .Interactive
		dispatch_event(p, p.doc.root, dom.Event{type = "readystatechange"})
		dispatch_event(p, p.doc.root, dom.Event{type = "DOMContentLoaded", bubbles = true})
	}
	for sc in s.list { if sc.async_ && sc.state != .Done { return } }
	if s.ready_state != .Complete {
		s.ready_state = .Complete
		dispatch_event(p, p.doc.root, dom.Event{type = "readystatechange"})
		fire_window_event(p, dom.Event{type = "load"})
	}
}
