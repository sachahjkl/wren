package style

import "core:testing"
import "wb:dom"
import "wb:html"

// HTML's presentational hints (hints.odin): the attribute microsyntaxes, the mapping of each attribute, and their place
// in the cascade (above the browser's styles, below every author rule and layer); quirks mode.

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
close_doc :: proc(d: ^Doc) { styled_destroy(d.st); engine_destroy(d.eng); dom.document_destroy(d.doc) }

@(private = "file")
el :: proc(d: ^Doc, id: string) -> ^Computed { return style_of(d.st, dom.find_by_id(d.doc, id)) }

@(private = "file")
rgb_is :: proc(c: [4]f32, rgb: u32) -> bool {
	near :: proc(a: f32, b: u32) -> bool { return abs(a - f32(b) / 255) < 0.005 }
	return near(c[0], rgb >> 16 & 255) && near(c[1], rgb >> 8 & 255) && near(c[2], rgb & 255)
}

@(test)
hint_microsyntaxes :: proc(t: ^testing.T) {
	Color_Case :: struct { in_: string, rgb: u32, ok: bool }
	for c in ([?]Color_Case{
		{"red", 0xff0000, true}, {"#0f0", 0x00ff00, true}, {"  #ABCDEF ", 0xabcdef, true}, {"ffffff", 0xffffff, true},
		{"chucknorris", 0xc00000, true}, {"crap", 0xc0a000, true}, {"abc", 0x0a0b0c, true}, {"#12345", 0x123450, true},
		{"transparent", 0, false}, {"", 0, false}, {"#1234567890abcdef", 0x1278cd, true}, {"#0000000a0000000b0000000c", 0x0a0b0c, true},
	}) {
		rgb, ok := parse_legacy_color(c.in_)
		testing.expectf(t, ok == c.ok && (!ok || rgb == c.rgb), "legacy color %q: got %06x %v", c.in_, rgb, ok)
	}
	v, pct, ok := parse_dimension(" 25%")
	testing.expect(t, ok && pct && v == 25, "25%")
	v, pct, ok = parse_dimension("12.5px")
	testing.expect(t, ok && !pct && v == 12.5, "12.5 (units are ignored)")
	v, pct, ok = parse_dimension("100.")
	testing.expect(t, ok && !pct && v == 100, "100.")
	_, _, ok = parse_dimension("auto")
	testing.expect(t, !ok, "auto is no dimension")
	n, nok := parse_nonneg_int(" +3x")
	testing.expect(t, nok && n == 3, "non-negative integer")
	_, nok = parse_nonneg_int("-1")
	testing.expect(t, !nok, "negative")
	Size_Case :: struct { in_, kw: string }
	for c in ([?]Size_Case{{"+1", "large"}, {"-2", "x-small"}, {"7", "xxx-large"}, {"9", "xxx-large"}, {"0", "x-small"}, {"3", "medium"}, {"-9", "x-small"}}) {
		kw, kok := legacy_font_size(c.in_)
		testing.expectf(t, kok && kw == c.kw, "font size %q: %q", c.in_, kw)
	}
	_, sok := legacy_font_size("big")
	testing.expect(t, !sok, "font size without digits")
}

@(test)
hints_yield_to_author_styles :: proc(t: ^testing.T) {
	d := open_doc(`<!doctype html><style>
		img.r { max-width: 100%; height: auto }
		td.w { width: 10px }
		@layer base { td.l { background-color: rgb(0, 0, 255) } }
	</style><body>
	<img id=i class=r width=400 height=300 src=x.png>
	<img id=j width="50%" height=20>
	<table><tr><td id=c1 class=w width=25% bgcolor=red>a</td><td id=c2 width=25% bgcolor="#00ff00" class=l>b</td><td id=c3 width=0 height=0>c</td></tr></table>
	</body>`)
	defer close_doc(&d)
	i := el(&d, "i")
	testing.expect(t, i.width.kind == .Px && i.width.v == 400, "img width attribute: CSS width")
	testing.expect(t, i.height.kind == .Auto, "the page's height: auto beats the height attribute")
	testing.expect(t, i.aspect_ratio_auto && abs(i.aspect_ratio - 4.0 / 3) < 1e-4, "aspect-ratio: auto 400 / 300")
	testing.expect(t, i.max_width.kind == .Percent, "max-width from the page")
	j := el(&d, "j")
	testing.expect(t, j.width.kind == .Percent && j.width.v == 50 && j.height.v == 20, "percent width")
	testing.expect(t, j.aspect_ratio == 0, "no ratio from a percentage")
	c1 := el(&d, "c1")
	testing.expect(t, c1.width.kind == .Px && c1.width.v == 10, "an author rule beats the width attribute")
	testing.expect(t, rgb_is(c1.background_color, 0xff0000), "bgcolor=red")
	c2 := el(&d, "c2")
	testing.expect(t, c2.width.kind == .Percent && c2.width.v == 25, "width=25%")
	testing.expect(t, rgb_is(c2.background_color, 0x0000ff), "a rule in a cascade layer beats bgcolor")
	c3 := el(&d, "c3")
	testing.expect(t, c3.width.kind == .Auto && c3.height.kind == .Auto, "zero cell width / height are ignored")
}

// th is centered only under a parent whose text-align is the initial value (HTML §15.3.8; Tailwind's text-left tables).
@(test)
th_text_align_follows_parent :: proc(t: ^testing.T) {
	d := open_doc(`<!doctype html><body>
	<table><tr><th id=a>x</th></tr></table>
	<table style="text-align:left"><tr><th id=b>x</th></tr></table>
	<table><tr style="text-align:right"><th id=c>x</th><th id=e style="text-align:start">x</th></tr></table>
	<div style="text-align:-webkit-center"><table><tr><th id=f>x</th></tr></table></div>
	</body>`)
	defer close_doc(&d)
	testing.expect_value(t, el(&d, "a").text_align, Text_Align.Center)
	testing.expect_value(t, el(&d, "b").text_align, Text_Align.Left)
	testing.expect_value(t, el(&d, "c").text_align, Text_Align.Right)
	testing.expect_value(t, el(&d, "e").text_align, Text_Align.Start)
	testing.expect_value(t, el(&d, "f").text_align, Text_Align.Legacy_Center)
}

// <svg width height>: presentation attributes of the CSS properties, in CSS syntax (an Angular icon component writes
// width="1rem"); the page's rules still win; what is not a CSS value (or could break out of it) is dropped.
@(test)
svg_size_presentation_attributes :: proc(t: ^testing.T) {
	d := open_doc(`<!doctype html><style>html { font-size: 20px } svg.s { width: 3px }</style><body style="font-size:10px">
	<svg id=a width="1rem" height="2em" viewBox="0 0 24 24"></svg>
	<svg id=b width="24" height="50%"></svg>
	<svg id=c class=s width="1rem" height="calc(1px + 2px)"></svg>
	<svg id=e width="1rem;color:red" height="bogus"></svg>
	</body>`)
	defer close_doc(&d)
	a := el(&d, "a")
	testing.expectf(t, a.width.kind == .Px && abs(a.width.v - 20) < 0.01 && abs(a.height.v - 20) < 0.01, "1rem / 2em: %v %v", a.width, a.height)
	b := el(&d, "b")
	testing.expect(t, b.width.kind == .Px && b.width.v == 24 && b.height.kind == .Percent && b.height.v == 50, "a bare number is px, a percentage stays")
	c := el(&d, "c")
	testing.expect(t, c.width.kind == .Px && c.width.v == 3, "an author rule beats the attribute")
	testing.expectf(t, abs(c.height.v - 3) < 0.01, "calc(): %v", c.height)
	e := el(&d, "e")
	testing.expect(t, e.width.kind == .Auto && e.height.kind == .Auto, "not a CSS value: no hint")
	testing.expect(t, !rgb_is(e.color, 0xff0000), "and nothing smuggled after it")
}

@(test)
hints_map_html_attributes :: proc(t: ^testing.T) {
	d := open_doc(`<!doctype html><body id=b bgcolor=white text=navy link=#00f>
	<center id=ce><div id=dc align=center>x</div><div id=dr align=RIGHT>y</div><p id=p align=justify>z</p></center>
	<table id=t cellpadding=0 cellspacing=4 border=2 align=center width=80%>
	  <tbody id=tb valign=top><tr id=tr align=left height=30><td id=td nowrap>a</td><th id=th valign=bottom>b</th></tr></tbody>
	</table>
	<table id=t0 border=0><tr><td id=td0>c</td></tr></table>
	<table id=tf frame=hsides rules=cols><tr><td id=tdr>d</td></tr></table>
	<font id=f size=+2 color=green face="Fira Code, monospace">f</font>
	<br id=br clear=all>
	<img id=im align=left hspace=5 vspace=6 border=1 width=10 height=10>
	<img id=im2 align=absmiddle>
	<hr id=hr size=1 noshade align=left width=50%>
	<hr id=hr2 size=5 color=red>
	<ol id=ol type=A><li id=li type=i>x</li></ol><ul id=ul type=square></ul>
	<a id=a href=x>link</a>
	<iframe id=fr frameborder=0></iframe>
	<pre id=pre wrap>p</pre>
	</body>`)
	defer close_doc(&d)
	b := el(&d, "b")
	testing.expect(t, rgb_is(b.color, 0x000080), "body text")
	testing.expect(t, rgb_is(el(&d, "a").color, 0x0000ff), "body link reaches links")
	testing.expect_value(t, el(&d, "ce").text_align, Text_Align.Legacy_Center)
	testing.expect_value(t, el(&d, "dc").text_align, Text_Align.Legacy_Center)
	testing.expect_value(t, el(&d, "dr").text_align, Text_Align.Legacy_Right)
	testing.expect_value(t, el(&d, "p").text_align, Text_Align.Justify)
	tt := el(&d, "t")
	testing.expect(t, tt.border_spacing == {4, 4}, "cellspacing")
	testing.expect(t, tt.margin[.Left].kind == .Auto && tt.margin[.Right].kind == .Auto, "table align=center")
	testing.expect(t, tt.width.kind == .Percent && tt.width.v == 80, "table width")
	testing.expect(t, tt.border_width[.Top] == 2 && tt.border_style[.Top] == .Outset, "table border=2: outset")
	testing.expect_value(t, el(&d, "tb").vertical_align.kind, Vertical_Align_Kind.Top)
	tr := el(&d, "tr")
	testing.expect(t, tr.text_align == .Legacy_Left && tr.height.v == 30, "tr align, height")
	td := el(&d, "td")
	testing.expect(t, td.padding[.Left].kind == .Px && td.padding[.Left].v == 0, "cellpadding=0")
	testing.expect(t, td.white_space == .Nowrap, "nowrap")
	testing.expect(t, td.vertical_align.kind == .Top, "valign inherited from the row group")
	testing.expect(t, td.border_width[.Top] == 1 && td.border_style[.Top] == .Inset, "cells of a bordered table: 1px inset")
	testing.expect(t, rgb_is(td.border_color[.Top], 0x808080), "... gray, from the table")
	testing.expect_value(t, el(&d, "th").vertical_align.kind, Vertical_Align_Kind.Bottom)
	testing.expect(t, el(&d, "t0").border_width[.Top] == 0 && el(&d, "td0").border_width[.Top] == 0, "border=0: none")
	tf := el(&d, "tf")
	testing.expect(t, tf.border_style[.Top] == .Solid && tf.border_style[.Left] == .Hidden && tf.border_collapse, "frame=hsides rules=cols")
	tdr := el(&d, "tdr")
	testing.expect(t, tdr.border_style[.Left] == .Solid && tdr.border_style[.Top] == .None, "rules=cols on cells")
	f := el(&d, "f")
	testing.expect(t, rgb_is(f.color, 0x008000), "font color")
	testing.expect(t, f.font_size == 24, "font size=+2 (x-large)")
	testing.expect(t, len(f.font_family) == 2 && f.font_family[0] == "Fira Code" && f.font_family[1] == "monospace", "font face")
	testing.expect_value(t, el(&d, "br").clear, Clear.Both)
	im := el(&d, "im")
	testing.expect(t, im.float == .Left && im.margin[.Left].v == 5 && im.margin[.Top].v == 6, "img align=left hspace vspace")
	testing.expect(t, im.border_width[.Top] == 1 && im.border_style[.Top] == .Solid, "img border")
	testing.expect_value(t, el(&d, "im2").vertical_align.kind, Vertical_Align_Kind.Middle)
	hr := el(&d, "hr")
	testing.expect(t, hr.border_style[.Top] == .Solid && hr.border_width[.Bottom] == 0, "hr noshade size=1")
	testing.expect(t, hr.margin[.Left].v == 0 && hr.margin[.Right].kind == .Auto && hr.width.kind == .Percent, "hr align, width")
	hr2 := el(&d, "hr2")
	testing.expect(t, hr2.height.v == 3 && rgb_is(hr2.background_color, 0xff0000), "hr size=5 color=red")
	testing.expect_value(t, el(&d, "ol").list_style_type, List_Style_Type.Upper_Alpha)
	testing.expect_value(t, el(&d, "li").list_style_type, List_Style_Type.Lower_Roman)
	testing.expect_value(t, el(&d, "ul").list_style_type, List_Style_Type.Square)
	testing.expect(t, el(&d, "fr").border_width[.Top] == 0, "iframe frameborder=0")
	testing.expect_value(t, el(&d, "pre").white_space, White_Space.Pre_Wrap)

	// off: the attributes do nothing
	d2 := open_doc(`<!doctype html><table id=t cellspacing=9><tr><td id=c bgcolor=red>x</td></tr></table>`, proc(s: ^Settings) { s.presentational_hints = false })
	defer close_doc(&d2)
	testing.expect(t, el(&d2, "t").border_spacing == {2, 2} && el(&d2, "c").background_color[3] == 0, "style.presentational_hints.enabled off")
}

@(test)
quirks_mode_rules :: proc(t: ^testing.T) {
	SRC :: `<body style="font-size: 10px; white-space: nowrap"><table id=t><tr><td id=c>x</td></tr></table><form id=f><input id=i><button id=bt>b</button></form></body>`
	q := open_doc(SRC)
	defer close_doc(&q)
	testing.expect_value(t, q.doc.mode, dom.Document_Mode.Quirks)
	testing.expect(t, el(&q, "t").font_size == 16 && el(&q, "c").font_size == 16, "quirks: tables do not inherit the font size")
	testing.expect(t, el(&q, "c").white_space == .Normal, "quirks: nor white-space")
	testing.expect(t, el(&q, "f").margin[.Bottom].v > 0, "quirks: forms have a bottom margin")
	s := open_doc(`<!DOCTYPE html>` + SRC)
	defer close_doc(&s)
	testing.expect_value(t, s.doc.mode, dom.Document_Mode.No_Quirks)
	testing.expect(t, el(&s, "t").font_size == 10, "standards mode: tables inherit")
	testing.expect(t, el(&s, "i").box_sizing == .Content_Box && el(&s, "bt").box_sizing == .Border_Box, "standards: text fields content-box, buttons border-box")
	testing.expect(t, el(&q, "i").box_sizing == .Border_Box, "quirks: text fields border-box")
	l := open_doc(`<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">` + SRC)
	defer close_doc(&l)
	testing.expect_value(t, l.doc.mode, dom.Document_Mode.Limited_Quirks)
	testing.expect(t, el(&l, "t").font_size == 10, "limited quirks: tables inherit")
	o := open_doc(SRC, proc(st: ^Settings) { st.quirks_rules = false })
	defer close_doc(&o)
	testing.expect(t, el(&o, "t").font_size == 10, "style.quirks_mode.enabled off")
}
