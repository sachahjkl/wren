package frontend

import "base:runtime"
import ucd "wb:engine/unicode"
import "wb:engine/numconv"

// The ECMAScript lexer. It turns UTF-8 source bytes into a stream of tokens on demand (the parser pulls one at a
// time), tracking line/column positions and cooking literal values (numbers via numconv, identifiers via ucd,
// strings/templates with full escape handling). It handles the whole 2025 lexical grammar: Unicode identifiers
// with \u escapes, numeric separators and BigInt, template literals, regexp vs. division disambiguation (driven
// by the parser through a flag), Annex B HTML-like comments, the hashbang, and private names (#x).
//
// The lexer does not itself know strict mode for keyword purposes: it returns identifiers and a keyword hint, and
// the parser decides whether a reserved word is legal in context. This mirrors QuickJS, where next_token
// produces TOK_IDENT with an atom and the parser compares against JS_ATOM_xxx keyword atoms.

Token_Kind :: enum u8 {
	eof,
	ident,          // identifier or keyword (value in Token.ident; keyword hint in Token.keyword)
	private_name,   // #name
	number,         // numeric literal (Token.num)
	bigint,         // BigInt literal (Token.text holds the digits without the trailing 'n')
	string,         // string literal (cooked value in Token.str)
	template,       // a complete `...` with no substitutions, or the head `...${`, middle `}...${`, tail `}...`
	regexp,         // regular expression literal (Token.text = body, Token.flags_text = flags)
	punct,          // punctuator / operator (Token.punct)
}

// Template cursor sub-kind, so the parser can thread the three template fragment shapes.
Template_Part :: enum u8 {
	no_sub,   // `complete`
	head,     // `head${
	middle,   // }middle${
	tail,     // }tail`
}

// Punctuators. One enum value per distinct operator token; the parser branches on these.
Punct :: enum u8 {
	none,
	lbrace, rbrace, lparen, rparen, lbracket, rbracket,
	dot, dotdotdot, semicolon, comma,
	lt, gt, lte, gte, eq, neq, strict_eq, strict_neq,
	plus, minus, star, percent, starstar,
	plusplus, minusminus,
	shl, sar, shr,
	amp, bar, caret, bang, tilde, and_and, or_or, question, question_dot, question_question,
	colon, arrow, slash, slash_eq,
	assign, plus_eq, minus_eq, star_eq, percent_eq, starstar_eq,
	shl_eq, sar_eq, shr_eq, amp_eq, bar_eq, caret_eq, and_and_eq, or_or_eq, question_question_eq,
	at,
}

Token :: struct {
	kind:          Token_Kind,
	punct:         Punct,
	keyword:       Atom,          // for ident: the predefined keyword atom, or JS_ATOM_NULL if not a keyword
	ident:         string,        // for ident / private_name: the decoded name (escapes resolved) on the arena
	had_escape:    bool,          // ident contained a \u escape (then it is never treated as a keyword)
	str:           String_Value,  // for string / template: the cooked value
	raw:           string,        // for template: the raw (uncooked) text, for the .raw array
	template_part: Template_Part,
	num:           f64,           // for number
	num_is_int:    bool,          // the literal fits the JS_TAG_INT fast path (QuickJS push_i32/push_const choice)
	text:          string,        // for bigint (digits) / regexp (pattern body)
	flags_text:    string,        // for regexp (flags)
	radix:         int,           // for bigint: 2/8/10/16
	pos:           Source_Pos,    // start of the token
	end:           Source_Pos,    // one past the end
	nl_before:     bool,          // a line terminator appeared between the previous token and this one (for ASI)
}

// A cooked string value: QuickJS strings are Latin-1 or UTF-16. We keep the decoded form as a slice of u16 units
// unless it is all Latin-1, in which case `latin1` holds the bytes. This is the shape atoms.intern_utf16 and the
// serializer consume, so a string literal becomes a constant-pool string or an atom without re-decoding.
String_Value :: struct {
	units:   []u16,
	latin1:  []u8,
	is_wide: bool,
}

Lexer :: struct {
	src:        string,
	allocator:  runtime.Allocator,
	pos:        int,  // byte offset of the next unread byte
	line:       u32,
	col:        u32,  // code-point column, 1-based
	line_start: int,  // byte offset of the current line start
	strict:     bool, // affects octal-escape and legacy-octal errors
	had_error:  bool,
	error:      Error,
	// A scratch buffer reused for building cooked strings/identifiers before they are copied onto the arena.
	scratch:    [dynamic]u16,
}

lexer_init :: proc(l: ^Lexer, src: string, allocator: runtime.Allocator) {
	l.src = src
	l.allocator = allocator
	l.pos = 0
	l.line = 1
	l.col = 1
	l.line_start = 0
	l.scratch = make([dynamic]u16, 0, 64, allocator)
	// Skip a hashbang line (#!...) if present; it is only valid at the very start of a source.
	if len(src) >= 2 && src[0] == '#' && src[1] == '!' {
		for l.pos < len(src) && !is_line_terminator_byte_start(src, l.pos) {
			l.pos += 1
		}
	}
}

// --- character classification -------------------------------------------------------------------------------

// ECMAScript LineTerminator: LF, CR, LS (U+2028), PS (U+2029).
@(private = "file")
is_line_terminator :: #force_inline proc(c: rune) -> bool {
	return c == '\n' || c == '\r' || c == 0x2028 || c == 0x2029
}

// WhiteSpace: TAB, VT, FF, SP, NBSP, ZWNBSP(BOM) and any Space_Separator. Not line terminators.
@(private = "file")
is_js_whitespace :: proc(c: rune) -> bool {
	switch c {
	case '\t', 0x0B, '\f', ' ', 0xA0, 0xFEFF:
		return true
	}
	if c < 0x80 {
		return false
	}
	// Space_Separator (Zs) are inside White_Space in ucd minus the line/para separators we excluded above.
	return c >= 0x1680 && ucd.is_white_space(u32(c)) && !is_line_terminator(c)
}

@(private = "file")
is_line_terminator_byte_start :: proc(s: string, i: int) -> bool {
	c := s[i]
	if c == '\n' || c == '\r' {
		return true
	}
	// U+2028 / U+2029 are E2 80 A8 / E2 80 A9.
	if c == 0xE2 && i + 2 < len(s) && s[i + 1] == 0x80 && (s[i + 2] == 0xA8 || s[i + 2] == 0xA9) {
		return true
	}
	return false
}

// --- low-level cursor ---------------------------------------------------------------------------------------

@(private = "file")
cur_pos :: proc(l: ^Lexer) -> Source_Pos {
	return Source_Pos{offset = u32(l.pos), line = l.line, col = l.col}
}

// peek_rune decodes the code point at a byte offset without advancing, returning U+FFFD on malformed input.
@(private = "file")
peek_rune :: proc(l: ^Lexer, at: int) -> (r: rune, w: int) {
	if at >= len(l.src) {
		return 0, 0
	}
	b := l.src[at]
	if b < 0x80 {
		return rune(b), 1
	}
	s := l.src
	if b < 0xC0 {
		return 0xFFFD, 1
	} else if b < 0xE0 {
		if at + 1 >= len(s) {return 0xFFFD, 1}
		return rune(u32(b & 0x1F) << 6 | u32(s[at + 1] & 0x3F)), 2
	} else if b < 0xF0 {
		if at + 2 >= len(s) {return 0xFFFD, 1}
		return rune(u32(b & 0x0F) << 12 | u32(s[at + 1] & 0x3F) << 6 | u32(s[at + 2] & 0x3F)), 3
	} else if b < 0xF8 {
		if at + 3 >= len(s) {return 0xFFFD, 1}
		return rune(u32(b & 0x07) << 18 | u32(s[at + 1] & 0x3F) << 12 | u32(s[at + 2] & 0x3F) << 6 | u32(s[at + 3] & 0x3F)), 4
	}
	return 0xFFFD, 1
}

@(private = "file")
advance_rune :: proc(l: ^Lexer) -> rune {
	r, w := peek_rune(l, l.pos)
	if w == 0 {
		return 0
	}
	if is_line_terminator(r) {
		// CRLF counts as one line terminator; handle by not double-counting when CR is followed by LF.
		if r == '\r' && l.pos + 1 < len(l.src) && l.src[l.pos + 1] == '\n' {
			l.pos += 1
		}
		l.pos += w
		l.line += 1
		l.col = 1
		l.line_start = l.pos
	} else {
		l.pos += w
		l.col += 1
	}
	return r
}

@(private = "file")
lex_error :: proc(l: ^Lexer, msg: string) -> Token {
	if !l.had_error {
		l.had_error = true
		l.error = make_error(msg, cur_pos(l))
	}
	return Token{kind = .eof, pos = cur_pos(l), end = cur_pos(l)}
}

// --- skipping trivia ----------------------------------------------------------------------------------------

// skip_trivia advances over whitespace and comments, returning whether a line terminator was crossed (needed for
// ASI and for the `}` after a template substitution). Annex B HTML-like comments (<!-- and -->) are recognized in
// non-module (script) code; the parser sets `html_comments`.
@(private = "file")
skip_trivia :: proc(l: ^Lexer, html_comments: bool) -> (nl: bool) {
	for l.pos < len(l.src) {
		b := l.src[l.pos]
		if b == ' ' || b == '\t' || b == 0x0B || b == '\f' {
			l.pos += 1
			l.col += 1
			continue
		}
		if b == '\n' || b == '\r' {
			advance_rune(l)
			nl = true
			continue
		}
		if b == '/' && l.pos + 1 < len(l.src) {
			nb := l.src[l.pos + 1]
			if nb == '/' {
				l.pos += 2
				for l.pos < len(l.src) && !is_line_terminator_byte_start(l.src, l.pos) {
					l.pos += 1
				}
				continue
			}
			if nb == '*' {
				l.pos += 2
				for l.pos < len(l.src) {
					if l.src[l.pos] == '*' && l.pos + 1 < len(l.src) && l.src[l.pos + 1] == '/' {
						l.pos += 2
						break
					}
					if is_line_terminator_byte_start(l.src, l.pos) {
						advance_rune(l)
						nl = true
					} else {
						l.pos += 1
						l.col += 1
					}
				}
				continue
			}
		}
		// Annex B: `<!--` starts a single-line comment in script code.
		if html_comments && b == '<' && starts_with_at(l.src, l.pos, "<!--") {
			l.pos += 4
			for l.pos < len(l.src) && !is_line_terminator_byte_start(l.src, l.pos) {
				l.pos += 1
			}
			continue
		}
		// Annex B: `-->` at the start of a line (only whitespace/comments before it) is a single-line comment.
		if html_comments && b == '-' && nl && starts_with_at(l.src, l.pos, "-->") {
			l.pos += 3
			for l.pos < len(l.src) && !is_line_terminator_byte_start(l.src, l.pos) {
				l.pos += 1
			}
			continue
		}
		// Unicode whitespace beyond ASCII.
		r, w := peek_rune(l, l.pos)
		if is_js_whitespace(r) {
			l.pos += w
			l.col += 1
			continue
		}
		if is_line_terminator(r) {
			advance_rune(l)
			nl = true
			continue
		}
		break
	}
	return nl
}

@(private = "file")
starts_with_at :: proc(s: string, i: int, prefix: string) -> bool {
	if i + len(prefix) > len(s) {
		return false
	}
	return s[i:i + len(prefix)] == prefix
}

// --- the main token routine ---------------------------------------------------------------------------------

// Options the parser passes per token so the lexer can resolve the context-sensitive bits of the grammar.
Lex_Options :: struct {
	regexp_allowed: bool, // a `/` here begins a regexp literal, not a division (parser tracks this)
	html_comments:  bool, // Annex B HTML comments allowed (script, not module)
	strict:         bool, // strict mode: octal escapes and legacy octals are errors
}

// next_token scans and returns the next token. On lexical error it sets l.had_error and returns an eof token;
// callers must check l.had_error.
next_token :: proc(l: ^Lexer, opt: Lex_Options) -> Token {
	l.strict = opt.strict
	nl := skip_trivia(l, opt.html_comments)
	start := cur_pos(l)
	if l.pos >= len(l.src) {
		return Token{kind = .eof, pos = start, end = start, nl_before = nl}
	}
	b := l.src[l.pos]

	// Identifiers / keywords, and the \u escape start.
	if b == '$' || b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || b >= 0x80 || b == '\\' {
		return lex_identifier(l, start, nl)
	}
	if b == '#' {
		return lex_private_name(l, start, nl)
	}
	if b >= '0' && b <= '9' {
		return lex_number(l, start, nl)
	}
	if b == '.' {
		// `.5` is a number; `.` and `...` are punctuators.
		if l.pos + 1 < len(l.src) && l.src[l.pos + 1] >= '0' && l.src[l.pos + 1] <= '9' {
			return lex_number(l, start, nl)
		}
		return lex_punct(l, start, nl)
	}
	if b == '"' || b == '\'' {
		return lex_string(l, start, nl)
	}
	if b == '`' {
		return lex_template(l, start, nl, true)
	}
	if b == '/' && opt.regexp_allowed {
		return lex_regexp(l, start, nl)
	}
	return lex_punct(l, start, nl)
}

// scan_template_continuation is called by the parser when it has consumed a `}` that closes a template
// substitution, to read the following middle/tail fragment. The lexer is positioned right after the `}`.
scan_template_continuation :: proc(l: ^Lexer) -> Token {
	start := cur_pos(l)
	return lex_template(l, start, false, false)
}

// --- identifiers --------------------------------------------------------------------------------------------

@(private = "file")
lex_identifier :: proc(l: ^Lexer, start: Source_Pos, nl: bool) -> Token {
	clear(&l.scratch)
	had_escape := false
	first := true
	for l.pos < len(l.src) {
		r, w := peek_rune(l, l.pos)
		if r == '\\' {
			// Must be \uXXXX or \u{...}.
			if l.pos + 1 >= len(l.src) || l.src[l.pos + 1] != 'u' {
				return lex_error(l, "invalid escape sequence in identifier")
			}
			l.pos += 2
			l.col += 2
			cp, ok := read_unicode_escape(l)
			if !ok {
				return lex_error(l, "invalid escape sequence in identifier")
			}
			ok2 := first ? ucd.js_is_ident_first(u32(cp)) : ucd.js_is_ident_next(u32(cp))
			if !ok2 {
				return lex_error(l, "invalid identifier character")
			}
			had_escape = true
			append_cp(&l.scratch, cp)
			first = false
			continue
		}
		if first {
			if !(r == '$' || r == '_' || ucd.is_id_start(u32(r))) {
				break
			}
		} else {
			if !(r == '$' || r == '_' || r == 0x200C || r == 0x200D || ucd.is_id_continue(u32(r))) {
				break
			}
		}
		append_cp(&l.scratch, r)
		l.pos += w
		l.col += 1
		first = false
	}
	name := units_to_utf8(l.scratch[:], l.allocator)
	kw := JS_ATOM_NULL
	if !had_escape {
		kw = keyword_atom(name)
	}
	return Token{
		kind = .ident, ident = name, had_escape = had_escape, keyword = kw,
		pos = start, end = cur_pos(l), nl_before = nl,
	}
}

@(private = "file")
lex_private_name :: proc(l: ^Lexer, start: Source_Pos, nl: bool) -> Token {
	l.pos += 1 // consume '#'
	l.col += 1
	t := lex_identifier(l, start, nl)
	if l.had_error {
		return t
	}
	if len(t.ident) == 0 {
		return lex_error(l, "invalid private name")
	}
	t.kind = .private_name
	t.keyword = JS_ATOM_NULL
	t.pos = start
	return t
}

// keyword_atom returns the predefined keyword atom for a name, or JS_ATOM_NULL. Keywords are exactly the leading
// run of the predefined atom table (null .. await), matching QuickJS's JS_ATOM_LAST_KEYWORD / reserved-word
// handling: the parser decides strictness. We recognize the whole reserved-word set here and let the parser gate
// the contextual ones (let/yield/await/static/etc.) by mode.
@(private = "file")
keyword_atom :: proc(name: string) -> Atom {
	// The reserved words occupy positions null(1)..await(47) in PREDEFINED_ATOMS; but null/false/true are
	// literals and the rest are keywords. We match any of them and return the atom; the parser classifies.
	switch name {
	case "null", "false", "true", "if", "else", "return", "var", "this", "delete", "void", "typeof", "new",
	     "in", "instanceof", "do", "while", "for", "break", "continue", "switch", "case", "default", "throw",
	     "try", "catch", "finally", "function", "debugger", "with", "class", "const", "enum", "export",
	     "extends", "import", "super", "using", "implements", "interface", "let", "package", "private",
	     "protected", "public", "static", "yield", "await":
		return predef_atom(name)
	}
	return JS_ATOM_NULL
}

// --- unicode escape helpers ---------------------------------------------------------------------------------

// read_unicode_escape reads the XXXX or {...} after a \u (the \u has been consumed). Returns the code point.
@(private = "file")
read_unicode_escape :: proc(l: ^Lexer) -> (cp: rune, ok: bool) {
	if l.pos < len(l.src) && l.src[l.pos] == '{' {
		l.pos += 1
		l.col += 1
		v: u32 = 0
		digits := 0
		for l.pos < len(l.src) && l.src[l.pos] != '}' {
			d, dok := hex_digit(l.src[l.pos])
			if !dok {
				return 0, false
			}
			v = v * 16 + u32(d)
			if v > 0x10FFFF {
				return 0, false
			}
			l.pos += 1
			l.col += 1
			digits += 1
		}
		if digits == 0 || l.pos >= len(l.src) {
			return 0, false
		}
		l.pos += 1 // '}'
		l.col += 1
		return rune(v), true
	}
	v: u32 = 0
	for _ in 0 ..< 4 {
		if l.pos >= len(l.src) {
			return 0, false
		}
		d, dok := hex_digit(l.src[l.pos])
		if !dok {
			return 0, false
		}
		v = v * 16 + u32(d)
		l.pos += 1
		l.col += 1
	}
	return rune(v), true
}

@(private = "file")
hex_digit :: proc(c: u8) -> (int, bool) {
	switch c {
	case '0' ..= '9':
		return int(c - '0'), true
	case 'a' ..= 'f':
		return int(c - 'a' + 10), true
	case 'A' ..= 'F':
		return int(c - 'A' + 10), true
	}
	return 0, false
}

// --- numbers ------------------------------------------------------------------------------------------------

@(private = "file")
lex_number :: proc(l: ^Lexer, start: Source_Pos, nl: bool) -> Token {
	begin := l.pos
	is_bigint := false
	radix := 10
	// Prefixed forms: 0x 0o 0b and legacy octal 0NNN.
	if l.src[l.pos] == '0' && l.pos + 1 < len(l.src) {
		c := l.src[l.pos + 1]
		switch c {
		case 'x', 'X':
			radix = 16
			l.pos += 2; l.col += 2
			if !scan_digits(l, 16) {return lex_error(l, "invalid number literal")}
		case 'o', 'O':
			radix = 8
			l.pos += 2; l.col += 2
			if !scan_digits(l, 8) {return lex_error(l, "invalid number literal")}
		case 'b', 'B':
			radix = 2
			l.pos += 2; l.col += 2
			if !scan_digits(l, 2) {return lex_error(l, "invalid number literal")}
		case '0' ..= '9':
			// Legacy octal (0777) or a decimal with a leading zero (08). Strict mode forbids both.
			if l.strict {
				return lex_error(l, "octal literals are not allowed in strict mode")
			}
			radix = 8
			for l.pos < len(l.src) && l.src[l.pos] >= '0' && l.src[l.pos] <= '9' {
				if l.src[l.pos] >= '8' {radix = 10} // 08/09 -> decimal (NonOctalDecimalIntegerLiteral)
				l.pos += 1; l.col += 1
			}
		}
	}
	if radix == 10 {
		// Integer part.
		scan_decimal_digits(l)
		// BigInt suffix only valid for integer with no '.'/exp.
		if l.pos < len(l.src) && l.src[l.pos] == 'n' {
			is_bigint = true
		} else {
			if l.pos < len(l.src) && l.src[l.pos] == '.' {
				l.pos += 1; l.col += 1
				scan_decimal_digits(l)
			}
			if l.pos < len(l.src) && (l.src[l.pos] == 'e' || l.src[l.pos] == 'E') {
				l.pos += 1; l.col += 1
				if l.pos < len(l.src) && (l.src[l.pos] == '+' || l.src[l.pos] == '-') {
					l.pos += 1; l.col += 1
				}
				if !scan_digits(l, 10) {return lex_error(l, "invalid number literal")}
			}
		}
	} else {
		if l.pos < len(l.src) && l.src[l.pos] == 'n' {
			is_bigint = true
		}
	}

	text := l.src[begin:l.pos]
	if is_bigint {
		digits := strip_separators(text, l.allocator)
		// skip the 'n'
		l.pos += 1; l.col += 1
		// A following identifier char is an error (e.g. 1nx).
		if ident_follows(l) {
			return lex_error(l, "invalid BigInt literal")
		}
		return Token{kind = .bigint, text = digits, radix = radix, pos = start, end = cur_pos(l), nl_before = nl}
	}

	if ident_follows(l) {
		return lex_error(l, "invalid number literal")
	}
	// Parse the value. numconv.atod takes the radix (0 = auto with prefix) and returns the f64. We pass the
	// explicit radix so 0x/0o/0b and legacy octal are handled consistently, using a separator-stripped copy.
	clean := strip_separators(text, l.allocator)
	val: f64
	ok: bool
	consumed: int
	val, consumed, ok = numconv.atod(clean, radix == 10 ? 0 : radix, {.Accept_Bin_Oct})
	_ = consumed
	if !ok {
		return lex_error(l, "invalid number literal")
	}
	// Decide the int fast path: QuickJS emits push_i32 for an integer that round-trips through i32, and a float
	// constant otherwise. An integer-form literal (no '.', 'e') whose value fits i32 takes the fast path.
	integral := radix != 10 || is_integer_literal(clean)
	is_int := integral && val == f64(i32(val))
	return Token{
		kind = .number, num = val, num_is_int = is_int,
		pos = start, end = cur_pos(l), nl_before = nl,
	}
}

@(private = "file")
is_integer_literal :: proc(s: string) -> bool {
	for c in transmute([]u8)s {
		if c == '.' || c == 'e' || c == 'E' {
			return false
		}
	}
	return true
}

@(private = "file")
scan_decimal_digits :: proc(l: ^Lexer) {
	for l.pos < len(l.src) {
		c := l.src[l.pos]
		if c >= '0' && c <= '9' {
			l.pos += 1; l.col += 1
		} else if c == '_' {
			l.pos += 1; l.col += 1
		} else {
			break
		}
	}
}

// scan_digits reads one or more digits of the given radix, allowing single underscores between digits. Returns
// false if there is not at least one digit.
@(private = "file")
scan_digits :: proc(l: ^Lexer, radix: int) -> bool {
	n := 0
	for l.pos < len(l.src) {
		c := l.src[l.pos]
		if c == '_' {
			l.pos += 1; l.col += 1
			continue
		}
		d, ok := hex_digit(c)
		if !ok || d >= radix {
			break
		}
		l.pos += 1; l.col += 1
		n += 1
	}
	return n > 0
}

@(private = "file")
ident_follows :: proc(l: ^Lexer) -> bool {
	if l.pos >= len(l.src) {
		return false
	}
	r, _ := peek_rune(l, l.pos)
	return r == '$' || r == '_' || ucd.is_id_start(u32(r)) || (r >= '0' && r <= '9')
}

@(private = "file")
strip_separators :: proc(s: string, allocator: runtime.Allocator) -> string {
	has := false
	for c in transmute([]u8)s {
		if c == '_' {has = true; break}
	}
	if !has {
		return s
	}
	b := make([dynamic]u8, 0, len(s), allocator)
	for c in transmute([]u8)s {
		if c != '_' {append(&b, c)}
	}
	return string(b[:])
}

// --- strings ------------------------------------------------------------------------------------------------

@(private = "file")
lex_string :: proc(l: ^Lexer, start: Source_Pos, nl: bool) -> Token {
	quote := l.src[l.pos]
	l.pos += 1; l.col += 1
	clear(&l.scratch)
	for l.pos < len(l.src) {
		b := l.src[l.pos]
		if b == quote {
			l.pos += 1; l.col += 1
			sv := units_to_string_value(l.scratch[:], l.allocator)
			return Token{kind = .string, str = sv, pos = start, end = cur_pos(l), nl_before = nl}
		}
		if b == '\\' {
			if !lex_escape_into(l, &l.scratch) {
				return error_token(l)
			}
			continue
		}
		if b == '\n' || b == '\r' {
			return lex_error(l, "unterminated string literal")
		}
		r, w := peek_rune(l, l.pos)
		if is_line_terminator(r) {
			return lex_error(l, "unterminated string literal")
		}
		append_cp(&l.scratch, r)
		l.pos += w; l.col += 1
	}
	return lex_error(l, "unterminated string literal")
}

@(private = "file")
error_token :: proc(l: ^Lexer) -> Token {
	return Token{kind = .eof, pos = cur_pos(l), end = cur_pos(l)}
}

// lex_escape_into consumes a backslash escape and appends its cooked code units to `out`. Handles \n \t \r etc.,
// \xHH, \uXXXX, \u{...}, line continuations, legacy octal escapes (non-strict), and \0.
@(private = "file")
lex_escape_into :: proc(l: ^Lexer, out: ^[dynamic]u16) -> bool {
	l.pos += 1; l.col += 1 // backslash
	if l.pos >= len(l.src) {
		lex_error(l, "unterminated string literal")
		return false
	}
	c := l.src[l.pos]
	switch c {
	case 'n': append(out, u16('\n')); l.pos += 1; l.col += 1
	case 't': append(out, u16('\t')); l.pos += 1; l.col += 1
	case 'r': append(out, u16('\r')); l.pos += 1; l.col += 1
	case 'b': append(out, u16(0x08)); l.pos += 1; l.col += 1
	case 'f': append(out, u16(0x0C)); l.pos += 1; l.col += 1
	case 'v': append(out, u16(0x0B)); l.pos += 1; l.col += 1
	case '0' ..= '7':
		return lex_octal_escape(l, out, c)
	case 'x':
		l.pos += 1; l.col += 1
		if l.pos >= len(l.src) {lex_error(l, "invalid hexadecimal escape sequence"); return false}
		h1, ok1 := hex_digit(l.src[l.pos])
		if !ok1 {lex_error(l, "invalid hexadecimal escape sequence"); return false}
		l.pos += 1; l.col += 1
		if l.pos >= len(l.src) {lex_error(l, "invalid hexadecimal escape sequence"); return false}
		h2, ok2 := hex_digit(l.src[l.pos])
		if !ok2 {lex_error(l, "invalid hexadecimal escape sequence"); return false}
		l.pos += 1; l.col += 1
		append(out, u16(h1 * 16 + h2))
	case 'u':
		l.pos += 1; l.col += 1
		cp, ok := read_unicode_escape(l)
		if !ok {lex_error(l, "invalid Unicode escape sequence"); return false}
		append_cp(out, rune(cp))
	case '\r':
		// Line continuation: \ followed by CR, CRLF or LF produces nothing.
		l.pos += 1; l.col += 1
		if l.pos < len(l.src) && l.src[l.pos] == '\n' {l.pos += 1}
		l.line += 1; l.col = 1; l.line_start = l.pos
	case '\n':
		l.pos += 1; l.line += 1; l.col = 1; l.line_start = l.pos
	case:
		// \<LS>/<PS> line continuation, or any other character which stands for itself.
		r, w := peek_rune(l, l.pos)
		if is_line_terminator(r) {
			l.pos += w; l.line += 1; l.col = 1; l.line_start = l.pos
		} else {
			append_cp(out, r)
			l.pos += w; l.col += 1
		}
	}
	return true
}

@(private = "file")
lex_octal_escape :: proc(l: ^Lexer, out: ^[dynamic]u16, first: u8) -> bool {
	// \0 not followed by a digit is a NUL and is allowed even in strict mode. Any other octal escape is a legacy
	// feature and is a SyntaxError in strict mode.
	if first == '0' && !(l.pos + 1 < len(l.src) && l.src[l.pos + 1] >= '0' && l.src[l.pos + 1] <= '9') {
		append(out, 0)
		l.pos += 1; l.col += 1
		return true
	}
	if l.strict {
		lex_error(l, "octal escape sequences are not allowed in strict mode")
		return false
	}
	v := int(first - '0')
	l.pos += 1; l.col += 1
	max_more := first <= '3' ? 2 : 1
	for _ in 0 ..< max_more {
		if l.pos < len(l.src) && l.src[l.pos] >= '0' && l.src[l.pos] <= '7' {
			v = v * 8 + int(l.src[l.pos] - '0')
			l.pos += 1; l.col += 1
		} else {
			break
		}
	}
	append(out, u16(v))
	return true
}

// --- templates ----------------------------------------------------------------------------------------------

// lex_template reads one template fragment. When `head` is true the lexer is positioned on the opening backtick
// (so the result is .no_sub or .head); otherwise it is positioned right after a `}` (so the result is .middle or
// .tail). The raw text (for the .raw cooked array) and the cooked value are both produced.
@(private = "file")
lex_template :: proc(l: ^Lexer, start: Source_Pos, nl: bool, head: bool) -> Token {
	if head {
		l.pos += 1; l.col += 1 // opening backtick
	}
	raw_begin := l.pos
	clear(&l.scratch)
	for l.pos < len(l.src) {
		b := l.src[l.pos]
		if b == '`' {
			raw := l.src[raw_begin:l.pos]
			l.pos += 1; l.col += 1
			part: Template_Part = head ? .no_sub : .tail
			sv := units_to_string_value(l.scratch[:], l.allocator)
			return Token{kind = .template, str = sv, raw = raw, template_part = part, pos = start, end = cur_pos(l), nl_before = nl}
		}
		if b == '$' && l.pos + 1 < len(l.src) && l.src[l.pos + 1] == '{' {
			raw := l.src[raw_begin:l.pos]
			l.pos += 2; l.col += 2
			part: Template_Part = head ? .head : .middle
			sv := units_to_string_value(l.scratch[:], l.allocator)
			return Token{kind = .template, str = sv, raw = raw, template_part = part, pos = start, end = cur_pos(l), nl_before = nl}
		}
		if b == '\\' {
			// In a template, cooked escapes may be invalid without aborting the whole literal (tagged templates
			// allow undefined cooked value). We cook best-effort; the parser handles the undefined-cooked rule.
			if !lex_escape_into(l, &l.scratch) {
				// Keep going for the raw; reset the error so a tagged template can still carry raw text.
				l.had_error = false
			}
			continue
		}
		if b == '\r' {
			// Template literals normalize CRLF and CR to LF in both raw and cooked.
			append(&l.scratch, u16('\n'))
			l.pos += 1
			if l.pos < len(l.src) && l.src[l.pos] == '\n' {l.pos += 1}
			l.line += 1; l.col = 1; l.line_start = l.pos
			continue
		}
		r, w := peek_rune(l, l.pos)
		if is_line_terminator(r) {
			append(&l.scratch, u16('\n'))
			l.pos += w; l.line += 1; l.col = 1; l.line_start = l.pos
			continue
		}
		append_cp(&l.scratch, r)
		l.pos += w; l.col += 1
	}
	return lex_error(l, "unterminated template literal")
}

// --- regexp -------------------------------------------------------------------------------------------------

@(private = "file")
lex_regexp :: proc(l: ^Lexer, start: Source_Pos, nl: bool) -> Token {
	l.pos += 1; l.col += 1 // leading '/'
	body_begin := l.pos
	in_class := false
	for l.pos < len(l.src) {
		b := l.src[l.pos]
		if is_line_terminator_byte_start(l.src, l.pos) {
			return lex_error(l, "unterminated regular expression literal")
		}
		if b == '\\' {
			l.pos += 1; l.col += 1
			if l.pos >= len(l.src) || is_line_terminator_byte_start(l.src, l.pos) {
				return lex_error(l, "unterminated regular expression literal")
			}
			r, w := peek_rune(l, l.pos)
			_ = r
			l.pos += w; l.col += 1
			continue
		}
		if b == '[' {
			in_class = true
		} else if b == ']' {
			in_class = false
		} else if b == '/' && !in_class {
			break
		}
		r, w := peek_rune(l, l.pos)
		_ = r
		l.pos += w; l.col += 1
	}
	if l.pos >= len(l.src) || l.src[l.pos] != '/' {
		return lex_error(l, "unterminated regular expression literal")
	}
	body := l.src[body_begin:l.pos]
	l.pos += 1; l.col += 1 // closing '/'
	flags_begin := l.pos
	for l.pos < len(l.src) {
		r, w := peek_rune(l, l.pos)
		if r == '$' || r == '_' || ucd.is_id_continue(u32(r)) {
			l.pos += w; l.col += 1
		} else {
			break
		}
	}
	flags := l.src[flags_begin:l.pos]
	return Token{kind = .regexp, text = body, flags_text = flags, pos = start, end = cur_pos(l), nl_before = nl}
}

// --- punctuators --------------------------------------------------------------------------------------------

@(private = "file")
lex_punct :: proc(l: ^Lexer, start: Source_Pos, nl: bool) -> Token {
	s := l.src
	i := l.pos
	p := Punct.none
	n := 1
	c := s[i]
	switch c {
	case '{': p = .lbrace
	case '}': p = .rbrace
	case '(': p = .lparen
	case ')': p = .rparen
	case '[': p = .lbracket
	case ']': p = .rbracket
	case ';': p = .semicolon
	case ',': p = .comma
	case ':': p = .colon
	case '~': p = .tilde
	case '@': p = .at
	case '.':
		if starts_with_at(s, i, "...") {p = .dotdotdot; n = 3} else {p = .dot}
	case '?':
		if starts_with_at(s, i, "??=") {p = .question_question_eq; n = 3}
		else if starts_with_at(s, i, "??") {p = .question_question; n = 2}
		else if i + 1 < len(s) && s[i + 1] == '.' && !(i + 2 < len(s) && s[i + 2] >= '0' && s[i + 2] <= '9') {
			p = .question_dot; n = 2
		} else {p = .question}
	case '<':
		if starts_with_at(s, i, "<<=") {p = .shl_eq; n = 3}
		else if starts_with_at(s, i, "<<") {p = .shl; n = 2}
		else if starts_with_at(s, i, "<=") {p = .lte; n = 2}
		else {p = .lt}
	case '>':
		if starts_with_at(s, i, ">>>=") {p = .shr_eq; n = 4}
		else if starts_with_at(s, i, ">>>") {p = .shr; n = 3}
		else if starts_with_at(s, i, ">>=") {p = .sar_eq; n = 3}
		else if starts_with_at(s, i, ">>") {p = .sar; n = 2}
		else if starts_with_at(s, i, ">=") {p = .gte; n = 2}
		else {p = .gt}
	case '=':
		if starts_with_at(s, i, "===") {p = .strict_eq; n = 3}
		else if starts_with_at(s, i, "==") {p = .eq; n = 2}
		else if starts_with_at(s, i, "=>") {p = .arrow; n = 2}
		else {p = .assign}
	case '!':
		if starts_with_at(s, i, "!==") {p = .strict_neq; n = 3}
		else if starts_with_at(s, i, "!=") {p = .neq; n = 2}
		else {p = .bang}
	case '+':
		if starts_with_at(s, i, "++") {p = .plusplus; n = 2}
		else if starts_with_at(s, i, "+=") {p = .plus_eq; n = 2}
		else {p = .plus}
	case '-':
		if starts_with_at(s, i, "--") {p = .minusminus; n = 2}
		else if starts_with_at(s, i, "-=") {p = .minus_eq; n = 2}
		else {p = .minus}
	case '*':
		if starts_with_at(s, i, "**=") {p = .starstar_eq; n = 3}
		else if starts_with_at(s, i, "**") {p = .starstar; n = 2}
		else if starts_with_at(s, i, "*=") {p = .star_eq; n = 2}
		else {p = .star}
	case '/':
		if starts_with_at(s, i, "/=") {p = .slash_eq; n = 2} else {p = .slash}
	case '%':
		if starts_with_at(s, i, "%=") {p = .percent_eq; n = 2} else {p = .percent}
	case '&':
		if starts_with_at(s, i, "&&=") {p = .and_and_eq; n = 3}
		else if starts_with_at(s, i, "&&") {p = .and_and; n = 2}
		else if starts_with_at(s, i, "&=") {p = .amp_eq; n = 2}
		else {p = .amp}
	case '|':
		if starts_with_at(s, i, "||=") {p = .or_or_eq; n = 3}
		else if starts_with_at(s, i, "||") {p = .or_or; n = 2}
		else if starts_with_at(s, i, "|=") {p = .bar_eq; n = 2}
		else {p = .bar}
	case '^':
		if starts_with_at(s, i, "^=") {p = .caret_eq; n = 2} else {p = .caret}
	case:
		return lex_error(l, "unexpected character")
	}
	l.pos += n
	l.col += u32(n)
	return Token{kind = .punct, punct = p, pos = start, end = cur_pos(l), nl_before = nl}
}

// --- unit/encoding helpers ----------------------------------------------------------------------------------

@(private = "file")
append_cp :: proc(out: ^[dynamic]u16, r: rune) {
	if r > 0xFFFF {
		c := u32(r) - 0x10000
		append(out, u16(0xD800 + (c >> 10)))
		append(out, u16(0xDC00 + (c & 0x3FF)))
	} else {
		append(out, u16(r))
	}
}

// units_to_utf8 re-encodes decoded identifier code units back to UTF-8 for use as an identifier string / map key.
@(private = "file")
units_to_utf8 :: proc(units: []u16, allocator: runtime.Allocator) -> string {
	b := make([dynamic]u8, 0, len(units) + 4, allocator)
	i := 0
	for i < len(units) {
		cp: u32
		u := units[i]
		if u >= 0xD800 && u <= 0xDBFF && i + 1 < len(units) && units[i + 1] >= 0xDC00 && units[i + 1] <= 0xDFFF {
			cp = 0x10000 + (u32(u - 0xD800) << 10) + u32(units[i + 1] - 0xDC00)
			i += 2
		} else {
			cp = u32(u)
			i += 1
		}
		encode_utf8(&b, cp)
	}
	return string(b[:])
}

@(private = "file")
encode_utf8 :: proc(b: ^[dynamic]u8, cp: u32) {
	if cp < 0x80 {
		append(b, u8(cp))
	} else if cp < 0x800 {
		append(b, u8(0xC0 | (cp >> 6)), u8(0x80 | (cp & 0x3F)))
	} else if cp < 0x10000 {
		append(b, u8(0xE0 | (cp >> 12)), u8(0x80 | ((cp >> 6) & 0x3F)), u8(0x80 | (cp & 0x3F)))
	} else {
		append(b, u8(0xF0 | (cp >> 18)), u8(0x80 | ((cp >> 12) & 0x3F)), u8(0x80 | ((cp >> 6) & 0x3F)), u8(0x80 | (cp & 0x3F)))
	}
}

// units_to_string_value packs cooked code units into the String_Value shape, choosing Latin-1 when every unit
// fits in a byte (QuickJS's is_wide_char = 0) and UTF-16 otherwise.
@(private = "file")
units_to_string_value :: proc(units: []u16, allocator: runtime.Allocator) -> String_Value {
	wide := false
	for u in units {
		if u >= 256 {wide = true; break}
	}
	if wide {
		cp := make([]u16, len(units), allocator)
		copy(cp, units)
		return String_Value{units = cp, is_wide = true}
	}
	b := make([]u8, len(units), allocator)
	for u, i in units {
		b[i] = u8(u)
	}
	return String_Value{latin1 = b, is_wide = false}
}
