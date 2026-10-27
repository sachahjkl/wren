package layout

import "base:runtime"
import "wb:style"

// What a computed style asks of a font beyond family / weight / slant / size: OpenType features (CSS Fonts 4 §6:
// font-variant-*, font-kerning, then font-feature-settings, which wins) and variations (font-variation-settings).

// Identity of the feature-related values of a style, for the font cache of a pass (the lists are shared by inheritance).
// (A list is never shared by two different values: its address tells it apart. `content_language` is inherited by copy,
// so its data pointer is shared across a subtree and tells one language from another.)
@(private)
Font_Sig :: struct {
	feat:  rawptr,
	vars:  rawptr,
	lang:  rawptr,
	enums: u64,     // ligatures, east-asian, caps, numeric, position, kerning, optical-sizing, text-rendering
}

@(private)
font_sig :: #force_inline proc(cs: ^style.Computed) -> Font_Sig {
	e := u64(transmute(u16)cs.font_variant_ligatures) | u64(transmute(u16)cs.font_variant_east_asian) << 16 |
		u64(cs.font_variant_caps) << 32 | u64(transmute(u8)cs.font_variant_numeric) << 40 | u64(cs.font_variant_position) << 48 |
		u64(cs.font_kerning) << 56 | u64(cs.font_optical_sizing) << 59 | u64(cs.text_rendering) << 60
	return Font_Sig{feat = raw_data(cs.font_feature_settings), vars = raw_data(cs.font_variation_settings),
		lang = raw_data(cs.content_language), enums = e}
}

// The OpenType features and variation axes of a style, in `a`. `size` is the used font size (device px), for the
// `opsz` axis of font-optical-sizing: auto.
font_features :: proc(cs: ^style.Computed, size: f32, a: runtime.Allocator) -> (feats: []Font_Feature, vars: []Font_Variation) {
	out := make([dynamic]Font_Feature, 0, 8, context.temp_allocator)
	add :: proc(out: ^[dynamic]Font_Feature, tag: string, v: u32 = 1) {
		append(out, Font_Feature{{tag[0], tag[1], tag[2], tag[3]}, v})
	}
	// text-rendering: optimizeSpeed asks for speed over quality: a browser turns kerning and optional ligatures off,
	// unless font-kerning / font-variant-ligatures ask for them back below (both lists go to the shaper in order)
	fast := cs.text_rendering == .Optimize_Speed
	if fast { add(&out, "kern", 0); for t in ([]string{"liga", "clig", "calt"}) { add(&out, t, 0) } }
	switch cs.font_kerning {
	case .Auto:   // kept on (or off above under optimizeSpeed); DirectWrite / HarfRust kern by default
	case .Normal: add(&out, "kern")       // wins over the optimizeSpeed `kern` off above (later setting wins)
	case .None: add(&out, "kern", 0)
	}
	lig := cs.font_variant_ligatures
	if .None in lig {
		for t in ([]string{"liga", "clig", "dlig", "hlig", "calt"}) { add(&out, t, 0) }
	}
	if .Common in lig { add(&out, "liga"); add(&out, "clig") }
	if .No_Common in lig { add(&out, "liga", 0); add(&out, "clig", 0) }
	if .Discretionary in lig { add(&out, "dlig") }
	if .No_Discretionary in lig { add(&out, "dlig", 0) }
	if .Historical in lig { add(&out, "hlig") }
	if .No_Historical in lig { add(&out, "hlig", 0) }
	if .Contextual in lig { add(&out, "calt") }
	if .No_Contextual in lig { add(&out, "calt", 0) }
	switch cs.font_variant_caps {
	case .Normal:
	case .Small_Caps: add(&out, "smcp")
	case .All_Small_Caps: add(&out, "c2sc"); add(&out, "smcp")
	case .Petite_Caps: add(&out, "pcap")
	case .All_Petite_Caps: add(&out, "c2pc"); add(&out, "pcap")
	case .Unicase: add(&out, "unic")
	case .Titling_Caps: add(&out, "titl")
	}
	NUM := [style.Numeric_Value]string{
		.Lining = "lnum", .Oldstyle = "onum", .Proportional = "pnum", .Tabular = "tnum",
		.Diagonal_Fractions = "frac", .Stacked_Fractions = "afrc", .Ordinal = "ordn", .Slashed_Zero = "zero",
	}
	for v in style.Numeric_Value { if v in cs.font_variant_numeric { add(&out, NUM[v]) } }
	EA := [style.East_Asian_Value]string{
		.Jis78 = "jp78", .Jis83 = "jp83", .Jis90 = "jp90", .Jis04 = "jp04", .Simplified = "smpl", .Traditional = "trad",
		.Full_Width = "fwid", .Proportional_Width = "pwid", .Ruby = "ruby",
	}
	for v in style.East_Asian_Value { if v in cs.font_variant_east_asian { add(&out, EA[v]) } }
	switch cs.font_variant_position {
	case .Normal:
	case .Sub: add(&out, "subs")
	case .Super: add(&out, "sups")
	}
	for f in cs.font_feature_settings { append(&out, Font_Feature{f.tag, f.value}) }
	if len(out) > 0 {
		feats = make([]Font_Feature, len(out), a)
		copy(feats, out[:])
	}
	// variations: font-variation-settings, plus the `opsz` axis set to the font size for font-optical-sizing: auto
	// (CSS Fonts 4 §11.5), unless the author already set `opsz` by hand (which wins)
	opsz := cs.font_optical_sizing == .Auto && size > 0
	if opsz {
		for v in cs.font_variation_settings { if v.tag == {'o', 'p', 's', 'z'} { opsz = false; break } }
	}
	nv := len(cs.font_variation_settings) + (opsz ? 1 : 0)
	if nv > 0 {
		vars = make([]Font_Variation, nv, a)
		for v, i in cs.font_variation_settings { vars[i] = {v.tag, v.value} }
		if opsz { vars[nv - 1] = {{'o', 'p', 's', 'z'}, size} }
	}
	return
}
