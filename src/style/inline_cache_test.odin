package style

import "core:testing"
import "wb:dom"
import "wb:html"

// Compiled style attributes (inline_cache.odin) give the styles parsing the attribute gives: in a full pass where many
// elements share a text, in partial restyles after the attribute changes, and from rules primed by CSSOM.

@(private = "file")
Ic :: struct {
	doc: ^dom.Document,
	eng: ^Engine,
	st:  ^Styled,
}

@(private = "file")
ic_load :: proc(src: string, entries := 8192) -> Ic {
	f: Ic
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	ss := settings_default()
	ss.inline_cache_entries = entries
	f.eng = engine_make(ss)
	settings_destroy(&ss)
	engine_set_journal(f.eng, 1 << 16)
	f.eng.settings.inc_max_ratio = 1
	sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = compute_styles(f.eng, f.doc, {})
	dom.journal_enable(f.doc, 1 << 16)
	return f
}

@(private = "file")
ic_unload :: proc(f: ^Ic) {
	styled_destroy(f.st)
	engine_destroy(f.eng)
	dom.document_destroy(f.doc)
}

@(private = "file")
ic_restyle :: proc(t: ^testing.T, f: ^Ic, what: string, loc := #caller_location) {
	_, ok := restyle_dom(f.eng, f.doc, f.st)
	testing.expectf(t, ok, "%s: not partial (%s)", what, f.eng.last_restyle.fallback, loc = loc)
	diff := verify_styles(f.eng, f.doc, f.st, context.temp_allocator)
	testing.expectf(t, diff == "", "%s: %s", what, diff, loc = loc)
}

@(private = "file")
IC_PAGE :: `<style>p { color: blue } .v { --w: 7px }</style>
	<div id=a style="color: red; margin: 1px 2px; --k: 3px">x</div>
	<div id=b style="color: red; margin: 1px 2px; --k: 3px">y</div>
	<div id=c class=v style="padding-left: var(--w) !important; border: 1px solid green">z</div>
	<p id=d style="color: nonsense; width: 10px">w</p>`

@(test)
inline_cache_full_pass_matches_parsing :: proc(t: ^testing.T) {
	cached := ic_load(IC_PAGE)
	defer ic_unload(&cached)
	plain := ic_load(IC_PAGE, entries = 0)
	defer ic_unload(&plain)
	testing.expect(t, len(cached.st.inline_rules) == 3, "one rule per distinct style attribute")
	testing.expect(t, len(plain.st.inline_rules) == 0)
	testing.expect_value(t, verify_styles(cached.eng, cached.doc, cached.st, context.temp_allocator), "")
	for id in ([]string{"a", "b", "c", "d"}) {
		x := style_of(cached.st, dom.find_by_id(cached.doc, id))
		y := style_of(plain.st, dom.find_by_id(plain.doc, id))
		testing.expectf(t, x != nil && y != nil && x.color == y.color && x.margin == y.margin && x.padding == y.padding && x.width == y.width && x.border_width == y.border_width, "#%s", id)
	}
	testing.expect(t, style_of(cached.st, dom.find_by_id(cached.doc, "d")).color == {0, 0, 1, 1}, "the invalid inline color is dropped")
}

@(test)
inline_cache_partial_restyles :: proc(t: ^testing.T) {
	f := ic_load(IC_PAGE)
	defer ic_unload(&f)
	a := dom.find_by_id(f.doc, "a")
	for v in ([]string{"color: green", "color: red; margin: 1px 2px; --k: 3px", "transform: rotate(10deg)", "", "color: green"}) {
		dom.set_attribute(f.doc, a, "style", v)
		ic_restyle(t, &f, v)
	}
	testing.expect(t, style_of(f.st, a).color == {0, 128.0 / 255, 0, 1})
}

// What CSSOM primes is what parsing the attribute gives, invalid parts and !important included; a full pass after it
// does not see the primed rules (a new Styled).
@(test)
inline_cache_primed_rules :: proc(t: ^testing.T) {
	f := ic_load(`<div id=a>x</div><div id=b>y</div>`)
	defer ic_unload(&f)
	text := "color: red; width: bogus; margin-left: 4px !important; --q: 1px;"
	_, _, ok_color := inline_declaration(f.eng, f.st, "color", "red")
	_, _, ok_bogus := inline_declaration(f.eng, f.st, "width", "bogus")
	testing.expect(t, ok_color && !ok_bogus)
	parts := []Inline_Part{{"color", "red", false}, {"width", "bogus", false}, {"margin-left", "4px", true}, {"--q", "1px", false}}
	inline_style_prime(f.eng, f.st, text, parts)
	r, has := f.st.inline_rules[text]
	testing.expect(t, has && r != nil && len(r.decls) == 2 && len(r.customs) == 1)
	if r != nil && len(r.decls) == 2 { testing.expect(t, !r.decls[0].important && r.decls[1].important) }
	dom.set_attribute(f.doc, dom.find_by_id(f.doc, "a"), "style", text)
	dom.set_attribute(f.doc, dom.find_by_id(f.doc, "b"), "style", text)
	ic_restyle(t, &f, "primed")
	cs := style_of(f.st, dom.find_by_id(f.doc, "b"))
	testing.expect(t, cs.color == {1, 0, 0, 1} && cs.margin[.Left].v == 4)
}

// Past style.inline_cache.entries the maps start over (their memory stays with the pass) and styles stay right.
@(test)
inline_cache_bounded :: proc(t: ^testing.T) {
	f := ic_load(`<div id=a>x</div>`, entries = 2)
	defer ic_unload(&f)
	a := dom.find_by_id(f.doc, "a")
	for i in 0 ..< 9 {
		v := i % 2 == 0 ? "padding-top: 1px" : "padding-top: 2px; color: red"
		if i >= 4 { v = i % 3 == 0 ? "width: 5px" : "height: 6px" }
		dom.set_attribute(f.doc, a, "style", v)
		ic_restyle(t, &f, v)
		testing.expect(t, len(f.st.inline_rules) <= 2)
	}
}
