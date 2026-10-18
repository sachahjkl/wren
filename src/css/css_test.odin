package css

import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:strings"
import "core:testing"

@(private = "file")
OPT :: Parse_Options{max_nesting_depth = 512, max_rules = 100_000}

@(private = "file")
Arena :: struct { a: virtual.Arena, alloc: Arena_Alloc }

@(private = "file")
arena_make :: proc() -> ^Arena {
	r := new(Arena)
	_ = virtual.arena_init_growing(&r.a)
	r.alloc = virtual.arena_allocator(&r.a)
	return r
}
@(private = "file")
arena_free :: proc(r: ^Arena) { virtual.arena_destroy(&r.a); free(r) }

@(private = "file")
dump_tokens :: proc(src: string) -> string {
	ar := arena_make()
	defer arena_free(ar)
	sb := strings.builder_make(context.temp_allocator)
	for t, i in tokenize(src, ar.alloc) {
		if i > 0 { strings.write_byte(&sb, ' ') }
		switch t.kind {
		case .Ident: fmt.sbprintf(&sb, "I(%s)", t.text)
		case .Function: fmt.sbprintf(&sb, "F(%s)", t.text)
		case .At_Keyword: fmt.sbprintf(&sb, "@(%s)", t.text)
		case .Hash: fmt.sbprintf(&sb, "#(%s%s)", t.text, t.is_id ? "" : "!")
		case .String: fmt.sbprintf(&sb, "S(%s)", t.text)
		case .Bad_String: strings.write_string(&sb, "BS")
		case .Url: fmt.sbprintf(&sb, "U(%s)", t.text)
		case .Bad_Url: strings.write_string(&sb, "BU")
		case .Delim: fmt.sbprintf(&sb, "D(%s)", t.text)
		case .Number: fmt.sbprintf(&sb, "N(%g%s)", t.num, t.is_int ? "i" : "")
		case .Percentage: fmt.sbprintf(&sb, "P(%g)", t.num)
		case .Dimension: fmt.sbprintf(&sb, "Dim(%g%s)", t.num, t.text)
		case .Whitespace: strings.write_string(&sb, "_")
		case .CDO: strings.write_string(&sb, "CDO")
		case .CDC: strings.write_string(&sb, "CDC")
		case .Colon: strings.write_string(&sb, ":")
		case .Semicolon: strings.write_string(&sb, ";")
		case .Comma: strings.write_string(&sb, ",")
		case .Open_Square: strings.write_string(&sb, "[")
		case .Close_Square: strings.write_string(&sb, "]")
		case .Open_Paren: strings.write_string(&sb, "(")
		case .Close_Paren: strings.write_string(&sb, ")")
		case .Open_Curly: strings.write_string(&sb, "{")
		case .Close_Curly: strings.write_string(&sb, "}")
		case .EOF:
		}
	}
	return strings.to_string(sb)
}

@(test)
tokenizer_basics :: proc(t: ^testing.T) {
	testing.expect_value(t, dump_tokens("a{color:red}"), "I(a) { I(color) : I(red) }")
	testing.expect_value(t, dump_tokens("12 -3.5 +.5e2 1e3px 50% #fff #1a"), "N(12i) _ N(-3.5) _ N(50) _ Dim(1000px) _ P(50) _ #(fff) _ #(1a!)")
	testing.expect_value(t, dump_tokens(`"a\"b" 'c' "unterminated`), `S(a"b) _ S(c) _ S(unterminated)`)
	testing.expect_value(t, dump_tokens("\"bad\nstring\""), "BS _ I(string) S()")   // the newline ends the bad string, the last quote opens a new (empty, unterminated) one
	testing.expect_value(t, dump_tokens("url(a.png) url( 'b.png' ) url(a b)"), "U(a.png) _ F(url) _ S(b.png) _ ) _ BU")
	testing.expect_value(t, dump_tokens("@media a-b <!-- --> /* c */ x"), "@(media) _ I(a-b) _ CDO _ CDC _ _ I(x)")
	testing.expect_value(t, dump_tokens(`\41 b \"x`), "I(Ab) _ I(\"x)")                       // escapes
	testing.expect_value(t, dump_tokens("a\r\nb\fc"), "I(a) _ I(b) _ I(c)")                     // newline normalisation
	testing.expect_value(t, dump_tokens("--x -webkit-y 2n+1"), "I(--x) _ I(-webkit-y) _ Dim(2n) N(1i)")
}

@(test)
parser_rules_and_declarations :: proc(t: ^testing.T) {
	src := `
		@charset "utf-8";
		@import url(base.css) screen and (min-width: 600px);
		a, b.c > #d { color: red; margin: 0 auto !important; --Custom: 1px  solid }
		@media (max-width: 500px) { p { display: none } }
		@font-face { font-family: X; src: url(x.woff2) }
		@keyframes spin { from { opacity: 0 } 50%, to { opacity: 1 } }
		@layer base, ui;
		@layer ui { x { y: z } }
		bad selector ?? { color: blue }
		ok { color: green }
		@supports (display: grid) { s { t: u } }
		@unknown foo;
	`
	s := parse_stylesheet(src, OPT)
	defer stylesheet_destroy(s)
	kinds := make([dynamic]Rule_Kind, context.temp_allocator)
	for r in s.rules { append(&kinds, r.kind) }
	want := []Rule_Kind{.Import, .Style, .Media, .Font_Face, .Keyframes, .Layer_Statement, .Layer_Block, .Style, .Supports}
	testing.expect_value(t, len(kinds), len(want))
	for k, i in want { if i < len(kinds) { testing.expect_value(t, kinds[i], k) } }

	testing.expect_value(t, s.rules[0].url, "base.css")
	testing.expect_value(t, len(s.rules[0].media), 1)
	style := s.rules[1]
	testing.expect_value(t, len(style.selectors), 2)
	testing.expect_value(t, len(style.declarations), 3)
	testing.expect_value(t, style.declarations[0].name, "color")
	testing.expect(t, style.declarations[1].important)
	testing.expect_value(t, style.declarations[1].name, "margin")
	testing.expect_value(t, style.declarations[2].name, "--Custom")                       // custom property names keep their case
	testing.expect_value(t, serialize_values(style.declarations[2].value, context.temp_allocator), "1px solid")
	testing.expect_value(t, len(s.rules[2].rules), 1)
	testing.expect_value(t, s.rules[4].name, "spin")
	testing.expect_value(t, len(s.rules[4].keyframes), 2)
	testing.expect_value(t, len(s.rules[4].keyframes[1].offsets), 2)
	testing.expect_value(t, len(s.rules[5].layer_names), 2)
	testing.expect_value(t, s.rules[6].layer, "ui")
}

@(test)
parser_error_recovery :: proc(t: ^testing.T) {
	// a declaration with a syntax error is dropped, its neighbours survive
	decls := parse_declarations("color: red; : bad; width; height: 3px; ; margin: 1px 2px", OPT, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for d in decls { append(&names, d.name) }
	testing.expect_value(t, strings.join(names[:], ",", context.temp_allocator), "color,height,margin")
	// unbalanced blocks
	s := parse_stylesheet("a { color: red; b { c: d } e { f: g", OPT)
	defer stylesheet_destroy(s)
	testing.expect(t, len(s.rules) >= 1)
	// an unclosed string and a stray brace do not hang or crash
	s2 := parse_stylesheet("a { content: \"x } b { color: red }", OPT)
	defer stylesheet_destroy(s2)
	s3 := parse_stylesheet("} } } a{}", OPT)
	defer stylesheet_destroy(s3)
}

@(test)
parser_survives_hostile_nesting :: proc(t: ^testing.T) {
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	strings.write_string(&sb, "a { b: ")
	for _ in 0 ..< 50_000 { strings.write_string(&sb, "(") }
	s := parse_stylesheet(strings.to_string(sb), OPT)
	defer stylesheet_destroy(s)
	testing.expect(t, len(s.errors) > 0, "the depth limit was hit and reported")
	opt := OPT
	opt.max_rules = 10
	big := strings.repeat("a{b:c}", 1000, context.temp_allocator)
	s2 := parse_stylesheet(big, opt)
	defer stylesheet_destroy(s2)
	testing.expect(t, len(s2.rules) <= 10, "the rule limit is enforced")
}

@(test)
nesting :: proc(t: ^testing.T) {
	s := parse_stylesheet(".card { color: red; & .title { font-weight: bold } .x:hover { y: z } @media (min-width: 10px) { color: blue } }", OPT)
	defer stylesheet_destroy(s)
	testing.expect_value(t, len(s.rules), 1)
	card := s.rules[0]
	testing.expect_value(t, len(card.declarations), 1)
	testing.expect_value(t, len(card.nested), 3)
	testing.expect_value(t, card.nested[2].kind, Rule_Kind.Media)
	// `& .title` has the specificity of .card + .title
	sp := card.nested[0].selectors[0].specificity
	testing.expect_value(t, sp, Specificity{0, 2, 0})
}

@(private = "file")
sel :: proc(src: string, ar: ^Arena) -> (Selector_List, bool) {
	toks := tokenize(src, ar.alloc)
	p := Parser{toks = toks, a = ar.alloc, opt = OPT, errors = new([dynamic]string, ar.alloc)}
	vs := parse_values(&p, .EOF, 0)
	return parse_selector_list(trim_values(vs), ar.alloc, nil)
}

@(test)
selectors_and_specificity :: proc(t: ^testing.T) {
	ar := arena_make()
	defer arena_free(ar)
	spec :: proc(src: string, ar: ^Arena) -> Specificity {
		l, ok := sel(src, ar)
		if !ok { return {max(u32), 0, 0} }
		return l[0].specificity
	}
	testing.expect_value(t, spec("*", ar), Specificity{0, 0, 0})
	testing.expect_value(t, spec("li", ar), Specificity{0, 0, 1})
	testing.expect_value(t, spec("ul li", ar), Specificity{0, 0, 2})
	testing.expect_value(t, spec("ul ol+li", ar), Specificity{0, 0, 3})
	testing.expect_value(t, spec("h1 + *[rel=up]", ar), Specificity{0, 1, 1})
	testing.expect_value(t, spec("ul ol li.red", ar), Specificity{0, 1, 3})
	testing.expect_value(t, spec("li.red.level", ar), Specificity{0, 2, 1})
	testing.expect_value(t, spec("#x34y", ar), Specificity{1, 0, 0})
	testing.expect_value(t, spec("#s12:not(p)", ar), Specificity{1, 0, 1})
	testing.expect_value(t, spec("a:not(#x, .y)", ar), Specificity{1, 0, 1})   // :not takes its most specific argument
	testing.expect_value(t, spec(":where(#a, .b)", ar), Specificity{0, 0, 0})
	testing.expect_value(t, spec(":is(#a, .b) p", ar), Specificity{1, 0, 1})
	testing.expect_value(t, spec("p::before", ar), Specificity{0, 0, 2})
	testing.expect_value(t, spec("li:nth-child(2n+1 of .x)", ar), Specificity{0, 2, 1})
	testing.expect_value(t, spec("a:hover:focus", ar), Specificity{0, 2, 1})

	l, ok := sel("a > b ~ c d, e", ar)
	testing.expect(t, ok)
	testing.expect_value(t, len(l), 2)
	testing.expect_value(t, len(l[0].compounds), 4)
	testing.expect_value(t, l[0].combinators[0], Combinator.Child)
	testing.expect_value(t, l[0].combinators[1], Combinator.Subsequent_Sibling)
	testing.expect_value(t, l[0].combinators[2], Combinator.Descendant)

	for bad in ([]string{"", "a >", "> a", "a > > b", "a,", ",a", "a::bogus", "a:bogus", "#1x", "a[", "a[=b]", ":nth-child(x)", "a::before b", "p:not()"}) {
		_, good := sel(bad, ar)
		testing.expect(t, !good, bad)
	}
	// forgiving lists keep the valid items
	l2, ok2 := sel(":is(a, ???, b)", ar)
	testing.expect(t, ok2)
	testing.expect_value(t, len(l2[0].compounds[0].simples[0].list^), 2)
	// attribute forms and nth parsing
	l3, _ := sel(`[a], [a=b], [a~=b], [a|=b], [a^=b], [a$=b], [a*=b i], [a="x y" s]`, ar)
	ops := [?]Attr_Op{.Exists, .Equals, .Includes, .Dash_Match, .Prefix, .Suffix, .Substring, .Equals}
	for op, i in ops { testing.expect_value(t, l3[i].compounds[0].simples[0].op, op) }
	testing.expect(t, l3[6].compounds[0].simples[0].ci)
	nths := [?]struct { src: string, a, b: int }{{":nth-child(odd)", 2, 1}, {":nth-child(even)", 2, 0}, {":nth-child(5)", 0, 5}, {":nth-child(n)", 1, 0}, {":nth-child(-n+3)", -1, 3}, {":nth-child(2n - 1)", 2, -1}, {":nth-child(+3n+2)", 3, 2}, {":nth-last-of-type(4n)", 4, 0}}
	for n in nths {
		l4, good := sel(n.src, ar)
		testing.expect(t, good, n.src)
		if good {
			s := l4[0].compounds[0].simples[0]
			testing.expect_value(t, s.nth_a, n.a)
			testing.expect_value(t, s.nth_b, n.b)
		}
	}
}

@(private = "file")
mq :: proc(src: string, env: Media_Env) -> bool {
	ar := arena_make()
	defer arena_free(ar)
	toks := tokenize(src, ar.alloc)
	p := Parser{toks = toks, a = ar.alloc, opt = OPT, errors = new([dynamic]string, ar.alloc)}
	vs := parse_values(&p, .EOF, 0)
	return media_matches(parse_media_query_list(vs, ar.alloc), env)
}

@(test)
media_queries :: proc(t: ^testing.T) {
	env := Media_Env{type = .Screen, width = 1000, height = 600, dppx = 2, prefers_dark = true, hover = true, pointer_fine = true, color_bits = 24}
	testing.expect(t, mq("", env))
	testing.expect(t, mq("screen", env))
	testing.expect(t, !mq("print", env))
	testing.expect(t, mq("not print", env))
	testing.expect(t, mq("(min-width: 800px)", env))
	testing.expect(t, !mq("(min-width: 1200px)", env))
	testing.expect(t, mq("(max-width: 1000px) and (min-height: 500px)", env))
	testing.expect(t, mq("screen and (width >= 900px) and (width < 1100px)", env))
	testing.expect(t, mq("(400px <= width <= 1000px)", env))
	testing.expect(t, !mq("(400px < width < 1000px)", env))
	testing.expect(t, mq("(orientation: landscape)", env))
	testing.expect(t, !mq("(orientation: portrait)", env))
	testing.expect(t, mq("(prefers-color-scheme: dark)", env))
	testing.expect(t, !mq("(prefers-color-scheme: light)", env))
	testing.expect(t, mq("(min-resolution: 2dppx)", env))
	testing.expect(t, mq("(min-resolution: 192dpi)", env))
	testing.expect(t, mq("(hover: hover) and (pointer: fine)", env))
	testing.expect(t, mq("(prefers-reduced-motion: no-preference)", env))
	testing.expect(t, mq("(min-aspect-ratio: 16/10)", env))
	testing.expect(t, mq("(color)", env))
	testing.expect(t, mq("(max-width: 500px), (min-width: 900px)", env))
	testing.expect(t, mq("(width: 20em) or (min-width: calc(500px + 400px))", env))
	testing.expect(t, mq("not ((min-width: 2000px) or (max-width: 100px))", env))
	testing.expect(t, !mq("(unknown-feature: 1)", env), "unknown features are false")
	testing.expect(t, !mq("not (unknown-feature: 1)", env), "...and so is their negation: unknown, not true")
	testing.expect(t, !mq("(min-width: )", env), "a malformed query is 'not all'")
	testing.expect(t, mq("(scripting: none)", env), "there is no scripting engine")
}

@(private = "file")
col :: proc(src: string, dark := false) -> (c: Color, current: bool, ok: bool) {
	ar := arena_make()
	defer arena_free(ar)
	toks := tokenize(src, ar.alloc)
	p := Parser{toks = toks, a = ar.alloc, opt = OPT, errors = new([dynamic]string, ar.alloc)}
	vs := parse_values(&p, .EOF, 0)
	env := Color_Env{dark = dark, system = proc(user: rawptr, name: string) -> (Color, bool) { return name == "canvastext" ? Color{0, 0, 0, 1} : Color{}, name == "canvastext" }}
	cv, good := parse_color(vs, &env)
	return cv.rgba, cv.kind == .Current_Color, good
}

@(private = "file")
near :: proc(a, b: Color, eps: f32 = 0.01) -> bool {
	for i in 0 ..< 4 { if math.abs(a[i] - b[i]) > eps { return false } }
	return true
}

@(test)
colors :: proc(t: ^testing.T) {
	c, _, ok := col("#f00")
	testing.expect(t, ok && near(c, {1, 0, 0, 1}))
	c, _, ok = col("#00ff0080")
	testing.expect(t, ok && near(c, {0, 1, 0, 0.5}))
	c, _, ok = col("RebeccaPurple")
	testing.expect(t, ok && near(c, {0.4, 0.2, 0.6, 1}))
	c, _, ok = col("rgb(255 128 0 / 50%)")
	testing.expect(t, ok && near(c, {1, 0.502, 0, 0.5}))
	c, _, ok = col("rgba(100%, 0%, 0%, 0.25)")
	testing.expect(t, ok && near(c, {1, 0, 0, 0.25}))
	c, _, ok = col("hsl(120deg 100% 25%)")
	testing.expect(t, ok && near(c, {0, 0.5, 0, 1}))
	c, _, ok = col("hsl(0.5turn, 100%, 50%)")
	testing.expect(t, ok && near(c, {0, 1, 1, 1}))
	c, _, ok = col("hwb(0 0% 0%)")
	testing.expect(t, ok && near(c, {1, 0, 0, 1}))
	c, _, ok = col("hwb(0 50% 50%)")
	testing.expect(t, ok && near(c, {0.5, 0.5, 0.5, 1}))
	c, _, ok = col("oklch(62.8% 0.2577 29.23)")   // the sRGB red, in OKLCH
	testing.expect(t, ok && near(c, {1, 0, 0, 1}, 0.03))
	c, _, ok = col("lab(53.24 80.09 67.2)")       // sRGB red, in Lab D50 (approximately)
	testing.expect(t, ok && near(c, {1, 0, 0, 1}, 0.05))
	c, _, ok = col("color-mix(in srgb, red, blue)")
	testing.expect(t, ok && near(c, {0.5, 0, 0.5, 1}))
	c, _, ok = col("color-mix(in srgb, red 25%, blue)")
	testing.expect(t, ok && near(c, {0.25, 0, 0.75, 1}))
	c, _, ok = col("light-dark(white, black)", false)
	testing.expect(t, ok && near(c, {1, 1, 1, 1}))
	c, _, ok = col("light-dark(white, black)", true)
	testing.expect(t, ok && near(c, {0, 0, 0, 1}))
	_, cur, ok2 := col("currentColor")
	testing.expect(t, ok2 && cur)
	c, _, ok = col("transparent")
	testing.expect(t, ok && c.a == 0)
	c, _, ok = col("CanvasText")
	testing.expect(t, ok && near(c, {0, 0, 0, 1}), "system colors come from the environment")
	for bad in ([]string{"#ff", "#gggggg", "rgb(1 2)", "notacolor", "hsl(1)", "rgb(1, 2, 3, 4, 5)", "12"}) {
		_, _, g := col(bad)
		testing.expect(t, !g, bad)
	}
}

@(private = "file")
calc_px :: proc(src: string, percent_base := 200.0) -> (f64, bool) {
	ar := arena_make()
	defer arena_free(ar)
	toks := tokenize(src, ar.alloc)
	p := Parser{toks = toks, a = ar.alloc, opt = OPT, errors = new([dynamic]string, ar.alloc)}
	vs := parse_values(&p, .EOF, 0)
	if len(vs) != 1 { return 0, false }
	n := parse_calc(vs[0], ar.alloc)
	if n == nil { return 0, false }
	return eval_calc(n, Length_Context{font_size = 16, root_font_size = 10, vw = 1000, vh = 500, percent_base = percent_base}), true
}

@(test)
calc_expressions :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, src: string, want: f64, loc := #caller_location) {
		v, ok := calc_px(src)
		testing.expect(t, ok, src, loc = loc)
		testing.expect(t, math.abs(v - want) < 1e-6, src, loc = loc)
	}
	check(t, "calc(1px + 2px)", 3)
	check(t, "calc(100% - 20px)", 180)
	check(t, "calc(2 * (1em + 4px))", 40)
	check(t, "calc(1rem + 1em)", 26)
	check(t, "calc(10vw / 2)", 50)
	check(t, "calc(50% + 10vh - 1in)", 100 + 50 - 96)
	check(t, "calc(-1 * 5px)", -5)
	check(t, "calc(3 + 4 * 2)", 11)
	check(t, "min(10px, 3em, 100%)", 10)
	check(t, "max(10px, 3em)", 48)
	check(t, "clamp(10px, 50%, 80px)", 80)
	check(t, "clamp(10px, 2%, 80px)", 10)
	check(t, "calc(1px - 3px)", -2)
	check(t, "calc(4 / 0)", 0)
	for bad in ([]string{"calc()", "calc(1px +)", "calc(red)", "calc(1px 2px)", "min()", "calc(* 2)"}) {
		_, ok := calc_px(bad)
		testing.expect(t, !ok, bad)
	}
	// deep nesting is rejected, not recursed into
	deep := strings.concatenate({"calc(", strings.repeat("(", 200, context.temp_allocator), "1px", strings.repeat(")", 200, context.temp_allocator), ")"}, context.temp_allocator)
	_, ok := calc_px(deep)
	testing.expect(t, !ok)
}

@(test)
raw_descriptor_values_and_units :: proc(t: ^testing.T) {
	s := parse_stylesheet("@media screen { @font-face { font-family: X; unicode-range: U+0E00-0E7F, U+4??; src: url(a.woff) } }", OPT)
	defer { stylesheet_destroy(s); free(s) }
	ff := s.rules[0].rules[0]
	testing.expect(t, ff.kind == .Font_Face)
	testing.expect_value(t, ff.declarations[1].raw, "U+0E00-0E7F, U+4??")
	ms, ok := time_unit_to_ms(1.5, "s")
	testing.expect(t, ok && ms == 1500)
	deg, ok2 := angle_unit_to_deg(0.25, "turn")
	testing.expect(t, ok2 && deg == 90)
}
