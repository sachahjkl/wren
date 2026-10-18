package style

import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:html"

@(private = "file")
Jx :: struct { doc: ^dom.Document, eng: ^Engine, st: ^Styled }

@(private = "file")
jx_load :: proc(src: string) -> ^Jx {
	f := new(Jx)
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 100_000)
	ss := settings_default()
	f.eng = engine_make(ss)
	settings_destroy(&ss)
	engine_set_journal(f.eng, 1024)
	sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = compute_styles(f.eng, f.doc, {})
	return f
}

@(private = "file")
jx_restyle :: proc(f: ^Jx) {
	sync_document_sheets(f.eng, f.doc, "about:test")
	old := f.st
	f.st = compute_styles(f.eng, f.doc, {})
	journal_diff(old, f.st)
	styled_destroy(old)
}

@(private = "file")
jx_unload :: proc(f: ^Jx) {
	styled_destroy(f.st)
	engine_destroy(f.eng)
	dom.document_destroy(f.doc)
	free(f)
}

@(test)
change_levels :: proc(t: ^testing.T) {
	f := jx_load(`<style>.w{width:10px} .d{display:flex} .c{color:red} .fs{font-size:30px} .m{margin-top:4px}</style><div id=a>x</div>`)
	defer jx_unload(f)
	a := dom.find_by_id(f.doc, "a")
	level_after :: proc(f: ^Jx, a: base.Handle, class: string) -> Change_Level {
		before := f.st.serial
		dom.set_attribute(f.doc, a, "class", class)
		jx_restyle(f)
		es, ok := journal_since(f.st, before)
		if !ok { return .Box }
		level := Change_Level.None
		for e in es { if e.node == a { level = max(level, e.level) } }
		return level
	}
	testing.expect_value(t, level_after(f, a, "w"), Change_Level.Layout)    // a size: the box stays
	testing.expect_value(t, level_after(f, a, "w c"), Change_Level.None)    // paint only: not recorded
	testing.expect_value(t, level_after(f, a, "w c m"), Change_Level.Layout)
	testing.expect_value(t, level_after(f, a, "d"), Change_Level.Box)       // display: another box
	testing.expect_value(t, level_after(f, a, "d fs"), Change_Level.Box)    // fonts are read when building boxes
	// the classification itself
	x, y := new(Computed, context.temp_allocator), new(Computed, context.temp_allocator)
	x^ = f.st.initial^
	y^ = x^
	testing.expect_value(t, change_level(x, y), Change_Level.None)
	y.background_color = {1, 0, 0, 1}
	testing.expect_value(t, change_level(x, y), Change_Level.Paint)
	y.padding[.Left] = px(3)
	testing.expect_value(t, change_level(x, y), Change_Level.Layout)
	y.position = .Absolute
	testing.expect_value(t, change_level(x, y), Change_Level.Box)
	testing.expect(t, props_level(ps_of(.Transform, .Opacity)) == .Paint)
	testing.expect(t, props_level(ps_of(.Width, .Opacity)) == .Layout)
	testing.expect(t, props_level(ps_of(.Visibility)) == .Box)
}

@(test)
journal_serials :: proc(t: ^testing.T) {
	f := jx_load(`<style>a:hover{padding:3px}</style><a id=l>x</a><p>y</p>`)
	defer jx_unload(f)
	s0 := f.st.serial
	_, ok := journal_since(f.st, s0)
	testing.expect(t, ok, "covers what comes after the current styles")
	// a partial restyle records its changes, stamped with the new serial
	l := dom.find_by_id(f.doc, "l")
	changed, ok2 := restyle_state(f.eng, f.doc, f.st, State{hover = l})
	testing.expect(t, ok2 && changed)
	es, ok3 := journal_since(f.st, s0)
	testing.expect(t, ok3 && len(es) == 1 && es[0].node == l && es[0].level == .Layout && es[0].serial == f.st.serial)
	none, ok4 := journal_since(f.st, f.st.serial)
	testing.expect(t, ok4 && len(none) == 0, "a reader up to date has nothing to read")
	// a full pass carries what changed since the pass it replaces
	s1 := f.st.serial
	jx_restyle(f)
	_, ok5 := journal_since(f.st, s1)
	testing.expect(t, ok5)
	_, ok6 := journal_since(f.st, s0)
	testing.expect(t, !ok6, "older readers start over")
}
