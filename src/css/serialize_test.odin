package css

import "core:strings"
import "core:testing"

@(private = "file")
OPT :: Parse_Options{max_nesting_depth = 64, max_rules = 1000}

// The selector of a sheet's first rule, as CSSOM gives it back.
@(private = "file")
selector_of :: proc(src: string) -> string {
	s := parse_stylesheet(src, OPT)
	defer { stylesheet_destroy(s); free(s) }
	if len(s.rules) == 0 { return "(none)" }
	return clone_temp(s.rules[0].selector_text)
}

@(private = "file")
clone_temp :: proc(s: string) -> string {
	out := make([]u8, len(s), context.temp_allocator)
	copy(out, s)
	return string(out)
}

@(private = "file")
media_of :: proc(src: string) -> string {
	return serialize_media_list(parse_component_values(src, OPT, context.temp_allocator), context.temp_allocator)
}

// Selectors: whitespace and combinators, keywords lower-cased, identifiers escaped, attribute values quoted, An+B
// canonical, legacy pseudo-elements with two colons, a nested rule's leading combinator.
@(test)
selectors_serialize :: proc(t: ^testing.T) {
	testing.expect_value(t, selector_of("  div>p  +  a~b  { }"), "div > p + a ~ b")
	testing.expect_value(t, selector_of("A:HOVER , .x#y{}"), "A:hover, .x#y")
	testing.expect_value(t, selector_of(":nth-child( -1n + 5 ) {}"), ":nth-child(-n+5)")
	testing.expect_value(t, selector_of(":nth-child(odd of .a ,.b) {}"), ":nth-child(2n+1 of .a, .b)")
	testing.expect_value(t, selector_of("p:not( .a ):is(b,i) {}"), "p:not(.a):is(b, i)")
	testing.expect_value(t, selector_of("[data-x=y I] [a|=\"q\\\"\"] {}"), "[data-x=\"y\" i] [a|=\"q\\\"\"]")
	testing.expect_value(t, selector_of("[\\30zonk] {}"), "[\\30 zonk]")
	testing.expect_value(t, selector_of("p:before, p::After {}"), "p::before, p::after")
	testing.expect_value(t, selector_of(":has( > img) {}"), ":has(> img)")
	testing.expect_value(t, selector_of(".a { > .b { } }"), ".a")
	// a nested selector without & has its implied "& " written, one with & anywhere is as it is
	// (one starting with a combinator always: "+ .f &"; a type selector after & is invalid)
	s := parse_stylesheet(".a { > .b { } .c, .d & { } :is(&.e) { } + .f & { } &div { } }", OPT)
	defer { stylesheet_destroy(s); free(s) }
	testing.expect(t, len(s.rules) == 1 && len(s.rules[0].nested) == 4)
	if len(s.rules) == 1 && len(s.rules[0].nested) == 4 {
		testing.expect_value(t, s.rules[0].nested[0].selector_text, "& > .b")
		testing.expect_value(t, s.rules[0].nested[1].selector_text, "& .c, .d &")
		testing.expect_value(t, s.rules[0].nested[2].selector_text, ":is(&.e)")
		testing.expect_value(t, s.rules[0].nested[3].selector_text, "& + .f &")
		testing.expect_value(t, len(s.rules[0].nested[3].selectors[0].compounds), 3)   // &, .f and & again
	}
}

// The sheet's last rule's selector, and whether it parsed.
@(private = "file")
last_selector_of :: proc(src: string) -> string {
	s := parse_stylesheet(src, OPT)
	defer { stylesheet_destroy(s); free(s) }
	if len(s.rules) == 0 || s.rules[len(s.rules) - 1].kind != .Style { return "(none)" }
	return clone_temp(s.rules[len(s.rules) - 1].selector_text)
}

// Type selectors and @namespace (CSSOM §6.7.2): `*|` kept only with a default namespace, a prefix naming the default
// namespace left out, `*` left out before the rest of its compound; an undeclared prefix, or @namespace after a style
// rule or without a URL, invalid. The default namespace selects in compounds without a type selector too.
@(test)
selectors_serialize_namespaces :: proc(t: ^testing.T) {
	NS :: "@namespace ns url(ns);"
	DEFAULT :: "@namespace url(d); @namespace nsd url(d);" + NS
	testing.expect_value(t, last_selector_of(NS + "*|e, *|*, *|*.c, *.c, |e, |*.c, ns|*.c {}"), "e, *, .c, .c, |e, |*.c, ns|*.c")
	testing.expect_value(t, last_selector_of(DEFAULT + "*|e, *|*, *|*.c, *.c, nsd|e, nsd|*.c, ns|e {}"), "*|e, *|*, *|*.c, .c, e, .c, ns|e")
	testing.expect_value(t, last_selector_of("*:not(:active), [|lang], [*|lang] {}"), ":not(:active), [lang], [*|lang]")
	testing.expect_value(t, last_selector_of("x|e {}"), "(none)")
	testing.expect_value(t, last_selector_of("p {} @namespace x url(x); x|e {}"), "p")
	testing.expect_value(t, last_selector_of("@namespace x; x|e {}"), "(none)")

	s := parse_stylesheet("@namespace url(" + NS_HTML + "); @namespace svg url(" + NS_SVG + "); .c, svg|* {}", OPT)
	defer { stylesheet_destroy(s); free(s) }
	sel := s.rules[len(s.rules) - 1].selectors
	testing.expect(t, len(sel) == 2 && sel[0].compounds[0].simples[0].kind == .Universal && sel[0].compounds[0].simples[0].ns == .HTML)
	testing.expect(t, len(sel) == 2 && sel[1].compounds[0].simples[0].ns == .SVG)
}

// Media query lists: "all and" left out, keywords and features lower-cased, "name: value", invalid queries "not all".
@(test)
media_lists_serialize :: proc(t: ^testing.T) {
	testing.expect_value(t, media_of("ALL and (Max-Width:23px)"), "(max-width: 23px)")
	testing.expect_value(t, media_of("not all and (color) , print"), "not all and (color), print")
	testing.expect_value(t, media_of("screen and"), "not all")
	testing.expect_value(t, media_of(""), "")
}

// Identifiers and strings: CSSOM's escapes.
@(test)
identifiers_serialize :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	write_ident(&sb, "-1a\x01b c")
	write_css_string(&sb, "q\"\\\x00")
	testing.expect_value(t, strings.to_string(sb), "-\\31 a\\1 b\\ c\"q\\\"\\\\�\"")
}
