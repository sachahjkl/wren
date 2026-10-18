package style

import "core:testing"
import "wb:dom"
import "wb:html"

@(private = "file")
Pc :: struct {
	doc: ^dom.Document,
	eng: ^Engine,
	st:  ^Styled,
	tl:  ^Timeline,
}

@(private = "file")
pc_open :: proc(src: string) -> Pc {
	f: Pc
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	s := settings_default()
	s.anim_mode = .Normal
	f.eng = engine_make(s)
	settings_destroy(&s)
	sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = compute_styles(f.eng, f.doc, {})
	f.tl = timeline_make(f.eng)
	timeline_restyled(f.tl, f.doc, nil, f.st, 0)
	timeline_tick(f.tl, f.doc, f.st, 0)
	return f
}

@(private = "file")
pc_close :: proc(f: ^Pc) {
	timeline_destroy(f.tl, f.st)
	styled_destroy(f.st)
	engine_destroy(f.eng)
	dom.document_destroy(f.doc)
}

@(private = "file")
el :: proc(f: ^Pc, id: string) -> ^Computed { return style_of(f.st, dom.find_by_id(f.doc, id)) }

@(test)
paint_only_tiers :: proc(t: ^testing.T) {
	f := pc_open(`<div id=a style="color:red;background:blue;transform:rotate(10deg);opacity:.5;width:10px"></div>
<div id=b style="color:green;background:white;transform:rotate(80deg);opacity:.9;width:10px;box-shadow:0 0 3px red;transition:color 1s"></div>
<div id=c style="color:red;width:20px;transform:rotate(10deg);opacity:.5"></div>
<div id=d style="color:red;background:blue;opacity:.5;width:10px"></div>
<div id=e style="color:red;background:blue;transform:rotate(10deg);width:10px"></div>`)
	defer pc_close(&f)
	a, b, c, d, e := el(&f, "a"), el(&f, "b"), el(&f, "c"), el(&f, "d"), el(&f, "e")
	testing.expect(t, layout_equal(a, b), "colors, backgrounds, shadows, transform values, opacity values, transitions: paint-only")
	testing.expect(t, !layout_equal(a, c), "a width is not")
	testing.expect(t, !layout_equal(a, d), "transform none against some: a new stacking context and containing block")
	testing.expect(t, !layout_equal(a, e), "opacity 1 against below 1: a new stacking context")
	testing.expect(t, prop_tier(.Transform) == .Paint && prop_tier(.Width) == .Layout && prop_tier(.Visibility) == .Layout)
	testing.expect(t, paint_only(ps_of(.Color, .Opacity, .Rotate)) && !paint_only(ps_of(.Color, .Margin_Left)))
}

@(test)
animation_serials :: proc(t: ^testing.T) {
	f := pc_open(`<style>
@keyframes spin { from { transform: rotate(0deg) } to { transform: rotate(360deg) } }
@keyframes slide { from { margin-left: 0 } to { margin-left: 100px } }
#s { animation: spin 1s linear infinite }
#m { animation: slide 1s linear infinite }
</style><div id=s></div><div id=m></div>`)
	defer pc_close(&f)
	// both run: the margin animation changes layout at every tick
	ls := f.st.layout_serial
	timeline_tick(f.tl, f.doc, f.st, 100)
	testing.expect(t, f.st.serial == f.st.layout_serial && f.st.layout_serial != ls, "a margin animation is a layout change")

	g := pc_open(`<style>
@keyframes spin { from { transform: rotate(0deg) } to { transform: rotate(360deg) } }
@keyframes fade { from { opacity: 0.2 } to { opacity: 0.8 } }
#s { animation: spin 1s linear infinite } #o { animation: fade 1s linear infinite; color: red }
</style><div id=s></div><div id=o></div>`)
	defer pc_close(&g)
	timeline_tick(g.tl, g.doc, g.st, 50)
	ls2, s2 := g.st.layout_serial, g.st.serial
	timeline_tick(g.tl, g.doc, g.st, 100)
	timeline_tick(g.tl, g.doc, g.st, 150)
	testing.expect(t, g.st.serial != s2, "values moved")
	testing.expect(t, g.st.layout_serial == ls2, "transform and opacity animations are paint-only")
}
