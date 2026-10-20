package style

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import "wb:css"
import "wb:dom"
import "wb:html"

@(private = "file")
Fx :: struct {
	doc: ^dom.Document,
	eng: ^Engine,
	st:  ^Styled,
}

@(private = "file")
load :: proc(src: string, settings: Settings = {}, state: State = {}) -> Fx {
	f: Fx
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	s := settings
	own := false
	if s.default_font_size == 0 { s = settings_default(); own = true }
	f.eng = engine_make(s)
	if own { settings_destroy(&s) }
	sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = compute_styles(f.eng, f.doc, state)
	return f
}

@(private = "file")
restyle :: proc(f: ^Fx, state: State = {}) {
	styled_destroy(f.st)
	f.st = compute_styles(f.eng, f.doc, state)
}

@(private = "file")
unload :: proc(f: ^Fx) {
	styled_destroy(f.st)
	engine_destroy(f.eng)
	dom.document_destroy(f.doc)
}

@(private = "file")
at :: proc(f: ^Fx, id: string) -> ^Computed {
	h := dom.find_by_id(f.doc, id)
	return style_of(f.st, h)
}

@(private = "file")
near :: proc(a, b: f32, eps: f32 = 0.01) -> bool { return math.abs(a - b) <= eps }

@(private = "file")
same_color :: proc(a, b: css.Color, eps: f32 = 0.01) -> bool {
	for i in 0 ..< 4 { if math.abs(a[i] - b[i]) > eps { return false } }
	return true
}

RED :: css.Color{1, 0, 0, 1}
BLUE :: css.Color{0, 0, 1, 1}
GREEN :: css.Color{0, 0.5, 0, 1}

@(test)
cascade_specificity_order_important :: proc(t: ^testing.T) {
	f := load(`<style>
		p { color: green }
		.b { color: blue }
		#x { color: red }
		#y { color: red }
		.b2 { color: blue !important }
		#y2 { color: red }
		p { color: green; color: blue }   /* later declaration in the same rule wins */
		#z.c { color: red }
		#z { color: blue }
	</style>
	<p id=a>1</p><p id=b class=b>2</p><p id=x class=b>3</p><p id=y2 class=b2>4</p><p id=z class=c>5</p>
	<p id=inl style="color: red">6</p><p id=inl2 class=b2 style="color: red">7</p><p id=inl3 style="color: red !important" class=b2>8</p>`)
	defer unload(&f)
	testing.expect(t, same_color(at(&f, "a").color, BLUE), "later declaration in the same rule")
	testing.expect(t, same_color(at(&f, "b").color, BLUE), "class beats type")
	testing.expect(t, same_color(at(&f, "x").color, RED), "id beats class")
	testing.expect(t, same_color(at(&f, "y2").color, BLUE), "!important beats id")
	testing.expect(t, same_color(at(&f, "z").color, RED), "higher specificity wins regardless of order")
	testing.expect(t, same_color(at(&f, "inl").color, RED), "inline style beats rules")
	testing.expect(t, same_color(at(&f, "inl2").color, BLUE), "!important rule beats a normal inline declaration")
	testing.expect(t, same_color(at(&f, "inl3").color, RED), "!important inline beats !important rule")
}

@(test)
cascade_layers :: proc(t: ^testing.T) {
	f := load(`<style>
		@layer base, theme;
		@layer theme { p { color: blue } }
		@layer base { p { color: red } #q { color: red } }
		.u { color: green }
		@layer base { .imp { color: red !important } }
		@layer theme { .imp { color: blue !important } }
		.imp { color: green !important }
	</style>
	<p id=a>1</p><p id=q>2</p><p id=u class=u>3</p><p id=imp class=imp>4</p>`)
	defer unload(&f)
	testing.expect(t, same_color(at(&f, "a").color, BLUE), "the later layer wins over the earlier one, specificity notwithstanding")
	testing.expect(t, same_color(at(&f, "q").color, BLUE), "layer order beats the id specificity inside a lower layer")
	testing.expect(t, same_color(at(&f, "u").color, GREEN), "unlayered beats layered")
	testing.expect(t, same_color(at(&f, "imp").color, RED), "for !important the order is reversed: the first layer wins, unlayered loses")
}

@(test)
browser_defaults :: proc(t: ^testing.T) {
	f := load(`<h1 id=h>T</h1><p id=p>x<b id=b>y</b></p><ul id=ul><li id=li>i</li></ul><a id=a href="/x">l</a><a id=na>n</a>
		<span id=s style="display:none">h</span><pre id=pre>code</pre><script id=sc></script>`)
	defer unload(&f)
	testing.expect_value(t, at(&f, "h").display, Display.Block)
	testing.expect(t, near(at(&f, "h").font_size, 32), "h1 is 2em of 16px")
	testing.expect_value(t, at(&f, "h").font_weight, u16(700))
	testing.expect(t, near(at(&f, "h").margin[.Top].v, 21.44), "0.67em")
	body := style_of(f.st, dom.find_first_by_tag(f.doc, "body"))
	testing.expect(t, near(body.margin[.Left].v, 8), "body margin")
	testing.expect_value(t, at(&f, "li").display, Display.List_Item)
	testing.expect_value(t, at(&f, "ul").list_style_type, List_Style_Type.Disc)
	testing.expect(t, near(at(&f, "ul").padding[.Left].v, 40))
	testing.expect_value(t, at(&f, "b").font_weight, u16(700))
	testing.expect(t, same_color(at(&f, "a").color, css.Color{0, 0, 0.933, 1}), "links are blue")
	testing.expect(t, .Underline in at(&f, "a").text_decoration)
	testing.expect(t, same_color(at(&f, "na").color, at(&f, "p").color), "an anchor without href is not a link")
	testing.expect_value(t, at(&f, "s").display, Display.None)
	testing.expect_value(t, at(&f, "sc").display, Display.None)
	testing.expect_value(t, at(&f, "pre").white_space, White_Space.Pre)
	testing.expect(t, near(at(&f, "pre").font_size, 13), "monospace size from preferences")
	testing.expect_value(t, at(&f, "pre").font_family[0], "monospace")
}

@(test)
inheritance_and_relative_units :: proc(t: ^testing.T) {
	f := load(`<style>
		#a { font-size: 20px; color: red; border: 1px solid; margin-left: 5px }
		#b { font-size: 2em; margin-left: 1.5em; padding-top: 2rem; width: 50%; height: calc(100% - 10px); line-height: 1.5 }
		#c { font-size: 150%; line-height: 2em }
		#d { color: inherit; border-color: inherit; margin-left: inherit }
		#e { font-size: larger }
		#f { font-size: x-large }
	</style><div id=a><div id=b><div id=c>x</div></div><div id=d>y</div><div id=e>z</div></div><div id=f></div>`)
	defer unload(&f)
	b := at(&f, "b")
	testing.expect(t, near(b.font_size, 40), "2em of the parent's 20px")
	testing.expect(t, near(b.margin[.Left].v, 60), "em uses the element's own font-size")
	testing.expect(t, near(b.padding[.Top].v, 32), "rem is the root's font-size")
	testing.expect_value(t, b.width.kind, Length_Kind.Percent)
	testing.expect_value(t, b.height.kind, Length_Kind.Calc)
	testing.expect(t, near(resolve(b.height, 200), 190))
	testing.expect_value(t, b.line_height.kind, Line_Height_Kind.Number)
	c := at(&f, "c")
	testing.expect(t, near(c.font_size, 60), "150% of 40px")
	testing.expect(t, c.line_height.kind == .Length && near(c.line_height.v, 120), "an em line-height is fixed in px where it is written, then inherited as px")
	testing.expect(t, same_color(c.color, RED), "color is inherited")
	d := at(&f, "d")
	testing.expect(t, same_color(d.border_color[.Top], RED), "inherit on a non-inherited property")
	testing.expect(t, near(d.margin[.Left].v, 5), "inherit copies the parent's computed value")
	testing.expect(t, near(at(&f, "e").font_size, 24), "larger = 1.2 x 20px")
	testing.expect(t, near(at(&f, "f").font_size, 24), "x-large = 1.5 x 16px")
	// a non-inherited property is not inherited
	testing.expect(t, near(b.border_width[.Top], 0), "borders are not inherited")
}

@(test)
shorthands :: proc(t: ^testing.T) {
	f := load(`<style>
		#a { margin: 1px 2px 3px; padding: 4px 5px; border: 2px dashed #f00; border-bottom-color: blue }
		#b { border-radius: 4px 8px / 2px 6px; gap: 3px 9px; overflow: hidden auto; inset: 0 auto }
		#c { background: url(x.png) no-repeat center / cover blue; font: italic bold 12px/1.4 "Fira Sans", serif }
		#d { flex: 2; list-style: square inside; text-decoration: underline red; outline: 1px dotted green; flex-flow: column wrap }
		#e { flex: none; margin: 0 auto; border-width: thin thick; border-style: solid dotted; border-color: red green blue }
		#f { margin: 1px 2px 3px 4px 5px; padding: -1px; border: none; }
	</style><div id=a></div><div id=b></div><div id=c></div><div id=d></div><div id=e></div><div id=f></div>`)
	defer unload(&f)
	a := at(&f, "a")
	testing.expect(t, near(a.margin[.Top].v, 1) && near(a.margin[.Right].v, 2) && near(a.margin[.Bottom].v, 3) && near(a.margin[.Left].v, 2), "3-value box shorthand")
	testing.expect(t, near(a.padding[.Left].v, 5) && near(a.padding[.Bottom].v, 4))
	testing.expect(t, near(a.border_width[.Left], 2) && a.border_style[.Right] == .Dashed)
	testing.expect(t, same_color(a.border_color[.Top], RED) && same_color(a.border_color[.Bottom], BLUE), "a later longhand overrides the shorthand")
	b := at(&f, "b")
	testing.expect(t, near(b.radius[.Top_Left].h.v, 4) && near(b.radius[.Top_Left].v.v, 2))
	testing.expect(t, near(b.radius[.Top_Right].h.v, 8) && near(b.radius[.Top_Right].v.v, 6))
	testing.expect(t, near(b.row_gap.v, 3) && near(b.column_gap.v, 9))
	testing.expect(t, b.overflow_x == .Hidden && b.overflow_y == .Auto)
	testing.expect(t, b.inset[.Top].kind == .Px && b.inset[.Left].kind == .Auto && b.inset[.Right].kind == .Auto)
	c := at(&f, "c")
	testing.expect(t, c.background_image.kind == .Url && c.background_image.url == "x.png")
	testing.expect(t, c.background_repeat[0] == .No_Repeat && c.background_size.kind == .Cover)
	testing.expect(t, same_color(c.background_color, BLUE))
	testing.expect(t, c.font_style == .Italic && c.font_weight == 700 && near(c.font_size, 12))
	testing.expect(t, c.line_height.kind == .Number && near(c.line_height.v, 1.4))
	testing.expect(t, len(c.font_family) == 2 && c.font_family[0] == "Fira Sans" && c.font_family[1] == "serif")
	d := at(&f, "d")
	testing.expect(t, near(d.flex_grow, 2) && near(d.flex_shrink, 1) && d.flex_basis.kind == .Percent, "flex: <number> = <number> 1 0%")
	testing.expect(t, d.list_style_type == .Square && d.list_style_position == .Inside)
	testing.expect(t, .Underline in d.text_decoration && same_color(d.text_decoration_color, RED))
	testing.expect(t, d.outline_style == .Dotted && near(d.outline_width, 1))
	testing.expect(t, d.flex_direction == .Column && d.flex_wrap == .Wrap)
	e := at(&f, "e")
	testing.expect(t, near(e.flex_grow, 0) && near(e.flex_shrink, 0) && e.flex_basis.kind == .Auto)
	testing.expect(t, e.margin[.Left].kind == .Auto && e.margin[.Top].kind == .Px)
	testing.expect(t, near(e.border_width[.Top], 1) && near(e.border_width[.Left], 5), "thin / thick")
	testing.expect(t, e.border_style[.Top] == .Solid && e.border_style[.Left] == .Dotted)
	testing.expect(t, same_color(e.border_color[.Right], GREEN) && same_color(e.border_color[.Bottom], BLUE))
	ff := at(&f, "f")
	testing.expect(t, near(ff.margin[.Top].v, 0), "an invalid shorthand (5 values) is dropped whole")
	testing.expect(t, near(ff.padding[.Top].v, 0), "negative padding is invalid")
	testing.expect(t, near(ff.border_width[.Top], 0), "border: none")
}

@(test)
custom_properties :: proc(t: ^testing.T) {
	f := load(`<style>
		:root { --brand: #00f; --gap: 8px; --pad: calc(var(--gap) * 2); --loop-a: var(--loop-b); --loop-b: var(--loop-a); --font: "Fira Sans", serif }
		.a { color: var(--brand); margin: var(--gap) var(--gap) 0; padding-left: var(--pad); border: var(--gap) solid var(--brand) }
		.b { color: var(--missing, red); margin-top: var(--missing, var(--gap)) }
		.c { color: var(--missing); }
		.d { color: var(--loop-a, green) }
		.e { --gap: 1px; margin-top: var(--gap) }
		.e .inner { margin-top: var(--gap); font-family: var(--font) }
		.f { --brand: red; color: var(--brand) }
		.g { margin: var(--gap) }
	</style><div id=a class=a></div><div id=b class=b></div><div id=c class=c></div><div id=d class=d></div>
	<div id=e class=e><div id=inner class=inner></div></div><div id=f class=f></div><div id=g class=g></div>`)
	defer unload(&f)
	a := at(&f, "a")
	testing.expect(t, same_color(a.color, BLUE))
	testing.expect(t, near(a.margin[.Top].v, 8) && near(a.margin[.Bottom].v, 0), "var() inside a shorthand")
	testing.expect(t, near(a.padding[.Left].v, 16), "a custom property can use another")
	testing.expect(t, near(a.border_width[.Top], 8) && same_color(a.border_color[.Top], BLUE))
	b := at(&f, "b")
	testing.expect(t, same_color(b.color, RED), "fallback")
	testing.expect(t, near(b.margin[.Top].v, 8), "fallback that is itself a var()")
	testing.expect(t, same_color(at(&f, "c").color, css.Color{0, 0, 0, 1}), "a missing variable without fallback: unset, so the inherited color")
	testing.expect(t, same_color(at(&f, "d").color, GREEN), "a cycle is invalid, so the fallback is used")
	testing.expect(t, near(at(&f, "e").margin[.Top].v, 1))
	testing.expect(t, near(at(&f, "inner").margin[.Top].v, 1), "custom properties inherit")
	testing.expect(t, at(&f, "inner").font_family[0] == "Fira Sans")
	testing.expect(t, same_color(at(&f, "f").color, RED), "an element's own definition wins over the inherited one")
	testing.expect(t, near(at(&f, "g").margin[.Left].v, 8))
}

@(test)
var_expansion_is_bounded :: proc(t: ^testing.T) {
	// each level doubles the size of the previous one: 2^40 without a limit
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "<style>:root { --v0: aaaaaaaaaaaaaaaa; ")
	for i in 1 ..= 40 { fmt.sbprintf(&sb, "--v%d: var(--v%d) var(--v%d); ", i, i - 1, i - 1) }
	strings.write_string(&sb, "} #a { font-family: var(--v40); color: green }</style><div id=a></div>")
	f := load(strings.to_string(sb))
	defer unload(&f)
	testing.expect(t, same_color(at(&f, "a").color, GREEN), "the document is still styled")
}

// A large custom property substituted by every element: the token trees of substitution are scratch memory of the
// element, not part of the pass (each element kept ~100x the text: 200 elements of an 8 KB value were ~0.6 GB).
@(test)
var_substitution_memory_is_per_element :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "<style>:root { --a: ")
	for _ in 0 ..< 2_000 { strings.write_string(&sb, "a b ") }
	strings.write_string(&sb, "; --c: green } * { color: var(--a); margin: var(--a); background-color: var(--c) }</style><body>")
	for _ in 0 ..< 200 { strings.write_string(&sb, "<div class=d></div>") }
	strings.write_string(&sb, "<p id=p></p></body>")
	f := load(strings.to_string(sb))
	defer unload(&f)
	testing.expect(t, same_color(at(&f, "p").background_color, GREEN), "the document is styled")
	testing.expectf(t, f.st.arena.total_used < 4 << 20, "%d bytes kept by the pass", f.st.arena.total_used)
}

@(test)
selector_matching :: proc(t: ^testing.T) {
	f := load(`<style>
		.hit { outline-offset: 1px }
		ul > li { margin-top: 1px }
		li + li { margin-top: 2px }
		h2 ~ p { margin-top: 3px }
		div p { padding-top: 4px }
		li:first-child { padding-top: 5px }
		li:last-child { padding-top: 6px }
		li:nth-child(2n+1) { padding-bottom: 7px }
		li:nth-child(-n+2) { padding-left: 8px }
		li:nth-last-child(1) { padding-right: 9px }
		p:not(.skip):not(#nope) { border-top-width: 1px; border-top-style: solid }
		:is(h2, h3) + p { margin-bottom: 10px }
		[data-x] { margin-left: 11px }
		[data-x=a] { margin-right: 12px }
		[data-x^=ab] { padding-top: 13px }
		[data-x$=bc] { padding-bottom: 14px }
		[data-x*=b] { padding-left: 15px }
		[data-x~=w2] { padding-right: 16px }
		[lang|=en] { margin-top: 17px }
		[data-i=AB i] { margin-bottom: 18px }
		div:has(> span.in) { margin-left: 19px }
		div:has(+ p) { margin-right: 20px }
		a:any-link { margin-top: 21px }
		input:disabled { margin-top: 22px }
		input:checked { margin-top: 23px }
		p:empty { margin-top: 24px }
		:root { margin-top: 25px }
		p:lang(fr) { margin-top: 26px }
		li:only-child { margin-top: 27px }
		span:first-of-type { margin-top: 28px }
		li:nth-child(2 of .sel) { margin-top: 29px }
	</style>
	<h2 id=h2>h</h2><p id=p1>p</p><p id=p2 class=skip></p>
	<ul><li id=l1>1</li><li id=l2 class=sel>2</li><li id=l3 class=sel>3</li><li id=l4>4</li></ul>
	<ul><li id=only>o</li></ul>
	<div id=dv><span id=sp class=in>s</span><span id=sp2>s2</span></div><div id=dv2></div><p id=after>x</p>
	<i id=i1 data-x=abc data-i=ab></i><i id=i2 data-x=a></i><i id=i3 data-x="w1 w2 w3"></i><i id=i4 lang=en-US></i><i id=i5 lang=fr-CA></i>
	<a id=lnk href=x>a</a><a id=nolnk>b</a><input id=dis disabled><input id=chk type=checkbox checked><p id=fr lang=fr>bonjour</p>`)
	defer unload(&f)
	m := proc(f: ^Fx, id: string) -> ^Computed { return at(f, id) }
	testing.expect(t, near(m(&f, "l1").margin[.Top].v, 1), "child combinator")
	testing.expect(t, near(m(&f, "l2").margin[.Top].v, 2), "adjacent sibling combinator")
	testing.expect(t, near(m(&f, "l3").margin[.Top].v, 29), ":nth-child(2 of .sel): the second .sel child")
	testing.expect(t, near(m(&f, "p1").margin[.Top].v, 3), "subsequent sibling")
	testing.expect(t, near(m(&f, "p1").margin[.Bottom].v, 10), ":is() + p")
	testing.expect(t, near(m(&f, "l1").padding[.Top].v, 5), ":first-child")
	testing.expect(t, near(m(&f, "l4").padding[.Top].v, 6), ":last-child")
	testing.expect(t, near(m(&f, "l1").padding[.Bottom].v, 7) && near(m(&f, "l3").padding[.Bottom].v, 7) && near(m(&f, "l2").padding[.Bottom].v, 0), "2n+1")
	testing.expect(t, near(m(&f, "l1").padding[.Left].v, 8) && near(m(&f, "l2").padding[.Left].v, 8) && near(m(&f, "l3").padding[.Left].v, 0), "-n+2")
	testing.expect(t, near(m(&f, "l4").padding[.Right].v, 9), ":nth-last-child(1)")
	testing.expect(t, m(&f, "p1").border_style[.Top] == .Solid && m(&f, "p2").border_style[.Top] == .None, ":not()")
	testing.expect(t, near(m(&f, "i1").margin[.Left].v, 11) && near(m(&f, "i2").margin[.Right].v, 12))
	testing.expect(t, near(m(&f, "i1").padding[.Top].v, 13) && near(m(&f, "i1").padding[.Bottom].v, 14) && near(m(&f, "i1").padding[.Left].v, 15))
	testing.expect(t, near(m(&f, "i3").padding[.Right].v, 16), "~=")
	testing.expect(t, near(m(&f, "i4").margin[.Top].v, 17) && near(m(&f, "i5").margin[.Top].v, 0), "|=")
	testing.expect(t, near(m(&f, "i1").margin[.Bottom].v, 18), "case-insensitive flag")
	testing.expect(t, near(m(&f, "dv").margin[.Left].v, 19), ":has(> child)")
	testing.expect(t, near(m(&f, "dv2").margin[.Right].v, 20), ":has(+ sibling)")
	testing.expect(t, near(m(&f, "lnk").margin[.Top].v, 21) && near(m(&f, "nolnk").margin[.Top].v, 0))
	testing.expect(t, near(m(&f, "dis").margin[.Top].v, 22) && near(m(&f, "chk").margin[.Top].v, 23))
	testing.expect(t, near(m(&f, "p2").margin[.Top].v, 24), ":empty")
	testing.expect(t, near(m(&f, "fr").margin[.Top].v, 26), ":lang(fr)")
	testing.expect(t, near(m(&f, "only").margin[.Top].v, 27) , ":only-child")
	testing.expect(t, near(m(&f, "sp").margin[.Top].v, 28), ":first-of-type")
	testing.expect(t, near(m(&f, "sp2").margin[.Top].v, 0))
	root := style_of(f.st, dom.find_first_by_tag(f.doc, "html"))
	testing.expect(t, near(root.margin[.Top].v, 25), ":root")
}

@(test)
dynamic_state :: proc(t: ^testing.T) {
	f := load(`<style>
		a:hover { color: red } div:hover { margin-top: 5px } a:focus { color: blue } input:focus-within, div:focus-within { margin-left: 6px }
		:target { margin-top: 7px } button:active { margin-top: 8px }
	</style><div id=d><a id=a href=x>l</a></div><span id=frag>t</span><button id=btn>b</button>`)
	defer unload(&f)
	a_h := dom.find_by_id(f.doc, "a")
	testing.expect(t, !same_color(at(&f, "a").color, RED))
	restyle(&f, State{hover = a_h})
	testing.expect(t, same_color(at(&f, "a").color, RED), ":hover on the element")
	testing.expect(t, near(at(&f, "d").margin[.Top].v, 5), ":hover also applies to ancestors")
	restyle(&f, State{focus = a_h})
	testing.expect(t, same_color(at(&f, "a").color, BLUE) && near(at(&f, "d").margin[.Left].v, 6), ":focus and :focus-within")
	restyle(&f, State{target_id = "frag"})
	testing.expect(t, near(at(&f, "frag").margin[.Top].v, 7), ":target")
	restyle(&f, State{active = dom.find_by_id(f.doc, "btn")})
	testing.expect(t, near(at(&f, "btn").margin[.Top].v, 8), ":active")
}

@(test)
media_and_supports :: proc(t: ^testing.T) {
	f := load(`<style>
		#a { margin-top: 1px }
		@media (min-width: 900px) { #a { margin-top: 2px } }
		@media (max-width: 899px) { #a { margin-top: 3px } }
		@supports (display: grid) { #b { margin-top: 4px } }
		@supports (frobnicate: yes) { #b { margin-top: 5px } }
		@supports not (frobnicate: yes) { #c { margin-top: 6px } }
		@supports (color: red) and (selector(a > b)) { #d { margin-top: 7px } }
		@media (prefers-color-scheme: dark) { #e { margin-top: 8px } }
		@media print { #f { margin-top: 9px } }
	</style><div id=a></div><div id=b></div><div id=c></div><div id=d></div><div id=e></div><div id=f></div>`)
	defer unload(&f)
	testing.expect(t, near(at(&f, "a").margin[.Top].v, 2), "viewport 1280 wide")
	testing.expect(t, near(at(&f, "b").margin[.Top].v, 4), "supported property")
	testing.expect(t, near(at(&f, "c").margin[.Top].v, 6), "not (unsupported)")
	testing.expect(t, near(at(&f, "d").margin[.Top].v, 7))
	testing.expect(t, near(at(&f, "e").margin[.Top].v, 0))
	testing.expect(t, near(at(&f, "f").margin[.Top].v, 0), "print rules do not apply on screen")

	env := f.eng.env
	env.width = 600
	env.prefers_dark = true
	testing.expect(t, engine_set_environment(f.eng, env))
	testing.expect(t, f.eng.dirty, "a viewport change invalidates the index when media queries are in use")
	restyle(&f)
	testing.expect(t, near(at(&f, "a").margin[.Top].v, 3))
	testing.expect(t, near(at(&f, "e").margin[.Top].v, 8))
}

@(test)
pseudo_elements_and_nesting :: proc(t: ^testing.T) {
	f := load(`<style>
		#a::before { content: "["; color: red }
		#a::after { content: attr(data-x) "!"; display: block }
		#b::before { color: red }
		#c::after { content: none }
		.card { color: green; & .title { color: blue } .x:hover { color: red } > p { margin-top: 3px } &.big { margin-top: 4px } @media (min-width: 10px) { padding-top: 5px } }
	</style><p id=a data-x=hi>t</p><p id=b>t</p><p id=c>t</p>
	<div id=card class="card big"><span id=t class=title>t</span><span id=x class=x>t</span><p id=cp>t</p></div>`)
	defer unload(&f)
	a := at(&f, "a")
	testing.expect(t, a.before != nil && a.before.content.kind == .Items && a.before.content.items[0].text == "[")
	testing.expect(t, same_color(a.before.color, RED))
	testing.expect(t, a.after != nil && len(a.after.content.items) == 1 && a.after.content.items[0].kind == .Text && a.after.content.items[0].text == "hi!" && a.after.display == .Block, "attr() is resolved into the text")
	testing.expect(t, len(a.after.content.parts) == 2 && a.after.content.parts[0].kind == .Attr, "the specified parts are kept")
	testing.expect(t, at(&f, "b").before == nil, "no content, no box")
	testing.expect(t, at(&f, "c").after == nil)
	testing.expect(t, same_color(at(&f, "t").color, BLUE), "nested rule with &")
	testing.expect(t, same_color(at(&f, "x").color, GREEN), "nested .x:hover does not apply without hover")
	testing.expect(t, near(at(&f, "cp").margin[.Top].v, 3), "nested relative selector `> p`")
	testing.expect(t, near(at(&f, "card").margin[.Top].v, 4), "&.big")
	testing.expect(t, near(at(&f, "card").padding[.Top].v, 5), "nested @media with declarations")
}

@(test)
invalid_values_are_ignored :: proc(t: ^testing.T) {
	f := load(`<style>
		#a { color: red; color: notacolor; width: 10px; width: -5px; display: bogus; margin-top: 1px; margin-top: 2 }
		#b { frobnicate: 1; font-size: 10px; font-size: banana }
		#c { color: var(--undefined); width: 7px; width: var(--undefined) }
	</style><div id=a></div><div id=b></div><div id=c></div>`)
	defer unload(&f)
	a := at(&f, "a")
	testing.expect(t, same_color(a.color, RED), "the invalid declaration is dropped, the earlier valid one stays")
	testing.expect(t, a.width.kind == .Px && near(a.width.v, 10), "negative width is invalid")
	testing.expect(t, a.display == .Block, "unknown display keyword is ignored")
	testing.expect(t, near(a.margin[.Top].v, 1), "a unitless nonzero number is not a length")
	testing.expect(t, near(at(&f, "b").font_size, 10))
	testing.expect(t, at(&f, "c").width.kind == .Auto, "invalid at computed-value time: unset, the earlier 7px does not come back")
	testing.expect(t, f.eng.ignored_properties >= 1)
}

@(test)
settings_change_behaviour :: proc(t: ^testing.T) {
	s := settings_default()
	s.author_colors = false
	s.default_font_size = 20
	s.body_margin = 0
	f := load(`<style>div { color: red; background: blue; font-size: 2em }</style><div id=a>x</div>`, s)
	settings_destroy(&s)
	defer unload(&f)
	a := at(&f, "a")
	testing.expect(t, !same_color(a.color, RED) && a.background_color.a == 0, "author colors can be switched off")
	testing.expect(t, near(a.font_size, 40), "default font size is a preference")
	testing.expect(t, near(style_of(f.st, dom.find_first_by_tag(f.doc, "body")).margin[.Top].v, 0), "body margin is a preference")

	s2 := settings_default()
	s2.ua_stylesheet = false
	g := load(`<h1 id=h>x</h1>`, s2)
	settings_destroy(&s2)
	defer unload(&g)
	testing.expect(t, at(&g, "h").display == .Inline && near(at(&g, "h").font_size, 16), "without the browser stylesheet nothing is styled")
}

@(test)
hostile_stylesheets :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "<style>")
	for i in 0 ..< 50_000 { fmt.sbprintf(&sb, ".c%d { color: red } ", i) }
	strings.write_string(&sb, "div div div div div div div div div div div div div div div div div div div div div div div div div div div div div div div div div div div div { color: blue } ")
	strings.write_string(&sb, "#a { margin-top: 3px }</style><div id=a class=c777></div>")
	s := settings_default()
	s.max_rules_total = 1000
	s.max_selector_compounds = 8
	f := load(strings.to_string(sb), s)
	settings_destroy(&s)
	defer unload(&f)
	testing.expect(t, f.eng.rule_count <= 1000, "the total rule limit is enforced")
	testing.expect(t, at(&f, "a") != nil)
}

// Values that overflow the arithmetic of matching or of computed values: the page is styled, nothing traps.
@(test)
hostile_values :: proc(t: ^testing.T) {
	f := load(`<style>
		li:nth-child(-n-9223372036854775807) { color: red }
		li:nth-last-child(-9223372036854775807n-9223372036854775807) { margin-top: 1px }
		li:nth-child(99999999999999999999n+2) { color: blue }
	</style><ul><li id=a>1</li><li id=b>2</li><li>3</li></ul>`)
	defer unload(&f)
	testing.expect(t, at(&f, "a") != nil)
	testing.expect(t, same_color(at(&f, "b").color, {0, 0, 1, 1}), "2^31 n + 2 matches the second child")
}

@(test)
partial_restyle_matches_a_full_pass :: proc(t: ^testing.T) {
	f := load(`<style>
		a:hover { color: red }
		.card:hover .title { color: blue }
		.card:hover + .next { margin-top: 5px }
		li:hover ~ li { padding-top: 3px }
		div:focus-within { border-top: 2px solid green }
		.x:not(:hover) { opacity: 0.5 }
		.box:hover > p { font-size: 30px }
		.tint:hover { color: green }
		.tint:hover::before { content: "*" }
		:target { margin-left: 9px }
		button:active { margin-top: 7px }
	</style>
	<div class=card id=c1><span class=title id=t1>t</span><p id=p1>p <b id=b1>b</b></p></div><div class=next id=n1>n</div>
	<ul id=u1><li id=l1>1</li><li id=l2>2</li><li id=l3>3</li></ul>
	<div id=d1><input id=i1><a id=a1 href=x>l</a></div>
	<div class=x id=x1>x</div>
	<div class=box id=bx1><p id=p2>p2 <i id=i2>i</i></p></div>
	<div class=tint id=ti1>tint <u id=u2>u</u></div>
	<button id=bt1>b</button><span id=frag>f</span>`)
	defer unload(&f)
	ids := []string{"c1", "t1", "p1", "b1", "n1", "u1", "l1", "l2", "l3", "d1", "i1", "a1", "x1", "bx1", "p2", "i2", "ti1", "u2", "bt1", "frag"}
	states := make([dynamic]State, context.temp_allocator)
	append(&states, State{})
	for id in ids { append(&states, State{hover = dom.find_by_id(f.doc, id)}) }
	for id in ids { append(&states, State{focus = dom.find_by_id(f.doc, id)}) }
	append(&states, State{active = dom.find_by_id(f.doc, "bt1")}, State{target_id = "frag"}, State{hover = dom.find_by_id(f.doc, "l2"), target_id = "frag"}, State{})
	reference_failures := 0
	for st in states {
		changed, ok := restyle_state(f.eng, f.doc, f.st, st)
		testing.expect(t, ok)
		_ = changed
		fresh := compute_styles(f.eng, f.doc, st)
		for id in ids {
			h := dom.find_by_id(f.doc, id)
			if !computed_equal(style_of(f.st, h), style_of(fresh, h)) { reference_failures += 1; testing.expectf(t, false, "state %v: element %s differs from a full pass", st, id) }
		}
		styled_destroy(fresh)
	}
	testing.expect_value(t, reference_failures, 0)

	// a state nobody's rules depend on costs nothing
	g := load(`<style>p { color: red }</style><p id=a>a</p>`)
	defer unload(&g)
	changed, ok := restyle_state(g.eng, g.doc, g.st, State{hover = dom.find_by_id(g.doc, "a")})
	testing.expect(t, ok && !changed)

	// a hover that only toggles a rule on one element restyles that element alone
	h := load(`<style>.k:hover { color: red }</style><p id=a class=k>a</p><p id=b>b</p>`)
	defer unload(&h)
	before_b := style_of(h.st, dom.find_by_id(h.doc, "b"))
	changed, ok = restyle_state(h.eng, h.doc, h.st, State{hover = dom.find_by_id(h.doc, "a")})
	testing.expect(t, ok && changed)
	testing.expect(t, style_of(h.st, dom.find_by_id(h.doc, "b")) == before_b, "unrelated elements keep their computed style")
}
// A state that changes the root element's font size or line height (html:hover): rem and rlh everywhere follow, which a
// partial restyle cannot scope: it refuses, the caller does a full pass.
@(test)
restyle_state_root_font :: proc(t: ^testing.T) {
	f := load(`<style>html:hover { font-size: 20px } html:focus-within { line-height: 40px } p { width: 1rem; height: 1rlh }</style><p id=p tabindex=0>x</p>`)
	defer unload(&f)
	html := dom.find_first_by_tag(f.doc, "html")
	for st in ([]State{{hover = html}, {focus = dom.find_by_id(f.doc, "p")}}) {
		if _, ok := restyle_state(f.eng, f.doc, f.st, st); ok {
			testing.expect_value(t, verify_styles(f.eng, f.doc, f.st, context.temp_allocator), "")
		} else {
			restyle(&f, st)
		}
		testing.expect(t, at(&f, "p").width.v == (st.hover != {} ? 20 : 16), "rem follows the root")
	}
}