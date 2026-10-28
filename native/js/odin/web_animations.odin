// web_animations.odin: Web Animations for JavaScript (Element.animate, Animation, KeyframeEffect, document.timeline,
// AnimationPlaybackEvent) and the details of the browser's AnimationEvent / TransitionEvent. Ported from
// native/js/runtime/web_animations.c, same symbols (wj_cb_animation, the notify export) and messages.
//
// The browser keeps each animation's timing model and plays its effect (module animations,
// src/page/web_animations.odin; the calls are declared in api_decl/animations.odin and go through jsb). What is here
// is what needs the language: the arguments read as Web Animations says (a keyframes argument in both of its forms,
// the timing dictionaries), the KeyframeEffect object (its keyframes, as getKeyframes returns them, and its timing,
// sent to the browser packed whenever the effect belongs to an animation), and the ready / finished promises, settled
// from what the browser reports (Animation_takeOps) in the notify microtask of the animation. An animation's wrapper
// is kept alive while the browser says it may still matter (k / u: running, pending, events to fire, an effect
// shown); a new one is kept until the first report.
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

@(private = "file") Animation :: api_decl.Animation
@(private = "file") none: abi.Nothing

// the interfaces whose objects are the engine's (by name: jsb.iface_of)
@(private = "file") KeyframeEffect         :: distinct u64
@(private = "file") AnimationEffect        :: distinct u64
@(private = "file") AnimationTimeline      :: distinct u64
@(private = "file") DocumentTimeline       :: distinct u64
@(private = "file") CSSAnimation           :: distinct u64
@(private = "file") CSSTransition          :: distinct u64
@(private = "file") AnimationPlaybackEvent :: distinct u64
@(private = "file") AnimationEvent         :: distinct u64
@(private = "file") TransitionEvent        :: distinct u64
@(private = "file") Element                :: distinct u64
@(private = "file") Document               :: distinct u64
@(private = "file") ShadowRoot             :: distinct u64

@(private = "file") NAN :: f64(0h7FF8_0000_0000_0000)
@(private = "file") NEG_INF :: f64(0hFFF0_0000_0000_0000)

@(private = "file") FILL_NAMES                := [5]string{"none", "forwards", "backwards", "both", "auto"}
@(private = "file") FILL_AUTO                 :: 4
@(private = "file") DIRECTION_NAMES           := [4]string{"normal", "reverse", "alternate", "alternate-reverse"}
@(private = "file") COMPOSITE_NAMES           := [3]string{"replace", "add", "accumulate"}
@(private = "file") COMPOSITE_AUTO_NAMES      := [4]string{"replace", "add", "accumulate", "auto"}
@(private = "file") ITERATION_COMPOSITE_NAMES := [2]string{"replace", "accumulate"}
@(private = "file") PLAY_STATE_NAMES          := [4]string{"idle", "running", "paused", "finished"}
@(private = "file") REPLACE_STATE_NAMES       := [3]string{"active", "removed", "persisted"}

@(private = "file") is_nan :: #force_inline proc "contextless" (x: f64) -> bool { return x != x }
@(private = "file") is_finite :: #force_inline proc "contextless" (x: f64) -> bool { return x == x && x - x == 0 }

@(private = "file")
index_of :: proc "contextless" (names: []string, s: []u8) -> i32 {
	for n, i in names { if n == string(s) { return i32(i) } }
	return -1
}

// wj_check_enum's TypeError (the C took a NULL-terminated table; these are Odin slices). Frees s.
@(private = "file")
enum_throw :: proc "contextless" (ctx: ^wj.Context, s: ^wj.Str, type: cstring) -> bool {
	shown := i32(min(s.len, 64))
	wj.JS_ThrowTypeError(ctx, "The provided value '%.*s' is not a valid enum value of type %s.", shown, wj.cstr_bytes(s.ptr), type)
	wj.wj_str_free(ctx, s)
	return false
}

@(private = "file")
name_value :: #force_inline proc "contextless" (ctx: ^wj.Context, names: []string, i: i32) -> wj.JSValue {
	return wj.new_string_len(ctx, names[i])
}

// ---- timing ----

@(private = "file")
Timing :: struct {
	delay, end_delay: f64,
	duration:         f64,   // NaN: "auto"
	iterations:       f64,
	iteration_start:  f64,
	fill, direction:  i32,
	easing:           [^]u8, // libc-allocated, NUL-terminated; nil: "linear"
}

@(private = "file") TIMING_DEFAULT :: Timing{duration = NAN, iterations = 1, fill = FILL_AUTO}

@(private = "file")
easing_text :: proc "contextless" (t: ^Timing) -> string {
	return t.easing != nil ? string(t.easing[:wj.strlen(cstring(t.easing))]) : "linear"
}

@(private = "file")
easing_check :: proc(ctx: ^wj.Context, s: []u8) -> bool {
	ok: bool
	jsb.host(&ok, api_decl.Animation_validEasing, wj.wr_Animation_validEasing, string(s))
	if ok { return true }
	wj.JS_ThrowTypeError(ctx, "'%.*s' is not a valid value for easing", i32(min(len(s), 64)), wj.cstr_bytes(raw_data(s)))
	return false
}

@(private = "file")
read_double :: proc "contextless" (ctx: ^wj.Context, dict: wj.JSValue, name: cstring, restricted: bool, has: ^bool, out: ^f64) -> bool {
	has^ = false
	v: wj.JSValue
	if !wj.web_dict_get(ctx, dict, name, &v) { return false }
	if wj.is_undefined(v) { return true }
	ok := wj.wj_to_double(ctx, v, out, restricted)
	wj.JS_FreeValue(ctx, v)
	has^ = ok
	return ok
}

@(private = "file")
read_enum :: proc "contextless" (ctx: ^wj.Context, dict: wj.JSValue, name: cstring, names: []string, type: cstring, has: ^bool, out: ^i32) -> bool {
	has^ = false
	v: wj.JSValue
	if !wj.web_dict_get(ctx, dict, name, &v) { return false }
	if wj.is_undefined(v) { return true }
	s: wj.Str
	ok := wj.wj_to_str(ctx, v, &s, 0, "")
	wj.JS_FreeValue(ctx, v)
	if !ok { return false }
	i := index_of(names, wj.str_slice(s))
	if i < 0 { return enum_throw(ctx, &s, type) }
	wj.wj_str_free(ctx, &s)
	out^ = i
	has^ = true
	return true
}

// Reads EffectTiming / OptionalEffectTiming members of `dict` into `t` (members absent keep their value), checked as
// "update the timing properties of an animation effect" says before anything changes.
@(private = "file")
timing_read :: proc(ctx: ^wj.Context, dict: wj.JSValue, t: ^Timing) -> bool {
	n := t^
	n.easing = nil
	has: bool
	d: f64
	e: i32
	easing: [^]u8
	fail :: proc "contextless" (easing: [^]u8) -> bool { if easing != nil { wj.libc_free(easing) }; return false }
	if !read_double(ctx, dict, "delay", true, &has, &d) { return false }
	if has { n.delay = d }
	if !read_enum(ctx, dict, "direction", DIRECTION_NAMES[:], "PlaybackDirection", &has, &e) { return false }
	if has { n.direction = e }
	dur: wj.JSValue
	if !wj.web_dict_get(ctx, dict, "duration", &dur) { return false }
	if !wj.is_undefined(dur) {
		if wj.is_string(dur) {
			s := wj.JS_ToCString(ctx, dur)
			is_auto := s != nil && wj.str_eq(s, "auto")
			if s != nil { wj.JS_FreeCString(ctx, s) }
			wj.JS_FreeValue(ctx, dur)
			if !is_auto { wj.JS_ThrowTypeError(ctx, "duration must be a non-negative number or the string 'auto'"); return false }
			n.duration = NAN
		} else {
			ok := wj.wj_to_double(ctx, dur, &d, false)
			wj.JS_FreeValue(ctx, dur)
			if !ok { return false }
			if is_nan(d) || d < 0 { wj.JS_ThrowTypeError(ctx, "duration must be a non-negative number or the string 'auto'"); return false }
			n.duration = d
		}
	}
	ez: wj.JSValue
	if !wj.web_dict_get(ctx, dict, "easing", &ez) { return false }
	if !wj.is_undefined(ez) {
		s: wj.Str
		ok := wj.wj_to_str(ctx, ez, &s, 0, "")
		wj.JS_FreeValue(ctx, ez)
		if !ok { return false }
		if !easing_check(ctx, wj.str_slice(s)) { wj.wj_str_free(ctx, &s); return false }
		easing = wj.web_strndup(wj.cstr_bytes(s.ptr), s.len)
		wj.wj_str_free(ctx, &s)
		if easing == nil { wj.JS_ThrowOutOfMemory(ctx); return false }
	}
	if !read_double(ctx, dict, "endDelay", true, &has, &d) { return fail(easing) }
	if has { n.end_delay = d }
	if !read_enum(ctx, dict, "fill", FILL_NAMES[:], "FillMode", &has, &e) { return fail(easing) }
	if has { n.fill = e }
	if !read_double(ctx, dict, "iterationStart", true, &has, &d) { return fail(easing) }
	if has {
		if d < 0 { wj.JS_ThrowTypeError(ctx, "iterationStart must be non-negative"); return fail(easing) }
		n.iteration_start = d
	}
	if !read_double(ctx, dict, "iterations", false, &has, &d) { return fail(easing) }
	if has {
		if is_nan(d) || d < 0 { wj.JS_ThrowTypeError(ctx, "iterations must be non-negative"); return fail(easing) }
		n.iterations = d
	}
	if easing != nil {
		if t.easing != nil { wj.libc_free(t.easing) }
		n.easing = easing
	} else {
		n.easing = t.easing
	}
	t^ = n
	return true
}

// KeyframeEffectOptions or a duration
@(private = "file")
timing_from_options :: proc(ctx: ^wj.Context, opt: wj.JSValue, t: ^Timing) -> bool {
	if wj.is_nullish(opt) || wj.is_object(opt) { return timing_read(ctx, opt, t) }
	d: f64
	if !wj.wj_to_double(ctx, opt, &d, false) { return false }
	if is_nan(d) || d < 0 { wj.JS_ThrowTypeError(ctx, "duration must be a non-negative number"); return false }
	t.duration = d
	return true
}

@(private = "file")
active_duration :: proc "contextless" (t: ^Timing) -> f64 {
	dur := is_nan(t.duration) ? 0 : t.duration
	if dur == 0 || t.iterations == 0 { return 0 }
	return dur * t.iterations
}

// ---- a growable byte buffer (the packed keyframes) ----

@(private = "file")
Pack :: struct {
	p:      [^]u8,
	n, cap: int,
	failed: bool,
}

@(private = "file")
pack_put :: proc "contextless" (b: ^Pack, s: string) {
	if b.failed || len(s) == 0 { return }
	if b.n + len(s) > b.cap {
		cap := max(b.cap * 2, b.n + len(s), 256)
		q := ([^]u8)(wj.libc_realloc(b.p, uint(cap)))
		if q == nil { b.failed = true; return }
		b.p = q
		b.cap = cap
	}
	for i in 0 ..< len(s) { b.p[b.n + i] = s[i] }
	b.n += len(s)
}

// a value as the browser takes it: the separators \x1e and \x1f dropped
@(private = "file")
pack_put_clean :: proc "contextless" (b: ^Pack, s: string) {
	start := 0
	for i in 0 ..< len(s) {
		if s[i] == 0x1e || s[i] == 0x1f { pack_put(b, s[start:i]); start = i + 1 }
	}
	pack_put(b, s[start:])
}

@(private = "file")
pack_free :: proc "contextless" (b: ^Pack) {
	if b.p != nil { wj.libc_free(b.p) }
	b^ = {}
}

// ---- keyframes ----

// Whether a keyframe member names a property (Web Animations 1 §5.10.3, "animation property name to IDL attribute
// name"): a custom property, or a camel-cased name without a hyphen.
@(private = "file")
css_name_ok :: proc "contextless" (s: string) -> bool {
	if len(s) >= 2 && s[0] == '-' && s[1] == '-' { return true }
	if len(s) == 0 { return false }
	for i in 0 ..< len(s) { if s[i] == '-' { return false } }
	return true
}

// The CSS name of a member that names a property ("backgroundColor" -> "background-color", "cssFloat" -> "float").
@(private = "file")
css_name_put :: proc "contextless" (b: ^Pack, s: string) {
	if len(s) >= 2 && s[0] == '-' && s[1] == '-' { pack_put(b, s); return }
	if s == "cssFloat" { pack_put(b, "float"); return }
	if s == "cssOffset" { pack_put(b, "offset"); return }
	i := 0
	if len(s) > 6 && s[:6] == "webkit" && s[6] >= 'A' && s[6] <= 'Z' { pack_put(b, "-webkit"); i = 6 }
	for ; i < len(s); i += 1 {
		c := s[i]
		if c >= 'A' && c <= 'Z' {
			x := [2]u8{'-', c - 'A' + 'a'}
			pack_put(b, string(x[:]))
		} else {
			pack_put(b, s[i:i + 1])
		}
	}
}

@(private = "file")
reserved_member :: proc "contextless" (s: string) -> bool {
	return s == "offset" || s == "easing" || s == "composite" || s == "computedOffset"
}

// A key of a record as a NUL-terminated string (JS_ToCString's: free with JS_FreeCString) and its length.
@(private = "file")
key_string :: proc "contextless" (ctx: ^wj.Context, key: wj.JSValue) -> (cstring, string) {
	n: uint
	k := wj.to_cstring_len(ctx, &n, key)
	if k == nil { return nil, "" }
	return k, string(([^]u8)(rawptr(k))[:n])
}

// A new normalized keyframe: {offset, easing, composite} (computedOffset is added once known).
@(private = "file")
frame_new :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue {
	f := wj.JS_NewObject(ctx)
	if wj.is_exception(f) { return f }
	wj.JS_SetPropertyStr(ctx, f, "offset", wj.NULL)
	wj.JS_SetPropertyStr(ctx, f, "easing", wj.new_string(ctx, "linear"))
	wj.JS_SetPropertyStr(ctx, f, "composite", wj.new_string(ctx, "auto"))
	return f
}

@(private = "file") Seq_State :: struct { frames: wj.JSValue, n: u32 }

@(private = "file")
member_copy :: proc "c" (ctx: ^wj.Context, key: wj.JSValue, value: wj.JSValue, opaque: rawptr) -> bool {
	frame := (^wj.JSValue)(opaque)^
	k, ks := key_string(ctx, key)
	if k == nil { return false }
	ok := true
	if !reserved_member(ks) && css_name_ok(ks) {
		s := wj.JS_ToString(ctx, value)   // the value in the sequence form: a string (an array as its string)
		if wj.is_exception(s) { ok = false } else { wj.JS_SetPropertyStr(ctx, frame, k, s) }
	}
	wj.JS_FreeCString(ctx, k)
	return ok
}

// offset / easing / composite of one keyframe object (BaseKeyframe)
@(private = "file")
base_keyframe :: proc "contextless" (ctx: ^wj.Context, src: wj.JSValue, frame: wj.JSValue) -> bool {
	v: wj.JSValue
	if !wj.web_dict_get(ctx, src, "offset", &v) { return false }
	if !wj.is_nullish(v) {
		d: f64
		ok := wj.wj_to_double(ctx, v, &d, true)
		wj.JS_FreeValue(ctx, v)
		if !ok { return false }
		wj.JS_SetPropertyStr(ctx, frame, "offset", wj.new_float64(ctx, d))
	} else {
		wj.JS_FreeValue(ctx, v)
	}
	if !wj.web_dict_get(ctx, src, "easing", &v) { return false }
	if !wj.is_undefined(v) {
		s := wj.JS_ToString(ctx, v)
		wj.JS_FreeValue(ctx, v)
		if wj.is_exception(s) { return false }
		wj.JS_SetPropertyStr(ctx, frame, "easing", s)
	}
	e: i32
	has: bool
	if !read_enum(ctx, src, "composite", COMPOSITE_AUTO_NAMES[:], "CompositeOperationOrAuto", &has, &e) { return false }
	if has { wj.JS_SetPropertyStr(ctx, frame, "composite", name_value(ctx, COMPOSITE_AUTO_NAMES[:], e)) }
	return true
}

@(private = "file")
seq_item :: proc "c" (ctx: ^wj.Context, item: wj.JSValue, opaque: rawptr) -> bool {
	st := (^Seq_State)(opaque)
	if !wj.is_nullish(item) && !wj.is_object(item) {
		wj.JS_ThrowTypeError(ctx, "Failed to execute 'animate': a keyframe is not an object")
		return false
	}
	frame := frame_new(ctx)
	if wj.is_exception(frame) { return false }
	ok := base_keyframe(ctx, item, frame) && (!wj.is_object(item) || wj.web_for_record(ctx, item, member_copy, &frame))
	if !ok { wj.JS_FreeValue(ctx, frame); return false }
	wj.array_set(ctx, st.frames, st.n, frame)
	st.n += 1
	return true
}

@(private = "file")
frame_offset :: proc "contextless" (ctx: ^wj.Context, frame: wj.JSValue, name: cstring, has: ^bool) -> f64 {
	v := wj.JS_GetPropertyStr(ctx, frame, name)
	d: f64
	has^ = wj.is_number(v)
	if has^ { wj.JS_ToFloat64(ctx, &d, v) }
	wj.JS_FreeValue(ctx, v)
	return d
}

// A list member of a property-indexed keyframe (a value, or a sequence of them): an array (counted).
@(private = "file")
as_list :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue) -> wj.JSValue {
	it := wj.web_is_iterable(ctx, v)
	if it < 0 { return wj.EXCEPTION }
	if it != 0 && !wj.is_string(v) {
		from := wj.JS_GetPropertyStr(ctx, wj.realm_global(), "Array")
		fn := wj.JS_GetPropertyStr(ctx, from, "from")
		arg := v
		r := wj.JS_Call(ctx, fn, from, 1, &arg)
		wj.JS_FreeValue(ctx, fn)
		wj.JS_FreeValue(ctx, from)
		return r
	}
	a := wj.JS_NewArray(ctx)
	if !wj.is_exception(a) { wj.array_set(ctx, a, 0, wj.JS_DupValue(ctx, v)) }
	return a
}

@(private = "file")
list_length :: proc "contextless" (ctx: ^wj.Context, a: wj.JSValue) -> u32 {
	n: i64
	wj.JS_GetLength(ctx, a, &n)
	return u32(max(n, 0))
}

@(private = "file") Pi_State :: struct { frames: wj.JSValue, n: u32, src: wj.JSValue }

// the frame at computed offset `off` (made, in order, when there is none)
@(private = "file")
pi_frame_at :: proc "contextless" (ctx: ^wj.Context, st: ^Pi_State, off: f64) -> wj.JSValue {
	at := st.n
	for i in 0 ..< st.n {
		f := wj.JS_GetPropertyUint32(ctx, st.frames, i)
		has: bool
		o := frame_offset(ctx, f, "computedOffset", &has)
		if o == off { return f }
		wj.JS_FreeValue(ctx, f)
		if o > off { at = i; break }
	}
	f := frame_new(ctx)
	if wj.is_exception(f) { return f }
	wj.JS_SetPropertyStr(ctx, f, "computedOffset", wj.new_float64(ctx, off))
	for i := st.n; i > at; i -= 1 { wj.array_set(ctx, st.frames, i, wj.JS_GetPropertyUint32(ctx, st.frames, i - 1)) }
	wj.array_set(ctx, st.frames, at, wj.JS_DupValue(ctx, f))
	st.n += 1
	return f
}

@(private = "file")
pi_member :: proc "c" (ctx: ^wj.Context, key: wj.JSValue, value: wj.JSValue, opaque: rawptr) -> bool {
	st := (^Pi_State)(opaque)
	k, ks := key_string(ctx, key)
	if k == nil { return false }
	defer wj.JS_FreeCString(ctx, k)
	if reserved_member(ks) || !css_name_ok(ks) { return true }
	list := as_list(ctx, value)
	if wj.is_exception(list) { return false }
	defer wj.JS_FreeValue(ctx, list)
	n := list_length(ctx, list)
	for i in 0 ..< n {
		v := wj.JS_GetPropertyUint32(ctx, list, i)
		s := wj.JS_ToString(ctx, v)
		wj.JS_FreeValue(ctx, v)
		if wj.is_exception(s) { return false }
		f := pi_frame_at(ctx, st, n == 1 ? 1.0 : f64(i) / f64(n - 1))
		if wj.is_exception(f) { wj.JS_FreeValue(ctx, s); return false }
		wj.JS_SetPropertyStr(ctx, f, k, s)
		wj.JS_FreeValue(ctx, f)
	}
	return true
}

// offset, easing, composite of a property-indexed keyframe, given to the frames in order (easings and composites
// repeat when there are fewer than frames)
@(private = "file")
pi_spread :: proc "contextless" (ctx: ^wj.Context, st: ^Pi_State) -> bool {
	names := [3]cstring{"offset", "easing", "composite"}
	for m in 0 ..< 3 {
		v: wj.JSValue
		if !wj.web_dict_get(ctx, st.src, names[m], &v) { return false }
		if wj.is_undefined(v) { continue }
		list := (m == 0 && wj.is_null(v)) ? wj.JS_NewArray(ctx) : as_list(ctx, v)
		wj.JS_FreeValue(ctx, v)
		if wj.is_exception(list) { return false }
		n := list_length(ctx, list)
		for i in 0 ..< st.n {
			if n == 0 || (m == 0 && i >= n) { break }
			x := wj.JS_GetPropertyUint32(ctx, list, m == 0 ? i : i % n)
			f := wj.JS_GetPropertyUint32(ctx, st.frames, i)
			ok := true
			if m == 0 {
				if !wj.is_null(x) {
					d: f64
					ok = wj.wj_to_double(ctx, x, &d, true)
					if ok { wj.JS_SetPropertyStr(ctx, f, "offset", wj.new_float64(ctx, d)) }
				}
			} else {
				s: wj.Str
				ok = wj.wj_to_str(ctx, x, &s, 0, "")
				if ok && m == 2 {
					e := index_of(COMPOSITE_AUTO_NAMES[:], wj.str_slice(s))
					if e < 0 {
						ok = enum_throw(ctx, &s, "CompositeOperationOrAuto")
					} else {
						wj.JS_SetPropertyStr(ctx, f, "composite", name_value(ctx, COMPOSITE_AUTO_NAMES[:], e))
						wj.wj_str_free(ctx, &s)
					}
				} else if ok {
					wj.JS_SetPropertyStr(ctx, f, "easing", wj.new_string_len(ctx, wj.str_slice(s)))
					wj.wj_str_free(ctx, &s)
				}
			}
			wj.JS_FreeValue(ctx, f)
			wj.JS_FreeValue(ctx, x)
			if !ok { wj.JS_FreeValue(ctx, list); return false }
		}
		wj.JS_FreeValue(ctx, list)
	}
	return true
}

// "Process a keyframes argument" (Web Animations 1 §5.10.3): the normalized keyframes (an array, counted), offsets
// checked and computed, easings checked.
@(private = "file")
keyframes_process :: proc(ctx: ^wj.Context, kf: wj.JSValue) -> wj.JSValue {
	frames := wj.JS_NewArray(ctx)
	if wj.is_exception(frames) || wj.is_nullish(kf) { return frames }
	if !wj.is_object(kf) { wj.JS_FreeValue(ctx, frames); return wj.JS_ThrowTypeError(ctx, "keyframes must be an object or null") }
	it := wj.web_is_iterable(ctx, kf)
	if it < 0 { wj.JS_FreeValue(ctx, frames); return wj.EXCEPTION }
	n: u32
	sequence := it > 0
	if sequence {
		st := Seq_State{frames, 0}
		if !wj.web_for_of(ctx, kf, seq_item, &st) { wj.JS_FreeValue(ctx, frames); return wj.EXCEPTION }
		n = st.n
	} else {
		st := Pi_State{frames, 0, kf}
		if !wj.web_for_record(ctx, kf, pi_member, &st) || !pi_spread(ctx, &st) { wj.JS_FreeValue(ctx, frames); return wj.EXCEPTION }
		n = st.n
	}
	// offsets: in [0, 1], never decreasing (TypeError); the missing ones spread evenly between the known ones
	off := ([^]f64)(wj.libc_calloc(uint(max(n, 1)), size_of(f64)))
	known := ([^]bool)(wj.libc_calloc(uint(max(n, 1)), size_of(bool)))
	defer { wj.libc_free(off); wj.libc_free(known) }
	if off == nil || known == nil { wj.JS_FreeValue(ctx, frames); return wj.JS_ThrowOutOfMemory(ctx) }
	last := NEG_INF
	for i in 0 ..< n {
		f := wj.JS_GetPropertyUint32(ctx, frames, i)
		off[i] = frame_offset(ctx, f, "offset", &known[i])
		wj.JS_FreeValue(ctx, f)
		if !known[i] { continue }
		if off[i] < 0 || off[i] > 1 { wj.JS_FreeValue(ctx, frames); return wj.JS_ThrowTypeError(ctx, "Offsets must be null or in the range [0,1].") }
		if off[i] < last { wj.JS_FreeValue(ctx, frames); return wj.JS_ThrowTypeError(ctx, "Offsets must be monotonically non-decreasing.") }
		last = off[i]
	}
	if !sequence {
		// property-indexed: the frames were made at their computed offsets; explicit offsets replace them
		for i in 0 ..< n {
			if known[i] { continue }
			f := wj.JS_GetPropertyUint32(ctx, frames, i)
			has: bool
			o := frame_offset(ctx, f, "computedOffset", &has)
			wj.JS_FreeValue(ctx, f)
			if has { off[i] = o; known[i] = true }
		}
	}
	if n > 0 && !known[n - 1] { off[n - 1] = 1; known[n - 1] = true }
	if n > 1 && !known[0] { off[0] = 0; known[0] = true }
	for i := u32(1); i < n; i += 1 {
		if known[i] { continue }
		j := i
		for !known[j] { j += 1 }
		for k in i ..< j {
			off[k] = off[i - 1] + (off[j] - off[i - 1]) * f64(k - i + 1) / f64(j - i + 1)
			known[k] = true
		}
		i = j
	}
	ok := true
	for i := u32(0); i < n && ok; i += 1 {
		f := wj.JS_GetPropertyUint32(ctx, frames, i)
		wj.JS_SetPropertyStr(ctx, f, "computedOffset", wj.new_float64(ctx, off[i]))
		ez := wj.JS_GetPropertyStr(ctx, f, "easing")
		k, ks := key_string(ctx, ez)
		ok = k != nil && easing_check(ctx, transmute([]u8)ks)
		if k != nil { wj.JS_FreeCString(ctx, k) }
		wj.JS_FreeValue(ctx, ez)
		wj.JS_FreeValue(ctx, f)
	}
	if !ok { wj.JS_FreeValue(ctx, frames); return wj.EXCEPTION }
	return frames
}

@(private = "file")
pack_member :: proc "c" (ctx: ^wj.Context, key: wj.JSValue, value: wj.JSValue, opaque: rawptr) -> bool {
	b := (^Pack)(opaque)
	k, ks := key_string(ctx, key)
	if k == nil { return false }
	if !reserved_member(ks) && css_name_ok(ks) {
		v, vs := key_string(ctx, value)
		if v != nil {
			pack_put(b, "\x1f")
			css_name_put(b, ks)
			pack_put(b, "\x1f")
			pack_put_clean(b, vs)
			wj.JS_FreeCString(ctx, v)
		}
	}
	wj.JS_FreeCString(ctx, k)
	return true
}

// The keyframes as the browser takes them (api/animations.widl), in `b`.
@(private = "file")
keyframes_pack :: proc "contextless" (ctx: ^wj.Context, frames: wj.JSValue, b: ^Pack) -> bool {
	n := list_length(ctx, frames)
	for i in 0 ..< n {
		f := wj.JS_GetPropertyUint32(ctx, frames, i)
		has: bool
		off := frame_offset(ctx, f, "computedOffset", &has)
		num: [40]u8
		k := wj.snprintf(&num[0], len(num), "%.17g", off)
		if i > 0 { pack_put(b, "\x1e") }
		pack_put(b, string(num[:clamp(int(k), 0, len(num) - 1)]))
		pack_put(b, "\x1f")
		ez := wj.JS_GetPropertyStr(ctx, f, "easing")
		s, ss := key_string(ctx, ez)
		if s != nil { pack_put_clean(b, ss); wj.JS_FreeCString(ctx, s) }
		wj.JS_FreeValue(ctx, ez)
		// the keyframe's own composite operation ("auto": the effect's)
		co := wj.JS_GetPropertyStr(ctx, f, "composite")
		if wj.is_string(co) {
			c, cs := key_string(ctx, co)
			if c != nil && (cs == "replace" || cs == "add" || cs == "accumulate") {
				pack_put(b, "\x1fcomposite\x1f")
				pack_put(b, cs)
			}
			if c != nil { wj.JS_FreeCString(ctx, c) }
		}
		wj.JS_FreeValue(ctx, co)
		ok := wj.web_for_record(ctx, f, pack_member, b)
		wj.JS_FreeValue(ctx, f)
		if !ok { return false }
	}
	if b.failed { wj.JS_ThrowOutOfMemory(ctx); return false }
	return true
}

// ---- KeyframeEffect ----

@(private = "file")
Effect :: struct {
	target:              wj.JSValue,   // Element, or null
	pseudo:              wj.JSValue,   // string, or null: effects on pseudo-elements are kept but not shown
	frames:              wj.JSValue,   // the normalized keyframes
	t:                   Timing,
	composite:           i32,
	iteration_composite: i32,
	anim:                Animation,    // the browser's animation it is the effect of (0: none)
}

@(private = "file")
fx_free :: proc "c" (p: rawptr) {
	e := (^Effect)(p)
	rt := wj.web_rt()
	wj.JS_FreeValueRT(rt, e.target)
	wj.JS_FreeValueRT(rt, e.pseudo)
	wj.JS_FreeValueRT(rt, e.frames)
	if e.t.easing != nil { wj.libc_free(e.t.easing) }
	wj.libc_free(e)
}

@(private = "file")
fx_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	e := (^Effect)(p)
	wj.wj_mark(rt, e.target, mark_func)
	wj.wj_mark(rt, e.pseudo, mark_func)
	wj.wj_mark(rt, e.frames, mark_func)
}

@(private = "file")
fx_of :: proc "contextless" (v: wj.JSValue) -> ^Effect {
	o := wj.wj_unwrap(v, jsb.iface_of(KeyframeEffect))
	return o != nil && o.impl_free == fx_free ? (^Effect)(o.impl) : nil
}

@(private = "file")
fx_this :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^Effect {
	if wj.wj_this(ctx, this_val, jsb.iface_of(AnimationEffect)) == nil { return nil }
	e := fx_of(this_val)
	if e == nil { wj.JS_ThrowTypeError(ctx, "Illegal invocation") }
	return e
}

// Sends the effect to its animation's browser side.
@(private = "file")
fx_push :: proc(ctx: ^wj.Context, e: ^Effect) -> bool {
	if e.anim == 0 { return true }
	target: u64
	if wj.is_null(e.pseudo) {
		if o := wj.wj_unwrap(e.target, jsb.iface_of(Element)); o != nil { target = o.handle }
	}
	b: Pack
	defer pack_free(&b)
	if !keyframes_pack(ctx, e.frames, &b) { return false }
	// fill modes in the style engine's order: none, forwards, backwards, both
	fill := e.t.fill == FILL_AUTO ? 0 : e.t.fill
	keyframes := b.n > 0 ? b.p[:b.n] : wj.empty_ptr()[:0]
	st := jsb.host_n(&none, api_decl.Animation_setEffect, wj.wr_Animation_setEffect, e.anim, target, keyframes, e.t.duration, e.t.delay,
		e.t.end_delay, e.t.iterations, e.t.iteration_start, e.t.direction, fill, easing_text(&e.t), e.composite)
	if st != .None { wj.wj_throw_status(ctx, i32(st), "KeyframeEffect"); return false }
	return true
}

@(private = "file")
valid_pseudo :: proc "contextless" (s: string, legacy: bool) -> bool {
	return s == "::before" || s == "::after" || s == "::marker" || (legacy && (s == ":before" || s == ":after"))
}

// The string of v as a JS string (counted) and whether it names a pseudo-element; EXCEPTION when it does not convert.
@(private = "file")
pseudo_of :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, legacy: bool) -> (wj.JSValue, bool) {
	s := wj.JS_ToString(ctx, v)
	if wj.is_exception(s) { return s, false }
	c, cs := key_string(ctx, s)
	valid := c != nil && valid_pseudo(cs, legacy)
	if c != nil { wj.JS_FreeCString(ctx, c) }
	return s, valid
}

@(private = "file")
fx_new :: proc(ctx: ^wj.Context, new_target: wj.JSValue, target: wj.JSValue, keyframes: wj.JSValue, options: wj.JSValue) -> wj.JSValue {
	if !wj.is_nullish(target) && wj.wj_unwrap(target, jsb.iface_of(Element)) == nil {
		return wj.JS_ThrowTypeError(ctx, "Failed to construct 'KeyframeEffect': parameter 1 is not of type 'Element'.")
	}
	e := (^Effect)(wj.libc_calloc(1, size_of(Effect)))
	if e == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	e.target = wj.is_undefined(target) ? wj.NULL : wj.JS_DupValue(ctx, target)
	e.pseudo = wj.NULL
	e.frames = wj.UNDEFINED
	e.t = TIMING_DEFAULT
	frames := keyframes_process(ctx, keyframes)
	if wj.is_exception(frames) || !timing_from_options(ctx, options, &e.t) { wj.JS_FreeValue(ctx, frames); fx_free(e); return wj.EXCEPTION }
	e.frames = frames
	if wj.is_object(options) {
		has: bool
		v: i32
		if !read_enum(ctx, options, "composite", COMPOSITE_NAMES[:], "CompositeOperation", &has, &v) { fx_free(e); return wj.EXCEPTION }
		if has { e.composite = v }
		if !read_enum(ctx, options, "iterationComposite", ITERATION_COMPOSITE_NAMES[:], "IterationCompositeOperation", &has, &v) { fx_free(e); return wj.EXCEPTION }
		if has { e.iteration_composite = v }
		pe: wj.JSValue
		if !wj.web_dict_get(ctx, options, "pseudoElement", &pe) { fx_free(e); return wj.EXCEPTION }
		if !wj.is_nullish(pe) {
			s, valid := pseudo_of(ctx, pe, true)
			wj.JS_FreeValue(ctx, pe)
			if wj.is_exception(s) { fx_free(e); return s }
			if !valid { wj.JS_FreeValue(ctx, s); fx_free(e); return wj.wj_throw_dom(ctx, "SyntaxError", "Invalid pseudoElement") }
			e.pseudo = s
		} else {
			wj.JS_FreeValue(ctx, pe)
		}
	}
	obj := wj.wj_new_object_for(ctx, jsb.iface_of(KeyframeEffect), new_target, nil, nil)
	if wj.is_exception(obj) { fx_free(e); return obj }
	wj.web_set_impl(obj, e, fx_free, fx_mark)
	return obj
}

@(export, link_name = "wjr_KeyframeEffect_constructor")
wjr_KeyframeEffect_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor KeyframeEffect requires 'new'") }
	if src := argc == 1 ? fx_of(argv[0]) : nil; src != nil {
		// new KeyframeEffect(source): a copy of its target, keyframes and timing
		obj := fx_new(ctx, new_target, src.target, wj.NULL, wj.UNDEFINED)
		if wj.is_exception(obj) { return obj }
		e := fx_of(obj)
		wj.JS_FreeValue(ctx, e.frames)
		e.frames = wj.JS_DupValue(ctx, src.frames)
		wj.JS_FreeValue(ctx, e.pseudo)
		e.pseudo = wj.JS_DupValue(ctx, src.pseudo)
		if e.t.easing != nil { wj.libc_free(e.t.easing) }
		e.t = src.t
		e.t.easing = src.t.easing != nil ? wj.web_strndup(src.t.easing, uint(wj.strlen(cstring(src.t.easing)))) : nil
		e.composite = src.composite
		e.iteration_composite = src.iteration_composite
		return obj
	}
	if argc < 2 { return wj.wj_throw_arity(ctx, "KeyframeEffect", 2, argc) }
	return fx_new(ctx, new_target, argv[0], argv[1], wj.arg(argc, argv, 2))
}

@(export, link_name = "wjr_KeyframeEffect_get_target")
wjr_KeyframeEffect_get_target :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	e := fx_this(ctx, this_val)
	return e != nil ? wj.JS_DupValue(ctx, e.target) : wj.EXCEPTION
}

@(export, link_name = "wjr_KeyframeEffect_set_target")
wjr_KeyframeEffect_set_target :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	e := fx_this(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	if !wj.is_nullish(v) && wj.wj_unwrap(v, jsb.iface_of(Element)) == nil {
		return wj.JS_ThrowTypeError(ctx, "Failed to set the 'target' property on 'KeyframeEffect': The provided value is not of type 'Element'.")
	}
	wj.JS_FreeValue(ctx, e.target)
	e.target = wj.is_undefined(v) ? wj.NULL : wj.JS_DupValue(ctx, v)
	return fx_push(ctx, e) ? wj.UNDEFINED : wj.EXCEPTION
}

@(export, link_name = "wjr_KeyframeEffect_get_pseudoElement")
wjr_KeyframeEffect_get_pseudoElement :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	e := fx_this(ctx, this_val)
	return e != nil ? wj.JS_DupValue(ctx, e.pseudo) : wj.EXCEPTION
}

@(export, link_name = "wjr_KeyframeEffect_set_pseudoElement")
wjr_KeyframeEffect_set_pseudoElement :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	e := fx_this(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	s := wj.NULL
	if !wj.is_null(v) {
		valid: bool
		s, valid = pseudo_of(ctx, v, false)
		if wj.is_exception(s) { return s }
		if !valid { wj.JS_FreeValue(ctx, s); return wj.wj_throw_dom(ctx, "SyntaxError", "Invalid pseudoElement") }
	}
	wj.JS_FreeValue(ctx, e.pseudo)
	e.pseudo = s
	return fx_push(ctx, e) ? wj.UNDEFINED : wj.EXCEPTION
}

@(export, link_name = "wjr_KeyframeEffect_get_composite")
wjr_KeyframeEffect_get_composite :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	e := fx_this(ctx, this_val)
	return e != nil ? name_value(ctx, COMPOSITE_NAMES[:], e.composite) : wj.EXCEPTION
}

// An enum attribute ignores other values; nil: absent or another string, false: the string did not convert.
@(private = "file")
enum_attr :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, names: []string) -> (i: i32, ok: bool) {
	s: wj.Str
	if !wj.wj_to_str(ctx, v, &s, 0, "") { return -1, false }
	i = index_of(names, wj.str_slice(s))
	wj.wj_str_free(ctx, &s)
	return i, true
}

@(export, link_name = "wjr_KeyframeEffect_set_composite")
wjr_KeyframeEffect_set_composite :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	e := fx_this(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	i, ok := enum_attr(ctx, v, COMPOSITE_NAMES[:])
	if !ok { return wj.EXCEPTION }
	if i < 0 { return wj.UNDEFINED }
	e.composite = i
	return fx_push(ctx, e) ? wj.UNDEFINED : wj.EXCEPTION
}

@(export, link_name = "wjr_KeyframeEffect_get_iterationComposite")
wjr_KeyframeEffect_get_iterationComposite :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	e := fx_this(ctx, this_val)
	return e != nil ? name_value(ctx, ITERATION_COMPOSITE_NAMES[:], e.iteration_composite) : wj.EXCEPTION
}

@(export, link_name = "wjr_KeyframeEffect_set_iterationComposite")
wjr_KeyframeEffect_set_iterationComposite :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	e := fx_this(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	i, ok := enum_attr(ctx, v, ITERATION_COMPOSITE_NAMES[:])
	if !ok { return wj.EXCEPTION }
	if i >= 0 { e.iteration_composite = i }
	return wj.UNDEFINED
}

@(private = "file")
frame_copy_member :: proc "c" (ctx: ^wj.Context, key: wj.JSValue, value: wj.JSValue, opaque: rawptr) -> bool {
	a := wj.JS_ValueToAtom(ctx, key)
	if a == wj.ATOM_NULL { return false }
	r := wj.JS_SetProperty(ctx, (^wj.JSValue)(opaque)^, a, wj.JS_DupValue(ctx, value))
	wj.JS_FreeAtom(ctx, a)
	return r >= 0
}

@(export, link_name = "wjr_KeyframeEffect_getKeyframes")
wjr_KeyframeEffect_getKeyframes :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	e := fx_this(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	n := list_length(ctx, e.frames)
	out := wj.JS_NewArray(ctx)
	for i := u32(0); i < n && !wj.is_exception(out); i += 1 {
		f := wj.JS_GetPropertyUint32(ctx, e.frames, i)
		dup := wj.JS_NewObject(ctx)
		if !wj.web_for_record(ctx, f, frame_copy_member, &dup) {
			wj.JS_FreeValue(ctx, f); wj.JS_FreeValue(ctx, dup); wj.JS_FreeValue(ctx, out)
			return wj.EXCEPTION
		}
		wj.JS_FreeValue(ctx, f)
		wj.array_set(ctx, out, i, dup)
	}
	return out
}

@(export, link_name = "wjr_KeyframeEffect_setKeyframes")
wjr_KeyframeEffect_setKeyframes :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	e := fx_this(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "KeyframeEffect.setKeyframes", 1, argc) }
	frames := keyframes_process(ctx, argv[0])
	if wj.is_exception(frames) { return frames }
	wj.JS_FreeValue(ctx, e.frames)
	e.frames = frames
	return fx_push(ctx, e) ? wj.UNDEFINED : wj.EXCEPTION
}

@(private = "file")
timing_put :: proc "contextless" (ctx: ^wj.Context, obj: wj.JSValue, t: ^Timing, computed: bool) {
	wj.JS_SetPropertyStr(ctx, obj, "delay", wj.new_float64(ctx, t.delay))
	wj.JS_SetPropertyStr(ctx, obj, "direction", name_value(ctx, DIRECTION_NAMES[:], t.direction))
	if computed || !is_nan(t.duration) {
		wj.JS_SetPropertyStr(ctx, obj, "duration", wj.new_float64(ctx, is_nan(t.duration) ? 0 : t.duration))
	} else {
		wj.JS_SetPropertyStr(ctx, obj, "duration", wj.new_string(ctx, "auto"))
	}
	wj.JS_SetPropertyStr(ctx, obj, "easing", wj.new_string_len(ctx, easing_text(t)))
	wj.JS_SetPropertyStr(ctx, obj, "endDelay", wj.new_float64(ctx, t.end_delay))
	wj.JS_SetPropertyStr(ctx, obj, "fill", name_value(ctx, FILL_NAMES[:], computed && t.fill == FILL_AUTO ? 0 : t.fill))
	wj.JS_SetPropertyStr(ctx, obj, "iterationStart", wj.new_float64(ctx, t.iteration_start))
	wj.JS_SetPropertyStr(ctx, obj, "iterations", wj.new_float64(ctx, t.iterations))
}

@(export, link_name = "wjr_AnimationEffect_getTiming")
wjr_AnimationEffect_getTiming :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	e := fx_this(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	obj := wj.JS_NewObject(ctx)
	if !wj.is_exception(obj) { timing_put(ctx, obj, &e.t, false) }
	return obj
}

@(private = "file")
nullable :: proc "contextless" (ctx: ^wj.Context, v: f64) -> wj.JSValue { return is_nan(v) ? wj.NULL : wj.new_float64(ctx, v) }

@(private = "file")
computed_timing :: proc(ctx: ^wj.Context, e: ^Effect, which: i32) -> wj.JSValue {
	if e.anim == 0 { return wj.NULL }
	v: f64
	jsb.host(&v, api_decl.Animation_computedTiming, wj.wr_Animation_computedTiming, e.anim, which)
	return nullable(ctx, v)
}

@(export, link_name = "wjr_AnimationEffect_getComputedTiming")
wjr_AnimationEffect_getComputedTiming :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	e := fx_this(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	obj := wj.JS_NewObject(ctx)
	if wj.is_exception(obj) { return obj }
	timing_put(ctx, obj, &e.t, true)
	active := active_duration(&e.t)
	end := e.t.delay + active + e.t.end_delay
	wj.JS_SetPropertyStr(ctx, obj, "activeDuration", wj.new_float64(ctx, active))
	wj.JS_SetPropertyStr(ctx, obj, "endTime", wj.new_float64(ctx, end > 0 ? end : 0))
	wj.JS_SetPropertyStr(ctx, obj, "localTime", computed_timing(ctx, e, 0))
	wj.JS_SetPropertyStr(ctx, obj, "progress", computed_timing(ctx, e, 1))
	wj.JS_SetPropertyStr(ctx, obj, "currentIteration", computed_timing(ctx, e, 2))
	return obj
}

@(export, link_name = "wjr_AnimationEffect_updateTiming")
wjr_AnimationEffect_updateTiming :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	e := fx_this(ctx, this_val)
	if e == nil { return wj.EXCEPTION }
	opt := wj.arg(argc, argv, 0)
	if !wj.web_dict_check(ctx, opt, "updateTiming") || !timing_read(ctx, opt, &e.t) { return wj.EXCEPTION }
	return fx_push(ctx, e) ? wj.UNDEFINED : wj.EXCEPTION
}

// ---- the document timeline ----

@(private = "file")
make_timeline :: proc "c" (ctx: ^wj.Context) -> wj.JSValue { return wj.wj_new_object(ctx, jsb.iface_of(DocumentTimeline), nil, nil) }

@(private = "file")
document_timeline :: proc "contextless" (ctx: ^wj.Context) -> wj.JSValue { return wj.web_singleton(ctx, wj.SINGLE_TIMELINE, make_timeline) }

@(export, link_name = "wjr_Document_get_timeline")
wjr_Document_get_timeline :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, jsb.iface_of(Document)) == nil { return wj.EXCEPTION }
	return document_timeline(ctx)
}

// new DocumentTimeline({originTime}): the document's timeline seen from another origin. (Animations associated with
// one play on the document timeline: their times are not shifted.)
@(private = "file") Timeline :: struct { origin: f64 }

@(private = "file")
timeline_free :: proc "c" (p: rawptr) { wj.libc_free(p) }

@(export, link_name = "wjr_DocumentTimeline_constructor")
wjr_DocumentTimeline_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor DocumentTimeline requires 'new'") }
	opt := wj.arg(argc, argv, 0)
	if !wj.web_dict_check(ctx, opt, "DocumentTimeline") { return wj.EXCEPTION }
	has: bool
	origin: f64
	if !read_double(ctx, opt, "originTime", true, &has, &origin) { return wj.EXCEPTION }
	t := (^Timeline)(wj.libc_calloc(1, size_of(Timeline)))
	if t == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	t.origin = has ? origin : 0
	return wj.wj_new_object_for(ctx, jsb.iface_of(DocumentTimeline), new_target, t, timeline_free)
}

@(export, link_name = "wjr_AnimationTimeline_get_currentTime")
wjr_AnimationTimeline_get_currentTime :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, this_val, jsb.iface_of(AnimationTimeline))
	if o == nil { return wj.EXCEPTION }
	origin := o.impl != nil && o.impl_free == timeline_free ? (^Timeline)(o.impl).origin : 0
	now: f64
	jsb.host(&now, api_decl.DocumentTimeline_currentTime, wj.wr_DocumentTimeline_currentTime)
	return nullable(ctx, now - origin)
}

@(export, link_name = "wjr_AnimationTimeline_get_duration")
wjr_AnimationTimeline_get_duration :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	return wj.wj_this(ctx, this_val, jsb.iface_of(AnimationTimeline)) != nil ? wj.NULL : wj.EXCEPTION
}

// ---- Animation ----

@(private = "file")
Anim :: struct {
	host:        Animation,
	slot:        u32,
	pin:         u32,
	effect:      wj.JSValue,
	timeline:    wj.JSValue,
	id:          wj.JSValue,
	ready:       wj.JSValue,
	ready_fn:    [2]wj.JSValue,   // the resolving functions while pending (undefined otherwise)
	finished:    wj.JSValue,
	finished_fn: [2]wj.JSValue,
}

// notify slots -> the animation's wrapper (not counted; cleared when it dies)
@(private = "file") an_slots: [^]wj.JSValue
@(private = "file") an_slots_cap: u32

@(private = "file")
an_free :: proc "c" (p: rawptr) {
	a := (^Anim)(p)
	rt := wj.web_rt()
	if a.slot != 0 && a.slot < an_slots_cap { an_slots[a.slot] = wj.UNDEFINED }
	for v in ([?]wj.JSValue{a.effect, a.timeline, a.id, a.ready, a.ready_fn[0], a.ready_fn[1], a.finished, a.finished_fn[0], a.finished_fn[1]}) {
		wj.JS_FreeValueRT(rt, v)
	}
	wj.libc_free(a)
}

@(private = "file")
an_mark :: proc "c" (rt: rawptr, p: rawptr, mark_func: rawptr) {
	a := (^Anim)(p)
	for v in ([?]wj.JSValue{a.effect, a.timeline, a.id, a.ready, a.ready_fn[0], a.ready_fn[1], a.finished, a.finished_fn[0], a.finished_fn[1]}) {
		wj.wj_mark(rt, v, mark_func)
	}
}

@(private = "file")
an_this :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue) -> ^Anim {
	o := wj.wj_this(ctx, this_val, jsb.iface_of(Animation))
	if o == nil { return nil }
	if o.impl == nil || o.impl_free != an_free { wj.JS_ThrowTypeError(ctx, "Illegal invocation"); return nil }
	return (^Anim)(o.impl)
}

@(private = "file")
an_of :: proc "contextless" (v: wj.JSValue) -> ^Anim {
	o := wj.obj_of(v)
	return o != nil && o.impl_free == an_free ? (^Anim)(o.impl) : nil
}

@(private = "file")
noop :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, magic: i32, data: [^]wj.JSValue) -> wj.JSValue {
	return wj.UNDEFINED
}

// rejects with AbortError a pending promise, marked handled (Web Animations: [[PromiseIsHandled]])
@(private = "file")
reject_abort :: proc "contextless" (ctx: ^wj.Context, promise: wj.JSValue, fn: ^[2]wj.JSValue) {
	if wj.is_undefined(fn[1]) { return }
	wj.JS_FreeValue(ctx, wj.web_then(ctx, promise, nil, rawptr(noop), 0, nil))
	wj.web_settle(ctx, fn[1], wj.web_dom_exception(ctx, "AbortError", "The animation was cancelled."))
	wj.JS_FreeValue(ctx, fn[0])
	wj.JS_FreeValue(ctx, fn[1])
	fn^ = {wj.UNDEFINED, wj.UNDEFINED}
}

@(private = "file")
resolve_with :: proc "contextless" (ctx: ^wj.Context, fn: ^[2]wj.JSValue, obj: wj.JSValue) {
	if wj.is_undefined(fn[0]) { return }
	wj.web_settle(ctx, fn[0], wj.JS_DupValue(ctx, obj))
	wj.JS_FreeValue(ctx, fn[0])
	wj.JS_FreeValue(ctx, fn[1])
	fn^ = {wj.UNDEFINED, wj.UNDEFINED}
}

@(private = "file")
renew :: proc "contextless" (ctx: ^wj.Context, promise: ^wj.JSValue, fn: ^[2]wj.JSValue) {
	wj.JS_FreeValue(ctx, promise^)
	wj.JS_FreeValue(ctx, fn[0])
	wj.JS_FreeValue(ctx, fn[1])
	fn^ = {wj.UNDEFINED, wj.UNDEFINED}
	promise^ = wj.web_promise_new(ctx, &fn[0])
}

// Applies what the browser reported (Animation_takeOps).
@(private = "file")
an_sync :: proc(ctx: ^wj.Context, obj: wj.JSValue, a: ^Anim) {
	for {
		s: string
		jsb.host(&s, api_decl.Animation_takeOps, wj.wr_Animation_takeOps, a.host)
		if len(s) == 0 { return }
		ops: [256]u8
		take := copy(ops[:], s)   // (the scratch buffer is reused by the calls below)
		more := len(s) > take
		jsb.host(&none, api_decl.Animation_dropOps, wj.wr_Animation_dropOps, a.host, i32(take))
		for op in ops[:take] {
			switch op {
			case 'r': resolve_with(ctx, &a.ready_fn, obj)
			case 'n': renew(ctx, &a.ready, &a.ready_fn)
			case 'R':
				reject_abort(ctx, a.ready, &a.ready_fn)
				wj.JS_FreeValue(ctx, a.ready)
				a.ready = wj.web_promise_resolved(ctx, obj)
			case 'f': resolve_with(ctx, &a.finished_fn, obj)
			case 'F':
				reject_abort(ctx, a.finished, &a.finished_fn)
				renew(ctx, &a.finished, &a.finished_fn)
			case 'm': renew(ctx, &a.finished, &a.finished_fn)
			case 'k': if a.pin == 0 { a.pin = wj.web_pin(ctx, obj) }
			case 'u': if a.pin != 0 { wj.web_unpin(ctx, a.pin); a.pin = 0 }
			}
		}
		if !more { return }
	}
}

// The browser's notify microtask of an animation.
@(export, link_name = "wj_cb_animation")
wj_cb_animation :: proc "c" (user: i32) {
	context = jsb.glue_context()
	ctx := wj.realm_ctx()
	wj.wj_stack_enter(ctx)
	if user <= 0 || u32(user) >= an_slots_cap || wj.is_undefined(an_slots[user]) { return }
	self := wj.JS_DupValue(ctx, an_slots[user])
	if a := an_of(self); a != nil { an_sync(ctx, self, a) }
	wj.JS_FreeValue(ctx, self)
}

@(private = "file")
slot_alloc :: proc "contextless" (obj: wj.JSValue) -> u32 {
	for i in 1 ..< an_slots_cap { if wj.is_undefined(an_slots[i]) { an_slots[i] = obj; return i } }
	cap := an_slots_cap != 0 ? an_slots_cap * 2 : 32
	s := ([^]wj.JSValue)(wj.libc_realloc(an_slots, uint(cap) * size_of(wj.JSValue)))
	if s == nil { return 0 }
	for i in an_slots_cap ..< cap { s[i] = wj.UNDEFINED }
	at := an_slots_cap != 0 ? an_slots_cap : 1
	an_slots = s
	an_slots_cap = cap
	an_slots[at] = obj
	return at
}

@(private = "file")
anim_alloc :: proc "contextless" (ctx: ^wj.Context) -> ^Anim {
	a := (^Anim)(wj.libc_calloc(1, size_of(Anim)))
	if a == nil { return nil }
	a.effect = wj.NULL
	a.timeline = wj.UNDEFINED
	a.id = wj.new_string(ctx, "")
	a.ready = wj.UNDEFINED
	a.finished = wj.UNDEFINED
	a.ready_fn = {wj.UNDEFINED, wj.UNDEFINED}
	a.finished_fn = {wj.UNDEFINED, wj.UNDEFINED}
	// the slot is reserved (null) until the wrapper exists: the browser's first report comes in a microtask after
	a.slot = slot_alloc(wj.NULL)
	return a
}

// the wrapper's promises and timeline once it exists (a new animation is ready, not finished)
@(private = "file")
anim_attach :: proc "contextless" (ctx: ^wj.Context, a: ^Anim, obj: wj.JSValue) {
	wj.web_set_impl(obj, a, an_free, an_mark)
	if a.slot != 0 { an_slots[a.slot] = obj }
	a.timeline = document_timeline(ctx)
	a.ready = wj.web_promise_resolved(ctx, obj)
	a.finished = wj.web_promise_new(ctx, &a.finished_fn[0])
}

@(private = "file")
an_new :: proc(ctx: ^wj.Context, new_target: wj.JSValue) -> wj.JSValue {
	a := anim_alloc(ctx)
	if a == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	host: Animation
	jsb.host(&host, api_decl.Animation_create, wj.wr_Animation_create, wj.table_index(rawptr(wj_cb_animation)), i32(a.slot))
	if host == 0 { an_free(a); return wj.JS_ThrowTypeError(ctx, "Animation: no document") }
	a.host = host
	obj := wj.wj_wrap_owned(ctx, u64(host), jsb.iface_of(Animation), new_target)
	if wj.is_exception(obj) { an_free(a); return obj }
	anim_attach(ctx, a, obj)
	a.pin = wj.web_pin(ctx, obj)
	return obj
}

// animation.effect = v (a KeyframeEffect, or null)
@(private = "file")
an_set_effect :: proc(ctx: ^wj.Context, a: ^Anim, v: wj.JSValue) -> bool {
	e := wj.is_nullish(v) ? nil : fx_of(v)
	if e == nil && !wj.is_nullish(v) { wj.JS_ThrowTypeError(ctx, "The provided value is not of type 'AnimationEffect'."); return false }
	old := fx_of(a.effect)
	if old == e && e != nil { return true }
	if old != nil { old.anim = 0 }
	prev := a.effect
	a.effect = wj.NULL
	if e != nil && e.anim != 0 && e.anim != a.host {
		// an effect belongs to one animation: the other one loses it
		if b := an_of(wj.wj_cached(ctx, u64(e.anim))); b != nil {
			x := b.effect
			b.effect = wj.NULL
			wj.JS_FreeValue(ctx, x)
		}
		jsb.host(&none, api_decl.Animation_clearEffect, wj.wr_Animation_clearEffect, e.anim)
		e.anim = 0
	}
	wj.JS_FreeValue(ctx, prev)
	if e == nil { jsb.host(&none, api_decl.Animation_clearEffect, wj.wr_Animation_clearEffect, a.host); return true }
	a.effect = wj.JS_DupValue(ctx, v)
	e.anim = a.host
	return fx_push(ctx, e)
}

@(private = "file")
an_set_timeline :: proc(ctx: ^wj.Context, a: ^Anim, v: wj.JSValue) -> bool {
	if !wj.is_null(v) && wj.wj_unwrap(v, jsb.iface_of(AnimationTimeline)) == nil {
		wj.JS_ThrowTypeError(ctx, "The provided value is not of type 'AnimationTimeline'.")
		return false
	}
	wj.JS_FreeValue(ctx, a.timeline)
	a.timeline = wj.JS_DupValue(ctx, v)
	jsb.host(&none, api_decl.Animation_setTimeline, wj.wr_Animation_setTimeline, a.host, !wj.is_null(v))
	return true
}

@(export, link_name = "wjr_Animation_constructor")
wjr_Animation_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.is_undefined(new_target) { return wj.JS_ThrowTypeError(ctx, "Constructor Animation requires 'new'") }
	obj := an_new(ctx, new_target)
	if wj.is_exception(obj) { return obj }
	a := an_of(obj)
	if !an_set_effect(ctx, a, wj.arg(argc, argv, 0)) { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	if argc >= 2 && !wj.is_undefined(argv[1]) && !an_set_timeline(ctx, a, argv[1]) { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	return obj
}

@(export, link_name = "wjr_Animation_get_effect")
wjr_Animation_get_effect :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	a := an_this(ctx, this_val)
	return a != nil ? wj.JS_DupValue(ctx, a.effect) : wj.EXCEPTION
}

@(export, link_name = "wjr_Animation_set_effect")
wjr_Animation_set_effect :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	a := an_this(ctx, this_val)
	return a != nil && an_set_effect(ctx, a, v) ? wj.UNDEFINED : wj.EXCEPTION
}

@(export, link_name = "wjr_Animation_get_timeline")
wjr_Animation_get_timeline :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	a := an_this(ctx, this_val)
	return a != nil ? wj.JS_DupValue(ctx, a.timeline) : wj.EXCEPTION
}

@(export, link_name = "wjr_Animation_set_timeline")
wjr_Animation_set_timeline :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	a := an_this(ctx, this_val)
	return a != nil && an_set_timeline(ctx, a, v) ? wj.UNDEFINED : wj.EXCEPTION
}

@(export, link_name = "wjr_Animation_get_id")
wjr_Animation_get_id :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	a := an_this(ctx, this_val)
	return a != nil ? wj.JS_DupValue(ctx, a.id) : wj.EXCEPTION
}

@(export, link_name = "wjr_Animation_set_id")
wjr_Animation_set_id :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	a := an_this(ctx, this_val)
	if a == nil { return wj.EXCEPTION }
	s := wj.JS_ToString(ctx, v)
	if wj.is_exception(s) { return s }
	wj.JS_FreeValue(ctx, a.id)
	a.id = s
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Animation_get_playState")
wjr_Animation_get_playState :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	a := an_this(ctx, this_val)
	if a == nil { return wj.EXCEPTION }
	s: i32
	jsb.host(&s, api_decl.Animation_playState, wj.wr_Animation_playState, a.host)
	return name_value(ctx, PLAY_STATE_NAMES[:], s >= 0 && s < 4 ? s : 0)
}

@(export, link_name = "wjr_Animation_get_replaceState")
wjr_Animation_get_replaceState :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	a := an_this(ctx, this_val)
	if a == nil { return wj.EXCEPTION }
	s: i32
	jsb.host(&s, api_decl.Animation_replaceState, wj.wr_Animation_replaceState, a.host)
	return name_value(ctx, REPLACE_STATE_NAMES[:], s >= 0 && s < 3 ? s : 0)
}

@(export, link_name = "wjr_Animation_get_ready")
wjr_Animation_get_ready :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	a := an_this(ctx, this_val)
	if a == nil { return wj.EXCEPTION }
	an_sync(ctx, this_val, a)
	return wj.JS_DupValue(ctx, a.ready)
}

@(export, link_name = "wjr_Animation_get_finished")
wjr_Animation_get_finished :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	a := an_this(ctx, this_val)
	if a == nil { return wj.EXCEPTION }
	an_sync(ctx, this_val, a)
	return wj.JS_DupValue(ctx, a.finished)
}

// CSSNumberish? as a double (CSS Typed OM values are not supported: a number); NaN for null
@(private = "file")
numberish :: proc "contextless" (ctx: ^wj.Context, v: wj.JSValue, out: ^f64) -> bool {
	if wj.is_null(v) { out^ = NAN; return true }
	if !wj.wj_to_double(ctx, v, out, false) { return false }
	if !is_finite(out^) { wj.JS_ThrowTypeError(ctx, "The provided double value is non-finite."); return false }
	return true
}

@(export, link_name = "wjr_Animation_get_startTime")
wjr_Animation_get_startTime :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	a := an_this(ctx, this_val)
	if a == nil { return wj.EXCEPTION }
	t: f64
	jsb.host(&t, api_decl.Animation_startTime, wj.wr_Animation_startTime, a.host)
	return nullable(ctx, t)
}

@(export, link_name = "wjr_Animation_set_startTime")
wjr_Animation_set_startTime :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	a := an_this(ctx, this_val)
	d: f64
	if a == nil || !numberish(ctx, v, &d) { return wj.EXCEPTION }
	jsb.host(&none, api_decl.Animation_set_startTime, wj.wr_Animation_set_startTime, a.host, d)
	return wj.UNDEFINED
}

@(export, link_name = "wjr_Animation_get_currentTime")
wjr_Animation_get_currentTime :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	a := an_this(ctx, this_val)
	if a == nil { return wj.EXCEPTION }
	t: f64
	jsb.host(&t, api_decl.Animation_currentTime, wj.wr_Animation_currentTime, a.host)
	return nullable(ctx, t)
}

@(export, link_name = "wjr_Animation_set_currentTime")
wjr_Animation_set_currentTime :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, v: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	a := an_this(ctx, this_val)
	d: f64
	if a == nil || !numberish(ctx, v, &d) { return wj.EXCEPTION }
	st := jsb.host(&none, api_decl.Animation_set_currentTime, wj.wr_Animation_set_currentTime, a.host, d)
	return st != .None ? wj.wj_throw_status(ctx, i32(st), "Animation.currentTime") : wj.UNDEFINED
}

@(export, link_name = "wjr_Animation_get_overallProgress")
wjr_Animation_get_overallProgress :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	a := an_this(ctx, this_val)
	if a == nil { return wj.EXCEPTION }
	e := fx_of(a.effect)
	cur: f64
	jsb.host(&cur, api_decl.Animation_currentTime, wj.wr_Animation_currentTime, a.host)
	if e == nil || is_nan(cur) { return wj.NULL }
	end := e.t.delay + active_duration(&e.t) + e.t.end_delay
	if end <= 0 { return wj.new_float64(ctx, cur < 0 ? 0 : 1) }
	if end == end && end - end != 0 { return wj.new_float64(ctx, 0) }   // infinite
	p := cur / end
	return wj.new_float64(ctx, p < 0 ? 0 : p > 1 ? 1 : p)
}

// ---- Element.animate, getAnimations ----

@(export, link_name = "wjr_Animatable_animate")
wjr_Animatable_animate :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_this(ctx, this_val, jsb.iface_of(Element)) == nil { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, "Element.animate", 1, argc) }
	options := wj.arg(argc, argv, 1)
	effect := fx_new(ctx, wj.UNDEFINED, this_val, argv[0], options)
	if wj.is_exception(effect) { return effect }
	id, timeline := wj.UNDEFINED, wj.UNDEFINED
	if wj.is_object(options) {
		if !wj.web_dict_get(ctx, options, "id", &id) || !wj.web_dict_get(ctx, options, "timeline", &timeline) {
			wj.JS_FreeValue(ctx, id)
			wj.JS_FreeValue(ctx, effect)
			return wj.EXCEPTION
		}
	}
	obj := an_new(ctx, wj.UNDEFINED)
	if wj.is_exception(obj) { wj.JS_FreeValue(ctx, id); wj.JS_FreeValue(ctx, timeline); wj.JS_FreeValue(ctx, effect); return obj }
	a := an_of(obj)
	ok := an_set_effect(ctx, a, effect)
	wj.JS_FreeValue(ctx, effect)
	if ok && !wj.is_undefined(id) {
		s := wj.JS_ToString(ctx, id)
		if wj.is_exception(s) { ok = false } else { wj.JS_FreeValue(ctx, a.id); a.id = s }
	}
	if ok && !wj.is_undefined(timeline) { ok = an_set_timeline(ctx, a, timeline) }
	wj.JS_FreeValue(ctx, id)
	wj.JS_FreeValue(ctx, timeline)
	if ok {
		if st := jsb.host(&none, api_decl.Animation_play, wj.wr_Animation_play, a.host); st != .None {
			wj.wj_throw_status(ctx, i32(st), "Element.animate")
			ok = false
		}
	}
	if !ok { wj.JS_FreeValue(ctx, obj); return wj.EXCEPTION }
	return obj
}

// The wrapper of a CSS animation or transition the browser listed (CSSAnimation / CSSTransition): an Animation whose
// effect is a KeyframeEffect on its target with its timing (no keyframes of its own: the style timeline runs it).
// Undefined when the handle is not a CSS one.
@(private = "file")
css_wrap :: proc(ctx: ^wj.Context, host: Animation) -> wj.JSValue {
	a := anim_alloc(ctx)
	if a == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	// (a struct result through a pointer and no status: no declaration lowers to it, so the import itself)
	info: wj.wr_CssAnimationInfo
	wj.wr_Animation_cssBind(u64(host), wj.table_index(rawptr(wj_cb_animation)), i32(a.slot), &info)
	if info.kind != 1 && info.kind != 2 { an_free(a); return wj.UNDEFINED }
	a.host = host
	iface := info.kind == 1 ? jsb.iface_of(CSSAnimation) : jsb.iface_of(CSSTransition)
	obj := wj.wj_wrap_owned(ctx, u64(host), iface, wj.UNDEFINED)
	if wj.is_exception(obj) { an_free(a); return obj }
	anim_attach(ctx, a, obj)
	target := wj.wj_wrap_node(ctx, info.target)
	if wj.is_exception(target) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); target = wj.NULL }
	fx := fx_new(ctx, wj.UNDEFINED, target, wj.NULL, wj.UNDEFINED)
	wj.JS_FreeValue(ctx, target)
	if wj.is_exception(fx) { wj.JS_FreeValue(ctx, wj.JS_GetException(ctx)); return obj }
	e := fx_of(fx)
	e.t.delay = info.delay
	e.t.duration = info.duration
	e.t.iterations = info.iterations
	a.effect = fx   // (not pushed: e.anim stays 0, the browser keeps no script effect for it)
	return obj
}

@(private = "file")
css_name :: proc(ctx: ^wj.Context, this_val: wj.JSValue, iface: i32) -> wj.JSValue {
	o := wj.wj_this(ctx, this_val, iface)
	if o == nil { return wj.EXCEPTION }
	s: string
	jsb.host(&s, api_decl.Animation_cssName, wj.wr_Animation_cssName, Animation(o.handle))
	return wj.new_string_len(ctx, s)
}

@(export, link_name = "wjr_CSSAnimation_get_animationName")
wjr_CSSAnimation_get_animationName :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { context = jsb.glue_context(); return css_name(ctx, t, jsb.iface_of(CSSAnimation)) }
@(export, link_name = "wjr_CSSTransition_get_transitionProperty")
wjr_CSSTransition_get_transitionProperty :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { context = jsb.glue_context(); return css_name(ctx, t, jsb.iface_of(CSSTransition)) }

@(private = "file")
relevant_list :: proc(ctx: ^wj.Context, root: u64, subtree: bool) -> wj.JSValue {
	packed: abi.Bytes
	if st := jsb.host(&packed, api_decl.Animation_relevant, wj.wr_Animation_relevant, root, subtree); st != .None {
		return wj.wj_throw_status(ctx, i32(st), "getAnimations")
	}
	count := len(packed) / 8
	// the handles out of the scratch buffer first: wrapping a CSS animation calls the browser again
	hs := ([^]u64)(wj.libc_malloc(uint(max(count, 1)) * size_of(u64)))
	if hs == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	defer wj.libc_free(hs)
	for i in 0 ..< count { hs[i] = wj.read_u64(raw_data(packed[i * 8:])) }
	out := wj.JS_NewArray(ctx)
	at: u32
	for i in 0 ..< count {
		w := wj.wj_cached(ctx, hs[i])
		if wj.is_object(w) { wj.array_set(ctx, out, at, wj.JS_DupValue(ctx, w)); at += 1; continue }
		w = css_wrap(ctx, Animation(hs[i]))   // a CSS animation or transition seen for the first time
		if wj.is_exception(w) { wj.JS_FreeValue(ctx, out); return wj.EXCEPTION }
		if wj.is_object(w) { wj.array_set(ctx, out, at, w); at += 1 }
	}
	return out
}

@(export, link_name = "wjr_Animatable_getAnimations")
wjr_Animatable_getAnimations :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	o := wj.wj_this(ctx, this_val, jsb.iface_of(Element))
	if o == nil { return wj.EXCEPTION }
	opt := wj.arg(argc, argv, 0)
	if !wj.web_dict_check(ctx, opt, "getAnimations") { return wj.EXCEPTION }
	v: wj.JSValue
	if !wj.web_dict_get(ctx, opt, "subtree", &v) { return wj.EXCEPTION }
	subtree := wj.JS_ToBool(ctx, v) != 0
	wj.JS_FreeValue(ctx, v)
	return relevant_list(ctx, o.handle, subtree)
}

@(export, link_name = "wjr_DocumentOrShadowRoot_getAnimations")
wjr_DocumentOrShadowRoot_getAnimations :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = jsb.glue_context()
	if wj.wj_unwrap(this_val, jsb.iface_of(Document)) != nil { return relevant_list(ctx, 0, true) }
	o := wj.wj_this(ctx, this_val, jsb.iface_of(ShadowRoot))
	if o == nil { return wj.EXCEPTION }
	return relevant_list(ctx, o.handle, true)
}

// ---- events ----

@(private = "file")
event_time :: proc(ctx: ^wj.Context, this_val: wj.JSValue, name: cstring, which: i32) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, jsb.iface_of(AnimationPlaybackEvent)) == nil { return wj.EXCEPTION }
	v := wj.web_extra_get(ctx, this_val, name)
	if !wj.is_undefined(v) { return v }
	h := wj.web_event_host(this_val)
	if h == 0 { return wj.NULL }
	t: f64
	jsb.host(&t, api_decl.AnimationPlaybackEvent_time, wj.wr_AnimationPlaybackEvent_time, h, which)
	return nullable(ctx, t)
}

@(export, link_name = "wjr_AnimationPlaybackEvent_get_currentTime")
wjr_AnimationPlaybackEvent_get_currentTime :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { context = jsb.glue_context(); return event_time(ctx, t, "currentTime", 0) }
@(export, link_name = "wjr_AnimationPlaybackEvent_get_timelineTime")
wjr_AnimationPlaybackEvent_get_timelineTime :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { context = jsb.glue_context(); return event_time(ctx, t, "timelineTime", 1) }

@(private = "file") Init_Kind :: enum { Nullable_Double, Double, String }

// a member of an event init dictionary, kept as an extra of the event: double? = null, double = 0, DOMString = ""
@(private = "file")
init_member :: proc "contextless" (ctx: ^wj.Context, ev: wj.JSValue, init: wj.JSValue, name: cstring, kind: Init_Kind) -> bool {
	v: wj.JSValue
	if !wj.web_dict_get(ctx, init, name, &v) { return false }
	defer wj.JS_FreeValue(ctx, v)
	out: wj.JSValue
	switch kind {
	case .Nullable_Double:
		d := NAN
		if !wj.is_nullish(v) && !wj.wj_to_double(ctx, v, &d, true) { return false }
		out = wj.is_nullish(v) ? wj.NULL : wj.new_float64(ctx, d)
	case .Double:
		d: f64
		if !wj.is_undefined(v) && !wj.wj_to_double(ctx, v, &d, true) { return false }
		out = wj.new_float64(ctx, d)
	case .String:
		out = wj.is_undefined(v) ? wj.new_string(ctx, "") : wj.JS_ToString(ctx, v)
		if wj.is_exception(out) { return false }
	}
	return wj.web_extra_set(ctx, ev, name, out)
}

@(export, link_name = "wjr_AnimationPlaybackEvent_constructor")
wjr_AnimationPlaybackEvent_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	ev := wj.wj_event_construct(ctx, new_target, argc, argv, jsb.iface_of(AnimationPlaybackEvent), "AnimationPlaybackEvent")
	if wj.is_exception(ev) { return ev }
	init := wj.arg(argc, argv, 1)
	if !init_member(ctx, ev, init, "currentTime", .Nullable_Double) || !init_member(ctx, ev, init, "timelineTime", .Nullable_Double) {
		wj.JS_FreeValue(ctx, ev)
		return wj.EXCEPTION
	}
	return ev
}

// AnimationEvent / TransitionEvent of the browser (page/animations.odin): Event_data the name, Event_code the elapsed
// time in microseconds, Event_text the pseudo-element
@(private = "file")
host_event_string :: proc(ctx: ^wj.Context, this_val: wj.JSValue, iface: i32, name: cstring, text: bool) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, iface) == nil { return wj.EXCEPTION }
	v := wj.web_extra_get(ctx, this_val, name)
	if !wj.is_undefined(v) { return v }
	h := wj.web_event_host(this_val)
	s: string
	if h != 0 {
		if text { jsb.host(&s, api_decl.Event_text, wj.wr_Event_text, h) } else { jsb.host(&s, api_decl.Event_data, wj.wr_Event_data, h) }
	}
	return wj.new_string_len(ctx, s)
}

@(private = "file")
host_event_elapsed :: proc(ctx: ^wj.Context, this_val: wj.JSValue, iface: i32) -> wj.JSValue {
	if wj.wj_this(ctx, this_val, iface) == nil { return wj.EXCEPTION }
	v := wj.web_extra_get(ctx, this_val, "elapsedTime")
	if !wj.is_undefined(v) { return v }
	h := wj.web_event_host(this_val)
	us: i64
	if h != 0 { jsb.host(&us, api_decl.Event_code, wj.wr_Event_code, h) }
	return wj.new_float64(ctx, f64(us) / 1e6)
}

@(export, link_name = "wjr_AnimationEvent_get_animationName")
wjr_AnimationEvent_get_animationName :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { context = jsb.glue_context(); return host_event_string(ctx, t, jsb.iface_of(AnimationEvent), "animationName", false) }
@(export, link_name = "wjr_AnimationEvent_get_pseudoElement")
wjr_AnimationEvent_get_pseudoElement :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { context = jsb.glue_context(); return host_event_string(ctx, t, jsb.iface_of(AnimationEvent), "pseudoElement", true) }
@(export, link_name = "wjr_AnimationEvent_get_elapsedTime")
wjr_AnimationEvent_get_elapsedTime :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { context = jsb.glue_context(); return host_event_elapsed(ctx, t, jsb.iface_of(AnimationEvent)) }
@(export, link_name = "wjr_TransitionEvent_get_propertyName")
wjr_TransitionEvent_get_propertyName :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { context = jsb.glue_context(); return host_event_string(ctx, t, jsb.iface_of(TransitionEvent), "propertyName", false) }
@(export, link_name = "wjr_TransitionEvent_get_pseudoElement")
wjr_TransitionEvent_get_pseudoElement :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { context = jsb.glue_context(); return host_event_string(ctx, t, jsb.iface_of(TransitionEvent), "pseudoElement", true) }
@(export, link_name = "wjr_TransitionEvent_get_elapsedTime")
wjr_TransitionEvent_get_elapsedTime :: proc "c" (ctx: ^wj.Context, t: wj.JSValue) -> wj.JSValue { context = jsb.glue_context(); return host_event_elapsed(ctx, t, jsb.iface_of(TransitionEvent)) }

@(private = "file")
host_event_construct :: proc "contextless" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue, iface: i32, name: cstring, name_member: cstring) -> wj.JSValue {
	ev := wj.wj_event_construct(ctx, new_target, argc, argv, iface, name)
	if wj.is_exception(ev) { return ev }
	init := wj.arg(argc, argv, 1)
	if !init_member(ctx, ev, init, name_member, .String) || !init_member(ctx, ev, init, "elapsedTime", .Double) || !init_member(ctx, ev, init, "pseudoElement", .String) {
		wj.JS_FreeValue(ctx, ev)
		return wj.EXCEPTION
	}
	return ev
}

@(export, link_name = "wjr_AnimationEvent_constructor")
wjr_AnimationEvent_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return host_event_construct(ctx, nt, argc, argv, jsb.iface_of(AnimationEvent), "AnimationEvent", "animationName")
}

@(export, link_name = "wjr_TransitionEvent_constructor")
wjr_TransitionEvent_constructor :: proc "c" (ctx: ^wj.Context, nt: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	return host_event_construct(ctx, nt, argc, argv, jsb.iface_of(TransitionEvent), "TransitionEvent", "propertyName")
}
