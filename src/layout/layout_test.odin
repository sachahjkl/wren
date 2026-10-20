package layout

import "core:math"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:html"
import "wb:style"

// Layout tests without a window: every character is 0.5 em wide, ascent 0.8 em, descent 0.2 em, x-height 0.5 em, so
// expected positions can be computed by hand.

@(private = "file")
Fx :: struct {
	doc: ^dom.Document,
	eng: ^style.Engine,
	st:  ^style.Styled,
	set: Settings,
	l:   Layout,
	vp:  Vec2,
}

@(private = "file")
fake_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> Font { return Font(1) }
@(private = "file")
fake_width :: proc(user: rawptr, f: Font, size: f32, text: string) -> f32 { return 0.5 * size * f32(rune_count(text)) }
@(private = "file")
fake_metrics :: proc(user: rawptr, f: Font, size: f32) -> Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} }

@(private = "file")
fake_api :: Text_Api{font = fake_font, width = fake_width, metrics = fake_metrics}

@(private = "file")
load :: proc(src: string, vw: f32 = 800, vh: f32 = 600) -> ^Fx {
	f := new(Fx)
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	ss := style.settings_default()
	f.eng = style.engine_make(ss)
	style.settings_destroy(&ss)
	style.sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = style.compute_styles(f.eng, f.doc, {})
	f.set = settings_default()
	f.vp = {vw, vh}
	relayout(f)
	return f
}

@(private = "file")
relayout :: proc(f: ^Fx) {
	run(&f.l, Input{doc = f.doc, styled = f.st, settings = &f.set, text = fake_api, viewport = f.vp, scale = 1, band_h = 256})
}

@(private = "file")
unload :: proc(f: ^Fx) {
	destroy(&f.l)
	style.styled_destroy(f.st)
	style.engine_destroy(f.eng)
	dom.document_destroy(f.doc)
	free(f)
}

@(private = "file")
node :: proc(f: ^Fx, id: string) -> base.Handle { return dom.find_by_id(f.doc, id) }

@(private = "file")
rect :: proc(f: ^Fx, id: string, scroll: f32 = 0) -> Rect {
	r, ok := box_of(&f.l, node(f, id), f.vp, scroll)
	if !ok { return Rect{{-1, -1}, {-1, -1}} }
	return r.border
}

@(private = "file")
near :: proc(a, b: f32, eps: f32 = 0.01) -> bool { return math.abs(a - b) <= eps }

@(private = "file")
expect_rect :: proc(t: ^testing.T, f: ^Fx, id: string, x0, y0, x1, y1: f32, loc := #caller_location) {
	r := rect(f, id)
	ok := near(r.min.x, x0) && near(r.min.y, y0) && near(r.max.x, x1) && near(r.max.y, y1)
	testing.expectf(t, ok, "%s: got (%v, %v)-(%v, %v), want (%v, %v)-(%v, %v)", id, r.min.x, r.min.y, r.max.x, r.max.y, x0, y0, x1, y1, loc = loc)
}

@(private = "file")
ifc_lines :: proc(f: ^Fx, id: string) -> []Line {
	bi := box_index(&f.l, node(f, id))
	if bi == NONE { return nil }
	b := &f.l.boxes[bi]
	return f.l.lines[b.lines[0]:b.lines[1]]
}

@(private = "file")
first_text :: proc(f: ^Fx, ln: Line) -> ^Frag {
	for i in ln.frags[0] ..< ln.frags[1] { if f.l.frags[i].kind == .Text { return &f.l.frags[i] } }
	return nil
}

@(test)
margin_collapsing :: proc(t: ^testing.T) {
	f := load(`<body style="margin:0">
<div id=a style="margin:20px 0 30px;height:10px"></div><div id=b style="margin-top:20px;height:10px"></div>
<div id=p style="margin-top:10px"><div id=q style="margin-top:25px;height:5px"></div></div>
<div id=e style="margin:40px 0"></div><div id=g2 style="margin-top:15px;height:1px"></div>
<div id=g style="padding-top:1px"><div id=h style="margin-top:12px;height:1px"></div></div>
<div id=i style="overflow:hidden"><div id=j style="margin-top:7px;height:1px"></div></div>
<div id=k style="margin-top:-5px;height:4px"></div>
</body>`)
	defer unload(f)
	expect_rect(t, f, "a", 0, 20, 800, 30)
	expect_rect(t, f, "b", 0, 60, 800, 70)         // max(30, 20)
	expect_rect(t, f, "p", 0, 95, 800, 100)        // parent and child margins collapse: max(10, 25)
	expect_rect(t, f, "q", 0, 95, 800, 100)
	expect_rect(t, f, "g2", 0, 140, 800, 141)      // an empty box lets its margins through: max(40, 40, 15)
	expect_rect(t, f, "g", 0, 141, 800, 155)       // padding stops the collapse
	expect_rect(t, f, "h", 0, 154, 800, 155)
	expect_rect(t, f, "i", 0, 155, 800, 163)       // a block formatting context root keeps its child's margin inside
	expect_rect(t, f, "j", 0, 162, 800, 163)
	expect_rect(t, f, "k", 0, 158, 800, 162)       // negative margin
}

@(test)
floats_and_clear :: proc(t: ^testing.T) {
	f := load(`<body style="margin:0;width:400px;font-size:10px;line-height:10px">
<div id=l style="float:left;width:100px;height:50px"></div>
<div id=r style="float:right;width:120px;height:30px"></div>
<div id=c style="clear:both;height:10px"></div>
<div id=l2 style="float:left;width:300px;height:20px"></div><div id=l3 style="float:left;width:200px;height:20px"></div>
<div id=after style="clear:left;height:1px"></div>
<div id=f4 style="float:left;width:100px;height:25px"></div><p id=t style="margin:0">xxxxxxxxxx xxxxxxxxxx xxxxxxxxxx xxxxxxxxxx xxxxxxxxxx xxxxxxxxxx xxxxxxxxxx xxxxxxxxxx xxxxxxxxxx xxxxxxxxxx xxxxxxxxxx xxxxxxxxxx xxxxxxxxxx xxxxxxxxxx xxxxxxxxxx xxxxxxxxxx xxxxxxxxxx xxxxxxxxxx xxxxxxxxxx xxxxxxxxxx</p>
<div id=bfc style="overflow:hidden;height:5px"></div>
</body>`)
	defer unload(f)
	expect_rect(t, f, "l", 0, 0, 100, 50)
	expect_rect(t, f, "r", 280, 0, 400, 30)
	expect_rect(t, f, "c", 0, 50, 400, 60)
	expect_rect(t, f, "l2", 0, 60, 300, 80)
	expect_rect(t, f, "l3", 0, 80, 200, 100)       // does not fit beside l2: goes below it
	expect_rect(t, f, "after", 0, 100, 400, 101)
	expect_rect(t, f, "f4", 0, 101, 100, 126)
	// lines beside the float are 300px wide (5 words of 50px + 4 spaces), then 400px
	lines := ifc_lines(f, "t")
	testing.expect_value(t, len(lines), 4)
	if len(lines) == 4 {
		testing.expect(t, near(first_text(f, lines[0]).x, 100), "first line starts after the float")
		testing.expect(t, near(first_text(f, lines[2]).x, 100), "third line still beside the float")
		testing.expect(t, near(first_text(f, lines[3]).x, 0), "fourth line below the float")
		testing.expect(t, near(first_text(f, lines[0]).w, 270), "five words")
	}
}

@(test)
bfc_avoids_floats :: proc(t: ^testing.T) {
	f := load(`<body style="margin:0;width:400px">
<div id=fl style="float:left;width:100px;height:50px"></div>
<div id=ov style="overflow:hidden;height:20px"></div>
<div id=wide style="display:flow-root;width:350px;height:10px"></div>
</body>`)
	defer unload(f)
	expect_rect(t, f, "ov", 100, 0, 400, 20)      // shrinks beside the float
	expect_rect(t, f, "wide", 0, 50, 350, 60)     // too wide beside it: below
}

@(test)
inline_block_and_vertical_align :: proc(t: ^testing.T) {
	f := load(`<body style="margin:0;font-size:10px;line-height:10px">
<div id=d1><span id=ib style="display:inline-block;width:20px;height:30px"></span>x</div>
<div id=d2><span id=ib2 style="display:inline-block;width:20px;height:30px;vertical-align:middle"></span>x</div>
<div id=d3><span id=ib3 style="display:inline-block;width:20px;height:30px;vertical-align:top"></span>x</div>
<div id=d4>a<span id=sup style="vertical-align:super">b</span></div>
<div id=d5><span id=ib5 style="display:inline-block;width:40px">yy<br>zz</span>x</div>
</body>`)
	defer unload(f)
	// baseline at the bottom of the inline-block: line from -30 to +2 around the baseline
	expect_rect(t, f, "d1", 0, 0, 800, 32)
	expect_rect(t, f, "ib", 0, 0, 20, 30)
	// middle: centre at baseline - x-height / 2 => box from -17.5 to 12.5, strut -8..2
	expect_rect(t, f, "d2", 0, 32, 800, 62)
	expect_rect(t, f, "ib2", 0, 32, 20, 62)
	// top: the box hangs from the line top; the line is as tall as the box
	expect_rect(t, f, "d3", 0, 62, 800, 92)
	expect_rect(t, f, "ib3", 0, 62, 20, 92)
	// super raises by 0.34 em of the parent: the line grows from -8..2 to -11.4..2
	sup, d4 := rect(f, "sup"), rect(f, "d4")
	testing.expect(t, near(sup.min.y, d4.min.y) && near(d4.max.y - d4.min.y, 13.4), "superscript is raised")
	// inline-block with text: its baseline is its last line's
	d5 := rect(f, "d5")
	ib5 := rect(f, "ib5")
	testing.expect(t, near(ib5.max.y - ib5.min.y, 20), "two lines")
	testing.expect(t, near(ib5.min.y, d5.min.y), "aligned on its last line")
	testing.expect(t, near(d5.max.y - d5.min.y, 20), "line as tall as the inline-block")
}

@(test)
text_align_and_justify :: proc(t: ^testing.T) {
	f := load(`<body style="margin:0;font-size:10px;line-height:10px">
<p id=j style="width:100px;text-align:justify;margin:0">aaa bbb ccc ddd eee fff</p>
<p id=c style="width:100px;text-align:center;margin:0">abc</p>
<p id=r style="width:100px;text-align:right;margin:0">abc</p>
<p id=in style="width:100px;text-indent:10px;margin:0">abc</p>
<p id=rtl style="width:100px;direction:rtl;margin:0">abc</p>
</body>`)
	defer unload(f)
	lj := ifc_lines(f, "j")
	testing.expect_value(t, len(lj), 2)
	if len(lj) == 2 {
		ft := first_text(f, lj[0])
		testing.expect(t, near(ft.w, 100), "justified line fills the width")
		testing.expect(t, near(ft.extra, 1.25), "5px spread over 4 spaces")
		testing.expect(t, near(first_text(f, lj[1]).extra, 0), "last line not justified")
	}
	testing.expect(t, near(first_text(f, ifc_lines(f, "c")[0]).x, 42.5), "centered")
	testing.expect(t, near(first_text(f, ifc_lines(f, "r")[0]).x, 85), "right")
	testing.expect(t, near(first_text(f, ifc_lines(f, "in")[0]).x, 10), "text-indent")
	testing.expect(t, near(first_text(f, ifc_lines(f, "rtl")[0]).x, 85), "rtl start is the right")
}

@(test)
white_space_modes :: proc(t: ^testing.T) {
	f := load("<body style=\"margin:0;font-size:10px;line-height:10px\">" +
		"<pre id=pr style=\"margin:0;font-size:10px\">a  b\ncc\n</pre>" +
		"<div id=pw style=\"white-space:pre-wrap;width:50px\">aaaa bbbb cccc</div>" +
		"<div id=nw style=\"white-space:nowrap;width:20px\">aaaa bbbb</div>" +
		"<div id=tab style=\"white-space:pre\">a\tb</div>" +
		"<div id=pl style=\"white-space:pre-line;width:200px\">a   b\nc</div>" +
		"<div id=n style=\"width:200px\">a \n   b</div>" +
		"<div id=ow style=\"width:20px;overflow-wrap:anywhere\">aaaaaaaaaa</div>" +
		"<div id=br>a<br>b<br><br>c</div>" +
		"</body>")
	defer unload(f)
	pr := ifc_lines(f, "pr")
	testing.expect_value(t, len(pr), 2)   // the final newline does not open a line
	if len(pr) > 0 { testing.expect(t, near(first_text(f, pr[0]).w, 20), "spaces preserved") }
	testing.expect_value(t, len(ifc_lines(f, "pw")), 2)
	testing.expect_value(t, len(ifc_lines(f, "nw")), 1)
	tb := ifc_lines(f, "tab")
	if len(tb) == 1 {
		// tab stops every 8 spaces (40px): "b" starts at 40
		ln := tb[0]
		last := &f.l.frags[ln.frags[1] - 1]
		testing.expect(t, near(last.x, 40), "tab stop")
	}
	testing.expect_value(t, len(ifc_lines(f, "pl")), 2)
	nl := ifc_lines(f, "n")
	testing.expect_value(t, len(nl), 1)
	if len(nl) == 1 {
		// "a b": collapsed to one space
		w: f32
		for i in nl[0].frags[0] ..< nl[0].frags[1] { if f.l.frags[i].kind == .Text { w = max(w, f.l.frags[i].x + f.l.frags[i].w) } }
		testing.expect(t, near(w, 15), "white space collapsed")
	}
	testing.expect_value(t, len(ifc_lines(f, "ow")), 3)   // 10 chars of 5px in 20px: 4 + 4 + 2
	testing.expect_value(t, len(ifc_lines(f, "br")), 4)
}

@(test)
positioning :: proc(t: ^testing.T) {
	f := load(`<body style="margin:0">
<div id=rel style="position:relative;left:10px;top:5px;height:20px"><div id=abs style="position:absolute;right:0;bottom:0;width:30px;height:10px"></div><div id=fill style="position:absolute;left:5px;right:5px;top:0;bottom:0"></div></div>
<div id=fix style="position:fixed;left:0;top:0;width:50px;height:50px"></div>
<div id=ctr style="position:absolute;left:0;right:0;top:100px;width:100px;height:10px;margin:0 auto"></div>
<div id=tall style="height:2000px"><div id=pad style="height:100px"></div><div id=stk style="position:sticky;top:0;height:10px"></div></div>
<div id=stat style="position:absolute;width:10px;height:10px"></div>
</body>`)
	defer unload(f)
	expect_rect(t, f, "rel", 10, 5, 810, 25)
	expect_rect(t, f, "abs", 780, 15, 810, 25)
	expect_rect(t, f, "fill", 15, 5, 805, 25)
	expect_rect(t, f, "fix", 0, 0, 50, 50)
	expect_rect(t, f, "ctr", 350, 100, 450, 110)
	expect_rect(t, f, "stk", 0, 120, 800, 130)
	expect_rect(t, f, "stat", 0, 2020, 10, 2030)   // static position: where it would have been
	fr, _ := box_of(&f.l, node(f, "fix"), f.vp, 300)
	testing.expect(t, fr.fixed && near(fr.border.min.y, 300), "fixed follows the viewport")
	sr, _ := box_of(&f.l, node(f, "stk"), f.vp, 500)
	testing.expect(t, near(sr.border.min.y, 500), "sticky sticks to the top")
	sr2, _ := box_of(&f.l, node(f, "stk"), f.vp, 3000)
	testing.expect(t, near(sr2.border.min.y, 2010), "sticky stops at its containing block's end")
}

@(private = "file")
item_index :: proc(f: ^Fx, id: string, kind: Item_Kind = .Box) -> int {
	h := node(f, id)
	for &it, i in f.l.items { if it.node == h && it.kind == kind { return i } }
	return -1
}

@(test)
paint_order_and_z_index :: proc(t: ^testing.T) {
	f := load(`<body style="margin:0">
<div id=a style="position:relative;z-index:2;height:10px;background:red"></div>
<div id=b style="position:relative;z-index:-1;height:10px;background:blue"></div>
<div id=c style="height:10px;background:green">text</div>
<div id=d style="position:absolute;top:0;left:0;width:10px;height:10px;background:black"></div>
<div id=fl style="float:left;width:10px;height:10px"></div>
<div id=op style="opacity:0.5;height:10px"></div>
</body>`)
	defer unload(f)
	ia, ib, ic, id_, ifl := item_index(f, "a"), item_index(f, "b"), item_index(f, "c"), item_index(f, "d"), item_index(f, "fl")
	itext := item_index(f, "c", .Text)
	testing.expect(t, ib < ic, "negative z-index under in-flow blocks")
	testing.expect(t, ic < ifl, "floats over block backgrounds")
	testing.expect(t, ifl < itext, "inline content over floats")
	testing.expect(t, itext < id_, "positioned over inline content")
	testing.expect(t, id_ < ia, "positive z-index last")
	h := hit_test(&f.l, {5, 5}, f.vp, 0)
	testing.expect(t, h.node == node(f, "a"), "the z-index 2 box is on top")
	op := item_index(f, "op")
	testing.expect(t, op >= 0 && f.l.items[op].group >= 0 && near(f.l.groups[f.l.items[op].group].alpha, 0.5), "opacity group")
}

@(test)
flexbox :: proc(t: ^testing.T) {
	f := load(`<body style="margin:0;font-size:10px;line-height:10px">
<div id=f style="display:flex;width:300px;height:100px"><div id=f1 style="flex:1 1 0px"></div><div id=f2 style="flex:2 1 0px"></div><div id=f3 style="width:60px;flex:none"></div></div>
<div style="display:flex;width:100px"><div id=s1 style="width:100px;flex-shrink:1;height:1px"></div><div id=s2 style="width:100px;flex-shrink:3;height:1px"></div></div>
<div style="display:flex;flex-wrap:wrap;width:100px;justify-content:space-between"><div id=w1 style="width:40px;height:10px"></div><div id=w2 style="width:40px;height:10px"></div><div id=w3 style="width:40px;height:10px"></div></div>
<div style="display:flex;width:100px;height:100px;align-items:center;justify-content:center"><div id=cc style="width:20px;height:20px"></div></div>
<div style="display:flex;width:100px"><div id=o1 style="width:10px;height:1px"></div><div id=o2 style="width:10px;height:1px;order:-1"></div></div>
<div style="display:flex;flex-direction:column;height:200px;width:50px"><div id=c1 style="flex-grow:1"></div><div id=c2 style="height:50px"></div></div>
<div style="display:flex;width:50px"><div id=mc>aaaaaaaaaaaa</div></div>
<div style="display:flex;width:100px;justify-content:space-evenly"><div id=e1 style="width:20px;height:1px"></div><div id=e2 style="width:20px;height:1px"></div></div>
<div style="display:flex;flex-direction:row-reverse;width:100px"><div id=rr style="width:20px;height:1px"></div></div>
<div style="display:flex;width:100px"><div id=am style="width:20px;height:1px;margin-left:auto"></div></div>
</body>`)
	defer unload(f)
	expect_rect(t, f, "f1", 0, 0, 80, 100)
	expect_rect(t, f, "f2", 80, 0, 240, 100)
	expect_rect(t, f, "f3", 240, 0, 300, 100)
	s1, s2 := rect(f, "s1"), rect(f, "s2")
	testing.expect(t, near(s1.max.x - s1.min.x, 75) && near(s2.max.x - s2.min.x, 25), "shrink weighted by flex-shrink x base size")
	w2, w3 := rect(f, "w2"), rect(f, "w3")
	testing.expect(t, near(w2.min.x, 60), "space-between")
	testing.expect(t, near(w3.min.x, 0) && near(w3.min.y, w2.max.y), "wraps to a second line")
	cc := rect(f, "cc")
	testing.expect(t, near(cc.min.x - 0, 40) && near(cc.min.y - (w3.max.y), 40), "centered on both axes")
	testing.expect(t, rect(f, "o2").min.x < rect(f, "o1").min.x, "order")
	c1 := rect(f, "c1")
	testing.expect(t, near(c1.max.y - c1.min.y, 150), "column grows")
	mc := rect(f, "mc")
	testing.expect(t, near(mc.max.x - mc.min.x, 60), "automatic minimum: no narrower than its longest word")
	testing.expect(t, near(rect(f, "e1").min.x, 20) && near(rect(f, "e2").min.x, 60), "space-evenly")
	testing.expect(t, near(rect(f, "rr").min.x, 80), "row-reverse starts at the right")
	testing.expect(t, near(rect(f, "am").min.x, 80), "auto margin takes the free space")
}

@(test)
tables :: proc(t: ^testing.T) {
	// (standards mode: in quirks mode tables would not inherit the font size and line height)
	f := load(`<!doctype html><body style="margin:0;font-size:10px;line-height:10px">
<table id=t style="border-spacing:0"><tr><td id=c1 style="width:50px;padding:0">a</td><td id=c2 style="width:30px;padding:0">b</td></tr><tr><td id=c3 colspan=2 style="padding:0">c</td></tr></table>
<table id=t2 style="border-spacing:2px"><tr><td id=d1 style="padding:0" rowspan=2>x<br>y<br>z</td><td id=d2 style="padding:0">q</td></tr><tr><td id=d3 style="padding:0">r</td></tr></table>
<div id=orph style="display:table-cell">cell</div>
</body>`)
	defer unload(f)
	expect_rect(t, f, "t", 0, 0, 80, 20)
	expect_rect(t, f, "c1", 0, 0, 50, 10)
	expect_rect(t, f, "c2", 50, 0, 80, 10)
	expect_rect(t, f, "c3", 0, 10, 80, 20)
	d1, d2, d3 := rect(f, "d1"), rect(f, "d2"), rect(f, "d3")
	testing.expect(t, near(d1.max.y - d1.min.y, 30), "rowspan cell spans both rows")
	testing.expect(t, near(d2.min.x, d1.max.x + 2), "border-spacing between columns")
	testing.expect(t, near(d3.max.y, d1.max.y), "rows share the rowspan height")
	testing.expect(t, rect(f, "orph").max.x > 0, "an orphan cell gets an anonymous table")
}

@(test)
overflow_clip_and_scroll :: proc(t: ^testing.T) {
	f := load(`<body style="margin:0">
<div id=sc style="overflow:auto;height:50px;width:100px"><div id=in style="height:200px"></div></div>
<div id=hid style="overflow:hidden;height:20px;width:100px"><div id=in2 style="height:200px;background:red"></div></div>
</body>`)
	defer unload(f)
	m, ok := scroll_max(&f.l, node(f, "sc"))
	testing.expect(t, ok && near(m.y, 150), "scrollable by the overflow")
	testing.expect(t, scroll_wheel(&f.l, {10, 10}, {0, 30}, f.vp, 0), "wheel scrolls the box under the pointer")
	off, _ := scroll_of(&f.l, node(f, "sc"))
	testing.expect(t, near(off.y, 30), "offset kept")
	testing.expect(t, near(rect(f, "in").min.y, -30), "content moved")
	set_scroll(&f.l, node(f, "sc"), {0, 1000})
	off, _ = scroll_of(&f.l, node(f, "sc"))
	testing.expect(t, near(off.y, 150), "clamped")
	testing.expect(t, !scroll_wheel(&f.l, {10, 10}, {0, 30}, f.vp, 0), "at the end: the page scrolls instead")
	relayout(f)
	off, _ = scroll_of(&f.l, node(f, "sc"))
	testing.expect(t, near(off.y, 150), "offset survives a relayout")
	_, ok2 := scroll_max(&f.l, node(f, "hid"))
	testing.expect(t, !ok2, "overflow hidden is not a scroll container")
	i := item_index(f, "in2")
	testing.expect(t, i >= 0 && f.l.items[i].clip != NONE, "clipped")
	if i >= 0 && f.l.items[i].clip != NONE {
		cr := f.l.clips[f.l.items[i].clip].rect
		testing.expect(t, near(cr.max.y - cr.min.y, 20), "clip is the padding box")
	}
	h := hit_test(&f.l, {10, 65}, f.vp, 0)
	testing.expect(t, h.node == node(f, "in2"), "inside the clip")
	h2 := hit_test(&f.l, {10, 75}, f.vp, 0)
	testing.expect(t, h2.node != node(f, "in2"), "clipped away")
}

@(test)
lists :: proc(t: ^testing.T) {
	f := load(`<body style="margin:0"><ol start=3><li id=l1>a</li><li id=l2 value=10>b</li><li id=l3>c</li></ol>
<ol reversed><li id=r1>a</li><li id=r2>b</li></ol>
<ol style="list-style-type:upper-roman" start=4><li id=ro>a</li></ol>
<ol style="list-style-type:lower-alpha" start=27><li id=al>a</li></ol>
<ul><li id=u1>a</li></ul>
<ul style="list-style-position:inside"><li id=ins>a</li></ul></body>`)
	defer unload(f)
	marker :: proc(f: ^Fx, id: string) -> string {
		bi := box_index(&f.l, node(f, id))
		return bi == NONE ? "?" : f.l.boxes[bi].marker
	}
	testing.expect_value(t, marker(f, "l1"), "3.")
	testing.expect_value(t, marker(f, "l2"), "10.")
	testing.expect_value(t, marker(f, "l3"), "11.")
	testing.expect_value(t, marker(f, "r1"), "2.")
	testing.expect_value(t, marker(f, "r2"), "1.")
	testing.expect_value(t, marker(f, "ro"), "IV.")
	testing.expect_value(t, marker(f, "al"), "aa.")
	ub := box_index(&f.l, node(f, "u1"))
	testing.expect(t, ub != NONE && f.l.boxes[ub].marker == "" && f.l.boxes[ub].marker_w > 0, "disc bullet is a shape")
	testing.expect(t, ub != NONE && f.l.boxes[ub].marker_pos.x < 0, "outside marker left of the content")
	testing.expect(t, item_index(f, "u1", .Marker) >= 0, "marker painted")
	ins := ifc_lines(f, "ins")
	testing.expect(t, len(ins) == 1 && first_text(f, ins[0]).text == "\u2022 ", "inside marker is inline content")
}

@(test)
hit_testing :: proc(t: ^testing.T) {
	f := load(`<body style="margin:0;font-size:10px;line-height:10px">
<div id=under style="height:50px"></div>
<div id=over style="position:absolute;top:0;left:0;width:100px;height:50px;pointer-events:none"></div>
<div id=hid style="position:absolute;top:0;left:100px;width:100px;height:50px;visibility:hidden"></div>
<p id=p style="margin:0">hello <span id=s>world</span></p>
</body>`)
	defer unload(f)
	testing.expect(t, hit_test(&f.l, {10, 10}, f.vp, 0).node == node(f, "under"), "pointer-events: none is transparent")
	testing.expect(t, hit_test(&f.l, {110, 10}, f.vp, 0).node == node(f, "under"), "visibility: hidden is transparent")
	testing.expect(t, hit_test(&f.l, {32, 55}, f.vp, 0).node == node(f, "s"), "text of the span")
	testing.expect(t, hit_test(&f.l, {5, 55}, f.vp, 0).node == node(f, "p"), "text of the paragraph")
	testing.expect(t, hit_test(&f.l, {10, 15}, f.vp, 100).node != node(f, "under"), "document scroll applies")
}

@(test)
replaced_and_controls :: proc(t: ^testing.T) {
	f := load(`<body style="margin:0;font-size:10px;line-height:10px">
<img id=i1 width=40 height=30><img id=i2><canvas id=cv></canvas>
<div><input id=in style="font-size:10px;padding:0;border:0"></div>
<div><input id=cb type=checkbox style="margin:0"></div>
<div><img id=ar style="width:100px;aspect-ratio:2"></div>
</body>`)
	defer unload(f)
	i1 := rect(f, "i1")
	testing.expect(t, near(i1.max.x - i1.min.x, 40) && near(i1.max.y - i1.min.y, 30), "width/height attributes")
	i2 := rect(f, "i2")
	testing.expect(t, near(i2.max.x - i2.min.x, 0), "unknown size: placeholder")
	cv := rect(f, "cv")
	testing.expect(t, near(cv.max.x - cv.min.x, 300) && near(cv.max.y - cv.min.y, 150), "canvas default")
	in_ := rect(f, "in")
	testing.expect(t, near(in_.max.x - in_.min.x, 100), "20 characters of 5px")
	cb := rect(f, "cb")
	testing.expect(t, near(cb.max.x - cb.min.x, 13), "checkbox")
	ar := rect(f, "ar")
	testing.expect(t, near(ar.max.y - ar.min.y, 50), "aspect-ratio")
	testing.expect(t, item_index(f, "in", .Control) >= 0, "control item for the forms painter")
}

@(test)
intrinsic_keywords :: proc(t: ^testing.T) {
	f := load(`<body style="margin:0;font-size:10px;line-height:10px">
<div id=mn style="width:min-content">aaa bbbbb cc</div>
<div id=mx style="width:max-content">aaa bbbbb cc</div>
<div id=fc style="width:fit-content">aaa</div>
<div><span id=ibk style="display:inline-block">aa bb</span></div>
</body>`)
	defer unload(f)
	mn := rect(f, "mn")
	testing.expect(t, near(mn.max.x - mn.min.x, 25), "min-content = longest word")
	mx := rect(f, "mx")
	testing.expect(t, near(mx.max.x - mx.min.x, 60), "max-content = one line")
	fc := rect(f, "fc")
	testing.expect(t, near(fc.max.x - fc.min.x, 15), "fit-content")
	ib := rect(f, "ibk")
	testing.expect(t, near(ib.max.x - ib.min.x, 25), "inline-block shrinks to fit")
}

@(test)
hostile_depth :: proc(t: ^testing.T) {
	// 100 000 nested elements: built directly (the parser has its own limits), styled and laid out without recursion
	f := new(Fx)
	f.doc = dom.document_create(nil)
	defer unload(f)
	htm := dom.create_element(f.doc, "html")
	dom.append_child(f.doc, f.doc.root, htm)
	body := dom.create_element(f.doc, "body")
	dom.append_child(f.doc, htm, body)
	cur := body
	for _ in 0 ..< 100_000 {
		d := dom.create_element(f.doc, "div")
		dom.append_child(f.doc, cur, d)
		cur = d
	}
	dom.append_child(f.doc, cur, dom.create_text(f.doc, "deep"))
	ss := style.settings_default()
	f.eng = style.engine_make(ss)
	style.settings_destroy(&ss)
	style.sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = style.compute_styles(f.eng, f.doc, {})
	f.set = settings_default()
	f.vp = {800, 600}
	relayout(f)
	max_depth: i32
	for &b in f.l.boxes { max_depth = max(max_depth, b.depth) }
	testing.expect(t, int(max_depth) <= f.set.max_depth, "box depth bounded")
	found := false
	for &it in f.l.inline_items { if it.kind == .Text && it.text == "deep" { found = true } }
	testing.expect(t, found, "the deepest text is still laid out")
	testing.expect(t, f.l.valid && len(f.l.items) > 0, "display list made")
	// deep inline nesting is iterative all the way
	f2 := new(Fx)
	f2.doc = dom.document_create(nil)
	defer unload(f2)
	h2 := dom.create_element(f2.doc, "html")
	dom.append_child(f2.doc, f2.doc.root, h2)
	b2 := dom.create_element(f2.doc, "body")
	dom.append_child(f2.doc, h2, b2)
	cur = b2
	for _ in 0 ..< 100_000 {
		s := dom.create_element(f2.doc, "span")
		dom.append_child(f2.doc, cur, s)
		cur = s
	}
	dom.append_child(f2.doc, cur, dom.create_text(f2.doc, "deep"))
	ss2 := style.settings_default()
	f2.eng = style.engine_make(ss2)
	style.settings_destroy(&ss2)
	style.sync_document_sheets(f2.eng, f2.doc, "about:test")
	f2.st = style.compute_styles(f2.eng, f2.doc, {})
	f2.set = settings_default()
	f2.vp = {800, 600}
	relayout(f2)
	testing.expect(t, f2.l.valid && hit_test(&f2.l, {12, 14}, f2.vp, 0).node != base.NIL_HANDLE, "deep inline content is hit")
}

// Hostile lengths stay finite through layout: huge widths and percentages of them, a huge canvas, a subnormal aspect
// ratio, tabs with no interval (font-size: 0, tab-size: 0). No NaN or infinity in boxes, fragments, items or extent.
@(test)
hostile_lengths_stay_finite :: proc(t: ^testing.T) {
	srcs := []string{
		`<div style="width:1e39px"><p style="width:0%">zero</p><p>auto <span style="margin-left:auto">x</span></p><div style="margin:auto;width:50%">c</div></div>`,
		`<canvas width="10000000000000000000000000000000000000000" height="1e40"></canvas><p>after</p>`,
		`<div style="aspect-ratio:1e-39;width:100px">r</div><div style="aspect-ratio:1/1e-39;width:100px">r</div>`,
		`<pre style="font-size:0">a	b	c</pre><pre style="tab-size:0">a	b</pre><pre style="letter-spacing:-1000px">a	b</pre><p>after</p>`,
		`<div style="width:calc(1e300px * 1e300);height:1e39px;margin-left:-1e39px">big</div><p style="text-indent:1e38px">t</p>`,
	}
	finite :: proc(v: f32) -> bool { return !math.is_nan(v) && !math.is_inf(v) }
	for s in srcs {
		f := load(s)
		defer unload(f)
		bad := 0
		for &b in f.l.boxes {
			if !finite(b.pos.x) || !finite(b.pos.y) || !finite(b.size.x) || !finite(b.size.y) || !finite(b.abs.x) || !finite(b.abs.y) { bad += 1 }
		}
		for &fr in f.l.frags { if !finite(fr.x) || !finite(fr.w) || !finite(fr.y) { bad += 1 } }
		for &it in f.l.items { if !finite(it.rect.min.x) || !finite(it.rect.max.x) || !finite(it.rect.min.y) || !finite(it.rect.max.y) { bad += 1 } }
		testing.expectf(t, bad == 0 && finite(f.l.height) && finite(f.l.doc_width), "%s: %d non-finite values, extent %v x %v", s, bad, f.l.doc_width, f.l.height)
		for y in ([]f32{0, 10, 300, 599}) { _ = hit_test(&f.l, {10, y}, f.vp, 0) }
	}
}