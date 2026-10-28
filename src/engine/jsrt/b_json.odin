package jsrt

// JSON (ECMA-262 §25.5) including JSON.parse source text access (reviver context, rawJSON).

import "wb:engine/numconv"

@(private = "file")
JSON_Parser :: struct {
	ctx:  ^Context,
	s:    ^JS_String,
	pos:  int,
	n:    int,
	err:  bool,
	with_source: bool,
}

@(private = "file")
jp_peek :: #force_inline proc(p: ^JSON_Parser) -> u16 {
	if p.pos >= p.n {return 0}
	return str_at(p.s, p.pos)
}

@(private = "file")
jp_ws :: proc(p: ^JSON_Parser) {
	for p.pos < p.n {
		c := str_at(p.s, p.pos)
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {p.pos += 1} else {break}
	}
}

@(private = "file")
jp_fail :: proc(p: ^JSON_Parser, msg: string) -> Value {
	if !p.err {
		p.err = true
		throw_syntax_error(p.ctx, cat(p.ctx, "JSON.parse: ", msg))
	}
	return EXCEPTION
}

// Parsed values carry their source span for the reviver's context.source (primitives only).
@(private = "file")
JSON_Node :: struct {
	start, end: int,
}

@(private = "file")
jp_value :: proc(p: ^JSON_Parser, depth: int) -> Value {
	ctx := p.ctx
	rt := ctx.rt
	if depth > 5000 {return jp_fail(p, "too deeply nested")}
	jp_ws(p)
	c := jp_peek(p)
	switch c {
	case '{':
		p.pos += 1
		o := new_plain_object(ctx)
		jp_ws(p)
		if jp_peek(p) == '}' {p.pos += 1; return mk_obj(o)}
		for {
			jp_ws(p)
			if jp_peek(p) != '"' {return jp_fail(p, "expected property name")}
			k := jp_string(p)
			if is_exception(k) {return EXCEPTION}
			jp_ws(p)
			if jp_peek(p) != ':' {return jp_fail(p, "expected ':'")}
			p.pos += 1
			v := jp_value(p, depth + 1)
			if is_exception(v) {return EXCEPTION}
			a := atom_from_string(rt, as_str(k))
			if a == pa(.A___proto__) {
				define_own_property(ctx, o, a, data_desc(v, CWE), false)
			} else {
				create_data_property(ctx, o, a, v, false)
			}
			jp_ws(p)
			c2 := jp_peek(p)
			if c2 == ',' {p.pos += 1; continue}
			if c2 == '}' {p.pos += 1; break}
			return jp_fail(p, "expected ',' or '}'")
		}
		return mk_obj(o)
	case '[':
		p.pos += 1
		a := array_new(ctx)
		jp_ws(p)
		if jp_peek(p) == ']' {p.pos += 1; return mk_obj(a)}
		for {
			v := jp_value(p, depth + 1)
			if is_exception(v) {return EXCEPTION}
			array_push_fast(rt, a, v)
			jp_ws(p)
			c2 := jp_peek(p)
			if c2 == ',' {p.pos += 1; continue}
			if c2 == ']' {p.pos += 1; break}
			return jp_fail(p, "expected ',' or ']'")
		}
		return mk_obj(a)
	case '"':
		return jp_string(p)
	case 't':
		if jp_lit(p, "true") {return TRUE}
	case 'f':
		if jp_lit(p, "false") {return FALSE}
	case 'n':
		if jp_lit(p, "null") {return NULL}
	case '-', '0' ..= '9':
		return jp_number(p)
	}
	if p.pos >= p.n {return jp_fail(p, "unexpected end of input")}
	return jp_fail(p, "unexpected character")
}

@(private = "file")
jp_lit :: proc(p: ^JSON_Parser, lit: string) -> bool {
	if p.pos + len(lit) > p.n {return false}
	for i in 0 ..< len(lit) {if str_at(p.s, p.pos + i) != u16(lit[i]) {return false}}
	p.pos += len(lit)
	return true
}

@(private = "file")
jp_number :: proc(p: ^JSON_Parser) -> Value {
	start := p.pos
	if jp_peek(p) == '-' {p.pos += 1}
	if jp_peek(p) == '0' {
		p.pos += 1
	} else if jp_peek(p) >= '1' && jp_peek(p) <= '9' {
		for jp_peek(p) >= '0' && jp_peek(p) <= '9' {p.pos += 1}
	} else {
		return jp_fail(p, "invalid number")
	}
	if jp_peek(p) == '.' {
		p.pos += 1
		if !(jp_peek(p) >= '0' && jp_peek(p) <= '9') {return jp_fail(p, "invalid number")}
		for jp_peek(p) >= '0' && jp_peek(p) <= '9' {p.pos += 1}
	}
	if jp_peek(p) == 'e' || jp_peek(p) == 'E' {
		p.pos += 1
		if jp_peek(p) == '+' || jp_peek(p) == '-' {p.pos += 1}
		if !(jp_peek(p) >= '0' && jp_peek(p) <= '9') {return jp_fail(p, "invalid number")}
		for jp_peek(p) >= '0' && jp_peek(p) <= '9' {p.pos += 1}
	}
	buf := make([]u8, p.pos - start, tmp(p.ctx.rt))
	for i in 0 ..< len(buf) {buf[i] = u8(str_at(p.s, start + i))}
	return mk_number(numconv.parse_float(string(buf)))
}

@(private = "file")
jp_hex :: proc(c: u16) -> int {
	switch c {
	case '0' ..= '9': return int(c - '0')
	case 'a' ..= 'f': return int(c - 'a') + 10
	case 'A' ..= 'F': return int(c - 'A') + 10
	}
	return -1
}

@(private = "file")
jp_string :: proc(p: ^JSON_Parser) -> Value {
	rt := p.ctx.rt
	p.pos += 1
	start := p.pos
	// fast path: no escapes
	for p.pos < p.n {
		c := str_at(p.s, p.pos)
		if c == '"' {
			v := str_sub(rt, p.s, start, p.pos)
			p.pos += 1
			return mk_str(v)
		}
		if c == '\\' || c < 0x20 {break}
		p.pos += 1
	}
	sb := sb_init(rt, p.pos - start + 8)
	sb_str_range(&sb, p.s, start, p.pos)
	for {
		if p.pos >= p.n {sb_destroy(&sb); return jp_fail(p, "unterminated string")}
		c := str_at(p.s, p.pos)
		p.pos += 1
		if c == '"' {break}
		if c < 0x20 {sb_destroy(&sb); return jp_fail(p, "control character in string")}
		if c != '\\' {sb_unit(&sb, c); continue}
		if p.pos >= p.n {sb_destroy(&sb); return jp_fail(p, "bad escape")}
		e := str_at(p.s, p.pos)
		p.pos += 1
		switch e {
		case '"': sb_unit(&sb, '"')
		case '\\': sb_unit(&sb, '\\')
		case '/': sb_unit(&sb, '/')
		case 'b': sb_unit(&sb, 8)
		case 'f': sb_unit(&sb, 12)
		case 'n': sb_unit(&sb, 10)
		case 'r': sb_unit(&sb, 13)
		case 't': sb_unit(&sb, 9)
		case 'u':
			if p.pos + 4 > p.n {sb_destroy(&sb); return jp_fail(p, "bad unicode escape")}
			v := 0
			for i in 0 ..< 4 {
				h := jp_hex(str_at(p.s, p.pos + i))
				if h < 0 {sb_destroy(&sb); return jp_fail(p, "bad unicode escape")}
				v = v * 16 + h
			}
			p.pos += 4
			sb_unit(&sb, u16(v))
		case:
			sb_destroy(&sb)
			return jp_fail(p, "bad escape")
		}
	}
	return mk_str(sb_finish(&sb))
}

// InternalizeJSONProperty. `src` is the parsed value tree mirrored for source-text access.
@(private = "file")
internalize :: proc(ctx: ^Context, holder: Value, a: Atom, reviver: Value, depth: int) -> Value {
	rt := ctx.rt
	if depth > 5000 {return throw_range_error(ctx, "JSON.parse: too deeply nested")}
	val := get(ctx, holder, a)
	if is_exception(val) {return EXCEPTION}
	if val.tag == .object {
		ia := is_array_value(ctx, val)
		if ia < 0 {return EXCEPTION}
		if ia == 1 {
			n, ok := length_of_array_like(ctx, val)
			if !ok {return EXCEPTION}
			for i in 0 ..< n {
				k := i <= i64(ATOM_MAX_INT) ? atom_from_u32(u32(i)) : number_to_atom(ctx, f64(i))
				ne := internalize(ctx, val, k, reviver, depth + 1)
				if is_exception(ne) {return EXCEPTION}
				if is_undefined(ne) {
					if delete_property(ctx, as_obj(val), k) < 0 {return EXCEPTION}
				} else {
					if create_data_property(ctx, as_obj(val), k, ne, false) < 0 {return EXCEPTION}
				}
			}
		} else {
			keys := make([dynamic]Atom, 0, 8, tmp(rt))
			if !own_property_keys(ctx, as_obj(val), &keys, {.strings}) {return EXCEPTION}
			for k in keys {
				e := own_enumerable(ctx, as_obj(val), k)
				if e < 0 {return EXCEPTION}
				if e == 0 {continue}
				ne := internalize(ctx, val, k, reviver, depth + 1)
				if is_exception(ne) {return EXCEPTION}
				if is_undefined(ne) {
					if delete_property(ctx, as_obj(val), k) < 0 {return EXCEPTION}
				} else {
					if create_data_property(ctx, as_obj(val), k, ne, false) < 0 {return EXCEPTION}
				}
			}
		}
	}
	context_obj := new_plain_object(ctx)
	if val.tag != .object {
		src := json_source_for(ctx, val)
		if !is_undefined(src) {define_value(ctx, context_obj, pa(.A_source), src, CWE)}
	}
	return call(ctx, reviver, holder, {atom_to_value(rt, a), val, mk_obj(context_obj)})
}

// The source text of a primitive JSON value: its canonical serialization.
@(private = "file")
json_source_for :: proc(ctx: ^Context, v: Value) -> Value {
	#partial switch v.tag {
	case .string:
		sb := sb_init(ctx.rt)
		json_quote(&sb, as_str(v))
		return mk_str(sb_finish(&sb))
	case .int, .float:
		return mk_str(number_to_string(ctx.rt, as_f64(v)))
	case .bool:
		return atom_to_value(ctx.rt, v.u.b ? pa(.A_true) : pa(.A_false))
	case .null:
		return atom_to_value(ctx.rt, pa(.A_null))
	}
	return UNDEFINED
}

@(private = "file")
json_parse :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	s := to_str(ctx, arg(args, 0))
	if s == nil {return EXCEPTION}
	f := str_flat(rt, s)
	p := JSON_Parser{ctx = ctx, s = f, n = int(f.len)}
	v := jp_value(&p, 0)
	if is_exception(v) {return EXCEPTION}
	jp_ws(&p)
	if p.pos < p.n {return jp_fail(&p, "unexpected data after the value")}
	reviver := arg(args, 1)
	if !is_callable(reviver) {return v}
	root_obj := new_plain_object(ctx)
	create_data_property(ctx, root_obj, pa(.A_empty_string), v, false)
	return internalize(ctx, mk_obj(root_obj), pa(.A_empty_string), reviver, 0)
}

// --- stringify ---

@(private = "file")
JSON_Writer :: struct {
	ctx:       ^Context,
	sb:        String_Builder,
	replacer:  Value,
	prop_list: [dynamic]Atom,
	has_list:  bool,
	gap:       ^JS_String,
	indent:    [dynamic]u16,
	stack:     [dynamic]^Object,
}

json_quote :: proc(sb: ^String_Builder, s: ^JS_String) {
	f := str_flat(sb.rt, s)
	n := int(f.len)
	HEX := "0123456789abcdef"
	sb_unit(sb, '"')
	for i := 0; i < n; i += 1 {
		c := str_at(f, i)
		switch c {
		case '"': sb_ascii(sb, "\\\"")
		case '\\': sb_ascii(sb, "\\\\")
		case 8: sb_ascii(sb, "\\b")
		case 12: sb_ascii(sb, "\\f")
		case 10: sb_ascii(sb, "\\n")
		case 13: sb_ascii(sb, "\\r")
		case 9: sb_ascii(sb, "\\t")
		case:
			lone := false
			if c >= 0xd800 && c < 0xdc00 {
				if i + 1 < n && str_at(f, i + 1) >= 0xdc00 && str_at(f, i + 1) < 0xe000 {
					sb_unit(sb, c)
					sb_unit(sb, str_at(f, i + 1))
					i += 1
					continue
				}
				lone = true
			} else if c >= 0xdc00 && c < 0xe000 {
				lone = true
			}
			if c < 0x20 || lone {
				sb_ascii(sb, "\\u")
				sb_unit(sb, u16(HEX[(c >> 12) & 15]))
				sb_unit(sb, u16(HEX[(c >> 8) & 15]))
				sb_unit(sb, u16(HEX[(c >> 4) & 15]))
				sb_unit(sb, u16(HEX[c & 15]))
			} else {
				sb_unit(sb, c)
			}
		}
	}
	sb_unit(sb, '"')
}

// SerializeJSONProperty; returns 1 written, 0 undefined (nothing written), -1 exception.
@(private = "file")
json_property :: proc(w: ^JSON_Writer, holder: Value, key: Atom, val_in: Value) -> int {
	ctx := w.ctx
	rt := ctx.rt
	v := val_in
	if v.tag == .object || v.tag == .bigint {
		tj := get(ctx, v, pa(.A_toJSON))
		if is_exception(tj) {return -1}
		if is_callable(tj) {
			v = call(ctx, tj, v, {atom_to_value(rt, key)})
			if is_exception(v) {return -1}
		}
	}
	if !is_undefined(w.replacer) {
		v = call(ctx, w.replacer, holder, {atom_to_value(rt, key), v})
		if is_exception(v) {return -1}
	}
	if v.tag == .object {
		o := as_obj(v)
		#partial switch o.class {
		case .number:
			d, ok := to_number(ctx, v)
			if !ok {return -1}
			v = mk_number(d)
		case .string:
			s := to_str(ctx, v)
			if s == nil {return -1}
			v = mk_str(s)
		case .boolean, .bigint:
			v = o.data.(Prim_Data).v
		case:
			if o.class == .object && is_raw_json(o) {
				i := shape_find(o.shape, pa(.A_rawJSON))
				sb_str(&w.sb, as_str(o.slots[i].value))
				return 1
			}
		}
	}
	#partial switch v.tag {
	case .null:
		sb_ascii(&w.sb, "null")
		return 1
	case .bool:
		sb_ascii(&w.sb, v.u.b ? "true" : "false")
		return 1
	case .string:
		json_quote(&w.sb, as_str(v))
		return 1
	case .int, .float:
		d := as_f64(v)
		if d != d || d == INF || d == -INF {
			sb_ascii(&w.sb, "null")
		} else {
			sb_str(&w.sb, number_to_string(rt, d))
		}
		return 1
	case .bigint:
		throw_type_error(ctx, "BigInt value can't be serialized in JSON")
		return -1
	case .object:
		if is_callable(v) {return 0}
		ia := is_array_value(ctx, v)
		if ia < 0 {return -1}
		return ia == 1 ? json_array(w, v) : json_object(w, v)
	}
	return 0
}

@(private = "file")
json_enter :: proc(w: ^JSON_Writer, o: ^Object) -> bool {
	for x in w.stack {
		if x == o {
			throw_type_error(w.ctx, "circular reference in JSON.stringify")
			return false
		}
	}
	if len(w.stack) > 4000 {
		throw_range_error(w.ctx, "JSON.stringify: too deeply nested")
		return false
	}
	append(&w.stack, o)
	return true
}

@(private = "file")
json_newline :: proc(w: ^JSON_Writer) {
	if w.gap.len == 0 {return}
	sb_unit(&w.sb, '\n')
	for c in w.indent {sb_unit(&w.sb, c)}
}

@(private = "file")
json_object :: proc(w: ^JSON_Writer, v: Value) -> int {
	ctx := w.ctx
	rt := ctx.rt
	o := as_obj(v)
	if !json_enter(w, o) {return -1}
	defer pop(&w.stack)
	old_indent := len(w.indent)
	gf := str_flat(rt, w.gap)
	for i in 0 ..< int(gf.len) {append(&w.indent, str_at(gf, i))}
	defer resize(&w.indent, old_indent)
	keys: [dynamic]Atom
	if w.has_list {
		keys = w.prop_list
	} else {
		keys = make([dynamic]Atom, 0, 8, tmp(rt))
		if !own_property_keys(ctx, o, &keys, {.strings}) {return -1}
	}
	sb_unit(&w.sb, '{')
	first := true
	for k in keys {
		if !w.has_list {
			e := own_enumerable(ctx, o, k)
			if e < 0 {return -1}
			if e == 0 {continue}
		}
		pv := get(ctx, v, k)
		if is_exception(pv) {return -1}
		mark := w.sb.len
		saved8 := len(w.sb.b8)
		saved16 := len(w.sb.b16)
		if !first {sb_unit(&w.sb, ',')}
		json_newline(w)
		json_quote(&w.sb, atom_to_string(rt, k))
		sb_unit(&w.sb, ':')
		if w.gap.len > 0 {sb_unit(&w.sb, ' ')}
		r := json_property(w, v, k, pv)
		if r < 0 {return -1}
		if r == 0 {
			// roll back the key
			w.sb.len = mark
			resize(&w.sb.b8, saved8)
			resize(&w.sb.b16, saved16)
			continue
		}
		first = false
	}
	if !first {
		resize(&w.indent, old_indent)
		json_newline(w)
	}
	sb_unit(&w.sb, '}')
	return 1
}

@(private = "file")
json_array :: proc(w: ^JSON_Writer, v: Value) -> int {
	ctx := w.ctx
	rt := ctx.rt
	o := as_obj(v)
	if !json_enter(w, o) {return -1}
	defer pop(&w.stack)
	n, ok := length_of_array_like(ctx, v)
	if !ok {return -1}
	old_indent := len(w.indent)
	gf := str_flat(rt, w.gap)
	for i in 0 ..< int(gf.len) {append(&w.indent, str_at(gf, i))}
	sb_unit(&w.sb, '[')
	for i in 0 ..< n {
		if i > 0 {sb_unit(&w.sb, ',')}
		json_newline(w)
		ev := get_index(ctx, v, i)
		if is_exception(ev) {return -1}
		k := i <= i64(ATOM_MAX_INT) ? atom_from_u32(u32(i)) : number_to_atom(ctx, f64(i))
		r := json_property(w, v, k, ev)
		if r < 0 {return -1}
		if r == 0 {sb_ascii(&w.sb, "null")}
	}
	resize(&w.indent, old_indent)
	if n > 0 {json_newline(w)}
	sb_unit(&w.sb, ']')
	return 1
}

json_stringify_value :: proc(ctx: ^Context, v: Value, replacer: Value, space: Value) -> Value {
	rt := ctx.rt
	w := JSON_Writer{ctx = ctx, replacer = UNDEFINED, gap = rt.empty_string}
	w.sb = sb_init(rt)
	w.indent = make([dynamic]u16, tmp(rt))
	w.stack = make([dynamic]^Object, tmp(rt))
	if is_callable(replacer) {
		w.replacer = replacer
	} else if replacer.tag == .object {
		ia := is_array_value(ctx, replacer)
		if ia < 0 {return EXCEPTION}
		if ia == 1 {
			w.has_list = true
			w.prop_list = make([dynamic]Atom, tmp(rt))
			n, ok := length_of_array_like(ctx, replacer)
			if !ok {return EXCEPTION}
			for i in 0 ..< n {
				e := get_index(ctx, replacer, i)
				if is_exception(e) {return EXCEPTION}
				item: ^JS_String
				if e.tag == .string {
					item = as_str(e)
				} else if is_number(e) {
					item = to_str(ctx, e)
				} else if e.tag == .object && (as_obj(e).class == .string || as_obj(e).class == .number) {
					item = to_str(ctx, e)
					if item == nil {return EXCEPTION}
				}
				if item == nil {continue}
				a := atom_from_string(rt, item)
				dup := false
				for x in w.prop_list {if x == a {dup = true; break}}
				if !dup {append(&w.prop_list, a)}
			}
		}
	}
	sp := space
	if sp.tag == .object {
		#partial switch as_obj(sp).class {
		case .number:
			d, ok := to_number(ctx, sp)
			if !ok {return EXCEPTION}
			sp = mk_number(d)
		case .string:
			s := to_str(ctx, sp)
			if s == nil {return EXCEPTION}
			sp = mk_str(s)
		}
	}
	if is_number(sp) {
		d, _ := to_integer(ctx, sp)
		k := int(clamp(d, 0, 10))
		w.gap = str_sub(rt, str_from_latin1(rt, transmute([]u8)string("          ")), 0, k)
	} else if sp.tag == .string {
		s := as_str(sp)
		w.gap = str_sub(rt, s, 0, min(int(s.len), 10))
	}
	wrapper := new_plain_object(ctx)
	create_data_property(ctx, wrapper, pa(.A_empty_string), v, false)
	r := json_property(&w, mk_obj(wrapper), pa(.A_empty_string), v)
	if r < 0 {sb_destroy(&w.sb); return EXCEPTION}
	if r == 0 {sb_destroy(&w.sb); return UNDEFINED}
	return sb_finish_value(ctx, &w.sb)
}

@(private = "file")
json_stringify :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	return json_stringify_value(ctx, arg(args, 0), arg(args, 1), arg(args, 2))
}

@(private = "file")
is_raw_json :: proc(o: ^Object) -> bool {
	return o.shape.proto == nil && !o.extensible && len(o.shape.props) == 1 && o.shape.props[0].atom == pa(.A_rawJSON)
}

@(private = "file")
json_raw :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	s := to_str(ctx, arg(args, 0))
	if s == nil {return EXCEPTION}
	f := str_flat(rt, s)
	if f.len == 0 {return throw_syntax_error(ctx, "JSON.rawJSON: empty string")}
	c0, c1 := str_at(f, 0), str_at(f, int(f.len) - 1)
	bad :: proc(c: u16) -> bool {return c == '\t' || c == '\n' || c == '\r' || c == ' '}
	if bad(c0) || bad(c1) {return throw_syntax_error(ctx, "JSON.rawJSON: leading or trailing whitespace")}
	p := JSON_Parser{ctx = ctx, s = f, n = int(f.len)}
	v := jp_value(&p, 0)
	if is_exception(v) {return EXCEPTION}
	if p.pos < p.n {return jp_fail(&p, "unexpected data after the value")}
	if v.tag == .object {return throw_syntax_error(ctx, "JSON.rawJSON: only primitive values are allowed")}
	o := object_new_proto(ctx, nil)
	define_value(ctx, o, pa(.A_rawJSON), mk_str(f), CWE)
	o.extensible = false
	set_property_flags(rt, o, 0, {.enumerable}, .data)
	return mk_obj(o)
}

@(private = "file")
json_is_raw :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	v := arg(args, 0)
	return mk_bool(v.tag == .object && is_raw_json(as_obj(v)))
}

init_json_builtins :: proc(ctx: ^Context) {
	j := new_plain_object(ctx)
	def_value(ctx, ctx.global_obj, "JSON", mk_obj(j))
	def_method(ctx, j, "parse", json_parse, 2)
	def_method(ctx, j, "stringify", json_stringify, 3)
	def_method(ctx, j, "rawJSON", json_raw, 1)
	def_method(ctx, j, "isRawJSON", json_is_raw, 1)
	def_tag(ctx, j, "JSON")
}
