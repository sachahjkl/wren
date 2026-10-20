package style

import "base:runtime"
import "core:strings"
import "wb:css"

// Expansion of the shorthands with list values or a richer grammar: font, background (every layer), white-space,
// text-wrap, font-variant, transition, animation, overscroll-behavior, columns and the grid shorthands.

@(private) COMMA_VALUE := css.Value{kind = .Token, tok = {kind = .Comma}}
@(private) SLASH_VALUE := css.Value{kind = .Token, tok = {kind = .Delim, text = "/"}}

@(private)
ident_v :: proc(s: string) -> css.Value { return css.Value{kind = .Token, tok = {kind = .Ident, text = s}} }

@(private)
idents :: proc(a: runtime.Allocator, names: ..string) -> []css.Value {
	out := make([]css.Value, len(names) * 2 - 1, a)
	for n, i in names {
		if i > 0 { out[i * 2 - 1] = WS_VALUE }
		out[i * 2] = ident_v(n)
	}
	return out
}

// Joins per-layer values with commas.
@(private)
comma_join :: proc(layers: [][]css.Value, a: runtime.Allocator) -> []css.Value {
	out := make([dynamic]css.Value, a)
	for l, i in layers {
		if i > 0 { append(&out, COMMA_VALUE) }
		append(&out, ..l)
	}
	return out[:]
}

@(private)
split_at_slash :: proc(items: []css.Value) -> [][]css.Value {
	out := make([dynamic][]css.Value, context.temp_allocator)
	start := 0
	for it, i in items {
		if is_delim(it, "/") { append(&out, items[start:i]); start = i + 1 }
	}
	append(&out, items[start:])
	return out[:]
}

////////////////////////////////
// font

@(private)
FONT_SYSTEM := [?]string{"caption", "icon", "menu", "message-box", "small-caption", "status-bar"}

@(private)
expand_font :: proc(input: []css.Value, a: runtime.Allocator) -> ([]Longhand, bool) {
	vs := css.trim_values(input)
	res := make([dynamic]Longhand, a)
	if id := css.ident_of(vs); id != "" {
		for s in FONT_SYSTEM {
			if s != id { continue }
			append(&res, Longhand{.Font_Style, INITIAL_KW[:]}, Longhand{.Font_Variant_Caps, INITIAL_KW[:]}, Longhand{.Font_Weight, INITIAL_KW[:]},
				Longhand{.Font_Stretch, INITIAL_KW[:]}, Longhand{.Font_Size, idents(a, "medium")}, Longhand{.Line_Height, INITIAL_KW[:]},
				Longhand{.Font_Family, idents(a, "system-ui")})
			for p in FONT_RESETS { append(&res, Longhand{p, INITIAL_KW[:]}) }
			return res[:], true
		}
	}
	i := 0
	skip_ws :: proc(vs: []css.Value, i: ^int) { for i^ < len(vs) && css.is_ws_value(vs[i^]) { i^ += 1 } }
	style, variant, weight, stretch: []css.Value
	skip_ws(vs, &i)
	for i < len(vs) {
		v := vs[i]
		if v.kind == .Token && v.tok.kind == .Ident {
			switch css.lower_temp(v.tok.text) {
			case "normal": i += 1; skip_ws(vs, &i); continue
			case "small-caps": variant = vs[i:i + 1]; i += 1; skip_ws(vs, &i); continue
			case "ultra-condensed", "extra-condensed", "condensed", "semi-condensed", "semi-expanded", "expanded", "extra-expanded", "ultra-expanded":
				stretch = vs[i:i + 1]; i += 1; skip_ws(vs, &i); continue
			case "italic": style = vs[i:i + 1]; i += 1; skip_ws(vs, &i); continue
			case "oblique":
				style = vs[i:i + 1]
				i += 1
				skip_ws(vs, &i)
				if i < len(vs) && vs[i].kind == .Token && vs[i].tok.kind == .Dimension { i += 1; skip_ws(vs, &i) }   // oblique <angle>
				continue
			case "bold", "bolder", "lighter": weight = vs[i:i + 1]; i += 1; skip_ws(vs, &i); continue
			}
		}
		if v.kind == .Token && v.tok.kind == .Number { weight = vs[i:i + 1]; i += 1; skip_ws(vs, &i); continue }
		break
	}
	if i >= len(vs) { return nil, false }
	size := vs[i:i + 1]
	i += 1
	skip_ws(vs, &i)
	line: []css.Value
	if i < len(vs) && is_delim(vs[i], "/") {
		i += 1
		skip_ws(vs, &i)
		if i >= len(vs) { return nil, false }
		line = vs[i:i + 1]
		i += 1
		skip_ws(vs, &i)
	}
	if i >= len(vs) { return nil, false }
	family := vs[i:]
	append(&res, Longhand{.Font_Style, or_initial(style)})
	append(&res, Longhand{.Font_Variant_Caps, or_initial(variant)})
	append(&res, Longhand{.Font_Weight, or_initial(weight)})
	append(&res, Longhand{.Font_Stretch, or_initial(stretch)})
	append(&res, Longhand{.Font_Size, size})
	append(&res, Longhand{.Line_Height, or_initial(line)})
	append(&res, Longhand{.Font_Family, family})
	for p in FONT_RESETS { append(&res, Longhand{p, INITIAL_KW[:]}) }
	return res[:], true
}

////////////////////////////////
// background (CSS Backgrounds 3 §3.10: any number of layers, the color only in the last)

@(private)
expand_background :: proc(input: []css.Value, a: runtime.Allocator) -> ([]Longhand, bool) {
	layers := css.split_commas(css.trim_values(input), a)
	if len(layers) == 0 { return nil, false }
	Layer :: struct { color, image: []css.Value, repeat, pos, size, boxes: [dynamic]css.Value, attach: []css.Value }
	parse_layer :: proc(vs: []css.Value, a: runtime.Allocator) -> (l: Layer, ok: bool) {
		items := split_items(vs, a)
		l.repeat = make([dynamic]css.Value, a)
		l.pos = make([dynamic]css.Value, a)
		l.size = make([dynamic]css.Value, a)
		l.boxes = make([dynamic]css.Value, a)
		in_size := false
		if len(items) == 0 { return }
		for it, i in items {
			if is_delim(it, "/") {
				if in_size || len(l.pos) == 0 { return }
				in_size = true
				continue
			}
			#partial switch it.kind {
			case .Function:
				switch css.lower_temp(it.tok.text) {
				case "url", "image", "image-set", "-webkit-image-set", "cross-fade", "element",
				     "linear-gradient", "radial-gradient", "conic-gradient", "repeating-linear-gradient", "repeating-radial-gradient", "repeating-conic-gradient",
				     "-webkit-linear-gradient", "-webkit-radial-gradient", "-webkit-repeating-linear-gradient", "-webkit-repeating-radial-gradient",
				     "-moz-linear-gradient", "-moz-radial-gradient", "-o-linear-gradient":
					if l.image != nil { return }
					l.image = items[i:i + 1]
				case "calc", "min", "max", "clamp":
					append(in_size ? &l.size : &l.pos, it)
				case:
					if l.color != nil { return }
					l.color = items[i:i + 1]
				}
			case .Token:
				#partial switch it.tok.kind {
				case .Url:
					if l.image != nil { return }
					l.image = items[i:i + 1]
				case .Hash:
					if l.color != nil { return }
					l.color = items[i:i + 1]
				case .Dimension, .Percentage, .Number: append(in_size ? &l.size : &l.pos, it)
				case .Ident:
					switch css.lower_temp(it.tok.text) {
					case "none":
						if l.image != nil { return }
						l.image = items[i:i + 1]
					case "repeat", "no-repeat", "repeat-x", "repeat-y", "space", "round": append(&l.repeat, it)
					case "scroll", "fixed", "local":
						if l.attach != nil { return }
						l.attach = items[i:i + 1]
					case "border-box", "padding-box", "content-box", "text": append(&l.boxes, it)
					case "left", "right", "top", "bottom", "center":
						if in_size { return }
						append(&l.pos, it)
					case "auto", "cover", "contain":
						if !in_size { return }
						append(&l.size, it)
					case:
						if l.color != nil { return }
						l.color = items[i:i + 1]
					}
				case: return
				}
			case: return
			}
		}
		if len(l.boxes) > 2 || len(l.repeat) > 2 { return }
		return l, true
	}
	n := len(layers)
	images := make([][]css.Value, n, a)
	repeats := make([][]css.Value, n, a)
	positions := make([][]css.Value, n, a)
	sizes := make([][]css.Value, n, a)
	origins := make([][]css.Value, n, a)
	clips := make([][]css.Value, n, a)
	attachments := make([][]css.Value, n, a)
	color: []css.Value
	for layer, k in layers {
		l, ok := parse_layer(layer, a)
		if !ok { return nil, false }
		if l.color != nil && k != n - 1 { return nil, false }   // only the bottom layer has a color
		if k == n - 1 { color = l.color }
		images[k] = l.image != nil ? l.image : idents(a, "none")
		repeats[k] = len(l.repeat) > 0 ? join_items(l.repeat[:], a) : idents(a, "repeat")
		positions[k] = len(l.pos) > 0 ? join_items(l.pos[:], a) : join_items(([]css.Value{{kind = .Token, tok = {kind = .Percentage}}, {kind = .Token, tok = {kind = .Percentage}}}), a)
		sizes[k] = len(l.size) > 0 ? join_items(l.size[:], a) : idents(a, "auto")
		switch len(l.boxes) {
		case 0: origins[k], clips[k] = idents(a, "padding-box"), idents(a, "border-box")
		case 1: origins[k], clips[k] = l.boxes[0:1], l.boxes[0:1]
		case: origins[k], clips[k] = l.boxes[0:1], l.boxes[1:2]
		}
		if is_ident(origins[k][0], "text") { origins[k] = idents(a, "border-box") }   // `text` is a clip only
		attachments[k] = l.attach != nil ? l.attach : idents(a, "scroll")
	}
	res := make([dynamic]Longhand, a)
	append(&res, Longhand{.Background_Color, or_initial(color)})
	append(&res, Longhand{.Background_Image, comma_join(images, a)})
	append(&res, Longhand{.Background_Repeat, comma_join(repeats, a)})
	append(&res, Longhand{.Background_Position, comma_join(positions, a)})
	append(&res, Longhand{.Background_Size, comma_join(sizes, a)})
	append(&res, Longhand{.Background_Origin, comma_join(origins, a)})
	append(&res, Longhand{.Background_Clip, comma_join(clips, a)})
	append(&res, Longhand{.Background_Attachment, comma_join(attachments, a)})
	return res[:], true
}

////////////////////////////////
// The others

@(private)
WRAP_STYLES := [?]string{"auto", "balance", "stable", "pretty"}
@(private)
COLLAPSES := [?]string{"collapse", "preserve", "preserve-breaks", "preserve-spaces", "break-spaces", "discard"}
@(private)
FONT_VARIANT_OTHER := [?]string{
	"none", "common-ligatures", "no-common-ligatures", "discretionary-ligatures", "no-discretionary-ligatures",
	"historical-ligatures", "no-historical-ligatures", "contextual", "no-contextual", "lining-nums", "oldstyle-nums",
	"proportional-nums", "tabular-nums", "diagonal-fractions", "stacked-fractions", "ordinal", "slashed-zero",
	"jis78", "jis83", "jis90", "jis04", "simplified", "traditional", "full-width", "proportional-width", "ruby", "sub",
	"super", "text", "emoji", "unicode",
}
@(private)
FONT_VARIANT_CAPS := [?]string{"small-caps", "all-small-caps", "petite-caps", "all-petite-caps", "unicase", "titling-caps"}

@(private)
in_list :: proc(s: string, list: []string) -> bool {
	for x in list { if x == s { return true } }
	return false
}

expand_shorthand_more :: proc(s: Short, vs: []css.Value, a: runtime.Allocator) -> ([]Longhand, bool) {
	res := make([dynamic]Longhand, a)
	items := split_items(css.trim_values(vs), a)
	emit :: proc(res: ^[dynamic]Longhand, p: Prop, v: []css.Value) { append(res, Longhand{p, v}) }
	#partial switch s {
	case .White_Space:
		// CSS Text 4: white-space = white-space-collapse || text-wrap-mode, plus the legacy keywords
		if len(items) == 1 {
			switch ident_lower(items[0]) {
			case "normal": emit(&res, .White_Space_Collapse, idents(a, "collapse")); emit(&res, .Text_Wrap_Mode, idents(a, "wrap")); return res[:], true
			case "pre": emit(&res, .White_Space_Collapse, idents(a, "preserve")); emit(&res, .Text_Wrap_Mode, idents(a, "nowrap")); return res[:], true
			case "pre-wrap": emit(&res, .White_Space_Collapse, idents(a, "preserve")); emit(&res, .Text_Wrap_Mode, idents(a, "wrap")); return res[:], true
			case "pre-line": emit(&res, .White_Space_Collapse, idents(a, "preserve-breaks")); emit(&res, .Text_Wrap_Mode, idents(a, "wrap")); return res[:], true
			case "nowrap": emit(&res, .White_Space_Collapse, idents(a, "collapse")); emit(&res, .Text_Wrap_Mode, idents(a, "nowrap")); return res[:], true
			case "break-spaces": emit(&res, .White_Space_Collapse, idents(a, "break-spaces")); emit(&res, .Text_Wrap_Mode, idents(a, "wrap")); return res[:], true
			}
		}
		if len(items) < 1 || len(items) > 2 { return nil, false }
		col, wrap: []css.Value
		for it, i in items {
			id := ident_lower(it)
			switch {
			case in_list(id, COLLAPSES[:]): if col != nil { return nil, false }; col = items[i:i + 1]
			case id == "wrap" || id == "nowrap": if wrap != nil { return nil, false }; wrap = items[i:i + 1]
			case: return nil, false
			}
		}
		emit(&res, .White_Space_Collapse, or_initial(col))
		emit(&res, .Text_Wrap_Mode, or_initial(wrap))
	case .Text_Wrap:
		if len(items) < 1 || len(items) > 2 { return nil, false }
		mode, style: []css.Value
		for it, i in items {
			id := ident_lower(it)
			switch {
			case id == "wrap" || id == "nowrap": if mode != nil { return nil, false }; mode = items[i:i + 1]
			case in_list(id, WRAP_STYLES[:]): if style != nil { return nil, false }; style = items[i:i + 1]
			case: return nil, false
			}
		}
		emit(&res, .Text_Wrap_Mode, or_initial(mode))
		emit(&res, .Text_Wrap_Style, or_initial(style))
	case .Font_Variant:
		return expand_font_variant(items, a)
	case .Overscroll_Behavior:
		if len(items) < 1 || len(items) > 2 { return nil, false }
		emit(&res, .Overscroll_Behavior_X, items[0:1])
		emit(&res, .Overscroll_Behavior_Y, items[len(items) - 1:])
	case .Columns:
		if len(items) < 1 || len(items) > 2 { return nil, false }
		width, count: []css.Value
		for it, i in items {
			switch {
			case is_ident(it, "auto"): continue
			case tok_is(it, .Number): if count != nil { return nil, false }; count = items[i:i + 1]
			case: if width != nil { return nil, false }; width = items[i:i + 1]
			}
		}
		emit(&res, .Column_Width, or_initial(width))
		emit(&res, .Column_Count, or_initial(count))
	case .Transition: return expand_transition(vs, a)
	case .Animation: return expand_animation(vs, a)
	case .Grid_Row, .Grid_Column:
		parts := split_at_slash(items)
		if len(parts) > 2 || len(parts[0]) == 0 { return nil, false }
		start := parts[0]
		end := len(parts) == 2 ? parts[1] : grid_line_default_end(start, a)
		if len(end) == 0 { return nil, false }
		props := short_longhands(s)
		emit(&res, props[0], join_items(start, a))
		emit(&res, props[1], join_items(end, a))
	case .Grid_Area:
		parts := split_at_slash(items)
		if len(parts) > 4 { return nil, false }
		for p in parts { if len(p) == 0 { return nil, false } }
		vals: [4][]css.Value
		for p, i in parts { vals[i] = p }
		// row-start / column-start / row-end / column-end; missing ones copy a lone name or become auto
		if len(parts) < 2 { vals[1] = grid_line_default_end(vals[0], a) }
		if len(parts) < 3 { vals[2] = grid_line_default_end(vals[0], a) }
		if len(parts) < 4 { vals[3] = grid_line_default_end(vals[1], a) }
		emit(&res, .Grid_Row_Start, join_items(vals[0], a))
		emit(&res, .Grid_Column_Start, join_items(vals[1], a))
		emit(&res, .Grid_Row_End, join_items(vals[2], a))
		emit(&res, .Grid_Column_End, join_items(vals[3], a))
	case .Grid_Template: return expand_grid_template(items, a)
	case .Grid: return expand_grid(items, a)
	case: return nil, false
	}
	return res[:], true
}

// The end line a grid-row / grid-column / grid-area gets when it is not written: the same name when the start is a
// lone name, else auto.
@(private)
grid_line_default_end :: proc(start: []css.Value, a: runtime.Allocator) -> []css.Value {
	if len(start) == 1 && tok_is(start[0], .Ident) && !is_ident(start[0], "span") { return start }
	return idents(a, "auto")
}

// grid-template: none | rows / columns | [names? "string" size? names?]+ [/ columns]?
@(private)
expand_grid_template :: proc(items: []css.Value, a: runtime.Allocator) -> ([]Longhand, bool) {
	res := make([dynamic]Longhand, a)
	if len(items) == 1 && is_ident(items[0], "none") {
		append(&res, Longhand{.Grid_Template_Rows, idents(a, "none")}, Longhand{.Grid_Template_Columns, idents(a, "none")}, Longhand{.Grid_Template_Areas, idents(a, "none")})
		return res[:], true
	}
	parts := split_at_slash(items)
	if len(parts) > 2 { return nil, false }
	has_strings := false
	for it in parts[0] { if tok_is(it, .String) { has_strings = true; break } }
	if !has_strings {
		if len(parts) != 2 || len(parts[0]) == 0 || len(parts[1]) == 0 { return nil, false }
		append(&res, Longhand{.Grid_Template_Rows, join_items(parts[0], a)}, Longhand{.Grid_Template_Columns, join_items(parts[1], a)}, Longhand{.Grid_Template_Areas, idents(a, "none")})
		return res[:], true
	}
	rows := make([dynamic]css.Value, a)
	areas := make([dynamic]css.Value, a)
	row_items := parts[0]
	i := 0
	for i < len(row_items) {
		if is_line_names(row_items[i]) { append(&rows, row_items[i]); i += 1; continue }
		if !tok_is(row_items[i], .String) { return nil, false }
		append(&areas, row_items[i])
		i += 1
		if i < len(row_items) && !is_line_names(row_items[i]) && !tok_is(row_items[i], .String) {
			if row_items[i].kind == .Function && strings.equal_fold(row_items[i].tok.text, "repeat") { return nil, false }
			append(&rows, row_items[i])
			i += 1
		} else {
			append(&rows, ident_v("auto"))
		}
	}
	cols := len(parts) == 2 ? join_items(parts[1], a) : idents(a, "none")
	if len(parts) == 2 {
		for it in parts[1] { if it.kind == .Function && strings.equal_fold(it.tok.text, "repeat") {
			args := css.split_commas(it.children, context.temp_allocator)
			if len(args) > 0 { switch css.ident_of(args[0]) { case "auto-fill", "auto-fit": return nil, false } }
		} }
	}
	append(&res, Longhand{.Grid_Template_Rows, join_items(rows[:], a)}, Longhand{.Grid_Template_Columns, cols}, Longhand{.Grid_Template_Areas, join_items(areas[:], a)})
	return res[:], true
}

// grid: <grid-template> | rows / auto-flow dense? columns? | auto-flow dense? rows? / columns
@(private)
expand_grid :: proc(items: []css.Value, a: runtime.Allocator) -> ([]Longhand, bool) {
	parts := split_at_slash(items)
	auto_flow_in :: proc(vs: []css.Value) -> (found, dense: bool, rest: []css.Value) {
		k := 0
		for k < len(vs) && (is_ident(vs[k], "auto-flow") || is_ident(vs[k], "dense")) {
			if is_ident(vs[k], "auto-flow") { found = true } else { dense = true }
			k += 1
		}
		if !found { return false, false, vs }
		return true, dense, vs[k:]
	}
	res := make([dynamic]Longhand, a)
	if len(parts) == 2 {
		if found, dense, rest := auto_flow_in(parts[1]); found {
			if len(parts[0]) == 0 { return nil, false }
			append(&res, Longhand{.Grid_Template_Rows, join_items(parts[0], a)}, Longhand{.Grid_Template_Columns, idents(a, "none")}, Longhand{.Grid_Template_Areas, idents(a, "none")})
			append(&res, Longhand{.Grid_Auto_Rows, idents(a, "auto")}, Longhand{.Grid_Auto_Columns, len(rest) > 0 ? join_items(rest, a) : idents(a, "auto")})
			append(&res, Longhand{.Grid_Auto_Flow, dense ? idents(a, "column", "dense") : idents(a, "column")})
			return res[:], true
		}
		if found, dense, rest := auto_flow_in(parts[0]); found {
			if len(parts[1]) == 0 { return nil, false }
			append(&res, Longhand{.Grid_Template_Rows, idents(a, "none")}, Longhand{.Grid_Template_Columns, join_items(parts[1], a)}, Longhand{.Grid_Template_Areas, idents(a, "none")})
			append(&res, Longhand{.Grid_Auto_Rows, len(rest) > 0 ? join_items(rest, a) : idents(a, "auto")}, Longhand{.Grid_Auto_Columns, idents(a, "auto")})
			append(&res, Longhand{.Grid_Auto_Flow, dense ? idents(a, "row", "dense") : idents(a, "row")})
			return res[:], true
		}
	}
	tpl, ok := expand_grid_template(items, a)
	if !ok { return nil, false }
	append(&res, ..tpl)
	append(&res, Longhand{.Grid_Auto_Rows, idents(a, "auto")}, Longhand{.Grid_Auto_Columns, idents(a, "auto")}, Longhand{.Grid_Auto_Flow, idents(a, "row")})
	return res[:], true
}

////////////////////////////////
// transition and animation

@(private)
is_time_value :: proc(v: css.Value) -> bool {
	_, ok := parse_time(v)
	return ok
}

@(private)
is_easing_value :: proc(v: css.Value) -> bool {
	switch ident_lower(v) {
	case "linear", "ease", "ease-in", "ease-out", "ease-in-out", "step-start", "step-end": return true
	}
	if v.kind == .Function {
		switch css.lower_temp(v.tok.text) { case "cubic-bezier", "steps", "linear": return true }
	}
	return false
}

// transition: [ none | <property> ] || <time> || <easing> || <time> || <behavior>, comma-separated.
@(private)
expand_transition :: proc(vs: []css.Value, a: runtime.Allocator) -> ([]Longhand, bool) {
	layers := css.split_commas(css.trim_values(vs), a)
	n := len(layers)
	if n == 0 { return nil, false }
	props := make([][]css.Value, n, a)
	durs := make([][]css.Value, n, a)
	eases := make([][]css.Value, n, a)
	delays := make([][]css.Value, n, a)
	behs := make([][]css.Value, n, a)
	for layer, k in layers {
		items := split_items(layer, a)
		if len(items) == 0 { return nil, false }
		prop, dur, ease, delay, beh: []css.Value
		for it, i in items {
			switch {
			case is_time_value(it):
				if dur == nil { dur = items[i:i + 1] } else if delay == nil { delay = items[i:i + 1] } else { return nil, false }
			case is_easing_value(it):
				if ease != nil { return nil, false }
				ease = items[i:i + 1]
			case is_ident(it, "normal") || is_ident(it, "allow-discrete"):
				if beh != nil { return nil, false }
				beh = items[i:i + 1]
			case tok_is(it, .Ident):
				if prop != nil { return nil, false }
				if is_ident(it, "none") && n > 1 { return nil, false }
				prop = items[i:i + 1]
			case: return nil, false
			}
		}
		props[k] = prop != nil ? prop : idents(a, "all")
		durs[k] = dur != nil ? dur : time_zero(a)
		eases[k] = ease != nil ? ease : idents(a, "ease")
		delays[k] = delay != nil ? delay : time_zero(a)
		behs[k] = beh != nil ? beh : idents(a, "normal")
	}
	res := make([dynamic]Longhand, a)
	append(&res, Longhand{.Transition_Property, comma_join(props, a)}, Longhand{.Transition_Duration, comma_join(durs, a)},
		Longhand{.Transition_Timing_Function, comma_join(eases, a)}, Longhand{.Transition_Delay, comma_join(delays, a)},
		Longhand{.Transition_Behavior, comma_join(behs, a)})
	return res[:], true
}

@(private)
time_zero :: proc(a: runtime.Allocator) -> []css.Value {
	v := make([]css.Value, 1, a)
	v[0] = css.Value{kind = .Token, tok = css.Token{kind = .Dimension, num = 0, is_int = true, text = "s"}}
	return v
}

// animation: <time> || <easing> || <time> || <iteration-count> || <direction> || <fill-mode> || <play-state> || <name>.
// A keyword is given to the first property that accepts it and has no value yet; what is left is the name.
@(private)
expand_animation :: proc(vs: []css.Value, a: runtime.Allocator) -> ([]Longhand, bool) {
	layers := css.split_commas(css.trim_values(vs), a)
	n := len(layers)
	if n == 0 { return nil, false }
	cols: [9][][]css.Value
	for &c in cols { c = make([][]css.Value, n, a) }
	DEFAULTS := [9]string{"none", "", "ease", "", "1", "normal", "none", "running", "replace"}
	for layer, k in layers {
		items := split_items(layer, a)
		if len(items) == 0 { return nil, false }
		got: [9][]css.Value   // name, duration, easing, delay, count, direction, fill, play, composition
		for it, i in items {
			v := items[i:i + 1]
			id := ident_lower(it)
			switch {
			case is_time_value(it):
				if got[1] == nil { got[1] = v } else if got[3] == nil { got[3] = v } else { return nil, false }
				continue
			case is_easing_value(it) && got[2] == nil: got[2] = v; continue
			case (id == "infinite" || tok_is(it, .Number)) && got[4] == nil: got[4] = v; continue
			case (id == "normal" || id == "reverse" || id == "alternate" || id == "alternate-reverse") && got[5] == nil: got[5] = v; continue
			case (id == "none" || id == "forwards" || id == "backwards" || id == "both") && got[6] == nil && id != "none": got[6] = v; continue
			case (id == "running" || id == "paused") && got[7] == nil: got[7] = v; continue
			}
			if (tok_is(it, .Ident) || tok_is(it, .String)) && got[0] == nil { got[0] = v; continue }
			// `none` twice: the first is the fill mode, the second the name
			if id == "none" && got[6] == nil { got[6] = v; continue }
			return nil, false
		}
		for c in 0 ..< 9 {
			switch {
			case got[c] != nil: cols[c][k] = got[c]
			case c == 1 || c == 3: cols[c][k] = time_zero(a)
			case c == 4: cols[c][k] = number_value(1, a)
			case: cols[c][k] = idents(a, DEFAULTS[c])
			}
		}
	}
	props := [9]Prop{.Animation_Name, .Animation_Duration, .Animation_Timing_Function, .Animation_Delay, .Animation_Iteration_Count, .Animation_Direction, .Animation_Fill_Mode, .Animation_Play_State, .Animation_Composition}
	res := make([dynamic]Longhand, a)
	for c in 0 ..< 9 { append(&res, Longhand{props[c], comma_join(cols[c], a)}) }
	return res[:], true
}
