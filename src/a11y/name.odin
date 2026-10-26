package a11y

// Accessible names and descriptions (Accessible Name and Description Computation 1.2, with the native sources of HTML
// Accessibility API Mappings: labels, alt, caption, legend, figcaption, value, title, placeholder).

import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:forms"
import "wb:style"

// What the computations read: the document, its computed styles (nil: everything shown) and its forms (nil: values
// from the attributes).
Source :: struct {
	doc:    ^dom.Document,
	styled: ^style.Styled,
	forms:  ^forms.Forms,
}

@(private)
attr :: proc(src: ^Source, h: base.Handle, name: string) -> (string, bool) { return dom.get_attribute(src.doc, h, name) }

// Hidden from the accessibility tree by itself: aria-hidden="true", the hidden attribute, inert, display: none (or no
// computed style at all when the document has some: inside a display: none subtree), visibility: hidden.
hidden_self :: proc(src: ^Source, h: base.Handle, n: ^dom.Node) -> (gone, invisible: bool) {
	if n.kind != .Element { return false, false }
	if v, ok := attr(src, h, "aria-hidden"); ok && strings.equal_fold(strings.trim_space(v), "true") { return true, true }
	if _, ok := attr(src, h, "inert"); ok { return true, true }
	if src.styled != nil {
		cs := style.style_of(src.styled, h)
		if cs == nil || cs.display == .None { return true, true }
		if cs.visibility != .Visible { return false, true }   // (its children may be visible again)
	} else if _, ok := attr(src, h, "hidden"); ok {
		return true, true
	}
	return false, false
}

// Whitespace collapsed to single spaces, trimmed.
collapse :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	space := false
	for r in s {
		if r == ' ' || r == '\t' || r == '\n' || r == '\r' || r == '\f' || r == 0xA0 {
			space = strings.builder_len(b) > 0
			continue
		}
		if space { strings.write_byte(&b, ' '); space = false }
		strings.write_rune(&b, r)
	}
	return strings.to_string(b)
}

// The role of an element: its first known ARIA role token, else its implicit role.
role_of :: proc(src: ^Source, h: base.Handle, n: ^dom.Node) -> Role {
	if n.kind == .Text { return .Label }
	if n.kind != .Element { return .Unknown }
	if v, ok := attr(src, h, "role"); ok {
		for tok in strings.fields(strings.to_lower(v, context.temp_allocator), context.temp_allocator) {
			if r, known := aria_role(tok); known {
				// none / presentation is ignored on focusable elements and on those with global ARIA (ARIA §9.3)
				if r == .Unknown && (is_focusable(src, h, n) || has_global_aria(n)) { break }
				return r
			}
		}
	}
	return implicit_role(src.doc, h, n, has_own_name(src, h))
}

@(private)
has_global_aria :: proc(n: ^dom.Node) -> bool {
	for a in n.attrs {
		switch a.name {
		case "aria-label", "aria-labelledby", "aria-describedby", "aria-live", "aria-owns", "aria-controls": return true
		}
	}
	return false
}

@(private)
has_own_name :: proc(src: ^Source, h: base.Handle) -> bool {
	if v, ok := attr(src, h, "aria-label"); ok && strings.trim_space(v) != "" { return true }
	if _, ok := attr(src, h, "aria-labelledby"); ok { return true }
	if v, ok := attr(src, h, "title"); ok && strings.trim_space(v) != "" { return true }
	return false
}

// Focusable as the forms of the page say (a link with href, a control, tabindex, contenteditable, summary).
is_focusable :: proc(src: ^Source, h: base.Handle, n: ^dom.Node) -> bool {
	if n.kind != .Element { return false }
	if _, ok := attr(src, h, "tabindex"); ok { return true }
	if _, ok := attr(src, h, "disabled"); ok {
		switch n.name { case "button", "input", "select", "textarea": return false }
	}
	switch n.name {
	case "a", "area": _, ok := attr(src, h, "href"); return ok
	case "button", "select", "textarea", "iframe", "summary": return true
	case "input":
		t, _ := attr(src, h, "type")
		return !strings.equal_fold(t, "hidden")
	}
	if v, ok := attr(src, h, "contenteditable"); ok && !strings.equal_fold(v, "false") { return true }
	return false
}

// The current value of a form control: what the user typed (the forms of the page), else its attribute or content.
control_value :: proc(src: ^Source, h: base.Handle, n: ^dom.Node) -> string {
	if src.forms != nil {
		switch n.name { case "input", "textarea", "select", "output": return forms.value(src.forms, h) }
	}
	switch n.name {
	case "textarea": return dom.text_content(src.doc, h)
	case "select":
		for c := n.first_child; c != base.NIL_HANDLE; {
			cn := dom.get(src.doc, c)
			if cn == nil { break }
			if cn.kind == .Element && cn.name == "option" {
				if _, sel := attr(src, c, "selected"); sel { return collapse(dom.text_content(src.doc, c)) }
			}
			c = cn.next
		}
		return ""
	}
	v, _ := attr(src, h, "value")
	return v
}

// The accessible name of `h` (whose role is `role`); `from_title`: it came from the title attribute (not then a
// description too).
name_of :: proc(src: ^Source, h: base.Handle, role: Role) -> (name: string, from_title: bool) {
	visited := make(map[base.Handle]bool, 16, context.temp_allocator)
	return text_alternative(src, h, role, false, false, &visited)
}

// accname 1.2 §4.3.2, for element `h`. `traversal`: computing a name from content or a reference; `referenced`:
// reached through aria-labelledby / describedby (hidden nodes count then).
@(private)
text_alternative :: proc(src: ^Source, h: base.Handle, role: Role, traversal, referenced: bool, visited: ^map[base.Handle]bool) -> (string, bool) {
	n := dom.get(src.doc, h)
	if n == nil || visited[h] { return "", false }
	visited[h] = true
	if n.kind == .Text { return n.text, false }
	if n.kind != .Element { return "", false }
	// A: hidden, unless reached through a reference
	if gone, _ := hidden_self(src, h, n); gone && !referenced { return "", false }
	// B: aria-labelledby (not followed again from a reference)
	if !referenced {
		if ids, ok := attr(src, h, "aria-labelledby"); ok {
			b := strings.builder_make(context.temp_allocator)
			for id in strings.fields(ids, context.temp_allocator) {
				ref := dom.find_by_id(src.doc, id)
				if ref == base.NIL_HANDLE { continue }
				rn := dom.get(src.doc, ref)
				if rn == nil { continue }
				t, _ := text_alternative(src, ref, role_of(src, ref, rn), true, true, visited)
				t = collapse(t)
				if t == "" { continue }
				if strings.builder_len(b) > 0 { strings.write_byte(&b, ' ') }
				strings.write_string(&b, t)
			}
			if s := strings.to_string(b); s != "" { return s, false }
		}
	}
	// C: an embedded control inside a name from content: its value
	if traversal && h != base.NIL_HANDLE {
		#partial switch role {
		case .Text_Input, .Search_Input, .Email_Input, .Url_Input, .Phone_Number_Input, .Combo_Box:
			return control_value(src, h, n), false
		case .Slider, .Spin_Button, .Progress_Indicator, .Meter:
			if v, ok := attr(src, h, "aria-valuetext"); ok { return v, false }
			if v, ok := attr(src, h, "aria-valuenow"); ok { return v, false }
			return control_value(src, h, n), false
		}
	}
	// D: aria-label
	if v, ok := attr(src, h, "aria-label"); ok && strings.trim_space(v) != "" { return strings.trim_space(v), false }
	// E: what the host language names it with
	if s := native_name(src, h, n, visited); s != "" { return s, false }
	// F: from its content
	if role != .Unknown && name_from_content(role) || traversal {
		b := strings.builder_make(context.temp_allocator)
		for c := n.first_child; c != base.NIL_HANDLE; {
			cn := dom.get(src.doc, c)
			if cn == nil { break }
			t: string
			if cn.kind == .Text {
				t = cn.text
			} else if cn.kind == .Element {
				t, _ = text_alternative(src, c, role_of(src, c, cn), true, referenced, visited)
				if block_level(src, c) { t = strings.concatenate({" ", t, " "}, context.temp_allocator) }
			}
			strings.write_string(&b, t)
			c = cn.next
		}
		if s := collapse(strings.to_string(b)); s != "" { return s, false }
	}
	// G: the tooltip
	if v, ok := attr(src, h, "title"); ok && strings.trim_space(v) != "" { return strings.trim_space(v), true }
	// (HTML-AAM: a text field's placeholder, last)
	if n.name == "input" || n.name == "textarea" {
		if v, ok := attr(src, h, "placeholder"); ok && strings.trim_space(v) != "" { return strings.trim_space(v), false }
	}
	return "", false
}

@(private)
block_level :: proc(src: ^Source, h: base.Handle) -> bool {
	if src.styled == nil { return false }
	cs := style.style_of(src.styled, h)
	if cs == nil { return false }
	#partial switch cs.display {
	case .Inline, .Inline_Block, .Inline_Flex, .Inline_Grid, .Inline_Table, .Contents, .None: return false
	}
	return true
}

// HTML-AAM's sources of a name: labels, alt, caption, legend, figcaption, the value of buttons, title of frames...
@(private)
native_name :: proc(src: ^Source, h: base.Handle, n: ^dom.Node, visited: ^map[base.Handle]bool) -> string {
	switch n.name {
	case "input":
		t, _ := attr(src, h, "type")
		switch strings.to_lower(t, context.temp_allocator) {
		case "button", "submit", "reset":
			if v, ok := attr(src, h, "value"); ok && strings.trim_space(v) != "" { return strings.trim_space(v) }
			if strings.equal_fold(t, "submit") { return "Submit" }
			if strings.equal_fold(t, "reset") { return "Reset" }
			return ""
		case "image":
			if v, ok := attr(src, h, "alt"); ok && strings.trim_space(v) != "" { return strings.trim_space(v) }
			if v, ok := attr(src, h, "value"); ok && strings.trim_space(v) != "" { return strings.trim_space(v) }
			return "Submit"
		}
		return label_text(src, h, visited)
	case "textarea", "select", "meter", "progress", "output":
		return label_text(src, h, visited)
	case "button":
		if s := label_text(src, h, visited); s != "" { return s }
	case "img", "area":
		if v, ok := attr(src, h, "alt"); ok { return collapse(v) }
	case "fieldset":
		return child_text(src, n, "legend", visited)
	case "table":
		return child_text(src, n, "caption", visited)
	case "figure":
		return child_text(src, n, "figcaption", visited)
	case "details":
		return ""
	case "iframe":
		if v, ok := attr(src, h, "title"); ok { return collapse(v) }
	case "optgroup":
		if v, ok := attr(src, h, "label"); ok { return collapse(v) }
	case "option":
		if v, ok := attr(src, h, "label"); ok && strings.trim_space(v) != "" { return collapse(v) }
	case "svg":
		return child_text(src, n, "title", visited)
	}
	return ""
}

// The text of the first child element named `tag` (a fieldset's legend, a table's caption).
@(private)
child_text :: proc(src: ^Source, n: ^dom.Node, tag: string, visited: ^map[base.Handle]bool) -> string {
	for c := n.first_child; c != base.NIL_HANDLE; {
		cn := dom.get(src.doc, c)
		if cn == nil { break }
		if cn.kind == .Element && cn.name == tag {
			t, _ := text_alternative(src, c, role_of(src, c, cn), true, false, visited)
			return collapse(t)
		}
		c = cn.next
	}
	return ""
}

// The labels of a labelable element: <label for=its id>, and the <label> around it.
@(private)
label_text :: proc(src: ^Source, h: base.Handle, visited: ^map[base.Handle]bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	add :: proc(src: ^Source, b: ^strings.Builder, l: base.Handle, visited: ^map[base.Handle]bool) {
		ln := dom.get(src.doc, l)
		if ln == nil { return }
		t, _ := text_alternative(src, l, .Label, true, false, visited)
		t = collapse(t)
		if t == "" { return }
		if strings.builder_len(b^) > 0 { strings.write_byte(b, ' ') }
		strings.write_string(b, t)
	}
	if id, ok := attr(src, h, "id"); ok && id != "" {
		for cur := dom.next_in_tree(src.doc, src.doc.root, src.doc.root); cur != base.NIL_HANDLE; cur = dom.next_in_tree(src.doc, cur, src.doc.root) {
			cn := dom.get(src.doc, cur)
			if cn == nil || cn.kind != .Element || cn.name != "label" { continue }
			if f, fok := attr(src, cur, "for"); fok && f == id { add(src, &b, cur, visited) }
		}
	}
	n := dom.get(src.doc, h)
	for n != nil && n.parent != base.NIL_HANDLE {
		pn := dom.get(src.doc, n.parent)
		if pn == nil || pn.kind != .Element { break }
		if pn.name == "label" {
			if _, has_for := attr(src, n.parent, "for"); !has_for { add(src, &b, n.parent, visited) }
			break
		}
		n = pn
	}
	return strings.to_string(b)
}

// The description of `h`: aria-describedby, aria-description, else its title when the name did not come from it.
description_of :: proc(src: ^Source, h: base.Handle, name_from_title: bool) -> string {
	if ids, ok := attr(src, h, "aria-describedby"); ok {
		visited := make(map[base.Handle]bool, 8, context.temp_allocator)
		b := strings.builder_make(context.temp_allocator)
		for id in strings.fields(ids, context.temp_allocator) {
			ref := dom.find_by_id(src.doc, id)
			rn := dom.get(src.doc, ref) if ref != base.NIL_HANDLE else nil
			if rn == nil { continue }
			t, _ := text_alternative(src, ref, role_of(src, ref, rn), true, true, &visited)
			t = collapse(t)
			if t == "" { continue }
			if strings.builder_len(b) > 0 { strings.write_byte(&b, ' ') }
			strings.write_string(&b, t)
		}
		if s := strings.to_string(b); s != "" { return s }
	}
	if v, ok := attr(src, h, "aria-description"); ok && strings.trim_space(v) != "" { return strings.trim_space(v) }
	if !name_from_title {
		if v, ok := attr(src, h, "title"); ok { return collapse(v) }
	}
	return ""
}
