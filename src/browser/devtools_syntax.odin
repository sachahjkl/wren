package browser

// Syntax coloring for one line of text at a time (the Response view, the Sources of the Application tab, the console's
// input and results, the Elements tree's markup): JSON, JavaScript, CSS, HTML / XML and plain text. A line is cut into
// runs of a token class each; the classes get the colors of the palette below (made for the theme's brightness).
// Block comments and multi-line strings are only followed within a line: coloring needs no state between lines, which is
// what lets a list of 100 000 lines show any of them without reading the ones before.

import "core:strings"
import "toolkit:draw"

Syn_Lang :: enum u8 { Plain, JSON, JS, CSS, HTML }
Syn_Class :: enum u8 { Plain, Keyword, String, Number, Comment, Punct, Tag, Attr, Func, Prop, Value, Name, Atom, Error }

syn_color :: proc(c: Syn_Class) -> draw.Color {
	dark := dtc.dark
	switch c {
	case .Plain:   return dtc.text
	case .Keyword: return dark ? draw.Color{0.78, 0.55, 0.88, 1} : draw.Color{0.55, 0.20, 0.65, 1}
	case .String:  return dark ? draw.Color{0.60, 0.80, 0.48, 1} : draw.Color{0.10, 0.50, 0.15, 1}
	case .Number:  return dark ? draw.Color{0.82, 0.68, 0.45, 1} : draw.Color{0.70, 0.35, 0.00, 1}
	case .Comment: return dark ? draw.Color{0.45, 0.52, 0.45, 1} : draw.Color{0.40, 0.50, 0.40, 1}
	case .Punct:   return dark ? draw.Color{0.62, 0.64, 0.68, 1} : draw.Color{0.40, 0.42, 0.46, 1}
	case .Tag:     return dark ? draw.Color{0.92, 0.45, 0.50, 1} : draw.Color{0.70, 0.12, 0.25, 1}
	case .Attr:    return dark ? draw.Color{0.88, 0.68, 0.40, 1} : draw.Color{0.62, 0.35, 0.05, 1}
	case .Func:    return dark ? draw.Color{0.45, 0.70, 0.95, 1} : draw.Color{0.10, 0.35, 0.75, 1}
	case .Prop:    return dark ? draw.Color{0.55, 0.78, 0.92, 1} : draw.Color{0.05, 0.40, 0.65, 1}
	case .Value:   return dark ? draw.Color{0.85, 0.70, 0.50, 1} : draw.Color{0.55, 0.30, 0.10, 1}
	case .Name:    return dark ? draw.Color{0.72, 0.62, 0.90, 1} : draw.Color{0.40, 0.25, 0.70, 1}
	case .Atom:    return dark ? draw.Color{0.95, 0.60, 0.40, 1} : draw.Color{0.75, 0.30, 0.05, 1}
	case .Error:   return dtc.bad
	}
	return dtc.text
}

@(private = "file")
JS_KEYWORDS := [?]string{"async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends",
	"finally", "for", "from", "function", "if", "import", "in", "instanceof", "let", "new", "of", "return", "static", "super", "switch", "this", "throw", "try",
	"typeof", "var", "void", "while", "with", "yield"}
@(private = "file")
JS_ATOMS := [?]string{"true", "false", "null", "undefined", "NaN", "Infinity"}

@(private = "file")
is_word :: proc(c: u8) -> bool { return c == '_' || c == '$' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80 }

@(private = "file")
in_set :: proc(s: string, set: []string) -> bool {
	for w in set { if w == s { return true } }
	return false
}

// Puts a run of `class` over `line[a:b]` (merging with the previous run of the same class).
@(private = "file")
put :: proc(out: ^[dynamic]Dt_Run, line: string, a, b: int, class: Syn_Class) {
	if b <= a { return }
	append(out, Dt_Run{line[a:b], syn_color(class)})
}

// The runs of one line (temp memory). `lang` Plain: one run.
syn_runs :: proc(line: string, lang: Syn_Lang, in_comment := false) -> []Dt_Run {
	out := make([dynamic]Dt_Run, 0, 16, context.temp_allocator)
	switch lang {
	case .Plain: append(&out, Dt_Run{line, dtc.text})
	case .JSON: json_runs(&out, line)
	case .JS: js_runs(&out, line)
	case .CSS: css_runs(&out, line)
	case .HTML: html_runs(&out, line)
	}
	return out[:]
}

@(private = "file")
json_runs :: proc(out: ^[dynamic]Dt_Run, line: string) {
	i := 0
	for i < len(line) {
		c := line[i]
		switch {
		case c == '"':
			j := i + 1
			for j < len(line) && line[j] != '"' { if line[j] == '\\' { j += 1 }; j += 1 }
			j = min(j + 1, len(line))
			// a key is a string followed by a colon
			k := j
			for k < len(line) && line[k] == ' ' { k += 1 }
			put(out, line, i, j, k < len(line) && line[k] == ':' ? .Prop : .String)
			i = j
		case (c >= '0' && c <= '9') || (c == '-' && i + 1 < len(line) && line[i + 1] >= '0' && line[i + 1] <= '9'):
			j := i + 1
			for j < len(line) && ((line[j] >= '0' && line[j] <= '9') || line[j] == '.' || line[j] == 'e' || line[j] == 'E' || line[j] == '+' || line[j] == '-') { j += 1 }
			put(out, line, i, j, .Number)
			i = j
		case is_word(c):
			j := i
			for j < len(line) && is_word(line[j]) { j += 1 }
			put(out, line, i, j, in_set(line[i:j], JS_ATOMS[:]) ? .Atom : .Plain)
			i = j
		case c == '{' || c == '}' || c == '[' || c == ']' || c == ',' || c == ':':
			put(out, line, i, i + 1, .Punct)
			i += 1
		case:
			put(out, line, i, i + 1, .Plain)
			i += 1
		}
	}
}

@(private = "file")
js_runs :: proc(out: ^[dynamic]Dt_Run, line: string) {
	i := 0
	for i < len(line) {
		c := line[i]
		switch {
		case c == '/' && i + 1 < len(line) && line[i + 1] == '/':
			put(out, line, i, len(line), .Comment)
			return
		case c == '/' && i + 1 < len(line) && line[i + 1] == '*':
			end := strings.index(line[i + 2:], "*/")
			j := end < 0 ? len(line) : i + 2 + end + 2
			put(out, line, i, j, .Comment)
			i = j
		case c == '"' || c == '\'' || c == '`':
			j := i + 1
			for j < len(line) && line[j] != c { if line[j] == '\\' { j += 1 }; j += 1 }
			j = min(j + 1, len(line))
			put(out, line, i, j, .String)
			i = j
		case c >= '0' && c <= '9':
			j := i + 1
			for j < len(line) && (is_word(line[j]) || line[j] == '.') { j += 1 }
			put(out, line, i, j, .Number)
			i = j
		case is_word(c):
			j := i
			for j < len(line) && is_word(line[j]) { j += 1 }
			w := line[i:j]
			k := j
			for k < len(line) && line[k] == ' ' { k += 1 }
			switch {
			case in_set(w, JS_KEYWORDS[:]): put(out, line, i, j, .Keyword)
			case in_set(w, JS_ATOMS[:]): put(out, line, i, j, .Atom)
			case k < len(line) && line[k] == '(': put(out, line, i, j, .Func)
			case w[0] >= 'A' && w[0] <= 'Z': put(out, line, i, j, .Name)
			case: put(out, line, i, j, .Plain)
			}
			i = j
		case strings.contains_rune("{}()[];,.:<>=+-*/%&|!?^~", rune(c)):
			put(out, line, i, i + 1, .Punct)
			i += 1
		case:
			put(out, line, i, i + 1, .Plain)
			i += 1
		}
	}
}

@(private = "file")
css_runs :: proc(out: ^[dynamic]Dt_Run, line: string) {
	// a line is a selector (up to `{`), a declaration (`prop: value;`), or a brace
	i := 0
	body := false
	// declaration lines start with whitespace in formatted CSS; minified lines mix both: follow the braces
	for i < len(line) {
		c := line[i]
		switch {
		case c == '/' && i + 1 < len(line) && line[i + 1] == '*':
			end := strings.index(line[i + 2:], "*/")
			j := end < 0 ? len(line) : i + 2 + end + 2
			put(out, line, i, j, .Comment)
			i = j
		case c == '{':
			put(out, line, i, i + 1, .Punct); body = true; i += 1
		case c == '}':
			put(out, line, i, i + 1, .Punct); body = false; i += 1
		case c == '"' || c == '\'':
			j := i + 1
			for j < len(line) && line[j] != c { if line[j] == '\\' { j += 1 }; j += 1 }
			j = min(j + 1, len(line))
			put(out, line, i, j, .String)
			i = j
		case body || (strings.has_prefix(line, "  ") || strings.has_prefix(line, "\t")):
			// a property: up to the colon; then the value up to the semicolon
			j := i
			for j < len(line) && line[j] != ':' && line[j] != ';' && line[j] != '}' && line[j] != '{' && line[j] != ' ' { j += 1 }
			if j > i && j < len(line) && (line[j] == ':' || line[j] == ' ') {
				k := j
				for k < len(line) && line[k] == ' ' { k += 1 }
				if k < len(line) && line[k] == ':' {
					put(out, line, i, j, .Prop)
					put(out, line, j, k + 1, .Punct)
					i = k + 1
					// the value
					v := i
					for v < len(line) && line[v] != ';' && line[v] != '}' && line[v] != '{' { v += 1 }
					css_value(out, line, i, v)
					i = v
					continue
				}
			}
			put(out, line, i, i + 1, .Plain)
			i += 1
		case c == ';' || c == ',' || c == ':':
			put(out, line, i, i + 1, .Punct); i += 1
		case c == '@':
			j := i + 1
			for j < len(line) && (is_word(line[j]) || line[j] == '-') { j += 1 }
			put(out, line, i, j, .Keyword)
			i = j
		case c == '.' || c == '#':
			j := i + 1
			for j < len(line) && (is_word(line[j]) || line[j] == '-') { j += 1 }
			put(out, line, i, j, .Name)
			i = j
		case is_word(c):
			j := i
			for j < len(line) && (is_word(line[j]) || line[j] == '-') { j += 1 }
			put(out, line, i, j, .Tag)
			i = j
		case:
			put(out, line, i, i + 1, .Plain); i += 1
		}
	}
}

// A CSS value: numbers (with their units), colors, strings, keywords.
@(private = "file")
css_value :: proc(out: ^[dynamic]Dt_Run, line: string, a, b: int) {
	i := a
	for i < b {
		c := line[i]
		switch {
		case c == '"' || c == '\'':
			j := i + 1
			for j < b && line[j] != c { j += 1 }
			j = min(j + 1, b)
			put(out, line, i, j, .String); i = j
		case c == '#':
			j := i + 1
			for j < b && is_word(line[j]) { j += 1 }
			put(out, line, i, j, .Number); i = j
		case (c >= '0' && c <= '9') || (c == '.' && i + 1 < b && line[i + 1] >= '0' && line[i + 1] <= '9') || (c == '-' && i + 1 < b && line[i + 1] >= '0' && line[i + 1] <= '9'):
			j := i + 1
			for j < b && (is_word(line[j]) || line[j] == '.' || line[j] == '%') { j += 1 }
			put(out, line, i, j, .Number); i = j
		case is_word(c) || c == '-':
			j := i
			for j < b && (is_word(line[j]) || line[j] == '-') { j += 1 }
			put(out, line, i, j, j < b && line[j] == '(' ? .Func : .Value); i = j
		case:
			put(out, line, i, i + 1, .Punct); i += 1
		}
	}
}

@(private = "file")
html_runs :: proc(out: ^[dynamic]Dt_Run, line: string) {
	i := 0
	for i < len(line) {
		if line[i] != '<' {
			j := strings.index_byte(line[i:], '<')
			end := j < 0 ? len(line) : i + j
			put(out, line, i, end, .Plain)
			i = end
			continue
		}
		if strings.has_prefix(line[i:], "<!--") {
			e := strings.index(line[i + 4:], "-->")
			j := e < 0 ? len(line) : i + 4 + e + 3
			put(out, line, i, j, .Comment)
			i = j
			continue
		}
		// a tag
		put(out, line, i, i + 1, .Punct)
		k := i + 1
		if k < len(line) && (line[k] == '/' || line[k] == '!' || line[k] == '?') { put(out, line, k, k + 1, .Punct); k += 1 }
		s := k
		for k < len(line) && !(line[k] == ' ' || line[k] == '>' || line[k] == '/' || line[k] == '\t') { k += 1 }
		put(out, line, s, k, .Tag)
		for k < len(line) && line[k] != '>' {
			c := line[k]
			switch {
			case c == ' ' || c == '\t': put(out, line, k, k + 1, .Plain); k += 1
			case c == '/' : put(out, line, k, k + 1, .Punct); k += 1
			case c == '=': put(out, line, k, k + 1, .Punct); k += 1
			case c == '"' || c == '\'':
				j := k + 1
				for j < len(line) && line[j] != c { j += 1 }
				j = min(j + 1, len(line))
				put(out, line, k, j, .String); k = j
			case:
				j := k
				for j < len(line) && !(line[j] == ' ' || line[j] == '=' || line[j] == '>' || line[j] == '/' || line[j] == '\t') { j += 1 }
				if j == k { j = k + 1 }
				put(out, line, k, j, .Attr); k = j
			}
		}
		if k < len(line) { put(out, line, k, k + 1, .Punct); k += 1 }
		i = k
	}
}

// The language a body is in, from its MIME type (or its URL's extension).
syn_lang_of :: proc(mime, url: string) -> Syn_Lang {
	m := net_mime_base(mime)
	switch {
	case strings.has_suffix(m, "json") || strings.has_suffix(m, "+json"): return .JSON
	case strings.has_suffix(m, "javascript") || strings.has_suffix(m, "ecmascript"): return .JS
	case m == "text/css": return .CSS
	case m == "text/html" || strings.has_suffix(m, "xml") || strings.has_suffix(m, "xhtml+xml") || m == "image/svg+xml": return .HTML
	case m == "" || m == "text/plain" || m == "application/octet-stream":
		p := url
		if q := strings.index_any(p, "?#"); q >= 0 { p = p[:q] }
		switch {
		case strings.has_suffix(p, ".json"): return .JSON
		case strings.has_suffix(p, ".js") || strings.has_suffix(p, ".mjs"): return .JS
		case strings.has_suffix(p, ".css"): return .CSS
		case strings.has_suffix(p, ".html") || strings.has_suffix(p, ".htm") || strings.has_suffix(p, ".xml") || strings.has_suffix(p, ".svg"): return .HTML
		}
	}
	return .Plain
}
