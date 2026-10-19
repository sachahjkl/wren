package css

import "core:math"
import "core:mem/virtual"
import "core:testing"

// Grammar added for real-world sheets: math functions and their types, colors in every space, @container and
// @property preludes, @import conditions, media features, selectors of other engines.

@(private = "file")
OPT :: Parse_Options{max_nesting_depth = 512, max_rules = 100_000}

@(private = "file")
calc_of :: proc(src: string, a: Arena_Alloc) -> ^Calc {
	vs := trim_values(parse_component_values(src, OPT, a))
	if len(vs) != 1 { return nil }
	return parse_calc(vs[0], a)
}

@(private = "file")
color_of :: proc(src: string, a: Arena_Alloc, env: ^Color_Env = nil) -> (Color, bool) {
	cv, ok := parse_color(parse_component_values(src, OPT, a), env)
	return cv.rgba, ok && cv.kind == .Rgba
}

@(private = "file")
near :: proc(a, b: f64, eps := 1e-3) -> bool { return math.abs(a - b) <= eps }

@(test)
math_functions :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	lc := Length_Context{font_size = 10, root_font_size = 16, vw = 1000, vh = 500}
	Case :: struct { src: string, want: f64, type: Calc_Type }
	cases := [?]Case{
		{"round(7.5)", 8, .Number}, {"round(up, 7.1px, 2px)", 8, .Length}, {"round(down, -7.1, 2)", -8, .Number},
		{"round(to-zero, -7.9px, 2px)", -6, .Length}, {"mod(-7, 5)", 3, .Number}, {"rem(-7, 5)", -2, .Number},
		{"sign(-3em)", -1, .Number}, {"abs(-4px)", 4, .Length}, {"pow(2, 10)", 1024, .Number}, {"sqrt(2)", math.SQRT_TWO, .Number},
		{"hypot(3px, 4px, 12px)", 13, .Length}, {"log(100, 10)", 2, .Number}, {"exp(0)", 1, .Number},
		{"sin(30deg)", 0.5, .Number}, {"cos(pi)", -1, .Number}, {"tan(0.25turn - 45deg)", 1, .Number},
		{"asin(1)", 90, .Angle}, {"atan2(1px, 1px)", 45, .Angle}, {"calc(1em + 2rem)", 42, .Length},
		{"clamp(1px, 50vw, 300px)", 300, .Length}, {"min(10px, 5%)", 5, .Length_Percent}, {"calc(e * 1)", math.E, .Number},
		{"calc(2 / 4)", 0.5, .Number}, {"calc(infinity * 1px)", CALC_INFINITY, .Length},
	}
	for c in cases {
		n := calc_of(c.src, a)
		if n == nil { testing.expectf(t, false, "%s: did not parse", c.src); continue }
		lc2 := lc
		lc2.percent_base = 100
		testing.expectf(t, near(eval_calc(n, lc2), c.want), "%s = %v, want %v", c.src, eval_calc(n, lc2), c.want)
		testing.expectf(t, calc_type(n) == c.type, "%s: type %v, want %v", c.src, calc_type(n), c.type)
	}
	for bad in ([?]string{"calc(1px + 2)", "calc(2px * 3px)", "calc(1s + 1px)", "calc(4px / 2px)", "pow(2px, 2)", "sin(1px)"}) {
		n := calc_of(bad, a)
		testing.expectf(t, n == nil || calc_type(n) == .Invalid, "%s is invalid", bad)
	}
}

@(test)
colors_in_every_space :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	Case :: struct { src: string, r, g, b, alpha: f32 }
	cases := [?]Case{
		{"oklch(0.628 0.2577 29.23)", 255, 0, 0, 1},
		{"oklab(0.52 -0.14 0.107)", 0, 128, 0, 1},
		{"lab(54.29 80.82 69.91)", 255, 0, 0, 1},
		{"lch(32.39 61.24 308.86)", 102, 51, 153, 1},
		{"color(srgb-linear 0.2140 0.2140 0.2140)", 128, 128, 128, 1},
		{"color(xyz-d65 0.4124 0.2126 0.0193)", 255, 0, 0, 1},
		{"color(xyz-d50 0.4360 0.2225 0.0139)", 255, 0, 0, 1},
		{"color(a98-rgb 0.8584 0 0)", 255, 0, 0, 1},
		{"color(prophoto-rgb 0.7022 0.2757 0.1036)", 255, 0, 0, 1},
		{"color(rec2020 0.7919 0.2310 0.0739)", 255, 0, 0, 1},
		{"hwb(120 0% 50%)", 0, 128, 0, 1},
		{"hsl(240deg 100% 50% / 25%)", 0, 0, 255, 0.25},
		{"rgb(255 0 0 / none)", 255, 0, 0, 0},
		{"color-mix(in lch, red 0%, blue)", 0, 0, 255, 1},
		{"color-mix(in oklch, white, black)", 99, 99, 99, 1},
		{"rgb(from rebeccapurple calc(r + 10) g b)", 112, 51, 153, 1},
		{"hwb(from red calc(h + 120) w b)", 0, 255, 0, 1},
		{"color(from red srgb r g b / 0.5)", 255, 0, 0, 0.5},
		{"lab(from #808080 l 0 0)", 128, 128, 128, 1},
	}
	for c in cases {
		col, ok := color_of(c.src, a)
		good := ok && math.abs(col.r * 255 - c.r) < 2.5 && math.abs(col.g * 255 - c.g) < 2.5 && math.abs(col.b * 255 - c.b) < 2.5 && math.abs(col.a - c.alpha) < 0.01
		testing.expectf(t, good, "%s = %v, want %v %v %v / %v", c.src, col * 255, c.r, c.g, c.b, c.alpha)
	}
	// currentcolor inside a function needs the element's color
	_, ok1 := color_of("color-mix(in srgb, currentcolor, red)", a)
	testing.expect(t, !ok1, "without a known currentcolor, color-mix() of it is not computable here")
	env := Color_Env{current = {0, 0, 1, 1}, has_current = true}
	col, ok2 := color_of("color-mix(in srgb, currentcolor, red)", a, &env)
	testing.expect(t, ok2 && near(f64(col.r), 0.5, 0.01) && near(f64(col.b), 0.5, 0.01), "currentcolor known")
	for bad in ([?]string{"color(lab 1 2 3)", "color-mix(in srgb, red)", "color-mix(in nowhere, red, blue)", "rgb(from red r g)", "oklch(1 2)", "color-mix(in srgb longer hue, red, blue)"}) {
		_, ok := color_of(bad, a)
		testing.expectf(t, !ok, "%s is invalid", bad)
	}
}

@(test)
preludes_of_newer_at_rules :: proc(t: ^testing.T) {
	s := parse_stylesheet(`
		@import url(a.css) layer(base.reset) supports(display: grid) screen and (min-width: 10px);
		@import "b.css" layer;
		@container card (inline-size > 30em) and style(--x: 1) { p { color: red } }
		@container (orientation: landscape) or (not (height < 100px)) { p { color: red } }
		@container { p { color: red } }
		@container card and (width > 1px) or (height > 1px) { p { color: red } }
		@property --a { syntax: "<length>"; inherits: false; initial-value: 0px }
		@property notdashed { syntax: "*"; inherits: true }
		@layer a.b, c;
	`, OPT)
	defer { stylesheet_destroy(s); free(s) }
	kinds := make([dynamic]Rule_Kind, context.temp_allocator)
	for r in s.rules { append(&kinds, r.kind) }
	testing.expectf(t, len(s.rules) == 6, "rules kept: %v", kinds[:])
	if len(s.rules) < 6 { return }
	i1 := s.rules[0]
	testing.expect(t, i1.kind == .Import && i1.layer == "base.reset" && len(i1.supports) > 0 && len(i1.media) == 1, "@import layer() supports() media")
	testing.expect(t, s.rules[1].layer == "\x00anonymous", "@import layer: an anonymous layer")
	c1 := s.rules[2]
	testing.expect(t, c1.kind == .Container && c1.container != nil && c1.container.name == "card" && c1.container.cond.kind == .And, "named container, and")
	c2 := s.rules[3]
	testing.expect(t, c2.container.name == "" && c2.container.cond.kind == .Or && c2.container.cond.kids[1].kind == .Not, "or, not")
	testing.expect(t, s.rules[4].kind == .Property && s.rules[4].name == "--a", "@property --a")
	testing.expect(t, s.rules[5].kind == .Layer_Statement && len(s.rules[5].layer_names) == 2 && s.rules[5].layer_names[0] == "a.b", "@layer a.b, c")
	sz := Container_Size{w = 500, h = 50, has_w = true, has_h = true}
	testing.expect(t, cq_eval_size(c1.container.cond.kids[0].size, sz) == .True, "inline-size > 30em (480px) at 500px")
}

@(test)
media_features_of_today :: proc(t: ^testing.T) {
	env := Media_Env{type = .Screen, width = 1280, height = 800, dppx = 2, hover = true, pointer_fine = true, color_bits = 24}
	Case :: struct { q: string, want: bool }
	cases := [?]Case{
		{"(color-gamut: srgb)", true}, {"(color-gamut: p3)", false}, {"(dynamic-range: standard)", true},
		{"(inverted-colors: none)", true}, {"(prefers-reduced-transparency: reduce)", false}, {"(forced-colors: active)", false},
		{"(-webkit-min-device-pixel-ratio: 2)", true}, {"(-webkit-max-device-pixel-ratio: 1.5)", false},
		{"(min-resolution: 2dppx)", true}, {"(400px <= width <= 1300px)", true}, {"(width >= 90rem)", false},
		{"(overflow-block: scroll)", true}, {"(grid)", false}, {"(inline-size > 0px)", false}, {"not (inline-size > 0px)", false},
		{"(prefers-reduced-motion: no-preference) and (hover: hover)", true},
	}
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	for c in cases {
		l := parse_media_query_list(parse_component_values(c.q, OPT, a), a)
		testing.expectf(t, media_matches(l, env) == c.want, "%s: want %v", c.q, c.want)
	}
}

@(test)
selectors_of_other_engines :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	valid := [?]string{
		":host", ":host(.x)", ":host-context(.dark) p", "::part(label)", "::slotted(span)", "::file-selector-button",
		"input::-webkit-inner-spin-button", "::-webkit-scrollbar-thumb:hover", ":-webkit-any(a, b)", "details:open",
		":popover-open", ":state(checked)", "::highlight(x)", "::view-transition-old(root)", ":where(:-moz-focusring, a)",
	}
	invalid := [?]string{":-moz-focusring", "::-moz-selection", "::nonsense", ":nonsense", ":host()", "::before::after"}
	for s in valid {
		_, ok := parse_selector_list(trim_values(parse_component_values(s, OPT, a)), a, nil)
		testing.expectf(t, ok, "%s is valid", s)
	}
	for s in invalid {
		_, ok := parse_selector_list(trim_values(parse_component_values(s, OPT, a)), a, nil)
		testing.expectf(t, !ok, "%s is invalid", s)
	}
}
