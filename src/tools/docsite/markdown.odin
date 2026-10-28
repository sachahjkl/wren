// A CommonMark subset tuned to the documentation Wren actually ships: ATX headings (with GitHub-style anchors),
// paragraphs, ATX-fenced code blocks (``` with an info string), GFM tables, blockquotes, bullet and ordered lists
// (nested by indentation), thematic breaks, and the inline grammar below. HTML blocks that start a line with a known
// block tag are passed through verbatim (the docs use a few <sub>, <a name> and comment lines); anything else is
// treated as text and escaped. It is a renderer, not a validator: malformed input produces plausible HTML, never a
// crash, so a doc author sees their mistake in the page rather than in a tool failure.
//
// Inline: `code`, **strong**, *emph* / _emph_, [text](url) links, ![alt](src) images, autolinks <http://...>,
// hard line breaks (two trailing spaces), and the backslash escapes CommonMark lists. Relative links of the form
// `foo.md`, `dir/foo.md` and `../README.md` are rewritten to the site's URLs by `link_rewrite` (set on Doc).
package docsite

import "core:strings"

// One rendered document: its HTML body and the headings collected for a table of contents.
Rendered :: struct {
	html:     string,
	headings: [dynamic]Heading,
	// Plain text of the body, for the search index (no markup, collapsed whitespace).
	plain:    string,
}

Heading :: struct {
	level: int,    // 1..6
	text:  string, // rendered inline-stripped text
	id:    string, // the anchor slug, unique within the document
}

// How the renderer resolves a link target. `rewrite` turns a relative `.md` path into the site URL; it returns ""
// to leave the href untouched (absolute URLs, fragments, mailto, etc.). `anchor` registers a heading slug so the
// renderer can keep them unique and the caller can check inner anchors afterwards.
Md_Context :: struct {
	rewrite:   proc(href: string, ctx: rawptr) -> string,
	user:      rawptr,
	seen_ids:  map[string]int, // slug -> how many times, to disambiguate duplicates
}

render_markdown :: proc(source: string, ctx: ^Md_Context, allocator := context.allocator) -> Rendered {
	context.allocator = allocator
	r: Rendered
	r.headings = make([dynamic]Heading)
	b := strings.builder_make()
	plain := strings.builder_make()
	lines := split_lines_keep(source)
	i := 0
	for i < len(lines) {
		line := lines[i]
		trimmed := strings.trim_left_space(line)

		// blank line: nothing
		if len(strings.trim_space(line)) == 0 { i += 1; continue }

		// fenced code block
		if fence, lang, ok := code_fence(trimmed); ok {
			i += 1
			code := strings.builder_make()
			for i < len(lines) {
				l := lines[i]
				if is_closing_fence(strings.trim_left_space(l), fence) { i += 1; break }
				strings.write_string(&code, l)
				strings.write_byte(&code, '\n')
				i += 1
			}
			emit_code_block(&b, strings.to_string(code), lang)
			strings.write_string(&plain, strings.to_string(code))
			strings.write_byte(&plain, ' ')
			continue
		}

		// HTML block / comment: a line beginning with '<' + a known block tag or a comment is copied through
		if len(trimmed) > 0 && trimmed[0] == '<' && is_html_block_start(trimmed) {
			for i < len(lines) {
				l := lines[i]
				if len(strings.trim_space(l)) == 0 { break }
				strings.write_string(&b, l)
				strings.write_byte(&b, '\n')
				i += 1
			}
			continue
		}

		// ATX heading
		if level, rest, ok := atx_heading(trimmed); ok {
			emit_heading(&b, &r, ctx, level, rest, &plain)
			i += 1
			continue
		}

		// thematic break
		if is_thematic_break(trimmed) {
			strings.write_string(&b, "<hr>\n")
			i += 1
			continue
		}

		// table: a header row followed by a delimiter row
		if i + 1 < len(lines) && is_table_delimiter(strings.trim_space(lines[i + 1])) && strings.contains(line, "|") {
			i = emit_table(&b, &plain, lines, i, ctx)
			continue
		}

		// blockquote
		if strings.has_prefix(trimmed, ">") {
			block := make([dynamic]string)
			for i < len(lines) {
				t := strings.trim_left_space(lines[i])
				if !strings.has_prefix(t, ">") { break }
				inner := t[1:]
				if len(inner) > 0 && inner[0] == ' ' { inner = inner[1:] }
				append(&block, inner)
				i += 1
			}
			sub := render_markdown(strings.join(block[:], "\n"), ctx, allocator)
			strings.write_string(&b, "<blockquote>\n")
			strings.write_string(&b, sub.html)
			strings.write_string(&b, "</blockquote>\n")
			strings.write_string(&plain, sub.plain)
			strings.write_byte(&plain, ' ')
			continue
		}

		// list (bullet or ordered)
		if _, _, ok := list_marker(line); ok {
			i = emit_list(&b, &plain, lines, i, ctx)
			continue
		}

		// paragraph: gather until a blank line or a block start
		para := make([dynamic]string)
		for i < len(lines) {
			l := lines[i]
			t := strings.trim_left_space(l)
			if len(strings.trim_space(l)) == 0 { break }
			if _, _, ok := atx_heading(t); ok { break }
			if _, _, ok := code_fence(t); ok { break }
			if _, _, ok := list_marker(l); ok { break }
			if is_thematic_break(t) { break }
			if strings.has_prefix(t, ">") { break }
			if i + 1 < len(lines) && is_table_delimiter(strings.trim_space(lines[i + 1])) && strings.contains(l, "|") { break }
			append(&para, strings.trim_space(l))
			i += 1
		}
		text := strings.join(para[:], "\n")
		strings.write_string(&b, "<p>")
		strings.write_string(&b, render_inline(text, ctx, &plain))
		strings.write_string(&b, "</p>\n")
		strings.write_byte(&plain, ' ')
	}
	r.html = strings.to_string(b)
	r.plain = strings.to_string(plain)
	return r
}

// --- blocks -----------------------------------------------------------------

emit_heading :: proc(b: ^strings.Builder, r: ^Rendered, ctx: ^Md_Context, level: int, rest: string, plain: ^strings.Builder) {
	// a trailing run of '#' is a closing sequence in ATX; drop it
	text := strings.trim_right(rest, "#")
	text = strings.trim_space(text)
	inline_text := strings.builder_make(context.temp_allocator)
	html := render_inline(text, ctx, &inline_text)
	bare := strings.to_string(inline_text)
	id := unique_slug(ctx, slugify(bare))
	strings.write_string(b, "<h")
	write_int(b, level)
	strings.write_string(b, " id=\"")
	strings.write_string(b, id)
	strings.write_string(b, "\"><a class=\"anchor\" href=\"#")
	strings.write_string(b, id)
	strings.write_string(b, "\" aria-hidden=\"true\">#</a>")
	strings.write_string(b, html)
	strings.write_string(b, "</h")
	write_int(b, level)
	strings.write_string(b, ">\n")
	append(&r.headings, Heading{level = level, text = strings.clone(bare), id = id})
	strings.write_string(plain, bare)
	strings.write_byte(plain, ' ')
}

// A list: consecutive items at the item's own indentation. A blank line inside makes the list "loose" (items wrapped
// in <p>). Nested lists are handed back to the block parser on the item's continuation lines.
emit_list :: proc(b: ^strings.Builder, plain: ^strings.Builder, lines: []string, start: int, ctx: ^Md_Context) -> int {
	i := start
	_, ordered0, _ := list_marker(lines[start])
	tag := ordered0 ? "ol" : "ul"
	strings.write_string(b, "<")
	strings.write_string(b, tag)
	strings.write_string(b, ">\n")
	for i < len(lines) {
		line := lines[i]
		indent, ordered, ok := list_marker(line)
		if !ok || ordered != ordered0 { break }
		// content of this item: the marker line's text, plus deeper-indented continuation lines
		marker_end := list_content_start(line)
		item := make([dynamic]string)
		append(&item, line[marker_end:])
		i += 1
		for i < len(lines) {
			l := lines[i]
			if len(strings.trim_space(l)) == 0 {
				// blank: keep if the next non-blank is still part of this item (deeper indent)
				j := i
				for j < len(lines) && len(strings.trim_space(lines[j])) == 0 { j += 1 }
				if j < len(lines) && leading_spaces(lines[j]) > indent {
					append(&item, "")
					i += 1
					continue
				}
				break
			}
			if _, _, is_item := list_marker(l); is_item && leading_spaces(l) <= indent { break }
			if leading_spaces(l) > indent {
				append(&item, l[min(marker_end, leading_spaces(l)):])
			} else {
				append(&item, strings.trim_left_space(l))
			}
			i += 1
		}
		sub := render_markdown(strings.join(item[:], "\n"), ctx, context.allocator)
		strings.write_string(b, "<li>")
		// a single paragraph item renders tight (no <p>)
		inner := strings.trim_space(sub.html)
		if strings.has_prefix(inner, "<p>") && strings.has_suffix(inner, "</p>") && strings.count(inner, "<p>") == 1 {
			inner = inner[3:len(inner) - 4]
		}
		strings.write_string(b, inner)
		strings.write_string(b, "</li>\n")
		strings.write_string(plain, sub.plain)
		strings.write_byte(plain, ' ')
	}
	strings.write_string(b, "</")
	strings.write_string(b, tag)
	strings.write_string(b, ">\n")
	return i
}

emit_table :: proc(b: ^strings.Builder, plain: ^strings.Builder, lines: []string, start: int, ctx: ^Md_Context) -> int {
	header := split_table_row(lines[start])
	aligns := table_aligns(lines[start + 1])
	strings.write_string(b, "<div class=\"table-box\"><table>\n<thead><tr>")
	for cell, k in header {
		strings.write_string(b, "<th")
		write_align(b, aligns, k)
		strings.write_string(b, ">")
		strings.write_string(b, render_inline(cell, ctx, plain))
		strings.write_string(b, "</th>")
	}
	strings.write_string(b, "</tr></thead>\n<tbody>\n")
	i := start + 2
	for i < len(lines) {
		row := strings.trim_space(lines[i])
		if len(row) == 0 || !strings.contains(row, "|") { break }
		cells := split_table_row(lines[i])
		strings.write_string(b, "<tr>")
		for k in 0 ..< len(header) {
			cell := k < len(cells) ? cells[k] : ""
			strings.write_string(b, "<td")
			write_align(b, aligns, k)
			strings.write_string(b, ">")
			strings.write_string(b, render_inline(cell, ctx, plain))
			strings.write_string(b, "</td>")
		}
		strings.write_string(b, "</tr>\n")
		i += 1
	}
	strings.write_string(b, "</tbody>\n</table></div>\n")
	strings.write_byte(plain, ' ')
	return i
}

write_align :: proc(b: ^strings.Builder, aligns: []string, k: int) {
	if k < len(aligns) && aligns[k] != "" {
		strings.write_string(b, " style=\"text-align:")
		strings.write_string(b, aligns[k])
		strings.write_string(b, "\"")
	}
}

// --- inline -----------------------------------------------------------------

// Render an inline string to HTML; append its stripped text to `plain` for search.
render_inline :: proc(s: string, ctx: ^Md_Context, plain: ^strings.Builder) -> string {
	b := strings.builder_make()
	n := len(s)
	i := 0
	for i < n {
		c := s[i]
		switch c {
		case '\\':
			if i + 1 < n && is_escapable(s[i + 1]) {
				write_escaped_byte(&b, s[i + 1])
				strings.write_byte(plain, s[i + 1])
				i += 2
				continue
			}
			strings.write_byte(&b, '\\')
			i += 1
		case '`':
			// a run of n backticks opens code until the same run
			run := backtick_run(s, i)
			end := find_backtick_close(s, i + run, run)
			if end >= 0 {
				code := strings.trim_space(s[i + run:end])
				strings.write_string(&b, "<code>")
				write_html_escaped(&b, code)
				strings.write_string(&b, "</code>")
				strings.write_string(plain, code)
				i = end + run
				continue
			}
			strings.write_byte(&b, '`')
			i += 1
		case '*', '_':
			// **strong** / __strong__ then *em* / _em*. An intra-word '_' (letters/digits on both sides, as in
			// gui_toolkit or api_generated) is literal: CommonMark does not open '_' emphasis inside a word.
			intra := c == '_' && i > 0 && is_alnum(s[i - 1]) && i + 1 < n && is_alnum(s[i + 1])
			if !intra {
				if i + 1 < n && s[i + 1] == c {
					if end := find_delim(s, i + 2, c, 2); end >= 0 {
						strings.write_string(&b, "<strong>")
						strings.write_string(&b, render_inline(s[i + 2:end], ctx, plain))
						strings.write_string(&b, "</strong>")
						i = end + 2
						continue
					}
				}
				if end := find_delim(s, i + 1, c, 1); end >= 0 && end > i + 1 {
					strings.write_string(&b, "<em>")
					strings.write_string(&b, render_inline(s[i + 1:end], ctx, plain))
					strings.write_string(&b, "</em>")
					i = end + 1
					continue
				}
			}
			write_escaped_byte(&b, c)
			strings.write_byte(plain, c)
			i += 1
		case '!':
			if i + 1 < n && s[i + 1] == '[' {
				if alt, dest, _, next, ok := parse_link(s, i + 1); ok {
					strings.write_string(&b, "<img src=\"")
					write_attr_escaped(&b, resolve_href(ctx, dest))
					strings.write_string(&b, "\" alt=\"")
					write_attr_escaped(&b, alt)
					strings.write_string(&b, "\" loading=\"lazy\">")
					strings.write_string(plain, alt)
					i = next
					continue
				}
			}
			strings.write_byte(&b, '!')
			i += 1
		case '[':
			if text, dest, title, next, ok := parse_link(s, i); ok {
				strings.write_string(&b, "<a href=\"")
				write_attr_escaped(&b, resolve_href(ctx, dest))
				strings.write_string(&b, "\"")
				if title != "" {
					strings.write_string(&b, " title=\"")
					write_attr_escaped(&b, title)
					strings.write_string(&b, "\"")
				}
				if is_external(dest) {
					strings.write_string(&b, " rel=\"noopener\"")
				}
				strings.write_string(&b, ">")
				strings.write_string(&b, render_inline(text, ctx, plain))
				strings.write_string(&b, "</a>")
				i = next
				continue
			}
			strings.write_byte(&b, '[')
			i += 1
		case '<':
			// autolink <http://...> or <a@b>
			if end := strings.index_byte(s[i:], '>'); end > 0 {
				inside := s[i + 1:i + end]
				if is_autolink(inside) {
					href := inside
					if strings.contains(inside, "@") && !strings.contains(inside, ":") { href = strings.concatenate({"mailto:", inside}, context.temp_allocator) }
					strings.write_string(&b, "<a href=\"")
					write_attr_escaped(&b, href)
					strings.write_string(&b, "\" rel=\"noopener\">")
					write_html_escaped(&b, inside)
					strings.write_string(&b, "</a>")
					strings.write_string(plain, inside)
					i = i + end + 1
					continue
				}
			}
			strings.write_string(&b, "&lt;")
			i += 1
		case '&':
			// keep an existing entity, escape a bare ampersand
			if is_entity(s, i) { strings.write_byte(&b, '&') } else { strings.write_string(&b, "&amp;") }
			i += 1
		case '>':
			strings.write_string(&b, "&gt;")
			i += 1
		case '\n':
			// a hard break is two trailing spaces before the newline
			if i >= 2 && s[i - 1] == ' ' && s[i - 2] == ' ' {
				strings.write_string(&b, "<br>\n")
			} else {
				strings.write_byte(&b, '\n')
			}
			strings.write_byte(plain, ' ')
			i += 1
		case:
			strings.write_byte(&b, c)
			strings.write_byte(plain, c)
			i += 1
		}
	}
	return strings.to_string(b)
}

is_alnum :: proc(c: byte) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

resolve_href :: proc(ctx: ^Md_Context, dest: string) -> string {
	if ctx != nil && ctx.rewrite != nil {
		if out := ctx.rewrite(dest, ctx.user); out != "" { return out }
	}
	return dest
}
