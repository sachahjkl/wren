package style

import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:host"
import "wb:html"

// restyle_dom against a full pass: after each mutation the partial restyle must give every element the computed style
// a full pass gives it (verify_styles), and stay partial.

@(private = "file")
Rx :: struct {
	doc: ^dom.Document,
	eng: ^Engine,
	st:  ^Styled,
	partial, full: int,
}

@(private = "file")
rx_load :: proc(src: string) -> ^Rx {
	f := new(Rx)
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	ss := settings_default()
	f.eng = engine_make(ss)
	settings_destroy(&ss)
	engine_set_journal(f.eng, 1 << 16)
	f.eng.settings.inc_max_ratio = 1   // documents of a few elements: any change is a large part of them
	sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = compute_styles(f.eng, f.doc, {})
	dom.journal_enable(f.doc, 1 << 16)
	return f
}

@(private = "file")
rx_unload :: proc(f: ^Rx) {
	styled_destroy(f.st)
	engine_destroy(f.eng)
	dom.document_destroy(f.doc)
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
@(test)
restyle_dom_forms :: proc(t: ^testing.T) {
	provider := Control_Provider{query = proc(user: rawptr, el: base.Handle, q: Control_Query) -> (bool, bool) { return false, false }}
	f := rx_load(`<form><input id=i name=a><input name=a></form><div id=d><p id=p>x</p></div>`)
	defer rx_unload(f)
	f.st.state.controls = provider
	p := by_id(f, "p")
	dom.remove_child(f.doc, by_id(f, "d"), p)
	dom.release(f.doc, p)
	_, ok := restyle_dom(f.eng, f.doc, f.st)
	testing.expect(t, !ok, "an element gone from a document with forms")
	g := rx_load(`<div id=d><p id=p>x</p><p>y</p></div>`)
	defer rx_unload(g)
	g.st.state.controls = provider
	q := by_id(g, "p")
	dom.remove_child(g.doc, by_id(g, "d"), q)
	dom.release(g.doc, q)
	expect_partial(t, g, "an element gone from a document without forms")
	in_ := dom.create_element(g.doc, "input")
	dom.append_child(g.doc, by_id(g, "d"), in_)
	_, ok2 := restyle_dom(g.eng, g.doc, g.st)
	testing.expect(t, !ok2 && g.eng.last_restyle.fallback == "form controls inserted")
	old := g.st
	g.st = compute_styles(g.eng, g.doc, {controls = provider})
	styled_destroy(old)
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

// A class on <body> that every section's descendants depend on: the forced subtree is shared out between threads, with
// the result of a full pass.
@(test)
restyle_dom_parallel :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `<style>.wide section p { margin-left: 3px } .wide b::before { content: "x" counter(sec) } section { counter-increment: sec } .wide { font-size: 18px } p + p { color: red }</style><body>`)
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

////////////////////////////////
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
`

@(private = "file")
RESTYLE_SEED :: #config(RESTYLE_SEED, 20261019)

@(private = "file")
TAGS := [?]string{"div", "p", "span", "section", "li", "ul", "ol", "h3", "b"}
@(private = "file")
CLASSES := [?]string{"a", "b", "c", "d", "e", "f", "g", "h", "x"}

@(test)
restyle_dom_random :: proc(t: ^testing.T) {
	rng := rand.create(RESTYLE_SEED)
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
