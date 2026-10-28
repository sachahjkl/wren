package frontend

import "base:runtime"
import ucd "wb:engine/unicode"

// Regexp literals compile to libregexp bytecode, the constant QuickJS stores next to the pattern source and that
// the runtime's RegExp objects execute. This is QuickJS-ng 0.17's lre_compile: the same parser (same accepted
// syntax, same SyntaxError verdicts) and the same emitter (same bytes), over the Unicode data of the `ucd`
// package. Character sets follow libunicode's CharRange conventions (half-open intervals, an inverted set ends
// at 0xFFFFFFFF), because re_emit_range encodes that convention in the bytecode.

REOP :: enum u8 {
	invalid, char, char_i, char32, char32_i, dot, any, space, not_space,
	line_start, line_start_m, line_end, line_end_m,
	goto, split_goto_first, split_next_first, match, lookahead_match, negative_lookahead_match,
	save_start, save_end, save_reset, loop,
	loop_split_goto_first, loop_split_next_first, loop_check_adv_split_goto_first, loop_check_adv_split_next_first,
	set_i32, word_boundary, word_boundary_i, not_word_boundary, not_word_boundary_i,
	back_reference, back_reference_i, backward_back_reference, backward_back_reference_i,
	range, range_i, range32, range32_i, lookahead, negative_lookahead, set_char_pos, check_advance, prev,
}

@(rodata)
reop_size := [REOP]u8 {
	.invalid = 1, .char = 3, .char_i = 3, .char32 = 5, .char32_i = 5, .dot = 1, .any = 1, .space = 1, .not_space = 1,
	.line_start = 1, .line_start_m = 1, .line_end = 1, .line_end_m = 1,
	.goto = 5, .split_goto_first = 5, .split_next_first = 5, .match = 1, .lookahead_match = 1, .negative_lookahead_match = 1,
	.save_start = 2, .save_end = 2, .save_reset = 3, .loop = 6,
	.loop_split_goto_first = 10, .loop_split_next_first = 10, .loop_check_adv_split_goto_first = 10, .loop_check_adv_split_next_first = 10,
	.set_i32 = 6, .word_boundary = 1, .word_boundary_i = 1, .not_word_boundary = 1, .not_word_boundary_i = 1,
	.back_reference = 2, .back_reference_i = 2, .backward_back_reference = 2, .backward_back_reference_i = 2,
	.range = 3, .range_i = 3, .range32 = 3, .range32_i = 3, .lookahead = 5, .negative_lookahead = 5,
	.set_char_pos = 2, .check_advance = 2, .prev = 1,
}

LRE_FLAG_GLOBAL :: 1 << 0
LRE_FLAG_IGNORECASE :: 1 << 1
LRE_FLAG_MULTILINE :: 1 << 2
LRE_FLAG_DOTALL :: 1 << 3
LRE_FLAG_UNICODE :: 1 << 4
LRE_FLAG_STICKY :: 1 << 5
LRE_FLAG_INDICES :: 1 << 6
LRE_FLAG_NAMED_GROUPS :: 1 << 7
LRE_FLAG_UNICODE_SETS :: 1 << 8
LRE_GROUP_NAME_TRAILER_LEN :: 2

@(private = "file") CAPTURE_COUNT_MAX :: 255
@(private = "file") REGISTER_COUNT_MAX :: 255
@(private = "file") GROUP_NAME_SCOPE_MAX :: 255
@(private = "file") RE_HEADER_LEN :: 8
@(private = "file") CLASS_RANGE_BASE :: 0x40000000
@(private = "file") CHAR_RANGE_d :: 0
@(private = "file") CHAR_RANGE_D :: 1
@(private = "file") CHAR_RANGE_s :: 2
@(private = "file") CHAR_RANGE_S :: 3
@(private = "file") CHAR_RANGE_w :: 4
@(private = "file") CHAR_RANGE_W :: 5

// --- CharRange (libunicode semantics) -----------------------------------------------------------------------

Cr :: struct {
	points: [dynamic]u32,
}

Cr_Op :: enum u8 {union_, inter, xor, sub}

@(private = "file")
cr_new :: proc(a: runtime.Allocator) -> Cr {
	return Cr{points = make([dynamic]u32, 0, 8, a)}
}

@(private = "file")
cr_compress :: proc(cr: ^Cr) {
	pt := cr.points[:]
	n := len(pt)
	i, k := 0, 0
	for i + 1 < n {
		if pt[i] == pt[i + 1] {
			i += 2
		} else {
			j := i
			for j + 3 < n && pt[j + 1] == pt[j + 2] {j += 2}
			pt[k] = pt[i]
			pt[k + 1] = pt[j + 1]
			k += 2
			i = j + 2
		}
	}
	resize(&cr.points, k)
}

@(private = "file")
cr_op_pts :: proc(cr: ^Cr, a, b: []u32, op: Cr_Op) {
	ai, bi := 0, 0
	for {
		v: u32
		if ai < len(a) && bi < len(b) {
			if a[ai] < b[bi] {
				v = a[ai]; ai += 1
			} else if a[ai] == b[bi] {
				v = a[ai]; ai += 1; bi += 1
			} else {
				v = b[bi]; bi += 1
			}
		} else if ai < len(a) {
			v = a[ai]; ai += 1
		} else if bi < len(b) {
			v = b[bi]; bi += 1
		} else {
			break
		}
		is_in: int
		switch op {
		case .union_: is_in = (ai & 1) | (bi & 1)
		case .inter: is_in = (ai & 1) & (bi & 1)
		case .xor: is_in = (ai & 1) ~ (bi & 1)
		case .sub: is_in = (ai & 1) & ((bi & 1) ~ 1)
		}
		if is_in != (len(cr.points) & 1) {
			append(&cr.points, v)
		}
	}
	cr_compress(cr)
}

@(private = "file")
cr_op1 :: proc(cr: ^Cr, b: []u32, op: Cr_Op, a: runtime.Allocator) {
	old := cr.points
	cr.points = make([dynamic]u32, 0, len(old) + len(b), a)
	cr_op_pts(cr, old[:], b, op)
}

@(private = "file")
cr_add_interval :: proc(cr: ^Cr, c1, c2: u32) {
	append(&cr.points, c1, c2)
}

// cr_union_interval adds the closed interval [c1, c2].
@(private = "file")
cr_union_interval :: proc(cr: ^Cr, c1, c2: u32, a: runtime.Allocator) {
	b := [2]u32{c1, c2 + 1}
	cr_op1(cr, b[:], .union_, a)
}

@(private = "file")
cr_invert :: proc(cr: ^Cr) {
	n := len(cr.points)
	resize(&cr.points, n + 2)
	for i := n; i > 0; i -= 1 {cr.points[i] = cr.points[i - 1]}
	cr.points[0] = 0
	cr.points[n + 1] = max(u32)
	cr_compress(cr)
}

// cr_regexp_canonicalize maps a set through the regexp case folding (lre_canonicalize). Only code points with a
// case mapping can change, and none is above 0x20000; everything else is kept as is.
CANON_LIMIT :: 0x20000

@(private = "file")
cr_regexp_canonicalize :: proc(cr: ^Cr, is_unicode: bool, a: runtime.Allocator) {
	low := [2]u32{0, CANON_LIMIT}
	inter := cr_new(a)
	cr_op_pts(&inter, cr.points[:], low[:], .inter)
	rest := cr_new(a)
	cr_op_pts(&rest, cr.points[:], low[:], .sub)
	res := cr_new(a)
	for i := 0; i < len(inter.points); i += 2 {
		for c := inter.points[i]; c < inter.points[i + 1]; c += 1 {
			d := lre_canonicalize(c, is_unicode)
			append(&res.points, d, d + 1)
		}
	}
	cr_sort_and_merge(&res)
	clear(&cr.points)
	cr_op_pts(cr, res.points[:], rest.points[:], .union_)
}

@(private = "file")
cr_sort_and_merge :: proc(cr: ^Cr) {
	n := len(cr.points) / 2
	if n <= 1 {return}
	// sort interval pairs by start (shell sort: no allocation, fine for the sizes produced here)
	gap := n / 2
	for gap > 0 {
		for i in gap ..< n {
			s0, e0 := cr.points[2 * i], cr.points[2 * i + 1]
			j := i
			for j >= gap && cr.points[2 * (j - gap)] > s0 {
				cr.points[2 * j] = cr.points[2 * (j - gap)]
				cr.points[2 * j + 1] = cr.points[2 * (j - gap) + 1]
				j -= gap
			}
			cr.points[2 * j] = s0
			cr.points[2 * j + 1] = e0
		}
		gap /= 2
	}
	w := 0
	i := 0
	for i < n {
		start := cr.points[2 * i]
		end := cr.points[2 * i + 1]
		i += 1
		for i < n {
			s1, e1 := cr.points[2 * i], cr.points[2 * i + 1]
			if s1 > end {break}
			if e1 > end {end = e1}
			i += 1
		}
		cr.points[2 * w] = start
		cr.points[2 * w + 1] = end
		w += 1
	}
	resize(&cr.points, 2 * w)
}

// lre_canonicalize: unicode mode is the simple case folding, except that libunicode's table stores U+FB05 by
// its full (two-letter) folding, so it stays itself, and folds U+FB06 to it by hand; legacy mode takes the full
// uppercase mapping when it is one code point >= 128.
lre_canonicalize :: proc(c: u32, is_unicode: bool) -> u32 {
	if c < 128 {
		return ucd.canonicalize(c, is_unicode)
	}
	if is_unicode {
		switch c {
		case 0xfb05, 0xfb06: return 0xfb05
		}
		return ucd.canonicalize(c, true)
	}
	res: [3]u32
	if ucd.full_case(&res, c, .To_Upper) == 1 && res[0] >= 128 {return res[0]}
	return c
}

// --- string sets (REStringList, for the v flag) -------------------------------------------------------------

@(private = "file")
Re_String :: struct {
	next: ^Re_String,
	hash: u32,
	buf:  []u32,
}

@(private = "file")
Re_String_List :: struct {
	cr:         Cr,
	n_strings:  int,
	hash_bits:  uint,
	hash_table: []^Re_String,
}

@(private = "file")
hash32u :: #force_inline proc(v: u32) -> u32 {
	// cutils.h hash32: multiply by the negated 32-bit golden ratio
	return v * 0x61c88647
}

@(private = "file")
re_string_hash :: proc(buf: []u32) -> u32 {
	h: u32 = 1
	for c in buf {h = h * 263 + c}
	return hash32u(h)
}

@(private = "file")
rsl_init :: proc(s: ^Re_Parser, sl: ^Re_String_List) {
	sl^ = Re_String_List{cr = cr_new(s.allocator)}
}

@(private = "file")
re_string_find2 :: proc(s: ^Re_Parser, sl: ^Re_String_List, buf: []u32, h0: u32, add_flag: bool) -> bool {
	if sl.n_strings != 0 {
		h := h0 >> (32 - sl.hash_bits)
		for p := sl.hash_table[h]; p != nil; p = p.next {
			if p.hash == h0 && len(p.buf) == len(buf) {
				same := true
				for i in 0 ..< len(buf) {
					if p.buf[i] != buf[i] {same = false; break}
				}
				if same {return true}
			}
		}
	}
	if !add_flag {return false}
	if sl.n_strings + 1 > len(sl.hash_table) {
		new_bits := max(sl.hash_bits + 1, 4)
		new_table := make([]^Re_String, 1 << new_bits, s.allocator)
		for i in 0 ..< len(sl.hash_table) {
			p := sl.hash_table[i]
			for p != nil {
				p_next := p.next
				h := p.hash >> (32 - new_bits)
				p.next = new_table[h]
				new_table[h] = p
				p = p_next
			}
		}
		sl.hash_bits = new_bits
		sl.hash_table = new_table
	}
	h := h0 >> (32 - sl.hash_bits)
	p := new(Re_String, s.allocator)
	p.buf = make([]u32, len(buf), s.allocator)
	copy(p.buf, buf)
	p.hash = h0
	p.next = sl.hash_table[h]
	sl.hash_table[h] = p
	sl.n_strings += 1
	return true
}

@(private = "file")
re_string_add :: proc(s: ^Re_Parser, sl: ^Re_String_List, buf: []u32) {
	if len(buf) == 1 {
		cr_union_interval(&sl.cr, buf[0], buf[0], s.allocator)
		return
	}
	re_string_find2(s, sl, buf, re_string_hash(buf), true)
}

@(private = "file")
re_string_list_op :: proc(s: ^Re_Parser, a, b: ^Re_String_List, op: Cr_Op) {
	cr_op1(&a.cr, b.cr.points[:], op, s.allocator)
	#partial switch op {
	case .union_:
		if b.n_strings != 0 {
			for i in 0 ..< len(b.hash_table) {
				for p := b.hash_table[i]; p != nil; p = p.next {
					re_string_find2(s, a, p.buf, p.hash, true)
				}
			}
		}
	case .inter, .sub:
		for i in 0 ..< len(a.hash_table) {
			pp := &a.hash_table[i]
			for {
				p := pp^
				if p == nil {break}
				ret := re_string_find2(s, b, p.buf, p.hash, false)
				if op == .sub {ret = !ret}
				if !ret {
					pp^ = p.next
					a.n_strings -= 1
				} else {
					pp = &p.next
				}
			}
		}
	}
}

@(private = "file")
re_string_list_canonicalize :: proc(s: ^Re_Parser, sl: ^Re_String_List, is_unicode: bool) {
	cr_regexp_canonicalize(&sl.cr, is_unicode, s.allocator)
	if sl.n_strings != 0 {
		old_table := sl.hash_table
		sl.n_strings = 0
		sl.hash_bits = 0
		sl.hash_table = nil
		for i in 0 ..< len(old_table) {
			for p := old_table[i]; p != nil; p = p.next {
				for j in 0 ..< len(p.buf) {
					p.buf[j] = lre_canonicalize(p.buf[j], is_unicode)
				}
				re_string_add(s, sl, p.buf)
			}
		}
	}
}

@(private = "file")
cr_init_char_range :: proc(s: ^Re_Parser, sl: ^Re_String_List, c: u32) {
	rsl_init(s, sl)
	switch c >> 1 {
	case 0:
		append(&sl.cr.points, 0x30, 0x3A)
	case 1:
		append(&sl.cr.points, 0x09, 0x0E, 0x20, 0x21, 0xA0, 0xA1, 0x1680, 0x1681, 0x2000, 0x200B,
			0x2028, 0x202A, 0x202F, 0x2030, 0x205F, 0x2060, 0x3000, 0x3001, 0xFEFF, 0xFF00)
	case 2:
		append(&sl.cr.points, 0x30, 0x3A, 0x41, 0x5B, 0x5F, 0x60, 0x61, 0x7B)
	}
	if (c & 1) != 0 {cr_invert(&sl.cr)}
}

// --- parser state -------------------------------------------------------------------------------------------

Re_Parser :: struct {
	allocator:           runtime.Allocator,
	byte_code:           [dynamic]u8,
	buf:                 []u8, // NUL-padded UTF-8 / CESU-8 pattern
	buf_ptr:             int,
	buf_end:             int,
	buf_start:           int,
	re_flags:            int,
	is_unicode:          bool,
	unicode_sets:        bool,
	ignore_case:         bool,
	multi_line:          bool,
	dotall:              bool,
	group_name_scope:    int,
	capture_count:       int,
	total_capture_count: int,
	has_named_captures:  int,
	group_names:         [dynamic]u8,
	error_msg:           string,
	depth:               int,
	stack:               Stack_Guard,
}

@(private = "file")
re_error :: proc(s: ^Re_Parser, msg: string) -> bool {
	if s.error_msg == "" {s.error_msg = msg}
	return true
}

@(private = "file")
re_emit_op :: proc(s: ^Re_Parser, op: REOP) {append(&s.byte_code, u8(op))}

@(private = "file")
re_put_u32 :: proc(s: ^Re_Parser, v: u32) {append(&s.byte_code, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))}

@(private = "file")
re_put_u16 :: proc(s: ^Re_Parser, v: u32) {append(&s.byte_code, u8(v), u8(v >> 8))}

@(private = "file")
re_emit_op_u32 :: proc(s: ^Re_Parser, op: REOP, val: u32) -> int {
	re_emit_op(s, op)
	pos := len(s.byte_code)
	re_put_u32(s, val)
	return pos
}

@(private = "file")
re_emit_goto :: proc(s: ^Re_Parser, op: REOP, val: u32) -> int {
	re_emit_op(s, op)
	pos := len(s.byte_code)
	re_put_u32(s, val - u32(pos + 4))
	return pos
}

@(private = "file")
re_emit_goto_u8 :: proc(s: ^Re_Parser, op: REOP, arg: u32, val: u32) -> int {
	re_emit_op(s, op)
	append(&s.byte_code, u8(arg))
	pos := len(s.byte_code)
	re_put_u32(s, val - u32(pos + 4))
	return pos
}

@(private = "file")
re_emit_goto_u8_u32 :: proc(s: ^Re_Parser, op: REOP, arg0, arg1: u32, val: u32) -> int {
	re_emit_op(s, op)
	append(&s.byte_code, u8(arg0))
	re_put_u32(s, arg1)
	pos := len(s.byte_code)
	re_put_u32(s, val - u32(pos + 4))
	return pos
}

@(private = "file")
re_emit_op_u8 :: proc(s: ^Re_Parser, op: REOP, val: u32) {
	re_emit_op(s, op)
	append(&s.byte_code, u8(val))
}

@(private = "file")
re_emit_op_u16 :: proc(s: ^Re_Parser, op: REOP, val: u32) {
	re_emit_op(s, op)
	re_put_u16(s, val)
}

@(private = "file")
dbuf_insert :: proc(b: ^[dynamic]u8, pos, n: int) {
	old := len(b)
	resize(b, old + n)
	for i := old - 1; i >= pos; i -= 1 {
		b[i + n] = b[i]
	}
}

@(private = "file")
put_u32_at :: proc(b: []u8, at: int, v: u32) {
	b[at] = u8(v); b[at + 1] = u8(v >> 8); b[at + 2] = u8(v >> 16); b[at + 3] = u8(v >> 24)
}

@(private = "file")
lre_is_digit :: #force_inline proc(c: u8) -> bool {return c >= '0' && c <= '9'}

@(private = "file")
parse_digits :: proc(buf: []u8, pp: ^int, allow_overflow: bool) -> int {
	p := pp^
	v: u64 = 0
	for {
		c := buf[p]
		if c < '0' || c > '9' {break}
		v = v * 10 + u64(c - '0')
		if v >= u64(max(i32)) {
			if allow_overflow {
				v = u64(max(i32))
			} else {
				return -1
			}
		}
		p += 1
	}
	pp^ = p
	return int(v)
}

@(private = "file")
re_parse_expect :: proc(s: ^Re_Parser, pp: ^int, c: u8) -> bool {
	if s.buf[pp^] != c {
		return re_error(s, "expecting a different character")
	}
	pp^ += 1
	return false
}

// utf8_decode_re: utf8_decode_len over the pattern buffer
@(private = "file")
utf8_decode_re :: proc(s: ^Re_Parser, p: int) -> (u32, int) {
	return utf8_decode(s.buf, p)
}

// --- unicode properties -------------------------------------------------------------------------------------

@(private = "file")
is_unicode_char :: proc(c: u8) -> bool {
	return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_'
}

// The property names and aliases libunicode accepts, in its table order; the first name is the one the `ucd`
// tables use (the second one for script extensions, which `ucd` keys by ISO 15924 code).
@(rodata, private = "file")
re_gc_names := [?]string {
	"Cn,Unassigned", "Lu,Uppercase_Letter", "Ll,Lowercase_Letter", "Lt,Titlecase_Letter", "Lm,Modifier_Letter",
	"Lo,Other_Letter", "Mn,Nonspacing_Mark", "Mc,Spacing_Mark", "Me,Enclosing_Mark", "Nd,Decimal_Number,digit",
	"Nl,Letter_Number", "No,Other_Number", "Sm,Math_Symbol", "Sc,Currency_Symbol", "Sk,Modifier_Symbol",
	"So,Other_Symbol", "Pc,Connector_Punctuation", "Pd,Dash_Punctuation", "Ps,Open_Punctuation",
	"Pe,Close_Punctuation", "Pi,Initial_Punctuation", "Pf,Final_Punctuation", "Po,Other_Punctuation",
	"Zs,Space_Separator", "Zl,Line_Separator", "Zp,Paragraph_Separator", "Cc,Control,cntrl", "Cf,Format",
	"Cs,Surrogate", "Co,Private_Use", "LC,Cased_Letter", "L,Letter", "M,Mark,Combining_Mark", "N,Number",
	"S,Symbol", "P,Punctuation,punct", "Z,Separator", "C,Other",
}

@(rodata, private = "file")
re_script_names := [?]string {
	"Adlam,Adlm", "Ahom,Ahom", "Anatolian_Hieroglyphs,Hluw", "Arabic,Arab", "Armenian,Armn", "Avestan,Avst",
	"Balinese,Bali", "Bamum,Bamu", "Bassa_Vah,Bass", "Batak,Batk", "Bengali,Beng", "Beria_Erfe,Berf",
	"Bhaiksuki,Bhks", "Bopomofo,Bopo", "Brahmi,Brah", "Braille,Brai", "Buginese,Bugi", "Buhid,Buhd",
	"Canadian_Aboriginal,Cans", "Carian,Cari", "Caucasian_Albanian,Aghb", "Chakma,Cakm", "Cham,Cham",
	"Cherokee,Cher", "Chorasmian,Chrs", "Common,Zyyy", "Coptic,Copt,Qaac", "Cuneiform,Xsux", "Cypriot,Cprt",
	"Cyrillic,Cyrl", "Cypro_Minoan,Cpmn", "Deseret,Dsrt", "Devanagari,Deva", "Dives_Akuru,Diak", "Dogra,Dogr",
	"Duployan,Dupl", "Egyptian_Hieroglyphs,Egyp", "Elbasan,Elba", "Elymaic,Elym", "Ethiopic,Ethi",
	"Georgian,Geor", "Glagolitic,Glag", "Gothic,Goth", "Garay,Gara", "Grantha,Gran", "Greek,Grek",
	"Gujarati,Gujr", "Gunjala_Gondi,Gong", "Gurmukhi,Guru", "Gurung_Khema,Gukh", "Han,Hani", "Hangul,Hang",
	"Hanifi_Rohingya,Rohg", "Hanunoo,Hano", "Hatran,Hatr", "Hebrew,Hebr", "Hiragana,Hira",
	"Imperial_Aramaic,Armi", "Inherited,Zinh,Qaai", "Inscriptional_Pahlavi,Phli", "Inscriptional_Parthian,Prti",
	"Javanese,Java", "Kaithi,Kthi", "Kannada,Knda", "Katakana,Kana", "Katakana_Or_Hiragana,Hrkt", "Kawi,Kawi",
	"Kayah_Li,Kali", "Kharoshthi,Khar", "Khmer,Khmr", "Khojki,Khoj", "Khitan_Small_Script,Kits",
	"Khudawadi,Sind", "Kirat_Rai,Krai", "Lao,Laoo", "Latin,Latn", "Lepcha,Lepc", "Limbu,Limb", "Linear_A,Lina",
	"Linear_B,Linb", "Lisu,Lisu", "Lycian,Lyci", "Lydian,Lydi", "Makasar,Maka", "Mahajani,Mahj",
	"Malayalam,Mlym", "Mandaic,Mand", "Manichaean,Mani", "Marchen,Marc", "Masaram_Gondi,Gonm",
	"Medefaidrin,Medf", "Meetei_Mayek,Mtei", "Mende_Kikakui,Mend", "Meroitic_Cursive,Merc",
	"Meroitic_Hieroglyphs,Mero", "Miao,Plrd", "Modi,Modi", "Mongolian,Mong", "Mro,Mroo", "Multani,Mult",
	"Myanmar,Mymr", "Nabataean,Nbat", "Nag_Mundari,Nagm", "Nandinagari,Nand", "New_Tai_Lue,Talu", "Newa,Newa",
	"Nko,Nkoo", "Nushu,Nshu", "Nyiakeng_Puachue_Hmong,Hmnp", "Ogham,Ogam", "Ol_Chiki,Olck", "Ol_Onal,Onao",
	"Old_Hungarian,Hung", "Old_Italic,Ital", "Old_North_Arabian,Narb", "Old_Permic,Perm", "Old_Persian,Xpeo",
	"Old_Sogdian,Sogo", "Old_South_Arabian,Sarb", "Old_Turkic,Orkh", "Old_Uyghur,Ougr", "Oriya,Orya",
	"Osage,Osge", "Osmanya,Osma", "Pahawh_Hmong,Hmng", "Palmyrene,Palm", "Pau_Cin_Hau,Pauc", "Phags_Pa,Phag",
	"Phoenician,Phnx", "Psalter_Pahlavi,Phlp", "Rejang,Rjng", "Runic,Runr", "Samaritan,Samr",
	"Saurashtra,Saur", "Sharada,Shrd", "Shavian,Shaw", "Siddham,Sidd", "Sidetic,Sidt", "SignWriting,Sgnw",
	"Sinhala,Sinh", "Sogdian,Sogd", "Sora_Sompeng,Sora", "Soyombo,Soyo", "Sundanese,Sund", "Sunuwar,Sunu",
	"Syloti_Nagri,Sylo", "Syriac,Syrc", "Tagalog,Tglg", "Tagbanwa,Tagb", "Tai_Le,Tale", "Tai_Tham,Lana",
	"Tai_Viet,Tavt", "Tai_Yo,Tayo", "Takri,Takr", "Tamil,Taml", "Tangut,Tang", "Telugu,Telu", "Thaana,Thaa",
	"Thai,Thai", "Tibetan,Tibt", "Tifinagh,Tfng", "Tirhuta,Tirh", "Tangsa,Tnsa", "Todhri,Todr",
	"Tolong_Siki,Tols", "Toto,Toto", "Tulu_Tigalari,Tutg", "Ugaritic,Ugar", "Vai,Vaii", "Vithkuqi,Vith",
	"Wancho,Wcho", "Warang_Citi,Wara", "Yezidi,Yezi", "Yi,Yiii", "Zanabazar_Square,Zanb",
}

@(rodata, private = "file")
re_prop_names := [?]string {
	"ASCII_Hex_Digit,AHex", "Bidi_Control,Bidi_C", "Dash", "Deprecated,Dep", "Diacritic,Dia", "Extender,Ext",
	"Hex_Digit,Hex", "IDS_Unary_Operator,IDSU", "IDS_Binary_Operator,IDSB", "IDS_Trinary_Operator,IDST",
	"Ideographic,Ideo", "Join_Control,Join_C", "Logical_Order_Exception,LOE", "Modifier_Combining_Mark,MCM",
	"Noncharacter_Code_Point,NChar", "Pattern_Syntax,Pat_Syn", "Pattern_White_Space,Pat_WS",
	"Quotation_Mark,QMark", "Radical", "Regional_Indicator,RI", "Sentence_Terminal,STerm", "Soft_Dotted,SD",
	"Terminal_Punctuation,Term", "Unified_Ideograph,UIdeo", "Variation_Selector,VS", "White_Space,space",
	"Bidi_Mirrored,Bidi_M", "Emoji", "Emoji_Component,EComp", "Emoji_Modifier,EMod",
	"Emoji_Modifier_Base,EBase", "Emoji_Presentation,EPres", "Extended_Pictographic,ExtPict",
	"Default_Ignorable_Code_Point,DI", "ID_Start,IDS", "Case_Ignorable,CI", "ASCII", "Alphabetic,Alpha", "Any",
	"Assigned", "Cased", "Changes_When_Casefolded,CWCF", "Changes_When_Casemapped,CWCM",
	"Changes_When_Lowercased,CWL", "Changes_When_NFKC_Casefolded,CWKCF", "Changes_When_Titlecased,CWT",
	"Changes_When_Uppercased,CWU", "Grapheme_Base,Gr_Base", "Grapheme_Extend,Gr_Ext", "ID_Continue,IDC",
	"ID_Compat_Math_Start", "ID_Compat_Math_Continue", "Lowercase,Lower", "Math", "Uppercase,Upper",
	"XID_Continue,XIDC", "XID_Start,XIDS",
}

@(rodata, private = "file")
re_sequence_prop_names := [?]string {
	"Basic_Emoji", "Emoji_Keycap_Sequence", "RGI_Emoji_Modifier_Sequence", "RGI_Emoji_Flag_Sequence",
	"RGI_Emoji_Tag_Sequence", "RGI_Emoji_ZWJ_Sequence", "RGI_Emoji",
}

// re_find_name is unicode_find_name: the index of the entry having `name` among its aliases, or -1.
@(private = "file")
re_find_name :: proc(table: []string, name: string) -> int {
	for entry, idx in table {
		rest := entry
		for len(rest) > 0 {
			i := 0
			for i < len(rest) && rest[i] != ',' {i += 1}
			if rest[:i] == name {return idx}
			rest = rest[min(i + 1, len(rest)):]
		}
	}
	return -1
}

@(private = "file")
re_alias :: proc(entry: string, n: int) -> string {
	rest := entry
	for k := 0; ; k += 1 {
		i := 0
		for i < len(rest) && rest[i] != ',' {i += 1}
		if k == n || i == len(rest) {return rest[:i]}
		rest = rest[i + 1:]
	}
}

@(private = "file")
re_ucd_runs :: proc(tables: []ucd.Named_Table, name: string) -> []ucd.Range_Run {
	for t in tables {
		if t.name == name {return t.runs}
	}
	return nil
}

@(private = "file")
re_add_runs :: proc(s: ^Re_Parser, cr: ^Cr, runs: []ucd.Range_Run) {
	if len(runs) == 0 {return}
	pts := make([]u32, 2 * len(runs), s.allocator)
	for r, i in runs {
		pts[2 * i] = r.lo
		pts[2 * i + 1] = r.hi
	}
	cr_op1(cr, pts, .union_, s.allocator)
}

@(private = "file")
re_unicode_gc :: proc(s: ^Re_Parser, cr: ^Cr, name: string) -> bool {
	idx := re_find_name(re_gc_names[:], name)
	if idx < 0 {return false}
	mask: u32
	switch re_alias(re_gc_names[idx], 0) {
	case "LC": mask = re_gc_mask({"Lu", "Ll", "Lt"})
	case "L": mask = re_gc_mask({"Lu", "Ll", "Lt", "Lm", "Lo"})
	case "M": mask = re_gc_mask({"Mn", "Mc", "Me"})
	case "N": mask = re_gc_mask({"Nd", "Nl", "No"})
	case "S": mask = re_gc_mask({"Sm", "Sc", "Sk", "So"})
	case "P": mask = re_gc_mask({"Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po"})
	case "Z": mask = re_gc_mask({"Zs", "Zl", "Zp"})
	case "C": mask = re_gc_mask({"Cc", "Cf", "Cs", "Co", "Cn"})
	case: mask = 1 << uint(idx)
	}
	re_gc_ranges(s, cr, mask)
	return true
}

@(private = "file")
re_gc_mask :: proc(names: []string) -> u32 {
	m: u32
	for n in names {m |= 1 << uint(re_find_name(re_gc_names[:30], n))}
	return m
}

@(private = "file")
Gc_Run :: struct {
	lo, hi: u32,
	gc:     u8,
}

// re_gc_ranges is unicode_general_category1. libunicode keeps one run per stretch of equal category, plus
// alternating Lu/Ll stretches packed as one run, and adds the matching runs without merging neighbours; that
// segmentation shows in the emitted ranges, so it is rebuilt here from the `ucd` tables as unicode_gen does it.
@(private = "file")
re_gc_ranges :: proc(s: ^Re_Parser, cr: ^Cr, mask: u32) {
	CHARCODE_MAX :: 0x10FFFF
	GC_LU :: 1
	GC_LL :: 2
	runs := make([dynamic]Gc_Run, 0, 4096, s.allocator)
	for t in ucd.general_category_tables {
		g := re_find_name(re_gc_names[:30], t.name)
		if g < 0 {continue}
		for r in t.runs {append(&runs, Gc_Run{r.lo, r.hi, u8(g)})}
	}
	// sort by start (shell sort), then fill the gaps with Cn (0) and merge equal neighbours
	n := len(runs)
	for gap := n / 2; gap > 0; gap /= 2 {
		for i in gap ..< n {
			x := runs[i]
			j := i
			for j >= gap && runs[j - gap].lo > x.lo {
				runs[j] = runs[j - gap]
				j -= gap
			}
			runs[j] = x
		}
	}
	full := make([dynamic]Gc_Run, 0, 2 * n + 2, s.allocator)
	push :: proc(full: ^[dynamic]Gc_Run, r: Gc_Run) {
		if r.lo >= r.hi {return}
		if len(full) > 0 {
			last := &full[len(full) - 1]
			if last.gc == r.gc && last.hi == r.lo {
				last.hi = r.hi
				return
			}
		}
		append(full, r)
	}
	c: u32 = 0
	for r in runs {
		if r.lo > c {push(&full, Gc_Run{c, r.lo, 0})}
		push(&full, r)
		c = r.hi
	}
	if c <= CHARCODE_MAX {push(&full, Gc_Run{c, CHARCODE_MAX + 1, 0})}

	k := 0
	gc_at :: proc(full: []Gc_Run, k: int, c: u32) -> u8 {
		i := k
		for i < len(full) && full[i].hi <= c {i += 1}
		return i < len(full) ? full[i].gc : 0
	}
	i: u32 = 0
	for i <= CHARCODE_MAX {
		for full[k].hi <= i {k += 1}
		v := u32(full[k].gc)
		cnt := full[k].hi - i
		if v == GC_LU {
			n1: u32 = 1
			for i + n1 <= CHARCODE_MAX && u32(gc_at(full[:], k, i + n1)) == GC_LU + (n1 & 1) {n1 += 1}
			if n1 > cnt {
				v = 31
				cnt = n1
			}
		}
		c0 := i
		c1 := i + cnt
		if v == 31 {
			b := mask & ((1 << GC_LU) | (1 << GC_LL))
			if b == (1 << GC_LU) | (1 << GC_LL) {
				cr_add_interval(cr, c0, c1)
			} else if b != 0 {
				if (mask & (1 << GC_LL)) != 0 {c0 += 1}
				for ; c0 < c1; c0 += 2 {cr_add_interval(cr, c0, c0 + 1)}
			}
		} else if (mask >> v) & 1 != 0 {
			cr_add_interval(cr, c0, c1)
		}
		i = c1
	}
}

// re_unicode_script is unicode_script: Script_Extensions adds the characters whose extension list names the
// script, except for Common and Inherited, which keep only their characters that have no extension list.
@(private = "file")
re_unicode_script :: proc(s: ^Re_Parser, cr: ^Cr, name: string, is_ext: bool) -> bool {
	if name == "Unknown" || name == "Zzzz" {
		for t in ucd.script_tables {re_add_runs(s, cr, t.runs)}
		cr_invert(cr)
		return true
	}
	idx := re_find_name(re_script_names[:], name)
	if idx < 0 {return false}
	long := re_alias(re_script_names[idx], 0)
	code := re_alias(re_script_names[idx], 1)
	if !is_ext {
		re_add_runs(s, cr, re_ucd_runs(ucd.script_tables, long))
		return true
	}
	base := cr_new(s.allocator)
	re_add_runs(s, &base, re_ucd_runs(ucd.script_tables, long))
	if long == "Common" || long == "Inherited" {
		listed := cr_new(s.allocator)
		for t in ucd.script_ext_tables {re_add_runs(s, &listed, t.runs)}
		cr_invert(&listed)
		cr_op_pts(cr, base.points[:], listed.points[:], .inter)
	} else {
		ext := cr_new(s.allocator)
		re_add_runs(s, &ext, re_ucd_runs(ucd.script_ext_tables, code))
		cr_op_pts(cr, base.points[:], ext.points[:], .union_)
	}
	return true
}

@(private = "file")
re_unicode_prop :: proc(s: ^Re_Parser, cr: ^Cr, name: string) -> bool {
	idx := re_find_name(re_prop_names[:], name)
	if idx < 0 {return false}
	long := re_alias(re_prop_names[idx], 0)
	switch long {
	case "ASCII":
		cr_add_interval(cr, 0, 0x80)
	case "Any":
		cr_add_interval(cr, 0, 0x110000)
	case "Assigned":
		re_gc_ranges(s, cr, 1)
		cr_invert(cr)
	case "Grapheme_Base":
		// libunicode derives it as the complement of a set, so it runs on past U+10FFFF
		re_add_runs(s, cr, re_ucd_runs(ucd.binary_prop_tables, long))
		hi := [2]u32{0x110000, max(u32)}
		cr_op1(cr, hi[:], .union_, s.allocator)
	case:
		re_add_runs(s, cr, re_ucd_runs(ucd.binary_prop_tables, long))
	}
	return true
}

@(private = "file")
re_unicode_sequence_prop :: proc(s: ^Re_Parser, sl: ^Re_String_List, name: string) -> bool {
	if re_find_name(re_sequence_prop_names[:], name) < 0 {return false}
	for t in ucd.sequence_prop_tables {
		if t.name != name {continue}
		seqs := t.seqs
		for len(seqs) > 0 {
			n := int(seqs[0])
			re_string_add(s, sl, seqs[1:1 + n])
			seqs = seqs[1 + n:]
		}
		return true
	}
	return false
}

@(private = "file")
parse_unicode_property :: proc(s: ^Re_Parser, sl: ^Re_String_List, pp: ^int, is_inv: bool, allow_sequence_prop: bool) -> bool {
	p := pp^
	if s.buf[p] != '{' {
		return re_error(s, "expecting '{' after \\p")
	}
	p += 1
	name_start := p
	for is_unicode_char(s.buf[p]) {
		if p - name_start >= 63 {
			return re_error(s, "unknown unicode property name")
		}
		p += 1
	}
	name := string(s.buf[name_start:p])
	value := ""
	if s.buf[p] == '=' {
		p += 1
		v_start := p
		for is_unicode_char(s.buf[p]) {
			if p - v_start >= 63 {
				return re_error(s, "unknown unicode property value")
			}
			p += 1
		}
		value = string(s.buf[v_start:p])
	}
	if s.buf[p] != '}' {
		return re_error(s, "expecting '}'")
	}
	p += 1

	rsl_init(s, sl)
	if name == "Script" || name == "sc" || name == "Script_Extensions" || name == "scx" {
		is_ext := name == "Script_Extensions" || name == "scx"
		if !re_unicode_script(s, &sl.cr, value, is_ext) {
			return re_error(s, "unknown unicode script")
		}
	} else if name == "General_Category" || name == "gc" {
		if !re_unicode_gc(s, &sl.cr, value) {
			return re_error(s, "unknown unicode general category")
		}
	} else if value == "" {
		if !re_unicode_gc(s, &sl.cr, name) && !re_unicode_prop(s, &sl.cr, name) {
			if is_inv || !allow_sequence_prop || !re_unicode_sequence_prop(s, sl, name) {
				return re_error(s, "unknown unicode property name")
			}
		}
	} else {
		return re_error(s, "unknown unicode property name")
	}

	if s.ignore_case && s.unicode_sets {
		re_string_list_canonicalize(s, sl, s.is_unicode)
	}
	if is_inv {
		cr_invert(&sl.cr)
	}
	if s.ignore_case && !s.unicode_sets {
		re_string_list_canonicalize(s, sl, s.is_unicode)
	}
	pp^ = p
	return false
}

// --- class atoms --------------------------------------------------------------------------------------------

@(private = "file")
parse_class_string_disjunction :: proc(s: ^Re_Parser, sl: ^Re_String_List, pp: ^int) -> bool {
	p := pp^
	if s.buf[p] != '{' {
		return re_error(s, "expecting '{' after \\q")
	}
	rsl_init(s, sl)
	str := make([dynamic]u32, 0, 8, s.allocator)
	p += 1
	for {
		clear(&str)
		for s.buf[p] != '}' && s.buf[p] != '|' {
			c := get_class_atom(s, nil, &p, true)
			if c < 0 {return true}
			append(&str, u32(c))
		}
		re_string_add(s, sl, str[:])
		if s.buf[p] == '}' {break}
		p += 1
	}
	if s.ignore_case {
		re_string_list_canonicalize(s, sl, true)
	}
	p += 1
	pp^ = p
	return false
}

// get_class_atom returns the character, CLASS_RANGE_BASE+n for a class (sl initialized), or -1 on error.
@(private = "file")
get_class_atom :: proc(s: ^Re_Parser, sl: ^Re_String_List, pp: ^int, inclass: bool) -> int {
	p := pp^
	c := u32(s.buf[p])
	normal := false
	switch c {
	case '\\':
		p += 1
		if p >= s.buf_end {
			re_error(s, "unexpected end")
			return -1
		}
		c = u32(s.buf[p])
		p += 1
		default_escape := false
		switch c {
		case 'd', 'D', 's', 'S', 'w', 'W':
			cls: u32
			switch c {
			case 'd': cls = CHAR_RANGE_d
			case 'D': cls = CHAR_RANGE_D
			case 's': cls = CHAR_RANGE_s
			case 'S': cls = CHAR_RANGE_S
			case 'w': cls = CHAR_RANGE_w
			case 'W': cls = CHAR_RANGE_W
			}
			if sl == nil {
				default_escape = true
			} else {
				cr_init_char_range(s, sl, cls)
				c = cls + CLASS_RANGE_BASE
			}
		case 'c':
			c = u32(s.buf[p])
			if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			   (((c >= '0' && c <= '9') || c == '_') && inclass && !s.is_unicode) {
				c &= 0x1f
				p += 1
			} else if s.is_unicode {
				re_error(s, "invalid escape sequence in regular expression")
				return -1
			} else {
				p -= 1
				c = '\\'
			}
		case '-':
			if !inclass && s.is_unicode {
				re_error(s, "invalid escape sequence in regular expression")
				return -1
			}
		case '&', '!', '#', '%', ',', ':', ';', '<', '=', '>', '@', '`', '~':
			if s.is_unicode && (!inclass || !s.unicode_sets) {
				re_error(s, "invalid escape sequence in regular expression")
				return -1
			}
		case '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/':
		case 'p', 'P':
			if s.is_unicode && sl != nil {
				if parse_unicode_property(s, sl, &p, c == 'P', s.unicode_sets) {return -1}
				c = CLASS_RANGE_BASE
			} else {
				default_escape = true
			}
		case 'q':
			if s.unicode_sets && sl != nil && inclass {
				if parse_class_string_disjunction(s, sl, &p) {return -1}
				c = CLASS_RANGE_BASE
			} else {
				default_escape = true
			}
		case:
			default_escape = true
		}
		if default_escape {
			p -= 1
			ret, np := lre_parse_escape(s.buf, p, s.is_unicode ? 2 : 0)
			if ret >= 0 {
				c = u32(ret)
				p = np
			} else {
				if s.is_unicode {
					re_error(s, "invalid escape sequence in regular expression")
					return -1
				}
				// just ignore the '\'
				normal = true
			}
		}
	case 0:
		if p >= s.buf_end {
			re_error(s, "unexpected end")
			return -1
		}
		normal = true
	case '&', '!', '#', '$', '%', '*', '+', ',', '.', ':', ';', '<', '=', '>', '?', '@', '^', '`', '~':
		if s.unicode_sets && u32(s.buf[p + 1]) == c {
			re_error(s, "invalid class set operation in regular expression")
			return -1
		}
		normal = true
	case '(', ')', '[', ']', '{', '}', '/', '-', '|':
		if s.unicode_sets {
			re_error(s, "invalid character in class in regular expression")
			return -1
		}
		normal = true
	case:
		normal = true
	}
	if normal {
		c = u32(s.buf[p])
		if c >= 128 {
			c, p = utf8_decode_re(s, p)
			if c > 0xffff && !s.is_unicode {
				re_error(s, "malformed unicode char")
				return -1
			}
		} else {
			p += 1
		}
	}
	pp^ = p
	return int(c)
}

@(private = "file")
re_emit_range :: proc(s: ^Re_Parser, cr: ^Cr) -> bool {
	n := len(cr.points)
	l := n / 2
	if l >= 65535 {
		return re_error(s, "too many ranges")
	}
	if l == 0 {
		re_emit_op_u32(s, .char32, max(u32))
	} else {
		high := cr.points[n - 1]
		if high == max(u32) {high = cr.points[n - 2]}
		if high <= 0xffff {
			re_emit_op_u16(s, s.ignore_case ? .range_i : .range, u32(l))
			for i := 0; i < n; i += 2 {
				re_put_u16(s, cr.points[i])
				hi := cr.points[i + 1] - 1
				if hi == max(u32) - 1 {hi = 0xffff}
				re_put_u16(s, hi)
			}
		} else {
			re_emit_op_u16(s, s.ignore_case ? .range32_i : .range32, u32(l))
			for i := 0; i < n; i += 2 {
				re_put_u32(s, cr.points[i])
				re_put_u32(s, cr.points[i + 1] - 1)
			}
		}
	}
	return false
}

@(private = "file")
re_emit_char :: proc(s: ^Re_Parser, c: u32) {
	if c <= 0xffff {
		re_emit_op_u16(s, s.ignore_case ? .char_i : .char, c)
	} else {
		re_emit_op_u32(s, s.ignore_case ? .char32_i : .char32, c)
	}
}

@(private = "file")
re_emit_string_list :: proc(s: ^Re_Parser, sl: ^Re_String_List) -> bool {
	if sl.n_strings == 0 {
		return re_emit_range(s, &sl.cr)
	}
	tab := make([dynamic]^Re_String, 0, sl.n_strings, s.allocator)
	has_empty_string := false
	for i in 0 ..< len(sl.hash_table) {
		for p := sl.hash_table[i]; p != nil; p = p.next {
			if len(p.buf) == 0 {
				has_empty_string = true
			} else {
				append(&tab, p)
			}
		}
	}
	// longest strings first; ties keep rqsort's (unstable) order, which the bytecode depends on
	re_rqsort(tab[:])
	last_match_pos := -1
	n := len(tab)
	for i in 0 ..< n {
		p := tab[i]
		is_last := !has_empty_string && len(sl.cr.points) == 0 && i == n - 1
		split_pos := 0
		if !is_last {split_pos = re_emit_op_u32(s, .split_next_first, 0)}
		for ch in p.buf {re_emit_char(s, ch)}
		if !is_last {
			last_match_pos = re_emit_op_u32(s, .goto, u32(i32(last_match_pos)))
			put_u32_at(s.byte_code[:], split_pos, u32(len(s.byte_code) - (split_pos + 4)))
		}
	}
	if len(sl.cr.points) != 0 {
		is_last := !has_empty_string
		split_pos := 0
		if !is_last {split_pos = re_emit_op_u32(s, .split_next_first, 0)}
		if re_emit_range(s, &sl.cr) {return true}
		if !is_last {
			put_u32_at(s.byte_code[:], split_pos, u32(len(s.byte_code) - (split_pos + 4)))
		}
	}
	for last_match_pos != -1 {
		next_pos := int(i32(get_u32(s.byte_code[:], last_match_pos)))
		put_u32_at(s.byte_code[:], last_match_pos, u32(len(s.byte_code) - (last_match_pos + 4)))
		last_match_pos = next_pos
	}
	return false
}

// re_rqsort is cutils.h rqsort (three-way quicksort, heapsort past depth 50, insertion sort below 7 elements)
// with re_string_cmp_len, ported step for step so equal-length strings end up in the same order.
@(private = "file")
re_rqsort :: proc(a: []^Re_String) {
	cmp :: proc(a: []^Re_String, i, j: int) -> int {
		l1, l2 := len(a[i].buf), len(a[j].buf)
		return int(l1 < l2) - int(l1 > l2)
	}
	swap :: proc(a: []^Re_String, i, j: int) {a[i], a[j] = a[j], a[i]}
	swap_block :: proc(a: []^Re_String, i, j, n: int) {
		for k in 0 ..< n {a[i + k], a[j + k] = a[j + k], a[i + k]}
	}
	heapsort :: proc(a: []^Re_String, base, nmemb: int) {
		if nmemb <= 1 {return}
		i := nmemb / 2
		for i > 0 {
			i -= 1
			r := i
			for {
				c := r * 2 + 1
				if c >= nmemb {break}
				if c < nmemb - 1 && cmp(a, base + c, base + c + 1) <= 0 {c += 1}
				if cmp(a, base + r, base + c) > 0 {break}
				swap(a, base + r, base + c)
				r = c
			}
		}
		for i = nmemb - 1; i > 0; i -= 1 {
			swap(a, base, base + i)
			r := 0
			for {
				c := r * 2 + 1
				if c >= i {break}
				if c < i - 1 && cmp(a, base + c, base + c + 1) <= 0 {c += 1}
				if cmp(a, base + r, base + c) > 0 {break}
				swap(a, base + r, base + c)
				r = c
			}
		}
	}
	med3 :: proc(a: []^Re_String, x, y, z: int) -> int {
		if cmp(a, x, y) < 0 {
			return cmp(a, y, z) < 0 ? y : (cmp(a, x, z) < 0 ? z : x)
		}
		return cmp(a, y, z) > 0 ? y : (cmp(a, x, z) < 0 ? x : z)
	}
	Seg :: struct {base, count, depth: int}
	if len(a) < 2 {return}
	stack: [50]Seg
	sp := 0
	stack[sp] = {0, len(a), 0}
	sp += 1
	for sp > 0 {
		sp -= 1
		ptr, nmemb, depth := stack[sp].base, stack[sp].count, stack[sp].depth
		for nmemb > 6 {
			depth += 1
			if depth > 50 {
				heapsort(a, ptr, nmemb)
				nmemb = 0
				break
			}
			m4 := nmemb >> 2
			m := med3(a, ptr + m4, ptr + 2 * m4, ptr + 3 * m4)
			swap(a, ptr, m)
			i, lt := 1, 1
			pi, plt := ptr + 1, ptr + 1
			gt := nmemb
			pj, pgt, top := ptr + nmemb, ptr + nmemb, ptr + nmemb
			for {
				for pi < pj {
					c := cmp(a, ptr, pi)
					if c < 0 {break}
					if c == 0 {
						swap(a, plt, pi)
						lt += 1
						plt += 1
					}
					i += 1
					pi += 1
				}
				for {
					pj -= 1
					if pi >= pj {break}
					c := cmp(a, ptr, pj)
					if c > 0 {break}
					if c == 0 {
						gt -= 1
						pgt -= 1
						swap(a, pgt, pj)
					}
				}
				if pi >= pj {break}
				swap(a, pi, pj)
				i += 1
				pi += 1
			}
			span := plt - ptr
			span2 := pi - plt
			lt = i - lt
			if span > span2 {span = span2}
			swap_block(a, ptr, pi - span, span)
			span = top - pgt
			span2 = pgt - pi
			pgt = top - span2
			gt = nmemb - (gt - i)
			if span > span2 {span = span2}
			swap_block(a, pi, top - span, span)
			if lt > nmemb - gt {
				stack[sp] = {ptr, lt, depth}
				sp += 1
				ptr = pgt
				nmemb -= gt
			} else {
				stack[sp] = {pgt, nmemb - gt, depth}
				sp += 1
				nmemb = lt
			}
		}
		for pi := ptr + 1; pi < ptr + nmemb; pi += 1 {
			for pj := pi; pj > ptr && cmp(a, pj - 1, pj) > 0; pj -= 1 {
				swap(a, pj, pj - 1)
			}
		}
	}
}

@(private = "file")
re_parse_class_set_operand :: proc(s: ^Re_Parser, sl: ^Re_String_List, pp: ^int) -> bool {
	if s.buf[pp^] == '[' {
		if re_parse_nested_class(s, sl, pp) {return true}
	} else {
		c1 := get_class_atom(s, sl, pp, true)
		if c1 < 0 {return true}
		if c1 < CLASS_RANGE_BASE {
			rsl_init(s, sl)
			cc := u32(c1)
			if s.ignore_case {cc = lre_canonicalize(cc, s.is_unicode)}
			cr_union_interval(&sl.cr, cc, cc, s.allocator)
		}
	}
	return false
}

@(private = "file")
re_parse_nested_class :: proc(s: ^Re_Parser, sl: ^Re_String_List, pp: ^int) -> bool {
	s.depth += 1
	defer s.depth -= 1
	if s.depth > 2000 || stack_exhausted(s.stack) {
		return re_error(s, "stack overflow")
	}
	rsl_init(s, sl)
	cr1: Re_String_List
	p := pp^
	p += 1
	invert := false
	if s.buf[p] == '^' {
		p += 1
		invert = true
	}
	is_first := true
	for {
		if s.buf[p] == ']' {break}
		class_union := false
		if s.buf[p] == '[' && s.unicode_sets {
			if re_parse_nested_class(s, &cr1, &p) {return true}
			class_union = true
		} else {
			c1 := get_class_atom(s, &cr1, &p, true)
			if c1 < 0 {return true}
			class_atom := false
			if s.buf[p] == '-' && s.buf[p + 1] != ']' {
				p0 := p + 1
				if s.buf[p + 1] == '-' && s.unicode_sets && is_first {
					class_atom = true
				} else if c1 >= CLASS_RANGE_BASE {
					if s.is_unicode {
						return re_error(s, "invalid class range")
					}
					class_atom = true
				} else {
					c2 := get_class_atom(s, &cr1, &p0, true)
					if c2 < 0 {return true}
					if c2 >= CLASS_RANGE_BASE {
						if s.is_unicode {
							return re_error(s, "invalid class range")
						}
						class_atom = true
					} else {
						p = p0
						if c2 < c1 {
							return re_error(s, "invalid class range")
						}
						if s.ignore_case {
							cr2 := cr_new(s.allocator)
							cr_add_interval(&cr2, u32(c1), u32(c2) + 1)
							cr_regexp_canonicalize(&cr2, s.is_unicode, s.allocator)
							cr_op1(&sl.cr, cr2.points[:], .union_, s.allocator)
						} else {
							cr_union_interval(&sl.cr, u32(c1), u32(c2), s.allocator)
						}
						is_first = false
					}
				}
			} else {
				class_atom = true
			}
			if class_atom {
				if c1 >= CLASS_RANGE_BASE {
					class_union = true
				} else {
					cc := u32(c1)
					if s.ignore_case {cc = lre_canonicalize(cc, s.is_unicode)}
					cr_union_interval(&sl.cr, cc, cc, s.allocator)
				}
			}
		}
		if class_union {
			re_string_list_op(s, sl, &cr1, .union_)
		}
		if s.unicode_sets && is_first {
			if s.buf[p] == '&' && s.buf[p + 1] == '&' && s.buf[p + 2] != '&' {
				for {
					if s.buf[p] == ']' {
						break
					} else if s.buf[p] == '&' && s.buf[p + 1] == '&' && s.buf[p + 2] != '&' {
						p += 2
					} else {
						return re_error(s, "invalid operation in regular expression")
					}
					if re_parse_class_set_operand(s, &cr1, &p) {return true}
					re_string_list_op(s, sl, &cr1, .inter)
				}
			} else if s.buf[p] == '-' && s.buf[p + 1] == '-' {
				for {
					if s.buf[p] == ']' {
						break
					} else if s.buf[p] == '-' && s.buf[p + 1] == '-' {
						p += 2
					} else {
						return re_error(s, "invalid operation in regular expression")
					}
					if re_parse_class_set_operand(s, &cr1, &p) {return true}
					re_string_list_op(s, sl, &cr1, .sub)
				}
			}
		}
		is_first = false
	}
	p += 1
	pp^ = p
	if invert {
		if sl.n_strings != 0 {
			return re_error(s, "negated character class with strings in regular expression debugger eval code")
		}
		cr_invert(&sl.cr)
	}
	return false
}

@(private = "file")
re_parse_char_class :: proc(s: ^Re_Parser, pp: ^int) -> bool {
	sl: Re_String_List
	if re_parse_nested_class(s, &sl, pp) {return true}
	return re_emit_string_list(s, &sl)
}

@(private = "file")
re_need_check_adv_and_capture_init :: proc(pneed_capture_init: ^bool, bc: []u8) -> bool {
	need_check_adv := true
	need_capture_init := false
	pos := 0
	loop: for pos < len(bc) {
		op := REOP(bc[pos])
		l := int(reop_size[op])
		#partial switch op {
		case .range, .range_i:
			l += int(get_u16(bc, pos + 1)) * 4
			need_check_adv = false
		case .range32, .range32_i:
			l += int(get_u16(bc, pos + 1)) * 8
			need_check_adv = false
		case .char, .char_i, .char32, .char32_i, .dot, .any, .space, .not_space:
			need_check_adv = false
		case .line_start, .line_start_m, .line_end, .line_end_m, .set_i32, .set_char_pos, .word_boundary,
		     .word_boundary_i, .not_word_boundary, .not_word_boundary_i, .prev:
		case .save_start, .save_end, .save_reset:
		case .back_reference, .back_reference_i, .backward_back_reference, .backward_back_reference_i:
			l += int(bc[pos + 1])
			need_capture_init = true
		case:
			need_capture_init = true
			break loop
		}
		pos += l
	}
	pneed_capture_init^ = need_capture_init
	return need_check_adv
}

// re_parse_group_name: pp points after '<'. Returns the UTF-8 name, or ok=false.
@(private = "file")
re_parse_group_name :: proc(s: ^Re_Parser, pp: ^int) -> (string, bool) {
	p := pp^
	out := make([dynamic]u8, 0, 16, s.allocator)
	for {
		c := u32(s.buf[p])
		if c == '\\' {
			p += 1
			if s.buf[p] != 'u' {return "", false}
			r, np := lre_parse_escape(s.buf, p, 2)
			if r < 0 {
				c = max(u32)
			} else {
				c = u32(r)
				p = np
			}
		} else if c == '>' {
			break
		} else if c >= 128 {
			c, p = utf8_decode_re(s, p)
			if c >= 0xD800 && c < 0xDC00 {
				d, p1 := utf8_decode_re(s, p)
				if d >= 0xDC00 && d < 0xE000 {
					c = (((c & 0x3FF) << 10) | (d & 0x3FF)) + 0x10000
					p = p1
				}
			}
		} else {
			p += 1
		}
		if c > 0x10FFFF {return "", false}
		if len(out) == 0 {
			if !lre_js_is_ident_first(c) {return "", false}
		} else {
			if !lre_js_is_ident_next(c) {return "", false}
		}
		if len(out) + 4 + 1 > 128 {return "", false}
		utf8_append(&out, c)
	}
	if len(out) == 0 {return "", false}
	p += 1
	pp^ = p
	return string(out[:]), true
}

@(private = "file")
utf8_append :: proc(out: ^[dynamic]u8, c: u32) {
	switch {
	case c < 0x80:
		append(out, u8(c))
	case c < 0x800:
		append(out, u8(0xC0 | (c >> 6)), u8(0x80 | (c & 0x3F)))
	case c < 0x10000:
		append(out, u8(0xE0 | (c >> 12)), u8(0x80 | ((c >> 6) & 0x3F)), u8(0x80 | (c & 0x3F)))
	case:
		append(out, u8(0xF0 | (c >> 18)), u8(0x80 | ((c >> 12) & 0x3F)), u8(0x80 | ((c >> 6) & 0x3F)), u8(0x80 | (c & 0x3F)))
	}
}

@(private = "file")
re_parse_captures :: proc(s: ^Re_Parser, phas_named_captures: ^int, capture_name: string, has_name: bool, emit_group_index: bool) -> int {
	capture_index := 1
	n := 0
	phas_named_captures^ = 0
	buf := s.buf
	outer: for p := s.buf_start; p < s.buf_end; p += 1 {
		switch buf[p] {
		case '(':
			if buf[p + 1] == '?' {
				if buf[p + 2] == '<' && buf[p + 3] != '=' && buf[p + 3] != '!' {
					phas_named_captures^ = 1
					if has_name {
						p += 3
						name, ok := re_parse_group_name(s, &p)
						if ok && name == capture_name {
							if emit_group_index {append(&s.byte_code, u8(capture_index))}
							n += 1
						}
					}
					capture_index += 1
					if capture_index >= CAPTURE_COUNT_MAX {break outer}
				}
			} else {
				capture_index += 1
				if capture_index >= CAPTURE_COUNT_MAX {break outer}
			}
		case '\\':
			p += 1
		case '[':
			p += 1 + (buf[p] == ']' ? 1 : 0)
			for p < s.buf_end && buf[p] != ']' {
				if buf[p] == '\\' {p += 1}
				p += 1
			}
		}
	}
	if has_name {return n}
	return capture_index
}

@(private = "file")
re_count_captures :: proc(s: ^Re_Parser) -> int {
	if s.total_capture_count < 0 {
		s.total_capture_count = re_parse_captures(s, &s.has_named_captures, "", false, false)
	}
	return s.total_capture_count
}

@(private = "file")
re_has_named_captures :: proc(s: ^Re_Parser) -> bool {
	if s.has_named_captures < 0 {re_count_captures(s)}
	return s.has_named_captures != 0
}

// group_names: for each capture, the name (or empty) NUL-terminated, then the scope byte.
@(private = "file")
find_group_name :: proc(s: ^Re_Parser, name: string, emit_group_index: bool) -> int {
	g := s.group_names[:]
	p := 0
	capture_index := 1
	n := 0
	for p < len(g) {
		e := p
		for g[e] != 0 {e += 1}
		if string(g[p:e]) == name {
			if emit_group_index {append(&s.byte_code, u8(capture_index))}
			n += 1
		}
		p = e + LRE_GROUP_NAME_TRAILER_LEN
		capture_index += 1
	}
	return n
}

@(private = "file")
is_duplicate_group_name :: proc(s: ^Re_Parser, name: string, scope: int) -> bool {
	g := s.group_names[:]
	p := 0
	for p < len(g) {
		e := p
		for g[e] != 0 {e += 1}
		if string(g[p:e]) == name {
			if int(g[e + 1]) == scope {return true}
		}
		p = e + LRE_GROUP_NAME_TRAILER_LEN
	}
	return false
}

@(private = "file")
re_parse_modifiers :: proc(s: ^Re_Parser, pp: ^int) -> int {
	p := pp^
	mask := 0
	for {
		val: int
		switch s.buf[p] {
		case 'i': val = LRE_FLAG_IGNORECASE
		case 'm': val = LRE_FLAG_MULTILINE
		case 's': val = LRE_FLAG_DOTALL
		case:
			pp^ = p
			return mask
		}
		if (mask & val) != 0 {
			re_error(s, "duplicate modifier")
			return -1
		}
		mask |= val
		p += 1
	}
}

@(private = "file")
update_modifier :: proc(val: bool, add_mask, remove_mask, mask: int) -> bool {
	v := val
	if (add_mask & mask) != 0 {v = true}
	if (remove_mask & mask) != 0 {v = false}
	return v
}

@(private = "file")
re_parse_term :: proc(s: ^Re_Parser, is_backward_dir: bool) -> bool {
	last_atom_start := -1
	last_capture_count := 0
	p := s.buf_ptr
	buf := s.buf
	c := int(buf[p])
	sl: Re_String_List
	quant_min, quant_max: int
	bwd := is_backward_dir ? 1 : 0

	Next :: enum {none, class_atom, normal_char}
	next := Next.none

	switch c {
	case '^':
		p += 1
		re_emit_op(s, s.multi_line ? .line_start_m : .line_start)
	case '$':
		p += 1
		re_emit_op(s, s.multi_line ? .line_end_m : .line_end)
	case '.':
		p += 1
		last_atom_start = len(s.byte_code)
		last_capture_count = s.capture_count
		if is_backward_dir {re_emit_op(s, .prev)}
		re_emit_op(s, s.dotall ? .any : .dot)
		if is_backward_dir {re_emit_op(s, .prev)}
	case '{', '*', '+', '?':
		if c == '{' {
			if s.is_unicode {
				return re_error(s, "syntax error")
			} else if !lre_is_digit(buf[p + 1]) {
				next = .class_atom
				break
			} else {
				p1 := p + 1
				parse_digits(buf, &p1, true)
				if buf[p1] == ',' {
					p1 += 1
					if lre_is_digit(buf[p1]) {parse_digits(buf, &p1, true)}
				}
				if buf[p1] != '}' {
					next = .class_atom
					break
				}
			}
		}
		return re_error(s, "nothing to repeat")
	case '(':
		if buf[p + 1] == '?' {
			if buf[p + 2] == ':' {
				p += 3
				last_atom_start = len(s.byte_code)
				last_capture_count = s.capture_count
				s.buf_ptr = p
				if re_parse_disjunction(s, is_backward_dir) {return true}
				p = s.buf_ptr
				if re_parse_expect(s, &p, ')') {return true}
			} else if buf[p + 2] == 'i' || buf[p + 2] == 'm' || buf[p + 2] == 's' || buf[p + 2] == '-' {
				p += 2
				remove_mask := 0
				add_mask := re_parse_modifiers(s, &p)
				if add_mask < 0 {return true}
				if buf[p] == '-' {
					p += 1
					remove_mask = re_parse_modifiers(s, &p)
					if remove_mask < 0 {return true}
				}
				if (add_mask == 0 && remove_mask == 0) || (add_mask & remove_mask) != 0 {
					return re_error(s, "invalid modifiers")
				}
				if re_parse_expect(s, &p, ':') {return true}
				saved_ignore_case, saved_multi_line, saved_dotall := s.ignore_case, s.multi_line, s.dotall
				s.ignore_case = update_modifier(s.ignore_case, add_mask, remove_mask, LRE_FLAG_IGNORECASE)
				s.multi_line = update_modifier(s.multi_line, add_mask, remove_mask, LRE_FLAG_MULTILINE)
				s.dotall = update_modifier(s.dotall, add_mask, remove_mask, LRE_FLAG_DOTALL)
				last_atom_start = len(s.byte_code)
				last_capture_count = s.capture_count
				s.buf_ptr = p
				if re_parse_disjunction(s, is_backward_dir) {return true}
				p = s.buf_ptr
				if re_parse_expect(s, &p, ')') {return true}
				s.ignore_case, s.multi_line, s.dotall = saved_ignore_case, saved_multi_line, saved_dotall
			} else if buf[p + 2] == '=' || buf[p + 2] == '!' || (buf[p + 2] == '<' && (buf[p + 3] == '=' || buf[p + 3] == '!')) {
				is_neg: bool
				is_backward_lookahead: bool
				if buf[p + 2] == '<' {
					is_neg = buf[p + 3] == '!'
					is_backward_lookahead = true
					p += 4
				} else {
					is_neg = buf[p + 2] == '!'
					is_backward_lookahead = false
					p += 3
				}
				if !s.is_unicode && !is_backward_lookahead {
					last_atom_start = len(s.byte_code)
					last_capture_count = s.capture_count
				}
				pos := re_emit_op_u32(s, is_neg ? .negative_lookahead : .lookahead, 0)
				s.buf_ptr = p
				if re_parse_disjunction(s, is_backward_lookahead) {return true}
				p = s.buf_ptr
				if re_parse_expect(s, &p, ')') {return true}
				re_emit_op(s, is_neg ? .negative_lookahead_match : .lookahead_match)
				put_u32_at(s.byte_code[:], pos, u32(len(s.byte_code) - (pos + 4)))
			} else if buf[p + 2] == '<' {
				p += 3
				name, ok := re_parse_group_name(s, &p)
				if !ok {
					return re_error(s, "invalid group name")
				}
				if is_duplicate_group_name(s, name, s.group_name_scope) {
					return re_error(s, "duplicate group name")
				}
				append(&s.group_names, ..transmute([]u8)name)
				append(&s.group_names, 0)
				append(&s.group_names, u8(s.group_name_scope))
				s.has_named_captures = 1
				if parse_capture(s, &p, &last_atom_start, &last_capture_count, is_backward_dir) {return true}
			} else {
				return re_error(s, "invalid group")
			}
		} else {
			p += 1
			append(&s.group_names, 0, 0)
			if parse_capture(s, &p, &last_atom_start, &last_capture_count, is_backward_dir) {return true}
		}
	case '\\':
		switch buf[p + 1] {
		case 'b', 'B':
			if buf[p + 1] != 'b' {
				re_emit_op(s, s.ignore_case && s.is_unicode ? .not_word_boundary_i : .not_word_boundary)
			} else {
				re_emit_op(s, s.ignore_case && s.is_unicode ? .word_boundary_i : .word_boundary)
			}
			p += 2
		case 'k':
			p1 := p
			if buf[p1 + 2] != '<' {
				if s.is_unicode || re_has_named_captures(s) {
					return re_error(s, "expecting group name")
				}
				next = .class_atom
				break
			}
			p1 += 3
			name, ok := re_parse_group_name(s, &p1)
			if !ok {
				if s.is_unicode || re_has_named_captures(s) {
					return re_error(s, "invalid group name")
				}
				next = .class_atom
				break
			}
			is_forward := false
			n := find_group_name(s, name, false)
			if n == 0 {
				dummy: int
				n = re_parse_captures(s, &dummy, name, true, false)
				if n == 0 {
					if s.is_unicode || re_has_named_captures(s) {
						return re_error(s, "group name not defined")
					}
					next = .class_atom
					break
				}
				is_forward = true
			}
			last_atom_start = len(s.byte_code)
			last_capture_count = s.capture_count
			re_emit_op_u8(s, REOP(int(REOP.back_reference) + 2 * bwd + (s.ignore_case ? 1 : 0)), u32(n))
			if is_forward {
				dummy: int
				re_parse_captures(s, &dummy, name, true, true)
			} else {
				find_group_name(s, name, true)
			}
			p = p1
		case '0':
			p += 2
			c = 0
			if s.is_unicode {
				if lre_is_digit(buf[p]) {
					return re_error(s, "invalid decimal escape in regular expression")
				}
			} else {
				if buf[p] >= '0' && buf[p] <= '7' {
					c = int(buf[p] - '0'); p += 1
					if buf[p] >= '0' && buf[p] <= '7' {
						c = (c << 3) + int(buf[p] - '0'); p += 1
					}
				}
			}
			next = .normal_char
		case '1' ..= '9':
			p += 1
			q := p
			c = parse_digits(buf, &p, false)
			if c < 0 || (c >= s.capture_count && c >= re_count_captures(s)) {
				if !s.is_unicode {
					p = q
					if buf[p] <= '7' {
						c = 0
						if buf[p] <= '3' {c = int(buf[p] - '0'); p += 1}
						if buf[p] >= '0' && buf[p] <= '7' {
							c = (c << 3) + int(buf[p] - '0'); p += 1
							if buf[p] >= '0' && buf[p] <= '7' {
								c = (c << 3) + int(buf[p] - '0'); p += 1
							}
						}
					} else {
						c = int(buf[p]); p += 1
					}
					next = .normal_char
					break
				}
				return re_error(s, "back reference out of range in regular expression")
			}
			last_atom_start = len(s.byte_code)
			last_capture_count = s.capture_count
			re_emit_op_u8(s, REOP(int(REOP.back_reference) + 2 * bwd + (s.ignore_case ? 1 : 0)), 1)
			append(&s.byte_code, u8(c))
		case:
			next = .class_atom
		}
	case '[':
		last_atom_start = len(s.byte_code)
		last_capture_count = s.capture_count
		if is_backward_dir {re_emit_op(s, .prev)}
		if re_parse_char_class(s, &p) {return true}
		if is_backward_dir {re_emit_op(s, .prev)}
	case ']', '}':
		if s.is_unicode {
			return re_error(s, "syntax error")
		}
		next = .class_atom
	case:
		next = .class_atom
	}

	if next == .class_atom {
		c = get_class_atom(s, &sl, &p, false)
		if c < 0 {return true}
		next = .normal_char
	}
	if next == .normal_char {
		last_atom_start = len(s.byte_code)
		last_capture_count = s.capture_count
		if is_backward_dir {re_emit_op(s, .prev)}
		if c >= CLASS_RANGE_BASE {
			if c == CLASS_RANGE_BASE + CHAR_RANGE_s {
				re_emit_op(s, .space)
			} else if c == CLASS_RANGE_BASE + CHAR_RANGE_S {
				re_emit_op(s, .not_space)
			} else {
				if re_emit_string_list(s, &sl) {return true}
			}
		} else {
			cc := u32(c)
			if s.ignore_case {cc = lre_canonicalize(cc, s.is_unicode)}
			re_emit_char(s, cc)
		}
		if is_backward_dir {re_emit_op(s, .prev)}
	}

	// quantifier
	if last_atom_start >= 0 {
		c = int(buf[p])
		has_quant := false
		switch c {
		case '*':
			p += 1
			quant_min, quant_max = 0, int(max(i32))
			has_quant = true
		case '+':
			p += 1
			quant_min, quant_max = 1, int(max(i32))
			has_quant = true
		case '?':
			p += 1
			quant_min, quant_max = 0, 1
			has_quant = true
		case '{':
			p1 := p
			if !lre_is_digit(buf[p + 1]) {
				if s.is_unicode {
					return re_error(s, "invalid repetition count")
				}
				break
			}
			p += 1
			quant_min = parse_digits(buf, &p, true)
			quant_max = quant_min
			if buf[p] == ',' {
				p += 1
				if lre_is_digit(buf[p]) {
					quant_max = parse_digits(buf, &p, true)
					if quant_max < quant_min {
						return re_error(s, "invalid repetition count")
					}
				} else {
					quant_max = int(max(i32))
				}
			}
			if buf[p] != '}' && !s.is_unicode {
				p = p1
				break
			}
			if re_parse_expect(s, &p, '}') {return true}
			has_quant = true
		}
		if has_quant {
			greedy := true
			if buf[p] == '?' {
				p += 1
				greedy = false
			}
			g := greedy ? 1 : 0
			need_capture_init: bool
			add_zero_advance_check := re_need_check_adv_and_capture_init(&need_capture_init, s.byte_code[last_atom_start:])
			if need_capture_init && last_capture_count != s.capture_count {
				dbuf_insert(&s.byte_code, last_atom_start, 3)
				s.byte_code[last_atom_start] = u8(REOP.save_reset)
				s.byte_code[last_atom_start + 1] = u8(last_capture_count)
				s.byte_code[last_atom_start + 2] = u8(s.capture_count - 1)
			}
			l := len(s.byte_code) - last_atom_start
			azc := add_zero_advance_check ? 1 : 0
			if quant_min == 0 {
				if !need_capture_init && last_capture_count != s.capture_count {
					dbuf_insert(&s.byte_code, last_atom_start, 3)
					s.byte_code[last_atom_start] = u8(REOP.save_reset)
					s.byte_code[last_atom_start + 1] = u8(last_capture_count)
					s.byte_code[last_atom_start + 2] = u8(s.capture_count - 1)
					last_atom_start += 3
				}
				if quant_max == 0 {
					resize(&s.byte_code, last_atom_start)
				} else if quant_max == 1 || quant_max == int(max(i32)) {
					has_goto := quant_max == int(max(i32))
					hg := has_goto ? 1 : 0
					dbuf_insert(&s.byte_code, last_atom_start, 5 + azc * 2)
					s.byte_code[last_atom_start] = u8(int(REOP.split_goto_first) + g)
					put_u32_at(s.byte_code[:], last_atom_start + 1, u32(l + 5 * hg + azc * 2 * 2))
					if add_zero_advance_check {
						s.byte_code[last_atom_start + 1 + 4] = u8(REOP.set_char_pos)
						s.byte_code[last_atom_start + 1 + 4 + 1] = 0
						re_emit_op_u8(s, .check_advance, 0)
					}
					if has_goto {
						re_emit_goto(s, .goto, u32(last_atom_start))
					}
				} else {
					dbuf_insert(&s.byte_code, last_atom_start, 11 + azc * 2)
					pos := last_atom_start
					s.byte_code[pos] = u8(int(REOP.split_goto_first) + g); pos += 1
					put_u32_at(s.byte_code[:], pos, u32(6 + azc * 2 + l + 10)); pos += 4
					s.byte_code[pos] = u8(REOP.set_i32); pos += 1
					s.byte_code[pos] = 0; pos += 1
					put_u32_at(s.byte_code[:], pos, u32(quant_max)); pos += 4
					last_atom_start = pos
					if add_zero_advance_check {
						s.byte_code[pos] = u8(REOP.set_char_pos); pos += 1
						s.byte_code[pos] = 0; pos += 1
					}
					op := add_zero_advance_check ? REOP.loop_check_adv_split_next_first : REOP.loop_split_next_first
					re_emit_goto_u8_u32(s, REOP(int(op) - g), 0, u32(quant_max), u32(last_atom_start))
				}
			} else if quant_min == 1 && quant_max == int(max(i32)) && !add_zero_advance_check {
				re_emit_goto(s, REOP(int(REOP.split_next_first) - g), u32(last_atom_start))
			} else {
				if quant_min == quant_max {
					add_zero_advance_check = false
					azc = 0
				}
				dbuf_insert(&s.byte_code, last_atom_start, 6 + azc * 2)
				pos := last_atom_start
				s.byte_code[pos] = u8(REOP.set_i32); pos += 1
				s.byte_code[pos] = 0; pos += 1
				put_u32_at(s.byte_code[:], pos, u32(quant_max)); pos += 4
				last_atom_start = pos
				if add_zero_advance_check {
					s.byte_code[pos] = u8(REOP.set_char_pos); pos += 1
					s.byte_code[pos] = 0; pos += 1
				}
				if quant_min == quant_max {
					re_emit_goto_u8(s, .loop, 0, u32(last_atom_start))
				} else {
					op := add_zero_advance_check ? REOP.loop_check_adv_split_next_first : REOP.loop_split_next_first
					re_emit_goto_u8_u32(s, REOP(int(op) - g), 0, u32(quant_max - quant_min), u32(last_atom_start))
				}
			}
		}
	}
	s.buf_ptr = p
	return false
}

@(private = "file")
parse_capture :: proc(s: ^Re_Parser, pp: ^int, last_atom_start, last_capture_count: ^int, is_backward_dir: bool) -> bool {
	if s.capture_count >= CAPTURE_COUNT_MAX {
		return re_error(s, "too many captures")
	}
	last_atom_start^ = len(s.byte_code)
	last_capture_count^ = s.capture_count
	capture_index := s.capture_count
	s.capture_count += 1
	bwd := is_backward_dir ? 1 : 0
	re_emit_op_u8(s, REOP(int(REOP.save_start) + bwd), u32(capture_index))
	s.buf_ptr = pp^
	if re_parse_disjunction(s, is_backward_dir) {return true}
	pp^ = s.buf_ptr
	re_emit_op_u8(s, REOP(int(REOP.save_start) + 1 - bwd), u32(capture_index))
	return re_parse_expect(s, pp, ')')
}

@(private = "file")
re_parse_alternative :: proc(s: ^Re_Parser, is_backward_dir: bool) -> bool {
	start := len(s.byte_code)
	for {
		p := s.buf_ptr
		if p >= s.buf_end {break}
		if s.buf[p] == '|' || s.buf[p] == ')' {break}
		term_start := len(s.byte_code)
		if re_parse_term(s, is_backward_dir) {return true}
		if is_backward_dir {
			end := len(s.byte_code)
			term_size := end - term_start
			tmp := make([]u8, term_size, s.allocator)
			copy(tmp, s.byte_code[term_start:end])
			for i := end - 1; i >= start + term_size; i -= 1 {
				s.byte_code[i] = s.byte_code[i - term_size]
			}
			copy(s.byte_code[start:start + term_size], tmp)
		}
	}
	return false
}

@(private = "file")
re_parse_disjunction :: proc(s: ^Re_Parser, is_backward_dir: bool) -> bool {
	s.depth += 1
	defer s.depth -= 1
	if s.depth > 2000 || stack_exhausted(s.stack) {
		return re_error(s, "stack overflow")
	}
	start := len(s.byte_code)
	if re_parse_alternative(s, is_backward_dir) {return true}
	for s.buf[s.buf_ptr] == '|' {
		s.buf_ptr += 1
		l := len(s.byte_code) - start
		dbuf_insert(&s.byte_code, start, 5)
		s.byte_code[start] = u8(REOP.split_next_first)
		put_u32_at(s.byte_code[:], start + 1, u32(l + 5))
		pos := re_emit_op_u32(s, .goto, 0)
		if re_has_named_captures(s) && s.group_name_scope == GROUP_NAME_SCOPE_MAX {
			return re_error(s, "too many named groups")
		}
		s.group_name_scope += 1
		if re_parse_alternative(s, is_backward_dir) {return true}
		l = len(s.byte_code) - (pos + 4)
		put_u32_at(s.byte_code[:], pos, u32(l))
	}
	return false
}

@(private = "file")
compute_register_count :: proc(bc_all: []u8) -> int {
	bc := bc_all[RE_HEADER_LEN:]
	stack_size := 0
	stack_size_max := 0
	pos := 0
	for pos < len(bc) {
		op := REOP(bc[pos])
		l := int(reop_size[op])
		#partial switch op {
		case .set_i32, .set_char_pos:
			bc[pos + 1] = u8(stack_size)
			stack_size += 1
			if stack_size > stack_size_max {
				if stack_size > REGISTER_COUNT_MAX {return -1}
				stack_size_max = stack_size
			}
		case .check_advance, .loop, .loop_split_goto_first, .loop_split_next_first:
			stack_size -= 1
			bc[pos + 1] = u8(stack_size)
		case .loop_check_adv_split_goto_first, .loop_check_adv_split_next_first:
			stack_size -= 2
			bc[pos + 1] = u8(stack_size)
		case .range, .range_i:
			l += int(get_u16(bc, pos + 1)) * 4
		case .range32, .range32_i:
			l += int(get_u16(bc, pos + 1)) * 8
		case .back_reference, .back_reference_i, .backward_back_reference, .backward_back_reference_i:
			l += int(bc[pos + 1])
		}
		pos += l
	}
	return stack_size_max
}

// lre_compile compiles a UTF-8 (unicode mode) or CESU-8 pattern; returns the bytecode or an error message.
lre_compile :: proc(pattern: []u8, re_flags: int, allocator: runtime.Allocator, stack := Stack_Guard{}) -> (bc: []u8, err: string) {
	s := Re_Parser{allocator = allocator, stack = stack}
	buf := make([]u8, len(pattern) + 8, allocator)
	copy(buf, pattern)
	s.buf = buf
	s.buf_ptr = 0
	s.buf_end = len(pattern)
	s.buf_start = 0
	s.re_flags = re_flags
	s.is_unicode = (re_flags & (LRE_FLAG_UNICODE | LRE_FLAG_UNICODE_SETS)) != 0
	is_sticky := (re_flags & LRE_FLAG_STICKY) != 0
	s.ignore_case = (re_flags & LRE_FLAG_IGNORECASE) != 0
	s.multi_line = (re_flags & LRE_FLAG_MULTILINE) != 0
	s.dotall = (re_flags & LRE_FLAG_DOTALL) != 0
	s.unicode_sets = (re_flags & LRE_FLAG_UNICODE_SETS) != 0
	s.capture_count = 1
	s.total_capture_count = -1
	s.has_named_captures = -1
	s.byte_code = make([dynamic]u8, 0, 64 + len(pattern) * 4, allocator)
	s.group_names = make([dynamic]u8, 0, 16, allocator)

	re_put_u16(&s, u32(re_flags))
	append(&s.byte_code, 0, 0)
	re_put_u32(&s, 0)
	if !is_sticky {
		re_emit_op_u32(&s, .split_goto_first, 1 + 5)
		re_emit_op(&s, .any)
		re_emit_op_u32(&s, .goto, ~u32(5 + 1 + 5 - 1))
	}
	re_emit_op_u8(&s, .save_start, 0)
	if re_parse_disjunction(&s, false) {
		return nil, s.error_msg
	}
	re_emit_op_u8(&s, .save_end, 0)
	re_emit_op(&s, .match)
	if s.buf[s.buf_ptr] != 0 {
		return nil, "extraneous characters at the end"
	}
	register_count := compute_register_count(s.byte_code[:])
	if register_count < 0 {
		return nil, "too many imbricated quantifiers"
	}
	s.byte_code[2] = u8(s.capture_count)
	s.byte_code[3] = u8(register_count)
	put_u32_at(s.byte_code[:], 4, u32(len(s.byte_code) - RE_HEADER_LEN))
	if len(s.group_names) > (s.capture_count - 1) * LRE_GROUP_NAME_TRAILER_LEN {
		append(&s.byte_code, ..s.group_names[:])
		flags := int(get_u16(s.byte_code[:], 0)) | LRE_FLAG_NAMED_GROUPS
		s.byte_code[0] = u8(flags)
		s.byte_code[1] = u8(flags >> 8)
	}
	return s.byte_code[:], ""
}
