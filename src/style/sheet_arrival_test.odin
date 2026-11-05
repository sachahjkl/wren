package style

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:html"

// A sheet that arrives gives the styles of a full pass over all the sheets, read from nothing: an engine of its own, its rules
// flattened in document order, compared element by element and field by field (computed_equal).

@(private = "file")
SHEETS := [?]string{
	`.a { color: rgb(1, 0, 0) } div > .b { margin-top: 1px } #x ~ p { padding-top: 2px } [data-k=v] { font-size: 20px } p::before { content: "1" }
	 .only-here { width: 1px } .deep { --v: 4px }`,
	`.a { color: rgb(2, 0, 0); --v: 3px } .c { margin-left: var(--v) } em { font-style: normal } p::before { content: "2" } @font-face { font-family: f2; src: url(a.woff2) }`,
	`.a { color: rgb(3, 0, 0) } li:nth-child(2) { width: 5px } section:has(.b) { border-left-width: 3px; border-left-style: solid } :not(.a).b { float: left }
	 @media (min-width: 1px) { .b { height: 1px } } @media (max-width: 1px) { .b { height: 9px } } @supports (display: grid) { .c { display: grid } }
	 @keyframes unused { to { opacity: 0 } } .z { animation-name: not-defined }`,
	`.outer { font-size: 30px; color: rgb(4, 0, 0) } .c .b { line-height: 2 } ul { list-style-type: square } .a + .b { text-indent: 1em } .c { color: inherit }`,
}

@(private = "file")
BASE_SHEET :: `<style>.a { color: rgb(9, 9, 9); margin-bottom: 1px } .b { color: rgb(8, 8, 8) } section { padding-left: 1em } p { margin: 0 }</style>`

@(private = "file")
ELEMENT_ROWS :: 40

@(private = "file")
document_markup :: proc() -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `<!doctype html><head>`)
	strings.write_string(&sb, BASE_SHEET)
	for _, i in SHEETS { fmt.sbprintf(&sb, `<link id=l%d rel=stylesheet href=s%d.css>`, i, i) }
	strings.write_string(&sb, `</head><body>`)
	for i in 0 ..< ELEMENT_ROWS {
		fmt.sbprintf(&sb, `<section class="%s"><div><p class="a %s" id="%s">t <em>e</em></p><p class=b>u</p><p data-k=v>w</p></div>`, i % 4 == 0 ? "outer" : "", i % 3 == 0 ? "b" : "", i == 7 ? "x" : "")
		fmt.sbprintf(&sb, `<ul class=%s><li>1<li class="c a">2<li class="c"><span class="b deep z">3</span></ul></section>`, i % 5 == 0 ? "c" : "d")
	}
	strings.write_string(&sb, `<p class=only-here>the one</p></body>`)
	return strings.to_string(sb)
}

@(private = "file")
add_link_sheet :: proc(e: ^Engine, doc: ^dom.Document, i: int, text: string) {
	engine_add_sheet(e, text, dom.find_by_id(doc, fmt.tprintf("l%d", i)), from_link = true)
}

// What a full pass of an engine that has `arrived` of SHEETS from the start says, against `s`: "" when they agree on every element.
@(private = "file")
differs_from_all_at_once :: proc(doc: ^dom.Document, s: ^Styled, arrived: []int, extra: string = "", extra_at := -1) -> string {
	settings := settings_default()
	defer settings_destroy(&settings)
	ref := engine_make(settings)
	defer engine_destroy(ref)
	sync_document_sheets(ref, doc, "about:test")
	for i in arrived { add_link_sheet(ref, doc, i, SHEETS[i]) }
	if extra_at >= 0 { add_link_sheet(ref, doc, extra_at, extra) }
	full := compute_styles(ref, doc, s.state)
	defer styled_destroy(full)
	for h := doc.root; h != base.NIL_HANDLE; h = dom.next_shadow_including(doc, h, doc.root) {
		n := dom.get(doc, h)
		if n.kind != .Element { continue }
		a, b := base_style_of(s, h), style_of(full, h)
		if !computed_equal(a, b) {
			what := "a field no property owns"
			for p in Prop { if a != nil && b != nil && !prop_equal(a, b, p) { what = prop_name(p); break } }
			class, _ := dom.get_attribute(doc, h, "class")
			return fmt.tprintf("<%s class=%q>: %s", n.name, class, what)
		}
	}
	return ""
}

@(private = "file")
Fixture :: struct {
	doc: ^dom.Document,
	e:   ^Engine,
	s:   ^Styled,
}

@(private = "file")
fixture_make :: proc(whole_document := false) -> Fixture {
	f: Fixture
	f.doc = dom.document_create(nil)
	src := document_markup()
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 1_000_000)
	settings := settings_default()
	defer settings_destroy(&settings)
	if whole_document { settings.inc_max_ratio = 1 }   // (the sheets of this document are about all it has)
	f.e = engine_make(settings)
	sync_document_sheets(f.e, f.doc, "about:test")
	f.s = compute_styles(f.e, f.doc, {})
	return f
}

@(private = "file")
fixture_destroy :: proc(f: ^Fixture) {
	styled_destroy(f.s)
	engine_destroy(f.e)
	dom.document_destroy(f.doc)
}

// A sheet comes, in document order or not: restyled in place, it is as if all had been there from the start.
@(test)
sheets_that_arrive_in_any_order_give_a_full_pass_s_styles :: proc(t: ^testing.T) {
	orders := [][]int{{0, 1, 2, 3}, {3, 2, 1, 0}, {2, 0, 3, 1}, {1, 3, 0, 2}}
	for order, o in orders {
		f := fixture_make(whole_document = true)
		defer fixture_destroy(&f)
		arrived := make([dynamic]int, context.temp_allocator)
		for i in order {
			add_link_sheet(f.e, f.doc, i, SHEETS[i])
			append(&arrived, i)
			testing.expectf(t, engine_extend(f.e, f.doc, f.s), "order %d, sheet %d: joined the rules", o, i)
			testing.expect(t, !f.e.dirty, "no rebuild is due")
			_, ok := restyle_arrivals(f.e, f.doc, f.s)
			testing.expectf(t, ok, "order %d, sheet %d: restyled: %s", o, i, f.e.last_restyle.fallback)
			testing.expect_value(t, differs_from_all_at_once(f.doc, f.s, arrived[:]), "")
			testing.expect_value(t, verify_styles(f.e, f.doc, f.s, context.temp_allocator), "")
		}
	}
}

// What it restyles is what it can match: one element of the document for a sheet of one class.
@(test)
a_sheet_that_arrives_restyles_what_it_matches :: proc(t: ^testing.T) {
	f := fixture_make()
	defer fixture_destroy(&f)
	sheet := `.only-here { color: rgb(5, 5, 5) } .nothing-has-this { color: red }`
	add_link_sheet(f.e, f.doc, 0, sheet)
	testing.expect(t, engine_extend(f.e, f.doc, f.s), "it joined the rules")
	_, ok := restyle_arrivals(f.e, f.doc, f.s)
	testing.expect(t, ok, "restyled")
	testing.expect_value(t, f.e.last_restyle.changed, 1)
	testing.expectf(t, f.e.last_restyle.marked <= 3, "the element and its ancestors on the way: %d", f.e.last_restyle.marked)
	testing.expect_value(t, differs_from_all_at_once(f.doc, f.s, {}, sheet, 0), "")
}

// insertRule at the end of a sheet, what CSS-in-JS libraries do rule by rule: as a sheet that arrives, in the sheet's place among the others.
@(test)
a_rule_inserted_at_the_end_of_a_sheet_arrives_like_a_sheet :: proc(t: ^testing.T) {
	f := fixture_make()
	defer fixture_destroy(&f)
	add_link_sheet(f.e, f.doc, 1, `.only-here { color: rgb(7, 7, 7) }`)   // (after the sheet that gets the rule, which wins)
	add_link_sheet(f.e, f.doc, 0, `.only-here { height: 1px }`)
	testing.expect(t, engine_extend(f.e, f.doc, f.s), "the sheets joined the rules")
	_, ok := restyle_arrivals(f.e, f.doc, f.s)
	testing.expect(t, ok, "restyled")
	first := engine_sheet_of_owner(f.e, dom.find_by_id(f.doc, "l0"))
	testing.expect_value(t, engine_sheet_insert_rule(f.e, first.id, `.only-here { color: rgb(6, 6, 6); width: 2px }`, 1), Rule_Edit_Error.None)
	testing.expect(t, f.e.dirty && !f.e.dirty_other, "the rules wait for it, not for a rebuild")
	testing.expect(t, engine_extend(f.e, f.doc, f.s), "it joined the rules")
	_, ok = restyle_arrivals(f.e, f.doc, f.s)
	testing.expect(t, ok, "restyled")
	testing.expect_value(t, f.e.last_restyle.changed, 1)
	testing.expect_value(t, verify_styles(f.e, f.doc, f.s, context.temp_allocator), "")
	testing.expect_value(t, engine_sheet_insert_rule(f.e, first.id, `.only-here { color: rgb(5, 5, 5) }`, 0), Rule_Edit_Error.None)
	testing.expect(t, f.e.dirty_other, "a rule inserted before others is for the rebuild")
}

// The reveal has an element out of the tree: its sheet stands after the others, where it is in the document, and its return changes nothing.
@(test)
a_sheet_whose_element_comes_back_where_it_was_needs_no_rebuild :: proc(t: ^testing.T) {
	f := fixture_make()
	defer fixture_destroy(&f)
	l := dom.find_by_id(f.doc, "l3")
	parent := dom.get(f.doc, l).parent
	next := dom.get(f.doc, l).next
	add_link_sheet(f.e, f.doc, 2, `.only-here { color: rgb(1, 1, 1) }`)
	add_link_sheet(f.e, f.doc, 3, `.only-here { color: rgb(2, 2, 2) }`)
	dom.detach(f.doc, l)
	held :: proc(user: rawptr, owner: base.Handle) -> bool { return true }
	sync_document_sheets(f.e, f.doc, "about:test", keep_missing = held)
	testing.expect(t, engine_extend(f.e, f.doc, f.s), "the sheets joined the rules")
	dom.insert_before(f.doc, parent, l, next)
	sync_document_sheets(f.e, f.doc, "about:test", keep_missing = held)
	testing.expect(t, !f.e.dirty, "the rules stand")
}

// What is more than the elements a rule matches goes the long way, to the same result.
@(test)
sheets_that_reach_further_keep_the_rebuild :: proc(t: ^testing.T) {
	cases := []string{
		`@layer one { .a { color: rgb(1, 1, 1) } }`,
		`@layer one, two;`,
		`@property --x { syntax: "<length>"; inherits: true; initial-value: 1px }`,
		`@import "other.css"; .a { color: rgb(1, 1, 1) }`,
		`.outer::part(p) { color: red } .a { color: rgb(1, 1, 1) }`,
		`.a::part(p) { color: red }`,
		`:host { color: red }`,
		`::slotted(p) { color: red }`,
	}
	for sheet, i in cases {
		f := fixture_make()
		defer fixture_destroy(&f)
		add_link_sheet(f.e, f.doc, 0, sheet)
		testing.expectf(t, !engine_extend(f.e, f.doc, f.s), "case %d: it does not join the rules", i)
		testing.expectf(t, f.e.dirty, "case %d: the rebuild is due", i)
		full := compute_styles(f.e, f.doc, {})
		defer styled_destroy(full)
		testing.expect_value(t, differs_from_all_at_once(f.doc, full, {}, sheet, 0), "")
	}
}

// @keyframes of a name elements use starts animations: not a matter of what the sheet's selectors match.
@(test)
keyframes_elements_use_keep_the_rebuild :: proc(t: ^testing.T) {
	f := fixture_make()
	defer fixture_destroy(&f)
	first := `.z { animation-name: spin; animation-duration: 1s }`
	add_link_sheet(f.e, f.doc, 0, first)
	testing.expect(t, engine_extend(f.e, f.doc, f.s), "the rule joined")
	_, ok := restyle_arrivals(f.e, f.doc, f.s)
	testing.expect(t, ok, "restyled")
	add_link_sheet(f.e, f.doc, 1, `@keyframes spin { to { opacity: 0 } }`)
	testing.expect(t, !engine_extend(f.e, f.doc, f.s), "the @keyframes it uses does not")
	add_link_sheet(f.e, f.doc, 2, `@keyframes other { to { opacity: 0 } }`)
	testing.expect(t, f.e.dirty, "and the rebuild stands for what came with it")
}

// A sheet that matches most of the document, one that changes the root's font size: the partial pass gives way to a full one.
@(test)
sheets_that_reach_everything_make_a_full_pass :: proc(t: ^testing.T) {
	for sheet, i in ([]string{`* { margin-right: 1px }`, `html { font-size: 20px }`}) {
		f := fixture_make()
		defer fixture_destroy(&f)
		add_link_sheet(f.e, f.doc, 0, sheet)
		testing.expectf(t, engine_extend(f.e, f.doc, f.s), "case %d: it joined the rules", i)
		_, ok := restyle_arrivals(f.e, f.doc, f.s)
		testing.expectf(t, !ok, "case %d: and asks for a full pass", i)
		full := compute_styles(f.e, f.doc, {})
		defer styled_destroy(full)
		testing.expect_value(t, differs_from_all_at_once(f.doc, full, {}, sheet, 0), "")
	}
}
