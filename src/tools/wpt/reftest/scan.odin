// Package reftest: what the WPT runner (src/tools/wpt) needs to run reference tests, apart from the page stack: reading a
// page's links to its references and its fuzzy annotations (this file), rasterising a layout's display list to RGBA
// pixels without a GPU or a font engine (raster*.odin), comparing two pictures under WPT's rules and writing them as PNG
// (compare.odin, png.odin). It imports layout and style, never page, so that its tests run without the engine.
package reftest

import "core:strconv"
import "core:strings"

// What a page says of itself as WPT's manifest reads it (tools/manifest/sourcefile.py at the pinned commit).
Relation :: enum u8 { Match, Mismatch }

Ref_Link :: struct {
	relation: Relation,
	url:      string,   // the path on the server, resolved against the page
}

// <meta name=fuzzy content="[url:]maxDifference=a-b;totalPixels=c-d">: the differences allowed. `url` empty: for every
// reference of the page; else for that reference only.
Fuzzy :: struct {
	url:           string,
	max_difference: [2]int,
	total_pixels:  [2]int,
}

Page_Info :: struct {
	refs:     []Ref_Link,
	fuzzy:    []Fuzzy,
	paged:    bool,     // <meta name=reftest-pages>: compared page by page, in print layout
	viewport: [2]int,   // <meta name=viewport-size content=WxH>, 0: the default
}

@(private = "file")
TAG_COMMENT_OPEN :: "<!--"
@(private = "file")
TAG_COMMENT_CLOSE :: "-->"
// What makes an ASCII letter lower case.
@(private = "file")
ASCII_CASE_BIT :: 0x20
@(private = "file")
FUZZY_NAME_DIFFERENCE :: "maxDifference"
@(private = "file")
FUZZY_NAME_PIXELS :: "totalPixels"

// The elements whose content is no markup: a link written in a script or a sheet is not a link.
@(private = "file")
RAW_TEXT_TAGS := [?]string{"script", "style", "textarea", "title"}

// The tag's name in lower case without a namespace prefix ("h:link"), from `s` just after '<'; n: its length, 0 when no
// tag starts here.
@(private = "file")
tag_name :: proc(s: string) -> (name: string, n: int) {
	for n < len(s) && (s[n] == ':' || s[n] == '-' || (s[n] >= '0' && s[n] <= '9') || (s[n] | ASCII_CASE_BIT >= 'a' && s[n] | ASCII_CASE_BIT <= 'z')) { n += 1 }
	name = s[:n]
	if k := strings.last_index_byte(name, ':'); k >= 0 { name = name[k + 1:] }
	return
}

@(private = "file")
is_space :: #force_inline proc(c: byte) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' }

// One attribute of a tag from `s[i^:]`; ok = false at the end of the tag ('>' consumed, i^ past it).
@(private = "file")
next_attribute :: proc(s: string, i: ^int) -> (name, value: string, ok: bool) {
	for i^ < len(s) && (is_space(s[i^]) || s[i^] == '/') { i^ += 1 }
	if i^ >= len(s) { return }
	if s[i^] == '>' { i^ += 1; return }
	start := i^
	for i^ < len(s) && !is_space(s[i^]) && s[i^] != '=' && s[i^] != '>' && s[i^] != '/' { i^ += 1 }
	name = s[start:i^]
	for i^ < len(s) && is_space(s[i^]) { i^ += 1 }
	ok = true
	if i^ >= len(s) || s[i^] != '=' { return }
	i^ += 1
	for i^ < len(s) && is_space(s[i^]) { i^ += 1 }
	if i^ >= len(s) { return }
	if s[i^] == '"' || s[i^] == '\'' {
		q := s[i^]
		i^ += 1
		vstart := i^
		for i^ < len(s) && s[i^] != q { i^ += 1 }
		value = s[vstart:i^]
		if i^ < len(s) { i^ += 1 }
		return
	}
	vstart := i^
	for i^ < len(s) && !is_space(s[i^]) && s[i^] != '>' { i^ += 1 }
	value = s[vstart:i^]
	return
}

// A path on the server from a link in the page at `base` (a path, maybe with a query): absolute, relative or a whole
// URL; the fragment goes, a query stays, "." and ".." are resolved. In `allocator`.
resolve_path :: proc(base, href: string, allocator := context.allocator) -> string {
	h := strings.trim_space(href)
	if k := strings.index_byte(h, '#'); k >= 0 { h = h[:k] }
	if k := strings.index(h, "://"); k >= 0 {
		rest := h[k + 3:]
		s := strings.index_byte(rest, '/')
		h = s >= 0 ? rest[s:] : "/"
	} else if strings.has_prefix(h, "//") {
		s := strings.index_byte(h[2:], '/')
		h = s >= 0 ? h[2 + s:] : "/"
	}
	query := ""
	if k := strings.index_byte(h, '?'); k >= 0 { h, query = h[:k], h[k:] }
	b := base
	if k := strings.index_byte(b, '?'); k >= 0 { b = b[:k] }
	if h == "" { return strings.concatenate({b, query}, allocator) }
	full := h
	if h[0] != '/' {
		k := strings.last_index_byte(b, '/')
		full = strings.concatenate({k >= 0 ? b[:k + 1] : "/", h}, context.temp_allocator)
	}
	parts := make([dynamic]string, 0, 16, context.temp_allocator)
	for part in strings.split(full, "/", context.temp_allocator) {
		switch part {
		case "", ".":
		case "..": if len(parts) > 0 { pop(&parts) }
		case: append(&parts, part)
		}
	}
	out := strings.builder_make(allocator)
	for part in parts { strings.write_byte(&out, '/'); strings.write_string(&out, part) }
	if len(parts) == 0 || strings.has_suffix(full, "/") { strings.write_byte(&out, '/') }
	strings.write_string(&out, query)
	return strings.to_string(out)
}

// "a-b" or "a" (a range of one value), spaces allowed.
@(private = "file")
parse_range :: proc(s: string) -> (r: [2]int, ok: bool) {
	t := strings.trim_space(s)
	lo, hi := t, t
	if k := strings.index_byte(t, '-'); k >= 0 { lo, hi = t[:k], t[k + 1:] }
	a, aok := strconv.parse_int(strings.trim_space(lo), 10)
	b, bok := strconv.parse_int(strings.trim_space(hi), 10)
	if !aok || !bok || a < 0 || b < a { return {}, false }
	return {a, b}, true
}

// The content of <meta name=fuzzy> as sourcefile.py reads it: an optional "url:" (up to the last colon), then two ranges
// separated by a semicolon, named maxDifference= and totalPixels= in any order, or by position. `base`: the page, for the
// URL. ok = false: not valid (WPT's manifest refuses such a page).
parse_fuzzy :: proc(content, base: string, allocator := context.allocator) -> (f: Fuzzy, ok: bool) {
	value := content
	if k := strings.last_index_byte(content, ':'); k >= 0 {
		value = content[k + 1:]
		f.url = resolve_path(base, content[:k], allocator)
	}
	parts := strings.split(value, ";", context.temp_allocator)
	if len(parts) != 2 { return f, false }
	have_difference, have_pixels := false, false
	positional := make([dynamic][2]int, 0, 2, context.temp_allocator)
	for part in parts {
		text := part
		name := ""
		if k := strings.index_byte(part, '='); k >= 0 { name, text = strings.trim_space(part[:k]), part[k + 1:] }
		r, rok := parse_range(text)
		if !rok { return f, false }
		switch name {
		case "": append(&positional, r)
		case FUZZY_NAME_DIFFERENCE:
			if have_difference { return f, false }
			f.max_difference, have_difference = r, true
		case FUZZY_NAME_PIXELS:
			if have_pixels { return f, false }
			f.total_pixels, have_pixels = r, true
		case: return f, false
		}
	}
	next := 0
	if !have_difference { f.max_difference = positional[next]; next += 1 }
	if !have_pixels { f.total_pixels = positional[next]; next += 1 }
	return f, true
}

@(private = "file")
parse_viewport :: proc(content: string) -> (v: [2]int) {
	k := strings.index_byte(content, 'x')
	if k < 0 { return }
	w, wok := strconv.parse_int(strings.trim_space(content[:k]), 10)
	h, hok := strconv.parse_int(strings.trim_space(content[k + 1:]), 10)
	if wok && hok && w > 0 && h > 0 { v = {w, h} }
	return
}

// Reads the links and annotations of the page at `path` from its source. Comments and the content of raw text elements
// are skipped; an invalid fuzzy annotation is ignored (no test of the pinned commit has one). In `allocator`.
scan_page :: proc(text, path: string, allocator := context.allocator) -> Page_Info {
	refs := make([dynamic]Ref_Link, allocator)
	fuzzy := make([dynamic]Fuzzy, allocator)
	info: Page_Info
	i := 0
	for i < len(text) {
		k := strings.index_byte(text[i:], '<')
		if k < 0 { break }
		i += k
		if strings.has_prefix(text[i:], TAG_COMMENT_OPEN) {
			e := strings.index(text[i:], TAG_COMMENT_CLOSE)
			if e < 0 { break }
			i += e + len(TAG_COMMENT_CLOSE)
			continue
		}
		name, n := tag_name(text[i + 1:])
		if n == 0 { i += 1; continue }
		i += 1 + n
		lower := strings.to_lower(name, context.temp_allocator)
		rel, href, meta_name, content: string
		for {
			an, av, ok := next_attribute(text, &i)
			if !ok { break }
			switch strings.to_lower(an, context.temp_allocator) {
			case "rel": rel = av
			case "href": href = av
			case "name": meta_name = av
			case "content": content = av
			}
		}
		switch lower {
		case "link":
			r := strings.to_lower(strings.trim_space(rel), context.temp_allocator)
			if r == "match" { append(&refs, Ref_Link{.Match, resolve_path(path, href, allocator)}) }
			if r == "mismatch" { append(&refs, Ref_Link{.Mismatch, resolve_path(path, href, allocator)}) }
		case "meta":
			switch strings.to_lower(meta_name, context.temp_allocator) {
			case "fuzzy": if f, ok := parse_fuzzy(content, path, allocator); ok { append(&fuzzy, f) }
			case "reftest-pages": info.paged = true
			case "viewport-size": info.viewport = parse_viewport(content)
			}
		}
		for raw in RAW_TEXT_TAGS {
			if lower != raw { continue }
			closing := strings.concatenate({"</", raw}, context.temp_allocator)
			e := index_fold(text[i:], closing)
			i = e >= 0 ? i + e : len(text)
			break
		}
	}
	info.refs, info.fuzzy = refs[:], fuzzy[:]
	return info
}

// A case-insensitive index of an ASCII needle.
@(private = "file")
index_fold :: proc(s, needle: string) -> int {
	if len(needle) == 0 || len(s) < len(needle) { return -1 }
	for i in 0 ..= len(s) - len(needle) {
		if s[i] == '<' && strings.equal_fold(s[i:i + len(needle)], needle) { return i }
	}
	return -1
}

page_info_destroy :: proc(info: Page_Info, allocator := context.allocator) {
	for r in info.refs { delete(r.url, allocator) }
	for f in info.fuzzy { delete(f.url, allocator) }
	delete(info.refs, allocator)
	delete(info.fuzzy, allocator)
}

// The annotation that applies to the comparison with reference `ref`: its own, else the page's general one.
fuzzy_for :: proc(info: ^Page_Info, ref: string) -> (f: Fuzzy, ok: bool) {
	for x in info.fuzzy { if x.url == ref { return x, true } }
	for x in info.fuzzy { if x.url == "" { return x, true } }
	return {}, false
}

// A file's name without its folder, query and last extension, as sourcefile.py calls it.
@(private = "file")
base_name :: proc(path: string) -> string {
	p := path
	if k := strings.index_byte(p, '?'); k >= 0 { p = p[:k] }
	name := p[strings.last_index_byte(p, '/') + 1:]
	if k := strings.last_index_byte(name, '.'); k >= 0 { name = name[:k] }
	return name
}

// The name's type flag: what follows its last '-', up to a dot ("x-print.sub" -> "print"); "" when it has no '-'.
@(private = "file")
type_flag :: proc(name: string) -> string {
	k := strings.last_index_byte(name, '-')
	if k < 0 { return "" }
	flag := name[k + 1:]
	if d := strings.index_byte(flag, '.'); d >= 0 { flag = flag[:d] }
	return flag
}

// WPT's print reftests, which compare pages (no paged layout here), and its visual tests, compared with nothing.
is_unmeasured_name :: proc(path: string) -> bool {
	p := path
	if k := strings.index_byte(p, '?'); k >= 0 { p = p[:k] }
	if strings.contains(p, "/print/") { return true }
	flag := type_flag(base_name(p))
	return flag == "print" || flag == "visual"
}

// sourcefile.py's name_is_reference: a file in a folder named "reference", or whose name has "ref" as a word, with a
// number or a "not" ((^|[-_])(not)?ref[0-9]*([-_]|$)). Such a file is no test, whatever links it has.
is_reference_name :: proc(path: string) -> bool {
	if strings.contains(path, "/reference/") { return true }
	WORD_REF :: "ref"
	WORD_NOT :: "not"
	name := base_name(path)
	for start := 0; start <= len(name); {
		end := start
		for end < len(name) && name[end] != '-' && name[end] != '_' { end += 1 }
		word := name[start:end]
		if strings.has_prefix(word, WORD_NOT) { word = word[len(WORD_NOT):] }
		if strings.has_prefix(word, WORD_REF) {
			only_digits := true
			for c in transmute([]byte)word[len(WORD_REF):] { if c < '0' || c > '9' { only_digits = false } }
			if only_digits { return true }
		}
		start = end + 1
	}
	return false
}
