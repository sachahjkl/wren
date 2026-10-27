package blocker

import "core:strings"
import "wb:fetch"
import "wb:html"

// HTML filters (`##^`), the uBlock Origin feature that removes elements from the markup of a document's response before
// the parser reads it (no DOM is ever built for them; the cosmetic `##` path hides elements, this one deletes them from
// the bytes). A rule is `host##^selector`; the selector is a single element with the operators uBlock allows there:
//
//   script, iframe, div, *           a tag name (or `*`), matched case-insensitively
//   ^script                          uBlock's leading `^` for an element: the same as the bare tag name here
//   [attr], [attr=v], [attr*=v], [attr^=v], [attr$=v], [attr~=v]     an attribute test (quotes optional)
//   :has-text(x) / :contains(x)      the element's text (between its start and end tags) holds x (plain, with `*`, or /regex/)
//   :not(:has-text(x)) / :not([a])   the negation of a text or attribute test
//
// `#@#^selector` exceptions switch the whole host off (no HTML filter runs), like uBlock's `##^` exceptions do at the host
// level; the engine already folds the generic `#@#^` into `no_html` (cosmetic.odin). The work is on the raw response bytes,
// before charset decoding: an element is found and *deleted* by byte range, so the surrounding bytes and the declared
// charset are untouched (we never re-encode). Only `:has-text` needs the text, and only the matched element's text slice is
// decoded to UTF-8 for the comparison. A size cap (`html.max_body`) and a time cap (`html.max_scan_ms`) keep a pathological
// page cheap: past the size cap the body streams through untouched.

Html_Op_Kind :: enum u8 { Has_Text, Attr }

Html_Op :: struct {
	kind:    Html_Op_Kind,
	negate:  bool,
	// Has_Text:
	text:    string,         // plain or `*` glob (owned); empty when `re` is set
	re:      ^Jsre,          // /regex/ form (owned), compiled from re_src/re_flags
	re_src:  string,         // the regex source (owned), kept so a clone can recompile
	re_flags: string,        // the regex flags (owned)
	// Attr:
	attr:    string,         // name (owned)
	op:      string,         // "", "=", "*=", "^=", "$=", "~=" (static)
	want:    string,         // value (owned)
}

Html_Rule :: struct {
	tag:     string,         // lower-case tag name, or "*" (owned)
	ops:     [dynamic]Html_Op,
}

html_rule_destroy :: proc(r: ^Html_Rule) {
	delete(r.tag)
	for &o in r.ops { delete(o.text); delete(o.attr); delete(o.want); delete(o.re_src); delete(o.re_flags); jsre_destroy(o.re) }
	delete(r.ops)
}

// Parses one `##^` selector into a rule. ok = false for a selector this native path does not support (it is then ignored,
// never applied as a `##` hide).
html_rule_parse :: proc(selector: string) -> (r: Html_Rule, ok: bool) {
	s := strings.trim_space(selector)
	if s == "" { return {}, false }
	if s[0] == '^' { s = s[1:] }    // uBlock's element marker
	// the tag name: letters, digits and `-`, or `*`
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '*' || c == ':' || c == '[' { break }
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_') { return {}, false }
		i += 1
	}
	tag := "*"
	if i > 0 { tag = s[:i] } else if i < len(s) && s[i] == '*' { i += 1 }
	r.tag = strings.to_lower(tag)
	rest := s[i:]
	for len(rest) > 0 {
		switch {
		case rest[0] == '[':
			end := strings.index_byte(rest, ']')
			if end < 0 { html_rule_destroy(&r); return {}, false }
			if !html_add_attr(&r, rest[1:end], false) { html_rule_destroy(&r); return {}, false }
			rest = rest[end + 1:]
		case strings.has_prefix(rest, ":has-text(") || strings.has_prefix(rest, ":contains("):
			open := strings.index_byte(rest, '(')
			end := html_close_paren(rest, open)
			if end < 0 { html_rule_destroy(&r); return {}, false }
			html_add_text(&r, strings.trim_space(rest[open + 1:end]), false)
			rest = rest[end + 1:]
		case strings.has_prefix(rest, ":not("):
			end := html_close_paren(rest, 4)
			if end < 0 { html_rule_destroy(&r); return {}, false }
			inner := strings.trim_space(rest[5:end])
			if !html_add_not(&r, inner) { html_rule_destroy(&r); return {}, false }
			rest = rest[end + 1:]
		case:
			html_rule_destroy(&r); return {}, false
		}
	}
	return r, true
}

@(private = "file")
html_close_paren :: proc(s: string, open: int) -> int {
	depth := 0
	quote: u8 = 0
	for i := open; i < len(s); i += 1 {
		c := s[i]
		if quote != 0 { if c == '\\' { i += 1 } else if c == quote { quote = 0 }; continue }
		switch c {
		case '"', '\'': quote = c
		case '\\': i += 1
		case '(': depth += 1
		case ')': depth -= 1; if depth == 0 { return i }
		}
	}
	return -1
}

@(private = "file")
html_add_text :: proc(r: ^Html_Rule, arg: string, negate: bool) {
	o := Html_Op{kind = .Has_Text, negate = negate}
	a := strings.trim(arg, "\"'")
	if len(a) >= 2 && a[0] == '/' {
		if last := strings.last_index_byte(a, '/'); last > 0 {
			if re := jsre_compile(a[1:last], a[last + 1:]); re != nil {
				o.re = re
				o.re_src = strings.clone(a[1:last])
				o.re_flags = strings.clone(a[last + 1:])
				append(&r.ops, o)
				return
			}
		}
	}
	o.text = strings.clone(a)
	append(&r.ops, o)
}

@(private = "file")
html_add_attr :: proc(r: ^Html_Rule, test: string, negate: bool) -> bool {
	t := strings.trim_space(test)
	if t == "" { return false }
	op, opi := "", -1
	for cand in ([]string{"*=", "^=", "$=", "~=", "="}) { if k := strings.index(t, cand); k >= 0 && (opi < 0 || k < opi) { op, opi = cand, k } }
	o := Html_Op{kind = .Attr, negate = negate, op = op}
	want := ""   // a slice of `test` until it is cloned into the op
	if opi < 0 {
		o.attr = strings.to_lower(strings.trim_space(t))
	} else {
		o.attr = strings.to_lower(strings.trim_space(t[:opi]))
		want = strings.trim(strings.trim_space(t[opi + len(op):]), "\"'")
	}
	if o.attr == "" { delete(o.attr); return false }
	o.want = strings.clone(want)
	append(&r.ops, o)
	return true
}

@(private = "file")
html_add_not :: proc(r: ^Html_Rule, inner: string) -> bool {
	switch {
	case strings.has_prefix(inner, ":has-text(") || strings.has_prefix(inner, ":contains("):
		open := strings.index_byte(inner, '(')
		end := html_close_paren(inner, open)
		if end < 0 { return false }
		html_add_text(r, strings.trim_space(inner[open + 1:end]), true)
		return true
	case strings.has_prefix(inner, "[") && strings.has_suffix(inner, "]"):
		return html_add_attr(r, inner[1:len(inner) - 1], true)
	}
	return false
}

////////////////////////////////
// Matching on the raw bytes

// A start tag found in the stream: its name, its attribute text (between the name and `>`), where it starts (`<`) and
// where its content starts (after `>`), and whether it is self-closing or a void element (no end tag to look for).
@(private = "file")
Html_Tag :: struct {
	name:    string,     // as written (comparison is case-insensitive)
	attrs:   string,     // the text between the name and `>`
	open:    int,        // index of `<`
	content: int,        // index after `>`
	void:    bool,       // `<img ... />` or a void element
}

@(private = "file")
VOID_ELEMENTS := [?]string{"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}

@(private = "file")
is_void_name :: proc(name: string) -> bool {
	for v in VOID_ELEMENTS { if strings.equal_fold(name, v) { return true } }
	return false
}

// The index after the end tag `</name>` that closes a start tag at `from`, respecting nesting of the same tag and the raw
// text of <script> / <style> / <textarea> / <title> (their content is never markup). -1 when the stream ends first.
@(private = "file")
html_element_end :: proc(text, name: string, from: int) -> int {
	raw := strings.equal_fold(name, "script") || strings.equal_fold(name, "style") || strings.equal_fold(name, "textarea") || strings.equal_fold(name, "title")
	if raw {
		close := strings.concatenate({"</", name}, context.temp_allocator)
		i := from
		for {
			k := index_fold(text[i:], close)
			if k < 0 { return -1 }
			j := i + k + len(close)
			g := strings.index_byte(text[j:], '>')
			if g < 0 { return -1 }
			return j + g + 1
		}
	}
	depth := 1
	i := from
	for i < len(text) {
		lt := strings.index_byte(text[i:], '<')
		if lt < 0 { return -1 }
		i += lt
		if strings.has_prefix(text[i:], "<!--") {
			e := strings.index(text[i:], "-->")
			if e < 0 { return -1 }
			i += e + 3
			continue
		}
		if i + 1 < len(text) && text[i + 1] == '/' {
			g := strings.index_byte(text[i:], '>')
			if g < 0 { return -1 }
			tag := strings.trim_space(text[i + 2:i + g])
			if name_matches(tag, name) {
				depth -= 1
				if depth == 0 { return i + g + 1 }
			}
			i += g + 1
			continue
		}
		t, ok := html_read_tag(text, i)
		if !ok { i += 1; continue }
		if name_matches(t.name, name) && !t.void { depth += 1 }
		i = t.content
	}
	return -1
}

@(private = "file")
name_matches :: proc(a, b: string) -> bool {
	// compare the element-name prefix (stop at whitespace or `/`)
	end := 0
	for end < len(a) && a[end] != ' ' && a[end] != '\t' && a[end] != '\n' && a[end] != '\r' && a[end] != '/' { end += 1 }
	return strings.equal_fold(a[:end], b)
}

@(private = "file")
index_fold :: proc(hay, needle: string) -> int {
	if needle == "" { return 0 }
	if len(needle) > len(hay) { return -1 }
	for i in 0 ..= len(hay) - len(needle) {
		if strings.equal_fold(hay[i:i + len(needle)], needle) { return i }
	}
	return -1
}

// Reads the start tag at `text[i]` (text[i] must be `<`). ok = false for a comment, doctype, processing instruction or an
// end tag.
@(private = "file")
html_read_tag :: proc(text: string, i: int) -> (t: Html_Tag, ok: bool) {
	if i >= len(text) || text[i] != '<' { return {}, false }
	if strings.has_prefix(text[i:], "<!") || strings.has_prefix(text[i:], "<?") || strings.has_prefix(text[i:], "</") { return {}, false }
	j := i + 1
	if j >= len(text) || !is_tag_start(text[j]) { return {}, false }
	ns := j
	for j < len(text) && !(text[j] == ' ' || text[j] == '\t' || text[j] == '\n' || text[j] == '\r' || text[j] == '>' || text[j] == '/') { j += 1 }
	name := text[ns:j]
	// find the `>` outside quotes
	quote: u8 = 0
	for j < len(text) {
		c := text[j]
		if quote != 0 { if c == quote { quote = 0 } } else if c == '"' || c == '\'' { quote = c } else if c == '>' { break }
		j += 1
	}
	if j >= len(text) { return {}, false }
	attrs := text[ns + len(name):j]
	t = Html_Tag{name = name, attrs = attrs, open = i, content = j + 1, void = strings.has_suffix(strings.trim_space(attrs), "/") || is_void_name(name)}
	return t, true
}

@(private = "file")
is_tag_start :: proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }

// Reads attribute `name` from a start tag's attribute text. has = false when the attribute is absent.
@(private = "file")
html_attr :: proc(attrs, name: string) -> (value: string, has: bool) {
	rest := attrs
	for {
		k := index_fold(rest, name)
		if k < 0 { return "", false }
		before := k == 0 ? u8(' ') : rest[k - 1]
		after := rest[k + len(name):]
		boundary := before == ' ' || before == '\t' || before == '\n' || before == '\r'
		starts := len(after) == 0 || after[0] == '=' || after[0] == ' ' || after[0] == '\t' || after[0] == '\n' || after[0] == '\r' || after[0] == '/' || after[0] == '>'
		if boundary && starts {
			trimmed := strings.trim_left_space(after)
			if !strings.has_prefix(trimmed, "=") { return "", true }   // a boolean attribute
			v := strings.trim_left_space(trimmed[1:])
			if len(v) > 0 && (v[0] == '"' || v[0] == '\'') {
				e := strings.index_byte(v[1:], v[0])
				if e >= 0 { return v[1:1 + e], true }
				return "", true
			}
			e := 0
			for e < len(v) && !(v[e] == ' ' || v[e] == '\t' || v[e] == '\n' || v[e] == '\r' || v[e] == '>') { e += 1 }
			return v[:e], true
		}
		rest = rest[k + len(name):]
	}
}

@(private = "file")
html_glob :: proc(pat, v: string) -> bool {
	if !strings.contains_rune(pat, '*') { return strings.contains(v, pat) }
	parts := strings.split(pat, "*", context.temp_allocator)
	pos := 0
	for part, i in parts {
		if part == "" { continue }
		at := strings.index(v[pos:], part)
		if at < 0 { return false }
		if i == 0 && at != 0 && pat[0] != '*' { return false }
		pos += at + len(part)
	}
	return true
}

@(private = "file")
contains_word :: proc(s, w: string) -> bool {
	for part in strings.fields(s, context.temp_allocator) { if part == w { return true } }
	return false
}

// Does the element (start tag `t`, element text `content`) satisfy every operator of the rule? `content` is the UTF-8 text
// between the start and end tags (decoded once, only when a :has-text op needs it).
@(private = "file")
html_rule_matches :: proc(r: ^Html_Rule, t: ^Html_Tag, content: string) -> bool {
	if r.tag != "*" && !strings.equal_fold(r.tag, t.name) { return false }
	for &o in r.ops {
		hit := false
		switch o.kind {
		case .Has_Text:
			if o.re != nil { hit = jsre_test(o.re, content) } else { hit = html_glob(o.text, content) }
		case .Attr:
			got, has := html_attr(t.attrs, o.attr)
			if !has { hit = false } else if o.op == "" { hit = true } else {
				switch o.op {
				case "=":  hit = got == o.want
				case "*=": hit = strings.contains(got, o.want)
				case "^=": hit = strings.has_prefix(got, o.want)
				case "$=": hit = strings.has_suffix(got, o.want)
				case "~=": hit = contains_word(got, o.want)
				}
			}
		}
		if o.negate { hit = !hit }
		if !hit { return false }
	}
	return true
}

////////////////////////////////
// Body filter

// Holds the whole HTML body (up to a cap), scans it on finish, and emits it with the matched elements deleted. Only the
// document (and frame) response of the targeted host reaches this filter (rewrite.odin).
Html_Doc_Filter :: struct {
	rules:   [dynamic]Html_Rule,     // clones, owned by the filter
	hold:    [dynamic]byte,
	through: bool,                   // the body passed the size cap: stream it untouched
	max:     int,                    // size cap (bytes)
	doc_url: string,                 // owned: the document whose markup is filtered (for the journal)
	on_hit:  proc(user: rawptr, doc_url, tag: string),   // nil or a per-removal callback (the dashboard's count and log)
	user:    rawptr,
}

@(private = "file")
html_doc_push :: proc(user: rawptr, chunk: []byte, out: ^[dynamic]byte) {
	f := (^Html_Doc_Filter)(user)
	if f.through { append(out, ..chunk); return }
	append(&f.hold, ..chunk)
	if len(f.hold) > f.max {
		f.through = true
		append(out, ..f.hold[:])
		clear(&f.hold)
	}
}

@(private = "file")
html_doc_finish :: proc(user: rawptr, out: ^[dynamic]byte) {
	f := (^Html_Doc_Filter)(user)
	if f.through || len(f.hold) == 0 { return }
	text := string(f.hold[:])
	emit := html_apply(f, text)
	append(out, ..transmute([]byte)emit)
	clear(&f.hold)
}

@(private = "file")
html_doc_destroy :: proc(user: rawptr) {
	f := (^Html_Doc_Filter)(user)
	for &r in f.rules { html_rule_destroy(&r) }
	delete(f.rules); delete(f.hold); delete(f.doc_url)
	free(f)
}

// The body with every element that a rule matches deleted (its `<...>...</...>` byte range removed). Overlapping removals
// are merged by scanning left to right and skipping into an already-removed range.
@(private = "file")
html_apply :: proc(f: ^Html_Doc_Filter, text: string) -> string {
	// first collect the byte ranges to delete, in order; matching needs the element's text, which for `:has-text` is
	// decoded to UTF-8 (the stream itself is left in its original charset)
	Range :: struct { start, end: int }
	ranges := make([dynamic]Range, context.temp_allocator)
	need_text := false
	for &r in f.rules { for &o in r.ops { if o.kind == .Has_Text { need_text = true } } }
	i := 0
	for i < len(text) {
		lt := strings.index_byte(text[i:], '<')
		if lt < 0 { break }
		i += lt
		if strings.has_prefix(text[i:], "<!--") {
			e := strings.index(text[i:], "-->")
			if e < 0 { break }
			i += e + 3
			continue
		}
		t, ok := html_read_tag(text, i)
		if !ok { i += 1; continue }
		// does any rule's tag match? (cheap gate before computing the element's text)
		any_tag := false
		for &r in f.rules { if r.tag == "*" || strings.equal_fold(r.tag, t.name) { any_tag = true; break } }
		if !any_tag { i = t.content; continue }

		end := t.content
		if !t.void { if e := html_element_end(text, t.name, t.content); e >= 0 { end = e } }
		// the element's text, decoded once (for :has-text); the bytes between the start tag's `>` and the end tag's `<`
		content := ""
		if need_text {
			raw := end > t.content ? text[t.content:end] : ""
			// trim the trailing end tag from the slice so its text is only the element's content
			if end > t.content {
				if last := strings.last_index_byte(raw, '<'); last >= 0 { raw = raw[:last] }
			}
			if dec, dok := html.decode_document(transmute([]byte)raw, "", "windows-1252", context.temp_allocator, false); dok {
				content = string(dec.text)
			} else { content = raw }
		}
		matched := false
		for &r in f.rules { if html_rule_matches(&r, &t, content) { matched = true; break } }
		if matched {
			append(&ranges, Range{t.open, end})
			if f.on_hit != nil { f.on_hit(f.user, f.doc_url, t.name) }
			i = end
		} else {
			i = t.content
		}
	}
	if len(ranges) == 0 { return text }
	sb := strings.builder_make(context.temp_allocator)
	at := 0
	for rg in ranges {
		if rg.start < at { continue }   // inside an already-removed range
		strings.write_string(&sb, text[at:rg.start])
		at = rg.end
	}
	strings.write_string(&sb, text[at:])
	return strings.to_string(sb)
}

// Builds the document body filter for a host's HTML rules, or the zero filter when there is none. `max` is the size cap;
// `on_hit` (may be nil) is called once per element removed, with the document URL and the element's tag name.
html_doc_filter_make :: proc(rules: []Html_Rule, max: int, doc_url: string, on_hit: proc(user: rawptr, doc_url, tag: string), user: rawptr) -> fetch.Body_Filter {
	if len(rules) == 0 { return {} }
	f := new(Html_Doc_Filter)
	f.max = max
	f.doc_url = strings.clone(doc_url)
	f.on_hit = on_hit
	f.user = user
	for r in rules { append(&f.rules, html_rule_clone(r)) }
	return fetch.Body_Filter{user = f, push = html_doc_push, finish = html_doc_finish, destroy = html_doc_destroy}
}

@(private = "file")
html_rule_clone :: proc(r: Html_Rule) -> Html_Rule {
	c := Html_Rule{tag = strings.clone(r.tag)}
	for o in r.ops {
		no := Html_Op{kind = o.kind, negate = o.negate, op = o.op}
		no.text = strings.clone(o.text)
		no.attr = strings.clone(o.attr)
		no.want = strings.clone(o.want)
		if o.re != nil {
			no.re_src = strings.clone(o.re_src)
			no.re_flags = strings.clone(o.re_flags)
			no.re = jsre_compile(no.re_src, no.re_flags)
		}
		append(&c.ops, no)
	}
	return c
}
