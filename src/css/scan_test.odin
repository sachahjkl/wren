package css

import "core:testing"
import "wb:base"

@(private = "file")
OPT :: Parse_Options{max_nesting_depth = 512, max_rules = 100_000, max_errors_kept = 100}

// Every length up to 64 (blocks of 16 and the bytes after them), filled with `fill`, and each with `special` at every
// position: the block scans and their scalar references must agree.
@(test)
block_scans_match_their_scalar_references :: proc(t: ^testing.T) {
	buf: [64]u8
	arena: base.Arena
	_ = base.arena_init_growing(&arena)
	defer base.arena_destroy(&arena)
	a := base.arena_allocator(&arena)
	Case :: struct { fill: u8, specials: []u8 }
	cases := [?]Case{
		{'a', []u8{' ', '(', '\\', 0x80, 0xC3, '-', '_', '9', 'Z', '{', '`', '@', '[', '/'}},
		{' ', []u8{'x', '\n', '\t', '*', '"'}},
		{'x', []u8{'*', '/', '"', '\'', '\\', '\n', 0, '\f', '\r', 0xFF}},
		{0xA9, []u8{'a', '\n', '*', '"'}},
	}
	for c in cases {
		for n in 0 ..= len(buf) {
			for at in -1 ..< n {
				for sp in c.specials {
					for i in 0 ..< n { buf[i] = c.fill }
					if at >= 0 { buf[at] = sp }
					// a comment end needs a `/` after its `*`: put one after every special `*`
					if sp == '*' && at >= 0 && at + 1 < n { buf[at + 1] = '/' }
					s := string(buf[:n])
					for from in ([?]int{0, 1, 15, 16, 17}) {
						if from > n { continue }
						testing.expectf(t, name_end(s, from) == name_end_scalar(s, from), "name_end %v from %d", buf[:n], from)
						testing.expectf(t, ws_end(s, from) == ws_end_scalar(s, from), "ws_end %v from %d", buf[:n], from)
						testing.expectf(t, comment_end(s, from) == comment_end_scalar(s, from), "comment_end %v from %d", buf[:n], from)
						testing.expectf(t, string_end(s, from, '"') == string_end_scalar(s, from, '"'), "string_end %v from %d", buf[:n], from)
						testing.expectf(t, string_end(s, from, '\'') == string_end_scalar(s, from, '\''), "string_end ' %v from %d", buf[:n], from)
					}
					testing.expectf(t, control_index(s) == control_index_scalar(s), "control_index %v", buf[:n])
					got := newline_offsets(s, a)
					ref := newline_offsets_scalar(s, a)
					same := len(got) == len(ref)
					if same { for i in 0 ..< len(got) { if got[i] != ref[i] { same = false } } }
					testing.expectf(t, same, "newline_offsets %v: %v %v", buf[:n], got, ref)
					base.arena_free_all(&arena)
				}
			}
		}
	}
}

// CR, CRLF and FF are line feeds, NUL and ill-formed UTF-8 U+FFFD; a clean input is not copied.
@(test)
preprocessing_in_bytes :: proc(t: ^testing.T) {
	clean_in := "a { color: café }"
	out, clean := preprocess(clean_in, context.temp_allocator)
	testing.expect(t, clean && raw_data(out) == raw_data(clean_in), "a clean input is read where it is")
	Case :: struct { input, want: string }
	cases := [?]Case{
		{"a\r\nb\rc\fd", "a\nb\nc\nd"},
		{"x\x00y", "x\uFFFDy"},
		{"\xC3(", "\uFFFD("},               // a lead byte without its continuation
		{"\xED\xA0\x80", "\uFFFD\uFFFD\uFFFD"},   // an encoded surrogate: three ill-formed bytes
		{"\xF0\x9F\x98\x80\r", "\U0001F600\n"},
		{"\r\r\n", "\n\n"},
	}
	for c in cases {
		got, was_clean := preprocess(c.input, context.temp_allocator)
		testing.expectf(t, !was_clean && got == c.want, "%q: %q", c.input, got)
	}
}

// Token positions are byte offsets in the preprocessed source; names and strings without escapes are substrings of a
// sheet's source, those with escapes copies.
@(test)
tokens_on_bytes :: proc(t: ^testing.T) {
	toks, src := tokenize_with_source(`é.x "q\"r" 'ok' /* c */ 10px`, context.temp_allocator, context.temp_allocator)
	want := [?]struct { kind: Token_Kind, text: string, pos: u32 }{
		{.Ident, "é", 0}, {.Delim, ".", 2}, {.Ident, "x", 3}, {.Whitespace, "", 4}, {.String, `q"r`, 5}, {.Whitespace, "", 11},
		{.String, "ok", 12}, {.Whitespace, "", 16}, {.Whitespace, "", 24}, {.Dimension, "px", 25},
	}
	testing.expect_value(t, len(toks), len(want))
	for w, i in want {
		if i >= len(toks) { break }
		testing.expectf(t, toks[i].kind == w.kind && toks[i].text == w.text && toks[i].pos == w.pos, "token %d: %v", i, toks[i])
	}
	testing.expect_value(t, len(src), len(`é.x "q\"r" 'ok' /* c */ 10px`))

	// a sheet's texts point into its source
	s := parse_stylesheet(".box { font-family: \"Fira Sans\", sans-serif; content: \"a\\62 c\" }", OPT)
	defer { stylesheet_destroy(s); free(s) }
	lo, hi := uintptr(raw_data(s.source)), uintptr(raw_data(s.source)) + uintptr(len(s.source))
	inside :: proc(text: string, lo, hi: uintptr) -> bool { p := uintptr(raw_data(text)); return p >= lo && p < hi }
	d := s.rules[0].declarations
	testing.expect(t, len(d) == 2, "two declarations")
	if len(d) == 2 {
		testing.expect(t, inside(d[0].value[0].tok.text, lo, hi) && d[0].value[0].tok.text == "Fira Sans", "a string without escapes is the source's")
		testing.expect(t, !inside(d[1].value[0].tok.text, lo, hi) && d[1].value[0].tok.text == "abc", "a string with escapes is a copy")
	}

	// a sheet with CRLF line ends: its texts are copies of the preprocessed source, which is dropped
	s2 := parse_stylesheet(".a {\r\n  color: red\r\n}\r\n.b { color: blue }", OPT)
	defer { stylesheet_destroy(s2); free(s2) }
	testing.expect_value(t, len(s2.rules), 2)
	if len(s2.rules) == 2 {
		testing.expect_value(t, s2.rules[0].declarations[0].value[0].tok.text, "red")
		testing.expect_value(t, line_of(s2, s2.rules[1].pos), 4)
	}
}

// Lines and raw values count bytes: characters of several bytes before a rule move neither.
@(test)
lines_and_raw_values_in_bytes :: proc(t: ^testing.T) {
	s := parse_stylesheet("/* ééé */\n.a { color: red }\n/* 😀 */ .b\n{ }\n@font-face { font-family: \"x\"; unicode-range: U+0E00-0E7F, U+4??; src: local(\"ü\") }", OPT)
	defer { stylesheet_destroy(s); free(s) }
	testing.expect_value(t, len(s.rules), 3)
	if len(s.rules) != 3 { return }
	testing.expect_value(t, line_of(s, s.rules[0].pos), 2)
	testing.expect_value(t, line_of(s, s.rules[1].pos), 3)
	ff := s.rules[2]
	testing.expect_value(t, len(ff.declarations), 3)
	if len(ff.declarations) == 3 {
		testing.expect_value(t, ff.declarations[1].raw, "U+0E00-0E7F, U+4??")
		testing.expect_value(t, ff.declarations[2].raw, `local("ü")`)
	}
	// an insertRule text: its own positions
	r, _ := parse_rule_into(s, "  .c { color: blue }", OPT)
	testing.expect(t, r != nil && r.pos == 2, "a rule's offset in its text")
}
