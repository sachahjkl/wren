package page

// CSSOM "serialize a CSS rule" (CSSOM §6.4): a rule's cssText made from the rule as parsed, not from its source. The
// selectors and the conditions are css' serialization (src/css/serialize.odin), the declarations a declaration block's
// (js_dom_style.odin: longhands validated, shorthands put back together), the rules inside one a line each, indented.
// Scripts read it (CSS-in-JS libraries that copy rules, devtools-like tools, frameworks that move sheets into shadow
// trees), and the objects of a sheet's rules are made from it (native/js/odin/dom_css_rules.odin).

import "core:math"
import "core:strings"
import "wb:base"
import "wb:css"
import "wb:style"

// The indentation of the rules inside a block, a line each.
@(private = "file")
CSSOM_RULE_INDENT :: "  "

// The text of a rule.
@(private)
rule_css_text :: proc(p: ^Page, r: ^css.Rule) -> string {
	sb := strings.builder_make(context.temp_allocator)
	write_rule(p, &sb, r)
	return strings.to_string(sb)
}

@(private = "file")
write_rule :: proc(p: ^Page, sb: ^strings.Builder, r: ^css.Rule) {
	switch r.kind {
	case .Style:
		decls := rule_declarations_text(p, r.declarations)
		if r.selector_text == "" { strings.write_string(sb, decls); return }   // the declarations of a nested group (CSSNestedDeclarations)
		strings.write_string(sb, r.selector_text)
		if len(r.nested) == 0 {
			write_declarations_block(sb, decls)
			return
		}
		strings.write_string(sb, " {")
		if decls != "" { write_inner_line(sb, decls) }
		for n in r.nested { write_inner_line(sb, rule_css_text(p, n)) }
		strings.write_string(sb, "\n}")
	case .Media:
		strings.write_string(sb, "@media ")
		strings.write_string(sb, css.serialize_media_list(r.prelude, context.temp_allocator))
		write_rule_block(p, sb, r.rules)
	case .Supports:
		strings.write_string(sb, "@supports ")
		css.write_compact(sb, r.supports)
		write_rule_block(p, sb, r.rules)
	case .Container:
		strings.write_string(sb, "@container ")
		css.write_compact(sb, r.prelude)
		write_rule_block(p, sb, r.rules)
	case .Layer_Block:
		strings.write_string(sb, "@layer")
		if r.layer != "" { strings.write_byte(sb, ' '); strings.write_string(sb, r.layer) }
		write_rule_block(p, sb, r.rules)
	case .Layer_Statement:
		strings.write_string(sb, "@layer ")
		strings.write_string(sb, strings.join(r.layer_names, ", ", context.temp_allocator))
		strings.write_byte(sb, ';')
	case .Import:
		strings.write_string(sb, "@import ")
		css.write_css_url(sb, r.url)
		media := make([dynamic]css.Value, context.temp_allocator)   // the prelude past layer() and supports(): the media queries
		for v in css.trim_values(r.prelude) {
			switch {
			case v.kind == .Function && (base.ascii_equal_fold(v.tok.text, "layer") || base.ascii_equal_fold(v.tok.text, "supports")):
				strings.write_byte(sb, ' ')
				css.write_compact(sb, []css.Value{v})
			case v.kind == .Token && v.tok.kind == .Ident && base.ascii_equal_fold(v.tok.text, "layer") && len(media) == 0: strings.write_string(sb, " layer")
			case: append(&media, v)
			}
		}
		if m := css.serialize_media_list(media[:], context.temp_allocator); m != "" { strings.write_byte(sb, ' '); strings.write_string(sb, m) }
		strings.write_byte(sb, ';')
	case .Namespace:
		strings.write_string(sb, "@namespace ")
		for v in css.trim_values(r.prelude) {
			if v.kind == .Token && v.tok.kind == .Ident { css.write_ident(sb, v.tok.text); strings.write_byte(sb, ' ') }
			if v.kind == .Token && (v.tok.kind == .String || v.tok.kind == .Url) { css.write_css_url(sb, v.tok.text) }
			if v.kind == .Function && len(css.trim_values(v.children)) == 1 { css.write_css_url(sb, css.trim_values(v.children)[0].tok.text) }
		}
		strings.write_byte(sb, ';')
	case .Font_Face, .Property, .Page, .Margin:
		#partial switch r.kind {
		case .Font_Face: strings.write_string(sb, "@font-face")
		case .Property: strings.write_string(sb, "@property "); css.write_ident(sb, r.name)
		case .Margin: strings.write_byte(sb, '@'); strings.write_string(sb, r.name)
		case: strings.write_string(sb, "@page"); if len(css.trim_values(r.prelude)) > 0 { strings.write_byte(sb, ' '); css.write_compact(sb, r.prelude) }
		}
		inner := strings.builder_make(context.temp_allocator)
		strings.write_string(&inner, r.kind == .Font_Face || r.kind == .Property ? descriptors_text(r.declarations) : rule_declarations_text(p, r.declarations))
		for n in r.nested {   // a page's margin rules
			if strings.builder_len(inner) > 0 { strings.write_byte(&inner, ' ') }
			strings.write_string(&inner, rule_css_text(p, n))
		}
		write_declarations_block(sb, strings.to_string(inner))
	case .Keyframes:
		strings.write_string(sb, "@keyframes ")
		css.write_ident(sb, r.name)
		strings.write_string(sb, " {")
		for k in r.keyframes {
			line := strings.builder_make(context.temp_allocator)
			write_key_text(&line, k.offsets)
			decls := rule_declarations_text(p, k.declarations)
			write_declarations_block(&line, decls)
			write_inner_line(sb, strings.to_string(line))
		}
		strings.write_string(sb, "\n}")
	case .Position_Try: strings.write_string(sb, style.try_rule_text(p.engine, r))
	case .Unknown:
	}
}

// " {", a line for each rule inside, "}" on a line of its own (CSSOM: "@media x {\n}" when empty).
@(private = "file")
write_rule_block :: proc(p: ^Page, sb: ^strings.Builder, rules: []^css.Rule) {
	strings.write_string(sb, " {")
	for n in rules { write_inner_line(sb, rule_css_text(p, n)) }
	strings.write_string(sb, "\n}")
}

// " { declarations }", " { }" without any.
@(private = "file")
write_declarations_block :: proc(sb: ^strings.Builder, decls: string) {
	strings.write_string(sb, " {")
	if decls != "" { strings.write_byte(sb, ' '); strings.write_string(sb, decls) }
	strings.write_string(sb, " }")
}

// A new line, indented, with `text`: its own lines as they are (CSSOM §6.4: the rule's cssText after two spaces).
@(private = "file")
write_inner_line :: proc(sb: ^strings.Builder, text: string) {
	strings.write_byte(sb, '\n')
	strings.write_string(sb, CSSOM_RULE_INDENT)
	strings.write_string(sb, text)
}

// CSSOM "serialize a CSS declaration block" of a rule: validated and expanded as the cascade reads them.
@(private = "file")
rule_declarations_text :: proc(p: ^Page, decls: []css.Declaration) -> string {
	block := make([dynamic]Style_Decl, 0, len(decls), context.temp_allocator)
	for d in decls { add_declaration(p, &block, d) }
	return block_text(block[:])
}

// The descriptors of @font-face and @property: the style system reads them, not the cascade.
@(private = "file")
descriptors_text :: proc(decls: []css.Declaration) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for d, i in decls {
		if i > 0 { strings.write_byte(&sb, ' ') }
		strings.write_string(&sb, d.name)
		strings.write_string(&sb, ": ")
		strings.write_string(&sb, d.raw != "" ? d.raw : css_text_of(d.value))
		strings.write_byte(&sb, ';')
	}
	return strings.to_string(sb)
}

// CSSKeyframeRule.keyText: percentages, from and to included ("0%", "100%"), to the decimals an f32 offset holds
// (30%, not the 30.000002% of 0.3 times 100).
@(private)
write_key_text :: proc(sb: ^strings.Builder, offsets: []f32) {
	PERCENT :: 100
	KEY_TEXT_SCALE :: 1e4
	for o, i in offsets {
		if i > 0 { strings.write_string(sb, ", ") }
		strings.write_string(sb, css_num(f32(math.round(f64(o) * PERCENT * KEY_TEXT_SCALE) / KEY_TEXT_SCALE)))
		strings.write_byte(sb, '%')
	}
}
