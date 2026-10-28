package jsrt

// Date (ECMA-262 §21.4) on the calendar arithmetic of src/engine/datetime (package jsdate). The clock
// and the local time zone come from the host (date_now_hook, jsdate.timezone_offset_proc).

import "core:math"
import jsdate "wb:engine/datetime"

// Milliseconds since the epoch (the host sets it; without one the clock reads 0).
date_now_hook: proc() -> f64

@(private = "file")
date_now :: proc() -> f64 {
	if date_now_hook != nil {return math.trunc(date_now_hook())}
	return 0
}

@(private = "file")
this_date :: proc(ctx: ^Context, this: Value) -> (^Object, bool) {
	if this.tag == .object && as_obj(this).class == .date {return as_obj(this), true}
	throw_type_error(ctx, "not a Date object")
	return nil, false
}

@(private = "file")
date_value :: #force_inline proc(o: ^Object) -> f64 {return o.data.(Date_Data).t}

@(private = "file")
date_ctor :: proc(ctx: ^Context, nt: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if is_undefined(nt) {
		return date_to_string_value(ctx, date_now(), .ToString, .All, true)
	}
	t: f64
	switch len(args) {
	case 0:
		t = date_now()
	case 1:
		v := args[0]
		if v.tag == .object && as_obj(v).class == .date {
			t = date_value(as_obj(v))
		} else {
			p := to_primitive(ctx, v)
			if is_exception(p) {return EXCEPTION}
			if p.tag == .string {
				t = jsdate.parse(str_to_utf8(rt, as_str(p), tmp(rt)))
			} else {
				d, ok := to_number(ctx, p)
				if !ok {return EXCEPTION}
				t = jsdate.time_clip(d)
			}
		}
	case:
		f, ok := fields_from_args(ctx, args)
		if !ok {return EXCEPTION}
		t = jsdate.time_clip(jsdate.set_date_fields(f, true))
		if math.is_nan(f[0]) {t = NAN}
	}
	proto, ok := proto_from_ctor(ctx, nt, .date)
	if !ok {return EXCEPTION}
	o := object_new_proto(ctx, proto, .date)
	o.data = Date_Data{jsdate.time_clip(t)}
	return mk_obj(o)
}

@(private = "file")
fields_from_args :: proc(ctx: ^Context, args: []Value) -> (jsdate.Fields, bool) {
	f := jsdate.Fields{0, 0, 1, 0, 0, 0, 0, 0, 0}
	valid := true
	for i in 0 ..< min(len(args), 7) {
		d, ok := to_number(ctx, args[i])
		if !ok {return f, false}
		if !is_finite_f64(d) {valid = false}
		f[i] = math.trunc(d)
		if i == 0 && f[0] >= 0 && f[0] <= 99 {f[0] += 1900}
	}
	if !valid {f[0] = NAN}
	return f, true
}

@(private = "file")
date_utc :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	if len(args) == 0 {return mk_float(NAN)}
	f, ok := fields_from_args(ctx, args)
	if !ok {return EXCEPTION}
	if math.is_nan(f[0]) {return mk_float(NAN)}
	return mk_number(jsdate.time_clip(jsdate.set_date_fields(f, false)))
}

@(private = "file")
date_parse_fn :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	s := to_str(ctx, arg(args, 0))
	if s == nil {return EXCEPTION}
	return mk_number(jsdate.parse(str_to_utf8(rt, s, tmp(rt))))
}

@(private = "file")
date_now_fn :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	return mk_number(date_now())
}

// getters: magic = field << 4 | is_local
@(private = "file")
date_get_field :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, ok := this_date(ctx, this)
	if !ok {return EXCEPTION}
	f, valid := jsdate.get_date_fields(date_value(o), magic & 1 != 0, false)
	if !valid {return mk_float(NAN)}
	field := magic >> 4
	if field == 9 {return mk_number(f[0] - 1900)} // getYear
	return mk_number(f[field])
}

@(private = "file")
date_get_time :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, ok := this_date(ctx, this)
	if !ok {return EXCEPTION}
	return mk_number(date_value(o))
}

@(private = "file")
date_tz_offset :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, ok := this_date(ctx, this)
	if !ok {return EXCEPTION}
	t := date_value(o)
	if math.is_nan(t) {return mk_float(NAN)}
	if jsdate.timezone_offset_proc == nil {return mk_int(0)}
	return mk_int(i32(jsdate.timezone_offset_proc(i64(t))))
}

// setters: magic = first << 8 | end << 4 | is_local
@(private = "file")
date_set_field :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, ok := this_date(ctx, this)
	if !ok {return EXCEPTION}
	first := int((magic >> 8) & 0xf)
	end := int((magic >> 4) & 0xf)
	is_local := magic & 1 != 0
	t := date_value(o)
	f, res := jsdate.get_date_fields(t, is_local, first == 0)
	valid_before := res
	n := min(len(args), end - first)
	for i in 0 ..< n {
		a, ok2 := to_number(ctx, args[i])
		if !ok2 {return EXCEPTION}
		if !is_finite_f64(a) {res = false}
		f[first + i] = math.trunc(a)
	}
	// an invalid date stays untouched (the arguments are still converted, in order)
	if !valid_before {return mk_float(NAN)}
	d := NAN
	if res && len(args) > 0 {d = jsdate.time_clip(jsdate.set_date_fields(f, is_local))}
	o.data = Date_Data{d}
	return mk_number(d)
}

@(private = "file")
date_set_time :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, ok := this_date(ctx, this)
	if !ok {return EXCEPTION}
	d, ok2 := to_number(ctx, arg(args, 0))
	if !ok2 {return EXCEPTION}
	v := jsdate.time_clip(d)
	o.data = Date_Data{v}
	return mk_number(v)
}

@(private = "file")
date_set_year :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, ok := this_date(ctx, this)
	if !ok {return EXCEPTION}
	y, ok2 := to_number(ctx, arg(args, 0))
	if !ok2 {return EXCEPTION}
	t := date_value(o)
	f, _ := jsdate.get_date_fields(t, true, true)
	if !is_finite_f64(y) {
		o.data = Date_Data{NAN}
		return mk_float(NAN)
	}
	yi := math.trunc(y)
	if yi >= 0 && yi <= 99 {yi += 1900}
	f[0] = yi
	d := jsdate.time_clip(jsdate.set_date_fields(f, true))
	o.data = Date_Data{d}
	return mk_number(d)
}

date_to_string_value :: proc(ctx: ^Context, t: f64, fmt: jsdate.Format, part: jsdate.Part, local: bool) -> Value {
	rt := ctx.rt
	if math.is_nan(t) {
		if fmt == .ISO {return throw_range_error(ctx, "Date value is NaN")}
		return new_string(ctx, "Invalid Date")
	}
	f, _ := jsdate.get_date_fields(t, local, false)
	buf: [96]u8
	n := jsdate.format_date(buf[:], f, fmt, part)
	if n < 0 {return throw_range_error(ctx, "Date value is NaN")}
	return mk_str(str_from_latin1(rt, buf[:n]))
}

// magic = fmt << 4 | part << 1 | local
@(private = "file")
date_to_string :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o, ok := this_date(ctx, this)
	if !ok {return EXCEPTION}
	fmt := jsdate.Format(magic >> 4)
	part := jsdate.Part((magic >> 1) & 3)
	return date_to_string_value(ctx, date_value(o), fmt, part, magic & 1 != 0)
}

@(private = "file")
date_to_json :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	o := to_object(ctx, this)
	if is_exception(o) {return EXCEPTION}
	tv := to_primitive(ctx, o, .number)
	if is_exception(tv) {return EXCEPTION}
	if is_number(tv) && !is_finite_f64(as_f64(tv)) {return NULL}
	return invoke(ctx, o, atom_from_utf8(ctx.rt, "toISOString"), {})
}

@(private = "file")
date_to_primitive :: proc(ctx: ^Context, this: Value, args: []Value, magic: i32) -> Value {
	rt := ctx.rt
	if this.tag != .object {return throw_type_error(ctx, "not an object")}
	h := arg(args, 0)
	if h.tag != .string {return throw_type_error(ctx, "invalid hint")}
	hs := as_str(h)
	hint: Hint
	switch {
	case str_eq_ascii(rt, hs, "string"), str_eq_ascii(rt, hs, "default"): hint = .string
	case str_eq_ascii(rt, hs, "number"): hint = .number
	case: return throw_type_error(ctx, "invalid hint")
	}
	return ordinary_to_primitive(ctx, this, hint)
}

init_date_builtins :: proc(ctx: ^Context) {
	dp := ctx.class_proto[.date]
	dc := def_ctor(ctx, "Date", date_ctor, 7, dp)
	def_method(ctx, dc, "UTC", date_utc, 7)
	def_method(ctx, dc, "parse", date_parse_fn, 1)
	def_method(ctx, dc, "now", date_now_fn, 0)
	gf :: proc(field: int, local: bool) -> i32 {return i32(field << 4) | (local ? 1 : 0)}
	getters := [?]struct {
		name:  string,
		field: int,
		local: bool,
	} {
		{"getFullYear", 0, true}, {"getUTCFullYear", 0, false}, {"getMonth", 1, true}, {"getUTCMonth", 1, false},
		{"getDate", 2, true}, {"getUTCDate", 2, false}, {"getHours", 3, true}, {"getUTCHours", 3, false},
		{"getMinutes", 4, true}, {"getUTCMinutes", 4, false}, {"getSeconds", 5, true}, {"getUTCSeconds", 5, false},
		{"getMilliseconds", 6, true}, {"getUTCMilliseconds", 6, false}, {"getDay", 7, true}, {"getUTCDay", 7, false},
		{"getYear", 9, true},
	}
	for g in getters {def_method(ctx, dp, g.name, date_get_field, 0, gf(g.field, g.local))}
	def_method(ctx, dp, "getTime", date_get_time, 0)
	def_method(ctx, dp, "valueOf", date_get_time, 0)
	def_method(ctx, dp, "getTimezoneOffset", date_tz_offset, 0)
	sf :: proc(first, end: int, local: bool) -> i32 {return i32(first << 8 | end << 4) | (local ? 1 : 0)}
	setters := [?]struct {
		name:        string,
		first, end:  int,
		local:       bool,
		length:      int,
	} {
		{"setMilliseconds", 6, 7, true, 1}, {"setUTCMilliseconds", 6, 7, false, 1},
		{"setSeconds", 5, 7, true, 2}, {"setUTCSeconds", 5, 7, false, 2},
		{"setMinutes", 4, 7, true, 3}, {"setUTCMinutes", 4, 7, false, 3},
		{"setHours", 3, 7, true, 4}, {"setUTCHours", 3, 7, false, 4},
		{"setDate", 2, 3, true, 1}, {"setUTCDate", 2, 3, false, 1},
		{"setMonth", 1, 3, true, 2}, {"setUTCMonth", 1, 3, false, 2},
		{"setFullYear", 0, 3, true, 3}, {"setUTCFullYear", 0, 3, false, 3},
	}
	for s in setters {def_method(ctx, dp, s.name, date_set_field, s.length, sf(s.first, s.end, s.local))}
	def_method(ctx, dp, "setTime", date_set_time, 1)
	def_method(ctx, dp, "setYear", date_set_year, 1)
	tf :: proc(fmt: jsdate.Format, part: jsdate.Part, local: bool) -> i32 {return i32(int(fmt) << 4 | int(part) << 1) | (local ? 1 : 0)}
	utc := def_method(ctx, dp, "toUTCString", date_to_string, 0, tf(.UTC, .All, false))
	def_value(ctx, dp, "toGMTString", mk_obj(utc))
	def_method(ctx, dp, "toString", date_to_string, 0, tf(.ToString, .All, true))
	def_method(ctx, dp, "toDateString", date_to_string, 0, tf(.ToString, .Date, true))
	def_method(ctx, dp, "toTimeString", date_to_string, 0, tf(.ToString, .Time, true))
	def_method(ctx, dp, "toISOString", date_to_string, 0, tf(.ISO, .All, false))
	def_method(ctx, dp, "toLocaleString", date_to_string, 0, tf(.Locale, .All, true))
	def_method(ctx, dp, "toLocaleDateString", date_to_string, 0, tf(.Locale, .Date, true))
	def_method(ctx, dp, "toLocaleTimeString", date_to_string, 0, tf(.Locale, .Time, true))
	def_method(ctx, dp, "toJSON", date_to_json, 1)
	def_method_sym(ctx, dp, .to_primitive, date_to_primitive, 1, 0, {.configurable})
}
