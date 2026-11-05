package html

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "wb:base"

// The tokenizer of a preload scanner (HTML: "speculative HTML parsing"): what a document's bytes name, read while they arrive,
// before the parser (which takes the whole document) has them. It keeps the tokenizer's states that decide where a tag is a tag:
// comments, the text of <script>, <style>, <textarea>, <title> and the other raw text elements (a <script> inside `<!-- -->` in a
// script's text too), the inert content of <template>, foreign content. It builds no tree, and what the tree builder would make
// of a tag is not its affair: what it finds is a guess that the real elements confirm (fetch/speculative.odin).
//
// Bytes, not text: every name it looks at is ASCII, the encodings it is used for keep ASCII where it is (page/preload_scan.odin).

// A tag still open at the end of the bytes is read again when more come; one this long is no tag worth waiting for.
SCAN_MAX_TAG_BYTES :: 8 << 20
// Attributes kept of a tag.
SCAN_MAX_ATTRS :: 32
// A numeric character reference outside Unicode.
SCAN_MAX_CODE_POINT :: 0x10FFFF
// The longest name of the character references HTML knows without their `;`.
SCAN_LEGACY_NAME_MAX :: 6
// The longest byte-order mark: what the first look at a document's bytes needs.
BOM_MAX_BYTES :: 3

Scan_Attr :: struct {
	name:  string,   // lower case (temporary)
	value: string,   // character references decoded (temporary)
	bad:   bool,     // a reference this scanner does not decode: `value` is not what the attribute says
}

Scan_Tag :: struct {
	name:    string,   // lower case: base, img, link, meta, picture, script, source
	closing: bool,     // </picture>
	in_head: bool,     // before any element that belongs to the body
	attrs:   []Scan_Attr,
}

scan_attr :: proc(t: ^Scan_Tag, name: string) -> (value: string, ok: bool) {
	for &a in t.attrs { if a.name == name { return a.value, !a.bad } }
	return "", false
}

scan_has_attr :: proc(t: ^Scan_Tag, name: string) -> bool {
	for &a in t.attrs { if a.name == name { return true } }
	return false
}

@(private = "file")
Scan_State :: enum u8 { Data, Raw_Text, Script_Text, Script_Escaped, Script_Double_Escaped, Done }

Preload_Scanner :: struct {
	pos:       int,        // what was read of the bytes so far
	state:     Scan_State,
	raw_name:  string,     // Raw_Text: the element that ends it (a constant)
	scripting: bool,       // <noscript> is raw text
	template:  int,        // <template> elements open: what they hold is inert
	in_foreign: int,        // <svg> and <math> open
	in_body:   bool,
	attrs:     [dynamic]Scan_Attr,   // of the tag in hand
	arrow:     int,        // the next `-->` of an escaped script's text, once found
	no_arrow:  int,        // none before this many bytes
	on_tag:    proc(user: rawptr, t: ^Scan_Tag),
	user:      rawptr,
}

// Stops reading: what follows is left to the parser.
scan_stop :: proc(s: ^Preload_Scanner) { s.state = .Done }

scan_destroy :: proc(s: ^Preload_Scanner) { delete(s.attrs) }

@(private = "file")
is_ws :: #force_inline proc(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' }

@(private = "file")
is_letter :: #force_inline proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }

@(private = "file")
find :: proc(data: []byte, from: int, needle: string) -> int {
	i := strings.index(string(data[from:]), needle)
	return i < 0 ? -1 : from + i
}

// Whether `data[at:]` starts with `name` in any case and a character that ends a tag name follows. `incomplete`: not known yet.
@(private = "file")
name_at :: proc(data: []byte, at: int, name: string) -> (found, incomplete: bool) {
	if at + len(name) >= len(data) { return false, true }
	if !base.ascii_equal_fold(string(data[at:at + len(name)]), name) { return false, false }
	c := data[at + len(name)]
	return is_ws(c) || c == '/' || c == '>', false
}

// The end of a comment that starts with `<!--` at `at`, past its `>`; -1: not in the bytes yet.
@(private = "file")
comment_end :: proc(data: []byte, at: int) -> int {
	from := at + len("<!--")
	if from >= len(data) { return -1 }
	// (abrupt closings: `<!-->` and `<!--->`)
	if data[from] == '>' { return from + 1 }
	if from + 1 < len(data) && data[from] == '-' && data[from + 1] == '>' { return from + 2 }
	i := from
	for {
		d := find(data, i, "--")
		if d < 0 || d + 2 >= len(data) { return -1 }
		if data[d + 2] == '>' { return d + 3 }
		if data[d + 2] == '!' {
			if d + 3 >= len(data) { return -1 }
			if data[d + 3] == '>' { return d + 4 }
		}
		i = d + 1
	}
}

@(private = "file")
named_reference :: proc(name: string) -> (byte, bool) {
	switch name {
	case "amp", "AMP": return '&', true
	case "lt", "LT": return '<', true
	case "gt", "GT": return '>', true
	case "quot", "QUOT": return '"', true
	case "apos": return '\'', true
	}
	return 0, false
}

// The value of an attribute with its character references: the five of markup and the numeric ones. Another named one is not
// decoded (`ok` false) unless the rule for attributes leaves it as it stands: no `;`, and `=` or an alphanumeric after it.
@(private = "file")
decode_value :: proc(raw: string) -> (value: string, ok: bool) {
	first := strings.index_byte(raw, '&')
	if first < 0 { return raw, true }
	b := strings.builder_make(0, len(raw), context.temp_allocator)
	strings.write_string(&b, raw[:first])
	for i := first; i < len(raw); {
		c := raw[i]
		if c != '&' { strings.write_byte(&b, c); i += 1; continue }
		j := i + 1
		if j < len(raw) && raw[j] == '#' {
			j += 1
			hex := j < len(raw) && (raw[j] == 'x' || raw[j] == 'X')
			if hex { j += 1 }
			start := j
			for j < len(raw) && (hex ? is_hex(raw[j]) : (raw[j] >= '0' && raw[j] <= '9')) { j += 1 }
			if j == start { strings.write_byte(&b, '&'); i += 1; continue }
			code, parsed := strconv.parse_uint(raw[start:j], hex ? 16 : 10)
			if !parsed || code == 0 || code > SCAN_MAX_CODE_POINT { return "", false }
			enc, n := utf8.encode_rune(rune(code))
			strings.write_string(&b, string(enc[:n]))
			if j < len(raw) && raw[j] == ';' { j += 1 }
			i = j
			continue
		}
		for j < len(raw) && (is_letter(raw[j]) || (raw[j] >= '0' && raw[j] <= '9')) { j += 1 }
		name := raw[i + 1:j]
		semi := j < len(raw) && raw[j] == ';'
		if name == "" { strings.write_byte(&b, '&'); i += 1; continue }
		if semi {
			r, known := named_reference(name)
			if !known { return "", false }
			strings.write_byte(&b, r)
			i = j + 1
			continue
		}
		// no `;`: before `=` it is text (`&copy=1`), and so is an alphanumeric run longer than any such name; a run that equals one
		// is the reference, and only the markup's are decoded here
		if j < len(raw) && raw[j] == '=' { strings.write_string(&b, raw[i:j]); i = j; continue }
		if r, known := named_reference(name); known && name != "apos" { strings.write_byte(&b, r); i = j; continue }
		if len(name) > SCAN_LEGACY_NAME_MAX { strings.write_string(&b, raw[i:j]); i = j; continue }
		return "", false
	}
	return strings.to_string(b), true
}

@(private = "file")
is_hex :: #force_inline proc(c: u8) -> bool { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') }


// The tag that starts with its name at `at` (after `<` or `</`): read to its `>`. -1: not in the bytes yet.
@(private = "file")
read_tag :: proc(data: []byte, at: int, attrs: ^[dynamic]Scan_Attr) -> (name: string, self_closing: bool, end: int) {
	end = -1
	i := at
	n := len(data)
	for i < n && !is_ws(data[i]) && data[i] != '/' && data[i] != '>' { i += 1 }
	if i >= n { return }
	name = string(data[at:i])
	wanted := is_wanted(name)
	for {
		for i < n && (is_ws(data[i]) || data[i] == '/') {
			self_closing = data[i] == '/'
			i += 1
		}
		if i >= n { return }
		if data[i] == '>' { end = i + 1; return }
		self_closing = false
		// (a `=` that starts a name belongs to it)
		start := i
		i += 1
		for i < n && !is_ws(data[i]) && data[i] != '/' && data[i] != '>' && data[i] != '=' { i += 1 }
		if i >= n { return }
		attr_name := string(data[start:i])
		for i < n && is_ws(data[i]) { i += 1 }
		if i >= n { return }
		value := ""
		if data[i] == '=' {
			i += 1
			for i < n && is_ws(data[i]) { i += 1 }
			if i >= n { return }
			if q := data[i]; q == '"' || q == '\'' {
				close := strings.index_byte(string(data[i + 1:]), q)
				if close < 0 { return }
				value = string(data[i + 1:i + 1 + close])
				i += close + 2
			} else {
				vstart := i
				for i < n && !is_ws(data[i]) && data[i] != '>' { i += 1 }
				if i >= n { return }
				value = string(data[vstart:i])
			}
		}
		if wanted && len(attrs) < SCAN_MAX_ATTRS {
			lower := base.ascii_lower(attr_name, context.temp_allocator)
			dup := false
			for &a in attrs { if a.name == lower { dup = true; break } }
			if !dup {
				v, ok := decode_value(value)
				append(attrs, Scan_Attr{name = lower, value = v, bad = !ok})
			}
		}
	}
}

// The tags reported; the others are only read through.
@(private = "file")
is_wanted :: proc(name: string) -> bool {
	if len(name) > len("picture") { return false }
	switch base.ascii_lower(name, context.temp_allocator) {
	case "base", "img", "link", "meta", "picture", "script", "source": return true
	}
	return false
}

@(private = "file")
raw_text_name :: proc(s: ^Preload_Scanner, name: string) -> (string, bool) {
	switch name {
	case "style": return "style", true
	case "textarea": return "textarea", true
	case "title": return "title", true
	case "xmp": return "xmp", true
	case "iframe": return "iframe", true
	case "noembed": return "noembed", true
	case "noframes": return "noframes", true
	case "noscript": if s.scripting { return "noscript", true }
	}
	return "", false
}

@(private = "file")
is_head_element :: proc(name: string) -> bool {
	switch name {
	case "html", "head", "title", "meta", "link", "base", "script", "style", "noscript", "template": return true
	}
	return false
}

@(private = "file")
tag_seen :: proc(s: ^Preload_Scanner, name: string, closing, self_closing: bool, attrs: []Scan_Attr) {
	foreign_root := name == "svg" || name == "math"
	if s.in_foreign > 0 {
		if foreign_root { s.in_foreign += closing ? -1 : (self_closing ? 0 : 1) }
		return
	}
	switch {
	case closing:
		if name == "template" { s.template = max(s.template - 1, 0); return }
		if name == "head" { s.in_body = true }
		if name != "picture" || s.template > 0 { return }
	case foreign_root:
		if !self_closing { s.in_foreign = 1 }
		s.in_body = true
		return
	case name == "template":
		s.template += 1
		return
	case name == "script":
		s.state = .Script_Text
	case name == "plaintext":
		s.state = .Done
		return
	case:
		if raw, is_raw := raw_text_name(s, name); is_raw {
			s.state, s.raw_name = .Raw_Text, raw
		}
	}
	if name == "body" { s.in_body = true }
	if !closing && !is_head_element(name) { s.in_body = true }
	if s.template > 0 { return }
	if is_wanted(name) {
		t := Scan_Tag{name = name, closing = closing, in_head = !s.in_body, attrs = attrs}
		s.on_tag(s.user, &t)
	}
}

// Text of the raw text element `s.raw_name`: up to the `<` of its end tag, or as far as what is there can be known.
@(private = "file")
raw_text :: proc(s: ^Preload_Scanner, data: []byte) -> bool {
	for {
		lt := strings.index_byte(string(data[s.pos:]), '<')
		if lt < 0 { s.pos = len(data); return false }
		at := s.pos + lt
		if at + 1 >= len(data) { s.pos = at; return false }
		if data[at + 1] != '/' { s.pos = at + 1; continue }
		found, incomplete := name_at(data, at + 2, s.raw_name)
		if incomplete { s.pos = at; return false }
		if found { s.pos = at; s.state = .Data; return true }
		s.pos = at + 1
	}
}

// The text of a <script>, with its `<!--` and `<script>` states (HTML "script data escaped", "double escaped").
@(private = "file")
script_text :: proc(s: ^Preload_Scanner, data: []byte) -> bool {
	for {
		from := s.pos
		lt := strings.index_byte(string(data[from:]), '<')
		if s.state != .Script_Text {
			if s.arrow < from && s.no_arrow < len(data) {
				s.arrow = find(data, from, "-->")
				if s.arrow < 0 { s.no_arrow = len(data) }
			}
			if s.arrow >= from && (lt < 0 || s.arrow < from + lt) {
				s.pos = s.arrow + len("-->")
				s.state = .Script_Text
				continue
			}
		}
		if lt < 0 {
			// (`-->` may be cut at the end of the bytes)
			s.pos = max(from, len(data) - (len("-->") - 1))
			return false
		}
		at := from + lt
		if at + 1 >= len(data) { s.pos = at; return false }
		switch s.state {
		case .Script_Text, .Script_Escaped:
			if data[at + 1] == '/' {
				found, incomplete := name_at(data, at + 2, "script")
				if incomplete { s.pos = at; return false }
				if found { s.pos = at; s.state = .Data; return true }
				s.pos = at + 1
				continue
			}
			if s.state == .Script_Text {
				if at + len("<!--") > len(data) { s.pos = at; return false }
				s.pos = at + 1
				if string(data[at:at + len("<!--")]) == "<!--" { s.pos = at + len("<!"); s.state = .Script_Escaped }
				continue
			}
			found, incomplete := name_at(data, at + 1, "script")
			if incomplete { s.pos = at; return false }
			s.pos = at + 1
			if found { s.state = .Script_Double_Escaped }
		case .Script_Double_Escaped:
			if data[at + 1] == '/' {
				found, incomplete := name_at(data, at + 2, "script")
				if incomplete { s.pos = at; return false }
				if found { s.state = .Script_Escaped }
			}
			s.pos = at + 1
		case .Data, .Raw_Text, .Done:
		}
	}
}

// Reads what can be read of `data`, all the document's bytes so far: `s.pos` says how far it went, and the next call, with more,
// goes on from there. Calls `s.on_tag`, which may scan_stop.
scan_feed :: proc(s: ^Preload_Scanner, data: []byte) {
	for s.state != .Done {
		switch s.state {
		case .Raw_Text: if !raw_text(s, data) { return }
		case .Script_Text, .Script_Escaped, .Script_Double_Escaped: if !script_text(s, data) { return }
		case .Data, .Done:
		}
		lt := strings.index_byte(string(data[s.pos:]), '<')
		if lt < 0 { s.pos = len(data); return }
		at := s.pos + lt
		if at + 1 >= len(data) { s.pos = at; return }
		c := data[at + 1]
		switch {
		case c == '!':
			if at + len("<!--") > len(data) { s.pos = at; return }
			if string(data[at:at + len("<!--")]) == "<!--" {
				end := comment_end(data, at)
				if end < 0 { s.pos = at; return }
				s.pos = end
				continue
			}
			if s.in_foreign > 0 && strings.has_prefix(string(data[at:]), "<![CDATA[") {
				end := find(data, at, "]]>")
				if end < 0 { s.pos = at; return }
				s.pos = end + len("]]>")
				continue
			}
			fallthrough
		case c == '?':
			end := strings.index_byte(string(data[at:]), '>')
			if end < 0 { s.pos = at; return }
			s.pos = at + end + 1
		case c == '/' || is_letter(c):
			closing := c == '/'
			from := closing ? at + 2 : at + 1
			if closing {
				if from >= len(data) { s.pos = at; return }
				if !is_letter(data[from]) {
					if data[from] == '>' { s.pos = from + 1; continue }
					end := strings.index_byte(string(data[from:]), '>')   // (a bogus comment)
					if end < 0 { s.pos = at; return }
					s.pos = from + end + 1
					continue
				}
			}
			clear(&s.attrs)
			name, self_closing, end := read_tag(data, from, &s.attrs)
			if end < 0 {
				s.pos = at
				if len(data) - at > SCAN_MAX_TAG_BYTES { s.state = .Done }
				return
			}
			s.pos = end
			tag_seen(s, base.ascii_lower(name, context.temp_allocator), closing, self_closing, s.attrs[:])
		case:
			s.pos = at + 1
		}
	}
}
