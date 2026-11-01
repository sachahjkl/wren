package layout

import "core:fmt"
import "core:math"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:html"
import "wb:style"

// Multi-column layout and writing modes: where boxes show (every character 0.5 em wide), and, after a change, that an incremental
// pass made what a full pass makes (layout.incremental.verify).

@(private = "file")
Mf :: struct {
	doc: ^dom.Document,
	eng: ^style.Engine,
	st:  ^style.Styled,
	set: Settings,
	l:   Layout,
	vp:  Vec2,
}

@(private = "file")
mf_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> Font { return Font(1) }
@(private = "file")
mf_width :: proc(user: rawptr, f: Font, size: f32, text: string) -> f32 { return 0.5 * size * f32(rune_count(text)) }
@(private = "file")
mf_metrics :: proc(user: rawptr, f: Font, size: f32) -> Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} }

@(private = "file")
mf_run :: proc(f: ^Mf) {
	run(&f.l, Input{doc = f.doc, styled = f.st, settings = &f.set, text = Text_Api{font = mf_font, width = mf_width, metrics = mf_metrics}, viewport = f.vp, scale = 1, band_h = 64})
}

@(private = "file")
mf_load :: proc(src: string, vw: f32 = 800, vh: f32 = 600) -> ^Mf {
	f := new(Mf)
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	ss := style.settings_default()
	f.eng = style.engine_make(ss)
	style.settings_destroy(&ss)
	style.engine_set_journal(f.eng, 1 << 16)
	style.sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = style.compute_styles(f.eng, f.doc, {})
	f.set = settings_default()
	f.set.inc_verify = true
	f.vp = {vw, vh}
	mf_run(f)
	return f
}

@(private = "file")
mf_unload :: proc(f: ^Mf) {
	destroy(&f.l)
	style.styled_destroy(f.st)
	style.engine_destroy(f.eng)
	dom.document_destroy(f.doc)
	free(f)
}

// After a change of the document: styles again, then an incremental pass, checked against a full one.
@(private = "file")
mf_frame :: proc(t: ^testing.T, f: ^Mf, loc := #caller_location) {
	if f.st.mutations != f.doc.mutations {
		old := f.st
		f.st = style.compute_styles(f.eng, f.doc, {})
		style.journal_diff(old, f.st)
		style.styled_destroy(old)
	}
	before := f.l.inc.verify_failures
	mf_run(f)
	testing.expectf(t, f.l.inc.verify_failures == before, "an incremental pass differs from a full one: %s", f.l.inc.verify_report, loc = loc)
}

@(private = "file")
mf_rect :: proc(f: ^Mf, id: string) -> Rect {
	r, ok := box_of(&f.l, dom.find_by_id(f.doc, id), f.vp, 0)
	if !ok { return {} }
	return r.border
}

@(private = "file")
mf_expect :: proc(t: ^testing.T, f: ^Mf, id: string, x0, y0, x1, y1: f32, loc := #caller_location) {
	r := mf_rect(f, id)
	near :: proc(a, b: f32) -> bool { return math.abs(a - b) <= 0.01 }
	ok := near(r.min.x, x0) && near(r.min.y, y0) && near(r.max.x, x1) && near(r.max.y, y1)
	testing.expectf(t, ok, "#%s at %v, expected (%v %v)-(%v %v)", id, r, x0, y0, x1, y1, loc = loc)
}

// Six lines, 20 px each, in `n` columns.
@(private = "file")
SIX :: `<div id=a>a</div><div id=b>b</div><div id=c>c</div><div id=d>d</div><div id=e>e</div><div id=f>f</div>`

@(test)
multicol_balanced :: proc(t: ^testing.T) {
	f := mf_load(`<!doctype html><style>body{margin:0;font:20px/20px x} #m{column-count:3;column-gap:10px;width:320px}</style><div id=m>` + SIX + `</div><p id=after style="margin:0">z</p>`)
	defer mf_unload(f)
	mf_expect(t, f, "a", 0, 0, 100, 20)
	mf_expect(t, f, "b", 0, 20, 100, 40)
	mf_expect(t, f, "c", 110, 0, 210, 20)
	mf_expect(t, f, "d", 110, 20, 210, 40)
	mf_expect(t, f, "e", 220, 0, 320, 20)
	mf_expect(t, f, "f", 220, 20, 320, 40)
	mf_expect(t, f, "m", 0, 0, 320, 40)
	mf_expect(t, f, "after", 0, 40, 800, 60)
	testing.expect(t, f.l.height <= 600, "the flow's strip adds nothing to the document")
}

@(test)
multicol_width_and_rtl :: proc(t: ^testing.T) {
	// column-width: as many as fit
	f := mf_load(`<!doctype html><style>body{margin:0;font:20px/20px x} #m{column-width:100px;column-gap:20px;width:390px}</style><div id=m>` + SIX + `</div>`)
	defer mf_unload(f)
	mf_expect(t, f, "a", 0, 0, 116.666, 20)
	mf_expect(t, f, "c", 136.666, 0, 253.333, 20)
	// columns: 2 in a right-to-left container start on the right
	g := mf_load(`<!doctype html><style>body{margin:0;font:20px/20px x} #m{columns:2;column-gap:0;width:200px;direction:rtl}</style><div id=m>` + SIX + `</div>`)
	defer mf_unload(g)
	mf_expect(t, g, "a", 100, 0, 200, 20)
	mf_expect(t, g, "d", 0, 0, 100, 20)
}

@(test)
multicol_forced_breaks_and_avoid :: proc(t: ^testing.T) {
	f := mf_load(`<!doctype html><style>body{margin:0;font:20px/20px x} #m{column-count:2;column-gap:0;width:200px} #c{break-before:column}</style><div id=m>` + SIX + `</div>`)
	defer mf_unload(f)
	mf_expect(t, f, "a", 0, 0, 100, 20)
	mf_expect(t, f, "b", 0, 20, 100, 40)
	mf_expect(t, f, "c", 100, 0, 200, 20)
	mf_expect(t, f, "f", 100, 60, 200, 80)
	// break-inside: avoid keeps a block whole
	g := mf_load(`<!doctype html><style>body{margin:0;font:20px/20px x} #m{column-count:2;column-gap:0;width:200px;orphans:1;widows:1} #k{break-inside:avoid}</style><div id=m><div>1</div><div>2</div><div id=k>3<br>4<br>5</div><div id=z>6</div></div>`)
	defer mf_unload(g)
	mf_expect(t, g, "k", 100, 0, 200, 60)
}

@(test)
multicol_orphans_widows :: proc(t: ^testing.T) {
	// the paragraph does not leave one line behind: two lines stay together on each side
	f := mf_load(`<!doctype html><style>body{margin:0;font:20px/20px x} #m{column-count:2;column-gap:0;width:200px;height:60px;column-fill:auto} p{margin:0}</style><div id=m><p id=a>1</p><p id=p>2<br>3<br>4</p></div>`)
	defer mf_unload(f)
	lines := f.l.boxes[box_index(&f.l, dom.find_by_id(f.doc, "p"))].lines
	testing.expect(t, lines[1] - lines[0] == 3)
	mf_expect(t, f, "a", 0, 0, 100, 20)
	// 40 px are left beside #a, but two lines would have to stay with the third (widows: 2 leave no room): all three in the second column,
	// since one line in the first would leave only two in the second
	r := mf_rect(f, "p")
	testing.expectf(t, r.max.x == 200, "%v", r)
}

@(test)
multicol_spanner :: proc(t: ^testing.T) {
	f := mf_load(`<!doctype html><style>body{margin:0;font:20px/20px x} #m{column-count:2;column-gap:0;width:200px} #s{column-span:all}</style><div id=m><div id=a>a</div><div id=b>b</div><div id=s>spanner</div><div id=c>c</div><div id=d>d</div></div>`)
	defer mf_unload(f)
	mf_expect(t, f, "a", 0, 0, 100, 20)
	mf_expect(t, f, "b", 100, 0, 200, 20)
	mf_expect(t, f, "s", 0, 20, 200, 40)
	mf_expect(t, f, "c", 0, 40, 100, 60)
	mf_expect(t, f, "d", 100, 40, 200, 60)
	mf_expect(t, f, "m", 0, 0, 200, 60)
}

@(test)
multicol_fill_auto_overflow_columns :: proc(t: ^testing.T) {
	f := mf_load(`<!doctype html><style>body{margin:0;font:20px/20px x} #m{column-count:2;column-gap:0;width:200px;height:20px;column-fill:auto}</style><div id=m>` + SIX + `</div>`)
	defer mf_unload(f)
	mf_expect(t, f, "a", 0, 0, 100, 20)
	mf_expect(t, f, "b", 100, 0, 200, 20)
	// overflow columns go on in the inline direction
	mf_expect(t, f, "f", 500, 0, 600, 20)
	mf_expect(t, f, "m", 0, 0, 200, 20)
	testing.expect(t, f.l.doc_width >= 800)
	g := mf_load(`<!doctype html><style>body{margin:0;font:20px/20px x} #m{column-count:2;column-gap:0;width:200px;height:20px;column-fill:auto}</style><div id=m>` + SIX + `</div>`, 300, 200)
	defer mf_unload(g)
	testing.expectf(t, g.l.doc_width == 600, "overflow columns are scrollable overflow: %v", g.l.doc_width)
}

@(test)
multicol_cuts_boxes_and_paints_rules :: proc(t: ^testing.T) {
	// a tall empty box is cut: a piece in each column, clipped
	f := mf_load(`<!doctype html><style>body{margin:0} #m{column-count:2;column-gap:20px;column-rule:4px solid red;width:220px} #x{height:200px;background:blue}</style><div id=m><div id=x></div></div>`)
	defer mf_unload(f)
	bi := box_index(&f.l, dom.find_by_id(f.doc, "x"))
	pieces := 0
	for &it in f.l.items { if it.box == bi && it.kind == .Box { pieces += 1 } }
	testing.expectf(t, pieces == 2, "one display item per column: %d", pieces)
	mf_expect(t, f, "x", 0, 0, 220, 100)
	rules := 0
	for &it in f.l.items {
		if it.kind != .Column_Rule { continue }
		rules += 1
		testing.expectf(t, it.rect == Rect{{108, 0}, {112, 100}}, "the rule: %v", it.rect)
	}
	testing.expect(t, rules == 1)
	// hit testing: the second column shows the box's lower half
	h := hit_test(&f.l, {150, 50}, f.vp, 0)
	testing.expect(t, h.box == bi, "hit in the second column")
	h2 := hit_test(&f.l, {105, 50}, f.vp, 0)
	testing.expect(t, h2.box != bi, "the gap is not the box")
	// getClientRects: one rectangle per fragment
	list := make([dynamic]Rect, 0, 4, context.temp_allocator)
	flow_rects(&f.l, box_index(&f.l, dom.find_by_id(f.doc, "m")), border_rect(&f.l.boxes[bi]), &list)
	testing.expectf(t, len(list) == 2 && list[1] == Rect{{120, 0}, {220, 100}}, "%v", list)
}

@(test)
multicol_inline_content :: proc(t: ^testing.T) {
	// lines right in the container
	f := mf_load(`<!doctype html><style>body{margin:0;font:20px/20px x} #m{column-count:2;column-gap:0;width:200px;orphans:1;widows:1}</style><div id=m>a<br>b<br>c<br>d</div>`)
	defer mf_unload(f)
	mf_expect(t, f, "m", 0, 0, 200, 40)
	xs := make([dynamic]Rect, 0, 4, context.temp_allocator)
	for &it in f.l.items { if it.kind == .Text { append(&xs, rect_shift(it.rect, f.l.spaces[it.space].shift)) } }
	testing.expectf(t, len(xs) == 4 && xs[2].min.x == 100 && xs[2].min.y == 0 && xs[3].min.y == 20, "%v", xs)
}

@(test)
multicol_incremental :: proc(t: ^testing.T) {
	f := mf_load(`<!doctype html><style>body{margin:0;font:20px/20px x} #m{column-count:2;column-gap:0;width:200px}</style><div id=m>` + SIX + `</div><p id=after style="margin:0">z</p>`)
	defer mf_unload(f)
	testing.expect(t, f.l.frames_on)
	// the text of a line, and the height of a block: the columns again
	cn := dom.find_by_id(f.doc, "b")
	dom.set_attribute(f.doc, cn, "style", "height:100px")
	mf_frame(t, f)
	testing.expect(t, f.l.last_pass == .Incremental, f.l.inc.fallback)
	mf_expect(t, f, "after", 0, 100, 800, 120)
	// a node added
	el := dom.create_element(f.doc, "div")
	dom.append_child(f.doc, dom.find_by_id(f.doc, "m"), el)
	mf_frame(t, f)
	// nothing changed: the same result
	mf_frame(t, f)
	// a resize
	f.vp = {700, 600}
	mf_frame(t, f)
}

@(test)
multicol_style_values :: proc(t: ^testing.T) {
	f := mf_load(`<!doctype html><style>#a{columns:100px 3;column-rule:thin dashed red;column-span:all;column-fill:auto;break-before:page;break-inside:avoid-column;orphans:3;widows:4}</style><div id=a></div>`)
	defer mf_unload(f)
	cs := style.style_of(f.st, dom.find_by_id(f.doc, "a"))
	testing.expect(t, cs.column_count == 3 && cs.column_width.v == 100 && cs.column_span == .All && cs.column_fill == .Auto)
	testing.expect(t, cs.column_rule_style == .Dashed && cs.column_rule_width == 1 && cs.column_rule_color.r == 1)
	testing.expect(t, cs.break_before == .Page && cs.break_inside == .Avoid_Column && cs.orphans == 3 && cs.widows == 4)
}

////////////////////////////////
// Writing modes

@(test)
vertical_block_flow :: proc(t: ^testing.T) {
	// vertical-rl: blocks from the right, each as wide as its line, as high as the container
	f := mf_load(`<!doctype html><style>body{margin:0;font:20px/30px x} #v{writing-mode:vertical-rl;width:200px;height:100px} p{margin:0}</style><div id=v><p id=a>x</p><p id=b>x</p></div>`)
	defer mf_unload(f)
	mf_expect(t, f, "v", 0, 0, 200, 100)
	mf_expect(t, f, "a", 170, 0, 200, 100)
	mf_expect(t, f, "b", 140, 0, 170, 100)
	// vertical-lr: from the left
	g := mf_load(`<!doctype html><style>body{margin:0;font:20px/30px x} #v{writing-mode:vertical-lr;width:200px;height:100px} p{margin:0}</style><div id=v><p id=a>x</p><p id=b>x</p></div>`)
	defer mf_unload(g)
	mf_expect(t, g, "a", 0, 0, 30, 100)
	mf_expect(t, g, "b", 30, 0, 60, 100)
}

@(test)
vertical_box_model_and_logical_properties :: proc(t: ^testing.T) {
	f := mf_load(`<!doctype html><style>body{margin:0;font:20px/30px x}
	#v{writing-mode:vertical-rl;width:300px;height:200px}
	#a{margin-block-start:10px;margin-block-end:20px;margin-inline-start:5px;padding-inline-end:7px;inline-size:100px;block-size:40px;border-inline-start:3px solid}
	#b{margin-top:6px;width:50px}
	#c{min-block-size:60px;inset-inline-start:2px;position:relative}
	</style><div id=v><div id=a>x</div><div id=b>x</div><div id=c></div></div>`)
	defer mf_unload(f)
	a := style.style_of(f.st, dom.find_by_id(f.doc, "a"))
	testing.expect(t, a.margin[.Right].v == 10 && a.margin[.Left].v == 20 && a.margin[.Top].v == 5 && a.padding[.Bottom].v == 7)
	testing.expect(t, a.height.v == 100 && a.width.v == 40 && a.border_width[.Top] == 3)
	// (block-start margin on the right; 3 + 100 + 7 tall)
	mf_expect(t, f, "a", 300 - 10 - 40, 5, 300 - 10, 5 + 3 + 100 + 7)
	// a physical margin in the inline axis, next block after the collapsed margins
	mf_expect(t, f, "b", 300 - 10 - 40 - 20 - 50, 6, 300 - 10 - 40 - 20, 200)
	c := style.style_of(f.st, dom.find_by_id(f.doc, "c"))
	testing.expect(t, c.min_width.v == 60 && c.inset[.Top].v == 2)
	mf_expect(t, f, "c", 300 - 10 - 40 - 20 - 50 - 60, 2, 300 - 10 - 40 - 20 - 50, 202)
}

@(test)
vertical_rtl_and_sideways_logical :: proc(t: ^testing.T) {
	f := mf_load(`<!doctype html><style>
	#a{writing-mode:vertical-lr;direction:rtl;margin-inline-start:1px;margin-block-start:2px}
	#b{writing-mode:sideways-lr;margin-inline-start:1px;margin-block-end:2px}
	#c{direction:rtl;margin-inline-start:1px;padding-inline-end:3px}
	</style><div id=a></div><div id=b></div><div id=c></div>`)
	defer mf_unload(f)
	a := style.style_of(f.st, dom.find_by_id(f.doc, "a"))
	testing.expect(t, a.margin[.Bottom].v == 1 && a.margin[.Left].v == 2)
	b := style.style_of(f.st, dom.find_by_id(f.doc, "b"))
	testing.expect(t, b.margin[.Bottom].v == 1 && b.margin[.Right].v == 2)
	c := style.style_of(f.st, dom.find_by_id(f.doc, "c"))
	testing.expect(t, c.margin[.Right].v == 1 && c.padding[.Left].v == 3, "direction: rtl maps inline-start too")
}

@(test)
vertical_orthogonal_in_horizontal :: proc(t: ^testing.T) {
	// a vertical box in a horizontal parent: as wide as its lines, as high as its text
	f := mf_load(`<!doctype html><style>body{margin:0;font:20px/30px x} #v{writing-mode:vertical-rl}</style><div id=v>xxxx</div><div id=n>y</div>`)
	defer mf_unload(f)
	mf_expect(t, f, "v", 0, 0, 30, 40)
	mf_expect(t, f, "n", 0, 40, 800, 70)
	// a percentage of the container's definite height; the text wraps at the viewport's height otherwise
	g := mf_load(`<!doctype html><style>body{margin:0;font:20px/30px x} #p{height:100px} #v{writing-mode:vertical-rl;height:50%;width:90px}</style><div id=p><div id=v>xxxx</div></div>`)
	defer mf_unload(g)
	mf_expect(t, g, "v", 0, 0, 90, 50)
	// a horizontal box in a vertical parent
	h := mf_load(`<!doctype html><style>body{margin:0;font:20px/30px x} #p{writing-mode:vertical-lr;height:100px;width:400px} #v{writing-mode:horizontal-tb}</style><div id=p><div id=v>xxxx</div><div id=w>y</div></div>`)
	defer mf_unload(h)
	mf_expect(t, h, "v", 0, 0, 40, 30)
	mf_expect(t, h, "w", 40, 0, 70, 100)
}

@(test)
vertical_document :: proc(t: ^testing.T) {
	f := mf_load(`<!doctype html><style>html{writing-mode:vertical-rl} body{margin:0;font:20px/30px x} p{margin:0}</style><p id=a>x</p><p id=b>x</p>`, 800, 600)
	defer mf_unload(f)
	// the root element at the right of the viewport, as high as it
	mf_expect(t, f, "a", 770, 0, 800, 600)
	mf_expect(t, f, "b", 740, 0, 770, 600)
	// many lines overflow to the left
	g := mf_load(`<!doctype html><style>html{writing-mode:vertical-rl} body{margin:0;font:20px/30px x} p{margin:0;inline-size:100px;block-size:500px}</style><p id=a>x</p><p id=b>x</p>`, 800, 600)
	defer mf_unload(g)
	mf_expect(t, g, "a", 300, 0, 800, 100)
	mf_expect(t, g, "b", -200, 0, 300, 100)
}

@(test)
vertical_flex_grid_table :: proc(t: ^testing.T) {
	// flex-direction: row is the inline axis: top to bottom
	f := mf_load(`<!doctype html><style>body{margin:0;font:20px/30px x} #v{writing-mode:vertical-rl;width:200px;height:100px;display:flex} #v div{block-size:40px;inline-size:30px}</style><div id=v><div id=a></div><div id=b></div></div>`)
	defer mf_unload(f)
	mf_expect(t, f, "a", 160, 0, 200, 30)
	mf_expect(t, f, "b", 160, 30, 200, 60)
	// grid columns are in the inline axis
	g := mf_load(`<!doctype html><style>body{margin:0} #v{writing-mode:vertical-lr;width:200px;height:100px;display:grid;grid-template-columns:30px 70px;grid-template-rows:20px 40px}</style><div id=v><div id=a></div><div id=b></div><div id=c></div></div>`)
	defer mf_unload(g)
	mf_expect(t, g, "a", 0, 0, 20, 30)
	mf_expect(t, g, "b", 0, 30, 20, 100)
	mf_expect(t, g, "c", 20, 0, 60, 30)
	// a table: rows are block-size, cells follow in the inline axis
	h := mf_load(`<!doctype html><style>body{margin:0;font:20px/30px x} table{writing-mode:vertical-rl;border-spacing:0;position:absolute;left:0;top:0} td{padding:0;width:50px;height:60px}</style><table id=t><tr><td id=a></td><td id=b></td></tr><tr><td id=c></td><td></td></tr></table>`)
	defer mf_unload(h)
	mf_expect(t, h, "t", 0, 0, 100, 120)
	mf_expect(t, h, "a", 50, 0, 100, 60)
	mf_expect(t, h, "b", 50, 60, 100, 120)
	mf_expect(t, h, "c", 0, 0, 50, 60)
}

@(test)
vertical_text_items :: proc(t: ^testing.T) {
	f := mf_load(`<!doctype html><style>body{margin:0;font:20px/30px x} #v{writing-mode:vertical-rl;width:100px;height:100px}</style><div id=v>xxx xxx</div>`)
	defer mf_unload(f)
	found := 0
	for &it in f.l.items {
		if it.kind != .Text { continue }
		found += 1
		testing.expect(t, .Vertical in it.flags)
		// the first line on the right, 30 px thick, the glyphs an em wide around the central baseline
		testing.expectf(t, it.rect.min.x >= 0 && it.rect.max.x <= 100 && it.rect.max.y - it.rect.min.y >= 30, "%v", it.rect)
		testing.expectf(t, it.rect.max.x - it.rect.min.x == 20, "thick as the font: %v", it.rect)
		testing.expectf(t, it.baseline == it.rect.min.x + 10, "the baseline in the middle: %v %v", it.baseline, it.rect)
	}
	testing.expect(t, found == 1)
	// text-combine-upright: one em along the line
	g := mf_load(`<!doctype html><style>body{margin:0;font:20px/30px x} #v{writing-mode:vertical-rl;width:100px;height:100px} span{text-combine-upright:all}</style><div id=v><span id=s>12345</span>x</div>`)
	defer mf_unload(g)
	mf_expect(t, g, "s", 75, 0, 95, 20)
}

@(test)
vertical_incremental :: proc(t: ^testing.T) {
	f := mf_load(`<!doctype html><style>body{margin:0;font:20px/30px x} #v{writing-mode:vertical-rl;width:300px;height:100px} p{margin:0}</style><div id=v><p id=a>x</p><p id=b>xx</p><div style="writing-mode:horizontal-tb"><p id=c>x</p></div></div><p id=z>z</p>`)
	defer mf_unload(f)
	// a line more
	dom.set_attribute(f.doc, dom.find_by_id(f.doc, "a"), "style", "block-size:60px")
	mf_frame(t, f)
	testing.expect(t, f.l.last_pass == .Incremental, f.l.inc.fallback)
	mf_expect(t, f, "b", 300 - 60 - 30, 0, 300 - 60, 100)
	// outside of the vertical box: what is inside it is taken from its cache, still right
	dom.set_attribute(f.doc, dom.find_by_id(f.doc, "z"), "style", "margin-top:10px")
	mf_frame(t, f)
	mf_expect(t, f, "b", 300 - 60 - 30, 0, 300 - 60, 100)
	f.vp = {700, 500}
	mf_frame(t, f)
	mf_expect(t, f, "b", 300 - 60 - 30, 0, 300 - 60, 100)
	// columns in a vertical box
	g := mf_load(`<!doctype html><style>body{margin:0;font:20px/20px x} #m{writing-mode:vertical-rl;column-count:2;column-gap:0;width:80px;height:100px;orphans:1;widows:1}</style><div id=m><div id=a>a</div><div id=b>b</div><div id=c>c</div><div id=d>d</div></div>`)
	defer mf_unload(g)
	// a column is a band of the inline axis: the first on top, the second under it
	mf_expect(t, g, "a", 60, 0, 80, 50)
	mf_expect(t, g, "c", 60, 50, 80, 100)
	dom.set_attribute(g.doc, dom.find_by_id(g.doc, "a"), "class", "k")
	mf_frame(t, g)
}

@(test)
vertical_anchor_positioning :: proc(t: ^testing.T) {
	// physical sides are physical; in vertical-rl block-end is on the left, inline-start on top
	f := mf_load(`<!doctype html><style>body{margin:0}
	#cb{writing-mode:vertical-rl;position:relative;width:400px;height:300px}
	#a{anchor-name:--a;margin-block-start:100px;margin-inline-start:50px;inline-size:40px;block-size:20px}
	.q{position:absolute;position-anchor:--a;width:10px;height:10px}
	#p{left:anchor(right);top:anchor(bottom)}
	#s{left:anchor(end);top:anchor(start)}
	#r{position-area:block-end inline-end}
	#d{width:anchor-size(block);height:anchor-size(inline)}
	</style><div id=cb><div id=a></div><div class=q id=p></div><div class=q id=s></div><div class=q id=r></div><div class=q id=d style="left:0;top:0"></div></div>`)
	defer mf_unload(f)
	// the anchor: 100 from the right, 20 wide, 50 down, 40 high
	mf_expect(t, f, "a", 280, 50, 300, 90)
	mf_expect(t, f, "p", 300, 90, 310, 100)
	// x's end is the block-end: the anchor's left; y's start: its top
	mf_expect(t, f, "s", 280, 50, 290, 60)
	// block-end: left of the anchor, inline-end: under it; against those edges
	mf_expect(t, f, "r", 270, 90, 280, 100)
	// sizes: block is x here
	mf_expect(t, f, "d", 0, 0, 20, 40)
}

@(test)
multicol_anchor_and_static_position :: proc(t: ^testing.T) {
	// an anchor in the second column; a box positioned against the container is not in the flow; a static position shows where its place shows
	f := mf_load(`<!doctype html><style>body{margin:0;font:20px/20px x} #m{column-count:2;column-gap:0;width:200px;position:relative} #q{position:absolute;position-anchor:--a;left:anchor(left);top:anchor(top);width:5px;height:5px} #d{anchor-name:--a} #abs{position:absolute;right:0;top:0;width:7px;height:7px} #st{position:absolute;width:3px;height:3px}</style><div id=m><div id=a>a</div><div id=b>b</div><div id=c>c</div><div id=d>d<span id=st></span></div></div><div id=q></div><style>#m{}</style>`)
	defer mf_unload(f)
	mf_expect(t, f, "d", 100, 20, 200, 40)
	mf_expect(t, f, "q", 100, 20, 105, 25)
}

@(test)
multicol_nested_in_rows :: proc(t: ^testing.T) {
	// the outer container's columns are 100 high; the inner one starts 60 down: a row of two columns 40 high, then a row in the next outer column
	f := mf_load(`<!doctype html><style>body{margin:0;font:20px/20px x} #o{columns:2;column-gap:0;column-fill:auto;width:400px;height:100px;orphans:1;widows:1} #i{columns:2;column-gap:0;orphans:1;widows:1}</style><div id=o><div style="height:60px"></div><div id=i><div id=a>a</div><div id=b>b</div><div id=c>c</div><div id=d>d</div><div id=e>e</div><div id=f>f</div></div></div>`)
	defer mf_unload(f)
	mf_expect(t, f, "a", 0, 60, 100, 80)
	mf_expect(t, f, "b", 0, 80, 100, 100)
	mf_expect(t, f, "c", 100, 60, 200, 80)
	mf_expect(t, f, "d", 100, 80, 200, 100)
	// the rest in the next outer column, balanced
	mf_expect(t, f, "e", 200, 0, 300, 20)
	mf_expect(t, f, "f", 300, 0, 400, 20)
	el := dom.find_by_id(f.doc, "b")
	dom.set_attribute(f.doc, el, "class", "changed")
	mf_frame(t, f)
	mf_expect(t, f, "f", 300, 0, 400, 20)
}

@(test)
multicol_flex_item_style_set_later :: proc(t: ^testing.T) {
	// a paragraph as a flex item, centered, that a script gives columns (MDN's examples)
	f := mf_load(`<!doctype html><style>body{margin:0;font:20px/20px x} section{display:flex;align-items:center;justify-content:center;height:300px;width:300px} p{margin:0}</style><section><p id=p>aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa</p></section>`)
	defer mf_unload(f)
	dom.set_attribute(f.doc, dom.find_by_id(f.doc, "p"), "style", "column-count:2;column-gap:20px")
	mf_frame(t, f)
	xs: [dynamic]f32
	defer delete(xs)
	v := view_make(&f.l, f.vp, 0, cull = false)
	seen_first, seen_second: bool
	for &it in f.l.items {
		if it.kind != .Text { continue }
		x := it.rect.min.x + v.offsets[it.space].x
		testing.expect(t, it.clip == NONE || !rect_empty(v.clips[it.clip]), "the clip of a column leaves something")
		if x < 100 { seen_first = true } else { seen_second = true }
	}
	testing.expectf(t, seen_first && seen_second, "lines in both columns: %v %v", seen_first, seen_second)
}

_ :: base.NIL_HANDLE
_ :: fmt.tprintf
