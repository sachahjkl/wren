package page

// Markup that scripts give the parser (HTML "dynamic markup insertion"): document.write / writeln, document.open /
// close, the result of a javascript: URL; and the scripting flag's effect on parsing (<noscript>).
//
// Written markup is parsed on its own (a document of its own), then its nodes are copied into the page's document as
// lone nodes and spliced into the parser's reveal at its current position (js_load.odin): the parser attaches them
// next, before the rest of the document, and runs their scripts; the inline ones, and any already there, before
// document.write returns (a written external script stops the reveal until it arrived, as a parser-blocking script
// does). Nodes of the written <head> go where the writing script is; those of the written <body> too, unless that
// script is in <head>, then into <body>. Markup is taken a call at a time: a tag split across two writes is not joined
// (the common uses write complete elements).
//
// After the document was parsed, document.write opens it again (document.open: emptied, a "script-created" parser
// that ends at document.close), unless it runs from an external script (ignored, as in browsers).

import "core:fmt"
import "wb:base"
import "wb:dom"
import "wb:html"

////////////////////////////////
// <noscript> with scripting enabled

// HTML parses the content of <noscript> as raw text when scripting is enabled: each noscript element of `d` gets its
// content serialized back to markup, as its one text child. Any thread (the document is not shared yet).
noscript_as_text :: proc(d: ^dom.Document) {
	found := make([dynamic]base.Handle, context.temp_allocator)
	stack := make([dynamic]base.Handle, context.temp_allocator)
	append(&stack, d.root)
	for len(stack) > 0 {
		cur := pop(&stack)
		n := dom.get(d, cur)
		if n == nil { continue }
		if n.kind == .Element && n.name == "noscript" { append(&found, cur); continue }
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).prev { append(&stack, ch) }
	}
	for el in found {
		n := dom.get(d, el)
		if n == nil || n.first_child == base.NIL_HANDLE { continue }
		if n.first_child == n.last_child && dom.get(d, n.first_child).kind == .Text { continue }
		dom.set_text_content(d, el, serialize_html(d, el, false))
	}
}

////////////////////////////////
// Parsing written markup into the page's document

// Parses `markup` and copies its nodes into the page's document (lone, detached): the reveal items, in document order,
// whose top-level nodes go under `target` (and `body_target` for the written body's, when given).
@(private)
markup_items :: proc(p: ^Page, markup: string, target, body_target: base.Handle, whole_document: bool) -> []Reveal_Item {
	tmp := dom.document_create(nil)
	defer dom.document_destroy(tmp)
	html.parse_into(tmp, tmp.root, transmute([]byte)markup, p.settings.html.max_nodes)
	if p.worker == nil && js_enabled(p) { noscript_as_text(tmp) }
	items := make([dynamic]Reveal_Item, context.temp_allocator)
	tops := make([dynamic]Reveal_Item, context.temp_allocator)   // (node in tmp, parent in the page)
	if whole_document {
		for ch := dom.get(tmp, tmp.root).first_child; ch != base.NIL_HANDLE; ch = dom.get(tmp, ch).next { append(&tops, Reveal_Item{ch, target}) }
	} else {
		thead := dom.find_first_by_tag(tmp, "head")
		tbody := dom.find_first_by_tag(tmp, "body")
		for part in ([2]base.Handle{thead, tbody}) {
			pn := dom.get(tmp, part)
			if pn == nil { continue }
			dest := part == tbody && body_target != base.NIL_HANDLE ? body_target : target
			for ch := pn.first_child; ch != base.NIL_HANDLE; ch = dom.get(tmp, ch).next { append(&tops, Reveal_Item{ch, dest}) }
		}
	}
	// copy each top-level subtree, in document order: (copy, its parent in the page)
	Copy :: struct { src, parent: base.Handle }
	stack := make([dynamic]Copy, context.temp_allocator)
	d := p.doc
	for i := len(tops) - 1; i >= 0; i -= 1 { append(&stack, Copy{tops[i].node, tops[i].parent}) }
	for len(stack) > 0 {
		c := pop(&stack)
		n := dom.get(tmp, c.src)
		if n == nil { continue }
		h: base.Handle
		switch n.kind {
		case .Element:
			extra := tmp.ns_extra[c.src]
			h = dom.create_element_ns(d, n.name, n.ns, extra.uri, extra.prefix)
			for a in n.attrs { dom.set_attribute(d, h, a.name, a.value) }
		case .Text: h = dom.create_text(d, n.text)
		case .Comment: h = dom.create_comment(d, n.text)
		case .Doctype:
			if c.parent != d.root { continue }
			public_id, system_id: string
			for a in n.attrs {
				if a.name == "publicId" { public_id = a.value } else if a.name == "systemId" { system_id = a.value }
			}
			h = dom.create_doctype(d, n.name, public_id, system_id)
		case .Document, .Fragment: continue
		}
		append(&items, Reveal_Item{h, c.parent})
		// children pushed in reverse: popped in order
		kids := make([dynamic]base.Handle, context.temp_allocator)
		for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(tmp, ch).next { append(&kids, ch) }
		#reverse for k in kids { append(&stack, Copy{k, h}) }
	}
	return items[:]
}

////////////////////////////////
// document.write / open / close

// Where the parser inserts: under the parent of the script it runs (else the end of the document's body).
@(private)
insertion_parent :: proc(p: ^Page) -> (parent, body_target: base.Handle, whole_document: bool) {
	d := p.doc
	s := p.scripts
	if s.current != base.NIL_HANDLE {
		if n := dom.get(d, s.current); n != nil && n.parent != base.NIL_HANDLE {
			parent = n.parent
			// a script of <head>: written body content goes to <body> (made by the parser: the document's)
			if pn := dom.get(d, parent); pn != nil && pn.kind == .Element && pn.name == "head" { body_target = p.body }
			return
		}
	}
	if dom.get(d, d.root).first_child == base.NIL_HANDLE { return d.root, base.NIL_HANDLE, true }
	if p.body != base.NIL_HANDLE && dom.get(d, p.body) != nil { return p.body, base.NIL_HANDLE, false }
	if p.doc_el != base.NIL_HANDLE && dom.get(d, p.doc_el) != nil { return p.doc_el, base.NIL_HANDLE, false }
	return d.root, base.NIL_HANDLE, false
}

// HTML "document.write()": `markup` at the insertion point (the steps of document.open first when there is none).
document_write :: proc(p: ^Page, markup: string) -> Api_Error {
	if p.worker != nil { return .Invalid_State }
	s := scripts_of(p)
	ps := &s.parser
	ls := &p.settings.js_load
	insertion := ps.active && (ps.script_created || ps.executing > 0)
	if !insertion {
		if s.ignore_destructive_writes > 0 {
			log(p, .Warn, "document.write from an external script after the document was parsed is ignored (it would erase the document)")
			return .None
		}
		if !document_open(p) { return .None }
	}
	if s.write_depth >= ls.write_max_depth {
		log(p, .Warn, fmt.tprintf("document.write nested more than %d deep is ignored (javascript.document_write.max_depth)", ls.write_max_depth))
		return .None
	}
	if s.written + len(markup) > ls.write_max_bytes {
		log(p, .Warn, fmt.tprintf("document.write past %d bytes is ignored (javascript.document_write.max_bytes)", ls.write_max_bytes))
		return .None
	}
	s.written += len(markup)
	parent, body_target, whole := insertion_parent(p)
	ps.revealing += 1   // the copies' attributes register their handlers when revealed, not now
	items := markup_items(p, markup, parent, body_target, whole)
	ps.revealing -= 1
	if len(items) == 0 { return .None }
	// spliced at the parser's position, then revealed now (a nested reveal: its scripts run before write returns)
	inject_at(&ps.queue, ps.next, ..items)
	saved_stop := ps.stop
	ps.stop = ps.next + len(items)
	s.write_depth += 1
	ps.nesting += 1
	reveal_run(p)
	if p.closed { return .None }
	ps.nesting -= 1
	s.write_depth -= 1
	ps.stop = saved_stop >= 0 ? saved_stop + len(items) : -1
	return .None
}

// HTML "document.open()": false when it does nothing (the parser is running a script).
document_open :: proc(p: ^Page) -> bool {
	s := scripts_of(p)
	ps := &s.parser
	if ps.active && ps.nesting > 0 { return false }
	d := p.doc
	// abort the active parser: what it had not attached yet goes
	for it in ps.queue[ps.next:] {
		if n := dom.get(d, it.node); n != nil && n.parent == base.NIL_HANDLE { dom.release(d, it.node) }
	}
	clear(&ps.queue)
	ps.next = 0
	ps.stop = -1
	ps.pending = nil
	clear(&s.deferred)
	// replace all children of the document with nothing
	for {
		root := dom.get(d, d.root)
		if root == nil || root.first_child == base.NIL_HANDLE { break }
		ch := root.first_child
		dom.detach(d, ch)
		dom.release(d, ch)
	}
	p.doc_el, p.head, p.body = base.NIL_HANDLE, base.NIL_HANDLE, base.NIL_HANDLE
	ps.active = true
	ps.script_created = true
	s.ready_state = .Loading
	s.parse_done = false
	s.content_loaded = false
	s.loaded = false
	s.started = true
	if p.doc.hooks.inserted == nil { scripts_install_hooks(p) }
	p.style_stale = true
	return true
}

// HTML "document.close()": the script-created parser reaches its end.
document_close :: proc(p: ^Page) {
	s := p.scripts
	if s == nil { return }
	ps := &s.parser
	if !ps.active || !ps.script_created { return }
	ps.script_created = false
	reveal_run(p)
	scripts_pump(p)
}

// The document becomes `markup` (a javascript: URL's string result).
document_replace :: proc(p: ^Page, markup: string) {
	if !document_open(p) { return }
	document_write(p, markup)
	if p.closed { return }
	document_close(p)
}

Document_writeMarkup :: proc(c: ^Call, markup: string) -> Api_Error {
	return document_write(c.page, markup)
}

Document_openStream :: proc(c: ^Call) -> Api_Error {
	if c.page.worker != nil { return .Invalid_State }
	document_open(c.page)
	return .None
}

Document_closeStream :: proc(c: ^Call) -> Api_Error {
	if c.page.worker != nil { return .Invalid_State }
	document_close(c.page)
	return .None
}
