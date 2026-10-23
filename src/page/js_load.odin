package page

// The scripts of a document, run when and in the order HTML says ("scripting": prepare / execute the script element,
// the parser's pending parsing-blocking script, the lists of deferred, in-order and as-soon-as-possible scripts, "the
// end" of parsing: readyState, DOMContentLoaded, load).
//
// The parser. The document is parsed as a whole, off the UI thread, then adopted; there is no incremental parser. To
// give scripts the view HTML gives them (a script sees only what precedes it: document.body is null in <head>, the
// elements after it do not exist yet), everything that follows the first script in document order is detached at
// adoption, each node on its own, and attached again ("revealed") in document order, to its parent as the parser
// left it, at the end of its children as the tree builder appends: up to each script's end tag, where the script is
// prepared; a parser-blocking script stops the reveal until it ran. document.write splices the nodes it parses at the
// reveal's position (its scripts run before it returns). The page can paint the revealed part meanwhile.
//
// Fetching. Every external script and module of the document starts loading at adoption (what a preload scanner
// does): a script element prepared later takes the preload of its URL. Scripts are fetched as JavaScript
// (fetch.Script_Type: HTML's MIME rules), with their crossorigin, referrerpolicy and nonce; integrity is checked (SRI)
// before they run. Large scripts are compiled to bytecode on other threads meanwhile (js_load_compile.odin).
//
// Scripts inserted by scripts (createElement + insertion): the DOM's insertion and attribute hooks (dom/hooks.odin)
// prepare them when they become connected; inline ones run before the insertion returns, external ones are async
// unless their async attribute was set to false. Scripts inserted by a fragment parser (innerHTML) never run.

import "core:encoding/base64"
import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:csp"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:url"

Script_Kind :: enum u8 { Classic, Module, Import_Map }

Script_State :: enum u8 { Fetching, Ready, Failed, Done }

Ready_State :: enum u8 { Loading, Interactive, Complete }

// The per-element state HTML keeps on a script element. "Force async" is true for a script element made by a script
// until its async attribute is touched: here it is the absence of Parser_Inserted, From_Fragment and Async_Touched.
Script_Flag :: enum u8 { Already_Started, Parser_Inserted, Async_Touched, From_Fragment }
Script_Flags :: bit_set[Script_Flag; u8]

@(private)
force_async :: #force_inline proc(f: Script_Flags) -> bool { return f & {.Parser_Inserted, .Async_Touched, .From_Fragment} == {} }

Cors_Setting :: enum u8 { No_Cors, Anonymous, Use_Credentials }

Page_Script :: struct {
	page:            ^Page,
	element:         base.Handle,
	kind:            Script_Kind,
	parser_inserted: bool,
	external:        bool,
	async_:          bool,
	defer_:          bool,
	state:           Script_State,
	url:             string,            // owned: the script's URL (the response's once fetched); the document's for inline code
	source:          [dynamic]byte,     // classic and import maps (inline, or once fetched)
	line:            i32,
	download:        ^Script_Fetch,     // external classic scripts
	graph:           ^Module_Graph,     // module scripts (js_load_modules.odin)
	integrity:       string,            // owned: the integrity attribute (SRI)
	error:           string,            // owned: why it cannot run
	nonce:           string,            // owned
	cors:            Cors_Setting,
	referrer:        fetch.Referrer_Policy,
}

// The download of an external classic script, shared by the preload scanner and the element that uses it.
Script_Fetch :: struct {
	page:       ^Page,
	url:        string,                 // owned: as requested
	final_url:  string,                 // owned: the response's
	cors:       Cors_Setting,
	task:       base.Handle,
	state:      Script_State,
	bytes:      [dynamic]byte,
	error:      string,                 // owned
	opaque:     bool,                   // no-cors cross-origin: integrity cannot be checked
	claimed:    bool,                   // an element uses it (a preload nobody claimed is dropped with the page)
	compiling:  bool,                   // its bytecode is being made on another thread
	parser_inserted: bool,
}

Reveal_Item :: struct { node, parent: base.Handle }

Doc_Parser :: struct {
	active:          bool,                  // the document is being parsed (its first load, or after document.open)
	script_created:  bool,                  // opened by document.open(): it ends at document.close()
	queue:           [dynamic]Reveal_Item,  // nodes not attached yet, in document order
	next:            int,
	stop:            int,                   // a nested reveal (document.write) ends here; -1 none
	pending:         ^Page_Script,          // the pending parsing-blocking script
	nesting:         int,                   // script nesting level
	revealing:       int,                   // attaching nodes: the DOM hooks ignore them
	executing:       int,                   // parser-inserted scripts running: the insertion point is defined
	waiting_since:   f64,                   // a script waits for stylesheets since (loop clock, ms)
}

Page_Scripts :: struct {
	scripts:      [dynamic]^Page_Script,
	fetches:      [dynamic]^Script_Fetch,
	flags:        map[base.Handle]Script_Flags,
	parser:       Doc_Parser,
	deferred:     [dynamic]^Page_Script,   // run in order when parsing finished (defer, modules)
	in_order:     [dynamic]^Page_Script,   // inserted by scripts, not async: in order, as soon as possible
	asap:         [dynamic]^Page_Script,   // async: whenever ready
	current:      base.Handle,             // document.currentScript
	ready_state:  Ready_State,
	started:      bool,
	parse_done:   bool,                    // "stop parsing" happened
	content_loaded: bool,                  // DOMContentLoaded fired
	loaded:       bool,                    // load fired
	ignore_destructive_writes: int,
	write_depth:  int,
	written:      int,                     // bytes document.write inserted
	poll:         base.Handle,             // a timer looking again at what the page waits for
	pumping:      bool,
	modules:      ^Module_State,           // js_load_modules.odin
	timing:       Script_Timing,
}

// When the document's life cycle steps happened (loop clock, ms): measurements and tests.
Script_Timing :: struct {
	started_ms:    f64,   // scripts_start (the document was parsed and adopted)
	parsed_ms:     f64,   // the reveal finished ("stop parsing")
	dcl_ms:        f64,   // DOMContentLoaded fired
	load_ms:       f64,   // load fired
	scripts_run:   int,
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
		if t == "importmap" { return .Import_Map, true }
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

@(private)
is_script_element :: #force_inline proc(n: ^dom.Node) -> bool { return n != nil && n.kind == .Element && n.name == "script" }

// The page's script state, made on first use (a page that never parsed a document can still get dynamic scripts).
@(private)
scripts_of :: proc(p: ^Page) -> ^Page_Scripts {
	if p.scripts == nil {
		p.scripts = new(Page_Scripts)
		p.scripts.parser.stop = -1
		p.scripts.ready_state = p.render.adopted ? .Complete : .Loading
		base.on_close(p.scope, scripts_free, p)
	}
	return p.scripts
}

@(private)
scripts_free :: proc(data: rawptr) {
	p := (^Page)(data)
	s := p.scripts
	if s == nil { return }
	for sc in s.scripts { script_free(sc) }
	delete(s.scripts)
	for f in s.fetches { script_fetch_free(p, f) }
	delete(s.fetches)
	delete(s.flags)
	delete(s.parser.queue)
	delete(s.deferred)
	delete(s.in_order)
	delete(s.asap)
	if s.modules != nil { modules_free(p, s.modules) }
	free(s)
	p.scripts = nil
}

@(private)
script_free :: proc(sc: ^Page_Script) {
	delete(sc.url); delete(sc.source); delete(sc.integrity); delete(sc.error); delete(sc.nonce)
	free(sc)
}

@(private)
script_fetch_free :: proc(p: ^Page, f: ^Script_Fetch) {
	if f.task != base.NIL_HANDLE && !p.closed { fetch.cancel(p.loader, f.task) }
	delete(f.url); delete(f.final_url); delete(f.bytes); delete(f.error)
	free(f)
}

////////////////////////////////
// Start: after the document's adoption

// Starts the scripts of the document just adopted (parsed with the scripting flag: js_load_write.odin). Nothing happens
// when JavaScript is off for the page.
scripts_start :: proc(p: ^Page) {
	if p.worker != nil { return }
	if !js_enabled(p) {
		frame_document_ready(p)   // no insertion hooks: its frames are found now (frames.odin)
		return
	}
	s := scripts_of(p)
	if s.started { return }
	s.started = true
	s.ready_state = .Loading
	s.timing.started_ms = now_ms(p)
	scripts_install_hooks(p)
	d := p.doc

	// document order, and the first script: what follows it is revealed by the parser as scripts allow
	order := make([dynamic]Reveal_Item, 0, d.nodes.count, context.temp_allocator)
	stack := make([dynamic]base.Handle, context.temp_allocator)
	for ch := dom.get(d, d.root).last_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).prev { append(&stack, ch) }
	first := -1
	for len(stack) > 0 {
		cur := pop(&stack)
		n := dom.get(d, cur)
		if n == nil { continue }
		if first < 0 && is_script_element(n) {
			if _, ok := script_kind_of(d, cur); ok { first = len(order) }
		}
		if n.kind == .Element && n.name == "script" { scripts_preload(p, cur) }
		append(&order, Reveal_Item{cur, n.parent})
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).prev { append(&stack, ch) }
	}
	// what is there already: its event handler attributes
	limit := first < 0 ? len(order) : first
	for it in order[:limit] { content_handlers_register(p, it.node) }
	s.parser.active = true
	if first >= 0 {
		resize(&s.parser.queue, len(order) - first)
		copy(s.parser.queue[:], order[first:])
		s.parser.next = 0
		for i := len(order) - 1; i >= first; i -= 1 { dom.detach(d, order[i].node) }
		if p.body != base.NIL_HANDLE && !dom.is_connected(d, p.body) { p.body = base.NIL_HANDLE }
		if p.head != base.NIL_HANDLE && !dom.is_connected(d, p.head) { p.head = base.NIL_HANDLE }
		if p.doc_el != base.NIL_HANDLE && !dom.is_connected(d, p.doc_el) { p.doc_el = base.NIL_HANDLE }
	}
	frames_scan(p)   // the frames of what stays connected (before the first script): theirs now (frames.odin)
	if p.closed { return }
	reveal_run(p)
	scripts_pump(p)
}

////////////////////////////////
// The parser's reveal

// Attaches the parser's next nodes until a parser-blocking script waits, the queue (or a nested reveal's part of it)
// is done, or the page closes. Preparing a script element at its end tag.
@(private)
reveal_run :: proc(p: ^Page) {
	s := p.scripts
	ps := &s.parser
	d := p.doc
	for !p.closed && ps.active && ps.pending == nil {
		end := ps.stop >= 0 ? ps.stop : len(ps.queue)
		if ps.next >= end { break }
		it := ps.queue[ps.next]
		ps.next += 1
		if !reveal_node(p, it) { continue }
		n := dom.get(d, it.node)
		if !is_script_element(n) { continue }
		// the script's text comes with it: the end tag is after its children
		for ps.next < end && ps.queue[ps.next].parent == it.node {
			reveal_node(p, ps.queue[ps.next])
			ps.next += 1
		}
		// the custom elements parsed before the script are upgraded (and connected) before it runs
		custom_elements_flush(p)
		s.flags[it.node] += {.Parser_Inserted}
		script_prepare(p, it.node, parser_inserted = true)
	}
	if p.closed { return }
	custom_elements_flush(p)
	if ps.active && ps.pending == nil && ps.stop < 0 && ps.next >= len(ps.queue) && !ps.script_created {
		parser_finish(p)
	}
}

// Attaches one node of the parser's queue. False when it is gone (a script released it meanwhile).
@(private)
reveal_node :: proc(p: ^Page, it: Reveal_Item) -> bool {
	d := p.doc
	n := dom.get(d, it.node)
	if n == nil || dom.get(d, it.parent) == nil { return false }
	s := p.scripts
	if n.parent == base.NIL_HANDLE {
		s.parser.revealing += 1
		dom.append_child(d, it.parent, it.node)
		s.parser.revealing -= 1
	}
	if n = dom.get(d, it.node); n != nil && n.kind == .Element {
		switch n.name {
		case "html": if p.doc_el == base.NIL_HANDLE { p.doc_el = it.node }
		case "head": if p.head == base.NIL_HANDLE { p.head = it.node }
		case "body": if p.body == base.NIL_HANDLE { p.body = it.node }
		}
		content_handlers_register(p, it.node)
		if n.name == "link" { link_revealed(p, it.node) }
		if n.name == "iframe" || n.name == "frame" { frames_note_inserted(p, it.node) }
	}
	return true
}

// HTML "stop parsing": the insertion point is gone, readyState is interactive; deferred scripts, DOMContentLoaded and
// load follow (scripts_pump).
@(private)
parser_finish :: proc(p: ^Page) {
	s := p.scripts
	ps := &s.parser
	ps.active = false
	ps.script_created = false
	clear(&ps.queue)
	ps.next = 0
	s.parse_done = true
	s.timing.parsed_ms = now_ms(p)
	p.style_stale = true   // stylesheets the reveal kept in place are read again (styles.odin)
	ready_state_set(p, .Interactive)
}

@(private)
ready_state_set :: proc(p: ^Page, rs: Ready_State) {
	s := p.scripts
	if s.ready_state == rs { return }
	s.ready_state = rs
	dispatch_event(p, p.doc.root, dom.Event{type = "readystatechange"})
}

// Whether the reveal is under way (styles.odin keeps the stylesheets of the not yet revealed part meanwhile).
scripts_revealing :: proc(p: ^Page) -> bool {
	s := p.scripts
	return s != nil && s.parser.active && s.parser.next < len(s.parser.queue)
}

////////////////////////////////
// Preparing a script element (HTML "prepare the script element")

@(private)
cors_setting :: proc(d: ^dom.Document, el: base.Handle) -> Cors_Setting {
	v, has := dom.get_attribute(d, el, "crossorigin")
	if !has { return .No_Cors }
	return strings.equal_fold(strings.trim_space(v), "use-credentials") ? .Use_Credentials : .Anonymous
}

@(private)
script_text :: proc(d: ^dom.Document, el: base.Handle, allocator := context.temp_allocator) -> string {
	// the child text content: Text children only
	sb := strings.builder_make(allocator)
	n := dom.get(d, el)
	for c := n.first_child; c != base.NIL_HANDLE; {
		cn := dom.get(d, c)
		if cn == nil { break }
		if cn.kind == .Text { strings.write_string(&sb, cn.text) }
		c = cn.next
	}
	return strings.to_string(sb)
}

@(private)
script_flags :: proc(p: ^Page, el: base.Handle) -> Script_Flags {
	s := p.scripts
	if s == nil { return {} }
	return s.flags[el]
}

script_prepare :: proc(p: ^Page, el: base.Handle, parser_inserted: bool) {
	s := scripts_of(p)
	d := p.doc
	flags := s.flags[el]
	if .Already_Started in flags { return }
	n := dom.get(d, el)
	if n == nil { return }
	src, has_src := dom.get_attribute(d, el, "src")
	text := script_text(d, el)
	if !has_src && text == "" { return }
	if !parser_inserted && !dom.is_connected(d, el) { return }
	kind, ok := script_kind_of(d, el)
	if !ok { return }
	s.flags[el] = flags + {.Already_Started}
	if !js_enabled(p) { return }
	_, nomodule := dom.get_attribute(d, el, "nomodule")
	if nomodule && kind == .Classic { return }
	nonce, _ := dom.get_attribute(d, el, "nonce")
	if !has_src {
		// inline code: Content-Security-Policy (nonce, hash, 'unsafe-inline')
		if !inline_allowed(p, .Script_Element, text, nonce) { return }
	}
	// legacy event-for scripts: only <script for=window event=onload> (or onload()) runs, at once
	if kind == .Classic {
		ev, has_ev := dom.get_attribute(d, el, "event")
		f, has_for := dom.get_attribute(d, el, "for")
		if has_ev && has_for {
			fv := strings.to_lower(strings.trim_space(f), context.temp_allocator)
			e := strings.to_lower(strings.trim_space(ev), context.temp_allocator)
			if fv != "window" || (e != "onload" && e != "onload()") { return }
		}
	}

	sc := new(Page_Script)
	sc.page = p
	sc.element = el
	sc.kind = kind
	sc.parser_inserted = parser_inserted
	sc.line = 1
	sc.nonce = strings.clone(nonce)
	sc.cors = cors_setting(d, el)
	if rp, has := dom.get_attribute(d, el, "referrerpolicy"); has { sc.referrer = fetch.parse_referrer_policy(rp) }
	if integ, has := dom.get_attribute(d, el, "integrity"); has { sc.integrity = strings.clone(integ) }
	_, sc.async_ = dom.get_attribute(d, el, "async")
	_, sc.defer_ = dom.get_attribute(d, el, "defer")
	is_force_async := !parser_inserted && force_async(flags)
	append(&s.scripts, sc)

	if kind == .Import_Map {
		// an inline import map is registered when it "executes" (at once); an external one is an error
		sc.url = strings.clone(p.env.location.href)
		if has_src {
			sc.state = .Failed
			sc.error = strings.clone("an import map cannot be external (src)")
			post_script_event(p, el, "error")
			log(p, .Error, "<script type=importmap src>: external import maps are not supported by HTML")
			return
		}
		append(&sc.source, ..transmute([]byte)text)
		sc.state = .Ready
		script_execute(p, sc)
		return
	}

	if has_src {
		sc.external = true
		if src == "" {
			sc.state = .Failed
			post_script_event(p, el, "error")
			return
		}
		resolved, okurl := url.parse(src, &p.env.location, context.temp_allocator)
		if !okurl {
			sc.state = .Failed
			sc.url = strings.clone(src)
			log(p, .Error, fmt.tprintf("invalid script URL %q", src))
			post_script_event(p, el, "error")
			return
		}
		sc.url = strings.clone(resolved.href)
		if kind == .Classic {
			sc.download = script_fetch_claim(p, sc.url, sc.cors, sc.nonce, sc.referrer, parser_inserted)
			sc.state = .Fetching
		} else {
			sc.state = .Fetching
			sc.graph = module_graph_for_script(p, sc, resolved.href, nil)
		}
	} else {
		sc.url = strings.clone(p.env.location.href)
		if kind == .Classic {
			append(&sc.source, ..transmute([]byte)text)
			sc.state = .Ready
		} else {
			sc.state = .Fetching
			sc.graph = module_graph_for_script(p, sc, "", transmute([]byte)text)
		}
	}

	// where it waits (HTML "prepare the script element", the last steps)
	ps := &s.parser
	if (kind == .Classic && has_src) || kind == .Module {
		if !sc.async_ && !is_force_async {
			switch {
			case parser_inserted && (kind == .Module || sc.defer_):
				append(&s.deferred, sc)
			case parser_inserted && kind == .Classic:
				ps.pending = sc
			case:
				append(&s.in_order, sc)
			}
		} else {
			append(&s.asap, sc)
		}
		return
	}
	// inline classic
	if parser_inserted && script_blocking_style(p) {
		ps.pending = sc
		ps.waiting_since = now_ms(p)
		return
	}
	script_execute(p, sc)
}

// Whether a parser-blocking script must wait for stylesheets ("has a style sheet that is blocking scripts").
@(private)
script_blocking_style :: proc(p: ^Page) -> bool {
	if !p.settings.js_load.scripts_wait_styles || p.engine == nil { return false }
	s := p.scripts
	if s.parser.waiting_since > 0 && now_ms(p) - s.parser.waiting_since >= p.settings.style.render_block_ms { return false }
	return pending_blocking_sheet(p) != ""
}

// Fires `type` at a script element from a task of its own (HTML "queue an element task on the DOM manipulation task
// source").
@(private)
Script_Event_Task :: struct { node: base.Handle, type: string }

@(private)
post_script_event :: proc(p: ^Page, el: base.Handle, type: string) {
	t := new(Script_Event_Task)
	t^ = {el, type}
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		t := (^Script_Event_Task)(data)
		defer free(t)
		if pg == nil || pg.closed { return }
		dispatch_event(pg, t.node, dom.Event{type = t.type})
		if pg.scripts != nil { scripts_pump(pg) }
	}, t)
}

////////////////////////////////
// Executing (HTML "execute the script element")

@(private)
script_ready :: proc(sc: ^Page_Script) -> bool {
	switch sc.state {
	case .Ready, .Failed, .Done: return true
	case .Fetching:
		if sc.download != nil { return (sc.download.state == .Ready || sc.download.state == .Failed) && !sc.download.compiling }
		if sc.graph != nil { return module_graph_settled(sc.graph) }
	}
	return false
}

@(private)
script_execute :: proc(p: ^Page, sc: ^Page_Script) {
	if sc.state == .Done { return }
	s := p.scripts
	// the result: a fetched classic script (checked), a module graph
	if sc.download != nil && sc.state == .Fetching {
		f := sc.download
		if f.state == .Failed {
			sc.state = .Failed
		} else {
			if f.final_url != "" && f.final_url != sc.url { delete(sc.url); sc.url = strings.clone(f.final_url) }
			if sc.integrity != "" && !integrity_ok(p, sc.integrity, f.bytes[:], f.opaque) {
				log(p, .Error, fmt.tprintf("script %s: its integrity does not match %q (Subresource Integrity): not run", sc.url, sc.integrity))
				sc.state = .Failed
			} else {
				append(&sc.source, ..f.bytes[:])
				sc.state = .Ready
			}
		}
	}
	if sc.graph != nil && sc.state == .Fetching {
		// a graph with an error to rethrow runs (to report it); one that could not be fetched is an error event
		sc.state = module_graph_failed(sc.graph) && !sc.graph.rethrow ? .Failed : .Ready
	}
	failed := sc.state == .Failed
	sc.state = .Done
	if failed {
		dispatch_event(p, sc.element, dom.Event{type = "error"})
		if !p.closed { script_retire(p, sc) }
		return
	}
	if !js_enabled(p) { script_retire(p, sc); return }
	external := sc.external || sc.kind == .Module
	if external { s.ignore_destructive_writes += 1 }
	defer if external { s.ignore_destructive_writes -= 1 }
	s.timing.scripts_run += 1
	switch sc.kind {
	case .Classic:
		prev := s.current
		s.current = sc.element
		parser := sc.parser_inserted
		if parser { s.parser.executing += 1; s.parser.nesting += 1 }
		js_run(p, sc.source[:], sc.url, sc.line)
		if parser { s.parser.executing -= 1; s.parser.nesting -= 1 }
		if p.closed { return }
		s.current = prev
	case .Module:
		prev := s.current
		s.current = base.NIL_HANDLE
		module_graph_run(p, sc.graph)
		if p.closed { return }
		s.current = prev
	case .Import_Map:
		import_map_register(p, string(sc.source[:]), p.env.location.href)
	}
	delete(sc.source)
	sc.source = nil
	if sc.external { dispatch_event(p, sc.element, dom.Event{type = "load"}) }
	if !p.closed { script_retire(p, sc) }
}

// A script that ran (or failed) is forgotten with what it alone used: a page inserting scripts for its whole life
// (JSONP, analytics) keeps no record of them. Nothing refers to it any more: it left every list before running.
@(private)
script_retire :: proc(p: ^Page, sc: ^Page_Script) {
	s := p.scripts
	if s == nil { return }
	for x, i in s.scripts { if x == sc { unordered_remove(&s.scripts, i); break } }
	if f := sc.download; f != nil {
		for x, i in s.fetches { if x == f { unordered_remove(&s.fetches, i); break } }
		script_fetch_free(p, f)
	}
	if g := sc.graph; g != nil && s.modules != nil {
		for x, i in s.modules.graphs { if x == g { ordered_remove(&s.modules.graphs, i); break } }
		graph_free(g)
	}
	script_free(sc)
}

////////////////////////////////
// The event loop's part: what may run now

// Runs what may run now, in HTML's order, then the document's life cycle events. Called whenever something a script
// waits for arrives, and by the poll timer while the page waits for stylesheets or resources.
scripts_pump :: proc(p: ^Page) {
	s := p.scripts
	if s == nil || p.closed || s.pumping { return }
	s.pumping = true
	defer if !p.closed && p.scripts != nil { p.scripts.pumping = false }
	for progressed := true; progressed && !p.closed; {
		progressed = false
		// async scripts: whenever they are ready
		for i := 0; i < len(s.asap); i += 1 {
			sc := s.asap[i]
			if !script_ready(sc) { continue }
			ordered_remove(&s.asap, i)
			script_execute(p, sc)
			progressed = true
			break
		}
		if p.closed { return }
		// scripts inserted by scripts, in order
		if len(s.in_order) > 0 && script_ready(s.in_order[0]) {
			sc := s.in_order[0]
			ordered_remove(&s.in_order, 0)
			script_execute(p, sc)
			progressed = true
			continue
		}
		// the parser's pending parsing-blocking script, then the rest of the document
		ps := &s.parser
		if ps.pending != nil && script_ready(ps.pending) && !script_blocking_style(p) {
			sc := ps.pending
			ps.pending = nil
			ps.waiting_since = 0
			script_execute(p, sc)
			if p.closed { return }
			reveal_run(p)
			progressed = true
			continue
		}
		if the_end(p) { progressed = true }
	}
	if !p.closed { poll_schedule(p) }
}

// HTML "the end": deferred scripts in order, DOMContentLoaded, then (once async and in-order scripts ran and the
// resources that delay it arrived) readyState complete and load. True when it did something.
@(private)
the_end :: proc(p: ^Page) -> bool {
	s := p.scripts
	if !s.parse_done { return false }
	if !s.content_loaded {
		if len(s.deferred) > 0 {
			sc := s.deferred[0]
			if !script_ready(sc) { return false }
			ordered_remove(&s.deferred, 0)
			script_execute(p, sc)
			return true
		}
		s.content_loaded = true
		s.timing.dcl_ms = now_ms(p)
		dispatch_event(p, p.doc.root, dom.Event{type = "DOMContentLoaded", bubbles = true})
		return true
	}
	if s.loaded || len(s.asap) > 0 || len(s.in_order) > 0 { return false }
	if load_delayed(p) { return false }
	s.loaded = true
	s.timing.load_ms = now_ms(p)
	ready_state_set(p, .Complete)
	if p.closed { return true }
	fire_window_event(p, dom.Event{type = "load"})
	if p.closed { return true }
	frames_document_complete(p)   // a nested document: its container's load event (frames.odin)
	fire_window_event(p, dom.Event{type = "pageshow"})
	return true
}

// Whether the document's load event still waits for resources (HTML "delay the load event": images, stylesheets,
// fonts in flight; module graphs and import() count through the scripts lists).
@(private)
load_delayed :: proc(p: ^Page) -> bool {
	s := p.scripts
	ls := &p.settings.js_load
	if !ls.load_waits_resources { return false }
	if ls.load_timeout_ms >= 0 && now_ms(p) - s.timing.dcl_ms >= ls.load_timeout_ms { return false }
	return resources_delay_load(p) || frames_delay_load(p)
}

// The resources in flight that delay a document's load event (stylesheets, @imports, fonts, images); a document
// without scripts uses it too (frames.odin).
resources_delay_load :: proc(p: ^Page) -> bool {
	if !p.settings.js_load.load_waits_resources { return false }
	for _, l in p.link_loads { if l.task != base.NIL_HANDLE { return true } }
	for l in p.import_loads { if l.task != base.NIL_HANDLE { return true } }
	for _, f in p.fonts.faces { if f.state == .Queued || f.state == .Loading { return true } }
	pi := &p.images
	if pi.ready {
		for _, el in pi.elements {
			if el.lazy_wait { continue }
			for r in ([2]^Img_Request{el.current, el.pending}) {
				if r != nil && (r.state == .Queued || r.state == .Loading || r.state == .Probing) { return true }
			}
		}
		if len(pi.events) > 0 { return true }
	}
	return false
}

// While something is waited for that sends no event of its own (stylesheets, images, fonts), look again regularly.
@(private)
poll_schedule :: proc(p: ^Page) {
	s := p.scripts
	waiting := (s.parser.pending != nil && script_ready(s.parser.pending)) || (s.content_loaded && !s.loaded && len(s.asap) == 0 && len(s.in_order) == 0)
	if !waiting || s.poll != base.NIL_HANDLE { return }
	s.poll = host.set_timer(p.loop, p.settings.js_load.poll_ms, 0, proc(data: rawptr) {
		pg := (^Page)(data)
		if pg.closed || pg.scripts == nil { return }
		pg.scripts.poll = base.NIL_HANDLE
		scripts_pump(pg)
	}, p, p.scope)
}

////////////////////////////////
// Fetching classic scripts (and the preload scanner)

// Starts the download of an external script of the document as parsed, before its element is reached.
@(private)
scripts_preload :: proc(p: ^Page, el: base.Handle) {
	d := p.doc
	kind, ok := script_kind_of(d, el)
	if !ok || kind == .Import_Map { return }
	src, has := dom.get_attribute(d, el, "src")
	if !has || src == "" { return }
	if _, nomodule := dom.get_attribute(d, el, "nomodule"); nomodule && kind == .Classic { return }
	resolved, okurl := url.parse(src, &p.env.location, context.temp_allocator)
	if !okurl { return }
	if kind == .Module {
		module_preload(p, resolved.href, cors_setting(d, el))
		return
	}
	s := p.scripts
	for f in s.fetches { if f.url == resolved.href && !f.claimed { return } }
	nonce, _ := dom.get_attribute(d, el, "nonce")
	rp: fetch.Referrer_Policy
	if v, hv := dom.get_attribute(d, el, "referrerpolicy"); hv { rp = fetch.parse_referrer_policy(v) }
	script_fetch_start(p, resolved.href, cors_setting(d, el), nonce, rp, true)
}

@(private)
script_fetch_start :: proc(p: ^Page, u: string, cors: Cors_Setting, nonce: string, referrer: fetch.Referrer_Policy, parser_inserted: bool) -> ^Script_Fetch {
	s := p.scripts
	f := new(Script_Fetch)
	f.page = p
	f.url = strings.clone(u)
	f.cors = cors
	f.state = .Fetching
	f.parser_inserted = parser_inserted
	append(&s.fetches, f)
	mode := cors == .No_Cors ? fetch.Mode.No_Cors : fetch.Mode.Cors
	cred := cors == .Anonymous ? fetch.Credentials.Same_Origin : fetch.Credentials.Include
	f.task = fetch.start(p.loader, {
		request = {url = f.url, mode = mode, credentials = cred, destination = .Script, initiator = &p.env, nonce = nonce,
			referrer_policy = referrer, script = .Classic, parser_inserted = parser_inserted},
		on_event = script_fetch_event, user = f, scope = p.scope, collect = true,
	})
	return f
}

// The download for a script element: its preload when the scanner started one with the same URL and CORS mode.
@(private)
script_fetch_claim :: proc(p: ^Page, u: string, cors: Cors_Setting, nonce: string, referrer: fetch.Referrer_Policy, parser_inserted: bool) -> ^Script_Fetch {
	s := p.scripts
	for f in s.fetches {
		if !f.claimed && f.url == u && f.cors == cors && f.parser_inserted == parser_inserted { f.claimed = true; return f }
	}
	f := script_fetch_start(p, u, cors, nonce, referrer, parser_inserted)
	f.claimed = true
	return f
}

@(private)
script_fetch_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	f := (^Script_Fetch)(user)
	p := f.page
	#partial switch ev.kind {
	case .Response:
		r := ev.response
		f.opaque = r.type == .Opaque
		if r.url != "" { delete(f.final_url); f.final_url = strings.clone(r.url) }
		if r.type != .Opaque && (r.status < 200 || r.status >= 300) {
			delete(f.error)
			f.error = fmt.aprintf("HTTP %d", r.status)
		}
	case .Done:
		f.task = base.NIL_HANDLE
		if f.error != "" {
			f.state = .Failed
			log(p, .Error, fmt.tprintf("script %s: %s", f.url, f.error))
		} else {
			append(&f.bytes, ..ev.data)
			f.state = .Ready
			compile_offthread(p, f)
		}
		scripts_pump(p)
	case .Failed:
		f.task = base.NIL_HANDLE
		f.state = .Failed
		delete(f.error)
		f.error = strings.clone(ev.detail)
		log(p, .Error, fmt.tprintf("script %s: %s", f.url, ev.detail))
		scripts_pump(p)
	}
}

////////////////////////////////
// Content-Security-Policy of inline code

// The base64 digest of `data` with a CSP / SRI algorithm name ("sha256", "sha384", "sha512"), "" when unknown.
digest_base64 :: proc(algo: string, data: []byte) -> string {
	a: Digest_Algorithm
	switch strings.to_lower(algo, context.temp_allocator) {
	case "sha256": a = .SHA256
	case "sha384": a = .SHA384
	case "sha512": a = .SHA512
	case: return ""
	}
	out := make([]byte, digest_size(a), context.temp_allocator)
	if !digest(a, data, out) { return "" }
	enc, err := base64.encode(out, allocator = context.temp_allocator)
	return err == nil ? enc : ""
}

@(private)
csp_digest :: proc(user: rawptr, algo: string, source: string) -> string {
	return digest_base64(algo, transmute([]byte)source)
}

// Subresource Integrity: does `bytes` match the metadata (the strongest algorithm present decides; any of its hashes
// may match)? Unknown algorithms are ignored; metadata with none known allows anything. An opaque response never
// matches.
integrity_ok :: proc(p: ^Page, metadata: string, bytes: []byte, opaque: bool) -> bool {
	strength :: proc(a: string) -> int {
		switch a { case "sha256": return 1; case "sha384": return 2; case "sha512": return 3 }
		return 0
	}
	best := 0
	rest := metadata
	for tok in strings.fields_iterator(&rest) {
		dash := strings.index_byte(tok, '-')
		if dash < 0 { continue }
		best = max(best, strength(strings.to_lower(tok[:dash], context.temp_allocator)))
	}
	if best == 0 { return true }
	if opaque { return false }
	rest = metadata
	for tok in strings.fields_iterator(&rest) {
		dash := strings.index_byte(tok, '-')
		if dash < 0 { continue }
		algo := strings.to_lower(tok[:dash], context.temp_allocator)
		if strength(algo) != best { continue }
		value := tok[dash + 1:]
		if q := strings.index_byte(value, '?'); q >= 0 { value = value[:q] }   // options are ignored
		got := digest_base64(algo, bytes)
		if got != "" && strings.trim_right(got, "=") == strings.trim_right(value, "=") { return true }
	}
	return false
}

@(private)
post_page_task_any :: proc(p: ^Page, fn: Page_Task_Proc, data: rawptr) { post_page_task(p, fn, data) }

// Reports what a verdict found, and whether it allows the code.
@(private)
csp_report :: proc(p: ^Page, v: csp.Verdict) -> bool {
	for viol in v.violations { csp_violation(p, viol) }
	return v.allowed
}

@(private)
inline_allowed :: proc(p: ^Page, kind: csp.Inline_Kind, source: string, nonce: string) -> bool {
	if len(p.env.policies.policies) == 0 { return true }
	return csp_report(p, csp.check_inline(&p.env.policies, kind, source, nonce, csp_digest, p))
}

////////////////////////////////
// The DOM's hooks: scripts and handlers inserted or changed by scripts

@(private)
scripts_install_hooks :: proc(p: ^Page) {
	dom.hooks_set(p.doc, dom.Hooks{user = p, inserted = hook_inserted, attribute = hook_attribute, removed = hook_removed})
}

// A node left the tree: frames whose container went with it are destroyed (frames.odin).
@(private)
hook_removed :: proc(user: rawptr, d: ^dom.Document) {
	p := (^Page)(user)
	if p.closed || d != p.doc { return }
	frames_note_removed(p)
	media_note_removed(p)
}

@(private)
hook_inserted :: proc(user: rawptr, d: ^dom.Document, node: base.Handle) {
	p := (^Page)(user)
	s := p.scripts
	if s == nil || p.closed || d != p.doc || s.parser.revealing > 0 { return }
	n := dom.get(d, node)
	if n == nil { return }
	if n.kind != .Element {
		frames_note_inserted(p, node)   // frame elements get their nested document (frames.odin)
		if p.closed || dom.get(d, node) == nil { return }
		n = dom.get(d, node)
	}
	styles_note_inserted(p, node)   // a <link> a script inserts loads now, not at the next styling (styles.odin)
	media_note_inserted(p, node)    // a <video> / <audio> / <source> (media_element.odin)
	fragment := d.parser_inserting > 0
	// a node inserted into a connected script element that has not started: its text changed ("children changed")
	if parent := dom.get(d, n.parent); is_script_element(parent) && !fragment {
		if script_flags(p, n.parent) & {.Already_Started, .Parser_Inserted} == {} && dom.is_connected(d, n.parent) {
			script_prepare(p, n.parent, parser_inserted = false)
			return
		}
	}
	// the script and frame elements of the inserted subtree, in tree order (HTML's post-connection steps: a script
	// before an iframe runs before that iframe has its document); frames in its shadow trees too
	if n.kind != .Element { return }
	connected := dom.is_connected(d, node)
	found := make([dynamic]base.Handle, context.temp_allocator)
	own_tree := dom.containing_shadow_root(d, node)
	for cur := node; cur != base.NIL_HANDLE; cur = dom.next_shadow_including(d, cur, node) {
		c := dom.get(d, cur)
		if _, ok := is_frame_container(c); ok { append(&found, cur); continue }
		if is_script_element(c) && (len(d.shadow_roots) == 0 || dom.containing_shadow_root(d, cur) == own_tree) { append(&found, cur) }
	}
	for el in found {
		if c := dom.get(d, el); c != nil {
			if _, ok := is_frame_container(c); ok {
				frames_note_inserted(p, el)
				if p.closed { return }
				continue
			}
		} else {
			continue
		}
		if fragment {
			// HTML: scripts made by the fragment parsing algorithm are marked "already started": they never run
			s.flags[el] += {.Already_Started, .From_Fragment}
			continue
		}
		if !connected { continue }
		if script_flags(p, el) & {.Already_Started, .Parser_Inserted} != {} { continue }
		script_prepare(p, el, parser_inserted = false)
		if p.closed { return }
	}
}

@(private)
hook_attribute :: proc(user: rawptr, d: ^dom.Document, el: base.Handle, name: string) {
	p := (^Page)(user)
	if p.closed || d != p.doc { return }
	if p.scripts != nil && p.scripts.parser.revealing > 0 { return }
	if name == "src" || name == "srcdoc" || name == "name" {
		frames_note_attribute(p, el, name)   // (frames.odin)
		if p.closed { return }
	}
	styles_note_attribute(p, el, name)
	media_note_attribute(p, el, name)
	// HTML "update the image data" runs for an <img> whether or not it is in the tree: `new Image()` with src and onload
	// (the canvas idiom) never gets a walk of the document, so the image's record is made now (images.odin)
	if name == "src" || name == "srcset" || name == "sizes" {
		if n := dom.get(d, el); n != nil && n.kind == .Element && n.name == "img" && !dom.is_connected(d, el) { image_element(p, el) }
	}
	if len(name) > 2 && name[0] == 'o' && name[1] == 'n' {
		content_handler_changed(p, el, name)
		return
	}
	if name == "async" {
		// HTML: setting or removing the async attribute clears "force async"
		if n := dom.get(d, el); is_script_element(n) { scripts_of(p).flags[el] += {.Async_Touched} }
		return
	}
	if name == "src" {
		n := dom.get(d, el)
		s := p.scripts
		if s == nil || !is_script_element(n) || s.parser.revealing > 0 { return }
		if script_flags(p, el) & {.Already_Started, .Parser_Inserted} != {} { return }
		if _, has := dom.get_attribute(d, el, "src"); !has { return }
		if dom.is_connected(d, el) { script_prepare(p, el, parser_inserted = false) }
	}
}

////////////////////////////////
// Imports (module "scripts" and the document's own)

HTMLScriptElement_forceAsync :: proc(c: ^Call, element: u64) -> bool {
	if dom.get(c.page.doc, H(element)) == nil { return false }
	return force_async(script_flags(c.page, H(element)))
}

HTMLScriptElement_setForceAsync :: proc(c: ^Call, element: u64, value: bool) {
	if dom.get(c.page.doc, H(element)) == nil { return }
	s := scripts_of(c.page)
	// only clearing it exists (the async IDL attribute's setter); setting it back is what a new element is
	if !value { s.flags[H(element)] += {.Async_Touched} }
}

Script_allowInline :: proc(c: ^Call, element: u64, kind: Api_InlineScriptKind, source: string) -> bool {
	k: csp.Inline_Kind
	switch kind {
	case .Element: k = .Script_Element
	case .Attribute: k = .Script_Attribute
	case .Navigation: k = .Navigation
	}
	if kind == .Attribute && !c.page.settings.js_load.content_handlers { return false }
	return inline_allowed(c.page, k, source, "")
}

Script_allowEval :: proc(c: ^Call, source: string) -> bool {
	p := c.page
	if len(p.env.policies.policies) == 0 { return true }
	return csp_report(p, csp.check_eval(&p.env.policies))
}

Script_baseName :: proc(c: ^Call) -> string {
	return c.page.env.location.href
}

Engine_queueRejectionCheck :: proc(c: ^Call) {
	post_page_task_any(c.page, proc(pg: ^Page, data: rawptr) {
		if pg == nil || pg.closed { return }
		r := pg.js
		if r == nil || r.failed || r.inst == nil || r.inst.dead { return }
		argv := [1]u32{}
		js_call(pg, r.inst, "wj_notify_rejections", argv[:])
	}, nil)
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

// When the document's life cycle steps happened (tests, measurements).
scripts_timing :: proc(p: ^Page) -> Script_Timing {
	if p.scripts == nil { return {} }
	return p.scripts.timing
}
