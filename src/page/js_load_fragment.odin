package page

// Script elements made by the fragment parsing algorithm and by cloning (HTML "prepare the script element", "already
// started"): the fragment parser marks its scripts already started (hook_inserted, js_load.odin), so markup set by
// innerHTML never runs; Range.createContextualFragment unmarks them, so they run once inserted, except a script the
// markup left open; a clone of a script element keeps the original's flag (HTML's cloning steps).

import "core:strings"
import "wb:base"
import "wb:dom"

// DOM Range.createContextualFragment(markup) (HTML "fragment parsing algorithm steps" of the DOM Parsing spec).
Range_createContextualFragment :: proc(c: ^Call, start: Api_Node, markup: string) -> (u64, Api_Error) {
	p := c.page
	d := p.doc
	// the context element: the start node, the parent element of a Text or a Comment; a <body> without one or for
	// the <html> element of an HTML document
	ctx := base.NIL_HANDLE
	#partial switch start.data.kind {
	case .Element: ctx = H(start.handle)
	case .Text, .Comment:
		if pn := dom.get(d, start.data.parent); pn != nil && pn.kind == .Element { ctx = start.data.parent }
	}
	if n := dom.get(d, ctx); n != nil && n.ns == .HTML && n.name == "html" { ctx = base.NIL_HANDLE }
	frag, err := parse_fragment_for(c, ctx, markup)
	if err != .None { return 0, err }
	unclosed := unclosed_script(d, frag, markup)
	if p.worker != nil { return u64(frag), .None }
	s := scripts_of(p)
	for cur := frag; cur != base.NIL_HANDLE; cur = dom.next_shadow_including(d, cur, frag) {
		if !is_script_element(dom.get(d, cur)) { continue }
		if cur == unclosed { s.flags[cur] += {.Already_Started}; continue }
		if f, ok := s.flags[cur]; ok { s.flags[cur] = f - {.Already_Started} }
	}
	return u64(frag), .None
}

// The script element the fragment parser was still in at the end of `markup` (HTML: "An end-of-file token" in the
// "text" insertion mode marks the current script element already started), or NIL. The parser's tree does not say
// so: that script is the fragment's last node in tree order (or the parent of its last Text), and the markup ends
// with the '>' of a <script> start tag followed by exactly its text (newlines normalized as the parser does).
@(private)
unclosed_script :: proc(d: ^dom.Document, frag: base.Handle, markup: string) -> base.Handle {
	last := frag
	for {
		n := dom.get(d, last)
		if n == nil || n.last_child == base.NIL_HANDLE { break }
		last = n.last_child
	}
	n := dom.get(d, last)
	if n == nil { return base.NIL_HANDLE }
	script := last
	if n.kind == .Text { script = n.parent }
	if !is_script_element(dom.get(d, script)) { return base.NIL_HANDLE }
	text := script_text(d, script)
	src := markup
	if strings.contains_rune(src, '\r') {
		src, _ = strings.replace_all(src, "\r\n", "\n", context.temp_allocator)
		src, _ = strings.replace_all(src, "\r", "\n", context.temp_allocator)
	}
	if !strings.has_suffix(src, text) { return base.NIL_HANDLE }
	head := src[:len(src) - len(text)]
	if !strings.has_suffix(head, ">") { return base.NIL_HANDLE }
	lt := strings.last_index_byte(head, '<')
	if lt < 0 || len(head) - lt < len("<script>") { return base.NIL_HANDLE }
	if !strings.equal_fold(head[lt:lt + 7], "<script") { return base.NIL_HANDLE }
	switch head[lt + 7] {
	case '\t', '\n', '\f', '\r', ' ', '/', '>': return script
	}
	return base.NIL_HANDLE
}

// HTML's cloning steps of script elements over a clone of `src` (cloneNode, importNode, a range's cloned contents):
// each clone of a script is already started when its original is. Both trees have the same shape (dom.clone_node).
scripts_cloned :: proc(p: ^Page, src, clone: base.Handle) {
	s := p.scripts
	if s == nil || len(s.flags) == 0 { return }
	d := p.doc
	a, b := src, clone
	for a != base.NIL_HANDLE && b != base.NIL_HANDLE {
		if is_script_element(dom.get(d, a)) && .Already_Started in s.flags[a] { s.flags[b] += {.Already_Started} }
		a = dom.next_in_tree(d, a, src)
		b = dom.next_in_tree(d, b, clone)
	}
}
