package layout

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:dom"
import "wb:html"
import "wb:style"

// Grid layout tests, with the measurements of layout_test.odin: every character is 0.5 em wide (5px at font-size 10px).
// Expected values are computed by hand in the comments.

@(private = "file")
Gx :: struct {
	doc: ^dom.Document,
	eng: ^style.Engine,
	st:  ^style.Styled,
	set: Settings,
	l:   Layout,
	vp:  Vec2,
}

@(private = "file")
g_font :: proc(user: rawptr, families: []string, weight: u16, italic: bool) -> Font { return Font(1) }
@(private = "file")
g_width :: proc(user: rawptr, f: Font, size: f32, text: string) -> f32 { return 0.5 * size * f32(rune_count(text)) }
@(private = "file")
g_metrics :: proc(user: rawptr, f: Font, size: f32) -> Font_Metrics { return {ascent = 0.8 * size, descent = 0.2 * size, x_height = 0.5 * size} }

@(private = "file")
g_load :: proc(src: string, vw: f32 = 800, vh: f32 = 600, set: ^Settings = nil) -> ^Gx {
	f := new(Gx)
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	ss := style.settings_default()
	f.eng = style.engine_make(ss)
	style.settings_destroy(&ss)
	style.sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = style.compute_styles(f.eng, f.doc, {})
	f.set = set != nil ? set^ : settings_default()
	f.vp = {vw, vh}
	run(&f.l, Input{doc = f.doc, styled = f.st, settings = &f.set, text = {font = g_font, width = g_width, metrics = g_metrics}, viewport = f.vp, scale = 1, band_h = 256})
	return f
}

@(private = "file")
g_unload :: proc(f: ^Gx) {
	destroy(&f.l)
	style.styled_destroy(f.st)
	style.engine_destroy(f.eng)
	dom.document_destroy(f.doc)
	free(f)
	free_all(context.temp_allocator)
}

@(private = "file")
g_rect :: proc(f: ^Gx, id: string) -> Rect {
	r, ok := box_of(&f.l, dom.find_by_id(f.doc, id), f.vp, 0)
	if !ok { return Rect{{-1, -1}, {-1, -1}} }
	return r.border
}

@(private = "file")
g_near :: proc(a, b: f32) -> bool { return math.abs(a - b) <= 0.02 }

@(private = "file")
expect_box :: proc(t: ^testing.T, f: ^Gx, id: string, x0, y0, x1, y1: f32, loc := #caller_location) {
	r := g_rect(f, id)
	ok := g_near(r.min.x, x0) && g_near(r.min.y, y0) && g_near(r.max.x, x1) && g_near(r.max.y, y1)
	testing.expectf(t, ok, "%s: got (%v, %v)-(%v, %v), want (%v, %v)-(%v, %v)", id, r.min.x, r.min.y, r.max.x, r.max.y, x0, y0, x1, y1, loc = loc)
}

@(test)
grid_fixed_fr_gaps :: proc(t: ^testing.T) {
	f := g_load(`<body style="margin:0;font-size:10px;line-height:10px">
<div id=g style="display:grid;grid-template-columns:100px 1fr 2fr;grid-template-rows:50px auto;width:400px;column-gap:10px;row-gap:5px">
<div id=a></div><div id=b></div><div id=c></div><div id=d>xx</div></div>
<div id=after style="height:1px"></div></body>`)
	defer g_unload(f)
	// 400 - 100 - 2 gaps = 280 for 3fr: 93.33 and 186.67; the auto row is the text's 10px
	expect_box(t, f, "a", 0, 0, 100, 50)
	expect_box(t, f, "b", 110, 0, 203.333, 50)
	expect_box(t, f, "c", 213.333, 0, 400, 50)
	expect_box(t, f, "d", 0, 55, 100, 65)
	expect_box(t, f, "g", 0, 0, 400, 65)
	expect_box(t, f, "after", 0, 65, 800, 66)
}

@(test)
grid_fr_with_min_content :: proc(t: ^testing.T) {
	f := g_load(`<body style="margin:0;font-size:10px;line-height:10px">
<div style="display:grid;grid-template-columns:1fr 1fr;width:100px"><div id=a>xxxxxxxxxxxx</div><div id=b></div></div>
<div style="display:grid;grid-template-columns:minmax(0,1fr) 1fr;width:100px"><div id=c>xxxxxxxxxxxx</div><div id=d></div></div>
<div style="display:grid;grid-template-columns:1fr 3fr;width:100px"><div id=e style="min-width:0">xxxxxxxxxxxx</div><div id=h></div></div>
</body>`)
	defer g_unload(f)
	// 1fr = minmax(auto, 1fr): the 60px word is the first track's minimum; the fr is then (100 - 60) / 1
	expect_box(t, f, "a", 0, 0, 60, 10)
	expect_box(t, f, "b", 60, 0, 100, 10)
	// minmax(0, 1fr): the word overflows, the tracks split evenly
	expect_box(t, f, "c", 0, 10, 50, 20)
	expect_box(t, f, "d", 50, 10, 100, 20)
	// min-width: 0 turns the automatic minimum off: 25 / 75
	expect_box(t, f, "e", 0, 20, 25, 30)
	expect_box(t, f, "h", 25, 20, 100, 30)
}

@(test)
grid_auto_tracks_stretch :: proc(t: ^testing.T) {
	f := g_load(`<body style="margin:0;font-size:10px;line-height:10px">
<div style="display:grid;grid-template-columns:auto auto;width:300px"><div id=a>xx</div><div id=b>xxxx</div></div>
<div style="display:grid;grid-template-columns:auto auto;width:300px;justify-content:start"><div id=c>xx</div><div id=d>xxxx</div></div>
<div style="display:grid;grid-template-columns:auto auto;width:30px"><div id=e>xx xx xx</div><div id=h>xx xx</div></div>
</body>`)
	defer g_unload(f)
	// max-content 10 + 20, then the 270px left stretch both auto tracks: 145 + 155
	expect_box(t, f, "a", 0, 0, 145, 10)
	expect_box(t, f, "b", 145, 0, 300, 10)
	// justify-content: start: no stretching
	expect_box(t, f, "c", 0, 10, 10, 20)
	expect_box(t, f, "d", 10, 20 - 10, 30, 20)
	// too narrow: base sizes are the min-content widths 10 + 10; the 10px left go to the tracks evenly up to their
	// max-content limits (40 and 25): 15 + 15
	// (3 lines, 2 lines: the row is 30 tall and both are stretched to it)
	expect_box(t, f, "e", 0, 20, 15, 50)
	expect_box(t, f, "h", 15, 20, 30, 50)
}

@(test)
grid_auto_placement_sparse_dense :: proc(t: ^testing.T) {
	f := g_load(`<body style="margin:0">
<div style="display:grid;grid-template-columns:repeat(3,10px);grid-auto-rows:10px">
<div id=a style="grid-column:span 2"></div><div id=b style="grid-column:span 2"></div><div id=c></div><div id=d></div></div>
<div style="display:grid;grid-template-columns:repeat(3,10px);grid-auto-rows:10px;grid-auto-flow:dense">
<div id=a2 style="grid-column:span 2"></div><div id=b2 style="grid-column:span 2"></div><div id=c2></div><div id=d2></div></div>
<div style="display:grid;grid-template-rows:repeat(2,10px);grid-auto-columns:10px;grid-auto-flow:column">
<div id=a3></div><div id=b3 style="grid-row:span 2"></div><div id=c3></div></div>
</body>`)
	defer g_unload(f)
	// sparse: b does not fit after a, so it starts the second row; c follows it; d wraps
	expect_box(t, f, "a", 0, 0, 20, 10)
	expect_box(t, f, "b", 0, 10, 20, 20)
	expect_box(t, f, "c", 20, 10, 30, 20)
	expect_box(t, f, "d", 0, 20, 10, 30)
	// dense: c goes back to the hole after a, d to the one after b
	expect_box(t, f, "a2", 0, 30, 20, 40)
	expect_box(t, f, "b2", 0, 40, 20, 50)
	expect_box(t, f, "c2", 20, 30, 30, 40)
	expect_box(t, f, "d2", 20, 40, 30, 50)
	// column flow: a3 (0,0); b3 spans both rows: next column; c3 below a3? no, sparse: after b3
	expect_box(t, f, "a3", 0, 50, 10, 60)
	expect_box(t, f, "b3", 10, 50, 20, 70)
	expect_box(t, f, "c3", 20, 50, 30, 60)
}

@(test)
grid_definite_and_locked :: proc(t: ^testing.T) {
	f := g_load(`<body style="margin:0">
<div style="display:grid;grid-template-columns:repeat(3,10px);grid-auto-rows:10px;justify-content:start">
<div id=x style="grid-row:2;grid-column:2"></div>
<div id=y style="grid-row:1"></div>
<div id=z style="grid-row:1"></div>
<div id=w style="grid-column:2"></div>
<div id=v></div>
<div id=neg style="grid-column:-2;grid-row:4"></div>
<div id=late style="grid-column:5"></div>
</div></body>`)
	defer g_unload(f)
	expect_box(t, f, "x", 10, 0 + 10, 20, 20)
	expect_box(t, f, "y", 0, 0, 10, 10)                // locked to row 1
	expect_box(t, f, "z", 10, 0, 20, 10)               // after y in that row
	// column 2, auto row: rows 1 and 2 are taken in that column
	expect_box(t, f, "w", 10, 20, 20, 30)
	// the cursor stays in row 3 after w
	expect_box(t, f, "v", 20, 20, 30, 30)
	// -2 is the last explicit column; column 5 adds implicit (auto, empty: 0 wide) columns 4 and 5, and still fits
	// in row 3 after v
	expect_box(t, f, "neg", 20, 30, 30, 40)
	expect_box(t, f, "late", 30, 20, 30, 30)
}

@(test)
grid_areas_and_names :: proc(t: ^testing.T) {
	f := g_load(`<body style="margin:0;font-size:10px;line-height:10px">
<div style="display:grid;grid-template-areas:'h h' 's m' 'f f';grid-template-columns:100px 1fr;grid-template-rows:20px 50px 30px;width:400px">
<div id=hd style="grid-area:h"></div><div id=sd style="grid-area:s"></div><div id=mn style="grid-area:m"></div><div id=ft style="grid-area:f"></div>
<div id=over style="grid-column:m-start / m-end;grid-row:h"></div>
</div>
<div style="display:grid;grid-template-columns:[a] 50px [b c] 50px [d];justify-content:start;grid-auto-columns:auto">
<div id=bd style="grid-column:b / d"></div><div id=cc style="grid-column:c;grid-row:2"></div>
<div id=nope style="grid-column:foo;grid-row:3">xx</div><div id=sp style="grid-column:a / span d;grid-row:4"></div>
</div></body>`)
	defer g_unload(f)
	expect_box(t, f, "hd", 0, 0, 400, 20)
	expect_box(t, f, "sd", 0, 20, 100, 70)
	expect_box(t, f, "mn", 100, 20, 400, 70)
	expect_box(t, f, "ft", 0, 70, 400, 100)
	expect_box(t, f, "over", 100, 0, 400, 20)          // implicit lines from the areas
	expect_box(t, f, "bd", 50, 100, 100, 100)
	expect_box(t, f, "cc", 50, 100, 100, 100)
	// no line named foo: the first implicit line after the explicit grid (line 4): an empty auto column, then its own
	expect_box(t, f, "nope", 100, 100, 110, 110)
	expect_box(t, f, "sp", 0, 110, 100, 110)           // span to the next line named d
}

@(test)
grid_auto_fill_fit :: proc(t: ^testing.T) {
	f := g_load(`<body style="margin:0">
<div style="display:grid;grid-template-columns:repeat(auto-fill,100px);column-gap:10px;width:330px"><div id=a></div><div id=b></div></div>
<div style="display:grid;grid-template-columns:repeat(auto-fit,100px);column-gap:10px;width:330px;justify-content:center"><div id=c></div><div id=d></div></div>
<div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(100px,1fr));column-gap:10px;width:330px"><div id=e></div><div id=h></div></div>
<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(100px,1fr));column-gap:10px;width:330px"><div id=i></div><div id=j></div></div>
<div style="display:grid;grid-template-columns:[s] repeat(auto-fill,[r] 50px) [e];width:160px"><div id=k style="grid-column:r 3"></div><div id=m style="grid-column:e"></div></div>
</body>`)
	defer g_unload(f)
	// 3 tracks of 100 fit in 330 with two 10px gaps
	expect_box(t, f, "a", 0, 0, 100, 0)
	expect_box(t, f, "b", 110, 0, 210, 0)
	// auto-fit: the empty third track collapses with its gap: 210 centered in 330
	expect_box(t, f, "c", 60, 0, 160, 0)
	expect_box(t, f, "d", 170, 0, 270, 0)
	// three flexible tracks: (330 - 20) / 3
	expect_box(t, f, "e", 0, 0, 103.333, 0)
	expect_box(t, f, "h", 113.333, 0, 216.667, 0)
	// auto-fit: two tracks share 330 - 10
	expect_box(t, f, "i", 0, 0, 160, 0)
	expect_box(t, f, "j", 170, 0, 330, 0)
	// 3 repetitions of 50 in 160; the third line named r starts the third track; e is the last line: m is in an
	// implicit auto track, stretched to the 10px left
	expect_box(t, f, "k", 100, 0, 150, 0)
	expect_box(t, f, "m", 150, 0, 160, 0)
}

@(test)
grid_minmax_fit_content :: proc(t: ^testing.T) {
	f := g_load(`<body style="margin:0;font-size:10px;line-height:10px">
<div style="display:grid;grid-template-columns:fit-content(40px) fit-content(100px) minmax(30px,50px);width:400px">
<div id=a>xxxx xxxx xxxx</div><div id=b>xxxx xxxx xxxx</div><div id=c></div></div>
<div style="display:grid;grid-template-columns:min-content max-content;justify-content:start">
<div id=d>xxxx xxxx</div><div id=e>xxxx xxxx</div></div>
</body>`)
	defer g_unload(f)
	// limits: min(70, 40), min(70, 100), 50; the free space takes every track to its limit. a wraps to 3 lines.
	expect_box(t, f, "a", 0, 0, 40, 30)
	expect_box(t, f, "b", 40, 0, 110, 30)
	expect_box(t, f, "c", 110, 0, 160, 30)
	expect_box(t, f, "d", 0, 30, 20, 50)
	expect_box(t, f, "e", 20, 30, 65, 50)
}

@(test)
grid_spanning_items :: proc(t: ^testing.T) {
	f := g_load(`<body style="margin:0;font-size:10px;line-height:10px">
<div style="display:grid;grid-template-columns:auto auto 30px;justify-content:start">
<div id=a style="grid-column:1/4">xxxxxxxxxxxxxxxxxxxx</div><div id=b>xx</div><div id=c>xxxx</div></div>
</body>`)
	defer g_unload(f)
	// the 100px word spans 2 auto tracks (10 and 20 from their own items) and a fixed 30px one: the 40px missing are
	// shared equally by the auto tracks, as base sizes (their min-content) and growth limits: 30 + 40 + 30
	expect_box(t, f, "a", 0, 0, 100, 10)
	expect_box(t, f, "b", 0, 10, 30, 20)
	expect_box(t, f, "c", 30, 10, 70, 20)
}

@(test)
grid_alignment :: proc(t: ^testing.T) {
	f := g_load(`<body style="margin:0;font-size:10px;line-height:10px">
<div style="display:grid;grid-template-columns:50px 50px;grid-template-rows:30px;width:200px;height:100px;justify-content:space-between;align-content:end">
<div id=a></div><div id=b></div></div>
<div style="display:grid;grid-template-columns:100px 100px;grid-template-rows:30px;justify-items:center;align-items:end">
<div id=c style="width:20px;height:10px"></div><div id=d style="justify-self:end;align-self:start;width:10px;height:10px"></div></div>
<div style="display:grid;grid-template-columns:100px;grid-template-rows:40px">
<div id=e style="width:20px;height:10px;margin:auto"></div></div>
<div style="display:grid;grid-template-columns:100px 100px;align-items:baseline">
<div id=f1 style="font-size:20px;line-height:20px">x</div><div id=f2>x</div></div>
<div style="display:grid;grid-template-columns:50px 50px;grid-template-rows:20px 20px;height:100px;align-content:space-evenly;justify-content:space-around;width:300px">
<div id=g1></div><div id=g2 style="grid-row:2;grid-column:2"></div></div>
</body>`)
	defer g_unload(f)
	expect_box(t, f, "a", 0, 70, 50, 100)
	expect_box(t, f, "b", 150, 70, 200, 100)
	expect_box(t, f, "c", 40, 120, 60, 130)
	expect_box(t, f, "d", 190, 100, 200, 110)
	expect_box(t, f, "e", 40, 145, 60, 155)                // auto margins center it in its 100x40 area
	// baseline: f1's baseline at 16 (0.8 em of 20px), f2's at 8: f2 moves down 8
	expect_box(t, f, "f1", 0, 170, 100, 190)
	expect_box(t, f, "f2", 100, 178, 200, 188)
	// space-evenly: 60px free over 3 gaps of 20; space-around: 200px over 2 tracks: 50 on each side of each
	expect_box(t, f, "g1", 50, 190 + 20, 100, 230)
	expect_box(t, f, "g2", 200, 190 + 60, 250, 270)
}

@(test)
grid_absolute_items :: proc(t: ^testing.T) {
	f := g_load(`<body style="margin:0">
<div style="display:grid;position:relative;grid-template-columns:100px 100px;grid-template-rows:50px 50px;width:300px;height:200px;padding:10px">
<div id=ab style="position:absolute;grid-column:2/3;grid-row:2/3;left:0;top:0;right:0;bottom:0"></div>
<div id=ab4 style="position:absolute;grid-column:2;grid-row:2;inset:0"></div>
<div id=ab2 style="position:absolute;grid-column:2/auto;top:0;right:0;width:10px;height:10px"></div>
<div id=ab3 style="position:absolute;grid-area:1/1/3/3;inset:0"></div>
<div id=st style="position:absolute;width:5px;height:5px"></div>
<div id=it style="grid-column:2"></div>
</div></body>`)
	defer g_unload(f)
	expect_box(t, f, "ab", 110, 60, 210, 110)
	expect_box(t, f, "ab4", 110, 60, 320, 220)             // `grid-column: 2` leaves the end auto: the padding edge
	expect_box(t, f, "ab2", 310, 0, 320, 10)               // end line auto: the padding edge
	expect_box(t, f, "ab3", 10, 10, 210, 110)
	expect_box(t, f, "st", 10, 10, 15, 15)                 // static position: the content box start
	expect_box(t, f, "it", 110, 10, 210, 60)
}

@(test)
grid_with_flex :: proc(t: ^testing.T) {
	f := g_load(`<body style="margin:0;font-size:10px;line-height:10px">
<div style="display:flex"><div id=gi style="display:grid;grid-template-columns:30px 40px;column-gap:5px"><div style="height:10px"></div></div><div id=f2 style="flex:1 1 0"></div></div>
<div style="display:grid;grid-template-columns:200px"><div id=fl style="display:flex"><div id=f3 style="width:30px;height:5px"></div><div id=f4 style="flex:1"></div></div></div>
<div style="display:flex;width:100px"><div id=f5 style="flex:1 1 0;min-width:0">xxxxxxxxxxxxxxxxxxxxxxxxxxxx</div><div id=f6 style="flex:1 1 0"></div></div>
</body>`)
	defer g_unload(f)
	// the grid's max-content width as a flex base size: 30 + 5 + 40
	expect_box(t, f, "gi", 0, 0, 75, 10)
	expect_box(t, f, "f2", 75, 0, 800, 10)
	expect_box(t, f, "fl", 0, 10, 200, 15)
	expect_box(t, f, "f4", 30, 10, 200, 15)
	// flex: 1 1 0 parses (basis 0) and min-width: 0 lets the long word overflow: 50 / 50
	r5 := g_rect(f, "f5")
	testing.expectf(t, g_near(r5.max.x - r5.min.x, 50), "min-width: 0 flex item: %v", r5)
}

@(test)
grid_intrinsic_contribution :: proc(t: ^testing.T) {
	f := g_load(`<body style="margin:0;font-size:10px;line-height:10px">
<div><span id=ig style="display:inline-grid;grid-template-columns:auto auto"><span>xxxx</span><span>xx</span></span></div>
<div><div id=fr style="display:inline-grid;grid-template-columns:1fr 1fr"><div>xxxx xxxx</div><div>xx</div></div></div>
<div style="width:min-content"><div id=mn style="display:grid;grid-template-columns:1fr 1fr"><div>xxxx xxxx</div><div>xx</div></div></div>
<div style="display:grid;grid-template-columns:auto 1fr;width:400px"><div id=nest style="display:grid;grid-template-columns:repeat(2,40px);column-gap:4px"></div><div id=n2></div></div>
</body>`)
	defer g_unload(f)
	expect_box(t, f, "ig", 0, 0, 30, 10)
	// max-content with flexible tracks: the fr is the largest max-content contribution (45): 2 x 45
	r := g_rect(f, "fr")
	testing.expectf(t, g_near(r.max.x - r.min.x, 90), "inline-grid with fr tracks: %v", r)
	// min-content: the fr is 0, tracks keep their minimum (the min-content widths 20 and 10)
	r = g_rect(f, "mn")
	testing.expectf(t, g_near(r.max.x - r.min.x, 30), "min-content grid: %v", r)
	expect_box(t, f, "n2", 84, 40, 400, 40)
}

@(test)
grid_order_and_paint :: proc(t: ^testing.T) {
	f := g_load(`<body style="margin:0">
<div style="display:grid;grid-template-columns:repeat(3,10px);grid-auto-rows:10px">
<div id=o1 style="order:2"></div><div id=o2></div><div id=o3 style="order:-1;z-index:1;background:red"></div></div>
</body>`)
	defer g_unload(f)
	expect_box(t, f, "o3", 0, 0, 10, 10)
	expect_box(t, f, "o2", 10, 0, 20, 10)
	expect_box(t, f, "o1", 20, 0, 30, 10)
	// z-index on an unpositioned grid item makes a stacking context
	bi := box_index(&f.l, dom.find_by_id(f.doc, "o3"))
	testing.expect(t, bi != NONE && .Stacking in f.l.boxes[bi].flags, "z-index creates a stacking context")
}

@(test)
grid_rtl_and_overflow :: proc(t: ^testing.T) {
	f := g_load(`<body style="margin:0">
<div style="display:grid;grid-template-columns:50px 100px;width:300px;direction:rtl;grid-auto-rows:10px"><div id=r1></div><div id=r2></div></div>
<div style="display:grid;grid-template-columns:200px 200px;width:300px;overflow:auto;grid-auto-rows:10px"><div id=o1></div><div id=o2></div></div>
</body>`)
	defer g_unload(f)
	expect_box(t, f, "r1", 250, 0, 300, 10)
	expect_box(t, f, "r2", 150, 0, 250, 10)
	expect_box(t, f, "o2", 200, 10, 400, 20)
}

@(test)
grid_hostile :: proc(t: ^testing.T) {
	{
		f := g_load(`<body style="margin:0"><div style="display:grid;grid-template-columns:repeat(100000,1fr);width:800px">
<div id=a></div><div id=b style="grid-column:-1"></div><div id=c style="grid-row:10000000;grid-column:span 100000"></div></div></body>`)
		defer g_unload(f)
		// the parser keeps 10000 repetitions: 0.08px tracks
		r := g_rect(f, "a")
		testing.expectf(t, g_near(r.max.x - r.min.x, 0.08), "track of repeat(100000, 1fr): %v", r)
		r = g_rect(f, "b")
		testing.expectf(t, math.abs(r.min.x - 799.92) < 0.2, "last column: %v", r)   // f32 sums of 10000 tracks
		testing.expect(t, g_rect(f, "c").min.x >= 0, "clamped lines still lay out")
	}
	{
		sb := strings.builder_make(context.temp_allocator)
		strings.write_string(&sb, `<body style="margin:0"><div id=g style="display:grid;grid-template-columns:repeat(10,1fr);grid-auto-rows:2px">`)
		for i in 0 ..< 100_000 {
			if i == 99_999 { strings.write_string(&sb, `<i id=last></i>`) } else { strings.write_string(&sb, "<i></i>") }
		}
		strings.write_string(&sb, "</div></body>")
		t0 := time.tick_now()
		f := g_load(strings.to_string(sb))
		defer g_unload(f)
		ms := time.duration_milliseconds(time.tick_since(t0))
		// 10000 rows of 2px; the last item ends the last row
		expect_box(t, f, "last", 720, 19998, 800, 20000)
		fmt.printfln("grid: 100000 items laid out in %.1f ms (parse and style included), layout %v", ms, f.l.stats)
	}
	{
		set := settings_default()
		set.grid_max_items = 1000
		sb := strings.builder_make(context.temp_allocator)
		strings.write_string(&sb, `<body style="margin:0"><div style="display:grid;grid-auto-rows:1px">`)
		for _ in 0 ..< 1500 { strings.write_string(&sb, "<i></i>") }
		strings.write_string(&sb, `<i id=over></i></div></body>`)
		f := g_load(strings.to_string(sb), set = &set)
		defer g_unload(f)
		expect_box(t, f, "over", 0, 0, 0, 0)               // past layout.grid.max_items: no box
	}
}

@(test)
grid_subgrid :: proc(t: ^testing.T) {
	f := g_load(`<body style="margin:0;font-size:10px;line-height:10px">
<div style="display:grid;grid-template-columns:auto 1fr auto;width:300px">
<div id=s1 style="display:grid;grid-column:1/4;grid-template-columns:subgrid;padding-left:5px"><div id=a>xxxx</div><div id=b></div><div id=c>xx</div></div>
<div id=s2 style="display:grid;grid-column:1/4;grid-template-columns:subgrid [x] [y] [z]"><div id=d>xxxxxx</div><div id=e style="grid-column:y"></div><div id=f>xxxx</div></div>
</div>
<div style="display:grid;grid-template-rows:auto auto;grid-template-columns:100px 100px">
<div id=r1 style="display:grid;grid-row:1/3;grid-template-rows:subgrid"><div id=g1>x</div><div id=g2>x<br>x<br>x</div></div>
<div id=h1>x<br>x</div>
</div></body>`)
	defer g_unload(f)
	// the first column fits a (20 + the subgrid's 5px padding) and d (30): 30; the last fits c and f: 20; 1fr the rest
	expect_box(t, f, "s1", 0, 0, 300, 10)
	expect_box(t, f, "a", 5, 0, 30, 10)
	expect_box(t, f, "b", 30, 0, 280, 10)
	expect_box(t, f, "c", 280, 0, 300, 10)
	expect_box(t, f, "d", 0, 10, 30, 20)
	expect_box(t, f, "e", 30, 10, 280, 20)           // the subgrid's own line name y
	expect_box(t, f, "f", 280, 10, 300, 20)
	// subgridded rows: row 1 fits g1 (10) and h1 (20), row 2 fits g2 (30)
	expect_box(t, f, "r1", 0, 20, 100, 70)
	expect_box(t, f, "g1", 0, 20, 100, 40)
	expect_box(t, f, "g2", 0, 40, 100, 70)
	expect_box(t, f, "h1", 100, 20, 200, 40)
}

// Layout time of a 10000-item grid against a flex container with the same items (the same order of magnitude).
@(test)
grid_vs_flex_timing :: proc(t: ^testing.T) {
	make_page :: proc(container: string) -> string {
		sb := strings.builder_make(context.temp_allocator)
		strings.write_string(&sb, `<body style="margin:0;font-size:10px;line-height:10px"><div style="`)
		strings.write_string(&sb, container)
		strings.write_string(&sb, `">`)
		for i in 0 ..< 10_000 { fmt.sbprintf(&sb, "<div>item %d text</div>", i) }
		strings.write_string(&sb, "</div></body>")
		return strings.to_string(sb)
	}
	grid := g_load(make_page("display:grid;grid-template-columns:repeat(auto-fill,minmax(120px,1fr));gap:4px"))
	gl := grid.l.stats[1]
	g_unload(grid)
	flex := g_load(make_page("display:flex;flex-wrap:wrap;gap:4px"))
	fl := flex.l.stats[1]
	g_unload(flex)
	fmt.printfln("10000 items: grid layout %.2f ms, flex layout %.2f ms", gl, fl)
	testing.expectf(t, gl < max(fl * 5, 20), "grid layout %.2f ms vs flex %.2f ms", gl, fl)
}
