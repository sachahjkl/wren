// A small tokenizer that colours code blocks at generation time (no client-side highlighting). It knows the
// languages the docs use: Odin, C, JavaScript, PowerShell, JSON, Rust and WIDL (the API description language). It is a
// lexer, not a parser: it classifies runs of characters into comment, string, number, keyword, type and
// function-name, and wraps each in a <span> whose class matches site/docs.css (reusing .k/.s/.c/.f/.t from the main
// site's code styles). An unknown language is emitted plain (escaped), so nothing ever breaks.
package docsite

import "core:strings"

Tok_Class :: enum {
	Plain,
	Keyword,   // .k
	Str,       // .s
	Comment,   // .c
	Func,      // .f  (a directive, attribute or preprocessor line)
	Type,      // .t  (a type or a number)
	Number,    // .t too, but tracked apart for clarity
}

class_name :: proc(c: Tok_Class) -> string {
	switch c {
	case .Keyword: return "k"
	case .Str:     return "s"
	case .Comment: return "c"
	case .Func:    return "f"
	case .Type:    return "t"
	case .Number:  return "t"
	case .Plain:   return ""
	}
	return ""
}

// Emit a highlighted <pre><code> for a code block.
emit_code_block :: proc(b: ^strings.Builder, code: string, lang: string) {
	strings.write_string(b, "<div class=\"code\">")
	if lang != "" {
		strings.write_string(b, "<div class=\"file\">")
		write_html_escaped(b, lang_label(lang))
		strings.write_string(b, "</div>")
	}
	strings.write_string(b, "<pre><code>")
	src := strings.trim_right(code, "\n")
	if has_highlighter(lang) {
		highlight_into(b, src, lang)
	} else {
		write_html_escaped(b, src)
	}
	strings.write_string(b, "</code></pre></div>\n")
}

lang_label :: proc(lang: string) -> string {
	switch lang {
	case "odin":       return "Odin"
	case "c":          return "C"
	case "js", "javascript": return "JavaScript"
	case "powershell", "ps1", "pwsh": return "PowerShell"
	case "json":       return "JSON"
	case "rust", "rs": return "Rust"
	case "widl":       return "WIDL"
	case "html":       return "HTML"
	case "css":        return "CSS"
	case "bash", "sh", "shell": return "Shell"
	case "text", "":   return ""
	}
	return lang
}

has_highlighter :: proc(lang: string) -> bool {
	switch lang {
	case "odin", "c", "js", "javascript", "powershell", "ps1", "pwsh", "json", "rust", "rs", "widl": return true
	}
	return false
}

Lang_Spec :: struct {
	keywords:   map[string]bool,
	types:      map[string]bool,
	line_comment: string,
	block_open:   string,
	block_close:  string,
	sigil:        byte, // a leading-identifier sigil that marks a directive/attribute (0 for none): '#' Odin, '@' WIDL
}

highlight_into :: proc(b: ^strings.Builder, src: string, lang: string) {
	spec := lang_spec(lang)
	i := 0
	n := len(src)
	for i < n {
		c := src[i]

		// line comment
		if spec.line_comment != "" && starts(src, i, spec.line_comment) {
			end := strings.index_byte(src[i:], '\n')
			stop := end < 0 ? n : i + end
			span(b, .Comment, src[i:stop])
			i = stop
			continue
		}
		// block comment
		if spec.block_open != "" && starts(src, i, spec.block_open) {
			close := strings.index(src[i:], spec.block_close)
			stop := close < 0 ? n : i + close + len(spec.block_close)
			span(b, .Comment, src[i:stop])
			i = stop
			continue
		}
		// string / char
		if c == '"' || c == '`' || (c == '\'' && (lang == "c" || lang == "rust" || lang == "rs" || lang == "odin")) {
			stop := scan_string(src, i, c)
			span(b, .Str, src[i:stop])
			i = stop
			continue
		}
		// PowerShell variable or JSON string key colour: PowerShell '$' variables read as types
		if (lang == "powershell" || lang == "ps1" || lang == "pwsh") && c == '$' {
			j := i + 1
			for j < n && (is_ident(src[j]) || src[j] == ':') { j += 1 }
			span(b, .Type, src[i:j])
			i = j
			continue
		}
		// a sigil directive: #foreign, @spec(...)
		if spec.sigil != 0 && c == spec.sigil {
			j := i + 1
			for j < n && is_ident(src[j]) { j += 1 }
			span(b, .Func, src[i:j])
			i = j
			continue
		}
		// C/Rust preprocessor / attribute line
		if lang == "c" && c == '#' && at_line_start(src, i) {
			end := strings.index_byte(src[i:], '\n')
			stop := end < 0 ? n : i + end
			span(b, .Func, src[i:stop])
			i = stop
			continue
		}
		// number
		if is_digit(c) || (c == '.' && i + 1 < n && is_digit(src[i + 1]) && !ident_before(src, i)) {
			j := i
			for j < n && (is_hex(src[j]) || src[j] == '.' || src[j] == 'x' || src[j] == 'X' || src[j] == '_') { j += 1 }
			// a suffix like f64, u8
			for j < n && is_ident(src[j]) { j += 1 }
			span(b, .Number, src[i:j])
			i = j
			continue
		}
		// identifier / keyword / type / call
		if is_ident_start(c) {
			j := i
			for j < n && is_ident(src[j]) { j += 1 }
			word := src[i:j]
			cls := Tok_Class.Plain
			switch {
			case word in spec.keywords: cls = .Keyword
			case word in spec.types:    cls = .Type
			case is_call(src, j):       cls = .Func
			case looks_like_type(word): cls = .Type
			}
			if cls == .Plain { write_html_escaped(b, word) } else { span(b, cls, word) }
			i = j
			continue
		}
		write_escaped_byte(b, c)
		i += 1
	}
}

span :: proc(b: ^strings.Builder, cls: Tok_Class, text: string) {
	name := class_name(cls)
	if name == "" { write_html_escaped(b, text); return }
	strings.write_string(b, "<span class=\"")
	strings.write_string(b, name)
	strings.write_string(b, "\">")
	write_html_escaped(b, text)
	strings.write_string(b, "</span>")
}

// scan a quoted string beginning at `i` (quote byte `q`); returns the index past the closing quote.
scan_string :: proc(src: string, i: int, q: byte) -> int {
	j := i + 1
	raw := q == '`'
	for j < len(src) {
		if !raw && src[j] == '\\' { j += 2; continue }
		if src[j] == q { return j + 1 }
		if src[j] == '\n' && q != '`' { return j } // a runaway string ends at the line (so colour does not bleed)
		j += 1
	}
	return len(src)
}

starts :: proc(s: string, i: int, p: string) -> bool {
	return i + len(p) <= len(s) && s[i:i + len(p)] == p
}

is_ident_start :: proc(c: byte) -> bool { return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }
is_ident :: proc(c: byte) -> bool { return is_ident_start(c) || is_digit(c) }
is_digit :: proc(c: byte) -> bool { return c >= '0' && c <= '9' }
is_hex :: proc(c: byte) -> bool { return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') }

at_line_start :: proc(s: string, i: int) -> bool {
	j := i - 1
	for j >= 0 && (s[j] == ' ' || s[j] == '\t') { j -= 1 }
	return j < 0 || s[j] == '\n'
}

ident_before :: proc(s: string, i: int) -> bool {
	return i > 0 && is_ident(s[i - 1])
}

// an identifier directly followed by '(' is a call/definition name
is_call :: proc(s: string, j: int) -> bool {
	k := j
	for k < len(s) && (s[k] == ' ' || s[k] == '\t') { k += 1 }
	return k < len(s) && s[k] == '('
}

// a heuristic: a CamelCase word starting with a capital is a type
looks_like_type :: proc(word: string) -> bool {
	if len(word) < 2 { return false }
	if word[0] < 'A' || word[0] > 'Z' { return false }
	has_lower := false
	for i in 1 ..< len(word) { if word[i] >= 'a' && word[i] <= 'z' { has_lower = true } }
	return has_lower
}

lang_spec :: proc(lang: string) -> Lang_Spec {
	s: Lang_Spec
	s.keywords = make(map[string]bool, context.temp_allocator)
	s.types = make(map[string]bool, context.temp_allocator)
	add :: proc(m: ^map[string]bool, words: []string) { for w in words { m[w] = true } }
	switch lang {
	case "odin":
		s.line_comment = "//"; s.block_open = "/*"; s.block_close = "*/"; s.sigil = '#'
		add(&s.keywords, []string{"package", "import", "proc", "return", "if", "else", "for", "switch", "case", "in", "when", "defer", "using", "struct", "union", "enum", "bit_set", "map", "distinct", "foreign", "cast", "transmute", "auto_cast", "or_else", "or_return", "break", "continue", "fallthrough", "do", "dynamic", "context", "nil", "true", "false", "matrix", "bit_field"})
		add(&s.types, []string{"int", "uint", "i8", "i16", "i32", "i64", "i128", "u8", "u16", "u32", "u64", "u128", "f16", "f32", "f64", "bool", "b8", "b16", "b32", "b64", "byte", "rune", "string", "cstring", "rawptr", "uintptr", "any", "typeid", "complex64", "complex128"})
	case "c":
		s.line_comment = "//"; s.block_open = "/*"; s.block_close = "*/"
		add(&s.keywords, []string{"if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto", "sizeof", "typedef", "struct", "union", "enum", "static", "const", "extern", "inline", "volatile", "register", "restrict", "_Bool", "NULL"})
		add(&s.types, []string{"void", "char", "short", "int", "long", "float", "double", "unsigned", "signed", "size_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t", "bool"})
	case "js", "javascript":
		s.line_comment = "//"; s.block_open = "/*"; s.block_close = "*/"
		add(&s.keywords, []string{"var", "let", "const", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "new", "delete", "typeof", "instanceof", "in", "of", "class", "extends", "super", "this", "try", "catch", "finally", "throw", "async", "await", "yield", "import", "export", "from", "as", "void", "null", "undefined", "true", "false"})
		add(&s.types, []string{"Object", "Array", "String", "Number", "Boolean", "Promise", "Map", "Set", "Symbol", "JSON", "Math", "Date", "RegExp", "Error", "console", "document", "window"})
	case "powershell", "ps1", "pwsh":
		s.line_comment = "#"; s.block_open = "<#"; s.block_close = "#>"
		add(&s.keywords, []string{"if", "else", "elseif", "for", "foreach", "while", "do", "switch", "function", "return", "break", "continue", "try", "catch", "finally", "throw", "param", "begin", "process", "end", "in", "filter"})
		add(&s.types, []string{"true", "false", "null"})
	case "json":
		add(&s.keywords, []string{"true", "false", "null"})
	case "rust", "rs":
		s.line_comment = "//"; s.block_open = "/*"; s.block_close = "*/"
		add(&s.keywords, []string{"fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "for", "while", "loop", "if", "else", "match", "return", "break", "continue", "pub", "use", "mod", "crate", "self", "super", "as", "where", "move", "ref", "dyn", "async", "await", "unsafe", "extern", "type", "true", "false"})
		add(&s.types, []string{"i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64", "bool", "char", "str", "String", "Vec", "Option", "Result", "Box"})
	case "widl":
		s.line_comment = "//"; s.block_open = "/*"; s.block_close = "*/"; s.sigil = '@'
		add(&s.keywords, []string{"module", "interface", "handle", "enum", "flags", "struct", "callback", "typedef", "raises", "optional", "out", "in", "static", "Window", "Worker", "exposed"})
		add(&s.types, []string{"i32", "u32", "i64", "u64", "f32", "f64", "bool", "string", "usvstring", "bytes", "void"})
	}
	return s
}
