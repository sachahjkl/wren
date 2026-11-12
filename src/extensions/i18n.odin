package extensions

// The message catalogue of an extension (`_locales/<locale>/messages.json`, chrome.i18n): the messages of the UI
// language, then those of `default_locale` behind them. A message's `$name$` is replaced by its placeholder's content,
// whose `$1`..`$9` are the substitutions of getMessage; `$$` is one '$'. Names compare without case, as in Chrome.

import "core:encoding/json"
import "core:strings"
import "wb:base"

Message :: struct {
	text:         string,
	placeholders: map[string]string,   // lower-case name -> content
}

Catalogue :: struct {
	locale:   string,                   // the locale whose messages come first ("" when none)
	messages: map[string]Message,       // lower-case name -> message, of that locale
	fallback: map[string]Message,       // of default_locale
}

// The locales to try for UI language `lang` ("en-US": en_US, en), then `default_locale`.
@(private)
locale_candidates :: proc(lang, default_locale: string) -> []string {
	out := make([dynamic]string, 0, 3, context.temp_allocator)
	l, _ := strings.replace_all(lang, "-", "_", context.temp_allocator)
	if l != "" { append(&out, l) }
	if i := strings.index_byte(l, '_'); i > 0 { append(&out, l[:i]) }
	if default_locale != "" { append(&out, default_locale) }
	return out[:]
}

// Parses one messages.json into `into` (allocator: the image's). False when it is not a JSON object of messages.
catalogue_parse :: proc(text: string, into: ^map[string]Message, allocator := context.allocator) -> bool {
	stripped := json_strip_comments(text, context.temp_allocator)
	root, err := json.parse_string(stripped, .JSON, false, context.temp_allocator)
	if err != .None { return false }
	obj, ok := root.(json.Object)
	if !ok { return false }
	for name, v in obj {
		m, mok := v.(json.Object)
		if !mok { continue }
		msg: Message
		if t, tok := m["message"].(json.String); tok { msg.text = strings.clone(t, allocator) } else { continue }
		if ph, pok := m["placeholders"].(json.Object); pok {
			msg.placeholders = make(map[string]string, len(ph), allocator)
			for pname, pv in ph {
				po, ook := pv.(json.Object)
				if !ook { continue }
				if c, cok := po["content"].(json.String); cok {
					msg.placeholders[base.ascii_lower_clone(pname, allocator)] = strings.clone(c, allocator)
				}
			}
		}
		into^[base.ascii_lower_clone(name, allocator)] = msg
	}
	return true
}

// The message `name` with `subs` ($1..$9), "" and false when neither catalogue has it. `ext_id`: for @@extension_id.
catalogue_get :: proc(c: ^Catalogue, name: string, subs: []string, ext_id := "", allocator := context.temp_allocator) -> (string, bool) {
	key := base.ascii_lower(name, context.temp_allocator)
	switch key {
	case "@@extension_id":       return strings.clone(ext_id, allocator), true
	case "@@ui_locale":          return strings.clone(c.locale != "" ? c.locale : "en", allocator), true
	case "@@bidi_dir":           return strings.clone("ltr", allocator), true
	case "@@bidi_reversed_dir":  return strings.clone("rtl", allocator), true
	case "@@bidi_start_edge":    return strings.clone("left", allocator), true
	case "@@bidi_end_edge":      return strings.clone("right", allocator), true
	}
	m, ok := c.messages[key]
	if !ok { m, ok = c.fallback[key] }
	if !ok { return "", false }
	return message_expand(m, subs, allocator), true
}

// `$name$` -> its placeholder (with $n inside replaced), `$n` -> subs[n-1] ("" past the end), `$$` -> '$'.
message_expand :: proc(m: Message, subs: []string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	expand_subs :: proc(b: ^strings.Builder, s: string, subs: []string) {
		i := 0
		for i < len(s) {
			c := s[i]
			if c == '$' && i + 1 < len(s) && s[i + 1] >= '1' && s[i + 1] <= '9' {
				n := int(s[i + 1] - '1')
				if n < len(subs) { strings.write_string(b, subs[n]) }
				i += 2
				continue
			}
			if c == '$' && i + 1 < len(s) && s[i + 1] == '$' { strings.write_byte(b, '$'); i += 2; continue }
			strings.write_byte(b, c)
			i += 1
		}
	}
	s := m.text
	i := 0
	for i < len(s) {
		if s[i] == '$' {
			if i + 1 < len(s) && s[i + 1] == '$' { strings.write_byte(&b, '$'); i += 2; continue }
			end := strings.index_byte(s[i + 1:], '$')
			if end > 0 {
				name := base.ascii_lower(s[i + 1:i + 1 + end], context.temp_allocator)
				if content, ok := m.placeholders[name]; ok {
					expand_subs(&b, content, subs)
					i += end + 2
					continue
				}
			}
			if i + 1 < len(s) && s[i + 1] >= '1' && s[i + 1] <= '9' {
				n := int(s[i + 1] - '1')
				if n < len(subs) { strings.write_string(&b, subs[n]) }
				i += 2
				continue
			}
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

// Replaces every `__MSG_name__` of a manifest text by its message, escaped for a JSON string (the manifest's strings are
// where these appear). An unknown name becomes "" as in Chrome.
manifest_localize :: proc(text: string, c: ^Catalogue, ext_id: string, allocator := context.temp_allocator) -> string {
	if !strings.contains(text, "__MSG_") { return text }
	b := strings.builder_make(allocator)
	rest := text
	for {
		i := strings.index(rest, "__MSG_")
		if i < 0 { break }
		end := strings.index(rest[i + 6:], "__")
		if end < 0 { break }
		strings.write_string(&b, rest[:i])
		name := rest[i + 6:i + 6 + end]
		msg, _ := catalogue_get(c, name, nil, ext_id)
		json_escape_into(&b, msg)
		rest = rest[i + 6 + end + 2:]
	}
	strings.write_string(&b, rest)
	return strings.to_string(b)
}

// Writes `s` escaped for the inside of a JSON string.
json_escape_into :: proc(b: ^strings.Builder, s: string) {
	HEX := "0123456789abcdef"
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':  strings.write_string(b, "\\\"")
		case '\\': strings.write_string(b, "\\\\")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case:
			if c < 0x20 {
				strings.write_string(b, "\\u00")
				strings.write_byte(b, HEX[c >> 4])
				strings.write_byte(b, HEX[c & 15])
			} else {
				strings.write_byte(b, c)
			}
		}
	}
}

// A JSON string literal of `s` (quotes included).
json_quote :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '"')
	json_escape_into(&b, s)
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

// Removes `//` and `/* */` comments outside strings (Chrome reads manifests and catalogues with them).
json_strip_comments :: proc(text: string, allocator := context.temp_allocator) -> string {
	if !strings.contains(text, "/") { return text }
	b := strings.builder_make(0, len(text), allocator)
	i := 0
	in_string := false
	for i < len(text) {
		c := text[i]
		if in_string {
			strings.write_byte(&b, c)
			if c == '\\' && i + 1 < len(text) { strings.write_byte(&b, text[i + 1]); i += 2; continue }
			if c == '"' { in_string = false }
			i += 1
			continue
		}
		if c == '"' { in_string = true; strings.write_byte(&b, c); i += 1; continue }
		if c == '/' && i + 1 < len(text) && text[i + 1] == '/' {
			for i < len(text) && text[i] != '\n' { i += 1 }
			continue
		}
		if c == '/' && i + 1 < len(text) && text[i + 1] == '*' {
			end := strings.index(text[i + 2:], "*/")
			if end < 0 { break }
			strings.write_byte(&b, ' ')
			i += end + 4
			continue
		}
		strings.write_byte(&b, c)
		i += 1
	}
	return strings.to_string(b)
}
