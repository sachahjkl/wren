package jsrt

// String: the constructor, the statics, String.prototype and the String iterator (ECMA-262 §22.1).
// Case mapping and normalization come from the Unicode tables of src/engine/unicode.

import ucd "wb:engine/unicode"

@(private = "file")
this_str :: proc(ctx: ^Context, this: Value, name: string) -> ^JS_String {
	if this.tag == .string {return as_str(this)}
	if is_nullish(this) {
		throw_type_error(ctx, cat(ctx, "String.prototype.", name, " called on null or undefined"))
		return nil
	}
	return to_str(ctx, this)
}

@(private = "file")
string_ctor :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	s: ^JS_String
	if len(args) == 0 {
		s = rt.empty_string
	} else {
		v := args[0]
		if is_undefined(nt) && v.tag == .symbol {return symbol_descriptive_string(ctx, as_sym(v))}
		s = to_str(ctx, v)
		if s == nil {return EXCEPTION}
	}
	if is_undefined(nt) {return mk_str(s)}
	proto, ok := proto_from_ctor(ctx, nt, .string)
	if !ok {return EXCEPTION}
	o := new_primitive_wrapper(ctx, .string, mk_str(s))
	if proto != ctx.class_proto[.string] {set_object_proto(rt, o, proto)}
	return mk_obj(o)
}

@(private = "file")
string_from_char_code :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	sb := sb_init(ctx.rt, len(args))
	for a in args {
		n, ok := to_uint32(ctx, a)
		if !ok {sb_destroy(&sb); return EXCEPTION}
		sb_unit(&sb, u16(n))
	}
	return sb_finish_value(ctx, &sb)
}

@(private = "file")
string_from_code_point :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	sb := sb_init(ctx.rt, len(args))
	for a in args {
		d, ok := to_number(ctx, a)
		if !ok {sb_destroy(&sb); return EXCEPTION}
		if !f64_is_integer(d) || d < 0 || d > 0x10ffff {
			sb_destroy(&sb)
			return throw_range_error(ctx, "invalid code point")
		}
		sb_code_point(&sb, u32(d))
	}
	return sb_finish_value(ctx, &sb)
}

@(private = "file")
string_raw :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	cooked := to_object(ctx, arg(args, 0))
	if is_exception(cooked) {return EXCEPTION}
	raw := to_object(ctx, get(ctx, cooked, pa(.A_raw)))
	if is_exception(raw) {return EXCEPTION}
	n, ok := length_of_array_like(ctx, raw)
	if !ok {return EXCEPTION}
	sb := sb_init(ctx.rt)
	for i in 0 ..< n {
		s := to_str(ctx, get_index(ctx, raw, i))
		if s == nil {sb_destroy(&sb); return EXCEPTION}
		sb_str(&sb, s)
		if i + 1 < n && int(i + 1) < len(args) {
			sub := to_str(ctx, args[i + 1])
			if sub == nil {sb_destroy(&sb); return EXCEPTION}
			sb_str(&sb, sub)
		}
	}
	return sb_finish_value(ctx, &sb)
}

// at(0) charAt(1) charCodeAt(2) codePointAt(3)
@(private = "file")
sp_char :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	s := this_str(ctx, this, "charAt")
	if s == nil {return EXCEPTION}
	d, ok := to_integer(ctx, arg(args, 0))
	if !ok {return EXCEPTION}
	n := f64(s.len)
	if magic == 0 && d < 0 {d += n}
	if d < 0 || d >= n {
		switch magic {
		case 0, 3: return UNDEFINED
		case 1: return mk_str(rt.empty_string)
		case 2: return mk_float(NAN)
		}
	}
	f := str_flat(rt, s)
	i := int(d)
	switch magic {
	case 0, 1: return mk_str(str_from_code_unit(rt, str_at(f, i)))
	case 2: return mk_int(i32(str_at(f, i)))
	}
	cp, _ := str_code_point_at(f, i)
	return mk_int(i32(cp))
}

@(private = "file")
sp_concat :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	s := this_str(ctx, this, "concat")
	if s == nil {return EXCEPTION}
	r := s
	for a in args {
		x := to_str(ctx, a)
		if x == nil {return EXCEPTION}
		r = str_concat(ctx.rt, r, x)
		if r == nil {return throw_range_error(ctx, "invalid string length")}
	}
	return mk_str(r)
}

// Find `pat` in `s` at or after `from` (-1 if absent).
str_index_of :: proc(rt: ^Runtime, s, pat: ^JS_String, from: int) -> int {
	fs := str_flat(rt, s)
	fp := str_flat(rt, pat)
	n, m := int(fs.len), int(fp.len)
	if m == 0 {return from <= n ? from : -1}
	if m > n {return -1}
	c0 := str_at(fp, 0)
	outer: for i := from; i <= n - m; i += 1 {
		if str_at(fs, i) != c0 {continue}
		for j in 1 ..< m {
			if str_at(fs, i + j) != str_at(fp, j) {continue outer}
		}
		return i
	}
	return -1
}

str_last_index_of :: proc(rt: ^Runtime, s, pat: ^JS_String, from: int) -> int {
	fs := str_flat(rt, s)
	fp := str_flat(rt, pat)
	n, m := int(fs.len), int(fp.len)
	start := min(from, n - m)
	outer: for i := start; i >= 0; i -= 1 {
		for j in 0 ..< m {
			if str_at(fs, i + j) != str_at(fp, j) {continue outer}
		}
		return i
	}
	return -1
}

// IsRegExp
is_regexp :: proc(ctx: ^Context, v: Value) -> int {
	if v.tag != .object {return 0}
	m := get(ctx, v, well_known_atom(.match))
	if is_exception(m) {return -1}
	if !is_undefined(m) {return to_boolean(m) ? 1 : 0}
	return as_obj(v).class == .regexp ? 1 : 0
}

// endsWith(0) includes(1) startsWith(2)
@(private = "file")
sp_includes :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	s := this_str(ctx, this, "includes")
	if s == nil {return EXCEPTION}
	r := is_regexp(ctx, arg(args, 0))
	if r < 0 {return EXCEPTION}
	if r == 1 {return throw_type_error(ctx, "argument must not be a regular expression")}
	pat := to_str(ctx, arg(args, 0))
	if pat == nil {return EXCEPTION}
	n := i64(s.len)
	m := int(pat.len)
	switch magic {
	case 0:
		end, ok := relative_index_clamp(ctx, arg(args, 1), n, n)
		if !ok {return EXCEPTION}
		start := int(end) - m
		if start < 0 {return FALSE}
		return mk_bool(str_index_of(rt, s, pat, start) == start)
	case 1:
		pos, ok := relative_index_clamp(ctx, arg(args, 1), n, 0)
		if !ok {return EXCEPTION}
		return mk_bool(str_index_of(rt, s, pat, int(pos)) >= 0)
	}
	pos, ok := relative_index_clamp(ctx, arg(args, 1), n, 0)
	if !ok {return EXCEPTION}
	if int(pos) + m > int(n) {return FALSE}
	return mk_bool(str_index_of(rt, s, pat, int(pos)) == int(pos))
}

// clamp(ToIntegerOrInfinity(v), 0, len) with a default for undefined
@(private = "file")
relative_index_clamp :: proc(ctx: ^Context, v: Value, n: i64, def: i64) -> (i64, bool) {
	if is_undefined(v) {return def, true}
	d, ok := to_integer(ctx, v)
	if !ok {return 0, false}
	return i64(clamp(d, 0, f64(n))), true
}

// indexOf(0) lastIndexOf(1)
@(private = "file")
sp_index_of :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	s := this_str(ctx, this, "indexOf")
	if s == nil {return EXCEPTION}
	pat := to_str(ctx, arg(args, 0))
	if pat == nil {return EXCEPTION}
	n := i64(s.len)
	if magic == 0 {
		pos, ok := relative_index_clamp(ctx, arg(args, 1), n, 0)
		if !ok {return EXCEPTION}
		return mk_int(i32(str_index_of(rt, s, pat, int(pos))))
	}
	d, ok := to_number(ctx, arg(args, 1))
	if !ok {return EXCEPTION}
	pos := n
	if d == d {
		t, _ := to_integer(ctx, mk_number(d))
		pos = i64(clamp(t, 0, f64(n)))
	}
	if int(pat.len) > int(n) {return mk_int(-1)}
	return mk_int(i32(str_last_index_of(rt, s, pat, int(pos))))
}

// isWellFormed(0) toWellFormed(1)
@(private = "file")
sp_well_formed :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	s := this_str(ctx, this, "isWellFormed")
	if s == nil {return EXCEPTION}
	f := str_flat(rt, s)
	n := int(f.len)
	if !f.is_wide {return magic == 0 ? TRUE : mk_str(f)}
	sb := sb_init(rt, n)
	defer if magic == 0 {sb_destroy(&sb)}
	for i := 0; i < n; {
		cp, w := str_code_point_at(f, i)
		if cp >= 0xd800 && cp < 0xe000 {
			if magic == 0 {return FALSE}
			sb_unit(&sb, 0xfffd)
		} else if magic == 1 {
			sb_code_point(&sb, cp)
		}
		i += w
	}
	if magic == 0 {return TRUE}
	return mk_str(sb_finish(&sb))
}

@(private = "file")
sp_locale_compare :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	s := this_str(ctx, this, "localeCompare")
	if s == nil {return EXCEPTION}
	t := to_str(ctx, arg(args, 0))
	if t == nil {return EXCEPTION}
	a := str_normalize(rt, s, .NFC)
	b := str_normalize(rt, t, .NFC)
	c := str_cmp(rt, a, b)
	return mk_int(c < 0 ? -1 : (c > 0 ? 1 : 0))
}

str_normalize :: proc(rt: ^Runtime, s: ^JS_String, form: ucd.Normal_Form) -> ^JS_String {
	f := str_flat(rt, s)
	n := int(f.len)
	ascii := true
	for i in 0 ..< n {if str_at(f, i) >= 0x80 {ascii = false; break}}
	if ascii {return f}
	cps := make([dynamic]u32, 0, n, tmp(rt))
	for i := 0; i < n; {
		cp, w := str_code_point_at(f, i)
		append(&cps, cp)
		i += w
	}
	out := ucd.normalize(cps[:], form, tmp(rt))
	sb := sb_init(rt, len(out))
	for c in out {sb_code_point(&sb, c)}
	return sb_finish(&sb)
}

@(private = "file")
sp_normalize :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	s := this_str(ctx, this, "normalize")
	if s == nil {return EXCEPTION}
	form := ucd.Normal_Form.NFC
	if !is_undefined(arg(args, 0)) {
		fs := to_str(ctx, args[0])
		if fs == nil {return EXCEPTION}
		switch {
		case str_eq_ascii(rt, fs, "NFC"): form = .NFC
		case str_eq_ascii(rt, fs, "NFD"): form = .NFD
		case str_eq_ascii(rt, fs, "NFKC"): form = .NFKC
		case str_eq_ascii(rt, fs, "NFKD"): form = .NFKD
		case: return throw_range_error(ctx, "invalid normalization form")
		}
	}
	return mk_str(str_normalize(rt, s, form))
}

// padEnd(0) padStart(1)
@(private = "file")
sp_pad :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	s := this_str(ctx, this, "padStart")
	if s == nil {return EXCEPTION}
	ml, ok := to_length(ctx, arg(args, 0))
	if !ok {return EXCEPTION}
	if ml <= i64(s.len) {return mk_str(s)}
	filler := rt.char_strings[' ']
	if !is_undefined(arg(args, 1)) {
		filler = to_str(ctx, args[1])
		if filler == nil {return EXCEPTION}
	}
	if filler.len == 0 {return mk_str(s)}
	if ml > STRING_LEN_MAX {return throw_range_error(ctx, "invalid string length")}
	fill_len := int(ml) - int(s.len)
	sb := sb_init(rt, int(ml))
	if magic == 0 {sb_str(&sb, s)}
	ff := str_flat(rt, filler)
	for i in 0 ..< fill_len {sb_unit(&sb, str_at(ff, i % int(ff.len)))}
	if magic == 1 {sb_str(&sb, s)}
	return sb_finish_value(ctx, &sb)
}

@(private = "file")
sp_repeat :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	s := this_str(ctx, this, "repeat")
	if s == nil {return EXCEPTION}
	d, ok := to_integer(ctx, arg(args, 0))
	if !ok {return EXCEPTION}
	if d < 0 || d == INF {return throw_range_error(ctx, "invalid repeat count")}
	if d == 0 || s.len == 0 {return mk_str(rt.empty_string)}
	if d * f64(s.len) > STRING_LEN_MAX {return throw_range_error(ctx, "invalid string length")}
	n := int(d)
	sb := sb_init(rt, n * int(s.len))
	for _ in 0 ..< n {sb_str(&sb, s)}
	return sb_finish_value(ctx, &sb)
}

// slice(0) substring(1) substr(2)
@(private = "file")
sp_slice :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	s := this_str(ctx, this, "slice")
	if s == nil {return EXCEPTION}
	n := i64(s.len)
	switch magic {
	case 0:
		start, ok := relative_index(ctx, arg(args, 0), n, 0)
		if !ok {return EXCEPTION}
		end, ok2 := relative_index(ctx, arg(args, 1), n, n)
		if !ok2 {return EXCEPTION}
		return mk_str(str_sub(rt, s, int(start), int(max(end, start))))
	case 1:
		a, ok := relative_index_clamp(ctx, arg(args, 0), n, 0)
		if !ok {return EXCEPTION}
		b, ok2 := relative_index_clamp(ctx, arg(args, 1), n, n)
		if !ok2 {return EXCEPTION}
		return mk_str(str_sub(rt, s, int(min(a, b)), int(max(a, b))))
	}
	start, ok := relative_index(ctx, arg(args, 0), n, 0)
	if !ok {return EXCEPTION}
	l := n - start
	if !is_undefined(arg(args, 1)) {
		d, ok2 := to_integer(ctx, args[1])
		if !ok2 {return EXCEPTION}
		l = i64(clamp(d, 0, f64(n - start)))
	}
	return mk_str(str_sub(rt, s, int(start), int(start + max(l, 0))))
}

// Case conversion with the full (SpecialCasing) mappings and the Final_Sigma rule.
str_case :: proc(rt: ^Runtime, s: ^JS_String, upper: bool) -> ^JS_String {
	f := str_flat(rt, s)
	n := int(f.len)
	if !f.is_wide {
		// fast ASCII/Latin-1 path when no special mapping is involved
		changed := false
		ok := true
		d := str_u8(f)
		for i in 0 ..< n {
			c := d[i]
			if upper {
				if c >= 'a' && c <= 'z' {changed = true} else if c >= 0x80 && (c == 0xb5 || c == 0xdf || c == 0xff || c >= 0xe0) {ok = false; break}
			} else {
				if c >= 'A' && c <= 'Z' {changed = true} else if c >= 0xc0 {ok = false; break}
			}
		}
		if ok {
			if !changed {return f}
			r := str_alloc(rt, n, false)
			o := str_u8(r)
			for i in 0 ..< n {
				c := d[i]
				if upper && c >= 'a' && c <= 'z' {c -= 32} else if !upper && c >= 'A' && c <= 'Z' {c += 32}
				o[i] = c
			}
			return r
		}
	}
	sb := sb_init(rt, n)
	for i := 0; i < n; {
		cp, w := str_code_point_at(f, i)
		if !upper && cp == 0x3a3 && final_sigma(f, i) {
			sb_code_point(&sb, 0x3c2)
		} else {
			res: [3]u32
			k := ucd.full_case(&res, cp, upper ? .To_Upper : .To_Lower)
			for j in 0 ..< k {sb_code_point(&sb, res[j])}
		}
		i += w
	}
	return sb_finish(&sb)
}

@(private = "file")
final_sigma :: proc(f: ^JS_String, i: int) -> bool {
	// preceded by a cased letter (skipping case-ignorable), not followed by one
	k := i - 1
	found := false
	for k >= 0 {
		c := u32(str_at(f, k))
		if c >= 0xdc00 && c < 0xe000 && k > 0 {
			hi := u32(str_at(f, k - 1))
			if hi >= 0xd800 && hi < 0xdc00 {c = 0x10000 + ((hi - 0xd800) << 10) + (c - 0xdc00); k -= 1}
		}
		if ucd.is_case_ignorable(c) {k -= 1; continue}
		found = ucd.is_cased(c)
		break
	}
	if !found {return false}
	j := i + 1
	n := int(f.len)
	for j < n {
		c, w := str_code_point_at(f, j)
		if ucd.is_case_ignorable(c) {j += w; continue}
		return !ucd.is_cased(c)
	}
	return true
}

// toLowerCase(0) toUpperCase(1) toLocaleLowerCase(2) toLocaleUpperCase(3)
@(private = "file")
sp_case :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	s := this_str(ctx, this, "toLowerCase")
	if s == nil {return EXCEPTION}
	if magic >= 2 && !is_undefined(arg(args, 0)) {
		// locale argument: validated by Intl in a full implementation; accept a string or array of strings
		l := args[0]
		if l.tag != .string && l.tag != .object {
			ls := to_str(ctx, l)
			if ls == nil {return EXCEPTION}
		}
	}
	return mk_str(str_case(ctx.rt, s, magic & 1 == 1))
}

@(private = "file")
sp_value_of :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	v, ok := this_primitive(ctx, this, .string, .string, "string")
	if !ok {return EXCEPTION}
	return v
}

is_trim_space :: proc(c: u32) -> bool {
	return is_js_space(c) || c == 0x0a || c == 0x0d || c == 0x2028 || c == 0x2029
}

// trim(0) trimStart(1) trimEnd(2)
str_trim :: proc(rt: ^Runtime, s: ^JS_String, mode: int) -> ^JS_String {
	f := str_flat(rt, s)
	a, b := 0, int(f.len)
	if mode != 2 {for a < b && is_trim_space(u32(str_at(f, a))) {a += 1}}
	if mode != 1 {for b > a && is_trim_space(u32(str_at(f, b - 1))) {b -= 1}}
	return str_sub(rt, f, a, b)
}

@(private = "file")
sp_trim :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	s := this_str(ctx, this, "trim")
	if s == nil {return EXCEPTION}
	return mk_str(str_trim(ctx.rt, s, int(magic)))
}

// Annex B HTML methods: magic indexes the table.
@(private = "file")
html_table := [13][3]string {
	{"anchor", "a", "name"}, {"big", "big", ""}, {"blink", "blink", ""}, {"bold", "b", ""},
	{"fixed", "tt", ""}, {"fontcolor", "font", "color"}, {"fontsize", "font", "size"},
	{"italics", "i", ""}, {"link", "a", "href"}, {"small", "small", ""}, {"strike", "strike", ""},
	{"sub", "sub", ""}, {"sup", "sup", ""},
}

@(private = "file")
sp_html :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if is_nullish(this) {return throw_type_error(ctx, "String.prototype method called on null or undefined")}
	s := to_str(ctx, this)
	if s == nil {return EXCEPTION}
	e := html_table[magic]
	sb := sb_init(rt)
	sb_ascii(&sb, "<")
	sb_ascii(&sb, e[1])
	if e[2] != "" {
		v := to_str(ctx, arg(args, 0))
		if v == nil {sb_destroy(&sb); return EXCEPTION}
		sb_ascii(&sb, " ")
		sb_ascii(&sb, e[2])
		sb_ascii(&sb, "=\"")
		fv := str_flat(rt, v)
		for i in 0 ..< int(fv.len) {
			c := str_at(fv, i)
			if c == '"' {sb_ascii(&sb, "&quot;")} else {sb_unit(&sb, c)}
		}
		sb_ascii(&sb, "\"")
	}
	sb_ascii(&sb, ">")
	sb_str(&sb, s)
	sb_ascii(&sb, "</")
	sb_ascii(&sb, e[1])
	sb_ascii(&sb, ">")
	return sb_finish_value(ctx, &sb)
}

// --- regexp-dispatching methods ---

// match(0) matchAll(1) search(2) replace(3) replaceAll(4) split(5)
@(private = "file")
sp_regexp_dispatch :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if is_nullish(this) {return throw_type_error(ctx, "String.prototype method called on null or undefined")}
	syms := [6]Well_Known{.match, .match_all, .search, .replace, .replace, .split}
	re := arg(args, 0)
	if !is_nullish(re) {
		if magic == 1 || magic == 4 {
			ir := is_regexp(ctx, re)
			if ir < 0 {return EXCEPTION}
			if ir == 1 {
				fl := get(ctx, re, pa(.A_flags))
				if is_exception(fl) {return EXCEPTION}
				if is_nullish(fl) {return throw_type_error(ctx, "flags is null or undefined")}
				fs := to_str(ctx, fl)
				if fs == nil {return EXCEPTION}
				if str_index_of(rt, fs, rt.char_strings['g'], 0) < 0 {
					return throw_type_error(ctx, "regexp must have the global flag")
				}
			}
		}
		m := get_method(ctx, re, well_known_atom(syms[magic]))
		if is_exception(m) {return EXCEPTION}
		if !is_undefined(m) {
			switch magic {
			case 3, 4: return call(ctx, m, re, {this, arg(args, 1)})
			case 5: return call(ctx, m, re, {this, arg(args, 1)})
			case: return call(ctx, m, re, {this})
			}
		}
	}
	s := to_str(ctx, this)
	if s == nil {return EXCEPTION}
	switch magic {
	case 0, 1, 2:
		// create a RegExp and invoke its symbol method
		rx: Value
		if magic == 1 {
			rx = regexp_create(ctx, re, mk_str(rt.char_strings['g']))
		} else {
			rx = regexp_create(ctx, re, UNDEFINED)
		}
		if is_exception(rx) {return EXCEPTION}
		return invoke(ctx, rx, well_known_atom(syms[magic]), {mk_str(s)})
	case 3, 4:
		return string_replace_generic(ctx, s, re, arg(args, 1), magic == 4)
	}
	return string_split_generic(ctx, s, re, arg(args, 1))
}

// GetSubstitution(matched, str, position, captures, namedCaptures, replacement).
get_substitution :: proc(ctx: ^Context, sb: ^String_Builder, matched: ^JS_String, str: ^JS_String, position: int, captures: []Value, named: Value, repl: ^JS_String) -> bool {
	rt := ctx.rt
	r := str_flat(rt, repl)
	n := int(r.len)
	m := len(captures)
	tail := position + int(matched.len)
	for i := 0; i < n; i += 1 {
		c := str_at(r, i)
		if c != '$' || i + 1 >= n {
			sb_unit(sb, c)
			continue
		}
		c2 := str_at(r, i + 1)
		switch {
		case c2 == '$':
			sb_unit(sb, '$')
			i += 1
		case c2 == '&':
			sb_str(sb, matched)
			i += 1
		case c2 == '`':
			sb_str_range(sb, str, 0, position)
			i += 1
		case c2 == '\'':
			if tail < int(str.len) {sb_str_range(sb, str, tail, int(str.len))}
			i += 1
		case c2 >= '0' && c2 <= '9':
			k := int(c2 - '0')
			consumed := 1
			if i + 2 < n {
				c3 := str_at(r, i + 2)
				if c3 >= '0' && c3 <= '9' {
					k2 := k * 10 + int(c3 - '0')
					if k2 >= 1 && k2 <= m {k = k2; consumed = 2}
				}
			}
			if k >= 1 && k <= m {
				v := captures[k - 1]
				if !is_undefined(v) {
					cs := to_str(ctx, v)
					if cs == nil {return false}
					sb_str(sb, cs)
				}
				i += consumed
			} else {
				sb_unit(sb, '$')
			}
		case c2 == '<':
			if is_undefined(named) {
				sb_unit(sb, '$')
				continue
			}
			close := -1
			for j in i + 2 ..< n {if str_at(r, j) == '>' {close = j; break}}
			if close < 0 {
				sb_unit(sb, '$')
				continue
			}
			name := str_sub(rt, r, i + 2, close)
			v := get(ctx, named, atom_from_string(rt, name))
			if is_exception(v) {return false}
			if !is_undefined(v) {
				cs := to_str(ctx, v)
				if cs == nil {return false}
				sb_str(sb, cs)
			}
			i = close
		case:
			sb_unit(sb, '$')
		}
	}
	return true
}

@(private = "file")
string_replace_generic :: proc(ctx: ^Context, s: ^JS_String, search: Value, replace: Value, all: bool) -> Value {
	rt := ctx.rt
	ss := to_str(ctx, search)
	if ss == nil {return EXCEPTION}
	functional := is_callable(replace)
	rs: ^JS_String
	if !functional {
		rs = to_str(ctx, replace)
		if rs == nil {return EXCEPTION}
	}
	positions := make([dynamic]int, 0, 4, tmp(rt))
	adv := max(int(ss.len), 1)
	p := str_index_of(rt, s, ss, 0)
	for p >= 0 {
		append(&positions, p)
		if !all {break}
		p = str_index_of(rt, s, ss, p + adv)
	}
	if len(positions) == 0 {return mk_str(s)}
	sb := sb_init(rt, int(s.len))
	end := 0
	for pos in positions {
		sb_str_range(&sb, s, end, pos)
		if functional {
			r := call(ctx, replace, UNDEFINED, {mk_str(ss), mk_int(i32(pos)), mk_str(s)})
			if is_exception(r) {sb_destroy(&sb); return EXCEPTION}
			x := to_str(ctx, r)
			if x == nil {sb_destroy(&sb); return EXCEPTION}
			sb_str(&sb, x)
		} else {
			if !get_substitution(ctx, &sb, ss, s, pos, nil, UNDEFINED, rs) {sb_destroy(&sb); return EXCEPTION}
		}
		end = pos + int(ss.len)
	}
	sb_str_range(&sb, s, end, int(s.len))
	return sb_finish_value(ctx, &sb)
}

@(private = "file")
string_split_generic :: proc(ctx: ^Context, s: ^JS_String, sep: Value, limit: Value) -> Value {
	rt := ctx.rt
	lim := u32(0xffffffff)
	if !is_undefined(limit) {
		l, ok := to_uint32(ctx, limit)
		if !ok {return EXCEPTION}
		lim = l
	}
	r := to_str(ctx, sep)
	if r == nil {return EXCEPTION}
	a := array_new(ctx)
	if lim == 0 {return mk_obj(a)}
	if is_undefined(sep) {
		array_push_fast(rt, a, mk_str(s))
		return mk_obj(a)
	}
	n := int(s.len)
	if n == 0 {
		if r.len > 0 {array_push_fast(rt, a, mk_str(s))}
		return mk_obj(a)
	}
	if r.len == 0 {
		f := str_flat(rt, s)
		for i in 0 ..< n {
			if a.data.(Array_Data).count >= lim {break}
			array_push_fast(rt, a, mk_str(str_from_code_unit(rt, str_at(f, i))))
		}
		return mk_obj(a)
	}
	p := 0
	for {
		q := str_index_of(rt, s, r, p)
		if q < 0 {break}
		array_push_fast(rt, a, mk_str(str_sub(rt, s, p, q)))
		if a.data.(Array_Data).count >= lim {return mk_obj(a)}
		p = q + int(r.len)
	}
	array_push_fast(rt, a, mk_str(str_sub(rt, s, p, n)))
	return mk_obj(a)
}

// --- String iterator ---

@(private = "file")
sp_iterator :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	s := this_str(ctx, this, "[Symbol.iterator]")
	if s == nil {return EXCEPTION}
	it := iter_state_new(ctx, ctx.class_proto[.string_iterator], .string_iterator, .string, mk_str(s))
	return mk_obj(it)
}

@(private = "file")
string_iterator_next :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	o := this_class(ctx, this, .string_iterator, "String Iterator")
	if o == nil {return EXCEPTION}
	st := o.data.(^Iter_State)
	if st.done || st.target.tag != .string {return iter_result(ctx, UNDEFINED, true)}
	f := str_flat(rt, as_str(st.target))
	if st.index >= i64(f.len) {
		st.done = true
		st.target = UNDEFINED
		return iter_result(ctx, UNDEFINED, true)
	}
	i := int(st.index)
	_, w := str_code_point_at(f, i)
	st.index += i64(w)
	return iter_result(ctx, mk_str(str_sub(rt, f, i, i + w)), false)
}

init_string_builtins :: proc(ctx: ^Context) {
	sp := ctx.class_proto[.string]
	sc := def_ctor(ctx, "String", string_ctor, 1, sp)
	def_method(ctx, sc, "fromCharCode", string_from_char_code, 1)
	def_method(ctx, sc, "fromCodePoint", string_from_code_point, 1)
	def_method(ctx, sc, "raw", string_raw, 1)
	def_method(ctx, sp, "at", sp_char, 1, 0)
	def_method(ctx, sp, "charAt", sp_char, 1, 1)
	def_method(ctx, sp, "charCodeAt", sp_char, 1, 2)
	def_method(ctx, sp, "codePointAt", sp_char, 1, 3)
	def_method(ctx, sp, "concat", sp_concat, 1)
	def_method(ctx, sp, "endsWith", sp_includes, 1, 0)
	def_method(ctx, sp, "includes", sp_includes, 1, 1)
	def_method(ctx, sp, "startsWith", sp_includes, 1, 2)
	def_method(ctx, sp, "indexOf", sp_index_of, 1, 0)
	def_method(ctx, sp, "lastIndexOf", sp_index_of, 1, 1)
	def_method(ctx, sp, "isWellFormed", sp_well_formed, 0, 0)
	def_method(ctx, sp, "toWellFormed", sp_well_formed, 0, 1)
	def_method(ctx, sp, "localeCompare", sp_locale_compare, 1)
	def_method(ctx, sp, "match", sp_regexp_dispatch, 1, 0)
	def_method(ctx, sp, "matchAll", sp_regexp_dispatch, 1, 1)
	def_method(ctx, sp, "search", sp_regexp_dispatch, 1, 2)
	def_method(ctx, sp, "replace", sp_regexp_dispatch, 2, 3)
	def_method(ctx, sp, "replaceAll", sp_regexp_dispatch, 2, 4)
	def_method(ctx, sp, "split", sp_regexp_dispatch, 2, 5)
	def_method(ctx, sp, "normalize", sp_normalize, 0)
	def_method(ctx, sp, "padEnd", sp_pad, 1, 0)
	def_method(ctx, sp, "padStart", sp_pad, 1, 1)
	def_method(ctx, sp, "repeat", sp_repeat, 1)
	def_method(ctx, sp, "slice", sp_slice, 2, 0)
	def_method(ctx, sp, "substring", sp_slice, 2, 1)
	def_method(ctx, sp, "substr", sp_slice, 2, 2)
	def_method(ctx, sp, "toLowerCase", sp_case, 0, 0)
	def_method(ctx, sp, "toUpperCase", sp_case, 0, 1)
	def_method(ctx, sp, "toLocaleLowerCase", sp_case, 0, 2)
	def_method(ctx, sp, "toLocaleUpperCase", sp_case, 0, 3)
	def_method(ctx, sp, "toString", sp_value_of, 0)
	def_method(ctx, sp, "valueOf", sp_value_of, 0)
	def_method(ctx, sp, "trim", sp_trim, 0, 0)
	ts := def_method(ctx, sp, "trimStart", sp_trim, 0, 1)
	te := def_method(ctx, sp, "trimEnd", sp_trim, 0, 2)
	def_value(ctx, sp, "trimLeft", mk_obj(ts))
	def_value(ctx, sp, "trimRight", mk_obj(te))
	for e, i in html_table {def_method(ctx, sp, e[0], sp_html, e[2] != "" ? 1 : 0, i32(i))}
	def_method_sym(ctx, sp, .iterator, sp_iterator, 0)
	sip := ctx.class_proto[.string_iterator]
	def_method(ctx, sip, "next", string_iterator_next, 0)
	def_tag(ctx, sip, "String Iterator")
}
