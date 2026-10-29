package frontend

import "core:strings"
import ucd "wb:engine/unicode"
import "wb:engine/numconv"

// The lexer, as QuickJS's next_token(): a pull lexer over a NUL-padded byte buffer, tracking the exact line and
// column bookkeeping QuickJS uses (the `mark`/`eol` pair), because those positions end up in the pc2line debug
// table and the judge compares it byte for byte. Identifiers become atoms, strings become JS strings, numbers
// become int32/float64/BigInt values, all at lex time.

CP_LS :: 0x2028
CP_PS :: 0x2029

// --- errors ---------------------------------------------------------------------------------------------------

// js_parse_error records the first syntax error (with QuickJS's column rule) and returns true for `return`.
js_parse_error :: proc(s: ^Parse_State, msg: ..string) -> bool {
	if !s.has_error {
		s.has_error = true
		col := s.token.col_num
		if s.token.ptr >= s.token.line_start {
			col = s.token.ptr - s.token.line_start + 1
		}
		s.error = make_error(strings.concatenate(msg, s.allocator), Source_Pos{offset = u32(max(s.token.ptr, 0)), line = u32(s.token.line_num), col = u32(col)})
	}
	return true
}

atom_text :: proc(s: ^Parse_State, a: Atom) -> string {
	sv := atom_to_string(s.atoms, a)
	if !sv.is_wide {return string(sv.latin1)}
	b := strings.builder_make(s.allocator)
	for u in sv.units {strings.write_rune(&b, rune(u))}
	return strings.to_string(b)
}

js_parse_expect :: proc(s: ^Parse_State, tok: int) -> bool {
	if s.token.val == tok {
		return next_token(s)
	}
	switch s.token.val {
	case TOK_EOF:
		return js_parse_error(s, "Unexpected end of input")
	case TOK_NUMBER:
		return js_parse_error(s, "Unexpected number")
	case TOK_STRING:
		return js_parse_error(s, "Unexpected string")
	case TOK_TEMPLATE:
		return js_parse_error(s, "Unexpected string template")
	case TOK_REGEXP:
		return js_parse_error(s, "Unexpected regexp")
	case TOK_IDENT:
		return js_parse_error(s, "Unexpected identifier '", atom_text(s, s.token.atom), "'")
	case TOK_ERROR:
		return js_parse_error(s, "Invalid or unexpected token")
	}
	end := max(s.buf_ptr, s.token.ptr)
	return js_parse_error(s, "Unexpected token '", string(s.buf[s.token.ptr:end]), "'")
}

js_parse_expect_semi :: proc(s: ^Parse_State) -> bool {
	if s.token.val != ';' {
		if s.token.val == TOK_EOF || s.token.val == '}' || s.got_lf {
			return false
		}
		return js_parse_error(s, "expecting ';'")
	}
	return next_token(s)
}

js_parse_error_reserved_identifier :: proc(s: ^Parse_State) -> bool {
	return js_parse_error(s, "'", atom_text(s, s.token.atom), "' is a reserved identifier")
}

token_is_pseudo_keyword :: #force_inline proc(s: ^Parse_State, atom: Atom) -> bool {
	return s.token.val == TOK_IDENT && s.token.atom == atom && !s.token.has_escape
}

// --- character classes --------------------------------------------------------------------------------------

lre_js_is_ident_first :: proc(c: u32) -> bool {
	if c < 128 {
		return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '$' || c == '_'
	}
	return ucd.is_id_start(c)
}

lre_js_is_ident_next :: proc(c: u32) -> bool {
	if c < 128 {
		return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '$' || c == '_'
	}
	return ucd.is_id_continue(c) || c == 0x200C || c == 0x200D
}

lre_is_space :: proc(c: u32) -> bool {
	if c < 256 {
		return (c >= 9 && c <= 13) || c == 0x20 || c == 0xA0
	}
	switch c {
	case 0x1680, 0x2000 ..= 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
		return true
	}
	return false
}

from_hex :: #force_inline proc(c: u8) -> int {
	switch c {
	case '0' ..= '9': return int(c - '0')
	case 'A' ..= 'F': return int(c - 'A' + 10)
	case 'a' ..= 'f': return int(c - 'a' + 10)
	}
	return -1
}

is_digit_byte :: #force_inline proc(c: u8) -> bool {return c >= '0' && c <= '9'}

// lre_parse_escape: *pp points after the '\'. Returns the char (and the new index), -1 if malformed, -2 if not
// an escape this routine handles.
lre_parse_escape :: proc(buf: []u8, p0: int, allow_utf16: int) -> (int, int) {
	p := p0
	c := u32(buf[p])
	p += 1
	switch c {
	case 'b': c = '\b'
	case 'f': c = '\f'
	case 'n': c = '\n'
	case 'r': c = '\r'
	case 't': c = '\t'
	case 'v': c = '\v'
	case 'x':
		h0 := from_hex(buf[p]); p += 1
		if h0 < 0 {return -1, p0}
		h1 := from_hex(buf[p]); p += 1
		if h1 < 0 {return -1, p0}
		c = u32(h0 << 4 | h1)
	case 'u':
		if buf[p] == '{' && allow_utf16 != 0 {
			p += 1
			c = 0
			for {
				h := from_hex(buf[p]); p += 1
				if h < 0 {return -1, p0}
				c = (c << 4) | u32(h)
				if c > 0x10FFFF {return -1, p0}
				if buf[p] == '}' {break}
			}
			p += 1
		} else {
			c = 0
			for _ in 0 ..< 4 {
				h := from_hex(buf[p]); p += 1
				if h < 0 {return -1, p0}
				c = (c << 4) | u32(h)
			}
			if c >= 0xD800 && c < 0xDC00 && allow_utf16 == 2 && buf[p] == '\\' && buf[p + 1] == 'u' {
				c1: u32 = 0
				i := 0
				for ; i < 4; i += 1 {
					h := from_hex(buf[p + 2 + i])
					if h < 0 {break}
					c1 = (c1 << 4) | u32(h)
				}
				if i == 4 && c1 >= 0xDC00 && c1 < 0xE000 {
					p += 6
					c = (((c & 0x3FF) << 10) | (c1 & 0x3FF)) + 0x10000
				}
			}
		}
	case '0' ..= '7':
		c -= '0'
		if allow_utf16 == 2 {
			if c != 0 || is_digit_byte(buf[p]) {return -1, p0}
		} else {
			v := u32(buf[p]) - '0'
			if v <= 7 {
				c = (c << 3) | v
				p += 1
				if c < 32 {
					v = u32(buf[p]) - '0'
					if v <= 7 {
						c = (c << 3) | v
						p += 1
					}
				}
			}
		}
	case:
		return -2, p0
	}
	return int(c), p
}

// --- template / string / regexp bodies ----------------------------------------------------------------------

js_parse_template_part :: proc(s: ^Parse_State, p0: int) -> bool {
	p := p0
	b: String_Buffer
	sb_init(&b, s.allocator)
	c: u32
	for {
		if p >= s.buf_end {
			return js_parse_error(s, "unexpected end of string")
		}
		c = u32(s.buf[p]); p += 1
		if c == '`' {break}
		if c == '$' && s.buf[p] == '{' {
			p += 1
			break
		}
		if c == '\\' {
			sb_putc(&b, c)
			if p >= s.buf_end {
				return js_parse_error(s, "unexpected end of string")
			}
			c = u32(s.buf[p]); p += 1
		}
		if c == '\r' {
			if s.buf[p] == '\n' {p += 1}
			c = '\n'
		}
		if c == '\n' {
			s.line_num += 1
			s.line_start = p
			s.eol = p - 1
			s.mark = p
		} else if c >= 0x80 {
			cc, p_next := utf8_decode(s.buf, p - 1)
			if p_next == p {
				return js_parse_error(s, "invalid UTF-8 sequence")
			}
			c = cc
			p = p_next
		}
		sb_putc(&b, c)
	}
	s.token.val = TOK_TEMPLATE
	s.token.sep = int(c)
	s.token.str = sb_end(&b, s.allocator)
	s.buf_ptr = p
	return false
}

// js_parse_string parses a quoted string or (sep == '`') re-cooks a template part. On success it fills token and
// returns the index after the body.
js_parse_string :: proc(s: ^Parse_State, sep: int, do_throw: bool, p0: int, token: ^JS_Token) -> (pp: int, failed: bool) {
	p := p0
	if sep != '`' {
		// fast path: printable ASCII up to the closing quote, no escape
		q := p0
		for q < s.buf_end {
			ch := s.buf[q]
			if ch < 0x20 || ch >= 0x80 || int(ch) == sep || ch == '\\' {break}
			q += 1
		}
		if q < s.buf_end && int(s.buf[q]) == sep {
			bytes := s.buf[p0:q] // (the text itself: the source buffer lives as long as the compile)
			token.val = TOK_STRING
			token.sep = sep
			token.str = String_Value{latin1 = bytes}
			return q + 1, false
		}
	}
	b: String_Buffer
	sb_init(&b, s.allocator)
	c: u32
	for {
		if p >= s.buf_end {
			if do_throw {js_parse_error(s, "unexpected end of string")}
			return p, true
		}
		c = u32(s.buf[p])
		if c < 0x20 {
			if sep == '`' {
				if c == '\r' {
					if s.buf[p + 1] == '\n' {p += 1}
					c = '\n'
				}
			} else if c == '\n' || c == '\r' {
				if do_throw {js_parse_error(s, "unexpected end of string")}
				return p, true
			}
		}
		p += 1
		if int(c) == sep {break}
		if c == '$' && s.buf[p] == '{' && sep == '`' {
			p += 1
			break
		}
		if c == '\\' {
			c = u32(s.buf[p])
			switch c {
			case 0:
				if p >= s.buf_end {
					if sep != '`' {
						if do_throw {js_parse_error(s, "unexpected end of string")}
						return p, true
					}
					if do_throw {js_parse_error(s, "Unexpected end of input")}
					return p, true
				}
				p += 1
			case '\'', '"', '\\':
				p += 1
			case '\r', '\n':
				if c == '\r' && s.buf[p + 1] == '\n' {p += 1}
				p += 1
				if sep != '`' {
					s.line_num += 1
					s.line_start = p
					s.eol = p - 1
					s.mark = p
				}
				continue
			case:
				if c == '0' && !(s.buf[p + 1] >= '0' && s.buf[p + 1] <= '9') {
					p += 1
					c = 0
				} else if (c >= '0' && c <= '9') && (s.cur_func.is_strict_mode || sep == '`') {
					if do_throw {
						js_parse_error(s, c >= '8' ? "\\8 and \\9" : "Octal escape sequences", " are not allowed in ", sep == '`' ? "template strings" : "strict mode")
					}
					return p, true
				} else if c >= 0x80 {
					cc, p_next := utf8_decode(s.buf, p)
					if p_next == p + 1 {
						if do_throw {js_parse_error(s, "invalid UTF-8 sequence")}
						return p, true
					}
					p = p_next
					c = cc
					if c == CP_LS || c == CP_PS {continue}
				} else {
					ret, np := lre_parse_escape(s.buf, p, 1)
					if ret == -1 {
						if do_throw {
							js_parse_error(s, "Invalid ", c == 'u' ? "Unicode" : "hexadecimal", " escape sequence")
						}
						return p, true
					} else if ret < 0 {
						p += 1
					} else {
						c = u32(ret)
						p = np
					}
				}
			}
		} else if c >= 0x80 {
			cc, p_next := utf8_decode(s.buf, p - 1)
			if p_next == p {
				if do_throw {js_parse_error(s, "invalid UTF-8 sequence")}
				return p, true
			}
			p = p_next
			c = cc
		}
		sb_putc(&b, c)
	}
	token.val = TOK_STRING
	token.sep = int(c)
	token.str = sb_end(&b, s.allocator)
	return p, false
}

js_parse_regexp :: proc(s: ^Parse_State) -> bool {
	p := s.buf_ptr
	p += 1
	in_class := false
	b, b2: String_Buffer
	sb_init(&b, s.allocator)
	sb_init(&b2, s.allocator)
	for {
		if p >= s.buf_end {
			return js_parse_error(s, "unexpected end of regexp")
		}
		c := u32(s.buf[p]); p += 1
		if c == '\n' || c == '\r' {
			return js_parse_error(s, "unexpected line terminator in regexp")
		} else if c == '/' {
			if !in_class {break}
		} else if c == '[' {
			in_class = true
		} else if c == ']' {
			in_class = false
		} else if c == '\\' {
			sb_putc(&b, c)
			c = u32(s.buf[p]); p += 1
			if c == '\n' || c == '\r' {
				return js_parse_error(s, "unexpected line terminator in regexp")
			} else if c == 0 && p >= s.buf_end {
				return js_parse_error(s, "unexpected end of regexp")
			} else if c >= 0x80 {
				cc, p_next := utf8_decode(s.buf, p - 1)
				if p_next == p {
					return js_parse_error(s, "invalid UTF-8 sequence")
				}
				p = p_next
				c = cc
				if c == CP_LS || c == CP_PS {
					return js_parse_error(s, "unexpected line terminator in regexp")
				}
			}
		} else if c >= 0x80 {
			cc, p_next := utf8_decode(s.buf, p - 1)
			if p_next == p {
				return js_parse_error(s, "invalid UTF-8 sequence")
			}
			p = p_next
			c = cc
			if c == CP_LS || c == CP_PS {
				return js_parse_error(s, "unexpected line terminator in regexp")
			}
		}
		sb_putc(&b, c)
	}
	for {
		c, p_next := utf8_decode(s.buf, p)
		if !lre_js_is_ident_next(c) {break}
		sb_putc(&b2, c)
		p = p_next
	}
	s.token.val = TOK_REGEXP
	s.token.re_body = sb_end(&b, s.allocator)
	s.token.re_flags = sb_end(&b2, s.allocator)
	s.buf_ptr = p
	return false
}

// --- identifiers --------------------------------------------------------------------------------------------

update_token_ident :: proc(s: ^Parse_State) {
	a := s.token.atom
	if a == A_using {return}
	fd := s.cur_func
	if a <= JS_ATOM_LAST_KEYWORD ||
	   (a <= JS_ATOM_LAST_STRICT_KEYWORD && fd.is_strict_mode) ||
	   (a == A_yield &&
			   (func_kind_is_generator(fd.func_kind) ||
					   (fd.func_type == .arrow && !fd.in_function_body && fd.parent != nil && func_kind_is_generator(fd.parent.func_kind)))) ||
	   (a == A_await &&
			   (s.is_module ||
					   func_kind_is_async(fd.func_kind) ||
					   fd.func_type == .class_static_init ||
					   (fd.func_type == .arrow && !fd.in_function_body && fd.parent != nil &&
							   (func_kind_is_async(fd.parent.func_kind) || fd.parent.func_type == .class_static_init)))) {
		if s.token.has_escape {
			s.token.is_reserved = true
			s.token.val = TOK_IDENT
		} else {
			s.token.val = int(a) - 1 + TOK_FIRST_KEYWORD
		}
	}
}

reparse_ident_token :: proc(s: ^Parse_State) {
	if s.token.val == TOK_IDENT || (s.token.val >= TOK_FIRST_KEYWORD && s.token.val <= TOK_LAST_KEYWORD) {
		s.token.val = TOK_IDENT
		s.token.is_reserved = false
		update_token_ident(s)
	}
}

@(private = "file")
is_ascii_ident_next :: #force_inline proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '$'
}

// parse_ident: c is the first code point (already consumed); returns the atom and the index after the name.
parse_ident :: proc(s: ^Parse_State, p0: int, has_escape: ^bool, c0: u32, is_private: bool) -> (Atom, int) {
	p := p0
	if c0 < 0x80 && s.buf[p0 - 1] == u8(c0) && !has_escape^ {
		// fast path: a plain ASCII name (first character not escaped) is interned straight from the source
		start := is_private ? p0 - 2 : p0 - 1
		q := p0
		for is_ascii_ident_next(s.buf[q]) {q += 1}
		if s.buf[q] != '\\' && s.buf[q] < 0x80 {
			return atom_from_latin1(s.atoms, s.buf[start:q]), q
		}
	}
	b: String_Buffer
	sb_init(&b, s.allocator)
	if is_private {sb_putc(&b, '#')}
	c := c0
	for {
		sb_putc(&b, c)
		c = u32(s.buf[p])
		p_next := p + 1
		if c == '\\' && s.buf[p_next] == 'u' {
			r, np := lre_parse_escape(s.buf, p_next, 1)
			c = u32(i32(r))
			if r >= 0 {p_next = np}
			has_escape^ = true
		} else if c >= 0x80 {
			c, p_next = utf8_decode(s.buf, p)
		}
		if i32(c) < 0 || !lre_js_is_ident_next(c) {break}
		p = p_next
	}
	return atom_from_string(s.atoms, sb_end(&b, s.allocator)), p
}

// --- numbers (js_atof with the lexer's flags) ---------------------------------------------------------------

@(private = "file")
to_digit :: #force_inline proc(c: u8) -> int {
	switch c {
	case '0' ..= '9': return int(c - '0')
	case 'A' ..= 'Z': return int(c - 'A' + 10)
	case 'a' ..= 'z': return int(c - 'a' + 10)
	}
	return 36
}

// js_atof_lex: parse a numeric literal at p (ATOD_ACCEPT_BIN_OCT | LEGACY_OCTAL | UNDERSCORES | SUFFIX).
// Returns the value (nil for the NaN "invalid" result) and the index after the literal.
js_atof_lex :: proc(s: ^Parse_State, p0: int) -> (JS_Value, int) {
	buf := s.buf
	p := p0
	sep := 256
	sep = '_'
	has_legacy_octal := false
	radix := 0
	if buf[p] == '0' {
		c1 := buf[p + 1]
		if c1 == 'x' || c1 == 'X' {
			p += 2; radix = 16
		} else if c1 == 'o' || c1 == 'O' {
			p += 2; radix = 8
		} else if c1 == 'b' || c1 == 'B' {
			p += 2; radix = 2
		} else if c1 >= '0' && c1 <= '9' {
			has_legacy_octal = true
			sep = 256
			i := 1
			for buf[p + i] >= '0' && buf[p + i] <= '7' {i += 1}
			if buf[p + i] == '8' || buf[p + i] == '9' {
				radix = 0
			} else {
				p += 1
				radix = 8
			}
		}
		if radix != 0 && !(has_legacy_octal && radix == 0) {
			if to_digit(buf[p]) >= radix {return nil, p}
		}
	}
	if radix == 0 {radix = 10}
	is_float := false
	p_start := p
	is_sep :: #force_inline proc(c: u8, sep: int) -> bool {return int(c) == sep}
	for to_digit(buf[p]) < radix ||
	    (is_sep(buf[p], sep) && (radix != 10 || p != p_start + 1 || buf[p - 1] != '0') && to_digit(buf[p + 1]) < radix) {
		p += 1
	}
	if radix == 10 {
		if buf[p] == '.' && (p > p_start || to_digit(buf[p + 1]) < radix) {
			is_float = true
			p += 1
			if is_sep(buf[p], sep) {return nil, p}
			for to_digit(buf[p]) < radix || (is_sep(buf[p], sep) && to_digit(buf[p + 1]) < radix) {p += 1}
		}
		if p > p_start && (buf[p] == 'e' || buf[p] == 'E') {
			p1 := p + 1
			is_float = true
			if buf[p1] == '+' || buf[p1] == '-' {p1 += 1}
			if is_digit_byte(buf[p1]) {
				p = p1 + 1
				for is_digit_byte(buf[p]) || (is_sep(buf[p], sep) && is_digit_byte(buf[p + 1])) {p += 1}
			}
		}
	}
	if p == p_start {return nil, p}
	if !is_float && buf[p] != 'n' && p - p_start <= 15 && (radix == 10 || radix == 16 && p - p_start <= 13) {
		// fast path: a short integer is exact in a double, no conversion routine needed
		v: u64 = 0
		plain := true
		for i in p_start ..< p {
			d := to_digit(buf[i])
			if d >= radix {plain = false; break}
			v = v * u64(radix) + u64(d)
		}
		if plain {return js_number(f64(v)), p}
	}
	clean := make([dynamic]u8, 0, p - p_start, s.allocator)
	for i in p_start ..< p {
		if buf[i] != '_' {append(&clean, buf[i])}
	}
	if buf[p] == 'n' {
		p += 1
		if has_legacy_octal || is_float {return nil, p}
		return bigint_from_digits(s, clean[:], radix), p
	}
	flags: numconv.Atod_Flags
	if !is_float {flags = {.Int_Only}}
	d, _, _ := numconv.atod(string(clean[:]), radix, flags)
	return js_number(d), p
}

// bigint_from_digits builds a normalized two's-complement limb array (js_bigint_from_string + normalize).
bigint_from_digits :: proc(s: ^Parse_State, digits: []u8, radix: int) -> JS_Value {
	limbs := make([dynamic]u32, 0, 4, s.allocator)
	append(&limbs, 0)
	for ch in digits {
		d := u64(to_digit(ch))
		carry := d
		for i in 0 ..< len(limbs) {
			x := u64(limbs[i]) * u64(radix) + carry
			limbs[i] = u32(x)
			carry = x >> 32
		}
		if carry != 0 {append(&limbs, u32(carry))}
	}
	// positive value: keep a zero limb if the top bit is set, drop redundant zero limbs otherwise
	for len(limbs) > 1 && limbs[len(limbs) - 1] == 0 && (limbs[len(limbs) - 2] & 0x8000_0000) == 0 {
		pop(&limbs)
	}
	if (limbs[len(limbs) - 1] & 0x8000_0000) != 0 {append(&limbs, 0)}
	return Big_Int{limbs = limbs[:]}
}

// --- next_token ---------------------------------------------------------------------------------------------

next_token :: proc(s: ^Parse_State) -> bool {
	buf := s.buf
	p := s.buf_ptr
	s.last_ptr = p
	s.got_lf = false
	s.last_line_num = s.token.line_num
	s.last_col_num = s.token.col_num
	ident_has_escape := false
	c: u32
	redo: for {
		s.token.line_num = s.line_num
		s.token.col_num = s.col_num
		s.token.ptr = p
		s.token.line_start = s.line_start
		c = u32(buf[p])
		switch c {
		case 0:
			if p >= s.buf_end {
				s.token.val = TOK_EOF
			} else {
				s.token.val = int(c); p += 1
			}
			break redo
		case '`':
			if js_parse_template_part(s, p + 1) {s.token.val = TOK_ERROR; return true}
			p = s.buf_ptr
			break redo
		case '\'', '"':
			np, failed := js_parse_string(s, int(c), true, p + 1, &s.token)
			if failed {s.token.val = TOK_ERROR; return true}
			p = np
			break redo
		case '\r', '\n':
			if c == '\r' && buf[p + 1] == '\n' {p += 1}
			p += 1
			s.line_start = p
			s.eol = p - 1
			s.mark = p
			s.got_lf = true
			s.line_num += 1
			continue redo
		case '\f', '\v', ' ', '\t':
			p += 1
			s.mark = p
			continue redo
		case '/':
			if buf[p + 1] == '*' {
				p += 2
				for {
					if buf[p] == 0 && p >= s.buf_end {
						js_parse_error(s, "unexpected end of comment")
						s.token.val = TOK_ERROR
						return true
					}
					if buf[p] == '*' && buf[p + 1] == '/' {
						p += 2
						break
					}
					if buf[p] == '\n' {
						s.line_num += 1
						s.got_lf = true
						s.eol = p
						p += 1
						s.line_start = p
						s.mark = p
					} else if buf[p] == '\r' {
						s.got_lf = true
						p += 1
						s.line_start = p
					} else if buf[p] >= 0x80 {
						cc, np := utf8_decode(buf, p)
						p = np
						if cc == CP_LS || cc == CP_PS {s.got_lf = true}
					} else {
						p += 1
					}
				}
				s.mark = p
				continue redo
			} else if buf[p + 1] == '/' {
				p += 2
				p = skip_line_comment(s, p)
				continue redo
			} else if buf[p + 1] == '=' {
				p += 2
				s.token.val = TOK_DIV_ASSIGN
			} else {
				p += 1
				s.token.val = int(c)
			}
			break redo
		case '\\':
			if buf[p + 1] == 'u' {
				c1, p1 := lre_parse_escape(buf, p + 1, 1)
				if c1 >= 0 && lre_js_is_ident_first(u32(c1)) {
					c = u32(c1)
					p = p1
					ident_has_escape = true
					if do_ident(s, &p, &ident_has_escape, c) {s.token.val = TOK_ERROR; return true}
					break redo
				}
			}
			s.token.val = int(c); p += 1
			break redo
		case 'a' ..= 'z', 'A' ..= 'Z', '_', '$':
			s.mark = p
			p += 1
			ident_has_escape = false
			if do_ident(s, &p, &ident_has_escape, c) {s.token.val = TOK_ERROR; return true}
			break redo
		case '#':
			p += 1
			c = u32(buf[p])
			p_next := p + 1
			if c == '\\' && buf[p_next] == 'u' {
				r, np := lre_parse_escape(buf, p_next, 1)
				c = u32(i32(r))
				if r >= 0 {p_next = np}
			} else if c >= 0x80 {
				c, p_next = utf8_decode(buf, p)
				if p_next == p + 1 {
					js_parse_error(s, "invalid UTF-8 sequence")
					s.token.val = TOK_ERROR
					return true
				}
			}
			if i32(c) < 0 || !lre_js_is_ident_first(c) {
				js_parse_error(s, "invalid first character of private name")
				s.token.val = TOK_ERROR
				return true
			}
			p = p_next
			esc := false
			atom: Atom
			atom, p = parse_ident(s, p, &esc, c, true)
			s.token.atom = atom
			s.token.val = TOK_PRIVATE_NAME
			break redo
		case '.':
			if buf[p + 1] == '.' && buf[p + 2] == '.' {
				p += 3
				s.token.val = TOK_ELLIPSIS
				break redo
			}
			if buf[p + 1] >= '0' && buf[p + 1] <= '9' {
				if parse_number(s, &p) {s.token.val = TOK_ERROR; return true}
				break redo
			}
			s.token.val = int(c); p += 1
			break redo
		case '0':
			if is_digit_byte(buf[p + 1]) && s.cur_func.is_strict_mode {
				js_parse_error(s, "Octal literals are not allowed in strict mode")
				s.token.val = TOK_ERROR
				return true
			}
			if parse_number(s, &p) {s.token.val = TOK_ERROR; return true}
			break redo
		case '1' ..= '9':
			if parse_number(s, &p) {s.token.val = TOK_ERROR; return true}
			break redo
		case '*':
			if buf[p + 1] == '=' {
				p += 2; s.token.val = TOK_MUL_ASSIGN
			} else if buf[p + 1] == '*' {
				if buf[p + 2] == '=' {
					p += 3; s.token.val = TOK_POW_ASSIGN
				} else {
					p += 2; s.token.val = TOK_POW
				}
			} else {
				s.token.val = int(c); p += 1
			}
			break redo
		case '%':
			if buf[p + 1] == '=' {
				p += 2; s.token.val = TOK_MOD_ASSIGN
			} else {
				s.token.val = int(c); p += 1
			}
			break redo
		case '+':
			if buf[p + 1] == '=' {
				p += 2; s.token.val = TOK_PLUS_ASSIGN
			} else if buf[p + 1] == '+' {
				p += 2; s.token.val = TOK_INC
			} else {
				s.token.val = int(c); p += 1
			}
			break redo
		case '-':
			if buf[p + 1] == '=' {
				p += 2; s.token.val = TOK_MINUS_ASSIGN
			} else if buf[p + 1] == '-' {
				if s.allow_html_comments && buf[p + 2] == '>' && (s.got_lf || s.last_ptr == s.buf_start) {
					p = skip_line_comment(s, p)
					continue redo
				}
				p += 2; s.token.val = TOK_DEC
			} else {
				s.token.val = int(c); p += 1
			}
			break redo
		case '<':
			if buf[p + 1] == '=' {
				p += 2; s.token.val = TOK_LTE
			} else if buf[p + 1] == '<' {
				if buf[p + 2] == '=' {
					p += 3; s.token.val = TOK_SHL_ASSIGN
				} else {
					p += 2; s.token.val = TOK_SHL
				}
			} else if s.allow_html_comments && buf[p + 1] == '!' && buf[p + 2] == '-' && buf[p + 3] == '-' {
				p = skip_line_comment(s, p)
				continue redo
			} else {
				s.token.val = int(c); p += 1
			}
			break redo
		case '>':
			if buf[p + 1] == '=' {
				p += 2; s.token.val = TOK_GTE
			} else if buf[p + 1] == '>' {
				if buf[p + 2] == '>' {
					if buf[p + 3] == '=' {
						p += 4; s.token.val = TOK_SHR_ASSIGN
					} else {
						p += 3; s.token.val = TOK_SHR
					}
				} else if buf[p + 2] == '=' {
					p += 3; s.token.val = TOK_SAR_ASSIGN
				} else {
					p += 2; s.token.val = TOK_SAR
				}
			} else {
				s.token.val = int(c); p += 1
			}
			break redo
		case '=':
			if buf[p + 1] == '=' {
				if buf[p + 2] == '=' {
					p += 3; s.token.val = TOK_STRICT_EQ
				} else {
					p += 2; s.token.val = TOK_EQ
				}
			} else if buf[p + 1] == '>' {
				p += 2; s.token.val = TOK_ARROW
			} else {
				s.token.val = int(c); p += 1
			}
			break redo
		case '!':
			if buf[p + 1] == '=' {
				if buf[p + 2] == '=' {
					p += 3; s.token.val = TOK_STRICT_NEQ
				} else {
					p += 2; s.token.val = TOK_NEQ
				}
			} else {
				s.token.val = int(c); p += 1
			}
			break redo
		case '&':
			if buf[p + 1] == '=' {
				p += 2; s.token.val = TOK_AND_ASSIGN
			} else if buf[p + 1] == '&' {
				if buf[p + 2] == '=' {
					p += 3; s.token.val = TOK_LAND_ASSIGN
				} else {
					p += 2; s.token.val = TOK_LAND
				}
			} else {
				s.token.val = int(c); p += 1
			}
			break redo
		case '^':
			if buf[p + 1] == '=' {
				p += 2; s.token.val = TOK_XOR_ASSIGN
			} else {
				s.token.val = int(c); p += 1
			}
			break redo
		case '|':
			if buf[p + 1] == '=' {
				p += 2; s.token.val = TOK_OR_ASSIGN
			} else if buf[p + 1] == '|' {
				if buf[p + 2] == '=' {
					p += 3; s.token.val = TOK_LOR_ASSIGN
				} else {
					p += 2; s.token.val = TOK_LOR
				}
			} else {
				s.token.val = int(c); p += 1
			}
			break redo
		case '?':
			if buf[p + 1] == '?' {
				if buf[p + 2] == '=' {
					p += 3; s.token.val = TOK_DOUBLE_QUESTION_MARK_ASSIGN
				} else {
					p += 2; s.token.val = TOK_DOUBLE_QUESTION_MARK
				}
			} else if buf[p + 1] == '.' && !(buf[p + 2] >= '0' && buf[p + 2] <= '9') {
				p += 2; s.token.val = TOK_QUESTION_MARK_DOT
			} else {
				s.token.val = int(c); p += 1
			}
			break redo
		case:
			if c >= 0x80 {
				cc, p_next := utf8_decode(buf, p)
				if p_next == p + 1 {
					js_parse_error(s, "invalid UTF-8 sequence")
					s.token.val = TOK_ERROR
					return true
				}
				p = p_next
				c = cc
				if c == CP_PS || c == CP_LS {
					s.line_start = p
					s.eol = p - 1
					s.mark = p
					s.got_lf = true
					s.line_num += 1
					continue redo
				}
				if lre_is_space(c) {
					s.mark = p
					continue redo
				} else if lre_js_is_ident_first(c) {
					ident_has_escape = false
					if do_ident(s, &p, &ident_has_escape, c) {s.token.val = TOK_ERROR; return true}
					break redo
				} else {
					js_parse_error(s, "unexpected character")
					s.token.val = TOK_ERROR
					return true
				}
			}
			s.token.val = int(c); p += 1
			break redo
		}
	}
	s.token.col_num = max(1, s.mark - s.eol)
	s.buf_ptr = p
	return false
}

@(private = "file")
skip_line_comment :: proc(s: ^Parse_State, p0: int) -> int {
	p := p0
	for {
		if s.buf[p] == 0 && p >= s.buf_end {break}
		if s.buf[p] == '\r' || s.buf[p] == '\n' {break}
		if s.buf[p] >= 0x80 {
			// the C decodes (and consumes) the separator before testing it
			cc, np := utf8_decode(s.buf, p)
			p = np
			if cc == CP_LS || cc == CP_PS {break}
		} else {
			p += 1
		}
	}
	s.mark = p
	return p
}

@(private = "file")
do_ident :: proc(s: ^Parse_State, pp: ^int, has_escape: ^bool, c: u32) -> bool {
	atom, np := parse_ident(s, pp^, has_escape, c, false)
	pp^ = np
	s.token.atom = atom
	s.token.has_escape = has_escape^
	s.token.is_reserved = false
	s.token.val = TOK_IDENT
	update_token_ident(s)
	return false
}

@(private = "file")
parse_number :: proc(s: ^Parse_State, pp: ^int) -> bool {
	val, p := js_atof_lex(s, pp^)
	pp^ = p
	is_nan := val == nil
	if !is_nan {
		if f, ok := val.(f64); ok && f != f {is_nan = true}
	}
	c, _ := utf8_decode(s.buf, p)
	if is_nan || lre_js_is_ident_next(c) {
		s.col_num = max(1, s.mark - s.eol)
		return js_parse_error(s, "invalid number literal")
	}
	s.token.val = TOK_NUMBER
	s.token.num = val
	return false
}

// simple_next_token: the cheap look-ahead used for ':', '=>', 'in', 'of', 'function', 'import'/'export'.
simple_next_token :: proc(buf: []u8, pp: ^int, no_line_terminator: bool) -> int {
	p := pp^
	for {
		c := u32(buf[p]); p += 1
		switch c {
		case '\r', '\n':
			if no_line_terminator {return '\n'}
			continue
		case ' ', '\t', '\v', '\f':
			continue
		case '/':
			if buf[p] == '/' {
				if no_line_terminator {return '\n'}
				for buf[p] != 0 && buf[p] != '\r' && buf[p] != '\n' {p += 1}
				continue
			}
			if buf[p] == '*' {
				for {
					p += 1
					if buf[p] == 0 {break}
					if (buf[p] == '\r' || buf[p] == '\n') && no_line_terminator {return '\n'}
					if buf[p] == '*' && buf[p + 1] == '/' {
						p += 2
						break
					}
				}
				continue
			}
		case '=':
			if buf[p] == '>' {return TOK_ARROW}
		case:
			if lre_js_is_ident_first(c) {
				nx :: #force_inline proc(b: u8) -> bool {return lre_js_is_ident_next(u32(b))}
				if c == 'i' {
					if buf[p] == 'n' && !nx(buf[p + 1]) {return TOK_IN}
					if buf[p] == 'm' && buf[p + 1] == 'p' && buf[p + 2] == 'o' && buf[p + 3] == 'r' && buf[p + 4] == 't' && !nx(buf[p + 5]) {
						pp^ = p + 5
						return TOK_IMPORT
					}
				} else if c == 'o' && buf[p] == 'f' && !nx(buf[p + 1]) {
					return TOK_OF
				} else if c == 'e' && buf[p] == 'x' && buf[p + 1] == 'p' && buf[p + 2] == 'o' && buf[p + 3] == 'r' && buf[p + 4] == 't' && !nx(buf[p + 5]) {
					pp^ = p + 5
					return TOK_EXPORT
				} else if c == 'f' && buf[p] == 'u' && buf[p + 1] == 'n' && buf[p + 2] == 'c' && buf[p + 3] == 't' && buf[p + 4] == 'i' && buf[p + 5] == 'o' && buf[p + 6] == 'n' && !nx(buf[p + 7]) {
					return TOK_FUNCTION
				} else if c == 'a' && buf[p] == 'w' && buf[p + 1] == 'a' && buf[p + 2] == 'i' && buf[p + 3] == 't' && !nx(buf[p + 4]) {
					return TOK_AWAIT
				} else if c == 'u' && buf[p] == 's' && buf[p + 1] == 'i' && buf[p + 2] == 'n' && buf[p + 3] == 'g' && !nx(buf[p + 4]) {
					return TOK_USING
				}
				return TOK_IDENT
			}
		}
		return int(c)
	}
}

peek_token :: proc(s: ^Parse_State, no_line_terminator: bool) -> int {
	p := s.buf_ptr
	return simple_next_token(s.buf, &p, no_line_terminator)
}

// --- saved positions (JSParsePos) -----------------------------------------------------------------------------

Parse_Pos :: struct {
	last_line_num, last_col_num, line_num, col_num: int,
	got_lf:                                         bool,
	ptr, line_start, eol, mark:                     int,
}

js_parse_get_pos :: proc(s: ^Parse_State) -> Parse_Pos {
	return Parse_Pos{
		last_line_num = s.last_line_num,
		last_col_num = s.last_col_num,
		line_num = s.token.line_num,
		col_num = s.token.col_num,
		ptr = s.token.ptr,
		line_start = s.line_start,
		eol = s.eol,
		mark = s.mark,
		got_lf = s.got_lf,
	}
}

js_parse_seek_token :: proc(s: ^Parse_State, sp: ^Parse_Pos) -> bool {
	s.token.line_num = sp.last_line_num
	s.token.col_num = sp.last_col_num
	s.line_num = sp.line_num
	s.col_num = sp.col_num
	s.buf_ptr = sp.ptr
	s.line_start = sp.line_start
	s.eol = sp.eol
	s.mark = sp.mark
	s.got_lf = sp.got_lf
	return next_token(s)
}

is_regexp_allowed :: proc(tok: int) -> bool {
	switch tok {
	case TOK_NUMBER, TOK_STRING, TOK_REGEXP, TOK_DEC, TOK_INC, TOK_NULL, TOK_FALSE, TOK_TRUE, TOK_THIS,
	     TOK_PRIVATE_NAME, ')', ']', '}', TOK_IDENT:
		return false
	}
	return true
}

SKIP_HAS_SEMI :: 1 << 0
SKIP_HAS_ELLIPSIS :: 1 << 1
SKIP_HAS_ASSIGNMENT :: 1 << 2

// js_parse_skip_parens_token scans ahead over a balanced (), [] or {} group and returns the token after it,
// then rewinds. Errors raised while scanning are discarded, as in QuickJS.
js_parse_skip_parens_token :: proc(s: ^Parse_State, pbits: ^int, no_line_terminator: bool) -> int {
	state: [256]u8
	level := 0
	bits := 0
	tok := TOK_EOF
	last_tok := 0
	saved_err, saved_has := s.error, s.has_error

	state[level] = 0; level += 1
	pos := js_parse_get_pos(s)
	scan: for {
		handle_template := false
		switch s.token.val {
		case '(', '[', '{':
			if level >= len(state) {break scan}
			state[level] = u8(s.token.val); level += 1
		case ')':
			level -= 1
			if state[level] != '(' {break scan}
		case ']':
			level -= 1
			if state[level] != '[' {break scan}
		case '}':
			level -= 1
			c := state[level]
			if c == '`' {
				s.got_lf = false
				s.last_line_num = s.token.line_num
				s.last_col_num = s.token.col_num
				if js_parse_template_part(s, s.buf_ptr) {break scan}
				handle_template = true
			} else if c != '{' {
				break scan
			}
		case TOK_TEMPLATE:
			handle_template = true
		case TOK_EOF:
			break scan
		case ';':
			if level == 2 {bits |= SKIP_HAS_SEMI}
		case TOK_ELLIPSIS:
			if level == 2 {bits |= SKIP_HAS_ELLIPSIS}
		case '=':
			bits |= SKIP_HAS_ASSIGNMENT
		case TOK_DIV_ASSIGN, '/':
			tok_len := s.token.val == '/' ? 1 : 2
			if is_regexp_allowed(last_tok) {
				s.buf_ptr -= tok_len
				if js_parse_regexp(s) {break scan}
			}
		}
		if handle_template {
			if s.token.sep != '`' {
				if level >= len(state) {break scan}
				state[level] = '`'; level += 1
			}
		}
		if s.token.val == TOK_IDENT && (token_is_pseudo_keyword(s, A_of) || token_is_pseudo_keyword(s, A_yield)) {
			last_tok = TOK_OF
		} else {
			last_tok = s.token.val
		}
		if next_token(s) {break scan}
		if level <= 1 {
			tok = s.token.val
			if token_is_pseudo_keyword(s, A_of) {tok = TOK_OF}
			if no_line_terminator && s.last_line_num != s.token.line_num {tok = '\n'}
			break scan
		}
	}
	if pbits != nil {pbits^ = bits}
	s.error, s.has_error = saved_err, saved_has
	if js_parse_seek_token(s, &pos) {return -1}
	return tok
}

skip_shebang :: proc(buf: []u8, p0: int, buf_end: int) -> int {
	p := p0
	if buf[p] == '#' && buf[p + 1] == '!' {
		p += 2
		for p < buf_end {
			if buf[p] == '\n' || buf[p] == '\r' {
				break
			} else if buf[p] >= 0x80 {
				c, np := utf8_decode(buf, p)
				p = np
				if c == CP_LS || c == CP_PS {break}
			} else {
				p += 1
			}
		}
	}
	return p
}
