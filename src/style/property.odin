package style

import "core:fmt"
import "core:math"
import "core:strings"
import "wb:css"

// @property (CSS Properties and Values API 1): registered custom properties. A registration gives a custom property a
// grammar (`syntax`), says whether it inherits and gives it an initial value. The cascade then
//  - computes a declared value against the grammar (lengths to px, angles to deg, times to ms, colors to rgb()); a value
//    that does not match is invalid at computed-value time and behaves as `unset`;
//  - does not pass a non-inherited property down to children: they see its initial value;
//  - substitutes the initial value for var() when nothing declares the property;
//  - interpolates typed values in transitions and animations (see `registered_interpolate`).
// The last valid @property rule for a name wins, in cascade order of the sheets.

Syntax_Type :: enum u8 {
	Ident, Length, Number, Percentage, Length_Percentage, Color, Image, Url, Integer, Angle, Time, Resolution,
	Transform_Function, Transform_List, Custom_Ident, String,
}

Syntax_Mult :: enum u8 { One, Space, Comma }

Syntax_Part :: struct {
	type:  Syntax_Type,
	mult:  Syntax_Mult,
	ident: string,       // Ident: the keyword
}

Registered_Prop :: struct {
	name:        string,
	universal:   bool,            // syntax "*": any value, kept as written
	parts:       []Syntax_Part,   // alternatives, tried in order
	inherits:    bool,
	initial:     string,          // computed initial value as text ("" with has_initial = false: guaranteed-invalid)
	has_initial: bool,
}

// The registration of `name`, nil when it is an ordinary custom property.
registered :: proc(e: ^Engine, name: string) -> ^Registered_Prop {
	if e == nil || len(e.registered) == 0 { return nil }
	return e.registered[name] or_else nil
}

// Parses a syntax string ("<length> | auto", "<color>#", "*"). Strings live in `a`.
parse_syntax :: proc(text: string, a := context.allocator) -> (universal: bool, parts: []Syntax_Part, ok: bool) {
	t := strings.trim_space(text)
	if t == "*" { return true, nil, true }
	if t == "" { return false, nil, false }
	out := make([dynamic]Syntax_Part, a)
	for alt in strings.split(t, "|", context.temp_allocator) {
		s := strings.trim_space(alt)
		if s == "" { return false, nil, false }
		part: Syntax_Part
		switch s[len(s) - 1] {
		case '+': part.mult = .Space; s = s[:len(s) - 1]
		case '#': part.mult = .Comma; s = s[:len(s) - 1]
		}
		if strings.has_prefix(s, "<") && strings.has_suffix(s, ">") {
			switch s[1:len(s) - 1] {
			case "length": part.type = .Length
			case "number": part.type = .Number
			case "percentage": part.type = .Percentage
			case "length-percentage": part.type = .Length_Percentage
			case "color": part.type = .Color
			case "image": part.type = .Image
			case "url": part.type = .Url
			case "integer": part.type = .Integer
			case "angle": part.type = .Angle
			case "time": part.type = .Time
			case "resolution": part.type = .Resolution
			case "transform-function": part.type = .Transform_Function
			case "transform-list":
				if part.mult != .One { return false, nil, false }   // already a list
				part.type = .Transform_List
			case "custom-ident": part.type = .Custom_Ident
			case "string": part.type = .String
			case: return false, nil, false
			}
		} else {
			// a keyword: an identifier, not a CSS-wide keyword
			for ch in s {
				if !(ch == '-' || ch == '_' || ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch >= 0x80) { return false, nil, false }
			}
			switch css.lower_temp(s) {
			case "initial", "inherit", "unset", "revert", "revert-layer", "default": return false, nil, false
			}
			part.type, part.ident = .Ident, strings.clone(s, a)
		}
		append(&out, part)
	}
	return false, out[:], true
}

// Validates an @property rule and records it (engine_rebuild calls this for each rule, in cascade order).
register_property :: proc(e: ^Engine, r: ^css.Rule) {
	syntax_text, has_syntax, has_inherits, inherits := "", false, false, false
	initial: []css.Value
	has_initial := false
	for d in r.declarations {
		switch d.name {
		case "syntax":
			vs := css.trim_values(d.value)
			if len(vs) != 1 || vs[0].kind != .Token || vs[0].tok.kind != .String { return }
			syntax_text, has_syntax = vs[0].tok.text, true
		case "inherits":
			switch css.ident_of(d.value) {
			case "true": inherits, has_inherits = true, true
			case "false": inherits, has_inherits = false, true
			case: return
			}
		case "initial-value":
			initial, has_initial = d.value, true
		}
	}
	if !has_syntax || !has_inherits { return }
	universal, parts, ok := parse_syntax(syntax_text, e.alloc)
	if !ok { return }
	reg := new(Registered_Prop, e.alloc)
	reg^ = Registered_Prop{name = strings.clone(r.name, e.alloc), universal = universal, parts = parts, inherits = inherits}
	if has_initial {
		// computationally independent: no var(), no unit that depends on an element
		if contains_var(initial) || has_relative_unit(initial) { return }
		cx := probe_context(e, e.alloc)
		text, good := registered_compute(&cx, reg, initial, e.alloc)
		if !good { return }
		reg.initial, reg.has_initial = text, true
	} else if !universal {
		return   // only "*" may leave the initial value out
	}
	if e.registered == nil { e.registered = make(map[string]^Registered_Prop) }
	if old := e.registered[reg.name] or_else nil; old != nil && !old.inherits { e.registered_noninherited -= 1 }
	e.registered[reg.name] = reg
	if !inherits { e.registered_noninherited += 1 }
}

@(private)
has_relative_unit :: proc(vs: []css.Value) -> bool {
	for v in vs {
		switch v.kind {
		case .Token:
			if v.tok.kind == .Dimension { if _, rel := css.relative_unit(v.tok.text); rel { return true } }
		case .Function, .Block:
			if has_relative_unit(v.children) { return true }
		}
	}
	return false
}

// The computed value of a registered property as text, or false when `vs` does not match its syntax.
registered_compute :: proc(cx: ^Cx, reg: ^Registered_Prop, vs_in: []css.Value, a := context.allocator) -> (string, bool) {
	vs := css.trim_values(vs_in)
	if reg.universal { return css.serialize_values(vs, a), true }
	if len(vs) == 0 { return "", false }
	for part in reg.parts {
		sb := strings.builder_make(a)
		if syntax_match(cx, part, vs, &sb) { return strings.to_string(sb), true }
		strings.builder_destroy(&sb)
	}
	return "", false
}

@(private)
syntax_match :: proc(cx: ^Cx, part: Syntax_Part, vs: []css.Value, sb: ^strings.Builder) -> bool {
	switch part.mult {
	case .One:
		if part.type == .Transform_List {
			if _, ok := parse_transform_list(cx, vs); !ok { return false }
			strings.write_string(sb, css.serialize_values(vs, context.temp_allocator))
			return true
		}
		items := split_items(vs)
		return len(items) == 1 && syntax_one(cx, part, items[0], sb)
	case .Space:
		items := split_items(vs)
		if len(items) == 0 { return false }
		for it, i in items {
			if i > 0 { strings.write_byte(sb, ' ') }
			if !syntax_one(cx, part, it, sb) { return false }
		}
		return true
	case .Comma:
		for item, i in css.split_commas(vs, context.temp_allocator) {
			parts := split_items(css.trim_values(item))
			if len(parts) != 1 { return false }
			if i > 0 { strings.write_string(sb, ", ") }
			if !syntax_one(cx, part, parts[0], sb) { return false }
		}
		return true
	}
	return false
}

@(private)
write_num :: proc(sb: ^strings.Builder, n: f64, unit: string) {
	if n == math.floor(n) && abs(n) < 1e15 { fmt.sbprintf(sb, "%d", i64(n)) } else { fmt.sbprintf(sb, "%.6g", n) }
	strings.write_string(sb, unit)
}

// One component value against one syntax component; its computed text goes to `sb`.
@(private)
syntax_one :: proc(cx: ^Cx, part: Syntax_Part, v: css.Value, sb: ^strings.Builder) -> bool {
	one := single(v)
	switch part.type {
	case .Ident:
		if v.kind != .Token || v.tok.kind != .Ident || v.tok.text != part.ident { return false }
		strings.write_string(sb, part.ident)
	case .Custom_Ident:
		if v.kind != .Token || v.tok.kind != .Ident { return false }
		switch css.lower_temp(v.tok.text) {
		case "initial", "inherit", "unset", "revert", "revert-layer", "default": return false
		}
		strings.write_string(sb, v.tok.text)
	case .String:
		if v.kind != .Token || v.tok.kind != .String { return false }
		strings.write_string(sb, css.serialize_values(one[:], context.temp_allocator))
	case .Url:
		is_url := (v.kind == .Token && v.tok.kind == .Url) || (v.kind == .Function && strings.equal_fold(v.tok.text, "url"))
		if !is_url { return false }
		strings.write_string(sb, css.serialize_values(one[:], context.temp_allocator))
	case .Number, .Integer:
		n, ok := css.parse_number(one[:])
		if !ok || math.is_nan(n) || math.is_inf(n) { return false }
		if part.type == .Integer {
			if v.kind == .Token && !v.tok.is_int { return false }
			n = math.round(n)
		}
		write_num(sb, n, "")
	case .Percentage:
		if v.kind == .Token && v.tok.kind == .Percentage { write_num(sb, v.tok.num, "%"); return true }
		if v.kind != .Function { return false }
		tree := css.parse_calc(v, context.temp_allocator)
		if tree == nil || !calc_only_unit(tree, .Percent) { return false }
		write_num(sb, css.eval_calc(tree, {percent_base = 100}), "%")
	case .Length, .Length_Percentage:
		flags := Len_Flags{.Negative}
		if part.type == .Length_Percentage { flags += {.Percent} }
		l, ok := parse_length(cx, one[:], flags)
		if !ok { return false }
		#partial switch l.kind {
		case .Px: write_num(sb, f64(l.v), "px")
		case .Percent: write_num(sb, f64(l.v), "%")
		case .Calc:
			// px and percent leaves only now: written back as calc()
			strings.write_string(sb, "calc(")
			write_calc(sb, l.calc)
			strings.write_byte(sb, ')')
		case: return false
		}
	case .Color:
		cv, ok := css.parse_color(one[:], &cx.cenv)
		if !ok { return false }
		if cv.kind == .Current_Color { strings.write_string(sb, "currentcolor"); return true }
		write_color(sb, cv.rgba)
	case .Angle:
		rad, ok := parse_angle(v, false)
		if !ok { return false }
		write_num(sb, f64(rad) * 180 / math.PI, "deg")
	case .Time:
		ms, ok := parse_time(v)
		if !ok { return false }
		write_num(sb, f64(ms) / 1000, "s")
	case .Resolution:
		if v.kind != .Token || v.tok.kind != .Dimension { return false }
		f: f64
		switch css.lower_temp(v.tok.text) {
		case "dppx", "x": f = 1
		case "dpi": f = 1.0 / 96
		case "dpcm": f = 2.54 / 96
		case: return false
		}
		write_num(sb, v.tok.num * f, "dppx")
	case .Image:
		if _, ok := parse_image(cx, one[:]); !ok { return false }
		strings.write_string(sb, css.serialize_values(one[:], context.temp_allocator))
	case .Transform_Function:
		if v.kind != .Function { return false }
		if _, ok := parse_transform_function(cx, v); !ok { return false }
		strings.write_string(sb, css.serialize_values(one[:], context.temp_allocator))
	case .Transform_List:
		return false   // handled as a whole in syntax_match
	}
	return true
}

write_color :: proc(sb: ^strings.Builder, c: css.Color) {
	ch :: proc(x: f32) -> f64 { return math.round(f64(clamp(x, 0, 1)) * 255 * 1000) / 1000 }
	strings.write_string(sb, "rgb(")
	write_num(sb, ch(c.r), " "); write_num(sb, ch(c.g), " "); write_num(sb, ch(c.b), "")
	if c.a < 1 { strings.write_string(sb, " / "); write_num(sb, math.round(f64(c.a) * 10000) / 10000, "") }
	strings.write_byte(sb, ')')
}

@(private)
write_calc :: proc(sb: ^strings.Builder, n: ^css.Calc) {
	if n == nil { strings.write_byte(sb, '0'); return }
	bin :: proc(sb: ^strings.Builder, n: ^css.Calc, op: string) {
		strings.write_byte(sb, '(')
		write_calc(sb, n.a); strings.write_string(sb, op); write_calc(sb, n.b)
		strings.write_byte(sb, ')')
	}
	#partial switch n.op {
	case .Number: write_num(sb, n.num, "")
	case .Dimension: write_num(sb, n.num, n.unit == .Percent ? "%" : "px")
	case .Add: bin(sb, n, " + ")
	case .Sub: bin(sb, n, " - ")
	case .Mul: bin(sb, n, " * ")
	case .Div: bin(sb, n, " / ")
	case .Neg: strings.write_string(sb, "(-1 * "); write_calc(sb, n.a); strings.write_byte(sb, ')')
	case:
		// min(), max(), clamp() and the other functions: their CSS name and arguments
		name, args, count := css.calc_function_of(n)
		strings.write_string(sb, name)
		strings.write_byte(sb, '(')
		if n.op == .Round {
			switch n.strategy {
			case .Nearest:
			case .Up: strings.write_string(sb, "up, ")
			case .Down: strings.write_string(sb, "down, ")
			case .To_Zero: strings.write_string(sb, "to-zero, ")
			}
		}
		for arg, i in args[:count] {
			if i > 0 { strings.write_string(sb, ", ") }
			write_calc(sb, arg)
		}
		strings.write_byte(sb, ')')
	}
}
