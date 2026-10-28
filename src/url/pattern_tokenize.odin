package url

// URLPattern — the tokenizer and pattern-string parser of the URL Pattern Standard
// (https://urlpattern.spec.whatwg.org/, §2.1). Pure code, no Lexbor: this turns a component pattern string
// (e.g. "/:category/*") into a part list, the ordered description of what a component must contain to match. The
// matcher (pattern_match.odin) compiles the part list directly rather than through an ECMAScript regular
// expression — Wren has no JavaScript regexp in the host — but produces the same captures and group names the
// specification's RegExpBuiltinExec would. Code points are handled as UTF-8 runes; indices below are code-point
// indices into the input (the spec's "code point substring").

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// §2.1.1 Tokens.
Token_Kind :: enum u8 {
	Open,            // {
	Close,           // }
	Regexp,          // (<regexp>)
	Name,            // :<name>
	Char,            // an ordinary code point
	Escaped_Char,    // \<char>
	Other_Modifier,  // ? or +
	Asterisk,        // *
	End,
	Invalid_Char,    // only produced by the lenient policy
}

Token :: struct {
	kind:  Token_Kind,
	index: int,       // code-point index of the first code point of the token
	value: string,    // the token's code points (a slice of the input, so no allocation)
}

Tokenize_Policy :: enum u8 { Strict, Lenient }

// The pattern parsing never allocates its tokens' strings: they are slices of `input`. The caller keeps `input`
// alive for the life of the token list. `rune_offsets` maps a code-point index to a byte offset in `input`.
@(private = "file")
Tokenizer :: struct {
	input:        string,
	runes:        []rune,       // the input decoded once (code points)
	byte_offset:  []int,        // byte offset of each code point, plus one past the end
	policy:       Tokenize_Policy,
	tokens:       [dynamic]Token,
	index:        int,          // code-point index where the current token began
	next_index:   int,          // code-point index just past the last code point read
	code_point:   rune,
	ok:           bool,         // false once a strict error was hit
}

// Decodes `input` into code points and their byte offsets (len+1 entries, the last one past the end).
@(private = "file")
decode_points :: proc(input: string, allocator := context.temp_allocator) -> (runes: []rune, offsets: []int) {
	rs := make([dynamic]rune, 0, len(input), allocator)
	off := make([dynamic]int, 0, len(input) + 1, allocator)
	i := 0
	for i < len(input) {
		r, w := utf8.decode_rune_in_string(input[i:])
		if w == 0 { w = 1 }
		append(&rs, r)
		append(&off, i)
		i += w
	}
	append(&off, len(input))
	return rs[:], off[:]
}

// The code-point substring [from, to) of the tokenizer's input, as a slice (no allocation).
@(private = "file")
cp_substr :: proc(t: ^Tokenizer, from, to: int) -> string {
	if from < 0 || from > len(t.runes) || to < from { return "" }
	hi := min(to, len(t.runes))
	return t.input[t.byte_offset[from]:t.byte_offset[hi]]
}

@(private = "file")
get_next_code_point :: proc(t: ^Tokenizer) {
	if t.next_index < len(t.runes) { t.code_point = t.runes[t.next_index] } else { t.code_point = -1 }
	t.next_index += 1
}

@(private = "file")
seek :: proc(t: ^Tokenizer, index: int) {
	t.next_index = index
	get_next_code_point(t)
}

@(private = "file")
add_token :: proc(t: ^Tokenizer, kind: Token_Kind, next_pos, value_pos, value_len: int) {
	append(&t.tokens, Token{kind = kind, index = t.index, value = cp_substr(t, value_pos, value_pos + value_len)})
	t.index = next_pos
}

@(private = "file")
add_token_default_len :: proc(t: ^Tokenizer, kind: Token_Kind, next_pos, value_pos: int) {
	add_token(t, kind, next_pos, value_pos, next_pos - value_pos)
}

@(private = "file")
add_token_default :: proc(t: ^Tokenizer, kind: Token_Kind) {
	add_token_default_len(t, kind, t.next_index, t.index)
}

// §2.1.2 "process a tokenizing error": strict throws (we record !ok), lenient emits an invalid-char token.
@(private = "file")
tokenizing_error :: proc(t: ^Tokenizer, next_pos, value_pos: int) {
	if t.policy == .Strict { t.ok = false; return }
	add_token_default_len(t, .Invalid_Char, next_pos, value_pos)
}

// IdentifierStart / IdentifierPart for a `:name`. We allow ASCII letters, `_`, `$`, and (continue) ASCII digits,
// plus non-ASCII letters/number marks — the common subset JS identifiers use in patterns.
@(private = "file")
is_valid_name_code_point :: proc(c: rune, first: bool) -> bool {
	if c == '$' || c == '_' { return true }
	if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' { return true }
	if !first && c >= '0' && c <= '9' { return true }
	if c < 0x80 { return false }
	if first { return unicode.is_letter(c) }
	return unicode.is_letter(c) || unicode.is_digit(c) || unicode.is_combining(c)
}

// §2.1.2 "tokenize": returns the token list and whether it was well formed (strict). The token values are slices of
// `input`; keep `input` alive. Uses the temp allocator for the working rune/offset tables.
tokenize :: proc(input: string, policy: Tokenize_Policy, allocator := context.allocator) -> (tokens: [dynamic]Token, ok: bool) {
	t: Tokenizer
	t.input = input
	t.runes, t.byte_offset = decode_points(input)
	t.policy = policy
	t.tokens = make([dynamic]Token, allocator)
	t.ok = true

	n := len(t.runes)
	for t.index < n {
		seek(&t, t.index)
		c := t.code_point
		switch {
		case c == '*':
			add_token_default(&t, .Asterisk)
			continue
		case c == '+' || c == '?':
			add_token_default(&t, .Other_Modifier)
			continue
		case c == '\\':
			if t.index == n - 1 {
				tokenizing_error(&t, t.next_index, t.index)
				if !t.ok { return t.tokens, false }
				continue
			}
			escaped := t.next_index
			get_next_code_point(&t)
			add_token_default_len(&t, .Escaped_Char, t.next_index, escaped)
			continue
		case c == '{':
			add_token_default(&t, .Open)
			continue
		case c == '}':
			add_token_default(&t, .Close)
			continue
		case c == ':':
			name_pos := t.next_index
			name_start := name_pos
			for name_pos < n {
				seek(&t, name_pos)
				first := name_pos == name_start
				if !is_valid_name_code_point(t.code_point, first) { break }
				name_pos = t.next_index
			}
			if name_pos <= name_start {
				tokenizing_error(&t, name_start, t.index)
				if !t.ok { return t.tokens, false }
				continue
			}
			add_token_default_len(&t, .Name, name_pos, name_start)
			continue
		case c == '(':
			depth := 1
			rx_pos := t.next_index
			rx_start := rx_pos
			error := false
			for rx_pos < n {
				seek(&t, rx_pos)
				if t.code_point < 0 || t.code_point >= 0x80 {
					tokenizing_error(&t, rx_start, t.index); error = true; break
				}
				if rx_pos == rx_start && t.code_point == '?' {
					tokenizing_error(&t, rx_start, t.index); error = true; break
				}
				if t.code_point == '\\' {
					if rx_pos == n - 1 {
						tokenizing_error(&t, rx_start, t.index); error = true; break
					}
					get_next_code_point(&t)
					if t.code_point < 0 || t.code_point >= 0x80 {
						tokenizing_error(&t, rx_start, t.index); error = true; break
					}
					rx_pos = t.next_index
					continue
				}
				if t.code_point == ')' {
					depth -= 1
					if depth == 0 { rx_pos = t.next_index; break }
				} else if t.code_point == '(' {
					depth += 1
					if rx_pos == n - 1 {
						tokenizing_error(&t, rx_start, t.index); error = true; break
					}
					temp := t.next_index
					get_next_code_point(&t)
					if t.code_point != '?' {
						tokenizing_error(&t, rx_start, t.index); error = true; break
					}
					t.next_index = temp
				}
				rx_pos = t.next_index
			}
			if error {
				if !t.ok { return t.tokens, false }
				continue
			}
			if depth != 0 {
				tokenizing_error(&t, rx_start, t.index)
				if !t.ok { return t.tokens, false }
				continue
			}
			rx_len := rx_pos - rx_start - 1
			if rx_len == 0 {
				tokenizing_error(&t, rx_start, t.index)
				if !t.ok { return t.tokens, false }
				continue
			}
			add_token(&t, .Regexp, rx_pos, rx_start, rx_len)
			continue
		case:
			add_token_default(&t, .Char)
			continue
		}
	}
	add_token_default_len(&t, .End, t.index, t.index)
	return t.tokens, t.ok
}

////////////////////////////////
// §2.1.3 / §2.1.5 Parts and the pattern parser.

Part_Kind :: enum u8 { Fixed_Text, Regexp, Segment_Wildcard, Full_Wildcard }
Part_Modifier :: enum u8 { None, Optional, Zero_Or_More, One_Or_More }

Part :: struct {
	kind:     Part_Kind,
	value:    string,   // owned: the regexp source for Regexp, the fixed text for Fixed_Text
	modifier: Part_Modifier,
	name:     string,   // owned
	prefix:   string,   // owned
	suffix:   string,   // owned
}

part_list_destroy :: proc(parts: []Part) {
	for p in parts { delete(p.value); delete(p.name); delete(p.prefix); delete(p.suffix) }
	delete(parts)
}

// The encoding callback (§3.1): validates and encodes a fixed text piece for a given component kind. Returns the
// encoded string (owned) and ok=false on a canonicalization failure (a TypeError upstream).
Encoding :: enum u8 { None, Protocol, Username, Password, Hostname, IPv6_Hostname, Port, Pathname, Opaque_Pathname, Search, Hash }

@(private = "file")
Pattern_Parser :: struct {
	tokens:        []Token,
	encoding:      Encoding,
	seg_wildcard:  string,    // generated segment wildcard regexp, e.g. "[^/]+?"
	parts:         [dynamic]Part,
	pending:       strings.Builder,   // pending fixed value
	index:         int,
	next_numeric:  int,
	prefix_cp:     string,    // options' prefix code point ("" or one ASCII char)
	ok:            bool,
}

FULL_WILDCARD_REGEXP :: ".*"

// §2.1.5 "generate a segment wildcard regexp".
@(private = "file")
segment_wildcard_regexp :: proc(delimiter: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "[^")
	escape_regexp_string(&b, delimiter)
	strings.write_string(&b, "]+?")
	return strings.to_string(b)
}

@(private = "file")
pp_try_consume :: proc(p: ^Pattern_Parser, kind: Token_Kind) -> (Token, bool) {
	if p.index >= len(p.tokens) { return {}, false }
	tok := p.tokens[p.index]
	if tok.kind != kind { return {}, false }
	p.index += 1
	return tok, true
}

@(private = "file")
pp_try_consume_modifier :: proc(p: ^Pattern_Parser) -> (Token, bool) {
	if tok, ok := pp_try_consume(p, .Other_Modifier); ok { return tok, true }
	return pp_try_consume(p, .Asterisk)
}

@(private = "file")
pp_try_consume_regexp_or_wildcard :: proc(p: ^Pattern_Parser, had_name: bool) -> (Token, bool) {
	if tok, ok := pp_try_consume(p, .Regexp); ok { return tok, true }
	if !had_name { return pp_try_consume(p, .Asterisk) }
	return {}, false
}

@(private = "file")
pp_consume_required :: proc(p: ^Pattern_Parser, kind: Token_Kind) -> bool {
	_, ok := pp_try_consume(p, kind)
	if !ok { p.ok = false }
	return ok
}

@(private = "file")
pp_consume_text :: proc(p: ^Pattern_Parser, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for {
		tok, ok := pp_try_consume(p, .Char)
		if !ok { tok, ok = pp_try_consume(p, .Escaped_Char) }
		if !ok { break }
		strings.write_string(&b, tok.value)
	}
	return strings.to_string(b)
}

@(private = "file")
pp_duplicate_name :: proc(p: ^Pattern_Parser, name: string) -> bool {
	for part in p.parts { if part.name == name { return true } }
	return false
}

// §2.1.5 "maybe add a part from the pending fixed value".
@(private = "file")
pp_maybe_add_fixed :: proc(p: ^Pattern_Parser) {
	s := strings.to_string(p.pending)
	if s == "" { return }
	encoded, ok := encode_part(p.encoding, s)
	strings.builder_reset(&p.pending)
	if !ok { p.ok = false; return }
	append(&p.parts, Part{kind = .Fixed_Text, value = encoded, modifier = .None})
}

// §2.1.5 "add a part".
@(private = "file")
pp_add_part :: proc(p: ^Pattern_Parser, prefix: string, name_tok: Maybe(Token), rx_tok: Maybe(Token), suffix: string, mod_tok: Maybe(Token)) {
	modifier := Part_Modifier.None
	if mt, has := mod_tok.?; has {
		switch mt.value {
		case "?": modifier = .Optional
		case "*": modifier = .Zero_Or_More
		case "+": modifier = .One_Or_More
		}
	}
	_, has_name := name_tok.?
	_, has_rx := rx_tok.?
	if !has_name && !has_rx && modifier == .None {
		strings.write_string(&p.pending, prefix)
		return
	}
	pp_maybe_add_fixed(p)
	if p.ok == false { return }
	if !has_name && !has_rx {
		// a "{foo}?" grouping: add the prefix as a modified fixed-text part immediately
		if prefix == "" { return }
		encoded, ok := encode_part(p.encoding, prefix)
		if !ok { p.ok = false; return }
		append(&p.parts, Part{kind = .Fixed_Text, value = encoded, modifier = modifier})
		return
	}
	// convert the regexp-or-wildcard token to a regexp value and a part kind
	rx_value := ""
	rt, _ := rx_tok.?
	if !has_rx {
		rx_value = p.seg_wildcard
	} else if rt.kind == .Asterisk {
		rx_value = FULL_WILDCARD_REGEXP
	} else {
		rx_value = rt.value
	}
	kind := Part_Kind.Regexp
	if rx_value == p.seg_wildcard {
		kind = .Segment_Wildcard
		rx_value = ""
	} else if rx_value == FULL_WILDCARD_REGEXP {
		kind = .Full_Wildcard
		rx_value = ""
	}
	name := ""
	if nt, has := name_tok.?; has {
		name = nt.value
	} else if has_rx {
		buf: [24]u8
		name = uint_to_string(u64(p.next_numeric), buf[:])
		p.next_numeric += 1
	}
	if pp_duplicate_name(p, name) { p.ok = false; return }
	enc_prefix, ok1 := encode_part(p.encoding, prefix)
	if !ok1 { p.ok = false; return }
	enc_suffix, ok2 := encode_part(p.encoding, suffix)
	if !ok2 { delete(enc_prefix); p.ok = false; return }
	append(&p.parts, Part{
		kind = kind, value = strings.clone(rx_value), modifier = modifier,
		name = strings.clone(name), prefix = enc_prefix, suffix = enc_suffix,
	})
}

// §2.1.5 "parse a pattern string": the component pattern string `input` into an owned part list. ok=false on a
// malformed pattern or a canonicalization failure (a TypeError upstream). The parts own their strings.
parse_pattern :: proc(input: string, encoding: Encoding, delimiter, prefix_cp: string, allocator := context.allocator) -> (parts: []Part, ok: bool) {
	toks, tok_ok := tokenize(input, .Strict, context.temp_allocator)
	if !tok_ok { return nil, false }
	p: Pattern_Parser
	p.tokens = toks[:]
	p.encoding = encoding
	p.seg_wildcard = segment_wildcard_regexp(delimiter)
	p.parts = make([dynamic]Part, allocator)
	p.pending = strings.builder_make(context.temp_allocator)
	p.prefix_cp = prefix_cp
	p.ok = true

	for p.index < len(p.tokens) && p.ok {
		char_tok, has_char := pp_try_consume(&p, .Char)
		name_tok, has_name := pp_try_consume(&p, .Name)
		rx_tok, has_rx := pp_try_consume_regexp_or_wildcard(&p, has_name)
		if has_name || has_rx {
			prefix := has_char ? char_tok.value : ""
			if prefix != "" && prefix != p.prefix_cp {
				strings.write_string(&p.pending, prefix)
				prefix = ""
			}
			pp_maybe_add_fixed(&p)
			mod_tok, has_mod := pp_try_consume_modifier(&p)
			pp_add_part(&p, prefix,
				has_name ? name_tok : nil, has_rx ? rx_tok : nil, "",
				has_mod ? mod_tok : nil)
			continue
		}
		fixed_tok := char_tok
		has_fixed := has_char
		if !has_fixed { fixed_tok, has_fixed = pp_try_consume(&p, .Escaped_Char) }
		if has_fixed {
			strings.write_string(&p.pending, fixed_tok.value)
			continue
		}
		open_tok, has_open := pp_try_consume(&p, .Open)
		_ = open_tok
		if has_open {
			prefix := pp_consume_text(&p)
			name_tok2, has_name2 := pp_try_consume(&p, .Name)
			rx_tok2, has_rx2 := pp_try_consume_regexp_or_wildcard(&p, has_name2)
			suffix := pp_consume_text(&p)
			if !pp_consume_required(&p, .Close) { break }
			mod_tok2, has_mod2 := pp_try_consume_modifier(&p)
			pp_add_part(&p, prefix,
				has_name2 ? name_tok2 : nil, has_rx2 ? rx_tok2 : nil, suffix,
				has_mod2 ? mod_tok2 : nil)
			continue
		}
		pp_maybe_add_fixed(&p)
		if !pp_consume_required(&p, .End) { break }
	}
	if !p.ok {
		part_list_destroy(p.parts[:])
		return nil, false
	}
	return p.parts[:], true
}

// §2.2 "escape a regexp string" (used when generating the pattern string / regexp source).
escape_regexp_string :: proc(b: ^strings.Builder, input: string) {
	for i in 0 ..< len(input) {
		c := input[i]
		switch c {
		case '.', '+', '*', '?', '^', '$', '{', '}', '(', ')', '[', ']', '|', '/', '\\':
			strings.write_byte(b, '\\')
		}
		strings.write_byte(b, c)
	}
}
