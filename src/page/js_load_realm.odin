package page

// What script loading asks of the realm beyond running scripts (native/js/runtime/load.c, handlers.c):
//   * starting the realm's loading machinery (wj_load_init: rejection tracker, module loader, eval policy);
//   * event handler content attributes (onclick="..."): registered with the realm when the attribute is set (by the
//     parser's reveal or setAttribute), compiled by the realm on first use;
//   * javascript: URLs (links, location): the script runs in a task of its own, a string result becomes the document.

import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:js"
import "wb:url"
import "wb:wasm"

// Right after wj_realm_start (js_realm.odin).
js_load_realm_started :: proc(p: ^Page, r: ^Js_Realm) {
	argv := [1]u32{}
	wasm.call_raw(r.inst, "wj_load_init", argv[:], 1)
	if embedder.realm_started != nil && p.worker == nil { embedder.realm_started(embedder.user, p) }   // (embedder.odin)
}

// Copies of strings in the engine's memory for one call (freed together).
@(private)
Guest_Strings :: struct {
	inst: ^wasm.Instance,
	ptrs: [8]u32,
	n:    int,
}

@(private)
guest_string :: proc(g: ^Guest_Strings, s: string) -> (ptr, length: u32, ok: bool) {
	if g.n == len(g.ptrs) { return 0, 0, false }
	ptr = js.guest_copy(g.inst, transmute([]byte)s, false)
	if ptr == 0 && len(s) > 0 { return 0, 0, false }
	if ptr == 0 { ptr = js.guest_copy(g.inst, nil, true) }   // an empty string still needs a valid address
	g.ptrs[g.n] = ptr
	g.n += 1
	return ptr, u32(len(s)), true
}

@(private)
guest_strings_free :: proc(g: ^Guest_Strings) {
	for i in 0 ..< g.n { js.guest_free(g.inst, g.ptrs[i]) }
	g.n = 0
}

////////////////////////////////
// Event handler content attributes

// An element under <svg> (outside <foreignObject>): its handlers' parameter is `evt`.
@(private)
in_svg :: proc(d: ^dom.Document, el: base.Handle) -> bool {
	for cur := el; cur != base.NIL_HANDLE; {
		n := dom.get(d, cur)
		if n == nil || n.kind != .Element { return false }
		if n.name == "foreignobject" && cur != el { return false }
		if n.name == "svg" { return true }
		cur = n.parent
	}
	return false
}

// Registers the handlers of every on* attribute `el` has (an element the parser revealed).
content_handlers_register :: proc(p: ^Page, el: base.Handle) {
	n := dom.get(p.doc, el)
	if n == nil || n.kind != .Element || len(n.attrs) == 0 { return }
	names := make([dynamic]string, context.temp_allocator)
	for a in n.attrs {
		if len(a.name) > 2 && a.name[0] == 'o' && a.name[1] == 'n' { append(&names, strings.clone(a.name, context.temp_allocator)) }
	}
	for name in names { content_handler_changed(p, el, name) }
}

// The attribute `name` (on*) of `el` was set, changed or removed: the realm's handler follows.
content_handler_changed :: proc(p: ^Page, el: base.Handle, name: string) {
	if !p.settings.js_load.content_handlers || p.worker != nil { return }
	d := p.doc
	n := dom.get(d, el)
	if n == nil || n.kind != .Element { return }
	r := js_realm(p)
	if r == nil { return }
	value, present := dom.get_attribute(d, el, name)
	value = strings.clone(value, context.temp_allocator)   // the attribute may change while the realm runs
	window_owner := n.name == "body" || n.name == "frameset"
	svg := in_svg(d, el)
	g := Guest_Strings{inst = r.inst}
	defer guest_strings_free(&g)
	np, nl, ok1 := guest_string(&g, name)
	vp, vl, ok2 := guest_string(&g, value)
	if !ok1 || !ok2 { return }
	h := u64(el)
	argv := [10]u32{u32(h), u32(h >> 32), window_owner ? 1 : 0, svg ? 1 : 0, np, nl, vp, vl, present ? 1 : 0, 1}
	js_call(p, r.inst, "wj_content_handler", argv[:])
}

////////////////////////////////
// javascript: URLs

@(private)
Js_Url_Task :: struct { source: string }

// A javascript: URL followed by a link or assigned to location: true when it is one (handled here, in a task of its
// own, as HTML's navigation does: the page stays unless the script's result is a string).
follow_javascript_url :: proc(p: ^Page, target: url.URL) -> bool {
	if p == nil || p.closed || target.scheme != "javascript" { return false }
	if !p.settings.js_load.javascript_urls || p.worker != nil || !js_enabled(p) { return true }
	// the URL serialized, "javascript:" removed, percent-decoded
	encoded := target.href[len("javascript:"):]
	bytes := make([dynamic]byte, 0, len(encoded), context.temp_allocator)
	hex :: proc(c: u8) -> (u8, bool) {
		switch c {
		case '0' ..= '9': return c - '0', true
		case 'a' ..= 'f': return c - 'a' + 10, true
		case 'A' ..= 'F': return c - 'A' + 10, true
		}
		return 0, false
	}
	for i := 0; i < len(encoded); i += 1 {
		c := encoded[i]
		if c == '%' && i + 2 < len(encoded) {
			hi, ok1 := hex(encoded[i + 1])
			lo, ok2 := hex(encoded[i + 2])
			if ok1 && ok2 { append(&bytes, hi << 4 | lo); i += 2; continue }
		}
		append(&bytes, c)
	}
	decoded := url.utf8_decode(bytes[:], context.temp_allocator)
	t := new(Js_Url_Task)
	t.source = strings.clone(decoded)
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		t := (^Js_Url_Task)(data)
		defer { delete(t.source); free(t) }
		if pg == nil || pg.closed { return }
		javascript_url_run(pg, t.source)
	}, t)
	return true
}

@(private)
javascript_url_run :: proc(p: ^Page, source: string) {
	if !inline_allowed(p, .Navigation, source, "") { return }
	r := js_realm(p)
	if r == nil { return }
	src := js.guest_copy(r.inst, transmute([]byte)source)
	if src == 0 { return }
	defer js.guest_free(r.inst, src)
	argv := [2]u32{src, u32(len(source))}
	js_call(p, r.inst, "wj_eval_javascript_url", argv[:])
	js_after_task(p, r, "javascript: URL")
}

// The string a javascript: URL evaluated to: the document becomes that markup (HTML "evaluate a javascript: URL").
Script_javascriptResult :: proc(c: ^Call, html: string) {
	p := c.page
	if p.worker != nil { return }
	t := new(Js_Url_Task)
	t.source = strings.clone(html)
	// after the script's task: the document is replaced from a task of its own
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		t := (^Js_Url_Task)(data)
		defer { delete(t.source); free(t) }
		if pg == nil || pg.closed { return }
		document_replace(pg, t.source)
	}, t)
}
