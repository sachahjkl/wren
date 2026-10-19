// Package html: HTML5 parsing into the browser's DOM. Lexbor does the tokenizer + tree construction (it implements the
// specification's error recovery); a small C shim replays its tree as events and we build our own DOM from them, so
// nothing of Lexbor's memory or layout is visible here and it is freed before `parse` returns.
//
// Limits: input is assumed UTF-8 (charset sniffing comes with Content-Type handling), `<template>` contents are not
// replayed, and the node count is capped so a hostile document cannot exhaust memory.
package html

import "base:runtime"
import "core:strings"
import "wb:base"
import "wb:dom"

foreign import lexbor {
	"../../build/lexbor/lexbor.lib",
	"system:msvcrt.lib",
	"system:ucrt.lib",
	"system:vcruntime.lib",
	"system:legacy_stdio_definitions.lib",
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

@(default_calling_convention = "c")
foreign lexbor {
	wb_html_parse :: proc(data: [^]u8, len: uint, sink: ^Shim_Sink, user: rawptr) -> i32 ---
}

Builder :: struct {
	max_nodes: int,
	doc:       ^dom.Document,
	stack:     [dynamic]base.Handle,
	count:     int,
	truncated: bool,
	mode:      dom.Document_Mode,
}

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
	context = runtime.default_context()
	b := (^Builder)(user)
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
	context = runtime.default_context()
	b := (^Builder)(user)
	if len(b.stack) > 1 { pop(&b.stack) }
}

@(private)
b_text :: proc "c" (user: rawptr, s: [^]u8, n: uint) {
	context = runtime.default_context()
	b := (^Builder)(user)
	parent := b.stack[len(b.stack) - 1]
	if b.truncated || parent == base.NIL_HANDLE || b.count >= b.max_nodes { return }
	dom.append_child(b.doc, parent, dom.create_text(b.doc, view(s, n)))
	b.count += 1
}

@(private)
b_comment :: proc "c" (user: rawptr, s: [^]u8, n: uint) {
	context = runtime.default_context()
	b := (^Builder)(user)
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
parse_into :: proc(d: ^dom.Document, parent: base.Handle, data: []byte, max_nodes: int) -> Parse_Result {
	b := Builder{doc = d, max_nodes = max_nodes}
	defer delete(b.stack)
	append(&b.stack, parent)
	// the document's mutation hooks see parser-made nodes (scripts of a fragment never run: page/js_load.odin)
	d.parser_inserting += 1
	defer d.parser_inserting -= 1
	sink := Shim_Sink{open = b_open, close = b_close, text = b_text, comment = b_comment, mode = b_mode}
	status := wb_html_parse(raw_data(data), uint(len(data)), &sink, &b)
	// a whole document (not a fragment parsed into an element) decides the document's mode
	if status == 0 && parent == d.root { d.mode = b.mode }
	return {ok = status == 0, truncated = b.truncated, status = status, nodes = b.count}
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
