package docsite

import "core:strconv"
import "core:strings"

// Split into lines, dropping a trailing '\r' of each (the docs are mixed CRLF/LF). The final line (no newline) is kept.
split_lines_keep :: proc(s: string) -> []string {
	out := make([dynamic]string, context.allocator)
	start := 0
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\n' {
			line := s[start:i]
			line = strings.trim_right(line, "\r")
			append(&out, line)
			start = i + 1
		}
	}
	if start <= len(s) {
		append(&out, strings.trim_right(s[start:], "\r"))
	}
	return out[:]
}

leading_spaces :: proc(s: string) -> int {
	n := 0
	for n < len(s) && (s[n] == ' ' || s[n] == '\t') {
		n += s[n] == '\t' ? 4 : 1
	}
	return n
}

// `# Heading` through `###### Heading`: returns the level and the text after the hashes (and one space).
atx_heading :: proc(s: string) -> (level: int, rest: string, ok: bool) {
	i := 0
	for i < len(s) && s[i] == '#' { i += 1 }
	if i == 0 || i > 6 { return 0, "", false }
	if i < len(s) && s[i] != ' ' { return 0, "", false }
	return i, strings.trim_space(s[i:]), true
}

// A code fence: three or more '`' (or '~'), then an optional info string whose first word is the language.
code_fence :: proc(s: string) -> (fence: string, lang: string, ok: bool) {
	if len(s) < 3 { return "", "", false }
	c := s[0]
	if c != '`' && c != '~' { return "", "", false }
	n := 0
	for n < len(s) && s[n] == c { n += 1 }
	if n < 3 { return "", "", false }
	info := strings.trim_space(s[n:])
	// the first token of the info string is the language
	if sp := strings.index_any(info, " \t"); sp >= 0 { info = info[:sp] }
	return s[:n], strings.to_lower(info, context.temp_allocator), true
}

is_closing_fence :: proc(s: string, fence: string) -> bool {
	t := strings.trim_right_space(s)
	if len(t) < len(fence) { return false }
	for i in 0 ..< len(t) { if t[i] != fence[0] { return false } }
	return len(t) >= len(fence)
}

is_thematic_break :: proc(s: string) -> bool {
	t := strings.trim_space(s)
	if len(t) < 3 { return false }
	c := t[0]
	if c != '-' && c != '*' && c != '_' { return false }
	count := 0
	for i in 0 ..< len(t) {
		if t[i] == c { count += 1 } else if t[i] != ' ' { return false }
	}
	return count >= 3
}

// A list marker: "- ", "* ", "+ " or "N. " / "N) ". Returns the indent of the marker and whether it is ordered.
list_marker :: proc(line: string) -> (indent: int, ordered: bool, ok: bool) {
	indent = leading_spaces(line)
	t := strings.trim_left_space(line)
	if len(t) == 0 { return 0, false, false }
	if (t[0] == '-' || t[0] == '*' || t[0] == '+') && len(t) > 1 && t[1] == ' ' {
		return indent, false, true
	}
	i := 0
	for i < len(t) && t[i] >= '0' && t[i] <= '9' { i += 1 }
	if i > 0 && i < len(t) && (t[i] == '.' || t[i] == ')') && i + 1 < len(t) && t[i + 1] == ' ' {
		return indent, true, true
	}
	return 0, false, false
}

// The byte offset in `line` where a list item's content begins (after the marker and its space).
list_content_start :: proc(line: string) -> int {
	i := 0
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') { i += 1 }
	if i < len(line) && (line[i] == '-' || line[i] == '*' || line[i] == '+') {
		i += 1
	} else {
		for i < len(line) && line[i] >= '0' && line[i] <= '9' { i += 1 }
		if i < len(line) && (line[i] == '.' || line[i] == ')') { i += 1 }
	}
	if i < len(line) && line[i] == ' ' { i += 1 }
	return i
}

// A table delimiter row: cells of only '-', ':' and spaces, separated by '|'.
is_table_delimiter :: proc(s: string) -> bool {
	t := strings.trim_space(s)
	if !strings.contains(t, "-") { return false }
	has_cell := false
	for cell in strings.split(strings.trim(t, "|"), "|", context.temp_allocator) {
		cc := strings.trim_space(cell)
		if len(cc) == 0 { continue }
		for i in 0 ..< len(cc) {
			if cc[i] != '-' && cc[i] != ':' && cc[i] != ' ' { return false }
		}
		if strings.contains(cc, "-") { has_cell = true }
	}
	return has_cell
}

split_table_row :: proc(line: string) -> []string {
	t := strings.trim_space(line)
	t = strings.trim(t, "|")
	// split on unescaped '|'
	out := make([dynamic]string, context.allocator)
	cur := strings.builder_make(context.allocator)
	for i := 0; i < len(t); i += 1 {
		if t[i] == '\\' && i + 1 < len(t) && t[i + 1] == '|' {
			strings.write_byte(&cur, '|')
			i += 1
			continue
		}
		if t[i] == '|' {
			append(&out, strings.trim_space(strings.to_string(cur)))
			cur = strings.builder_make(context.allocator)
			continue
		}
		strings.write_byte(&cur, t[i])
	}
	append(&out, strings.trim_space(strings.to_string(cur)))
	return out[:]
}

table_aligns :: proc(delim: string) -> []string {
	cells := split_table_row(delim)
	out := make([]string, len(cells), context.allocator)
	for cell, i in cells {
		c := strings.trim_space(cell)
		left := strings.has_prefix(c, ":")
		right := strings.has_suffix(c, ":")
		switch {
		case left && right: out[i] = "center"
		case right:         out[i] = "right"
		case left:          out[i] = "left"
		case:               out[i] = ""
		}
	}
	return out
}

// A line is an HTML block if it starts with a comment or one of these block-level tags.
is_html_block_start :: proc(s: string) -> bool {
	if strings.has_prefix(s, "<!--") { return true }
	tags := [?]string{"<div", "<table", "<p", "<pre", "<ul", "<ol", "<section", "<nav", "<figure", "<details", "<sub", "<sup", "<br", "<hr", "<a ", "<a>", "<img", "<span"}
	for t in tags {
		if strings.has_prefix(strings.to_lower(s, context.temp_allocator), t) { return true }
	}
	return false
}

backtick_run :: proc(s: string, i: int) -> int {
	n := 0
	for i + n < len(s) && s[i + n] == '`' { n += 1 }
	return n
}

find_backtick_close :: proc(s: string, from: int, run: int) -> int {
	i := from
	for i < len(s) {
		if s[i] == '`' {
			r := backtick_run(s, i)
			if r == run { return i }
			i += r
			continue
		}
		i += 1
	}
	return -1
}

// Find the closing delimiter of a run of `n` bytes `c`, not immediately preceded by a space (a weak emphasis rule
// that is enough for the docs). Returns the index of the first byte of the closing run.
find_delim :: proc(s: string, from: int, c: byte, n: int) -> int {
	i := from
	for i < len(s) {
		if s[i] == '`' {
			// skip inline code so `a*b` does not close emphasis
			r := backtick_run(s, i)
			end := find_backtick_close(s, i + r, r)
			if end >= 0 { i = end + r; continue }
		}
		if s[i] == c {
			run := 0
			for i + run < len(s) && s[i + run] == c { run += 1 }
			// a '_' closer surrounded by word characters is intra-word, not a delimiter
			intra := c == '_' && i > 0 && is_alnum(s[i - 1]) && i + run < len(s) && is_alnum(s[i + run])
			if run >= n && i > from && s[i - 1] != ' ' && !intra { return i }
			i += run
			continue
		}
		i += 1
	}
	return -1
}

// Parse a link starting at '[' : returns the text, destination, title and the index past the ')'.
parse_link :: proc(s: string, start: int) -> (text, dest, title: string, next: int, ok: bool) {
	// text: balanced brackets
	depth := 0
	i := start
	for i < len(s) {
		if s[i] == '\\' { i += 2; continue }
		if s[i] == '[' { depth += 1 }
		if s[i] == ']' { depth -= 1; if depth == 0 { break } }
		i += 1
	}
	if i >= len(s) || s[i] != ']' { return "", "", "", 0, false }
	text = s[start + 1:i]
	i += 1
	if i >= len(s) || s[i] != '(' { return "", "", "", 0, false }
	i += 1
	// destination up to a space or ')'
	ds := i
	for i < len(s) && s[i] != ')' && s[i] != ' ' && s[i] != '\t' { i += 1 }
	dest = s[ds:i]
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') { i += 1 }
	// optional "title"
	if i < len(s) && (s[i] == '"' || s[i] == '\'') {
		q := s[i]
		i += 1
		ts := i
		for i < len(s) && s[i] != q { i += 1 }
		title = s[ts:i]
		if i < len(s) { i += 1 }
		for i < len(s) && (s[i] == ' ' || s[i] == '\t') { i += 1 }
	}
	if i >= len(s) || s[i] != ')' { return "", "", "", 0, false }
	return text, dest, title, i + 1, true
}

is_external :: proc(href: string) -> bool {
	return strings.has_prefix(href, "http://") || strings.has_prefix(href, "https://") || strings.has_prefix(href, "//") || strings.has_prefix(href, "mailto:")
}

is_autolink :: proc(s: string) -> bool {
	if strings.has_prefix(s, "http://") || strings.has_prefix(s, "https://") { return true }
	// a bare email
	at := strings.index_byte(s, '@')
	return at > 0 && at < len(s) - 1 && !strings.contains(s, " ")
}

is_entity :: proc(s: string, i: int) -> bool {
	// &name; or &#123; or &#xAB;
	j := i + 1
	if j < len(s) && s[j] == '#' { j += 1 }
	k := j
	for k < len(s) && k < i + 12 && s[k] != ';' && s[k] != ' ' && s[k] != '&' { k += 1 }
	return k < len(s) && s[k] == ';' && k > j
}

is_escapable :: proc(c: byte) -> bool {
	switch c {
	case '\\', '`', '*', '_', '{', '}', '[', ']', '(', ')', '#', '+', '-', '.', '!', '<', '>', '|', '"', '\'', '~': return true
	}
	return false
}

write_escaped_byte :: proc(b: ^strings.Builder, c: byte) {
	switch c {
	case '<': strings.write_string(b, "&lt;")
	case '>': strings.write_string(b, "&gt;")
	case '&': strings.write_string(b, "&amp;")
	case:     strings.write_byte(b, c)
	}
}

// Escape text for an HTML text node.
write_html_escaped :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '<': strings.write_string(b, "&lt;")
		case '>': strings.write_string(b, "&gt;")
		case '&': strings.write_string(b, "&amp;")
		case:     strings.write_byte(b, s[i])
		}
	}
}

html_escape :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	write_html_escaped(&b, s)
	return strings.to_string(b)
}

// Escape text for a double-quoted attribute value.
write_attr_escaped :: proc(b: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '<':  strings.write_string(b, "&lt;")
		case '>':  strings.write_string(b, "&gt;")
		case '&':  strings.write_string(b, "&amp;")
		case '"':  strings.write_string(b, "&quot;")
		case:      strings.write_byte(b, s[i])
		}
	}
}

attr_escape :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	write_attr_escaped(&b, s)
	return strings.to_string(b)
}

write_int :: proc(b: ^strings.Builder, n: int) {
	buf: [20]u8
	strings.write_string(b, strconv.write_int(buf[:], i64(n), 10))
}

// GitHub-style heading slug: lowercase, spaces to '-', keep letters/digits/'-'/'_', drop the rest.
slugify :: proc(s: string) -> string {
	b := strings.builder_make(context.allocator)
	for r in s {
		switch {
		case r >= 'a' && r <= 'z': strings.write_rune(&b, r)
		case r >= 'A' && r <= 'Z': strings.write_rune(&b, r + 32)
		case r >= '0' && r <= '9': strings.write_rune(&b, r)
		case r == ' ' || r == '-' || r == '_': strings.write_byte(&b, '-')
		case:
		}
	}
	out := strings.to_string(b)
	// collapse runs of '-'
	for strings.contains(out, "--") { out, _ = strings.replace_all(out, "--", "-", context.allocator) }
	out = strings.trim(out, "-")
	if out == "" { out = "section" }
	return out
}

unique_slug :: proc(ctx: ^Md_Context, base: string) -> string {
	if ctx == nil { return base }
	n := ctx.seen_ids[base]
	ctx.seen_ids[base] = n + 1
	if n == 0 { return base }
	buf: [20]u8
	return strings.concatenate({base, "-", strconv.write_int(buf[:], i64(n), 10)}, context.allocator)
}
