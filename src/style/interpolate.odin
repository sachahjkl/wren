package style

import "base:runtime"
import "core:math"
import "core:mem"
import "wb:css"

// Interpolation of computed values (CSS Values 4 §3, Transitions 1, Transforms 2 §10, Backgrounds 3, Filter Effects 1):
// numbers, lengths (mixed units through calc()), colors (premultiplied, in sRGB or OKLab per preference), shadow lists,
// transform lists, filter lists, and any structure made of those, field by field. What cannot be interpolated is
// discrete: it flips at 50% (with the special cases of visibility and display).

Interp_Ctx :: struct {
	alloc: runtime.Allocator,   // memory for what the result points to (calc trees, lists)
	space: Anim_Color_Space,
}

// Properties that cannot be animated at all (CSS: "Animation type: not animatable").
animatable :: proc(p: Prop) -> bool {
	#partial switch p {
	case .Transition_Property, .Transition_Duration, .Transition_Timing_Function, .Transition_Delay, .Transition_Behavior,
	     .Animation_Name, .Animation_Duration, .Animation_Timing_Function, .Animation_Delay, .Animation_Iteration_Count,
	     .Animation_Direction, .Animation_Fill_Mode, .Animation_Play_State, .Animation_Composition, .Will_Change, .Direction:
		return false
	}
	return true
}

// dst.p = a.p + (b.p - a.p) * t. False when the values do not interpolate (the caller then uses `discrete_prop`); dst
// is unspecified in that case.
interpolate_prop :: proc(dst, a, b: ^Computed, p: Prop, t: f64, ctx: ^Interp_Ctx) -> bool {
	#partial switch p {
	case .Font_Feature_Settings:
		return false   // discrete (CSS Fonts 4 §6.12)
	case .Font_Variation_Settings:
		// the same axes in the same order: each value interpolates (CSS Fonts 4 §7.2); else discrete
		va, vb := a.font_variation_settings, b.font_variation_settings
		if len(va) != len(vb) { return false }
		for x, i in va { if x.tag != vb[i].tag { return false } }
		out := make([]Font_Variation_Setting, len(va), ctx.alloc)
		for x, i in va { out[i] = {x.tag, x.value + (vb[i].value - x.value) * f32(t)} }
		dst.font_variation_settings = out
		return true
	case .Visibility:
		// visible wins between the endpoints when one of them is visible
		if a.visibility == b.visibility { dst.visibility = a.visibility; return true }
		if a.visibility != .Visible && b.visibility != .Visible { return false }
		dst.visibility = t <= 0 ? a.visibility : (t >= 1 ? b.visibility : .Visible)
		return true
	case .Z_Index:
		if a.z_auto || b.z_auto { return a.z_auto && b.z_auto }
		dst.z_auto, dst.z_index = false, i32(clamp(math.round(lerp64(f64(a.z_index), f64(b.z_index), t)), f64(min(i32)), f64(max(i32))))   // an overshooting easing
		return true
	case .Tab_Size:
		// spaces and lengths do not interpolate with each other (CSS Text 3 §4.2: by computed value type)
		if a.tab_spaces != b.tab_spaces { return false }
		dst.tab_spaces, dst.tab_size = a.tab_spaces, max(lerp32(a.tab_size, b.tab_size, t), 0)
		return true
	case .Font_Weight:
		dst.font_weight = u16(clamp(math.round(lerp64(f64(a.font_weight), f64(b.font_weight), t)), 1, 1000))
		return true
	case .Display, .Content_Visibility, .Content, .Font_Family, .Background_Image, .List_Style_Type, .Cursor, .Quotes:
		return prop_equal(a, b, p) && copy_ok(dst, a, p)
	}
	da, db := prop_fields(dst, p)
	aa, ab := prop_fields(a, p)
	ba, bb := prop_fields(b, p)
	if !interp(da.data, aa.data, ba.data, type_info_of(da.id), t, ctx) { return false }
	if db.data != nil && !interp(db.data, ab.data, bb.data, type_info_of(db.id), t, ctx) { return false }
	clamp_prop(dst, p)
	return true
}

@(private)
copy_ok :: proc(dst, src: ^Computed, p: Prop) -> bool { copy_prop(dst, src, p); return true }

// The discrete step between two values: `a` before 50%, `b` from 50% on; display and content-visibility keep the
// non-hiding value for the whole time in between (CSS Display 4 / Transitions 2).
discrete_prop :: proc(dst, a, b: ^Computed, p: Prop, t: f64) {
	#partial switch p {
	case .Display:
		if (a.display == .None) != (b.display == .None) && t > 0 && t < 1 {
			copy_prop(dst, a.display == .None ? b : a, p)
			return
		}
	case .Content_Visibility:
		if (a.content_visibility == .Hidden) != (b.content_visibility == .Hidden) && t > 0 && t < 1 {
			copy_prop(dst, a.content_visibility == .Hidden ? b : a, p)
			return
		}
	}
	copy_prop(dst, t < 0.5 ? a : b, p)
}

// Whether two values of `p` interpolate (they can be transitioned without allow-discrete).
interpolable :: proc(a, b: ^Computed, p: Prop, ctx: ^Interp_Ctx) -> bool {
	scratch := new(Computed, context.temp_allocator)
	scratch^ = a^
	tmp := Interp_Ctx{alloc = context.temp_allocator, space = ctx.space}
	return interpolate_prop(scratch, a, b, p, 0.5, &tmp)
}

@(private)
lerp64 :: #force_inline proc(a, b, t: f64) -> f64 { return a + (b - a) * t }

@(private)
lerp32 :: #force_inline proc(a, b: f32, t: f64) -> f32 { return f32(f64(a) + (f64(b) - f64(a)) * t) }

////////////////////////////////
// By type

@(private)
interp :: proc(dst, a, b: rawptr, ti: ^runtime.Type_Info, t: f64, ctx: ^Interp_Ctx) -> bool {
	switch ti.id {
	case Length: return interp_length((^Length)(dst), (^Length)(a)^, (^Length)(b)^, t, ctx)
	case css.Color:
		(^css.Color)(dst)^ = mix_color((^css.Color)(a)^, (^css.Color)(b)^, t, ctx.space)
		return true
	case []Shadow:
		r, ok := interp_shadows((^[]Shadow)(a)^, (^[]Shadow)(b)^, t, ctx)
		if ok { (^[]Shadow)(dst)^ = r }
		return ok
	case []Transform_Op:
		r, ok := interp_transforms((^[]Transform_Op)(a)^, (^[]Transform_Op)(b)^, t, ctx)
		if ok { (^[]Transform_Op)(dst)^ = r }
		return ok
	case []Filter_Op:
		r, ok := interp_filters((^[]Filter_Op)(a)^, (^[]Filter_Op)(b)^, t, ctx)
		if ok { (^[]Filter_Op)(dst)^ = r }
		return ok
	case Translate_Value:
		x, y := (^Translate_Value)(a)^, (^Translate_Value)(b)^
		if !x.set && !y.set { (^Translate_Value)(dst)^ = x; return true }
		if !x.set { x = Translate_Value{set = true, x = px(0), y = px(0)} }
		if !y.set { y = Translate_Value{set = true, x = px(0), y = px(0)} }
		r := Translate_Value{set = true, z = lerp32(x.z, y.z, t)}
		if !interp_length(&r.x, x.x, y.x, t, ctx) || !interp_length(&r.y, x.y, y.y, t, ctx) { return false }
		(^Translate_Value)(dst)^ = r
		return true
	case Rotate_Value:
		x, y := (^Rotate_Value)(a)^, (^Rotate_Value)(b)^
		if !x.set && !y.set { (^Rotate_Value)(dst)^ = x; return true }
		if !x.set { x = Rotate_Value{set = true, axis = y.axis} }
		if !y.set { y = Rotate_Value{set = true, axis = x.axis} }
		r := Rotate_Value{set = true, angle = lerp32(x.angle, y.angle, t)}
		for k in 0 ..< 3 { r.axis[k] = lerp32(x.axis[k], y.axis[k], t) }
		(^Rotate_Value)(dst)^ = r
		return true
	case Scale_Value:
		x, y := (^Scale_Value)(a)^, (^Scale_Value)(b)^
		if !x.set && !y.set { (^Scale_Value)(dst)^ = x; return true }
		if !x.set { x = Scale_Value{set = true, s = {1, 1, 1}} }
		if !y.set { y = Scale_Value{set = true, s = {1, 1, 1}} }
		r := Scale_Value{set = true}
		for k in 0 ..< 3 { r.s[k] = lerp32(x.s[k], y.s[k], t) }
		(^Scale_Value)(dst)^ = r
		return true
	case ^Clip_Path:
		x, y := (^^Clip_Path)(a)^, (^^Clip_Path)(b)^
		if x == nil || y == nil { (^^Clip_Path)(dst)^ = x; return x == y }
		r := new(Clip_Path, ctx.alloc)
		if !interp(r, x, y, type_info_of(Clip_Path), t, ctx) { return false }
		(^^Clip_Path)(dst)^ = r
		return true
	case Easing, Image, ^Gradient, Content, Transition_Prop:
		if deep_equal(a, b, ti) { mem.copy(dst, a, ti.size); return true }
		return false
	}
	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case runtime.Type_Info_Float:
		switch ti.size {
		case 4: (^f32)(dst)^ = lerp32((^f32)(a)^, (^f32)(b)^, t)
		case 8: (^f64)(dst)^ = lerp64((^f64)(a)^, (^f64)(b)^, t)
		case: return false
		}
		return true
	case runtime.Type_Info_Integer:
		x, y: f64
		switch ti.size {
		case 1: x, y = v.signed ? f64((^i8)(a)^) : f64((^u8)(a)^), v.signed ? f64((^i8)(b)^) : f64((^u8)(b)^)
		case 2: x, y = v.signed ? f64((^i16)(a)^) : f64((^u16)(a)^), v.signed ? f64((^i16)(b)^) : f64((^u16)(b)^)
		case 4: x, y = v.signed ? f64((^i32)(a)^) : f64((^u32)(a)^), v.signed ? f64((^i32)(b)^) : f64((^u32)(b)^)
		case 8: x, y = v.signed ? f64((^i64)(a)^) : f64((^u64)(a)^), v.signed ? f64((^i64)(b)^) : f64((^u64)(b)^)
		case: return false
		}
		r := math.round(lerp64(x, y, t))
		switch ti.size {
		case 1: if v.signed { (^i8)(dst)^ = i8(clamp(r, -128, 127)) } else { (^u8)(dst)^ = u8(clamp(r, 0, 255)) }
		case 2: if v.signed { (^i16)(dst)^ = i16(clamp(r, -32768, 32767)) } else { (^u16)(dst)^ = u16(clamp(r, 0, 65535)) }
		case 4: if v.signed { (^i32)(dst)^ = i32(clamp(r, -2e9, 2e9)) } else { (^u32)(dst)^ = u32(clamp(r, 0, 4e9)) }
		case 8: if v.signed { (^i64)(dst)^ = i64(r) } else { (^u64)(dst)^ = u64(max(r, 0)) }
		}
		return true
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) {
			off := v.offsets[i]
			if !interp(rawptr(uintptr(dst) + off), rawptr(uintptr(a) + off), rawptr(uintptr(b) + off), v.types[i], t, ctx) { return false }
		}
		return true
	case runtime.Type_Info_Array:
		for i in 0 ..< v.count {
			off := uintptr(i * v.elem_size)
			if !interp(rawptr(uintptr(dst) + off), rawptr(uintptr(a) + off), rawptr(uintptr(b) + off), v.elem, t, ctx) { return false }
		}
		return true
	case runtime.Type_Info_Enumerated_Array:
		for i in 0 ..< v.count {
			off := uintptr(i * v.elem_size)
			if !interp(rawptr(uintptr(dst) + off), rawptr(uintptr(a) + off), rawptr(uintptr(b) + off), v.elem, t, ctx) { return false }
		}
		return true
	case runtime.Type_Info_Slice:
		sa, sb := (^runtime.Raw_Slice)(a), (^runtime.Raw_Slice)(b)
		if sa.len != sb.len { return false }
		if sa.len == 0 { (^runtime.Raw_Slice)(dst)^ = sa^; return true }
		data, err := mem.alloc(sa.len * v.elem_size, v.elem.align, ctx.alloc)
		if err != nil { return false }
		for i in 0 ..< sa.len {
			off := uintptr(i * v.elem_size)
			if !interp(rawptr(uintptr(data) + off), rawptr(uintptr(sa.data) + off), rawptr(uintptr(sb.data) + off), v.elem, t, ctx) { return false }
		}
		(^runtime.Raw_Slice)(dst)^ = runtime.Raw_Slice{data = data, len = sa.len}
		return true
	}
	// enums, booleans, strings, sets, pointers: only equal values "interpolate"
	if deep_equal(a, b, ti) { mem.copy(dst, a, ti.size); return true }
	return false
}

@(private)
interp_length :: proc(dst: ^Length, a, b: Length, t: f64, ctx: ^Interp_Ctx) -> bool {
	if a.kind == b.kind && (a.kind == .Px || a.kind == .Percent) {
		dst^ = Length{kind = a.kind, v = lerp32(a.v, b.v, t)}
		return true
	}
	numeric :: proc(k: Length_Kind) -> bool { return k == .Px || k == .Percent || k == .Calc }
	if numeric(a.kind) && numeric(b.kind) {
		if t == 0 { dst^ = a; return true }
		if t == 1 { dst^ = b; return true }
		wa := new(css.Calc, ctx.alloc)
		wa^ = css.Calc{op = .Number, num = 1 - t}
		wb := new(css.Calc, ctx.alloc)
		wb^ = css.Calc{op = .Number, num = t}
		ma := new(css.Calc, ctx.alloc)
		ma^ = css.Calc{op = .Mul, a = length_to_calc(a, ctx.alloc), b = wa}
		mb := new(css.Calc, ctx.alloc)
		mb^ = css.Calc{op = .Mul, a = length_to_calc(b, ctx.alloc), b = wb}
		sum := new(css.Calc, ctx.alloc)
		sum^ = css.Calc{op = .Add, a = ma, b = mb}
		dst^ = Length{kind = .Calc, calc = sum}
		return true
	}
	if a.kind == b.kind && a.v == b.v { dst^ = a; return true }   // auto, none, normal...
	return false
}

////////////////////////////////
// Colors

// Premultiplied interpolation: a transparent end takes the other end's hue instead of fading through black.
mix_color :: proc(a, b: css.Color, t: f64, space: Anim_Color_Space) -> css.Color {
	alpha := lerp64(f64(a.a), f64(b.a), t)
	if alpha <= 0 { return {0, 0, 0, 0} }
	out: css.Color
	switch space {
	case .Srgb:
		for k in 0 ..< 3 { out[k] = f32(lerp64(f64(a[k] * a.a), f64(b[k] * b.a), t) / alpha) }
	case .Oklab:
		la, lb := to_oklab(a), to_oklab(b)
		m: [3]f64
		for k in 0 ..< 3 { m[k] = lerp64(la[k] * f64(a.a), lb[k] * f64(b.a), t) / alpha }
		out = from_oklab(m)
	}
	for k in 0 ..< 3 { out[k] = clamp(out[k], 0, 1) }
	out.a = f32(clamp(alpha, 0, 1))
	return out
}

@(private)
lin :: proc(x: f32) -> f64 {
	v := f64(x)
	return v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4)
}

@(private)
gam :: proc(v: f64) -> f32 {
	return f32(v <= 0.0031308 ? 12.92 * v : 1.055 * math.pow(max(v, 0), 1 / 2.4) - 0.055)
}

@(private)
to_oklab :: proc(c: css.Color) -> [3]f64 {
	r, g, b := lin(c.r), lin(c.g), lin(c.b)
	l := math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
	m := math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
	s := math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
	return {0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s, 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s}
}

@(private)
from_oklab :: proc(v: [3]f64) -> css.Color {
	l_ := v[0] + 0.3963377774 * v[1] + 0.2158037573 * v[2]
	m_ := v[0] - 0.1055613458 * v[1] - 0.0638541728 * v[2]
	s_ := v[0] - 0.0894841775 * v[1] - 1.2914855480 * v[2]
	l, m, s := l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_
	return {
		gam(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
		gam(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
		gam(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
		1,
	}
}

////////////////////////////////
// Lists

// Shadow lists: the shorter one is padded with transparent zero shadows; pairs must agree on inset.
@(private)
interp_shadows :: proc(a, b: []Shadow, t: f64, ctx: ^Interp_Ctx) -> ([]Shadow, bool) {
	n := max(len(a), len(b))
	if n == 0 { return nil, true }
	out := make([]Shadow, n, ctx.alloc)
	for i in 0 ..< n {
		x, y: Shadow
		if i < len(a) { x = a[i] }
		if i < len(b) { y = b[i] }
		if i >= len(a) { x = Shadow{inset = y.inset, color = {0, 0, 0, 0}} }
		if i >= len(b) { y = Shadow{inset = x.inset, color = {0, 0, 0, 0}} }
		if x.inset != y.inset { return nil, false }
		out[i] = Shadow{
			x = lerp32(x.x, y.x, t), y = lerp32(x.y, y.y, t), blur = max(lerp32(x.blur, y.blur, t), 0),
			spread = lerp32(x.spread, y.spread, t), color = mix_color(x.color, y.color, t, ctx.space), inset = x.inset,
		}
	}
	return out, true
}

@(private)
identity_op :: proc(kind: Transform_Kind) -> Transform_Op {
	switch kind {
	case .Translate: return op_translate(px(0), px(0))
	case .Scale: return Transform_Op{kind = .Scale, v = {1, 1, 0, 0, 0, 0}}
	case .Rotate: return Transform_Op{kind = .Rotate}
	case .Skew: return Transform_Op{kind = .Skew}
	case .Perspective: return Transform_Op{kind = .Perspective}
	case .Matrix, .Mix: return Transform_Op{kind = .Matrix, v = IDENTITY_MATRIX}
	}
	return Transform_Op{kind = .Matrix, v = IDENTITY_MATRIX}
}

@(private)
box_relative :: proc(ops: []Transform_Op) -> bool {
	for op in ops {
		if op.kind == .Mix { return true }
		if op.kind == .Translate && (has_percent(op.l[0]) || has_percent(op.l[1])) { return true }
	}
	return false
}

@(private)
interp_op :: proc(a, b: Transform_Op, t: f64, ctx: ^Interp_Ctx) -> (Transform_Op, bool) {
	if a.kind != b.kind { return {}, false }
	r := Transform_Op{kind = a.kind}
	switch a.kind {
	case .Translate:
		if !interp_length(&r.l[0], a.l[0], b.l[0], t, ctx) || !interp_length(&r.l[1], a.l[1], b.l[1], t, ctx) { return {}, false }
	case .Scale, .Rotate, .Skew:
		for k in 0 ..< 2 { r.v[k] = lerp32(a.v[k], b.v[k], t) }
	case .Perspective:
		r = t < 0.5 ? a : b
	case .Matrix:
		m := recompose(decomposed_lerp(decompose(Matrix{a.v[0], a.v[1], a.v[2], a.v[3], a.v[4], a.v[5]}), decompose(Matrix{b.v[0], b.v[1], b.v[2], b.v[3], b.v[4], b.v[5]}), f32(t)))
		r.v = m
	case .Mix: return {}, false
	}
	return r, true
}

// Transform lists (CSS Transforms 2 §10): none is the identity of the other list; the common prefix of matching
// functions is interpolated function by function, the rest as matrices (decomposed, interpolated, recomposed). With
// box-relative lengths in the rest the matrices are not known yet: a Mix op defers that to `transform_matrix`.
@(private)
interp_transforms :: proc(a_in, b_in: []Transform_Op, t: f64, ctx: ^Interp_Ctx) -> ([]Transform_Op, bool) {
	a, b := a_in, b_in
	if len(a) == 0 && len(b) == 0 { return nil, true }
	if len(a) == 0 {
		id := make([]Transform_Op, len(b), context.temp_allocator)
		for op, i in b { id[i] = identity_op(op.kind) }
		a = id
	}
	if len(b) == 0 {
		id := make([]Transform_Op, len(a), context.temp_allocator)
		for op, i in a { id[i] = identity_op(op.kind) }
		b = id
	}
	prefix := 0
	for prefix < min(len(a), len(b)) && a[prefix].kind == b[prefix].kind && a[prefix].kind != .Mix { prefix += 1 }
	rest := prefix < len(a) || prefix < len(b)
	out := make([dynamic]Transform_Op, ctx.alloc)
	for i in 0 ..< prefix {
		op, ok := interp_op(a[i], b[i], t, ctx)
		if !ok { return nil, false }
		append(&out, op)
	}
	if rest {
		ra, rb := a[prefix:], b[prefix:]
		if box_relative(ra) || box_relative(rb) {
			mix := new(Transform_Mix, ctx.alloc)
			mix.from = clone_ops(ra, ctx.alloc)
			mix.to = clone_ops(rb, ctx.alloc)
			mix.t = f32(t)
			append(&out, Transform_Op{kind = .Mix, mix = mix})
		} else {
			m := recompose(decomposed_lerp(decompose(ops_matrix(ra, 0, 0)), decompose(ops_matrix(rb, 0, 0)), f32(t)))
			append(&out, Transform_Op{kind = .Matrix, v = m})
		}
	}
	return out[:], true
}

@(private)
clone_ops :: proc(ops: []Transform_Op, a: runtime.Allocator) -> []Transform_Op {
	s := ops
	deep_clone(&s, type_info_of([]Transform_Op), a)
	return s
}

@(private)
identity_filter :: proc(f: Filter_Op) -> Filter_Op {
	r := Filter_Op{kind = f.kind}
	#partial switch f.kind {
	case .Brightness, .Contrast, .Opacity, .Saturate: r.v = 1
	case .Drop_Shadow: r.shadow = Shadow{color = {0, 0, 0, 0}}
	case .Url: r.url = f.url
	}
	return r
}

// Filter lists (Filter Effects 1 §11): function by function when one list is a prefix of the other (the missing tail is
// the identity of the longer list's functions); otherwise discrete.
@(private)
interp_filters :: proc(a, b: []Filter_Op, t: f64, ctx: ^Interp_Ctx) -> ([]Filter_Op, bool) {
	n := max(len(a), len(b))
	if n == 0 { return nil, true }
	for i in 0 ..< min(len(a), len(b)) { if a[i].kind != b[i].kind || a[i].kind == .Url { return nil, false } }
	out := make([]Filter_Op, n, ctx.alloc)
	for i in 0 ..< n {
		x := i < len(a) ? a[i] : identity_filter(b[i])
		y := i < len(b) ? b[i] : identity_filter(a[i])
		if x.kind == .Url { return nil, false }
		r := Filter_Op{kind = x.kind, v = lerp32(x.v, y.v, t)}
		if x.kind == .Drop_Shadow {
			sh, ok := interp_shadows([]Shadow{x.shadow}, []Shadow{y.shadow}, t, ctx)
			if !ok { return nil, false }
			r.shadow = sh[0]
		}
		if r.kind == .Blur { r.v = max(r.v, 0) }
		out[i] = r
	}
	return out, true
}

////////////////////////////////
// Ranges and composition

@(private)
clamp_len :: proc(l: ^Length) { if (l.kind == .Px || l.kind == .Percent) && l.v < 0 { l.v = 0 } }

// Interpolated values outside a property's range (a bouncy cubic-bezier overshoots) are brought back into it.
clamp_prop :: proc(c: ^Computed, p: Prop) {
	#partial switch p {
	case .Opacity: c.opacity = clamp(c.opacity, 0, 1)
	case .Font_Size: c.font_size = max(c.font_size, 0)
	case .Font_Stretch: c.font_stretch = max(c.font_stretch, 0)
	case .Line_Height: c.line_height.v = max(c.line_height.v, 0)
	case .Width: clamp_len(&c.width)
	case .Height: clamp_len(&c.height)
	case .Min_Width: clamp_len(&c.min_width)
	case .Min_Height: clamp_len(&c.min_height)
	case .Max_Width: clamp_len(&c.max_width)
	case .Max_Height: clamp_len(&c.max_height)
	case .Padding_Top, .Padding_Right, .Padding_Bottom, .Padding_Left: clamp_len(&c.padding[Side(int(p) - int(Prop.Padding_Top))])
	case .Border_Top_Width, .Border_Right_Width, .Border_Bottom_Width, .Border_Left_Width:
		s := Side(int(p) - int(Prop.Border_Top_Width))
		c.border_width[s] = max(c.border_width[s], 0)
	case .Border_Top_Left_Radius, .Border_Top_Right_Radius, .Border_Bottom_Right_Radius, .Border_Bottom_Left_Radius:
		r := &c.radius[Corner(int(p) - int(Prop.Border_Top_Left_Radius))]
		clamp_len(&r.h); clamp_len(&r.v)
	case .Outline_Width: c.outline_width = max(c.outline_width, 0)
	case .Flex_Grow: c.flex_grow = max(c.flex_grow, 0)
	case .Flex_Shrink: c.flex_shrink = max(c.flex_shrink, 0)
	case .Flex_Basis: clamp_len(&c.flex_basis)
	case .Row_Gap: clamp_len(&c.row_gap)
	case .Column_Gap: clamp_len(&c.column_gap)
	case .Tab_Size: c.tab_size = max(c.tab_size, 0)
	case .Aspect_Ratio: c.aspect_ratio = max(c.aspect_ratio, 0)
	case .Perspective: c.perspective = max(c.perspective, 0)
	case .Column_Width: clamp_len(&c.column_width)
	case .Column_Count: if c.column_count < 0 { c.column_count = 0 }
	case .Text_Decoration_Thickness: clamp_len(&c.text_decoration_thickness)
	case .Border_Spacing: c.border_spacing = {max(c.border_spacing[0], 0), max(c.border_spacing[1], 0)}
	case .Background_Size:
		for &s in c.background_sizes { clamp_len(&s.w); clamp_len(&s.h) }
		clamp_len(&c.background_size.w); clamp_len(&c.background_size.h)
	}
}

// dst = underlying + value (animation-composition: add and accumulate) for what has a meaningful sum: numbers, px
// lengths (others through calc()), colors, transform lists (concatenated). False: `value` replaces.
add_prop :: proc(dst, underlying, value: ^Computed, p: Prop, ctx: ^Interp_Ctx) -> bool {
	if !animatable(p) { return false }
	#partial switch p {
	case .Transform:
		ops := make([]Transform_Op, len(underlying.transform) + len(value.transform), ctx.alloc)
		copy(ops, underlying.transform)
		copy(ops[len(underlying.transform):], value.transform)
		dst.transform = ops
		return true
	case .Z_Index:
		if underlying.z_auto || value.z_auto { return false }
		dst.z_auto, dst.z_index = false, i32(clamp(i64(underlying.z_index) + i64(value.z_index), i64(min(i32)), i64(max(i32))))
		return true
	}
	da, db := prop_fields(dst, p)
	ua, ub := prop_fields(underlying, p)
	va, vb := prop_fields(value, p)
	if db.data != nil && p != .Color { return false }   // `color` adds in both color schemes
	if !add_values(da.data, ua.data, va.data, type_info_of(da.id), ctx) { return false }
	if db.data != nil && !add_values(db.data, ub.data, vb.data, type_info_of(db.id), ctx) { return false }
	clamp_prop(dst, p)
	return true
}

@(private)
add_values :: proc(dst, a, b: rawptr, ti: ^runtime.Type_Info, ctx: ^Interp_Ctx) -> bool {
	switch ti.id {
	case f32: (^f32)(dst)^ = (^f32)(a)^ + (^f32)(b)^; return true
	case i32: (^i32)(dst)^ = (^i32)(a)^ + (^i32)(b)^; return true
	case u16: (^u16)(dst)^ = u16(min(int((^u16)(a)^) + int((^u16)(b)^), 65535)); return true
	case css.Color:
		x, y := (^css.Color)(a)^, (^css.Color)(b)^
		r: css.Color
		for k in 0 ..< 4 { r[k] = clamp(x[k] + y[k], 0, 1) }
		(^css.Color)(dst)^ = r
		return true
	case Length:
		x, y := (^Length)(a)^, (^Length)(b)^
		if x.kind == y.kind && (x.kind == .Px || x.kind == .Percent) { (^Length)(dst)^ = Length{kind = x.kind, v = x.v + y.v}; return true }
		numeric :: proc(k: Length_Kind) -> bool { return k == .Px || k == .Percent || k == .Calc }
		if !numeric(x.kind) || !numeric(y.kind) { return false }
		sum := new(css.Calc, ctx.alloc)
		sum^ = css.Calc{op = .Add, a = length_to_calc(x, ctx.alloc), b = length_to_calc(y, ctx.alloc)}
		(^Length)(dst)^ = Length{kind = .Calc, calc = sum}
		return true
	}
	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case runtime.Type_Info_Array:
		for i in 0 ..< v.count {
			off := uintptr(i * v.elem_size)
			if !add_values(rawptr(uintptr(dst) + off), rawptr(uintptr(a) + off), rawptr(uintptr(b) + off), v.elem, ctx) { return false }
		}
		return true
	case runtime.Type_Info_Struct:
		for i in 0 ..< int(v.field_count) {
			off := v.offsets[i]
			pa, pb, pd := rawptr(uintptr(a) + off), rawptr(uintptr(b) + off), rawptr(uintptr(dst) + off)
			if add_values(pd, pa, pb, v.types[i], ctx) { continue }
			if !deep_equal(pa, pb, v.types[i]) { return false }   // a field that does not add must agree (kinds, flags)
			mem.copy(pd, pa, v.types[i].size)
		}
		return true
	}
	return false
}
