package page

// Markup for JavaScript: the HTML fragment serialization algorithm (innerHTML / outerHTML getters, HTML §13.3), the
// fragment parsing algorithm through Lexbor in the element's context (setters, insertAdjacentHTML; html.parse_fragment),
// and innerText / outerText.

import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:html"
import lay "wb:layout"
import "wb:style"

@(private)
VOID_ELEMENTS :: [?]string{"area", "base", "basefont", "bgsound", "br", "col", "embed", "frame", "hr", "img", "input", "keygen", "link", "meta", "param", "source", "track", "wbr"}

@(private)
is_void_element :: proc(n: ^dom.Node) -> bool {
	if n.ns != .HTML { return false }
	for v in VOID_ELEMENTS { if n.name == v { return true } }
	return false
}

// Children of these are serialized as they are (HTML: "the text of a raw text element").
@(private)
is_raw_text_parent :: proc(n: ^dom.Node) -> bool {
	if n == nil || n.kind != .Element || n.ns != .HTML { return false }
	switch n.name {
	case "style", "script", "xmp", "iframe", "noembed", "noframes", "plaintext", "noscript": return true
	}
	return false
}

@(private)
write_escaped_text :: proc(b: ^strings.Builder, s: string, attr: bool) {
	start := 0
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		rep := ""
		switch c {
		case '&': rep = "&amp;"
		case '<': rep = "&lt;"
		case '>': rep = "&gt;"
		case '"': if attr { rep = "&quot;" }
		case 0xC2:
			if i + 1 < len(s) && s[i + 1] == 0xA0 {   // U+00A0
				strings.write_string(b, s[start:i])
				strings.write_string(b, "&nbsp;")
				i += 1
				start = i + 1
			}
			continue
		}
		if rep == "" { continue }
		strings.write_string(b, s[start:i])
		strings.write_string(b, rep)
		start = i + 1
	}
	strings.write_string(b, s[start:])
}

// The serialized name of an element (HTML: the qualified name of a foreign element, the local name otherwise).
@(private)
serialized_tag :: proc(d: ^dom.Document, h: base.Handle, n: ^dom.Node) -> string {
	#partial switch n.ns {
	case .HTML, .SVG, .MathML: return jd_local_name(n)
	}
	return jd_qualified_name(d, h, false)
}

// What getHTML() serializes besides the node tree: the shadow roots of hosts, as declarative shadow roots (HTML
// "serialize children": those serializable when `serializable`, and those listed).
Shadow_Serialize :: struct {
	serializable: bool,
	roots:        []base.Handle,
}

// Serializes the children of `h` (and `h` itself when `outer`) into `b`.
@(private)
serialize_node :: proc(d: ^dom.Document, b: ^strings.Builder, h: base.Handle, outer: bool, shadow: ^Shadow_Serialize = nil) {
	Step :: struct { h: base.Handle, close: bool, template: bool }   // template: a shadow root's <template>, then its close
	stack := make([dynamic]Step, 0, 64, context.temp_allocator)
	wants_shadow :: proc(d: ^dom.Document, shadow: ^Shadow_Serialize, root: base.Handle) -> bool {
		if shadow == nil || root == base.NIL_HANDLE { return false }
		if info := dom.shadow_info(d, root); info != nil && shadow.serializable && info.serializable { return true }
		for r in shadow.roots { if r == root { return true } }
		return false
	}
	push_children :: proc(d: ^dom.Document, stack: ^[dynamic]Step, h: base.Handle) {
		n := dom.get(d, h)
		src := h
		// a template serializes its contents
		if n.kind == .Element && n.ns == .HTML && n.name == "template" {
			if content, ok := d.templates[h]; ok && dom.get(d, content) != nil { src = content }
		}
		for ch := dom.get(d, src).last_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).prev { append(stack, Step{h = ch}) }
	}
	if outer { append(&stack, Step{h = h}) } else {
		push_children(d, &stack, h)
		if n := dom.get(d, h); n != nil && n.kind == .Element && wants_shadow(d, shadow, n.shadow) { append(&stack, Step{h = n.shadow, template = true}) }
	}
	for len(stack) > 0 {
		s := pop(&stack)
		n := dom.get(d, s.h)
		if n == nil { continue }
		if s.template {
			if s.close { strings.write_string(b, "</template>"); continue }
			info := dom.shadow_info(d, s.h)
			strings.write_string(b, info != nil && info.mode == .Closed ? `<template shadowrootmode="closed"` : `<template shadowrootmode="open"`)
			if info != nil && info.delegates_focus { strings.write_string(b, ` shadowrootdelegatesfocus=""`) }
			if info != nil && info.serializable { strings.write_string(b, ` shadowrootserializable=""`) }
			if info != nil && info.slot_assignment == .Manual { strings.write_string(b, ` shadowrootslotassignment="manual"`) }
			if info != nil && info.clonable { strings.write_string(b, ` shadowrootclonable=""`) }
			strings.write_byte(b, '>')
			append(&stack, Step{h = s.h, close = true, template = true})
			push_children(d, &stack, s.h)
			continue
		}
		if s.close {
			strings.write_string(b, "</")
			strings.write_string(b, serialized_tag(d, s.h, n))
			strings.write_byte(b, '>')
			continue
		}
		switch n.kind {
		case .Element:
			strings.write_byte(b, '<')
			strings.write_string(b, serialized_tag(d, s.h, n))
			for a in n.attrs {
				strings.write_byte(b, ' ')
				strings.write_string(b, jd_attr_name(n, a.name))
				strings.write_string(b, "=\"")
				write_escaped_text(b, a.value, true)
				strings.write_byte(b, '"')
			}
			strings.write_byte(b, '>')
			if is_void_element(n) { continue }
			append(&stack, Step{h = s.h, close = true})
			push_children(d, &stack, s.h)
			if wants_shadow(d, shadow, n.shadow) { append(&stack, Step{h = n.shadow, template = true}) }   // before the children
		case .Text:
			if is_raw_text_parent(dom.get(d, n.parent)) { strings.write_string(b, n.text) } else { write_escaped_text(b, n.text, false) }
		case .Comment:
			strings.write_string(b, "<!--")
			strings.write_string(b, n.text)
			strings.write_string(b, "-->")
		case .Doctype:
			strings.write_string(b, "<!DOCTYPE ")
			strings.write_string(b, n.name)
			strings.write_byte(b, '>')
		case .Document, .Fragment:
			push_children(d, &stack, s.h)
		}
	}
}

serialize_html :: proc(d: ^dom.Document, h: base.Handle, outer: bool, allocator := context.temp_allocator, shadow: ^Shadow_Serialize = nil) -> string {
	b := strings.builder_make(allocator)
	serialize_node(d, &b, h, outer, shadow)
	return strings.to_string(b)
}

Element_innerHTML :: proc(c: ^Call, element: Api_Element) -> string { return serialize_html(c.page.doc, H(element.handle), false) }

Element_outerHTML :: proc(c: ^Call, element: Api_Element) -> string { return serialize_html(c.page.doc, H(element.handle), true) }

// HTML's fragment parsing algorithm with `context` (an element) as the context element: a new fragment.
@(private)
parse_fragment_for :: proc(c: ^Call, context_el: base.Handle, markup: string, declarative_shadow := false) -> (base.Handle, Api_Error) {
	d := c.page.doc
	n := dom.get(d, context_el)
	tag, ns := "body", dom.Namespace.HTML
	if n != nil && n.kind == .Element {
		tag, ns = n.name, n.ns
		if ns == .None || ns == .Other { tag, ns = "body", .HTML }   // foreign elements of unknown namespaces: as HTML
	}
	// (the parser's own insertions: the custom elements it makes are upgraded even in a tree that is not connected)
	d.parser_inserting += 1
	frag, res := html.parse_fragment(d, tag, ns, d.mode, transmute([]byte)markup, c.page.settings.dom.max_fragment_nodes, declarative_shadow)
	d.parser_inserting -= 1
	if !res.ok {
		dom.destroy_unpinned(d, frag)
		return base.NIL_HANDLE, fail(c, .Syntax, "the markup could not be parsed")
	}
	if res.truncated { log(c.page, .Warn, "innerHTML: the markup has more nodes than javascript.dom.max_fragment_nodes; the rest was dropped") }
	return frag, .None
}

Element_set_innerHTML :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error {
	d := c.page.doc
	h := H(element.handle)
	frag, err := parse_fragment_for(c, h, value)
	if err != .None { return err }
	target := h
	if element.data.ns == .HTML && element.data.name == "template" { target = dom.template_content(d, h) }
	replace_all(d, target, frag)
	dom.destroy_unpinned(d, frag)
	return .None
}

Element_set_outerHTML :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error {
	d := c.page.doc
	h := H(element.handle)
	parent := element.data.parent
	if parent == base.NIL_HANDLE { return .None }
	pn := dom.get(d, parent)
	if pn.kind == .Document { return fail(c, .No_Modification_Allowed, "Failed to set the 'outerHTML' property on 'Element': This element's parent is of type '#document'.") }
	ctx := parent
	if pn.kind == .Fragment { ctx = base.NIL_HANDLE }   // a body context
	frag, err := parse_fragment_for(c, ctx, value)
	if err != .None { return err }
	err = replace_child(c, parent, frag, h)
	dom.destroy_unpinned(d, frag)
	return err
}

// The position argument of insertAdjacent*: 0 beforebegin, 1 afterbegin, 2 beforeend, 3 afterend.
@(private)
adjacent_position :: proc(position: string) -> (int, bool) {
	switch {
	case strings.equal_fold(position, "beforebegin"): return 0, true
	case strings.equal_fold(position, "afterbegin"): return 1, true
	case strings.equal_fold(position, "beforeend"): return 2, true
	case strings.equal_fold(position, "afterend"): return 3, true
	}
	return 0, false
}

// DOM "insert adjacent": false (and nothing done) when there is no parent for the outer positions.
@(private)
insert_adjacent :: proc(c: ^Call, h: base.Handle, pos: int, node: base.Handle) -> (bool, Api_Error) {
	d := c.page.doc
	n := dom.get(d, h)
	switch pos {
	case 0:
		if n.parent == base.NIL_HANDLE { return false, .None }
		return true, pre_insert(c, n.parent, node, h)
	case 1: return true, pre_insert(c, h, node, n.first_child)
	case 2: return true, pre_insert(c, h, node, base.NIL_HANDLE)
	case 3:
		if n.parent == base.NIL_HANDLE { return false, .None }
		return true, pre_insert(c, n.parent, node, n.next)
	}
	return false, .None
}

@(private)
BAD_POSITION :: "The value provided is not one of 'beforeBegin', 'afterBegin', 'beforeEnd', or 'afterEnd'."

Element_insertAdjacentElement :: proc(c: ^Call, element: Api_Element, position: string, other: Api_Element) -> (u64, Api_Error) {
	pos, ok := adjacent_position(position)
	if !ok { return 0, fail(c, .Syntax, BAD_POSITION) }
	done, err := insert_adjacent(c, H(element.handle), pos, H(other.handle))
	if err != .None || !done { return 0, err }
	return other.handle, .None
}

Element_insertAdjacentText :: proc(c: ^Call, element: Api_Element, position: string, data: string) -> Api_Error {
	pos, ok := adjacent_position(position)
	if !ok { return fail(c, .Syntax, BAD_POSITION) }
	d := c.page.doc
	t := dom.create_text(d, data)
	done, err := insert_adjacent(c, H(element.handle), pos, t)
	if !done || err != .None { dom.destroy_unpinned(d, t) }
	return err
}

Element_insertAdjacentHTML :: proc(c: ^Call, element: Api_Element, position: string, text: string) -> Api_Error {
	pos, ok := adjacent_position(position)
	if !ok { return fail(c, .Syntax, BAD_POSITION) }
	d := c.page.doc
	h := H(element.handle)
	ctx := h
	if pos == 0 || pos == 3 {
		ctx = element.data.parent
		if ctx == base.NIL_HANDLE || dom.get(d, ctx).kind == .Document {
			return fail(c, .No_Modification_Allowed, "The element has no parent element.")
		}
		if dom.get(d, ctx).kind == .Fragment { ctx = base.NIL_HANDLE }
	}
	frag, err := parse_fragment_for(c, ctx, text)
	if err != .None { return err }
	_, err = insert_adjacent(c, h, pos, frag)
	dom.destroy_unpinned(d, frag)
	return err
}

////////////////////////////////
// innerText / outerText

HTMLElement_innerText :: proc(c: ^Call, element: Api_Element) -> string {
	p := c.page
	d := p.doc
	h := H(element.handle)
	// not being rendered (detached, display: none...): the text content
	st := js_dom_styled(p)
	if st == nil || !dom.is_connected(d, h) { return dom.text_content(d, h) }
	cs := style.style_of(st, h)
	if cs == nil || cs.display == .None { return dom.text_content(d, h) }
	return lay.range_text(d, st, {h, 0}, {h, lay.child_count(d, h)}, root = h).text
}

HTMLElement_outerText :: proc(c: ^Call, element: Api_Element) -> string { return HTMLElement_innerText(c, element) }

// Text nodes for `value`, with a <br> for each line break (HTML "rendered text fragment"), in a new fragment.
@(private)
rendered_text_fragment :: proc(d: ^dom.Document, value: string) -> base.Handle {
	frag := dom.create_fragment(d)
	start := 0
	for i := 0; i <= len(value); i += 1 {
		if i < len(value) && value[i] != '\n' && value[i] != '\r' { continue }
		if i > start { dom.append_child(d, frag, dom.create_text(d, value[start:i])) }
		if i < len(value) {
			if value[i] == '\r' && i + 1 < len(value) && value[i + 1] == '\n' { i += 1 }
			dom.append_child(d, frag, dom.create_element(d, "br"))
		}
		start = i + 1
	}
	return frag
}

HTMLElement_set_innerText :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error {
	d := c.page.doc
	frag := rendered_text_fragment(d, value)
	replace_all(d, H(element.handle), dom.get(d, frag).first_child != base.NIL_HANDLE ? frag : base.NIL_HANDLE)
	dom.destroy_unpinned(d, frag)
	return .None
}

HTMLElement_set_outerText :: proc(c: ^Call, element: Api_Element, value: string) -> Api_Error {
	d := c.page.doc
	h := H(element.handle)
	parent := element.data.parent
	if parent == base.NIL_HANDLE { return fail(c, .No_Modification_Allowed, "The element has no parent.") }
	frag := rendered_text_fragment(d, value)
	if dom.get(d, frag).first_child == base.NIL_HANDLE { dom.append_child(d, frag, dom.create_text(d, "")) }
	err := replace_child(c, parent, frag, h)
	dom.destroy_unpinned(d, frag)
	return err
}
