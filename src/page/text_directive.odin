package page

// Text fragments (URL Fragment Text Directives): `#:~:text=[prefix-,]start[,end][,-suffix]` marks a passage of the document, which ::target-text paints and which comes into
// view. What follows `:~:` is the browser's, a page never sees it in its URL. Found over the text as it reads, whitespace folded, case aside; a passage may go over several
// nodes. A document in a frame has none: a page must not learn from another's frame whether it holds a text.

import "core:strings"
import "wb:base"
import "wb:dom"
import lay "wb:layout"
import "wb:style"
import "wb:url"

@(private = "file") DIRECTIVE_DELIMITER :: ":~:"
@(private = "file") TEXT_PREFIX :: "text="

@(private = "file")
Text_Directive :: struct {
	prefix, start, end, suffix: string,
}

// One `text=` value; ok false: it does not read as one.
@(private = "file")
directive_parse :: proc(value: string) -> (d: Text_Directive, ok: bool) {
	parts := strings.split(value, ",", context.temp_allocator)
	first, last := 0, len(parts)
	if first < last && strings.has_suffix(parts[first], "-") {
		d.prefix = url.percent_decode(parts[first][:len(parts[first]) - 1])
		first += 1
	}
	if first < last && strings.has_prefix(parts[last - 1], "-") {
		d.suffix = url.percent_decode(parts[last - 1][1:])
		last -= 1
	}
	if last - first < 1 || last - first > 2 || parts[first] == "" { return }
	d.start = url.percent_decode(parts[first])
	if last - first == 2 { d.end = url.percent_decode(parts[first + 1]) }
	return d, true
}

// The document's text as it reads: its visible text nodes end to end, whitespace folded into one space, lowered as ASCII; `at[i]` is where byte i comes from.
@(private = "file")
Flat_Text :: struct {
	text: [dynamic]u8,
	at:   [dynamic]lay.Text_Pos,
}

@(private = "file")
flat_text_of :: proc(p: ^Page) -> (f: Flat_Text) {
	f.text = make([dynamic]u8, context.temp_allocator)
	f.at = make([dynamic]lay.Text_Pos, context.temp_allocator)
	d := p.doc
	for cur := d.root; cur != base.NIL_HANDLE; cur = dom.next_in_tree(d, cur, d.root) {
		n := dom.get(d, cur)
		if n == nil || n.kind != .Text { continue }
		cs := style.style_of(p.styled, n.parent)
		if cs == nil || cs.display == .None || cs.visibility != .Visible { continue }
		for i in 0 ..< len(n.text) {
			c := n.text[i]
			if c == ' ' || c == '\n' || c == '\t' || c == '\r' || c == '\f' {
				if len(f.text) == 0 || f.text[len(f.text) - 1] == ' ' { continue }
				c = ' '
			} else if c >= 'A' && c <= 'Z' { c += 'a' - 'A' }
			append(&f.text, c)
			append(&f.at, lay.Text_Pos{cur, i})
		}
	}
	return
}

// `s` folded as the text is.
@(private = "file")
flat_needle :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)strings.trim_space(s) {
		switch {
		case c == ' ' || c == '\n' || c == '\t' || c == '\r' || c == '\f': if len(b.buf) > 0 && b.buf[len(b.buf) - 1] != ' ' { strings.write_byte(&b, ' ') }
		case c >= 'A' && c <= 'Z': strings.write_byte(&b, c + 'a' - 'A')
		case: strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

// The passage of `d` in `text`: its first bytes and past its last. The end of `start` and of `end` are at word boundaries or not: the directive says what it says.
@(private = "file")
directive_find :: proc(text: string, d: Text_Directive) -> (lo, hi: int, ok: bool) {
	start, end, prefix, suffix := flat_needle(d.start), flat_needle(d.end), flat_needle(d.prefix), flat_needle(d.suffix)
	for from := 0; from < len(text); {
		i := strings.index(text[from:], start)
		if i < 0 { return }
		lo = from + i
		from = lo + 1
		hi = lo + len(start)
		if prefix != "" {
			before := strings.trim_right(text[:lo], " ")
			if !strings.has_suffix(before, prefix) { continue }
		}
		if end != "" {
			j := strings.index(text[hi:], end)
			if j < 0 { return lo, hi, false }
			hi += j + len(end)
		}
		if suffix != "" {
			after := strings.trim_left(text[hi:], " ")
			if !strings.has_prefix(after, suffix) { continue }
		}
		return lo, hi, true
	}
	return
}

// Takes what the URL says of text out of it and marks that text; what comes into view is the first of it. `found`: there was a passage, it is that which is scrolled to.
text_directive_apply :: proc(p: ^Page) -> (first: lay.Text_Pos, found: bool) {
	href := p.env.location.href
	i := strings.index(href, "#")
	if i < 0 { return }
	cut := strings.index(href[i:], DIRECTIVE_DELIMITER)
	if cut < 0 { return }
	directive := strings.clone(href[i + cut + len(DIRECTIVE_DELIMITER):], context.temp_allocator)
	_ = set_document_url(p, strings.clone(href[:i + cut], context.temp_allocator))
	if page_top(p) != p || p.styled == nil { return }
	js_layout_now(p)
	flat := flat_text_of(p)
	text := string(flat.text[:])
	ranges := make([dynamic][2]lay.Text_Pos, context.temp_allocator)
	for piece in strings.split(directive, "&", context.temp_allocator) {
		if !strings.has_prefix(piece, TEXT_PREFIX) { continue }
		d := directive_parse(piece[len(TEXT_PREFIX):]) or_continue
		lo, hi := directive_find(text, d) or_continue
		last := flat.at[hi - 1]
		append(&ranges, [2]lay.Text_Pos{flat.at[lo], {last.node, last.offset + 1}})
	}
	marks_set(p, .Target_Text, ranges[:])
	if len(ranges) == 0 { return }
	return ranges[0][0], true
}
