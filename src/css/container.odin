package css

import "core:strings"

// CSS Containment 3 §6: the prelude of @container. Size features reuse the media query feature parser (width, height,
// inline-size, block-size, aspect-ratio, orientation, with the range syntax); style() queries compare custom
// properties. Evaluation needs the container's size and styles: package style does it (container.odin there).

Cq_Kind :: enum u8 { Size, Style, Not, And, Or, Unknown }

Cq_Node :: struct {
	kind:        Cq_Kind,
	size:        Media_Condition,   // Size: one feature
	style_name:  string,            // Style: the custom property (--x)
	style_value: []Value,           // Style: the value it must have (nil: it must not be the guaranteed-invalid value)
	kids:        []^Cq_Node,        // Not (one), And, Or
}

Container_Query :: struct {
	name: string,     // "" = the nearest container of the right type
	cond: ^Cq_Node,   // nil: only a name (true where a container of that name exists)
}

// The prelude of @container; nil when it is not valid (the rule is then ignored).
parse_container_query :: proc(prelude: []Value, a: Arena_Alloc) -> ^Container_Query {
	vs := trim_values(prelude)
	q := new(Container_Query, a)
	if len(vs) > 0 && vs[0].kind == .Token && vs[0].tok.kind == .Ident {
		switch strings.to_lower(vs[0].tok.text, context.temp_allocator) {
		case "not", "and", "or", "none":
		case:
			q.name = strings.clone(vs[0].tok.text, a)
			vs = trim_values(vs[1:])
		}
	}
	if len(vs) == 0 {
		if q.name == "" { return nil }
		return q
	}
	cond, ok := cq_condition(vs, a)
	if !ok { return nil }
	q.cond = cond
	return q
}

@(private)
cq_condition :: proc(input: []Value, a: Arena_Alloc) -> (^Cq_Node, bool) {
	vs := trim_values(input)
	if len(vs) == 0 { return nil, false }
	if vs[0].kind == .Token && vs[0].tok.kind == .Ident && strings.equal_fold(vs[0].tok.text, "not") {
		inner, ok := cq_in_parens(trim_values(vs[1:]), a)
		if !ok { return nil, false }
		n := new(Cq_Node, a)
		n.kind = .Not
		n.kids = make([]^Cq_Node, 1, a)
		n.kids[0] = inner
		return n, true
	}
	kids := make([dynamic]^Cq_Node, a)
	op := Cq_Kind.And
	saw_op := false
	i := 0
	for i < len(vs) {
		for i < len(vs) && is_ws_value(vs[i]) { i += 1 }
		if i >= len(vs) { break }
		k, ok := cq_in_parens(vs[i:i + 1], a)
		if !ok { return nil, false }
		append(&kids, k)
		i += 1
		for i < len(vs) && is_ws_value(vs[i]) { i += 1 }
		if i < len(vs) {
			if vs[i].kind != .Token || vs[i].tok.kind != .Ident { return nil, false }
			w := strings.to_lower(vs[i].tok.text, context.temp_allocator)
			this: Cq_Kind
			switch w {
			case "and": this = .And
			case "or": this = .Or
			case: return nil, false
			}
			if saw_op && this != op { return nil, false }   // and / or are not mixed without parentheses
			op, saw_op = this, true
			i += 1
		}
	}
	if len(kids) == 0 { return nil, false }
	if len(kids) == 1 { return kids[0], true }
	n := new(Cq_Node, a)
	n.kind, n.kids = op, kids[:]
	return n, true
}

@(private)
cq_in_parens :: proc(vs: []Value, a: Arena_Alloc) -> (^Cq_Node, bool) {
	if len(vs) != 1 { return nil, false }
	v := vs[0]
	n := new(Cq_Node, a)
	if v.kind == .Function {
		if strings.equal_fold(v.tok.text, "style") {
			inner := trim_values(v.children)
			if len(inner) == 0 { return nil, false }
			if inner[0].kind == .Token && inner[0].tok.kind == .Ident && strings.has_prefix(inner[0].tok.text, "--") {
				n.kind, n.style_name = .Style, strings.clone(inner[0].tok.text, a)
				rest := trim_values(inner[1:])
				if len(rest) == 0 { return n, true }
				if rest[0].kind != .Token || rest[0].tok.kind != .Colon { return nil, false }
				n.style_value = trim_values(rest[1:])
				return n, true
			}
		}
		n.kind = .Unknown   // scroll-state(), style() of standard properties, other functions: unknown
		return n, true
	}
	if v.kind != .Block || v.tok.kind != .Open_Paren { return nil, false }
	inner := trim_values(v.children)
	if len(inner) == 0 { return nil, false }
	is_nested := inner[0].kind == .Block || inner[0].kind == .Function ||
		(inner[0].kind == .Token && inner[0].tok.kind == .Ident && strings.equal_fold(inner[0].tok.text, "not") && !has_colon(inner))
	if is_nested {
		if c, ok := cq_condition(inner, a); ok { return c, true }
	}
	f, ok := parse_media_feature(inner, a)
	if !ok { n.kind = .Unknown; return n, true }
	if f.unknown { n.kind = .Unknown; return n, true }
	#partial switch f.feature {
	case .Width, .Height, .Inline_Size, .Block_Size, .Aspect_Ratio, .Orientation:
		n.kind, n.size = .Size, f
	case:
		n.kind = .Unknown   // not a size feature of a container
	}
	return n, true
}

// Size of a query container, CSS px; an axis the container type does not measure is unknown.
Container_Size :: struct {
	w, h:         f64,
	has_w, has_h: bool,
}

// A size feature against a container. Unknown when the axis it reads is not known.
cq_eval_size :: proc(c: Media_Condition, s: Container_Size) -> Tri {
	numeric: f64
	switch c.feature {
	case .Width, .Inline_Size:
		if !s.has_w { return .Unknown }
		numeric = s.w
	case .Height, .Block_Size:
		if !s.has_h { return .Unknown }
		numeric = s.h
	case .Aspect_Ratio:
		if !s.has_w || !s.has_h || s.h <= 0 { return .Unknown }
		numeric = s.w / s.h
	case .Orientation:
		if !s.has_w || !s.has_h { return .Unknown }
		if c.boolean { return .True }
		cur := s.w > s.h ? "landscape" : "portrait"
		return c.ident == cur ? .True : .False
	case .Unknown, .Resolution, .Color, .Monochrome, .Prefers_Color_Scheme, .Prefers_Reduced_Motion, .Prefers_Contrast,
	     .Prefers_Reduced_Data, .Hover, .Any_Hover, .Pointer, .Any_Pointer, .Display_Mode, .Scripting, .Update, .Forced_Colors,
	     .Color_Gamut, .Inverted_Colors, .Dynamic_Range, .Prefers_Reduced_Transparency, .Grid, .Overflow_Block, .Overflow_Inline,
	     .Device_Width, .Device_Height, .Device_Aspect_Ratio:
		return .Unknown
	}
	if c.boolean { return numeric != 0 ? .True : .False }
	if c.has_range {
		ok := true
		if c.has_lo { ok = ok && compare(c.lo, c.lo_cmp, numeric) }
		if c.has_hi { ok = ok && compare(numeric, c.hi_cmp, c.hi) }
		return ok ? .True : .False
	}
	switch c.min_max {
	case -1: return numeric >= c.value ? .True : .False
	case 1: return numeric <= c.value ? .True : .False
	}
	return numeric == c.value ? .True : .False
}
