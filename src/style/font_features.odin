package style

import "base:runtime"
import "wb:css"

// OpenType features and variations of fonts (CSS Fonts 4 §6, §7): font-feature-settings, font-variation-settings,
// font-kerning, font-variant-ligatures / -numeric / -east-asian / -position (font-variant-caps is in values_more.odin),
// and unicode-bidi (CSS Writing Modes 4 §2.2), which layout's bidi algorithm reads. The font-variant shorthand sets every
// variant longhand; `font` resets them (CSS Fonts 4 §2.8).

Font_Feature_Setting :: struct { tag: [4]u8, value: u32 }
Font_Variation_Setting :: struct { tag: [4]u8, value: f32 }

Font_Kerning :: enum u8 { Auto, Normal, None }
Font_Variant_Position :: enum u8 { Normal, Sub, Super }

// Empty set: `normal`. None alone: `none` (every ligature off).
Ligature_Value :: enum u8 {
	None, Common, No_Common, Discretionary, No_Discretionary, Historical, No_Historical, Contextual, No_Contextual,
}
Font_Variant_Ligatures :: bit_set[Ligature_Value; u16]

Numeric_Value :: enum u8 { Lining, Oldstyle, Proportional, Tabular, Diagonal_Fractions, Stacked_Fractions, Ordinal, Slashed_Zero }
Font_Variant_Numeric :: bit_set[Numeric_Value; u8]

East_Asian_Value :: enum u8 { Jis78, Jis83, Jis90, Jis04, Simplified, Traditional, Full_Width, Proportional_Width, Ruby }
Font_Variant_East_Asian :: bit_set[East_Asian_Value; u16]

Unicode_Bidi :: enum u8 { Normal, Embed, Isolate, Bidi_Override, Isolate_Override, Plaintext }

@(private)
LIGATURE_NAMES := [Ligature_Value]string{
	.None = "none", .Common = "common-ligatures", .No_Common = "no-common-ligatures",
	.Discretionary = "discretionary-ligatures", .No_Discretionary = "no-discretionary-ligatures",
	.Historical = "historical-ligatures", .No_Historical = "no-historical-ligatures",
	.Contextual = "contextual", .No_Contextual = "no-contextual",
}
@(private)
NUMERIC_NAMES := [Numeric_Value]string{
	.Lining = "lining-nums", .Oldstyle = "oldstyle-nums", .Proportional = "proportional-nums", .Tabular = "tabular-nums",
	.Diagonal_Fractions = "diagonal-fractions", .Stacked_Fractions = "stacked-fractions", .Ordinal = "ordinal", .Slashed_Zero = "slashed-zero",
}
@(private)
EAST_ASIAN_NAMES := [East_Asian_Value]string{
	.Jis78 = "jis78", .Jis83 = "jis83", .Jis90 = "jis90", .Jis04 = "jis04", .Simplified = "simplified",
	.Traditional = "traditional", .Full_Width = "full-width", .Proportional_Width = "proportional-width", .Ruby = "ruby",
}

// Which font-variant longhand a keyword of the shorthand belongs to (Font_Size: none).
font_variant_part :: proc(id: string) -> Prop {
	for n in LIGATURE_NAMES { if n == id { return .Font_Variant_Ligatures } }
	for n in NUMERIC_NAMES { if n == id { return .Font_Variant_Numeric } }
	for n in EAST_ASIAN_NAMES { if n == id { return .Font_Variant_East_Asian } }
	switch id {
	case "sub", "super": return .Font_Variant_Position
	case "small-caps", "all-small-caps", "petite-caps", "all-petite-caps", "unicase", "titling-caps": return .Font_Variant_Caps
	}
	return .Font_Size
}

@(private)
parse_ligatures :: proc(vs: []css.Value) -> (Font_Variant_Ligatures, bool) {
	items := split_items(css.trim_values(vs))
	set: Font_Variant_Ligatures
	if len(items) == 1 {
		switch ident_lower(items[0]) {
		case "normal": return {}, true
		case "none": return {.None}, true
		}
	}
	for it in items {
		id := ident_lower(it)
		found := false
		for n, v in LIGATURE_NAMES {
			if n != id || v == .None { continue }
			// one value per group: common, discretionary, historical, contextual
			pair := Ligature_Value(int(v) & 1 == 1 ? int(v) + 1 : int(v) - 1)
			if v in set || pair in set { return {}, false }
			set += {v}
			found = true
		}
		if !found { return {}, false }
	}
	return set, len(items) > 0
}

@(private)
parse_numeric :: proc(vs: []css.Value) -> (Font_Variant_Numeric, bool) {
	items := split_items(css.trim_values(vs))
	if len(items) == 1 && ident_lower(items[0]) == "normal" { return {}, true }
	set: Font_Variant_Numeric
	for it in items {
		id := ident_lower(it)
		found := false
		for n, v in NUMERIC_NAMES {
			if n != id { continue }
			if v in set { return {}, false }
			// exclusive pairs: lining / oldstyle, proportional / tabular, diagonal / stacked
			#partial switch v {
			case .Lining: if .Oldstyle in set { return {}, false }
			case .Oldstyle: if .Lining in set { return {}, false }
			case .Proportional: if .Tabular in set { return {}, false }
			case .Tabular: if .Proportional in set { return {}, false }
			case .Diagonal_Fractions: if .Stacked_Fractions in set { return {}, false }
			case .Stacked_Fractions: if .Diagonal_Fractions in set { return {}, false }
			}
			set += {v}
			found = true
		}
		if !found { return {}, false }
	}
	return set, len(items) > 0
}

@(private)
parse_east_asian :: proc(vs: []css.Value) -> (Font_Variant_East_Asian, bool) {
	items := split_items(css.trim_values(vs))
	if len(items) == 1 && ident_lower(items[0]) == "normal" { return {}, true }
	set: Font_Variant_East_Asian
	for it in items {
		id := ident_lower(it)
		found := false
		for n, v in EAST_ASIAN_NAMES {
			if n != id || v in set { continue }
			set += {v}
			found = true
		}
		if !found { return {}, false }
	}
	return set, len(items) > 0
}

@(private)
tag_of :: proc(s: string) -> ([4]u8, bool) {
	if len(s) != 4 { return {}, false }
	t: [4]u8
	for i in 0 ..< 4 {
		if s[i] < 0x20 || s[i] > 0x7E { return {}, false }
		t[i] = s[i]
	}
	return t, true
}

// `normal` | [<string> [<integer [0,∞]> | on | off]?]#
@(private)
parse_feature_settings :: proc(vs: []css.Value, a: runtime.Allocator) -> ([]Font_Feature_Setting, bool) {
	trimmed := css.trim_values(vs)
	if id := css.ident_of(trimmed); id == "normal" { return nil, true }
	parts := css.split_commas(trimmed, context.temp_allocator)
	out := make([]Font_Feature_Setting, len(parts), a)
	for part, i in parts {
		items := split_items(css.trim_values(part))
		if len(items) < 1 || len(items) > 2 || !tok_is(items[0], .String) { return nil, false }
		tag, ok := tag_of(items[0].tok.text)
		if !ok { return nil, false }
		value: u32 = 1
		if len(items) == 2 {
			it := items[1]
			switch {
			case tok_is(it, .Number) && it.tok.is_int && it.tok.num >= 0: value = u32(min(it.tok.num, f64(max(u32))))
			case ident_lower(it) == "on": value = 1
			case ident_lower(it) == "off": value = 0
			case: return nil, false
			}
		}
		out[i] = {tag, value}
	}
	return out, true
}

// `normal` | [<string> <number>]#
@(private)
parse_variation_settings :: proc(vs: []css.Value, a: runtime.Allocator) -> ([]Font_Variation_Setting, bool) {
	trimmed := css.trim_values(vs)
	if id := css.ident_of(trimmed); id == "normal" { return nil, true }
	parts := css.split_commas(trimmed, context.temp_allocator)
	out := make([]Font_Variation_Setting, len(parts), a)
	for part, i in parts {
		items := split_items(css.trim_values(part))
		if len(items) != 2 || !tok_is(items[0], .String) || !tok_is(items[1], .Number) { return nil, false }
		tag, ok := tag_of(items[0].tok.text)
		if !ok { return nil, false }
		out[i] = {tag, f32(items[1].tok.num)}
	}
	return out, true
}

// Computes the properties of this file (dispatched from apply_prop).
apply_font_feature_prop :: proc(cx: ^Cx, p: Prop, vs: []css.Value) -> bool {
	c := cx.c
	#partial switch p {
	case .Font_Feature_Settings:
		v, ok := parse_feature_settings(vs, cx.alloc)
		if ok { c.font_feature_settings = v }
		return ok
	case .Font_Variation_Settings:
		v, ok := parse_variation_settings(vs, cx.alloc)
		if ok { c.font_variation_settings = v }
		return ok
	case .Font_Kerning: return set_enum(vs, &c.font_kerning)
	case .Font_Variant_Position: return set_enum(vs, &c.font_variant_position)
	case .Font_Variant_Ligatures:
		v, ok := parse_ligatures(vs)
		if ok { c.font_variant_ligatures = v }
		return ok
	case .Font_Variant_Numeric:
		v, ok := parse_numeric(vs)
		if ok { c.font_variant_numeric = v }
		return ok
	case .Font_Variant_East_Asian:
		v, ok := parse_east_asian(vs)
		if ok { c.font_variant_east_asian = v }
		return ok
	case .Unicode_Bidi: return set_enum(vs, &c.unicode_bidi)
	}
	return false
}

// font-variant: normal | none | [every sub-property's keywords] (CSS Fonts 4 §6.11). The functional values of
// font-variant-alternates are accepted and have no effect.
expand_font_variant :: proc(items: []css.Value, a: runtime.Allocator) -> ([]Longhand, bool) {
	res := make([dynamic]Longhand, a)
	PARTS := [?]Prop{.Font_Variant_Ligatures, .Font_Variant_Caps, .Font_Variant_Numeric, .Font_Variant_East_Asian, .Font_Variant_Position}
	groups: [len(PARTS)][dynamic]css.Value
	for &g in groups { g = make([dynamic]css.Value, a) }
	if len(items) == 1 {
		switch ident_lower(items[0]) {
		case "normal":
			for p in PARTS { append(&res, Longhand{p, idents(a, "normal")}) }
			return res[:], true
		case "none":
			append(&res, Longhand{.Font_Variant_Ligatures, idents(a, "none")})
			for p in PARTS[1:] { append(&res, Longhand{p, idents(a, "normal")}) }
			return res[:], true
		}
	}
	for it in items {
		if it.kind == .Function {
			switch css.lower_temp(it.tok.text) {
			case "stylistic", "historical-forms", "styleset", "character-variant", "swash", "ornaments", "annotation": continue
			}
			return nil, false
		}
		id := ident_lower(it)
		if id == "historical-forms" { continue }
		part := font_variant_part(id)
		k := -1
		for p, i in PARTS { if p == part { k = i } }
		if k < 0 { return nil, false }
		append(&groups[k], it)
	}
	for p, i in PARTS {
		append(&res, Longhand{p, len(groups[i]) > 0 ? groups[i][:] : idents(a, "normal")})
	}
	return res[:], true
}

// What the `font` shorthand resets besides what it sets.
FONT_RESETS := [?]Prop{
	.Font_Variant_Ligatures, .Font_Variant_Numeric, .Font_Variant_East_Asian, .Font_Variant_Position, .Font_Kerning,
	.Font_Feature_Settings, .Font_Variation_Settings,
}
