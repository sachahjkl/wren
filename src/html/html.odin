// Package html: HTML5 parsing into the browser's DOM. Lexbor does the tokenizer + tree construction (it implements the
// specification's error recovery); a small C shim replays its tree as events and we build our own DOM from them, so
// nothing of Lexbor's memory or layout is visible here and it is freed before `parse` returns.
//
// The input is UTF-8 (charset.odin decodes documents first); `<template>` contents are replayed into their fragments.
// The node count of one parse is capped (html.max_nodes): what is past it is dropped.
package html

import "base:runtime"
import "core:strings"
import "wb:base"
import "wb:dom"

when ODIN_OS == .Windows {
	foreign import lexbor {
		"../../build/lexbor/lexbor.lib",
		"system:msvcrt.lib",
		"system:ucrt.lib",
		"system:libvcruntime.lib",
		"system:legacy_stdio_definitions.lib",
	}
} else {
	foreign import lexbor { "../../build/lexbor-" + ODIN_OS_STRING + "/liblexbor.a" }   // tools/build_lexbor.sh
}

Shim_Attr :: struct {
	name:      [^]u8,
	name_len:  uint,
	value:     [^]u8,
	value_len: uint,
}

Shim_Sink :: struct {
	open:    proc "c" (user: rawptr, tag: [^]u8, tag_len: uint, attrs: [^]Shim_Attr, n_attrs: uint),
	close:   proc "c" (user: rawptr),
	text:    proc "c" (user: rawptr, s: [^]u8, len: uint),
	comment: proc "c" (user: rawptr, s: [^]u8, len: uint),
	mode:    proc "c" (user: rawptr, compat_mode: i32),
}

// The second version of the shim (src/shim/wb_html_dom.c): namespaces, the doctype, template contents, fragments.
Shim_Sink2 :: struct {
	open:     proc "c" (user: rawptr, tag: [^]u8, tag_len: uint, attrs: [^]Shim_Attr, n_attrs: uint, ns: i32),
	close:    proc "c" (user: rawptr),
	text:     proc "c" (user: rawptr, s: [^]u8, len: uint),
	comment:  proc "c" (user: rawptr, s: [^]u8, len: uint),
	mode:     proc "c" (user: rawptr, compat_mode: i32),
	doctype:  proc "c" (user: rawptr, name: [^]u8, name_len: uint, public_id: [^]u8, public_len: uint, system_id: [^]u8, system_len: uint),
	template_begin: proc "c" (user: rawptr),
	template_end:   proc "c" (user: rawptr),
}

@(default_calling_convention = "c")
foreign lexbor {
	wb_html_parse :: proc(data: [^]u8, len: uint, sink: ^Shim_Sink, user: rawptr) -> i32 ---
	wb_html_parse2 :: proc(data: [^]u8, len: uint, sink: ^Shim_Sink2, user: rawptr) -> i32 ---
	wb_html_parse_fragment :: proc(data: [^]u8, len: uint, ctx_tag: [^]u8, ctx_len: uint, ctx_ns: i32, quirks: i32, sink: ^Shim_Sink2, user: rawptr) -> i32 ---
}

Builder :: struct {
	max_nodes: int,
	doc:       ^dom.Document,
	stack:     [dynamic]base.Handle,
	count:     int,
	truncated: bool,
	mode:      dom.Document_Mode,
	shadow_ok: bool,   // declarative shadow roots are attached (documents, setHTMLUnsafe; not innerHTML)
	dsd_pending: bool, // a declarative shadow root was just attached: the template_begin that may follow enters it
	ctx:       runtime.Context,   // the caller's: the nodes are made with its allocators
}

@(private)
b_open2 :: proc "c" (user: rawptr, tag: [^]u8, tag_len: uint, attrs: [^]Shim_Attr, n_attrs: uint, ns: i32) {
	if ns == 0 && view(tag, tag_len) == "template" && b_declarative_shadow(user, attrs, n_attrs) { return }
	b_open(user, tag, tag_len, attrs, n_attrs)
	bd := (^Builder)(user)
	context = bd.ctx
	top := bd.stack[len(bd.stack) - 1]
	if n := dom.get(bd.doc, top); n != nil && n.kind == .Element {
		switch ns {
		case 1: n.ns = .SVG
		case 2: n.ns = .MathML
		case 3: n.ns = .Other
		}
	}
}

@(private)
b_doctype :: proc "c" (user: rawptr, name: [^]u8, name_len: uint, public_id: [^]u8, public_len: uint, system_id: [^]u8, system_len: uint) {
	b := (^Builder)(user)
	context = b.ctx
	parent := b.stack[len(b.stack) - 1]
	if b.truncated || parent == base.NIL_HANDLE || b.count >= b.max_nodes { return }
	dom.append_child(b.doc, parent, dom.create_doctype(b.doc, view(name, name_len), view(public_id, public_len), view(system_id, system_len)))
	b.count += 1
}

// A <template shadowrootmode> (HTML §13.2.6.4.7 "A start tag whose tag name is template", declarative shadow roots):
// when the parse allows them and the current node can host one, the template is not inserted; its contents go into
// a shadow root attached to the current node (which the template_begin that follows enters). Otherwise (no valid
// mode, a host already, an element that cannot host) it is an ordinary template.
@(private)
b_declarative_shadow :: proc "c" (user: rawptr, attrs: [^]Shim_Attr, n_attrs: uint) -> bool {
	b := (^Builder)(user)
	context = b.ctx
	if !b.shadow_ok || b.truncated || b.count >= b.max_nodes { return false }
	init: dom.Shadow_Init
	init.declarative = true
	has_mode := false
	for i in 0 ..< int(n_attrs) {
		a := attrs[i]
		switch view(a.name, a.name_len) {
		case "shadowrootmode":
			v := view(a.value, a.value_len)
			if strings.equal_fold(v, "open") { init.mode = .Open; has_mode = true } else if strings.equal_fold(v, "closed") { init.mode = .Closed; has_mode = true }
		case "shadowrootdelegatesfocus": init.delegates_focus = true
		case "shadowrootclonable": init.clonable = true
		case "shadowrootserializable": init.serializable = true
		case "shadowrootslotassignment": if strings.equal_fold(view(a.value, a.value_len), "manual") { init.slot_assignment = .Manual }
		}
	}
	if !has_mode { return false }
	host := b.stack[len(b.stack) - 1]
	if host == base.NIL_HANDLE || dom.shadow_root_of(b.doc, host) != base.NIL_HANDLE { return false }
	root, err := dom.attach_shadow(b.doc, host, init)
	if err != .None { return false }
	append(&b.stack, root)   // what the template's close pops
	b.dsd_pending = true
	b.count += 1
	return true
}

// The contents of the template just opened: built in its DocumentFragment (dom.template_content), not under it.
@(private)
b_template_begin :: proc "c" (user: rawptr) {
	b := (^Builder)(user)
	context = b.ctx
	tpl := b.stack[len(b.stack) - 1]
	if b.dsd_pending {
		// a declarative shadow root: its contents go into the root itself
		b.dsd_pending = false
		append(&b.stack, tpl)
		return
	}
	if b.truncated || tpl == base.NIL_HANDLE { append(&b.stack, base.NIL_HANDLE); return }
	append(&b.stack, dom.template_content(b.doc, tpl))
}

@(private)
b_template_end :: proc "c" (user: rawptr) {
	b := (^Builder)(user)
	context = b.ctx
	if len(b.stack) > 1 { pop(&b.stack) }
}

@(private)
SINK2 :: Shim_Sink2{open = b_open2, close = b_close, text = b_text, comment = b_comment, mode = b_mode, doctype = b_doctype, template_begin = b_template_begin, template_end = b_template_end}

@(private)
b_mode :: proc "c" (user: rawptr, compat_mode: i32) {
	b := (^Builder)(user)
	switch compat_mode {
	case 1: b.mode = .Quirks
	case 2: b.mode = .Limited_Quirks
	case: b.mode = .No_Quirks
	}
}

@(private)
view :: #force_inline proc "contextless" (p: [^]u8, n: uint) -> string {
	if p == nil || n == 0 { return "" }
	return string(p[:n])
}

@(private)
b_open :: proc "c" (user: rawptr, tag: [^]u8, tag_len: uint, attrs: [^]Shim_Attr, n_attrs: uint) {
	b := (^Builder)(user)
	context = b.ctx
	b.dsd_pending = false
	// keep the stack balanced even when truncated: close callbacks always pop
	if b.truncated || b.count >= b.max_nodes {
		b.truncated = true
		append(&b.stack, base.NIL_HANDLE)
		return
	}
	d := b.doc
	el := dom.create_element(d, view(tag, tag_len))
	for i in 0 ..< int(n_attrs) {
		a := attrs[i]
		dom.set_attribute(d, el, view(a.name, a.name_len), view(a.value, a.value_len))
	}
	dom.append_child(d, b.stack[len(b.stack) - 1], el)
	append(&b.stack, el)
	b.count += 1
}

@(private)
b_close :: proc "c" (user: rawptr) {
	b := (^Builder)(user)
	context = b.ctx
	b.dsd_pending = false
	if len(b.stack) > 1 { pop(&b.stack) }
}

@(private)
b_text :: proc "c" (user: rawptr, s: [^]u8, n: uint) {
	b := (^Builder)(user)
	context = b.ctx
	parent := b.stack[len(b.stack) - 1]
	if b.truncated || parent == base.NIL_HANDLE || b.count >= b.max_nodes { return }
	dom.append_child(b.doc, parent, dom.create_text(b.doc, view(s, n)))
	b.count += 1
}

@(private)
b_comment :: proc "c" (user: rawptr, s: [^]u8, n: uint) {
	b := (^Builder)(user)
	context = b.ctx
	parent := b.stack[len(b.stack) - 1]
	if b.truncated || parent == base.NIL_HANDLE || b.count >= b.max_nodes { return }
	dom.append_child(b.doc, parent, dom.create_comment(b.doc, view(s, n)))
	b.count += 1
}

Parse_Result :: struct {
	ok:        bool,
	truncated: bool,
	status:    i32,
	nodes:     int,
}

// Parses `data` and appends the resulting tree under `parent` (normally the Document node).
// `declarative_shadow`: <template shadowrootmode> attaches shadow roots (not for DOMParser).
parse_into :: proc(d: ^dom.Document, parent: base.Handle, data: []byte, max_nodes: int, declarative_shadow := true) -> Parse_Result {
	b := Builder{doc = d, max_nodes = max_nodes, shadow_ok = declarative_shadow, ctx = context}
	defer delete(b.stack)
	append(&b.stack, parent)
	// the document's mutation hooks see parser-made nodes (scripts of a fragment never run: page/js_load.odin)
	d.parser_inserting += 1
	defer d.parser_inserting -= 1
	sink := SINK2
	status := wb_html_parse2(raw_data(data), uint(len(data)), &sink, &b)
	// a whole document (not a fragment parsed into an element) decides the document's mode
	if status == 0 && parent == d.root { d.mode = b.mode }
	return {ok = status == 0, truncated = b.truncated, status = status, nodes = b.count}
}

// HTML's fragment parsing algorithm (innerHTML, insertAdjacentHTML...): `data` parsed as the contents of an element
// named `context_tag` of namespace `context_ns` (lower case), in a document of mode `mode`. The nodes are built into
// a new DocumentFragment (detached, owned by the caller). ok = false: the parser failed (the fragment is empty).
// `declarative_shadow`: <template shadowrootmode> attaches shadow roots (setHTMLUnsafe; innerHTML does not).
parse_fragment :: proc(d: ^dom.Document, context_tag: string, context_ns: dom.Namespace, mode: dom.Document_Mode, data: []byte, max_nodes: int, declarative_shadow := false) -> (fragment: base.Handle, result: Parse_Result) {
	fragment = dom.create_fragment(d)
	b := Builder{doc = d, max_nodes = max_nodes, shadow_ok = declarative_shadow, ctx = context}
	defer delete(b.stack)
	append(&b.stack, fragment)
	sink := SINK2
	ns: i32 = context_ns == .SVG ? 1 : context_ns == .MathML ? 2 : 0
	quirks: i32 = mode == .Quirks ? 1 : mode == .Limited_Quirks ? 2 : 0
	tag := context_tag != "" ? context_tag : "body"
	status := wb_html_parse_fragment(raw_data(data), uint(len(data)), raw_data(tag), uint(len(tag)), ns, quirks, &sink, &b)
	return fragment, {ok = status == 0, truncated = b.truncated, status = status, nodes = b.count}
}

// The text of the document's <title>, for the tab strip.
title :: proc(d: ^dom.Document, allocator := context.temp_allocator) -> string {
	t := dom.find_first_by_tag(d, "title")
	if t == base.NIL_HANDLE { return "" }
	return strings.trim_space(dom.text_content(d, t, allocator))
}

// Handles of the document's <script> elements whose `type` is `script_type` (preference `html.module_script_type`,
// "application/wasm" by default), in document order (iterative walk). Which markup names a module is configuration, not
// code: one preference to change if the syntax ever does.
wasm_scripts :: proc(d: ^dom.Document, script_type: string, allocator := context.temp_allocator) -> []base.Handle {
	out := make([dynamic]base.Handle, allocator)
	stack: [dynamic]base.Handle
	defer delete(stack)
	append(&stack, d.root)
	for len(stack) > 0 {
		cur := pop(&stack)
		n := dom.get(d, cur)
		if n == nil { continue }
		if n.kind == .Element && n.name == "script" {
			ty, _ := dom.get_attribute(d, cur, "type")
			if strings.equal_fold(strings.trim_space(ty), script_type) { append(&out, cur) }
		}
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).prev { append(&stack, ch) }
	}
	return out[:]
}
