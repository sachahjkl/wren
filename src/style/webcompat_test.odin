package style

import "core:math"
import "core:testing"
import "wb:base"
import "wb:css"
import "wb:dom"
import "wb:html"

// What real sheets (Tailwind v4, MDN, frameworks) rely on: selector lists with pseudo-elements of other engines,
// custom properties with CSS-wide keywords, @property, CSS Color 4/5, math functions, new units, container queries.

@(private = "file")
Doc :: struct { doc: ^dom.Document, eng: ^Engine, st: ^Styled }

@(private = "file")
open_doc :: proc(src: string, configure: proc(s: ^Settings) = nil) -> Doc {
	d: Doc
	d.doc = dom.document_create(nil)
	html.parse_into(d.doc, d.doc.root, transmute([]byte)src, 2_000_000)
	s := settings_default()
	if configure != nil { configure(&s) }
	d.eng = engine_make(s)
	settings_destroy(&s)
	sync_document_sheets(d.eng, d.doc, "about:test")
	d.st = compute_styles(d.eng, d.doc, {})
	return d
}

@(private = "file")
restyle_doc :: proc(d: ^Doc) {
	styled_destroy(d.st)
	d.st = compute_styles(d.eng, d.doc, {})
}

@(private = "file")
close_doc :: proc(d: ^Doc) { styled_destroy(d.st); engine_destroy(d.eng); dom.document_destroy(d.doc) }

@(private = "file")
el :: proc(d: ^Doc, id: string) -> ^Computed { return style_of(d.st, dom.find_by_id(d.doc, id)) }

@(private = "file")
close_to :: proc(a, b: f32, eps: f32 = 0.02) -> bool { return math.abs(a - b) <= eps }

@(private = "file")
rgb_near :: proc(c: css.Color, r, g, b: f32, a: f32 = 1, eps: f32 = 2.0 / 255) -> bool {
	return math.abs(c.r - r / 255) <= eps && math.abs(c.g - g / 255) <= eps && math.abs(c.b - b / 255) <= eps && math.abs(c.a - a) <= eps
}

@(test)
selector_lists_of_other_engines :: proc(t: ^testing.T) {
	d := open_doc(`<style>
		*, ::after, ::before, ::backdrop, ::file-selector-button { margin: 0; box-sizing: border-box }
		html, :host { line-height: 1.5 }
		:root, :host { --c: rgb(0 128 0) }
		p, ::-webkit-input-placeholder, ::-webkit-scrollbar { color: var(--c) }
		.x::part(button), .y { padding-top: 7px }
		:is(.a, :-moz-focusring) { padding-left: 3px }
		:-moz-focusring, .z { padding-right: 9px }
		details:open { padding-bottom: 5px }
	</style><body><p id=p class="y a z">x</p><details id=d open></details></body>`)
	defer close_doc(&d)
	p := el(&d, "p")
	testing.expect(t, p.margin[.Top].kind == .Px && p.margin[.Top].v == 0 && p.box_sizing == .Border_Box, "a list with ::backdrop and ::file-selector-button applies")
	testing.expect(t, p.line_height.kind == .Number && p.line_height.v == 1.5, "html, :host applies to html")
	testing.expect(t, rgb_near(p.color, 0, 128, 0), "::-webkit- pseudo-elements keep the list")
	testing.expect(t, p.padding[.Top].v == 7, "::part() is valid")
	testing.expect(t, p.padding[.Left].v == 3, ":is() forgives an invalid item")
	testing.expect(t, p.padding[.Right].v == 0, "a list with :-moz-focusring is invalid, as in Blink")
	testing.expect(t, el(&d, "d").padding[.Bottom].v == 5, ":open matches details[open]")
}

@(test)
custom_properties_keywords :: proc(t: ^testing.T) {
	d := open_doc(`<style>
		#a { --off: initial; --on: ; --x: 4px; --toggle: var(--off) 1px; --w: var(--toggle, 6px) }
		#a { border-top: var(--w) solid; border-top-width: var(--w) }
		#b { --x: inherit; padding-left: var(--x) }
		#c { --x: unset; padding-left: var(--x) }
	</style><div id=a><div id=b></div><div id=c></div></div>`)
	defer close_doc(&d)
	a := el(&d, "a")
	// the space toggle: --toggle refers to a guaranteed-invalid value, so var(--toggle, 6px) takes its fallback
	testing.expect(t, a.border_width[.Top] == 6, "initial is the guaranteed-invalid value")
	testing.expect(t, el(&d, "b").padding[.Left].v == 4, "inherit")
	testing.expect(t, el(&d, "c").padding[.Left].v == 4, "unset inherits")
}

@(test)
registered_properties :: proc(t: ^testing.T) {
	d := open_doc(`<style>
		@property --size { syntax: "<length>"; inherits: false; initial-value: 10px }
		@property --tint { syntax: "<color>"; inherits: true; initial-value: red }
		@property --bad { syntax: "<length>"; inherits: false; initial-value: 2em }
		@property --any { syntax: "*"; inherits: false }
		@property --n { syntax: "<number> | auto"; inherits: false; initial-value: auto }
		#p { --size: 2em; font-size: 10px; --any: hello }
		#p, #c, #d { padding-left: var(--size); color: var(--tint); padding-right: var(--bad, 3px) }
		#d { --size: blue; }
		#e { --n: 4; padding-top: calc(var(--n) * 1px) }
	</style><div id=p><div id=c></div><div id=d></div><div id=e></div></div>`)
	defer close_doc(&d)
	p, c, dd := el(&d, "p"), el(&d, "c"), el(&d, "d")
	testing.expect(t, p.padding[.Left].v == 20 || p.padding[.Left].v == 32, "a registered <length> is computed to px")
	testing.expect(t, c.padding[.Left].v == 10, "a non-inherited registered property: the child sees the initial value")
	testing.expect(t, dd.padding[.Left].v == 10, "a value that does not match the syntax is unset (the initial value)")
	testing.expect(t, rgb_near(c.color, 255, 0, 0), "the initial value of a registered property substitutes var()")
	testing.expect(t, c.padding[.Right].v == 3, "an initial value with em is not computationally independent: the rule is invalid")
	testing.expect(t, el(&d, "e").padding[.Top].v == 4, "<number> | auto")
	_, ok := d.eng.registered["--any"]
	testing.expect(t, ok, "syntax * needs no initial value")
	_, bad := d.eng.registered["--bad"]
	testing.expect(t, !bad, "--bad is not registered")
}

@(test)
colors_level_4_and_5 :: proc(t: ^testing.T) {
	d := open_doc(`<style>
		#a { color: oklch(62.8% 0.2577 29.23) }
		#b { color: color(srgb 0 0.5 1) }
		#c { color: color(display-p3 1 0 0) }
		#d { color: lab(50% 0 0) }
		#e { color: rgb(from #ff0000 r g b / 50%) }
		#f { color: oklch(from rgb(0 0 255) l c calc(h - 120)) }
		#g { color: hsl(from green h s calc(l + 10)) }
		#h { color: rgb(0 0 255); background-color: color-mix(in oklab, currentcolor 50%, transparent) }
		#i { color: color-mix(in srgb, red, blue) }
		#j { color: color-mix(in hsl longer hue, red, blue) }
		#k { color: color-mix(in srgb, red 30%, blue 30%) }
		#l { color: rgb(10 20 30); }
		#l2 { color: color-mix(in srgb, currentcolor, white) }
	</style><p id=a></p><p id=b></p><p id=c></p><p id=d></p><p id=e></p><p id=f></p><p id=g></p><p id=h></p>
	<p id=i></p><p id=j></p><p id=k></p><div id=l><p id=l2></p></div>`)
	defer close_doc(&d)
	testing.expect(t, rgb_near(el(&d, "a").color, 255, 0, 0, 1, 3.0 / 255), "oklch red")
	testing.expect(t, rgb_near(el(&d, "b").color, 0, 127.5, 255), "color(srgb)")
	testing.expect(t, rgb_near(el(&d, "c").color, 255, 0, 0), "display-p3 red clipped to sRGB")
	testing.expect(t, rgb_near(el(&d, "d").color, 119, 119, 119, 1, 2.0 / 255), "lab(50% 0 0) is mid grey")
	testing.expect(t, rgb_near(el(&d, "e").color, 255, 0, 0, 0.5), "relative rgb with a new alpha")
	f := el(&d, "f").color
	testing.expect(t, f.g > f.r && f.g > 0.3, "relative oklch with calc() on the hue")
	g := el(&d, "g").color
	testing.expect(t, g.g > 128.0 / 255 && g.r < 0.2, "relative hsl: lighter green")
	h := el(&d, "h")
	testing.expect(t, rgb_near(h.background_color, 0, 0, 255, 0.5), "color-mix with currentcolor")
	testing.expect(t, rgb_near(el(&d, "i").color, 127.5, 0, 127.5), "color-mix in srgb")
	j := el(&d, "j").color
	testing.expect(t, j.g > 0.9, "the longer hue arc from red to blue passes through green")
	testing.expect(t, rgb_near(el(&d, "k").color, 127.5, 0, 127.5, 0.6), "percentages summing below 100% scale alpha")
	testing.expect(t, rgb_near(el(&d, "l2").color, 132.5, 137.5, 142.5), "currentcolor in `color` is the inherited color")
}

@(test)
math_functions_and_units :: proc(t: ^testing.T) {
	d := open_doc(`<style>
		html { font-size: 20px; line-height: 2 }
		#a { width: round(down, 37px, 10px); height: mod(-7px, 5px); min-width: rem(-7px, 5px) }
		#b { width: calc(pow(2, 3) * 1px); height: calc(sqrt(16) * 1px); min-height: hypot(3px, 4px) }
		#c { width: calc(sin(90deg) * 10px); height: calc(cos(0) * 10px); max-width: calc(tan(45deg) * 10px) }
		#d { width: calc(sign(-3px) * -5px); height: clamp(10px, 50vw, 20px); border-top: calc(infinity * 1px) solid }
		#e { font-size: 10px; line-height: 3; width: 2lh; height: 1rlh; min-width: 2rex }
		#f { line-height: calc(1.75 / 1.25); width: calc(2 * 3) }
		#g { z-index: calc(2.6 * 2); opacity: calc(1 / 4) }
	</style><p id=a></p><p id=b></p><p id=c></p><p id=d></p><p id=e></p><p id=f></p><p id=g></p>`)
	defer close_doc(&d)
	a := el(&d, "a")
	testing.expect(t, a.width.v == 30 && a.height.v == 3 && a.min_width.v == -2 || a.min_width.v == 0, "round / mod / rem")
	b := el(&d, "b")
	testing.expect(t, b.width.v == 8 && b.height.v == 4 && close_to(b.min_height.v, 5), "pow / sqrt / hypot")
	c := el(&d, "c")
	testing.expect(t, close_to(c.width.v, 10) && close_to(c.height.v, 10) && close_to(c.max_width.v, 10), "trigonometry")
	dd := el(&d, "d")
	testing.expect(t, dd.width.v == 5 && dd.height.v == 20, "sign / clamp")
	testing.expect(t, dd.border_width[.Top] > 1e6 && !math.is_inf(dd.border_width[.Top]), "infinity stays finite")
	e := el(&d, "e")
	testing.expect(t, e.width.v == 60 && e.height.v == 40 && e.min_width.v == 20, "lh, rlh, rex")
	f := el(&d, "f")
	testing.expect(t, f.line_height.kind == .Number && close_to(f.line_height.v, 1.4), "a number calc() is a number line-height")
	testing.expect(t, f.width.kind == .Auto, "a number calc() is not a length")
	g := el(&d, "g")
	testing.expect(t, !g.z_auto && g.z_index == 5 && close_to(g.opacity, 0.25), "number calc() for integers and numbers")
}

@(test)
container_queries :: proc(t: ^testing.T) {
	d := open_doc(`<style>
		.wrap { container-type: inline-size; container-name: card }
		.side { container: side / size }
		.t { font-size: 10cqw; padding-left: 1px }
		@container (width >= 400px) { .t { padding-left: 2px } }
		@container card (width < 300px) { .t { padding-right: 3px } }
		@container side (height > 50px) and (orientation: portrait) { .t { padding-top: 4px } }
		@container style(--mode: dark) { .t { padding-bottom: 5px } }
		.u { --mode: dark }
	</style><div class=wrap id=w><p class=t id=t></p></div><div class=side id=s><div class=u><p class=t id=t2></p></div></div>`)
	defer close_doc(&d)
	w, s := el(&d, "w"), el(&d, "s")
	testing.expect(t, w.container_type == .Inline_Size && len(w.container_name) == 1 && w.container_name[0] == "card", "container-type / container-name")
	testing.expect(t, s.container_type == .Size && s.container_name[0] == "side", "container shorthand")
	testing.expect(t, .Inline_Size in w.contain && .Size in s.contain, "query containers are size-contained")
	testing.expect(t, el(&d, "t").padding[.Left].v == 1, "no size yet: the query is unknown")
	testing.expect(t, close_to(el(&d, "t").font_size, 128), "no size yet: cq units use the viewport")
	testing.expect(t, el(&d, "t2").padding[.Bottom].v == 5, "style() query of the parent's custom property")
	testing.expect(t, engine_uses_container_queries(d.eng), "the engine knows it depends on container sizes")

	sizes := make(map[base.Handle][2]f32, context.temp_allocator)
	sizes[dom.find_by_id(d.doc, "w")] = {250, 40}
	sizes[dom.find_by_id(d.doc, "s")] = {60, 80}
	testing.expect(t, engine_set_container_sizes(d.eng, sizes), "new sizes ask for a restyle")
	testing.expect(t, d.eng.restyle_needed, "restyle_needed")
	restyle_doc(&d)
	t1 := el(&d, "t")
	testing.expect(t, t1.padding[.Left].v == 1 && t1.padding[.Right].v == 3, "card is 250px wide")
	testing.expect(t, close_to(t1.font_size, 25), "10cqw of a 250px container")
	testing.expect(t, el(&d, "t2").padding[.Top].v == 4, "named size container, height and orientation")
	testing.expect(t, !engine_set_container_sizes(d.eng, sizes), "the same sizes change nothing")
	sizes[dom.find_by_id(d.doc, "w")] = {500, 40}
	testing.expect(t, engine_set_container_sizes(d.eng, sizes), "a wider container")
	restyle_doc(&d)
	testing.expect(t, el(&d, "t").padding[.Left].v == 2 && el(&d, "t").padding[.Right].v == 0, "now 500px wide")
}

@(test)
tailwind_v4_patterns :: proc(t: ^testing.T) {
	d := open_doc(`<style>
		@layer theme, base, components, utilities;
		@layer theme { :root, :host { --spacing: 0.25rem; --text-xl: 1.25rem; --text-xl--line-height: calc(1.75 / 1.25); --color-x: oklch(98.5% 0 0) } }
		@layer base { img { height: auto; display: block } [hidden]:where(:not([hidden='until-found'])) { display: none !important } }
		@layer utilities {
			.mx-4 { margin-inline: calc(var(--spacing) * 4) }
			.h2 { font-size: var(--text-xl); line-height: var(--tw-leading, var(--text-xl--line-height)) }
			.container { width: 100%; @media (width >= 40rem) { max-width: 40rem } }
			.rounded-full { border-radius: calc(infinity * 1px) }
			.bg { background-color: color-mix(in oklab, var(--color-x) 50%, transparent) }
			.hidden { display: block }
			.bb { border-block: 2px solid; border-inline: 1px dashed; border-inline-width: 3px 4px }
		}
		img { height: 100px }
	</style><body><div id=a class="mx-4 h2 container rounded-full bg bb"></div><img id=i height=500><p id=h hidden class=hidden></p></body>`)
	defer close_doc(&d)
	a := el(&d, "a")
	testing.expect(t, a.margin[.Left].v == 16 && a.margin[.Right].v == 16, "margin-inline with calc(var() * 4)")
	testing.expect(t, a.line_height.kind == .Number && close_to(a.line_height.v, 1.4), "line-height from a nested var() fallback")
	testing.expect(t, a.max_width.kind == .Px && a.max_width.v == 640, "@media nested in a rule, range syntax with rem")
	testing.expect(t, a.radius[.Top_Left].h.v > 1e6, "rounded-full")
	testing.expect(t, a.background_color.a > 0.49 && a.background_color.a < 0.51, "color-mix with a var() color")
	testing.expectf(t, a.border_width[.Top] == 2 && a.border_width[.Bottom] == 2 && a.border_width[.Left] == 3 && a.border_width[.Right] == 4, "border-block / border-inline-width: %v %v", a.border_width, a.border_style)
	testing.expect(t, el(&d, "i").height.kind == .Px && el(&d, "i").height.v == 100, "unlayered beats layered")
	testing.expect(t, el(&d, "h").display == .None, "!important in an early layer beats later layers")
}

@(test)
supports_conditions :: proc(t: ^testing.T) {
	d := open_doc(`<style>
		@supports font-format(woff2) { #a { padding-left: 1px } }
		@supports font-tech(color-COLRv1) { #a { padding-right: 1px } }
		@supports font-tech(variations) { #a { padding-top: 1px } }
		@supports selector(:has(a)) and (color: oklch(0 0 0)) { #a { padding-bottom: 1px } }
		@supports (background-clip: text) { #a { margin-left: 1px } }
		@supports (not (-webkit-appearance: -apple-pay-button)) or (contain-intrinsic-size: 1px) { #a { margin-right: 1px } }
		@supports (container-type: inline-size) { #a { margin-top: 1px } }
		@media (color-gamut: srgb) and (not (inverted-colors: inverted)) and (-webkit-min-device-pixel-ratio: 1) { #a { margin-bottom: 1px } }
	</style><p id=a></p>`)
	defer close_doc(&d)
	a := el(&d, "a")
	testing.expect(t, a.padding[.Left].v == 1 && a.padding[.Right].v == 0 && a.padding[.Top].v == 1 && a.padding[.Bottom].v == 1, "font-format, font-tech, selector")
	testing.expect(t, a.margin[.Left].v == 0, "background-clip: text is not claimed while the painter cannot do it")
	testing.expect(t, a.margin[.Right].v == 1 && a.margin[.Top].v == 1 && a.margin[.Bottom].v == 1, "nested not / or, container-type, media features")
	d2 := open_doc(`<style>@supports (background-clip: text) { #a { margin-left: 1px } }</style><p id=a></p>`, proc(s: ^Settings) { s.background_clip_text = true })
	defer close_doc(&d2)
	testing.expect(t, el(&d2, "a").margin[.Left].v == 1, "style.background_clip_text.enabled")
}
