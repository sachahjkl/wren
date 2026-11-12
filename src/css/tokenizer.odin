// Package css: the CSS Syntax Module Level 3 (tokenizer and parser), Selectors Level 4 (parser), Media Queries Level 4
// (parser and evaluation) and the value grammar helpers (colors, lengths, numbers). It knows nothing about the DOM:
// matching selectors against documents and the cascade live in package style.
//
// Everything a stylesheet produces (rules, selectors, values, strings) is allocated from the stylesheet's own arena, so
// `stylesheet_destroy` is one call and a malicious sheet cannot leak.
package css

import "core:strconv"
import "core:strings"
import "wb:base"
import "core:unicode/utf8"

Token_Kind :: enum u8 {
	EOF,
	Ident, Function, At_Keyword, Hash, String, Bad_String, Url, Bad_Url,
	Delim, Number, Percentage, Dimension,
	Whitespace, CDO, CDC, Colon, Semicolon, Comma,
	Open_Square, Close_Square, Open_Paren, Close_Paren, Open_Curly, Close_Curly,
}

Token :: struct {
	kind:    Token_Kind,
	text:    string,    // Ident/Function/At_Keyword/Hash/String/Url name, Delim character, Dimension unit
	num:     f64,       // Number/Percentage/Dimension
	is_int:  bool,      // the number was written without fraction or exponent
	is_id:   bool,      // Hash: the text is a valid identifier (an id selector)
	has_sign: bool,     // Number: written with an explicit + or -
	unit:    Dim_Unit,  // Dimension: its unit, classified once here (fits in the padding: the token stays 40 bytes)
	pos:     u32,       // code point offset of the token in its (preprocessed) source: lets a grammar that needs the raw
	                    // representation (unicode-range) read it back
}

// The unit of a <dimension-token> among the length units, ASCII case-insensitive. Classified once when the token is read:
// every element a declaration applies to lower-cased and compared the unit text again. Unknown: not classified (a token
// made by hand: dim_unit_of reads its text); Other: a unit that is no length (s, deg, fr...).
Dim_Unit :: enum u8 {
	Unknown, Other,
	Px, Cm, Mm, Q, In, Pt, Pc,
	Em, Rem, Ex, Ch, Lh, Rlh, Cap, Ic, Rex, Rch, Ric, Rcap,
	Vw, Vh, Vi, Vb, Vmin, Vmax, Cqw, Cqh, Cqmin, Cqmax,
}

// The length unit `text` names (never Unknown).
dim_unit_of :: proc(text: string) -> Dim_Unit {
	buf: [5]u8   // (the longest length unit: vmin with a viewport prefix, cqmin, cqmax)
	if len(text) == 0 || len(text) > len(buf) { return .Other }
	for i in 0 ..< len(text) {
		c := text[i]
		if c >= 'A' && c <= 'Z' { c += 32 }
		buf[i] = c
	}
	switch string(buf[:len(text)]) {
	case "px": return .Px
	case "cm": return .Cm
	case "mm": return .Mm
	case "q": return .Q
	case "in": return .In
	case "pt": return .Pt
	case "pc": return .Pc
	case "em": return .Em
	case "rem": return .Rem
	case "ex": return .Ex
	case "ch": return .Ch
	case "lh": return .Lh
	case "rlh": return .Rlh
	case "cap": return .Cap
	case "ic": return .Ic
	case "rex": return .Rex
	case "rch": return .Rch
	case "ric": return .Ric
	case "rcap": return .Rcap
	// the viewport never has collapsing browser bars here: small, large and dynamic viewports are the same
	case "vw", "svw", "lvw", "dvw": return .Vw
	case "vh", "svh", "lvh", "dvh": return .Vh
	case "vi", "svi", "lvi", "dvi": return .Vi
	case "vb", "svb", "lvb", "dvb": return .Vb
	case "vmin", "svmin", "lvmin", "dvmin": return .Vmin
	case "vmax", "svmax", "lvmax", "dvmax": return .Vmax
	// container query units (horizontal writing: inline = width)
	case "cqw", "cqi": return .Cqw
	case "cqh", "cqb": return .Cqh
	case "cqmin": return .Cqmin
	case "cqmax": return .Cqmax
	}
	return .Other
}

@(private)
Lexer :: struct {
	src:   []rune,
	pos:   int,
	arena: Arena_Alloc,      // token texts (they live as long as the stylesheet)
	buf:   [dynamic]u8,      // the text being read (scratch, reused): a text is copied once, at its final size
}

// The token text read into l.buf, copied into the texts' arena.
@(private)
buf_text :: proc(l: ^Lexer) -> string {
	s := strings.clone(string(l.buf[:]), l.arena)
	clear(&l.buf)
	return s
}

@(private)
buf_rune :: proc(l: ^Lexer, r: rune) {
	b, n := utf8.encode_rune(r)
	append(&l.buf, ..b[:n])
}

// One-character delimiters of ASCII as slices of this table: no allocation per <delim-token>.
@(private)
delim_chars: [128]u8

@(private, init)
init_delim_chars :: proc "contextless" () { for i in 0 ..< 128 { delim_chars[i] = u8(i) } }

// Decodes and preprocesses the input: CR, CRLF and FF become LF, NUL becomes U+FFFD, invalid UTF-8 becomes U+FFFD.
@(private)
preprocess :: proc(input: string, allocator: Arena_Alloc) -> []rune {
	out := make([dynamic]rune, 0, len(input), allocator)
	i := 0
	for i < len(input) {
		c := input[i]
		if c >= ' ' && c < 0x80 { append(&out, rune(c)); i += 1; continue }
		r, w := utf8.decode_rune_in_string(input[i:])
		i += w
		switch r {
		case '\r':
			if i < len(input) && input[i] == '\n' { i += 1 }
			append(&out, '\n')
		case '\f': append(&out, '\n')
		case 0:    append(&out, '\uFFFD')
		case:      append(&out, r)
		}
	}
	return out[:]
}

@(private) peek :: #force_inline proc(l: ^Lexer, n := 0) -> rune { return l.pos + n < len(l.src) ? l.src[l.pos + n] : -1 }
@(private) is_digit :: #force_inline proc(r: rune) -> bool { return r >= '0' && r <= '9' }
@(private) is_hex :: #force_inline proc(r: rune) -> bool { return is_digit(r) || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F') }
@(private) is_ws :: #force_inline proc(r: rune) -> bool { return r == ' ' || r == '\t' || r == '\n' }
@(private) is_name_start :: #force_inline proc(r: rune) -> bool { return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || r == '_' || r >= 0x80 }
@(private) is_name_char :: #force_inline proc(r: rune) -> bool { return is_name_start(r) || is_digit(r) || r == '-' }
@(private) is_non_printable :: proc(r: rune) -> bool { return (r >= 0 && r <= 8) || r == 0x0B || (r >= 0x0E && r <= 0x1F) || r == 0x7F }

// Two code points start a valid escape: a backslash not followed by a newline.
@(private) valid_escape :: proc(a, b: rune) -> bool { return a == '\\' && b != '\n' && b != -1 }

@(private)
would_start_ident :: proc(a, b, c: rune) -> bool {
	switch {
	case a == '-': return is_name_start(b) || b == '-' || valid_escape(b, c)
	case is_name_start(a): return true
	case a == '\\': return valid_escape(a, b)
	}
	return false
}

@(private)
would_start_number :: proc(a, b, c: rune) -> bool {
	switch {
	case a == '+' || a == '-': return is_digit(b) || (b == '.' && is_digit(c))
	case a == '.': return is_digit(b)
	case is_digit(a): return true
	}
	return false
}

@(private)
consume_escape :: proc(l: ^Lexer) -> rune {
	r := peek(l)
	l.pos += 1
	if is_hex(r) {
		v := rune(base.hex_value(r))
		n := 1
		for n < 6 && is_hex(peek(l)) { v = v * 16 + rune(base.hex_value(peek(l))); l.pos += 1; n += 1 }
		if is_ws(peek(l)) { l.pos += 1 }
		if v == 0 || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF) { return '\uFFFD' }
		return v
	}
	if r == -1 { return '\uFFFD' }
	return r
}

@(private)
consume_name :: proc(l: ^Lexer) -> string {
	// most names are ASCII without escapes: their bytes straight from the code points, copied once
	start := l.pos
	for l.pos < len(l.src) && l.src[l.pos] < 0x80 && is_name_char(l.src[l.pos]) { l.pos += 1 }
	after := peek(l)
	if after < 0x80 && !valid_escape(after, peek(l, 1)) {
		text := make([]u8, l.pos - start, l.arena)
		for c, i in l.src[start:l.pos] { text[i] = u8(c) }
		return string(text)
	}
	clear(&l.buf)
	for c in l.src[start:l.pos] { append(&l.buf, u8(c)) }
	for {
		r := peek(l)
		switch {
		case is_name_char(r): buf_rune(l, r); l.pos += 1
		case valid_escape(r, peek(l, 1)): l.pos += 1; buf_rune(l, consume_escape(l))
		case: return buf_text(l)
		}
	}
}

// Returns the numeric value and whether it was an integer.
@(private)
consume_number :: proc(l: ^Lexer) -> (v: f64, is_int: bool, signed: bool) {
	start := l.pos
	is_int = true
	if peek(l) == '+' || peek(l) == '-' { l.pos += 1; signed = true }
	for is_digit(peek(l)) { l.pos += 1 }
	if peek(l) == '.' && is_digit(peek(l, 1)) {
		is_int = false
		l.pos += 1
		for is_digit(peek(l)) { l.pos += 1 }
	}
	if peek(l) == 'e' || peek(l) == 'E' {
		n1, n2 := peek(l, 1), peek(l, 2)
		if is_digit(n1) || ((n1 == '+' || n1 == '-') && is_digit(n2)) {
			is_int = false
			l.pos += 2
			for is_digit(peek(l)) { l.pos += 1 }
		}
	}
	// the characters of a number are ASCII: copied to a buffer of the stack, not built rune by rune
	buf: [64]u8
	s: string
	if l.pos - start <= len(buf) {
		for r, i in l.src[start:l.pos] { buf[i] = u8(r) }
		s = string(buf[:l.pos - start])
	} else {
		sb := strings.builder_make(context.temp_allocator)
		for r in l.src[start:l.pos] { strings.write_rune(&sb, r) }
		s = strings.to_string(sb)
	}
	if strings.has_prefix(s, "+") { s = s[1:] }
	v, _ = strconv.parse_f64(s)
	// beyond what any length, count or index can mean: an overflow (1e999 parses as an infinity) or a huge integer
	// would give infinities and NaN in later f32 arithmetic and out-of-range int() conversions (z-index:
	// 99999999999999999999 became negative); such numbers are saturated at the value `infinity` has in calc()
	if !(abs(v) <= CALC_INFINITY) { v = v < 0 ? -CALC_INFINITY : CALC_INFINITY }
	return
}

@(private)
consume_string :: proc(l: ^Lexer, ending: rune) -> Token {
	clear(&l.buf)
	for {
		r := peek(l)
		switch {
		case r == ending: l.pos += 1; return Token{kind = .String, text = buf_text(l)}
		case r == -1:     return Token{kind = .String, text = buf_text(l)}   // parse error: EOF ends the string
		case r == '\n':   return Token{kind = .Bad_String, text = buf_text(l)}   // newline is left for the next token
		case r == '\\':
			n := peek(l, 1)
			if n == -1 { l.pos += 1; continue }
			if n == '\n' { l.pos += 2; continue }   // an escaped newline continues the string
			l.pos += 1
			buf_rune(l, consume_escape(l))
		case: buf_rune(l, r); l.pos += 1
		}
	}
}

@(private)
consume_bad_url_remnants :: proc(l: ^Lexer) {
	for {
		r := peek(l)
		switch {
		case r == ')' || r == -1: if r == ')' { l.pos += 1 }; return
		case valid_escape(r, peek(l, 1)): l.pos += 1; consume_escape(l)
		case: l.pos += 1
		}
	}
}

@(private)
consume_url :: proc(l: ^Lexer) -> Token {
	for is_ws(peek(l)) { l.pos += 1 }
	clear(&l.buf)
	for {
		r := peek(l)
		switch {
		case r == ')': l.pos += 1; return Token{kind = .Url, text = buf_text(l)}
		case r == -1:  return Token{kind = .Url, text = buf_text(l)}
		case is_ws(r):
			for is_ws(peek(l)) { l.pos += 1 }
			if peek(l) == ')' || peek(l) == -1 { if peek(l) == ')' { l.pos += 1 }; return Token{kind = .Url, text = buf_text(l)} }
			consume_bad_url_remnants(l)
			return Token{kind = .Bad_Url}
		case r == '"' || r == '\'' || r == '(' || is_non_printable(r):
			consume_bad_url_remnants(l)
			return Token{kind = .Bad_Url}
		case r == '\\':
			if valid_escape(r, peek(l, 1)) { l.pos += 1; buf_rune(l, consume_escape(l)) } else { consume_bad_url_remnants(l); return Token{kind = .Bad_Url} }
		case: buf_rune(l, r); l.pos += 1
		}
	}
}

@(private)
consume_ident_like :: proc(l: ^Lexer) -> Token {
	name := consume_name(l)
	if peek(l) == '(' {
		l.pos += 1
		if base.ascii_equal_fold(name, "url") {
			// url( "..." ) is an ordinary function; only an unquoted argument makes a <url-token>
			i := 0
			for is_ws(peek(l, i)) { i += 1 }
			if peek(l, i) != '"' && peek(l, i) != '\'' { return consume_url(l) }
		}
		return Token{kind = .Function, text = name}
	}
	return Token{kind = .Ident, text = name}
}

@(private)
consume_numeric :: proc(l: ^Lexer) -> Token {
	v, is_int, signed := consume_number(l)
	if would_start_ident(peek(l), peek(l, 1), peek(l, 2)) {
		name := consume_name(l)
		return Token{kind = .Dimension, num = v, is_int = is_int, has_sign = signed, text = name, unit = dim_unit_of(name)}
	}
	if peek(l) == '%' { l.pos += 1; return Token{kind = .Percentage, num = v, is_int = is_int, has_sign = signed} }
	return Token{kind = .Number, num = v, is_int = is_int, has_sign = signed}
}

// Skips comments (an unclosed one runs to the end).
@(private)
skip_comments :: proc(l: ^Lexer) {
	for peek(l) == '/' && peek(l, 1) == '*' {
		l.pos += 2
		for l.pos < len(l.src) && !(peek(l) == '*' && peek(l, 1) == '/') { l.pos += 1 }
		l.pos = min(l.pos + 2, len(l.src))
	}
}

@(private)
next_token :: proc(l: ^Lexer) -> Token {
	r := peek(l)   // (comments were skipped by the caller: skip_comments, so that `pos` is the token's)
	switch {
	case r == -1: return Token{kind = .EOF}
	case is_ws(r):
		for is_ws(peek(l)) { l.pos += 1 }
		return Token{kind = .Whitespace}
	case r == '"' || r == '\'': l.pos += 1; return consume_string(l, r)
	case r == '#':
		if is_name_char(peek(l, 1)) || valid_escape(peek(l, 1), peek(l, 2)) {
			l.pos += 1
			is_id := would_start_ident(peek(l), peek(l, 1), peek(l, 2))
			return Token{kind = .Hash, is_id = is_id, text = consume_name(l)}
		}
		l.pos += 1
		return Token{kind = .Delim, text = "#"}
	case r == '(': l.pos += 1; return Token{kind = .Open_Paren}
	case r == ')': l.pos += 1; return Token{kind = .Close_Paren}
	case r == '[': l.pos += 1; return Token{kind = .Open_Square}
	case r == ']': l.pos += 1; return Token{kind = .Close_Square}
	case r == '{': l.pos += 1; return Token{kind = .Open_Curly}
	case r == '}': l.pos += 1; return Token{kind = .Close_Curly}
	case r == ',': l.pos += 1; return Token{kind = .Comma}
	case r == ':': l.pos += 1; return Token{kind = .Colon}
	case r == ';': l.pos += 1; return Token{kind = .Semicolon}
	case r == '+' || r == '.':
		if would_start_number(r, peek(l, 1), peek(l, 2)) { return consume_numeric(l) }
		l.pos += 1
		return Token{kind = .Delim, text = r == '+' ? "+" : "."}
	case r == '-':
		if would_start_number(r, peek(l, 1), peek(l, 2)) { return consume_numeric(l) }
		if peek(l, 1) == '-' && peek(l, 2) == '>' { l.pos += 3; return Token{kind = .CDC} }
		if would_start_ident(r, peek(l, 1), peek(l, 2)) { return consume_ident_like(l) }
		l.pos += 1
		return Token{kind = .Delim, text = "-"}
	case r == '<':
		if peek(l, 1) == '!' && peek(l, 2) == '-' && peek(l, 3) == '-' { l.pos += 4; return Token{kind = .CDO} }
		l.pos += 1
		return Token{kind = .Delim, text = "<"}
	case r == '@':
		if would_start_ident(peek(l, 1), peek(l, 2), peek(l, 3)) { l.pos += 1; return Token{kind = .At_Keyword, text = consume_name(l)} }
		l.pos += 1
		return Token{kind = .Delim, text = "@"}
	case r == '\\':
		if valid_escape(r, peek(l, 1)) { return consume_ident_like(l) }
		l.pos += 1
		return Token{kind = .Delim, text = "\\"}
	case is_digit(r): return consume_numeric(l)
	case is_name_start(r): return consume_ident_like(l)
	}
	l.pos += 1
	// a single-character delimiter: ASCII from the table, anything else copied
	if r >= 0 && r < 128 { return Token{kind = .Delim, text = string(delim_chars[int(r):int(r) + 1])} }
	clear(&l.buf)
	buf_rune(l, r)
	return Token{kind = .Delim, text = buf_text(l)}
}

// All tokens of `input` (without the trailing EOF).
tokenize :: proc(input: string, arena: Arena_Alloc) -> []Token {
	toks, _ := tokenize_with_source(input, arena, arena)
	return toks
}

// Tokens, and the preprocessed code points their `pos` fields index. The token texts go to `arena`; the token array,
// the code points and the reading buffer to `scratch` (a stylesheet drops them once it is parsed).
tokenize_with_source :: proc(input: string, arena: Arena_Alloc, scratch: Arena_Alloc) -> ([]Token, []rune) {
	l := Lexer{src = preprocess(input, scratch), arena = arena, buf = make([dynamic]u8, 0, 64, scratch)}
	// about one token per four bytes of CSS: one allocation in the common case
	out := make([dynamic]Token, 0, len(input) / 4 + 16, scratch)
	for {
		skip_comments(&l)
		start := l.pos
		t := next_token(&l)
		if t.kind == .EOF { break }
		t.pos = u32(start)
		append(&out, t)
	}
	return out[:], l.src
}
