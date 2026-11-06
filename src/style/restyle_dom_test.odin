package style

import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:host"

// restyle_dom against a full pass: after each mutation the partial restyle must give every element the computed style
// a full pass gives it (verify_styles), and stay partial.

@(private = "file")
Rx :: struct {
	using fx:      ^Fixture,
	partial, full: int,
}

@(private = "file")
rx_load :: proc(src: string) -> ^Rx { return new_clone(Rx{fx = fixture_load(src, {journal = FIXTURE_JOURNAL, partial = true})}) }

@(private = "file")
rx_unload :: proc(f: ^Rx) {
	fixture_unload(f.fx)
	free(f)
}

@(private = "file")
by_id :: proc(f: ^Rx, id: string) -> base.Handle { return dom.find_by_id(f.doc, id) }

// Restyles after mutations; checks the result against a full pass. Returns whether the restyle was partial.
@(private = "file")
rx_step :: proc(t: ^testing.T, f: ^Rx, what: string, loc := #caller_location) -> bool {
	_, ok := restyle_dom(f.eng, f.doc, f.st)
	if !ok {
		f.full += 1
		old := f.st
		f.st = compute_styles(f.eng, f.doc, {})
		journal_diff(old, f.st)
		styled_destroy(old)
	} else {
		f.partial += 1
	}
	diff := verify_styles(f.eng, f.doc, f.st, context.temp_allocator)
	testing.expectf(t, diff == "", "%s: %s (%v)", what, diff, f.eng.last_restyle, loc = loc)
	return ok
}

@(private = "file")
expect_partial :: proc(t: ^testing.T, f: ^Rx, what: string, max_marked := -1, loc := #caller_location) {
	ok := rx_step(t, f, what, loc)
	testing.expectf(t, ok, "%s: not partial (%s)", what, f.eng.last_restyle.fallback, loc = loc)
	if max_marked >= 0 {
		testing.expectf(t, f.eng.last_restyle.marked <= max_marked, "%s: %d elements restyled, at most %d expected", what, f.eng.last_restyle.marked, max_marked, loc = loc)
	}
}

@(private = "file")
LIST :: `<ul id=l><li id=i1>a</li><li id=i2>b</li><li id=i3>c</li><li id=i4>d</li><li id=i5>e</li></ul>`

@(test)
restyle_dom_descendant_and_child :: proc(t: ^testing.T) {
	f := rx_load(`<style>.a .b { color: red } .a > .c { padding: 3px } .z { margin: 1px }</style>
		<div id=x><p class=b id=p1><span class=b id=s1>t</span></p><p class=c id=p2>u</p></div><div id=y><p class=b>v</p></div>`)
	defer rx_unload(f)
	x := by_id(f, "x")
	dom.set_attribute(f.doc, x, "class", "a")
	expect_partial(t, f, "class on ancestor (.a .b, .a > .c)", 6)
	testing.expect(t, style_of(f.st, by_id(f, "s1")).color == {1, 0, 0, 1})
	dom.set_attribute(f.doc, x, "class", "a z")
	expect_partial(t, f, "irrelevant class added")
	testing.expect_value(t, f.eng.last_restyle.marked, 1)   // only the element itself: .z is a subject feature
	dom.remove_attribute(f.doc, x, "class")
	expect_partial(t, f, "class removed")
	// a class nobody tests restyles nothing
	before := f.st.serial
	dom.set_attribute(f.doc, x, "class", "nothing-uses-this")
	expect_partial(t, f, "unused class", 0)
	testing.expect_value(t, f.st.serial, before)
}

// A custom property declared in a style attribute is a key of the element's Custom_Props for as long as the record
// lives: its name must not point into the temporary memory the attribute was parsed in (freed at the end of the
// frame), or a later partial restyle keeps a record whose key is garbage (shadow-dom.html, inc_demo_pages).
@(test)
restyle_dom_inline_custom_property_names :: proc(t: ^testing.T) {
	f := rx_load(`<style>b { color: var(--accent, red) }</style><div id=host style="--accent: #00f"><b id=b>x</b></div><p id=other>y</p>`)
	defer rx_unload(f)
	// the end of the frame: the temp allocator is reset and its memory reused
	free_all(context.temp_allocator)
	junk := make([]u8, 1 << 16, context.temp_allocator)
	for &c in junk { c = ' ' }
	dom.set_attribute(f.doc, by_id(f, "other"), "style", "margin: 1px")
	expect_partial(t, f, "an unrelated inline style")
	host := style_of(f.st, by_id(f, "host"))
	testing.expect(t, host != nil && host.custom != nil)
	if host != nil && host.custom != nil {
		found := custom_has(host.custom, "--accent")
		testing.expect(t, found, "the key is still --accent")
	}
	testing.expect(t, style_of(f.st, by_id(f, "b")).color == {0, 0, 1, 1})
}

@(test)
restyle_dom_siblings :: proc(t: ^testing.T) {
	f := rx_load(`<style>.a + .b { color: red } .a ~ .c { margin-left: 5px } .a + * + .d { padding: 2px }</style>
		<div><p id=p0>x</p><p id=p1 class=b>x</p><p id=p2 class=c>x</p><p id=p3 class="c d">x</p><p class=c>x</p></div>`)
	defer rx_unload(f)
	p0 := by_id(f, "p0")
	dom.set_attribute(f.doc, p0, "class", "a")
	expect_partial(t, f, "class on an earlier sibling (+, ~)")
	testing.expect(t, style_of(f.st, by_id(f, "p1")).color == {1, 0, 0, 1})
	// a new sibling in between breaks `.a + .b`
	n := dom.create_element(f.doc, "p")
	dom.insert_before(f.doc, dom.get(f.doc, p0).parent, n, by_id(f, "p1"))
	expect_partial(t, f, "element inserted between siblings")
	dom.remove_child(f.doc, dom.get(f.doc, n).parent, n)
	dom.release(f.doc, n)
	expect_partial(t, f, "element removed between siblings")
	dom.remove_attribute(f.doc, p0, "class")
	expect_partial(t, f, "class removed from the earlier sibling")
}

@(test)
restyle_dom_positional :: proc(t: ^testing.T) {
	f := rx_load(strings.concatenate({`<style>li:nth-child(2n+1) { color: red } li:first-child { font-weight: bold } li:last-child { padding: 1px } li:nth-last-child(2) { margin: 2px } li:only-child { margin: 9px }</style>`, LIST}, context.temp_allocator))
	defer rx_unload(f)
	l := by_id(f, "l")
	n := dom.create_element(f.doc, "li")
	dom.append_child(f.doc, n, dom.create_text(f.doc, "new"))
	dom.insert_before(f.doc, l, n, dom.get(f.doc, l).first_child)
	expect_partial(t, f, ":nth-child(2n+1) after an insertion at the start")
	dom.remove_child(f.doc, l, n)
	expect_partial(t, f, ":first-child after a removal")
	dom.append_child(f.doc, l, n)
	expect_partial(t, f, ":last-child after an append")
	// down to one child: :only-child
	for {
		first := dom.get(f.doc, l).first_child
		if first == n { break }
		dom.remove_child(f.doc, l, first)
		dom.release(f.doc, first)
	}
	expect_partial(t, f, ":only-child")
}

@(test)
restyle_dom_empty_and_text :: proc(t: ^testing.T) {
	f := rx_load(`<style>p:empty { display: none } p { color: blue }</style><div><p id=e></p><p id=f>x</p></div>`)
	defer rx_unload(f)
	e := by_id(f, "e")
	testing.expect(t, style_of(f.st, e).display == .None)
	dom.append_child(f.doc, e, dom.create_text(f.doc, "now"))
	expect_partial(t, f, ":empty when a text appears", 2)
	testing.expect(t, style_of(f.st, e).display != .None)
	dom.set_text_content(f.doc, e, "")
	expect_partial(t, f, ":empty when the text goes")
	// text in a document without :empty restyles nothing
	g := rx_load(`<style>p { color: blue }</style><p id=a>x</p>`)
	defer rx_unload(g)
	before := g.st.serial
	dom.set_text_content(g.doc, by_id(g, "a"), "changed")
	expect_partial(t, g, "text only", 0)
	testing.expect_value(t, g.st.serial, before)
	testing.expect_value(t, g.st.mutations, g.doc.mutations)
}

@(test)
restyle_dom_has :: proc(t: ^testing.T) {
	f := rx_load(`<style>.card:has(.x) { border: 2px solid red } div:has(+ .y) { margin: 3px } .w:has(> p:empty) { padding: 4px }</style>
		<div class=card id=c><section><p id=p>t</p></section></div><div id=d>a</div><div id=e>b</div><div class=w id=w><p id=q>z</p></div>`)
	defer rx_unload(f)
	dom.set_attribute(f.doc, by_id(f, "p"), "class", "x")
	expect_partial(t, f, ":has(.x) on an ancestor")
	testing.expect(t, style_of(f.st, by_id(f, "c")).border_width[.Top] > 0)
	dom.set_attribute(f.doc, by_id(f, "e"), "class", "y")
	expect_partial(t, f, ":has(+ .y) on the previous sibling")
	dom.set_text_content(f.doc, by_id(f, "q"), "")
	expect_partial(t, f, ":has(> p:empty)")
	n := dom.create_element(f.doc, "b")
	dom.set_attribute(f.doc, n, "class", "x")
	dom.append_child(f.doc, by_id(f, "d"), n)
	expect_partial(t, f, ":has() after an insertion")
	dom.remove_child(f.doc, by_id(f, "d"), n)
	expect_partial(t, f, ":has() after a removal")
	dom.release(f.doc, n)
}

// A :has() anchor with nothing else in its compound (`:not(:has(.flag)) .t`, as YouTube's sheets have) is every
// ancestor's candidate: a class change that no :has() argument tests must not mark them (and through them the whole
// document); one the argument tests must, and the result stays what a full pass gives.
@(test)
restyle_dom_has_bare_anchor_unrelated_changes :: proc(t: ^testing.T) {
	f := rx_load(`<style>:not(:has(.flag)) > .t { color: red } .z { margin: 1px } [data-k] { padding: 2px }
		:has([data-w]) > .u { color: blue } .card:has(.q) { outline: 1px solid red }</style>
		<div id=root><div id=a><div id=b><span class=t id=t1>x</span><span class=u id=u1>y</span></div></div><div id=c><p id=p>t</p></div></div>`)
	defer rx_unload(f)
	dom.set_attribute(f.doc, by_id(f, "p"), "class", "z")
	expect_partial(t, f, "class no :has() tests", 1)
	dom.set_attribute(f.doc, by_id(f, "p"), "class", "q")   // tested by another anchor's :has(): the bare ones are not concerned
	expect_partial(t, f, "class another :has() tests", 1)
	dom.set_attribute(f.doc, by_id(f, "p"), "data-k", "1")
	expect_partial(t, f, "attribute no :has() tests", 1)
	dom.set_attribute(f.doc, by_id(f, "p"), "class", "flag")
	expect_partial(t, f, "class a :has() tests")
	dom.set_attribute(f.doc, by_id(f, "p"), "data-w", "1")
	expect_partial(t, f, "attribute a :has() tests")
	dom.remove_attribute(f.doc, by_id(f, "p"), "data-w")
	expect_partial(t, f, "attribute removed")
}

// `:has(> .k)` can only be an ancestor one level up: a class toggled deep in the tree restyles the parent's subtree, not
// every ancestor's (html and body as whole subtrees), and the result is still a full pass's.
@(test)
restyle_dom_has_child_combinator_reaches_one_level :: proc(t: ^testing.T) {
	f := rx_load(`<style>:has(> .k) .w { color: red } :has(> .k > .j) { outline: 1px solid red } :has(+ .m) { margin: 1px }</style>
		<div id=r><div id=a><div id=b><div id=c><div id=d><span class=w id=w1>x</span></div></div></div></div>
		<div id=e><span class=w id=w2>y</span></div></div>`)
	defer rx_unload(f)
	dom.set_attribute(f.doc, by_id(f, "d"), "class", "k")
	expect_partial(t, f, "class on a deep element", 4)   // its parent (c) and what the rule reaches below it (not r, a, b)
	testing.expect(t, style_of(f.st, by_id(f, "w1")).color == {1, 0, 0, 1})
	dom.set_attribute(f.doc, by_id(f, "w1"), "class", "w j")
	expect_partial(t, f, "second level")
	dom.set_attribute(f.doc, by_id(f, "e"), "class", "m")
	expect_partial(t, f, "sibling anchor", 3)
}

// `.a .b`: a class toggled on the ancestor restyles the `.b` elements under it, not its whole subtree (the reach names its
// subject's key); unions of rules with other subjects keep every key; a subject with no key restyles the subtree.
@(test)
restyle_dom_subject_keys :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `<style>.a .b { color: red } .a > .c { padding: 2px } #only { margin: 1px } .a em { outline: 1px solid red } .k * { margin: 3px }</style><div id=x>`)
	for i in 0 ..< 40 { fmt.sbprintf(&sb, "<p><i>t%d</i><span class=b>u</span></p>", i) }
	strings.write_string(&sb, `<em id=e>z</em><u id=only>w</u><div class=c id=c>q</div></div>`)
	f := rx_load(strings.to_string(sb))
	defer rx_unload(f)
	dom.set_attribute(f.doc, by_id(f, "x"), "class", "a")
	expect_partial(t, f, ".a toggled", 44)   // 40 .b, the em, the .c: not the 40 p and 40 i
	testing.expect(t, style_of(f.st, by_id(f, "e")).outline_width > 0)
	dom.remove_attribute(f.doc, by_id(f, "x"), "class")
	expect_partial(t, f, ".a removed", 44)
	dom.set_attribute(f.doc, by_id(f, "x"), "class", "k")
	expect_partial(t, f, ".k * (no key): the subtree")
	testing.expect(t, f.eng.last_restyle.marked > 100)
}

// An element that becomes a query container changes what its descendants see (their `containers`) though no rule of theirs
// matches differently: the walk must go down (it used to, by luck, through a descendant rule of the demo page).
@(test)
restyle_dom_becomes_container :: proc(t: ^testing.T) {
	f := rx_load(`<style>.k { container: box / inline-size } @container box (width >= 0px) { i { color: red } }</style><div id=d><p><i id=i>t</i></p></div>`)
	defer rx_unload(f)
	dom.set_attribute(f.doc, by_id(f, "d"), "class", "k")
	_ = rx_step(t, f, "container made")   // (compared with a full pass)
	dom.remove_attribute(f.doc, by_id(f, "d"), "class")
	_ = rx_step(t, f, "container removed")
}

@(test)
restyle_dom_attributes_and_ids :: proc(t: ^testing.T) {
	f := rx_load(`<style>[data-x="y"] { color: red } [data-x] span { margin: 1px } #one { padding: 5px } #one > i { font-style: normal } a:link { color: green }</style>
		<div id=d><span id=s>t</span><i id=i>u</i><a id=a>link</a></div>`)
	defer rx_unload(f)
	d := by_id(f, "d")
	dom.set_attribute(f.doc, d, "data-x", "y")
	expect_partial(t, f, "[data-x=y] added")
	dom.set_attribute(f.doc, d, "data-x", "z")
	expect_partial(t, f, "[data-x] value changed")
	dom.remove_attribute(f.doc, d, "data-x")
	expect_partial(t, f, "[data-x] removed")
	dom.set_attribute(f.doc, d, "id", "one")
	expect_partial(t, f, "id set")
	dom.set_attribute(f.doc, d, "id", "two")
	expect_partial(t, f, "id changed")
	dom.set_attribute(f.doc, by_id(f, "a"), "href", "#x")
	expect_partial(t, f, ":link from href")
	dom.set_attribute(f.doc, by_id(f, "s"), "style", "color: purple; --v: 3px")
	expect_partial(t, f, "inline style", 1)
}

// Presentational attributes no selector reads (hints.odin): the element, or a table's cells, restyle.
@(test)
restyle_dom_presentational_hints :: proc(t: ^testing.T) {
	f := rx_load(`<!doctype html><body id=b><div id=d>x</div><table id=t><tr id=r><td id=c>a</td><td>b</td></tr></table><a id=a href=x>l</a></body>`)
	defer rx_unload(f)
	dom.set_attribute(f.doc, by_id(f, "d"), "align", "center")
	expect_partial(t, f, "div align", 2)
	testing.expect_value(t, style_of(f.st, by_id(f, "d")).text_align, Text_Align.Legacy_Center)
	dom.set_attribute(f.doc, by_id(f, "c"), "bgcolor", "red")
	expect_partial(t, f, "td bgcolor", 1)
	dom.set_attribute(f.doc, by_id(f, "t"), "cellpadding", "7")
	expect_partial(t, f, "table cellpadding reaches the cells")
	testing.expect(t, style_of(f.st, by_id(f, "c")).padding[.Top].v == 7, "cellpadding applied")
	dom.set_attribute(f.doc, by_id(f, "t"), "border", "1")
	expect_partial(t, f, "table border reaches the cells")
	dom.set_attribute(f.doc, by_id(f, "b"), "link", "#ff0000")
	expect_partial(t, f, "body link reaches the links")
	testing.expect(t, style_of(f.st, by_id(f, "a")).color == {1, 0, 0, 1}, "link color applied")
	dom.remove_attribute(f.doc, by_id(f, "t"), "cellpadding")
	expect_partial(t, f, "cellpadding removed")
}

@(test)
restyle_dom_inheritance :: proc(t: ^testing.T) {
	f := rx_load(`<style>.big { font-size: 30px; color: red; --pad: 7px } p { padding: var(--pad, 1px) } span { margin: 1em } .kid { border-style: solid; border-width: inherit } .bw { border: 3px solid }</style>
		<div id=d><p id=p><span id=s>t</span><b class=kid id=k>u</b></p></div>`)
	defer rx_unload(f)
	d := by_id(f, "d")
	dom.set_attribute(f.doc, d, "class", "big")
	expect_partial(t, f, "inherited font-size, color, custom property")
	testing.expect_value(t, style_of(f.st, by_id(f, "s")).font_size, f32(30))
	// only a non-inherited value changes: what inherits it explicitly follows
	dom.set_attribute(f.doc, by_id(f, "p"), "class", "bw")
	expect_partial(t, f, "explicit inherit of a non-inherited property")
	testing.expect_value(t, style_of(f.st, by_id(f, "k")).border_width[.Top], style_of(f.st, by_id(f, "p")).border_width[.Top])
	dom.remove_attribute(f.doc, d, "class")
	expect_partial(t, f, "back")
}

@(test)
restyle_dom_generated_content :: proc(t: ^testing.T) {
	f := rx_load(`<style>.t::before { content: "[" attr(data-n) "]" } ol li::after { content: " #" counter(list-item) } h2 { counter-increment: sec } h2::before { content: counter(sec) ". " }</style>
		<p class=t id=t data-n=1>x</p><ol id=o><li>a</li><li>b</li><li>c</li></ol><h2>A</h2><h2 id=h>B</h2><h2>C</h2>`)
	defer rx_unload(f)
	dom.set_attribute(f.doc, by_id(f, "t"), "data-n", "2")
	expect_partial(t, f, "content: attr()", 1)
	o := by_id(f, "o")
	n := dom.create_element(f.doc, "li")
	dom.append_child(f.doc, n, dom.create_text(f.doc, "new"))
	dom.insert_before(f.doc, o, n, dom.get(f.doc, o).first_child)
	expect_partial(t, f, "list item inserted: markers and counter() renumbered")
	testing.expect(t, f.eng.last_restyle.rewalked)
	h := by_id(f, "h")
	dom.set_attribute(f.doc, h, "style", "display: none")
	expect_partial(t, f, "a counted heading hidden")
	dom.remove_attribute(f.doc, h, "style")
	expect_partial(t, f, "shown again")
	dom.set_attribute(f.doc, o, "start", "10")
	expect_partial(t, f, "ol start")
	dom.set_attribute(f.doc, o, "reversed", "")
	expect_partial(t, f, "ol reversed")
}

@(test)
restyle_dom_stops_marking_when_a_full_pass_is_shorter :: proc(t: ^testing.T) {
	// elements attached under many :has() anchors, too few to say so by their number: the marking stops when its answers are past what a full pass costs
	GROUPS :: 500
	PER_ELEMENT :: 6   // anchors above an inserted element
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `<style>.a:has(.b) { color: red } .c:has(.b) { color: blue }</style>`)
	for i in 0 ..< GROUPS { fmt.sbprintf(&sb, `<div class="a c"><div class="a c"><div class="a c" id=g%d></div></div></div>`, i) }
	f := rx_load(strings.to_string(sb))
	defer rx_unload(f)
	watch_prepare(f.eng, f.doc)
	for i in 0 ..< GROUPS {
		el := dom.create_element(f.doc, "i")
		dom.set_attribute(f.doc, el, "class", "b")
		dom.append_child(f.doc, by_id(f, fmt.tprintf("g%d", i)), el)
	}
	_, ok := restyle_dom(f.eng, f.doc, f.st)
	testing.expect(t, !ok && f.eng.last_restyle.fallback == "too much changed", "it gave up")
	limit := max(int(f.eng.settings.inc_max_ratio * f32(f.doc.nodes.count)), FLIP_LIMIT_MIN)
	testing.expectf(t, f.eng.last_restyle.flips > limit / 2 && f.eng.last_restyle.flips <= limit + PER_ELEMENT, "at the limit of %d, not at the %d answers of all the elements: %d", limit, GROUPS * PER_ELEMENT, f.eng.last_restyle.flips)
}

@(test)
restyle_dom_falls_back :: proc(t: ^testing.T) {
	f := rx_load(`<style>p { color: red }</style><div id=d><p>x</p></div>`)
	defer rx_unload(f)
	// a new <style>: the rules change, only a full pass will do (the page reads the sheets again first)
	st := dom.create_element(f.doc, "style")
	dom.append_child(f.doc, st, dom.create_text(f.doc, "p { color: blue }"))
	dom.append_child(f.doc, by_id(f, "d"), st)
	testing.expect(t, dom_touches_sheets(f.eng, f.doc, f.st, nil))
	sync_document_sheets(f.eng, f.doc, "about:test")
	_, ok := restyle_dom(f.eng, f.doc, f.st)
	testing.expect(t, !ok && f.eng.last_restyle.fallback == "rules changed")
	old := f.st
	f.st = compute_styles(f.eng, f.doc, {})
	styled_destroy(old)
	// too much at once
	f.eng.settings.inc_max_ratio = 0
	dom.set_attribute(f.doc, by_id(f, "d"), "style", "color: green")
	_, ok2 := restyle_dom(f.eng, f.doc, f.st)
	testing.expect(t, !ok2 && f.eng.last_restyle.fallback == "too much changed")
	f.eng.settings.inc_max_ratio = 1
	// the root font size: every rem follows
	g := rx_load(`<style>.r { font-size: 20px } p { margin: 1rem }</style><p id=p>x</p>`)
	defer rx_unload(g)
	dom.set_attribute(g.doc, dom.find_first_by_tag(g.doc, "html"), "class", "r")
	ok3 := rx_step(t, g, "root font size")
	testing.expect(t, !ok3)
}

// With a forms model (a control provider), what can reach other controls' state falls back to a full pass; the rest
// of the document stays partial.
// Rules that ask about groups of controls (:checked of a radio group, :valid of a form...): any control inserted,
// removed or changed may change another one's answer, so those restyle everything. Rules with only element-local
// questions (:disabled... Tailwind's disabled: variants) restyle what changed (rows of buttons in a virtual list).
// The search for such controls goes through shadow trees, and comes back: a shadow root names its host in `shadow` too.
@(test)
restyle_dom_forms_shadow_root :: proc(t: ^testing.T) {
	provider := Control_Provider{query = proc(user: rawptr, el: base.Handle, q: Control_Query) -> (bool, bool) { return false, false }}
	f := rx_load(`<style>input:checked { color: red }</style><div id=host></div><div id=d><p id=p>x</p></div>`)
	defer rx_unload(f)
	_, serr := dom.attach_shadow(f.doc, by_id(f, "host"), dom.Shadow_Init{})
	testing.expect_value(t, serr, dom.Error.None)
	old := f.st
	f.st = compute_styles(f.eng, f.doc, {controls = provider})
	styled_destroy(old)
	p := by_id(f, "p")
	dom.remove_child(f.doc, by_id(f, "d"), p)
	dom.release(f.doc, p)
	expect_partial(t, f, "an element gone from a document with a shadow tree and no radio buttons")
}

@(test)
restyle_dom_forms :: proc(t: ^testing.T) {
	provider := Control_Provider{query = proc(user: rawptr, el: base.Handle, q: Control_Query) -> (bool, bool) { return false, false }}
	GROUPS :: `<style>input:checked { color: red }</style>`
	f := rx_load(GROUPS + `<form><input id=i name=a><input name=a></form><div id=d><p id=p>x</p></div>`)
	defer rx_unload(f)
	f.st.state.controls = provider
	p := by_id(f, "p")
	dom.remove_child(f.doc, by_id(f, "d"), p)
	dom.release(f.doc, p)
	expect_partial(t, f, "an element gone from a document with forms but no radio buttons")
	// controls that come and go inside a form restyle the form (its :valid, its default button) and what they are
	form := dom.find_first_by_tag(f.doc, "form")
	c1 := dom.create_element(f.doc, "input")
	dom.append_child(f.doc, form, c1)
	expect_partial(t, f, "a control inserted in a form")
	b1 := dom.create_element(f.doc, "button")
	dom.append_child(f.doc, form, b1)
	expect_partial(t, f, "a button inserted in the form (a default button)")
	dom.set_attribute(f.doc, c1, "disabled", "")
	expect_partial(t, f, "a control of the form disabled")
	dom.remove_child(f.doc, form, c1)
	expect_partial(t, f, "a control removed from the form")
	dom.remove_child(f.doc, form, b1)
	dom.release(f.doc, b1)
	expect_partial(t, f, "a button gone from the form")
	// a radio button belongs to a group we cannot find from the node: a full pass
	rd := dom.create_element(f.doc, "input")
	dom.set_attribute(f.doc, rd, "type", "radio")
	dom.append_child(f.doc, form, rd)
	_, okr := restyle_dom(f.eng, f.doc, f.st)
	testing.expect(t, !okr && f.eng.last_restyle.fallback == "form controls inserted")
	oldf := f.st
	f.st = compute_styles(f.eng, f.doc, {controls = provider})
	styled_destroy(oldf)
	// and with one in the document, an element that is gone may have been one of the group
	q2 := dom.create_element(f.doc, "p")
	dom.append_child(f.doc, by_id(f, "d"), q2)
	expect_partial(t, f, "a paragraph inserted")
	dom.remove_child(f.doc, by_id(f, "d"), q2)
	dom.release(f.doc, q2)
	_, ok := restyle_dom(f.eng, f.doc, f.st)
	testing.expect(t, !ok && f.eng.last_restyle.fallback == "element removed from a document with form controls")

	// only local questions: a row with a button removed and another inserted, partially (and as a full pass would)
	l := rx_load(`<style>button:disabled { opacity: .5 } .r { margin: 1px }</style><div id=list><div class=r id=r1><button>a</button></div><div class=r><button disabled>b</button></div></div>
		<fieldset disabled id=fs><input id=fi></fieldset>`)
	defer rx_unload(l)
	l.st.state.controls = provider
	r1 := by_id(l, "r1")
	dom.remove_child(l.doc, by_id(l, "list"), r1)
	expect_partial(t, l, "a row holding a button removed (:disabled only)")
	row := dom.create_element(l.doc, "div")
	dom.set_attribute(l.doc, row, "class", "r")
	b := dom.create_element(l.doc, "button")
	dom.set_attribute(l.doc, b, "disabled", "")
	dom.append_child(l.doc, row, b)
	dom.append_child(l.doc, by_id(l, "list"), row)
	expect_partial(t, l, "a row holding a button inserted")
	dom.remove_attribute(l.doc, b, "disabled")
	expect_partial(t, l, "its disabled attribute removed")
	// the first legend of a disabled fieldset: what it holds is enabled, its siblings are not (restyled from the parent)
	lg := dom.create_element(l.doc, "legend")
	dom.insert_before(l.doc, by_id(l, "fs"), lg, by_id(l, "fi"))
	expect_partial(t, l, "a legend inserted in a disabled fieldset")
	dom.remove_child(l.doc, by_id(l, "fs"), lg)
	expect_partial(t, l, "and removed")

	g := rx_load(GROUPS + `<div id=d><p id=p>x</p><p>y</p></div>`)
	defer rx_unload(g)
	g.st.state.controls = provider
	q := by_id(g, "p")
	dom.remove_child(g.doc, by_id(g, "d"), q)
	dom.release(g.doc, q)
	expect_partial(t, g, "an element gone from a document without forms")
	in_ := dom.create_element(g.doc, "input")
	dom.append_child(g.doc, by_id(g, "d"), in_)
	expect_partial(t, g, "a control inserted outside any form")
	dom.set_attribute(g.doc, in_, "value", "b")
	expect_partial(t, g, "its value changed")
	// a control built the way components are (its type and name set, then put in): its attributes are restyled with it
	cb := dom.create_element(g.doc, "input")
	dom.set_attribute(g.doc, cb, "type", "checkbox")
	dom.set_attribute(g.doc, cb, "name", "n")
	dom.append_child(g.doc, by_id(g, "d"), cb)
	expect_partial(t, g, "a control inserted after its type and name were set")
	dom.set_attribute(g.doc, in_, "name", "b")
	_, ok3 := restyle_dom(g.eng, g.doc, g.st)
	testing.expect(t, !ok3 && g.eng.last_restyle.fallback == "form control attribute changed")
}

// Transitions start from the changes of a partial restyle; animations start in a subtree shown again and stop with
// elements removed.
@(test)
restyle_dom_animations :: proc(t: ^testing.T) {
	f := rx_load(`<style>.a { transition: color 1s } .a.on { color: red } @keyframes k { from { opacity: 0 } to { opacity: 1 } } .anim { animation: k 1s infinite }</style>
		<div id=x class=a>t</div><div id=hid style="display: none"><p class=anim>x</p></div>`)
	defer rx_unload(f)
	tl := timeline_make(f.eng)
	defer timeline_destroy(tl, f.st)
	timeline_restyled(tl, f.doc, nil, f.st, 0)
	testing.expect_value(t, timeline_running(tl), 0)
	x := by_id(f, "x")
	dom.set_attribute(f.doc, x, "class", "a on")
	expect_partial(t, f, "transition")
	timeline_restyled_dom(tl, f.doc, f.st, 16)
	testing.expect_value(t, timeline_running(tl), 1)
	dom.remove_attribute(f.doc, by_id(f, "hid"), "style")
	expect_partial(t, f, "shown")
	timeline_restyled_dom(tl, f.doc, f.st, 32)
	testing.expect_value(t, timeline_running(tl), 2)
	dom.remove_child(f.doc, dom.get(f.doc, x).parent, x)
	dom.release(f.doc, x)
	expect_partial(t, f, "removed")
	timeline_restyled_dom(tl, f.doc, f.st, 48)
	testing.expect_value(t, timeline_running(tl), 1)
	timeline_tick(tl, f.doc, f.st, 64)
}

@(test)
restyle_dom_journal_and_records :: proc(t: ^testing.T) {
	f := rx_load(`<style>.w { width: 10px } .c { color: red }</style><div id=a>x</div><div id=b>y</div>`)
	defer rx_unload(f)
	a, b := by_id(f, "a"), by_id(f, "b")
	pass := f.st.pass_id
	rec_b := style_of(f.st, b)
	s0 := f.st.serial
	dom.set_attribute(f.doc, a, "class", "c")
	expect_partial(t, f, "paint-only change")
	es, ok := journal_since(f.st, s0)
	testing.expect(t, ok && len(es) == 1 && es[0].node == a && es[0].level == .Paint)
	testing.expect_value(t, f.st.layout_serial, f.st.layout_serial)   // unchanged by a paint-only change...
	testing.expect(t, f.st.layout_serial < f.st.serial)
	s1 := f.st.serial
	dom.set_attribute(f.doc, a, "class", "c w")
	expect_partial(t, f, "layout change")
	es2, _ := journal_since(f.st, s1)
	testing.expect(t, len(es2) == 1 && es2[0].level == .Layout)
	testing.expect_value(t, f.st.layout_serial, f.st.serial)
	// records of elements not concerned stay; the pass keeps its identity
	testing.expect(t, style_of(f.st, b) == rec_b)
	testing.expect_value(t, f.st.pass_id, pass)
	// restyled to the same values: the record stays and nothing is left behind
	used := f.st.arena.total_used
	s2 := f.st.serial
	dom.set_attribute(f.doc, b, "style", "")
	expect_partial(t, f, "no change", 1)
	testing.expect(t, style_of(f.st, b) == rec_b)
	testing.expect_value(t, f.st.serial, s2)
	testing.expect_value(t, f.st.arena.total_used, used)
}

// A class on <body> that every section's descendants depend on (a rule whose subject has no class, id or tag to look for:
// .wide :not(.nz)): the forced subtree is shared out between threads, with the result of a full pass.
@(test)
restyle_dom_parallel :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `<style>.wide section p { margin-left: 3px } .wide :not(.nz) { padding-top: 1px } .wide b::before { content: "x" counter(sec) } section { counter-increment: sec } .wide { font-size: 18px } p + p { color: red }</style><body>`)
	for i in 0 ..< 400 { fmt.sbprintf(&sb, "<section class=k%d><p><b>t</b></p><p>u</p><ol><li>a</li><li>b</li></ol></section>", i % 5) }
	f := rx_load(strings.to_string(sb))
	defer rx_unload(f)
	pool := host.thread_pool_make(3)
	defer host.thread_pool_destroy(pool)
	f.eng.settings.inc_parallel_min = 100
	body := dom.find_first_by_tag(f.doc, "body")
	for round in 0 ..< 3 {
		dom.set_attribute(f.doc, body, "class", round % 2 == 0 ? "wide" : "")
		_, ok := restyle_dom(f.eng, f.doc, f.st, pool)
		testing.expectf(t, ok, "round %d: not partial (%s)", round, f.eng.last_restyle.fallback)
		testing.expect(t, f.eng.last_restyle.parallel, "the forced subtree went to the threads")
		diff := verify_styles(f.eng, f.doc, f.st, context.temp_allocator)
		testing.expectf(t, diff == "", "round %d: %s", round, diff)
	}
	// a class on one section: few elements, on this thread
	sec := dom.get(f.doc, body).first_child
	for sec != base.NIL_HANDLE && dom.get(f.doc, sec).name != "section" { sec = dom.get(f.doc, sec).next }
	dom.set_attribute(f.doc, sec, "class", "wide")
	_, ok := restyle_dom(f.eng, f.doc, f.st, pool)
	testing.expect(t, ok && !f.eng.last_restyle.parallel)
	testing.expect_value(t, verify_styles(f.eng, f.doc, f.st, context.temp_allocator), "")
}

// One element marked, what it passes on reaching a large subtree (cnn.com: 4 300 elements forced by one change, 300 ms on this thread, a full
// pass of all 11 000 on the threads costing 70): it goes to the threads, as a subtree marked whole does.
@(test)
restyle_dom_parallel_what_an_inherited_change_forces :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `<style>.on { color: red }</style><body><div id=big><main>`)
	for _ in 0 ..< 300 { strings.write_string(&sb, "<section><p><b>t</b></p></section>") }
	strings.write_string(&sb, `</main></div><div id=small><i>u</i></div>`)
	f := rx_load(strings.to_string(sb))
	defer rx_unload(f)
	pool := host.thread_pool_make(3)
	defer host.thread_pool_destroy(pool)
	f.eng.settings.inc_parallel_min = 100
	dom.set_attribute(f.doc, by_id(f, "small"), "class", "on")
	_, ok := restyle_dom(f.eng, f.doc, f.st, pool)
	testing.expect(t, ok && !f.eng.last_restyle.parallel, "a small subtree stays on this thread")
	dom.set_attribute(f.doc, by_id(f, "big"), "class", "on")
	_, ok = restyle_dom(f.eng, f.doc, f.st, pool)
	testing.expect(t, ok && f.eng.last_restyle.parallel, "the subtree went to the threads")
	testing.expect_value(t, verify_styles(f.eng, f.doc, f.st, context.temp_allocator), "")
}

// A reach of many subjects still names them: past a hundred classes it restyled the whole subtree.
@(test)
restyle_dom_many_subjects_stay_a_set :: proc(t: ^testing.T) {
	SUBJECTS :: 300
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "<style>")
	for i in 0 ..< SUBJECTS { fmt.sbprintf(&sb, ".a .k%d ", i); strings.write_string(&sb, "{ margin: 1px } ") }
	strings.write_string(&sb, "</style><div id=x><i class=k7>k</i>")
	strings.write_string(&sb, boxes(BOXES, BOX_SPANS, "box"))
	strings.write_string(&sb, "</div>")
	f := rx_load(strings.to_string(sb))
	defer rx_unload(f)
	dom.set_attribute(f.doc, by_id(f, "x"), "class", "a")
	expect_partial(t, f, "the class of the ancestors", 2)
}

// Rules are tried for the elements that can match them: `[data-q]`, `:root`, `:is(.a, b)` in a list of their own, not for every element.
@(test)
rules_are_listed_by_what_their_subject_requires :: proc(t: ^testing.T) {
	f := rx_load(`<style>:root { margin: 1px } [data-q] { margin: 2px } [title^=x] { margin: 3px } :is(.a, b) { margin: 4px } :where(#i, u) > :is(.c, [lang]) { margin: 5px } * { padding: 1px } :is(.a, *) { padding: 2px }</style>
		<body><p id=d data-q=ltr></p><p id=t title=xy></p><p id=two class=a><b id=b></b></p><u><i id=c class=c></i><i id=l lang=fr></i></u>`)
	defer rx_unload(f)
	ix := &f.eng.rules.index
	universal_before := 0
	for ent in ix.universal { if ent.rule.origin != .Author { universal_before += 1 } }
	testing.expect_value(t, len(ix.root), 1)
	testing.expect_value(t, len(ix.by_attr_name["data-q"]), 1)
	testing.expect_value(t, len(ix.by_attr_name["title"]), 1)
	testing.expect_value(t, len(ix.universal) - universal_before, 2)   // (`*`, and `:is(.a, *)`)
	margin :: proc(f: ^Rx, id: string) -> f32 { return style_of(f.st, by_id(f, id)).margin[.Top].v }
	testing.expect_value(t, style_of(f.st, dom.find_first_by_tag(f.doc, "html")).margin[.Top].v, f32(1))
	testing.expect_value(t, margin(f, "d"), f32(2))
	testing.expect_value(t, margin(f, "t"), f32(3))
	testing.expect_value(t, margin(f, "two"), f32(4))
	testing.expect_value(t, margin(f, "b"), f32(4))
	testing.expect_value(t, margin(f, "c"), f32(5))
	testing.expect_value(t, margin(f, "l"), f32(5))
}

// A text that comes or goes concerns the anchors that read :empty, not all of them.
@(test)
restyle_dom_text_reaches_the_anchors_of_empty :: proc(t: ^testing.T) {
	f := rx_load(strings.concatenate({`<style>.t:has(.m ~ .n) * { color: red } .u:has(:empty) { color: blue }</style><div id=t class=t><i class=m></i><i class=n>n</i><p id=p>x</p>`, boxes(BOXES, BOX_SPANS, "box"), `</div>`}, context.temp_allocator))
	defer rx_unload(f)
	dom.set_text_content(f.doc, by_id(f, "p"), "")
	expect_partial(t, f, "a text gone under an anchor that does not read it", 1)
}

// The index is built again for each sheet that comes, and from the same subjects: their unions are found, not made (cnn.com: 9 % of its
// style passes went in reach_union, for each of a dozen sheets).
@(test)
restyle_dom_unions_of_subjects_are_kept :: proc(t: ^testing.T) {
	f := rx_load(`<style>.a .x { color: red } .a .y { color: blue } .a .z { color: green }</style><body><p class=a>`)
	defer rx_unload(f)
	_ = inv_index(f.eng)
	unions, sets := len(f.eng.key_sets.unions), len(f.eng.key_sets.sets)
	testing.expect(t, unions > 0, "the rules of .a reach several subjects")
	f.eng.rebuilds += 1
	_ = inv_index(f.eng)
	testing.expect_value(t, len(f.eng.key_sets.unions), unions)
	testing.expect_value(t, len(f.eng.key_sets.sets), sets)
}

// A subtree restyled by the threads with a forms model: what the model fills in lazily is filled in on this thread first, as a full
// pass does (two threads building a radio group's list crashed in cnn.com's restyles, once its restyles were large enough).
@(test)
restyle_dom_parallel_settles_the_controls :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `<style>.wide :not(.nz) { padding-top: 1px }</style><body>`)
	for _ in 0 ..< 400 { strings.write_string(&sb, "<section><p>t</p><ol><li>a</li></ol></section>") }
	f := rx_load(strings.to_string(sb))
	defer rx_unload(f)
	pool := host.thread_pool_make(3)
	defer host.thread_pool_destroy(pool)
	f.eng.settings.inc_parallel_min = 100
	settled := 0
	f.st.state.controls = Control_Provider{
		query = proc(user: rawptr, el: base.Handle, q: Control_Query) -> (bool, bool) { return false, false },
		settle = proc(user: rawptr) { (^int)(user)^ += 1 },
		user = &settled,
	}
	dom.set_attribute(f.doc, dom.find_first_by_tag(f.doc, "body"), "class", "wide")
	_, ok := restyle_dom(f.eng, f.doc, f.st, pool)
	testing.expectf(t, ok, "not partial (%s)", f.eng.last_restyle.fallback)
	testing.expect(t, f.eng.last_restyle.parallel, "the subtree went to the threads")
	testing.expect_value(t, settled, 1)
}

// A class on the root element that changes its font size or line height, its subtree large enough for the threads:
// the root is restyled on this thread, where the change of the root font size is seen (the deferred root was not
// checked: every rem kept the old size); a change of the root line height (rlh) falls back to a full pass as well.
@(test)
restyle_dom_root_font_with_threads :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `<style>html.big { font-size: 32px } html.tall { line-height: 40px } html.big p, html.tall p { color: red } p { width: 1rem; height: 1rlh }</style><body>`)
	for _ in 0 ..< 400 { strings.write_string(&sb, "<section><p>t</p><p>u</p></section>") }
	f := rx_load(strings.to_string(sb))
	defer rx_unload(f)
	pool := host.thread_pool_make(3)
	defer host.thread_pool_destroy(pool)
	f.eng.settings.inc_parallel_min = 100
	root := dom.find_first_by_tag(f.doc, "html")
	for cls in ([]string{"big", "", "tall", ""}) {
		dom.set_attribute(f.doc, root, "class", cls)
		if _, ok := restyle_dom(f.eng, f.doc, f.st, pool); !ok {
			old := f.st
			f.st = compute_styles(f.eng, f.doc, {})
			styled_destroy(old)
		}
		diff := verify_styles(f.eng, f.doc, f.st, context.temp_allocator)
		testing.expectf(t, diff == "", "class %q: %s", cls, diff)
	}
}

////////////////////////////////
// A place among siblings, read by key

// A list of `n` boxes of `each` spans, each box of class `cls`.
@(private = "file")
boxes :: proc(n, each: int, cls: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< n {
		fmt.sbprintf(&sb, "<div class=%q>", cls)
		for _ in 0 ..< each { strings.write_string(&sb, "<span>x</span>") }
		strings.write_string(&sb, "</div>")
	}
	return strings.to_string(sb)
}

@(private = "file")
BOXES :: 20
@(private = "file")
BOX_SPANS :: 5

// cnn.com: `.zone--t-dark + .flex-experiment :is(...)` and `:last-child` compounds: a <div> added to or removed from <body> restyled every child
// of it whole, a third of the document.
@(test)
restyle_dom_removal_reaches_what_follows_it :: proc(t: ^testing.T) {
	f := rx_load(strings.concatenate({`<style>.a + .b .c { color: red } .q + .r * { margin: 1px }</style><div id=l><p id=a class=a>a</p><p id=gap>g</p><div id=b class=b><i id=c class=c>c</i></div>`, boxes(BOXES, BOX_SPANS, "box"), `</div>`}, context.temp_allocator))
	defer rx_unload(f)
	testing.expect(t, style_of(f.st, by_id(f, "c")).color != {1, 0, 0, 1})
	dom.remove_child(f.doc, by_id(f, "l"), by_id(f, "gap"))
	expect_partial(t, f, "the element between .a and .b removed", 3)
	testing.expect(t, style_of(f.st, by_id(f, "c")).color == {1, 0, 0, 1})
}

@(test)
restyle_dom_insertion_reaches_by_the_key_of_the_position :: proc(t: ^testing.T) {
	f := rx_load(strings.concatenate({`<style>.w:last-child * { color: red } .z:first-child * { color: blue } p:nth-child(2) * { color: green }</style><div id=l><div id=w class=w><b id=wb>x</b></div>`, boxes(BOXES, BOX_SPANS, "box"), `</div>`}, context.temp_allocator))
	defer rx_unload(f)
	l := by_id(f, "l")
	dom.append_child(f.doc, l, dom.create_element(f.doc, "div"))
	expect_partial(t, f, "an element added after boxes no rule reads the place of", 3)   // (it, and .w and what it holds: no longer the last)
	w := by_id(f, "w")
	dom.remove_child(f.doc, l, w)
	dom.append_child(f.doc, l, w)
	expect_partial(t, f, ".w moved to the end", 3)
	testing.expect(t, style_of(f.st, by_id(f, "wb")).color == {1, 0, 0, 1})
}

// `:nth-last-child(1 of .z)`: only an element of .z can match, whatever the walk of the siblings meets.
@(test)
restyle_dom_nth_of_selector_is_read_by_its_keys :: proc(t: ^testing.T) {
	f := rx_load(strings.concatenate({`<style>:nth-last-child(1 of .z) * { color: red }</style><div id=l><div id=z class=z><b id=zb>x</b></div>`, boxes(BOXES, BOX_SPANS, "box"), `</div>`}, context.temp_allocator))
	defer rx_unload(f)
	n := dom.create_element(f.doc, "div")
	dom.append_child(f.doc, by_id(f, "l"), n)
	expect_partial(t, f, "a plain element added", 3)
	testing.expect(t, style_of(f.st, by_id(f, "zb")).color == {1, 0, 0, 1})
	dom.set_attribute(f.doc, n, "class", "z")
	expect_partial(t, f, "the last one is .z now")
	testing.expect(t, style_of(f.st, by_id(f, "zb")).color != {1, 0, 0, 1})
}

// The subjects a sibling's change restyles under the element beside it: those of an :is(), or of an attribute, not the whole subtree.
@(test)
restyle_dom_subjects_of_is_and_attributes :: proc(t: ^testing.T) {
	f := rx_load(strings.concatenate({`<style>.p + .q :is(h2, h3) { color: red } .p + .q [data-k] { color: blue }</style><div id=l><p id=p class=p>p</p><p id=gap>g</p><div id=q class=q><h2 id=h>t</h2><b id=k data-k>u</b>`, boxes(BOXES, BOX_SPANS, "box"), `</div></div>`}, context.temp_allocator))
	defer rx_unload(f)
	dom.remove_child(f.doc, by_id(f, "l"), by_id(f, "gap"))
	expect_partial(t, f, "the gap closed", 3)
	testing.expect(t, style_of(f.st, by_id(f, "h")).color == {1, 0, 0, 1})
	testing.expect(t, style_of(f.st, by_id(f, "k")).color == {0, 0, 1, 1})
}

// What rules of any element reach beside it says nothing of what they reach under it: `:not(.z) *` left no set for `:not(.b) ~ .c .d`.
@(test)
restyle_dom_keyless_reach_keeps_its_subjects :: proc(t: ^testing.T) {
	f := rx_load(strings.concatenate({`<style>:not(.z) * { margin: 1px } :not(.b) ~ .c .d { color: red }</style><div id=l><div id=x class=b>x</div><div id=c class=c><i id=d class=d>d</i>`, boxes(BOXES, BOX_SPANS, "box"), `</div></div>`}, context.temp_allocator))
	defer rx_unload(f)
	l := by_id(f, "l")
	dom.insert_before(f.doc, l, dom.create_element(f.doc, "p"), by_id(f, "x"))
	expect_partial(t, f, "an element that matches the left compound added", 4)
	testing.expect(t, style_of(f.st, by_id(f, "d")).color == {1, 0, 0, 1})
}

// What a removed element showed its siblings when the styles were made, not what it has now.
@(test)
restyle_dom_removed_element_as_it_was :: proc(t: ^testing.T) {
	f := rx_load(`<style>.a ~ .b { color: red } .e + .f { color: blue }</style><div id=l><p id=a class=a>a</p><p id=gone>t</p><p id=b class=b>b</p><p id=e class=e>e</p><p id=f class=f>f</p><p id=g>g</p></div>`)
	defer rx_unload(f)
	l := by_id(f, "l")
	a := by_id(f, "a")
	dom.remove_attribute(f.doc, a, "class")
	dom.remove_child(f.doc, l, a)
	expect_partial(t, f, "class taken away, then the element")
	testing.expect(t, style_of(f.st, by_id(f, "b")).color != {1, 0, 0, 1})
	// the node beside it left too: its place is not known
	e, ff, g := by_id(f, "e"), by_id(f, "f"), by_id(f, "g")
	dom.remove_child(f.doc, l, e)
	dom.remove_child(f.doc, l, ff)
	dom.insert_before(f.doc, l, ff, g)
	dom.insert_before(f.doc, l, e, ff)
	expect_partial(t, f, "both taken out and put back")
	testing.expect(t, style_of(f.st, ff).color == {0, 0, 1, 1})
	dom.remove_child(f.doc, l, e)
	dom.release(f.doc, e)
	expect_partial(t, f, "the element destroyed")
	testing.expect(t, style_of(f.st, ff).color != {0, 0, 1, 1})
}

// `:has(.h .m)`: a class attribute rewritten above a member says nothing of the chain unless a class it names came or went
// (cnn.com: `layout  cnn` to `layout cnn` on <body>, and every anchor of the page restyled).
@(test)
restyle_dom_has_chain_reads_the_classes_that_changed :: proc(t: ^testing.T) {
	f := rx_load(strings.concatenate({`<style>.t:has(.h .m) * { color: red }</style><div id=t class=t><div id=h class="h  k"><i class=m>m</i></div>`, boxes(BOXES, BOX_SPANS, "box"), `</div>`}, context.temp_allocator))
	defer rx_unload(f)
	h := by_id(f, "h")
	dom.set_attribute(f.doc, h, "data-a", "1")
	expect_partial(t, f, "the first restyle makes the members")
	member :: proc(f: ^Rx, h: base.Handle) {
		n := dom.create_element(f.doc, "i")
		dom.set_attribute(f.doc, n, "class", "m")
		dom.append_child(f.doc, h, n)
	}
	// (with a member that comes, which asks whether the answer flipped)
	dom.set_attribute(f.doc, h, "class", "h k")
	member(f, h)
	expect_partial(t, f, "spaces", 1)
	dom.set_attribute(f.doc, h, "class", "h k z")
	member(f, h)
	expect_partial(t, f, "a class the chain does not name", 1)
	dom.set_attribute(f.doc, h, "class", "k z")
	expect_partial(t, f, "the class of the chain")
	testing.expect(t, f.eng.last_restyle.marked > BOXES)
}

// What the flips of an anchor cost: its members walked up once a batch, not for each element asked about.
@(test)
restyle_dom_has_flips_walk_the_members_once :: proc(t: ^testing.T) {
	DEPTH :: 12
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `<style>div:has(.m) > .y { color: red }</style>`)
	for _ in 0 ..< DEPTH { strings.write_string(&sb, `<div class=y>`) }
	strings.write_string(&sb, `<div id=in>`)
	for _ in 0 ..< BOXES { strings.write_string(&sb, `<i class=m>m</i>`) }
	strings.write_string(&sb, `</div>`)
	for _ in 0 ..< DEPTH { strings.write_string(&sb, `</div>`) }
	f := rx_load(strings.to_string(sb))
	defer rx_unload(f)
	dom.set_attribute(f.doc, by_id(f, "in"), "data-a", "1")
	expect_partial(t, f, "the first restyle makes the members")
	n := dom.create_element(f.doc, "i")
	dom.set_attribute(f.doc, n, "class", "m")
	dom.append_child(f.doc, by_id(f, "in"), n)
	expect_partial(t, f, "one more member")
	testing.expect(t, f.eng.last_restyle.flips >= DEPTH)
	testing.expectf(t, f.eng.last_restyle.flip_steps <= 2 * (BOXES + 2 * DEPTH), "%d steps", f.eng.last_restyle.flip_steps)
}

// Random mutations

@(private = "file")
RANDOM_CSS :: `
.a { color: rgb(200, 0, 0) } .b { font-size: 18px } .c { padding: 2px } .d { display: none } .e { --v: 4px }
.a .b { margin: 1px } .a > .c { border: 1px solid } .b + .c { color: green } .c ~ .d { display: block } .e p { padding: var(--v, 9px) }
li:nth-child(2n+1) { color: blue } li:first-child { font-weight: bold } li:last-child { margin-bottom: 3px } li:nth-last-child(2) { padding-left: 1px }
p:empty { min-height: 5px } section:has(.a) { outline: 1px solid red } div:has(> .e) { margin-top: 2px }
[data-x="1"] { letter-spacing: 1px } [data-x] span { word-spacing: 2px } #k1 { width: 50px } #k2 .a { height: 10px }
.f::before { content: "<" attr(data-x) ">" } ol li::after { content: counter(list-item) } h3 { counter-increment: hh } h3::before { content: counter(hh) ": " }
:is(.a, .b) > span { text-indent: 3px } div:not(.c) > p { text-align: center } .g { font-size: 1.5em } .h { border-width: inherit; border-style: solid }
section > :first-child + * { line-height: 2 } .a:nth-child(3) ~ li { color: purple }
.b + .c span { color: olive } .c ~ .d > span { color: navy } .e + :is(div, p) b { color: maroon } :is(.f, .g) ~ .h span { color: lime }
:nth-last-child(1 of .a) span { color: aqua } .a:not(.x) + * { letter-spacing: 2px } :not(.a) + .b .c { color: gray } .b + [data-x] span { color: silver }
:first-child ~ .g > * { margin-left: 1px } .x:last-child span { color: fuchsia } :not(.d) ~ .f { word-spacing: 1px }
`

@(private = "file")
RESTYLE_SEED :: #config(RESTYLE_SEED, 20261019)
// (each a document and its mutations of its own: what goes wrong among siblings needs the right neighbours)
@(private = "file")
RESTYLE_SEEDS :: 6

@(private = "file")
TAGS := [?]string{"div", "p", "span", "section", "li", "ul", "ol", "h3", "b"}
@(private = "file")
CLASSES := [?]string{"a", "b", "c", "d", "e", "f", "g", "h", "x"}

@(test)
restyle_dom_random :: proc(t: ^testing.T) {
	for seed in 0 ..< RESTYLE_SEEDS {
		restyle_dom_random_from(t, RESTYLE_SEED + u64(seed))
		if t.error_count > 0 { return }
	}
}

@(private = "file")
restyle_dom_random_from :: proc(t: ^testing.T, seed: u64) {
	rng := rand.create(seed)
	context.random_generator = rand.default_random_generator(&rng)
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "<style>%s</style><div id=root>", RANDOM_CSS)
	for i in 0 ..< 60 {
		tag := TAGS[rand.int_max(len(TAGS))]
		fmt.sbprintf(&sb, "<%s class=%q>t%d<%s>u</%s></%s>", tag, CLASSES[rand.int_max(len(CLASSES))], i, tag == "ul" || tag == "ol" ? "li" : "span", tag == "ul" || tag == "ol" ? "li" : "span", tag)
	}
	strings.write_string(&sb, "</div>")
	f := rx_load(strings.to_string(sb))
	defer rx_unload(f)

	elements :: proc(f: ^Rx) -> [dynamic]base.Handle {
		out := make([dynamic]base.Handle, context.temp_allocator)
		root := by_id(f, "root")
		stack := make([dynamic]base.Handle, context.temp_allocator)
		append(&stack, root)
		for len(stack) > 0 {
			h := pop(&stack)
			n := dom.get(f.doc, h)
			if n.kind != .Element { continue }
			if h != root { append(&out, h) }
			for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(f.doc, ch).next { append(&stack, ch) }
		}
		return out
	}
	steps := 500
	batch := make([dynamic]string, context.temp_allocator)
	for step in 0 ..< steps {
		els := elements(f)
		if len(els) < 10 { break }
		x := els[rand.int_max(len(els))]
		what := ""
		switch rand.int_max(9) {
		case 0, 1:
			what = "class"
			cls := strings.concatenate({CLASSES[rand.int_max(len(CLASSES))], " ", CLASSES[rand.int_max(len(CLASSES))]}, context.temp_allocator)
			if rand.int_max(4) == 0 { dom.remove_attribute(f.doc, x, "class") } else { dom.set_attribute(f.doc, x, "class", cls) }
		case 2:
			what = "data-x"
			if rand.int_max(3) == 0 { dom.remove_attribute(f.doc, x, "data-x") } else { dom.set_attribute(f.doc, x, "data-x", rand.int_max(2) == 0 ? "1" : "2") }
		case 3:
			what = "id"
			dom.set_attribute(f.doc, x, "id", rand.int_max(2) == 0 ? "k1" : "k2")
		case 4, 5:
			what = "insert"
			tag := TAGS[rand.int_max(len(TAGS))]
			n := dom.create_element(f.doc, tag)
			dom.set_attribute(f.doc, n, "class", CLASSES[rand.int_max(len(CLASSES))])
			if rand.int_max(2) == 0 { dom.append_child(f.doc, n, dom.create_text(f.doc, "n")) }
			p := dom.get(f.doc, x).parent
			if rand.int_max(2) == 0 { dom.insert_before(f.doc, p, n, x) } else { dom.append_child(f.doc, x, n) }
		case 6:
			what = "remove"
			p := dom.get(f.doc, x).parent
			dom.remove_child(f.doc, p, x)
			if rand.int_max(2) == 0 { dom.release(f.doc, x) } else {
				// moved elsewhere
				y := els[rand.int_max(len(els))]
				if y != x && !dom.is_ancestor_or_self(f.doc, x, y) { dom.append_child(f.doc, y, x) } else { dom.release(f.doc, x) }
			}
		case 7:
			what = "text"
			if rand.int_max(2) == 0 { dom.set_text_content(f.doc, x, rand.int_max(3) == 0 ? "" : "txt") } else { dom.append_child(f.doc, x, dom.create_text(f.doc, "more")) }
		case 8:
			what = "style"
			dom.set_attribute(f.doc, x, "style", rand.int_max(2) == 0 ? "font-size: 12px" : "color: teal")
		}
		{ xn := dom.get(f.doc, x); cl := ""; if xn != nil { cl, _ = attr(xn, "class") }; append(&batch, fmt.tprintf("%s on <%s class=%q> %v", what, xn != nil ? xn.name : "?", cl, x)) }
		// sometimes several mutations before a restyle
		if rand.int_max(3) == 0 { continue }
		rx_step(t, f, fmt.tprintf("step %d (%v)", step, batch[:]))
		clear(&batch)
		if t.error_count > 0 { return }
	}
	log.infof("random mutations: %d partial restyles, %d full", f.partial, f.full)
	testing.expectf(t, f.partial > 150, "%d partial restyles, %d full", f.partial, f.full)
}

// A :has() whose anchor is any element (`:has(ghost-el) .y`: YouTube's rules): elements that come or go restyle the anchors' subtrees
// only when their features (tag, class, id, attribute names) are some the argument names; any other insertion or removal, a
// removed node already destroyed included (the journal keeps its features), restyles the elements themselves.
@(test)
restyle_dom_has_bare_anchor :: proc(t: ^testing.T) {
	f := rx_load(`<style>:has(ghost-el) .y { margin: 1px } :has(.flag) .y { padding: 2px } :has(#spot) .y { color: red }</style>
		<div id=a><p class=y>u</p><p class=y>v</p><div id=box></div></div>`)
	defer rx_unload(f)
	box := by_id(f, "box")
	e := dom.create_element(f.doc, "span")
	dom.set_attribute(f.doc, e, "class", "other")
	dom.append_child(f.doc, box, e)
	expect_partial(t, f, "an unrelated element inserted", 3)
	dom.remove_child(f.doc, box, e)
	dom.release(f.doc, e)
	expect_partial(t, f, "an unrelated element removed and destroyed", 3)
	g := dom.create_element(f.doc, "ghost-el")
	dom.append_child(f.doc, box, g)
	expect_partial(t, f, "the element a :has() names inserted")
	testing.expect(t, f.eng.last_restyle.marked >= 3, "the paragraphs under the anchors were restyled")
	dom.remove_child(f.doc, box, g)
	dom.release(f.doc, g)
	expect_partial(t, f, "and removed, destroyed")
	testing.expect(t, f.eng.last_restyle.marked >= 2, "the paragraphs again")
	w := dom.create_element(f.doc, "div")
	dom.set_attribute(f.doc, w, "class", "flag")
	dom.append_child(f.doc, box, w)
	expect_partial(t, f, "a class a :has() names, inserted with its subtree")
	h := dom.create_element(f.doc, "i")
	dom.set_attribute(f.doc, h, "id", "spot")
	dom.append_child(f.doc, w, h)
	expect_partial(t, f, "an id a :has() names, in what was inserted")
	dom.remove_child(f.doc, box, w)
	dom.release(f.doc, w)
	expect_partial(t, f, "the subtree that held both removed and destroyed")
}

// The walk for the members of the exact anchors tests an element against the anchors its class tokens, id, attributes and tag name,
// not against all of them: each element here has one, of a hundred anchors. It ran after every full pass: on CNN, with its anchors and
// 11 500 elements, a good part of the window thread's time.
@(test)
restyle_dom_has_members_found_by_their_keys :: proc(t: ^testing.T) {
	ANCHORS :: 100
	ELEMENTS :: 300
	src := strings.builder_make(context.temp_allocator)
	strings.write_string(&src, `<style>:has(#solo) .y { margin: 1px } :has([data-x]) .y { margin: 2px } :has(ghost-el) .y { margin: 3px } :has(.two.k1) .y { margin: 4px }`)
	for i in 0 ..< ANCHORS { fmt.sbprintf(&src, ` :has(.k%d) .y {{ padding: %dpx }}`, i, i) }
	strings.write_string(&src, `</style><div id=box><p class=y>u</p><i id=solo></i><i data-x=1></i><ghost-el></ghost-el><i class="k1 two"></i>`)
	for i in 0 ..< ELEMENTS { fmt.sbprintf(&src, `<i class="k%d"></i>`, i % ANCHORS) }
	strings.write_string(&src, `</div>`)
	f := rx_load(strings.to_string(src))
	defer rx_unload(f)
	dom.set_attribute(f.doc, by_id(f, "box"), "title", "x")
	expect_partial(t, f, "a first change")   // (it takes the members)
	ix := inv_index(f.eng)
	testing.expect_value(t, len(ix.has_anchors), ANCHORS + 4)
	KEYED :: 2 * ELEMENTS   // (about one an element: every element against every anchor is ELEMENTS * ANCHORS)
	testing.expectf(t, ix.members_tested <= KEYED, "%d tests of an element against an argument, at most %d expected", ix.members_tested, KEYED)
	for &ha in ix.has_anchors {
		want := len(ha.arg.simples) == 2 || ha.arg.simples[0].kind != .Class ? 1 : ELEMENTS / ANCHORS
		if ha.arg.simples[0].name == "k1" && len(ha.arg.simples) == 1 { want += 1 }
		testing.expectf(t, ha.members != nil && len(ha.members.set) == want, "%s: %d members, %d expected", ha.arg.simples[0].name, ha.members == nil ? -1 : len(ha.members.set), want)
	}
}

// A :has() of tags, ids, classes and attributes keeps the elements that match its argument; the subtree of an anchor is restyled
// when its answer flips (the first member under it comes, the last one leaves), not whenever one more comes or goes.
@(test)
restyle_dom_has_exact :: proc(t: ^testing.T) {
	f := rx_load(`<style>:has(ghost-el) .y { margin: 1px } :has(> .kid) .z { padding: 2px }</style>
		<div id=a><p class=y>u</p><p class=z>w</p><div id=box><ghost-el id=g1></ghost-el></div><div id=other></div></div>`)
	defer rx_unload(f)
	box, other := by_id(f, "box"), by_id(f, "other")
	// (the first restyle makes the watch and takes the members: the page does it after its full pass)
	dom.set_attribute(f.doc, other, "title", "x")
	expect_partial(t, f, "a first change")
	// one more member under anchors that were true already: nothing above it is restyled
	g2 := dom.create_element(f.doc, "ghost-el")
	dom.append_child(f.doc, box, g2)
	expect_partial(t, f, "a second member under anchors that were true", 2)
	// one of two leaves: still true everywhere
	dom.remove_child(f.doc, box, g2)
	dom.release(f.doc, g2)
	expect_partial(t, f, "one of two members removed and destroyed", 2)
	// a member moved to another parent: the anchors that held it still do, `box` loses it and `other` gets it
	g1 := by_id(f, "g1")
	dom.remove_child(f.doc, box, g1)
	dom.append_child(f.doc, other, g1)
	expect_partial(t, f, "the only member moved to a sibling")
	// the last one gone: every anchor above it flips
	dom.remove_child(f.doc, other, g1)
	dom.release(f.doc, g1)
	expect_partial(t, f, "the last member removed and destroyed")
	testing.expect(t, f.eng.last_restyle.marked >= 1, "the paragraph under the anchors was restyled")
	g3 := dom.create_element(f.doc, "ghost-el")
	dom.append_child(f.doc, box, g3)
	expect_partial(t, f, "the first member again")
	testing.expect(t, f.eng.last_restyle.marked >= 1, "and again")
	// by a class changing
	dom.set_attribute(f.doc, g3, "class", "kid")
	expect_partial(t, f, "a class that makes it a child member of the other rule")
	dom.remove_attribute(f.doc, g3, "class")
	expect_partial(t, f, "and not any more")
	// :has(> .kid): only the parent is an anchor
	k := dom.create_element(f.doc, "span")
	dom.set_attribute(f.doc, k, "class", "kid")
	dom.append_child(f.doc, other, k)
	expect_partial(t, f, "a child member of a :has(> .kid) anchor")
	k2 := dom.create_element(f.doc, "span")
	dom.set_attribute(f.doc, k2, "class", "kid")
	dom.append_child(f.doc, other, k2)
	expect_partial(t, f, "a second one: the answer is the same", 2)
}

// A member removed from where the chain did not hold (no [role] above it, none in what was removed) was part of no true answer: nothing
// is restyled; one removed from under a [role] flips the answer (YouTube adds and removes such members all the time).
@(test)
restyle_dom_has_chain_removal :: proc(t: ^testing.T) {
	// (the subject is `*`: an answer that flips restyles the whole subtree of the anchor)
	f := rx_load(`<style>:has([role]:not([aria-hidden]) .k) * { margin: 1px }</style>
		<div id=a><p class=y id=y>u</p><div id=r role=x><b></b></div><div id=other><i id=i></i></div></div>`)
	defer rx_unload(f)
	r, other := by_id(f, "r"), by_id(f, "other")
	dom.set_attribute(f.doc, other, "title", "x")
	expect_partial(t, f, "a first change")
	k2 := dom.create_element(f.doc, "span")
	dom.set_attribute(f.doc, k2, "class", "k")
	dom.append_child(f.doc, other, k2)
	expect_partial(t, f, "a member where the chain does not hold", 3)
	dom.remove_child(f.doc, other, k2)
	dom.release(f.doc, k2)
	expect_partial(t, f, "that member removed and destroyed", 3)
	k3 := dom.create_element(f.doc, "span")
	dom.set_attribute(f.doc, k3, "class", "k")
	dom.append_child(f.doc, r, k3)
	expect_partial(t, f, "a member under a [role]: the answer flips")
	testing.expect(t, f.eng.last_restyle.marked >= 5, "the subtree of the anchors was restyled")
	dom.remove_child(f.doc, r, k3)
	dom.release(f.doc, k3)
	expect_partial(t, f, "that member removed: the answer flips back")
	testing.expect(t, f.eng.last_restyle.marked >= 5, "the subtree of the anchors was restyled again")
	// an attribute change on the way: the ancestor loses its role in the batch that removes the member
	k4 := dom.create_element(f.doc, "span")
	dom.set_attribute(f.doc, k4, "class", "k")
	dom.append_child(f.doc, r, k4)
	expect_partial(t, f, "a member under the [role] again")
	dom.remove_attribute(f.doc, r, "role")
	dom.remove_child(f.doc, r, k4)
	dom.release(f.doc, k4)
	expect_partial(t, f, "role and member gone in one batch")
	testing.expect(t, f.eng.last_restyle.marked >= 5, "and the answer flipped")
	// the head stops matching (aria-hidden): the member under it is not held any more, so its removal flips nothing
	dom.set_attribute(f.doc, r, "role", "x")
	expect_partial(t, f, "the role is back")
	k5 := dom.create_element(f.doc, "span")
	dom.set_attribute(f.doc, k5, "class", "k")
	dom.append_child(f.doc, r, k5)
	expect_partial(t, f, "a member under the [role]")
	testing.expect(t, f.eng.last_restyle.marked >= 5, "flipped to true")
	dom.set_attribute(f.doc, r, "aria-hidden", "true")
	expect_partial(t, f, "the head is hidden: flipped to false")
	testing.expect(t, f.eng.last_restyle.marked >= 5, "flipped to false")
	dom.remove_child(f.doc, r, k5)
	dom.release(f.doc, k5)
	expect_partial(t, f, "that member removed: it was under no matching head", 3)
}

// The same for a chain of compounds (YouTube: `:has([role]:not([aria-hidden]) .host) ...`): members are the elements that match its last
// compound and satisfy the chain; a change of an attribute the chain reads on an ancestor of a member may flip the answer.
@(test)
restyle_dom_has_chain :: proc(t: ^testing.T) {
	f := rx_load(`<style>:has([role]:not([aria-hidden]) .k) .y { margin: 1px }</style>
		<div id=a><p class=y>u</p><div id=r role=x><span class=k id=k1></span></div><div id=other><i id=i></i></div></div>`)
	defer rx_unload(f)
	r, other := by_id(f, "r"), by_id(f, "other")
	dom.set_attribute(f.doc, other, "title", "x")
	expect_partial(t, f, "a first change")
	k2 := dom.create_element(f.doc, "span")
	dom.set_attribute(f.doc, k2, "class", "k")
	dom.append_child(f.doc, r, k2)
	expect_partial(t, f, "a second member under the same ancestor with the attribute", 2)
	k3 := dom.create_element(f.doc, "span")
	dom.set_attribute(f.doc, k3, "class", "k")
	dom.append_child(f.doc, other, k3)
	expect_partial(t, f, "a member where the chain does not hold", 2)
	dom.set_attribute(f.doc, other, "role", "y")
	expect_partial(t, f, "the chain holds for it now: the answer flips for `other`'s side")
	dom.set_attribute(f.doc, other, "aria-hidden", "true")
	expect_partial(t, f, "and not any more")
	dom.remove_attribute(f.doc, r, "role")
	expect_partial(t, f, "the attribute of the ancestor of two members removed")
	dom.set_attribute(f.doc, r, "role", "x")
	expect_partial(t, f, "and back")
	dom.remove_child(f.doc, r, k2)
	dom.release(f.doc, k2)
	expect_partial(t, f, "a member removed and destroyed, another left")
	k1 := by_id(f, "k1")
	dom.remove_child(f.doc, r, k1)
	dom.release(f.doc, k1)
	expect_partial(t, f, "the last one of that ancestor")
}
// A style attribute of another text that computes to the same style: the restyle gives back what it allocated, not what the
// inline cache keeps (the cache's key and rule were read from memory a later allocation had taken: npr.org, freed memory poisoned).
@(test)
a_restyle_that_changes_nothing_leaves_the_inline_cache_whole :: proc(t: ^testing.T) {
	f := rx_load(`<!doctype html><body><p id=a style="color: red">a</p></body>`)
	defer rx_unload(f)
	a := by_id(f, "a")
	texts := []string{"color:red", "color: red;", "color : red"}
	for text in texts {
		dom.set_attribute(f.doc, a, "style", text)
		expect_partial(t, f, text, 1)
	}
	for text in texts { testing.expectf(t, text in f.st.inline_rules, "%q is still found", text) }
	for k, r in f.st.inline_rules { testing.expectf(t, r != nil && len(r.decls) == 1, "%q keeps its rule", k) }
}
