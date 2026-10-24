package blocker

import "core:fmt"
import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:host"
import "wb:page"

// The scriptlets that change the document, done on the document (route .Dom, scriptlet_route.odin): remove-attr, remove-class, set-attr,
// remove-node-text, replace-node-text, click-element, href-sanitizer, disable-newtab-links, and the one-shot writes of cookies and storage.
// uBlock Origin runs them as JavaScript with a MutationObserver; here they are Odin on the DOM, and they cost the page's realm nothing.
//
// Incremental: the document's mutation journal (dom/journal.odin) says what is new since the last pass: nodes inserted (their subtree is
// looked at once), text changed, attributes changed. A pass runs when the page is about to style, before every script that is about to
// run, and when the parser finishes: always before a page script could read what the operation would have changed. The document is never
// walked as a whole after the first pass, except when the journal forgot entries (a burst larger than its bound): then once more.
//
// Behavior (uBlock Origin's): `asap` runs from the start (here: as nodes arrive), the default once the parse is done plus what arrived
// before it, `stay` for ever. Text operations and clicks watch for ever (until done or timed out), as uBlock Origin's do.

Dom_Op_Kind :: enum u8 {
	Remove_Attr, Remove_Class, Set_Attr, Replace_Text, Remove_Text, Click, Href_Sanitize,
	Set_Cookie, Remove_Cookie, Set_Storage, Remove_Storage,
}

Dom_Op :: struct {
	kind:      Dom_Op_Kind,
	names:     []string,     // attributes / classes (owned)
	selector:  string,       // owned; "" for a default one made from `names`
	explicit:  bool,         // the selector was given
	value:     string,       // Set_Attr / Set_Storage / Set_Cookie value; Href_Sanitize source; Replace_Text replacement
	key:       string,       // Set_Cookie name, Set_Storage / Remove_Storage key
	path:      string,       // Set_Cookie
	reload:    bool,         // Set_Cookie: reload the page when the cookie changed
	session:   bool,         // Set_Storage / Remove_Storage
	stay:      bool,
	asap:      bool,
	live:      bool,         // still watching (a one-shot operation is done; a plain one stops once the parse is done)
	// text operations
	node_name: string,       // lower case; "" when `node_re` is used
	node_re:   ^Jsre,
	pat:       ^Jsre,        // Replace_Text: what to replace; Remove_Text: nil
	cond:      Needle,       // Remove_Text: the condition; Replace_Text: the extra `condition` / `includes`
	has_cond:  bool,
	sed_count: int,
	// clicks
	sels:      []string,     // owned
	next:      int,          // the selector waited for
	delay_ms:  int,
	deadline:  i64,          // wall clock ms after which the clicks stop waiting
	pending:   bool,         // Click: a click is scheduled
}

Dom_Ops :: struct {
	ops:       [dynamic]Dom_Op,
	cursor:    u64,
	started:   bool,
	running:   bool,
	parsed:    bool,
	clicks:    [dynamic]^Click_Ctx,   // the scheduled clicks (their timers are cleared with the document)
	click:     ^Click_Ctx,
	changed_cookie: bool,
}

Click_Ctx :: struct { hs: ^Doc_Hooks, op: int, el: base.Handle, timer: base.Handle }

DOM_JOURNAL_MAX :: 1 << 14
CLICK_WAIT_MS :: 10_000

ops_destroy :: proc(o: ^Dom_Ops, loop: ^host.Loop) {
	for &op in o.ops { op_destroy(&op) }
	delete(o.ops)
	for c in o.clicks { if loop != nil { host.clear_timer(loop, c.timer) }; free(c) }
	delete(o.clicks)
	o^ = {}
}

@(private = "file")
op_destroy :: proc(op: ^Dom_Op) {
	for s in op.names { delete(s) }
	delete(op.names)
	delete(op.selector); delete(op.value); delete(op.key); delete(op.path); delete(op.node_name)
	jsre_destroy(op.node_re); jsre_destroy(op.pat)
	needle_destroy(&op.cond)
	for s in op.sels { delete(s) }
	delete(op.sels)
}

@(private = "file")
split_list :: proc(s: string, sep: string) -> []string {
	out := make([dynamic]string)
	for part in strings.split(s, sep, context.temp_allocator) {
		t := strings.trim_space(part)
		if t != "" { append(&out, strings.clone(t)) }
	}
	return out[:]
}

@(private = "file")
arg :: proc(a: []string, i: int) -> string { return i < len(a) ? a[i] : "" }

// The extra arguments of the text scriptlets: pairs `name value` (condition, includes, sedCount, tryCount, tryDelay).
@(private = "file")
text_extras :: proc(op: ^Dom_Op, a: []string, from: int) {
	for i := from; i + 1 < len(a); i += 2 {
		switch a[i] {
		case "condition", "includes":
			needle_destroy(&op.cond)
			op.cond = needle_make(a[i + 1])
			op.has_cond = true
		case "sedCount":
			if n, ok := strconv.parse_int(a[i + 1]); ok { op.sed_count = n }
		}
	}
}

// Builds the operation for a scriptlet of route .Dom. False for one that is a no-op or whose arguments are not valid.
ops_make :: proc(canon: string, a: []string) -> (op: Dom_Op, ok: bool) {
	op.live = true
	behavior := ""
	switch canon {
	case "remove-attr":
		if arg(a, 1) == "" { return {}, false }
		op.kind = .Remove_Attr
		op.names = split_list(a[1], "|")
		if len(op.names) == 0 { return {}, false }
		op.selector, op.explicit = strings.clone(arg(a, 2)), arg(a, 2) != ""
		behavior = arg(a, 3)
	case "remove-class":
		if arg(a, 1) == "" { return {}, false }
		op.kind = .Remove_Class
		op.names = split_list(a[1], "|")
		if len(op.names) == 0 { return {}, false }
		op.selector, op.explicit = strings.clone(arg(a, 2)), arg(a, 2) != ""
		behavior = arg(a, 3)
	case "set-attr":
		if arg(a, 1) == "" || arg(a, 2) == "" { return {}, false }
		op.kind = .Set_Attr
		op.selector, op.explicit = strings.clone(a[1]), true
		op.names = make([]string, 1)
		op.names[0] = strings.clone(a[2])
		op.value = strings.clone(arg(a, 3))
		op.stay = true
	case "disable-newtab-links":
		op.kind = .Remove_Attr
		op.names = make([]string, 1)
		op.names[0] = strings.clone("target")
		op.selector, op.explicit = strings.clone("a[target=\"_blank\"], area[target=\"_blank\"]"), true
		op.stay = true
	case "href-sanitizer":
		if arg(a, 1) == "" { return {}, false }
		op.kind = .Href_Sanitize
		op.selector, op.explicit = strings.clone(a[1]), true
		op.value = strings.clone(arg(a, 2))
		op.stay = true
	case "remove-node-text":
		if arg(a, 1) == "" { return {}, false }
		op.kind = .Remove_Text
		node_name_of(&op, a[1])
		op.cond = needle_make(arg(a, 2))
		op.has_cond = true
		op.stay = true
		text_extras(&op, a, 3)
	case "replace-node-text":
		if arg(a, 1) == "" { return {}, false }
		op.kind = .Replace_Text
		node_name_of(&op, a[1])
		op.pat = pattern_regex(arg(a, 2), "g")
		if op.pat == nil { op_destroy(&op); return {}, false }
		op.value = strings.clone(arg(a, 3))
		op.stay = true
		text_extras(&op, a, 4)
	case "click-element":
		if arg(a, 1) == "" { return {}, false }
		op.kind = .Click
		op.sels = split_list(a[1], ",")
		// a selector list cut at commas inside brackets or parentheses is put back together
		op.sels = join_nested(op.sels)
		if len(op.sels) == 0 { return {}, false }
		if n, ok2 := strconv.parse_int(arg(a, 3)); ok2 { op.delay_ms = n }
		op.stay = true
	case "set-cookie", "set-cookie-reload":
		if arg(a, 1) == "" { return {}, false }
		op.kind = .Set_Cookie
		op.key, op.value = strings.clone(a[1]), strings.clone(arg(a, 2))
		op.path = strings.clone(arg(a, 3) == "" || arg(a, 3) == "/" ? "/" : (arg(a, 3) == "none" ? "" : arg(a, 3)))
		op.reload = canon == "set-cookie-reload"
	case "remove-cookie":
		op.kind = .Remove_Cookie
		op.pat = pattern_regex(arg(a, 1) == "" ? "/.*/" : arg(a, 1), "")
		if op.pat == nil { return {}, false }
	case "set-local-storage-item", "set-session-storage-item":
		if arg(a, 1) == "" { return {}, false }
		op.kind = .Set_Storage
		op.session = canon == "set-session-storage-item"
		op.key, op.value = strings.clone(a[1]), strings.clone(arg(a, 2))
	case "remove-local-storage-item", "remove-session-storage-item":
		if arg(a, 1) == "" { return {}, false }
		op.kind = .Remove_Storage
		op.session = canon == "remove-session-storage-item"
		op.key = strings.clone(a[1])
	case: return {}, false
	}
	if op.kind == .Remove_Attr || op.kind == .Remove_Class {
		op.asap = strings.contains(behavior, "asap")
		op.stay = op.stay || strings.contains(behavior, "stay")
	}
	if op.selector == "" && (op.kind == .Remove_Attr || op.kind == .Remove_Class) {
		sb := strings.builder_make(context.temp_allocator)
		for n, i in op.names {
			if i > 0 { strings.write_byte(&sb, ',') }
			strings.write_string(&sb, op.kind == .Remove_Attr ? "[" : ".")
			strings.write_string(&sb, n)
			if op.kind == .Remove_Attr { strings.write_byte(&sb, ']') }
		}
		delete(op.selector)
		op.selector = strings.clone(strings.to_string(sb))
	}
	return op, true
}

@(private = "file")
node_name_of :: proc(op: ^Dom_Op, text: string) {
	if len(text) >= 2 && text[0] == '/' {
		if end := strings.last_index_byte(text, '/'); end > 0 {
			op.node_re = jsre_compile(text[1:end], strings.contains(text[end + 1:], "i") ? text[end + 1:] : strings.concatenate({text[end + 1:], "i"}, context.temp_allocator))
			if op.node_re != nil { return }
		}
	}
	op.node_name = strings.to_lower(text)
}

// Puts back together the pieces of a selector list that a comma inside `[...]`, `(...)` or quotes cut.
@(private = "file")
join_nested :: proc(parts: []string) -> []string {
	out := make([dynamic]string)
	cur := strings.builder_make(context.temp_allocator)
	for p, i in parts {
		if strings.builder_len(cur) > 0 { strings.write_byte(&cur, ',') }
		strings.write_string(&cur, p)
		s := strings.to_string(cur)
		if strings.count(s, "[") == strings.count(s, "]") && strings.count(s, "(") == strings.count(s, ")") && strings.count(s, "\"") % 2 == 0 {
			append(&out, strings.clone(s))
			strings.builder_reset(&cur)
		}
		_ = i
	}
	if strings.builder_len(cur) > 0 { append(&out, strings.clone(strings.to_string(cur))) }
	for p in parts { delete(p) }
	delete(parts)
	return out[:]
}

////////////////////////////////
// Running

@(private = "file")
doc_has_class :: proc(value: string, c: string) -> bool {
	v := value
	for len(v) > 0 {
		for len(v) > 0 && (v[0] == ' ' || v[0] == '\t' || v[0] == '\n' || v[0] == '\r' || v[0] == 0x0c) { v = v[1:] }
		end := 0
		for end < len(v) && !(v[end] == ' ' || v[end] == '\t' || v[end] == '\n' || v[end] == '\r' || v[end] == 0x0c) { end += 1 }
		if v[:end] == c { return true }
		v = v[end:]
	}
	return false
}

@(private = "file")
selected :: proc(p: ^page.Page, op: ^Dom_Op, el: base.Handle) -> bool {
	// a fast path for the default selectors (`[attr]`, `.class`): the element's own attributes
	doc := p.doc
	n := dom.get(doc, el)
	if n == nil || n.kind != .Element { return false }
	if !op.explicit {
		switch op.kind {
		case .Remove_Attr:
			for name in op.names { if _, has := dom.get_attribute(doc, el, name); has { return true } }
			return false
		case .Remove_Class:
			cls, has := dom.get_attribute(doc, el, "class")
			if !has { return false }
			for name in op.names { if doc_has_class(cls, name) { return true } }
			return false
		case .Replace_Text, .Remove_Text, .Click, .Href_Sanitize, .Set_Attr, .Set_Cookie, .Remove_Cookie, .Set_Storage, .Remove_Storage:
		}
	}
	return page.element_matches(p, el, op.selector)
}

@(private = "file")
apply_attr_op :: proc(p: ^page.Page, op: ^Dom_Op, el: base.Handle) {
	doc := p.doc
	switch op.kind {
	case .Remove_Attr:
		for name in op.names { if _, has := dom.get_attribute(doc, el, name); has { dom.remove_attribute(doc, el, name) } }
	case .Remove_Class:
		cls, has := dom.get_attribute(doc, el, "class")
		if !has { return }
		sb := strings.builder_make(context.temp_allocator)
		changed := false
		v := cls
		for len(v) > 0 {
			for len(v) > 0 && (v[0] == ' ' || v[0] == '\t' || v[0] == '\n' || v[0] == '\r' || v[0] == 0x0c) { v = v[1:] }
			end := 0
			for end < len(v) && !(v[end] == ' ' || v[end] == '\t' || v[end] == '\n' || v[end] == '\r' || v[end] == 0x0c) { end += 1 }
			tok := v[:end]
			v = v[end:]
			if tok == "" { continue }
			drop := false
			for name in op.names { if name == tok { drop = true; changed = true } }
			if drop { continue }
			if strings.builder_len(sb) > 0 { strings.write_byte(&sb, ' ') }
			strings.write_string(&sb, tok)
		}
		if changed { dom.set_attribute(doc, el, "class", strings.to_string(sb)) }
	case .Set_Attr:
		name := op.names[0]
		if cur, has := dom.get_attribute(doc, el, name); !has || cur != op.value { dom.set_attribute(doc, el, name, op.value) }
	case .Href_Sanitize:
		sanitize_href(p, op, el)
	case .Replace_Text, .Remove_Text, .Click, .Set_Cookie, .Remove_Cookie, .Set_Storage, .Remove_Storage:
	}
}

// The link's own target: from the text of the element (`text`), another attribute (`[name]`), a parameter of the current address
// (`?name`), or, with no source, the first of the parameters that carry a URL (url, u, q, to, target, redirect).
@(private = "file")
sanitize_href :: proc(p: ^page.Page, op: ^Dom_Op, el: base.Handle) {
	doc := p.doc
	href, has := dom.get_attribute(doc, el, "href")
	if !has { return }
	target := ""
	src := op.value
	switch {
	case src == "text": target = strings.trim_space(dom.text_content(doc, el))
	case len(src) > 2 && src[0] == '[' && src[len(src) - 1] == ']': target, _ = dom.get_attribute(doc, el, src[1:len(src) - 1])
	case: 
		names: []string
		if len(src) > 1 && src[0] == '?' { names = {src[1:]} } else { names = {"url", "u", "q", "to", "target", "redirect", "dest", "link"} }
		q := strings.index_byte(href, '?')
		if q >= 0 {
			query := href[q + 1:]
			if h := strings.index_byte(query, '#'); h >= 0 { query = query[:h] }
			for pair in strings.split(query, "&", context.temp_allocator) {
				eq := strings.index_byte(pair, '=')
				if eq < 0 { continue }
				for nm in names {
					if pair[:eq] == nm { target = percent_decode(pair[eq + 1:]); break }
				}
				if target != "" { break }
			}
		}
	}
	if (strings.has_prefix(target, "https://") || strings.has_prefix(target, "http://")) && target != href { dom.set_attribute(doc, el, "href", target) }
}

@(private = "file")
percent_decode :: proc(s: string) -> string {
	if !strings.contains_any(s, "%+") { return s }
	out := make([dynamic]u8, context.temp_allocator)
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '+' { append(&out, ' '); i += 1; continue }
		if c == '%' && i + 2 < len(s) {
			a, b := hex_digit(s[i + 1]), hex_digit(s[i + 2])
			if a >= 0 && b >= 0 { append(&out, u8(a * 16 + b)); i += 3; continue }
		}
		append(&out, c)
		i += 1
	}
	return string(out[:])
}

@(private = "file")
hex_digit :: proc(c: u8) -> int {
	switch {
	case c >= '0' && c <= '9': return int(c - '0')
	case c >= 'a' && c <= 'f': return int(c - 'a') + 10
	case c >= 'A' && c <= 'F': return int(c - 'A') + 10
	}
	return -1
}

// The text operations on an element whose name matches (or on a text node, for `#text`).
@(private = "file")
name_matches :: proc(op: ^Dom_Op, name: string) -> bool {
	if op.node_re != nil { return jsre_test(op.node_re, name) }
	return strings.equal_fold(name, op.node_name)
}

@(private = "file")
rewrite_text :: proc(op: ^Dom_Op, text: string) -> (out: string, changed: bool) {
	if op.has_cond && op.kind == .Replace_Text && !needle_test(&op.cond, text) { return text, false }
	switch op.kind {
	case .Remove_Text:
		if op.has_cond && !needle_test(&op.cond, text) { return text, false }
		return "", text != ""
	case .Replace_Text:
		count: int
		out, count = jsre_replace(op.pat, text, op.value, op.sed_count, context.temp_allocator)
		return out, count > 0 && out != text
	case .Remove_Attr, .Remove_Class, .Set_Attr, .Click, .Href_Sanitize, .Set_Cookie, .Remove_Cookie, .Set_Storage, .Remove_Storage:
	}
	return text, false
}

// Applies the text operations to one element (its text content) and to its text children when an operation targets `#text`.
text_ops_on :: proc(p: ^page.Page, o: ^Dom_Ops, el: base.Handle) {
	doc := p.doc
	n := dom.get(doc, el)
	if n == nil || n.kind != .Element { return }
	for &op in o.ops {
		if !op.live || (op.kind != .Replace_Text && op.kind != .Remove_Text) { continue }
		if op.node_name == "#text" {
			for c := n.first_child; c != base.NIL_HANDLE; {
				cn := dom.get(doc, c)
				if cn == nil { break }
				next := cn.next
				if cn.kind == .Text {
					if out, changed := rewrite_text(&op, cn.text); changed { dom.set_data(doc, c, out) }
				}
				c = next
			}
			continue
		}
		if !name_matches(&op, n.name) { continue }
		text := dom.text_content(doc, el)
		if out, changed := rewrite_text(&op, text); changed { dom.set_text_content(doc, el, out) }
	}
}

@(private = "file")
has_text_ops :: proc(o: ^Dom_Ops) -> bool {
	for &op in o.ops { if op.live && (op.kind == .Replace_Text || op.kind == .Remove_Text) { return true } }
	return false
}

// One element of the document against every watching operation.
@(private = "file")
visit_element :: proc(p: ^page.Page, hs: ^Doc_Hooks, o: ^Dom_Ops, el: base.Handle, texts: bool) {
	for &op, i in o.ops {
		if !op.live { continue }
		switch op.kind {
		case .Remove_Attr, .Remove_Class, .Set_Attr, .Href_Sanitize:
			if selected(p, &op, el) { apply_attr_op(p, &op, el) }
		case .Click:
			click_candidate(p, hs, o, i, el)
		case .Replace_Text, .Remove_Text, .Set_Cookie, .Remove_Cookie, .Set_Storage, .Remove_Storage:
		}
	}
	if texts { text_ops_on(p, o, el) }
}

@(private = "file")
click_candidate :: proc(p: ^page.Page, hs: ^Doc_Hooks, o: ^Dom_Ops, i: int, el: base.Handle) {
	op := &o.ops[i]
	if op.next >= len(op.sels) || now_ms() > op.deadline { return }
	if op.pending { return }
	if !page.element_matches(p, el, op.sels[op.next]) { return }
	schedule_click(p, hs, o, i, el)
}

@(private = "file")
schedule_click :: proc(p: ^page.Page, hs: ^Doc_Hooks, o: ^Dom_Ops, i: int, el: base.Handle) {
	op := &o.ops[i]
	op.pending = true
	ctx := new(Click_Ctx)
	ctx.hs, ctx.op, ctx.el = hs, i, el
	ctx.timer = host.set_timer(p.loop, f64(max(op.delay_ms, 1)), 0, click_fire, ctx)
	append(&o.clicks, ctx)
}

@(private = "file")
click_fire :: proc(data: rawptr) {
	c := (^Click_Ctx)(data)
	defer free(c)
	hs := c.hs
	for k, i in hs.ops.clicks { if k == c { ordered_remove(&hs.ops.clicks, i); break } }
	p := hs.page
	if p == nil || p.closed || p.doc == nil || c.op >= len(hs.ops.ops) { return }
	op := &hs.ops.ops[c.op]
	op.pending = false
	if dom.get(p.doc, c.el) != nil { page.click_element(p, c.el) }
	op.next += 1
	if op.next >= len(op.sels) { op.live = false }
	// the next selector may be there already
	if op.live { click_scan(p, hs, c.op) }
}

@(private = "file")
click_scan :: proc(p: ^page.Page, hs: ^Doc_Hooks, i: int) {
	o := &hs.ops
	op := &o.ops[i]
	if op.next >= len(op.sels) { return }
	list, ok := page.select_all(p, op.sels[op.next])
	if ok && len(list) > 0 { schedule_click(p, hs, o, i, list[0]) }
}

// The first pass of a document, and the one after the journal lost entries: every operation over the whole document.
@(private = "file")
sweep_all :: proc(p: ^page.Page, hs: ^Doc_Hooks) {
	o := &hs.ops
	doc := p.doc
	for &op, i in o.ops {
		if !op.live { continue }
		switch op.kind {
		case .Remove_Attr, .Remove_Class, .Set_Attr, .Href_Sanitize:
			if list, ok := page.select_all(p, op.selector); ok { for el in list { apply_attr_op(p, &op, el) } }
		case .Click:
			if now_ms() <= op.deadline { click_scan(p, hs, i) }
		case .Replace_Text, .Remove_Text, .Set_Cookie, .Remove_Cookie, .Set_Storage, .Remove_Storage:
		}
	}
	if has_text_ops(o) {
		for h := doc.root; h != base.NIL_HANDLE; h = dom.next_in_tree(doc, h, doc.root) {
			if n := dom.get(doc, h); n != nil && n.kind == .Element { text_ops_on(p, o, h) }
		}
	}
}

// Starts the operations of a document: the one-shot writes happen now, the watchers take their first look.
ops_start :: proc(b: ^Blocker, hs: ^Doc_Hooks, p: ^page.Page) {
	o := &hs.ops

	if len(o.ops) == 0 || p.doc == nil { return }
	doc := p.doc
	if !doc.journal.on { dom.journal_enable(doc, DOM_JOURNAL_MAX) }
	o.started = true
	o.cursor = doc.mutations
	now := now_ms()
	for &op in o.ops {
		op.deadline = now + CLICK_WAIT_MS
		switch op.kind {
		case .Set_Cookie:
			text := fmt.tprintf("%s=%s%s", op.key, op.value, op.path == "" ? "" : fmt.tprintf("; path=%s", op.path))
			cur := doc_cookie_value(p, op.key)
			if cur != op.value { if page.store_cookie(p, text) { o.changed_cookie = true } }
			op.live = false
		case .Remove_Cookie:
			remove_cookies(p, op.pat)
			op.live = false
		case .Set_Storage:
			switch op.value {
			case "$remove$": page.storage_delete(p, op.session, op.key)
			case "emptyObj": page.storage_write(p, op.session, op.key, "{}")
			case "emptyArr": page.storage_write(p, op.session, op.key, "[]")
			case: page.storage_write(p, op.session, op.key, op.value)
			}
			op.live = false
		case .Remove_Storage:
			page.storage_delete(p, op.session, op.key)
			op.live = false
		case .Remove_Attr, .Remove_Class, .Set_Attr, .Href_Sanitize, .Replace_Text, .Remove_Text, .Click:
		}
	}
	sweep_all(p, hs)
	o.cursor = doc.mutations
	if o.changed_cookie {
		for &op in o.ops { if op.kind == .Set_Cookie && op.reload { ops_request_reload(b, hs); break } }
		o.changed_cookie = false
	}
}

@(private = "file")
ops_request_reload :: proc(b: ^Blocker, hs: ^Doc_Hooks) {
	if b.on_event == nil || hs.owner == nil || hs.owner.tab == nil { return }
	ev := Event{kind = .Reload, tab = hs.owner.tab.id}
	b.on_event(b.event_user, &ev)
}

// The value of one cookie of the document, "" when it has none.
@(private = "file")
doc_cookie_value :: proc(p: ^page.Page, name: string) -> string {
	header := page.document_cookies(p)
	for part in strings.split(header, ";", context.temp_allocator) {
		t := strings.trim_left_space(part)
		if eq := strings.index_byte(t, '='); eq > 0 && t[:eq] == name { return t[eq + 1:] }
	}
	return ""
}

@(private = "file")
remove_cookies :: proc(p: ^page.Page, pat: ^Jsre) {
	header := page.document_cookies(p)
	for part in strings.split(header, ";", context.temp_allocator) {
		t := strings.trim_left_space(part)
		eq := strings.index_byte(t, '=')
		if eq <= 0 { continue }
		name := t[:eq]
		if jsre_test(pat, name) {
			page.store_cookie(p, fmt.tprintf("%s=; Max-Age=0; path=/", name))
		}
	}
}

// Inserted nodes, text and attribute changes since the last pass.
ops_run :: proc(b: ^Blocker, hs: ^Doc_Hooks, p: ^page.Page) {
	o := &hs.ops
	if !o.started || o.running || p.doc == nil || p.closed { return }
	doc := p.doc
	if doc.mutations == o.cursor { return }

	o.running = true
	defer o.running = false
	entries, ok := dom.journal_since(doc, o.cursor)
	if !ok {
		if !doc.journal.on { dom.journal_enable(doc, DOM_JOURNAL_MAX) }
		sweep_all(p, hs)
		o.cursor = doc.mutations
		return
	}
	Attr_Event :: struct { el: base.Handle, name: string }
	roots := make([dynamic]base.Handle, context.temp_allocator)
	text_parents := make([dynamic]base.Handle, context.temp_allocator)
	attrs := make([dynamic]Attr_Event, context.temp_allocator)
	for &e in entries {
		switch e.kind {
		case .Insert: append(&roots, e.node)
		case .Text: if e.parent != base.NIL_HANDLE { append(&text_parents, e.parent) }
		case .Attribute: append(&attrs, Attr_Event{e.node, strings.clone(e.name, context.temp_allocator)})
		case .Remove, .Reslot:
		}
	}
	texts := has_text_ops(o)
	for r in roots {
		n := dom.get(doc, r)
		if n == nil || !dom.is_connected(doc, r) { continue }
		for h := r; h != base.NIL_HANDLE; h = dom.next_in_tree(doc, h, r) {
			cn := dom.get(doc, h)
			if cn == nil { continue }
			if cn.kind == .Element { visit_element(p, hs, o, h, texts) }
		}
		// a text node inserted by itself: its parent element is looked at
		if n.kind == .Text && texts && n.parent != base.NIL_HANDLE { text_ops_on(p, o, n.parent) }
	}
	if texts { for tp in text_parents { if dom.get(doc, tp) != nil && dom.is_connected(doc, tp) { text_ops_on(p, o, tp) } } }
	for a in attrs {
		if dom.get(doc, a.el) == nil || !dom.is_connected(doc, a.el) { continue }
		for &op, i in o.ops {
			if !op.live || !op.stay { continue }
			watched := op.explicit
			if !watched { for nm in op.names { if nm == a.name || (op.kind == .Remove_Class && a.name == "class") { watched = true } } }
			if !watched { continue }
			#partial switch op.kind {
			case .Remove_Attr, .Remove_Class, .Set_Attr, .Href_Sanitize: if selected(p, &op, a.el) { apply_attr_op(p, &op, a.el) }
			case .Click: click_candidate(p, hs, o, i, a.el)
			}
		}
	}
	o.cursor = doc.mutations
}

// The parser finished: what a plain (not `stay`) operation was to do, it has done; it stops watching.
ops_parsed :: proc(b: ^Blocker, hs: ^Doc_Hooks, p: ^page.Page) {
	o := &hs.ops
	if !o.started || p.doc == nil { return }
	ops_run(b, hs, p)
	o.parsed = true
	// a last whole-document look for the plain operations, then they rest
	doc := p.doc
	for &op in o.ops {
		if !op.live || op.stay { continue }
		if list, ok := page.select_all(p, op.selector); ok { for el in list { apply_attr_op(p, &op, el) } }
		op.live = false
	}
	o.cursor = doc.mutations
}

// An inline script is about to be read: the text operations that target `script` (or `#text`) rewrite it first.
ops_before_script :: proc(b: ^Blocker, hs: ^Doc_Hooks, p: ^page.Page, script: base.Handle) {
	o := &hs.ops
	if !o.started || o.running || p.doc == nil { return }
	ops_run(b, hs, p)
	if has_text_ops(o) {
		o.running = true
		text_ops_on(p, o, script)
		o.running = false
		o.cursor = p.doc.mutations
	}
}
