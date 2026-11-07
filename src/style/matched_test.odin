package style

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:css"
import "wb:dom"

// What an element matched, kept (matched.odin). verify_styles compares every list with a full pass's: every test of a restyle checks them.

@(private = "file")
PAGE :: `<!doctype html><html id=r><head><style>
	.card { color: var(--c, rgb(0, 0, 0)) }
	.on .card { padding-top: 1px }
	.card:hover { margin-top: 1px }
	.side ~ .card { margin-left: 1px }
	.w:has(.on) .card { padding-left: 2px }
	@media (min-width: 900px) { .card { padding-right: 3px } }
	.box { container-type: inline-size }
	@container (min-width: 300px) { .card { margin-right: 4px } }
</style><style id=gone>.card { border-left-width: 3px; border-left-style: solid }</style><link id=l0 rel=stylesheet href=x.css></head><body>
<div class=w id=w><div class=box id=box><p class=card id=a>a</p><p class=card id=b>b</p><p class=card id=c>c</p></div></div></body></html>`

@(private = "file")
load :: proc(src: string) -> ^Fixture {
	f := fixture_load(src, {journal = FIXTURE_JOURNAL, partial = true})
	f.eng.restyle_needed = false   // (the page clears it after its full pass)
	return f
}

// A custom property written on <html>, of another value each time: every element restyled, for what it inherits alone.
@(private = "file")
VALUES :: 250
@(private = "file")
inherited_moved :: proc(t: ^testing.T, f: ^Fixture, what: string, loc := #caller_location) {
	dom.set_attribute(f.doc, dom.find_by_id(f.doc, "r"), "style", fmt.tprintf("--c: rgb(%d, 0, 0)", f.st.serial % VALUES + 1))   // (the serial moves with each pass that changes something)
	_, ok := restyle_dom(f.eng, f.doc, f.st)
	testing.expectf(t, ok, "%s: not partial (%s)", what, f.eng.last_restyle.fallback, loc = loc)
	testing.expectf(t, f.eng.last_restyle.marked > 1, "%s: restyled %d", what, f.eng.last_restyle.marked, loc = loc)
	testing.expect_value(t, f.eng.last_restyle.taken, f.eng.last_restyle.marked - 1, loc = loc)   // (<html>, which the attribute marks, matches)
	testing.expect_value(t, verify_styles(f.eng, f.doc, f.st, context.temp_allocator), "", loc = loc)
}

@(test)
matched_an_inherited_change_matches_nothing :: proc(t: ^testing.T) {
	f := load(PAGE)
	defer fixture_unload(f)
	inherited_moved(t, f, "first")
	testing.expect_value(t, style_of(f.st, dom.find_by_id(f.doc, "a")).color.a, 1)
	testing.expect(t, style_of(f.st, dom.find_by_id(f.doc, "a")).color.r > 0, "the cascade ran on the rules: the new value is in")
	// beside a mark, the marked element matches and only it
	dom.set_attribute(f.doc, dom.find_by_id(f.doc, "r"), "style", "--c: rgb(0, 9, 0)")
	dom.set_attribute(f.doc, dom.find_by_id(f.doc, "b"), "class", "card side")
	_, ok := restyle_dom(f.eng, f.doc, f.st)
	testing.expect(t, ok, "partial")
	testing.expect_value(t, f.eng.last_restyle.taken, f.eng.last_restyle.marked - 2)   // (<html>, and #c that `.side ~ .card` reaches)
	testing.expect_value(t, verify_styles(f.eng, f.doc, f.st, context.temp_allocator), "")
	testing.expect(t, style_of(f.st, dom.find_by_id(f.doc, "c")).margin[.Left].v == 1, "what the mark reached has its new rule")
}

// Each kind of pass that may change what an element matches, then an inherited change that reads what it left.
@(test)
matched_every_kind_of_pass_keeps_the_list :: proc(t: ^testing.T) {
	f := load(PAGE)
	defer fixture_unload(f)
	doc, e := f.doc, f.eng
	card, w := dom.find_by_id(doc, "a"), dom.find_by_id(doc, "w")
	padding_of :: proc(f: ^Fixture, s: Side) -> f32 { return style_of(f.st, dom.find_by_id(f.doc, "a")).padding[s].v }

	dom.set_attribute(doc, dom.find_by_id(doc, "box"), "class", "box on")
	_, ok := restyle_dom(e, doc, f.st)
	testing.expect(t, ok, "attribute")
	inherited_moved(t, f, "attribute")
	testing.expect(t, padding_of(f, .Top) == 1, ".on .card stands")

	hovered := State{hover = card}
	_, ok = restyle_state(e, doc, f.st, hovered)
	testing.expect(t, ok, "state")
	inherited_moved(t, f, "state")
	testing.expect(t, style_of(f.st, card).margin[.Top].v == 1, ":hover stands")
	_, ok = restyle_state(e, doc, f.st, {})
	testing.expect(t, ok, "state left")
	inherited_moved(t, f, "state left")
	testing.expect(t, style_of(f.st, card).margin[.Top].v != 1, ":hover is gone")

	on := dom.create_element(doc, "i")
	dom.set_attribute(doc, on, "class", "on")
	dom.append_child(doc, w, on)
	_, ok = restyle_dom(e, doc, f.st)
	testing.expect(t, ok, "has")
	inherited_moved(t, f, ":has() flips")
	testing.expect(t, padding_of(f, .Left) == 2, ":has(.on) stands")

	env := e.env
	env.width = env.width >= 900 ? 600 : 1000
	engine_set_environment(e, env)
	testing.expect(t, e.gates_pending && !e.dirty, "the gate flipped")
	_, ok = restyle_media(e, doc, f.st)
	testing.expect(t, ok, "media")
	inherited_moved(t, f, "media")
	testing.expect(t, (padding_of(f, .Right) == 3) == (env.width >= 900), "the @media block as the width says")

	box := dom.find_by_id(doc, "box")
	sizes := make(map[base.Handle][2]f32, context.temp_allocator)
	sizes[box] = {400, 40}
	testing.expect(t, engine_set_container_sizes(e, sizes), "a size")
	_, ok = restyle_containers(e, doc, f.st)
	testing.expect(t, ok, "container")
	testing.expect_value(t, e.last_restyle.taken, 4)   // (the container and what it holds: only conditions moved)
	testing.expect(t, style_of(f.st, card).margin[.Right].v == 4, "the condition is read in the cascade")
	testing.expect_value(t, verify_styles(e, doc, f.st, context.temp_allocator), "")
	inherited_moved(t, f, "container")

	engine_add_sheet(e, `.card { word-spacing: 2px }`, dom.find_by_id(doc, "l0"), from_link = true)
	testing.expect(t, engine_extend(e, doc, f.st), "the sheet joined the rules")
	_, ok = restyle_arrivals(e, doc, f.st)
	testing.expect(t, ok, "arrival")
	inherited_moved(t, f, "a sheet came")
	testing.expect(t, style_of(f.st, card).word_spacing == 2, "the rule that came stands")

	gone := dom.find_by_id(doc, "gone")
	dom.remove_child(doc, dom.get(doc, gone).parent, gone)
	sync_document_sheets(e, doc, "about:test")
	_, ok = restyle_dom(e, doc, f.st)
	testing.expect(t, ok, "the mutation of the sheet that goes")
	_, ok = restyle_departures(e, doc, f.st)
	testing.expect(t, ok, "departure")
	inherited_moved(t, f, "a sheet went")
	testing.expect(t, style_of(f.st, card).border_width[.Left] == 0, "the rule that went is out")
}

// Rules gone, lists gone: they point at them. What the engine rebuilt under a Styled is not read, and the next full pass starts again.
@(test)
matched_go_with_the_rules :: proc(t: ^testing.T) {
	f := load(PAGE)
	defer fixture_unload(f)
	gen := f.eng.matched.gen
	engine_rebuild(f.eng, f.doc)
	testing.expect(t, f.eng.matched.gen != gen, "another generation")
	testing.expect_value(t, f.eng.matched.count, 0)
	dom.set_attribute(f.doc, dom.find_by_id(f.doc, "r"), "style", "--c: rgb(5, 0, 0)")
	_, ok := restyle_dom(f.eng, f.doc, f.st)
	testing.expect(t, ok, "partial")
	testing.expect_value(t, f.eng.last_restyle.taken, 0)
	testing.expect_value(t, f.eng.matched.count, 0)   // (a Styled of another generation writes none either)
	testing.expect_value(t, verify_styles(f.eng, f.doc, f.st, context.temp_allocator), "")
	old := f.st
	f.st = compute_styles(f.eng, f.doc, {})
	styled_destroy(old)
	inherited_moved(t, f, "after a full pass")
}

// A list is kept once, whatever the number of elements that have it.
@(test)
matched_lists_are_shared :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, `<!doctype html><html id=r><style>li { color: var(--c) } .x { margin: 1px } ul li { padding: 1px } li::before { content: "a" }</style><ul>`)
	ITEMS :: 1000
	for i in 0 ..< ITEMS { strings.write_string(&sb, i % 2 == 0 ? "<li>a</li>" : `<li class=x>b</li>`) }
	strings.write_string(&sb, "</ul></html>")
	f := load(strings.to_string(sb))
	defer fixture_unload(f)
	ul := dom.find_first_by_tag(f.doc, "ul")
	first := dom.find_first_by_tag(f.doc, "li")
	distinct_lists := make(map[^Matched_List]bool, context.temp_allocator)
	for ch := dom.get(f.doc, ul).first_child; ch != base.NIL_HANDLE; ch = dom.get(f.doc, ch).next { distinct_lists[matched_of(f.st, ch)] = true }
	testing.expect_value(t, len(distinct_lists), 2)
	l := matched_of(f.st, first)
	testing.expect_value(t, int(l.counts[.Element]), 3)   // (and the browser's li)
	testing.expect_value(t, int(l.counts[.Before]), 1)
	testing.expect(t, f.eng.matched.count < 10, "a few lists for a thousand elements")
	testing.expect(t, matched_bytes(f.eng) < MATCHED_BLOCK, "in the first block")
	dom.set_attribute(f.doc, dom.find_by_id(f.doc, "r"), "style", "--c: red")
	_, ok := restyle_dom(f.eng, f.doc, f.st)
	testing.expect(t, ok, "partial")
	testing.expect(t, f.eng.last_restyle.taken >= ITEMS, "taken from the lists")
	testing.expect_value(t, style_of(f.st, first).color, css.Color{1, 0, 0, 1})
}

// Past what the store may hold no list is kept: the element matches, and the store starts over with the next full pass.
@(test)
matched_past_the_limit_matching_runs :: proc(t: ^testing.T) {
	f := load(PAGE)
	defer fixture_unload(f)
	f.eng.matched.limit = 0
	old := f.st
	f.st = compute_styles(f.eng, f.doc, {})
	styled_destroy(old)
	dom.set_attribute(f.doc, dom.find_by_id(f.doc, "r"), "style", "--c: rgb(7, 0, 0)")
	_, ok := restyle_dom(f.eng, f.doc, f.st)
	testing.expect(t, ok, "partial")
	testing.expect_value(t, f.eng.last_restyle.taken, 0)
	testing.expect_value(t, verify_styles(f.eng, f.doc, f.st, context.temp_allocator), "")
}

// Which rules of another tree an element sees is not in a list: a document with a shadow tree matches, and has no list left when the tree goes.
@(test)
matched_shadow_trees_match :: proc(t: ^testing.T) {
	f := load(PAGE)
	defer fixture_unload(f)
	inherited_moved(t, f, "before the tree")
	host := dom.find_by_id(f.doc, "w")
	root, _ := dom.attach_shadow(f.doc, host, {mode = .Open})
	dom.append_child(f.doc, root, dom.create_element(f.doc, "slot"))
	dom.set_attribute(f.doc, dom.find_by_id(f.doc, "r"), "style", "--c: rgb(8, 0, 0)")
	_, ok := restyle_dom(f.eng, f.doc, f.st)
	testing.expect(t, ok, "partial")
	testing.expect_value(t, f.eng.last_restyle.taken, 0)
	testing.expect_value(t, f.st.matched_gen, 0)
	testing.expect_value(t, verify_styles(f.eng, f.doc, f.st, context.temp_allocator), "")
}

// `:nth-child(2)`, `:nth-last-child(-n + 2)` are read at their end of the list: a change past that place reaches nothing there.
@(test)
restyle_dom_nth_near_the_edge :: proc(t: ^testing.T) {
	f := load(`<!doctype html><style>:nth-child(2) { color: red } :nth-last-child(-n + 2) { margin-left: 1px } .z { padding: 1px }</style>
		<ul id=l><li id=a>a</li><li id=b>b</li><li id=c>c</li><li id=d>d</li><li id=e>e</li><li id=f>f</li><li id=g>g</li></ul>`)
	defer fixture_unload(f)
	l := dom.find_by_id(f.doc, "l")
	step :: proc(t: ^testing.T, f: ^Fixture, marked: int, what: string, loc := #caller_location) {
		_, ok := restyle_dom(f.eng, f.doc, f.st)
		testing.expectf(t, ok, "%s: not partial (%s)", what, f.eng.last_restyle.fallback, loc = loc)
		testing.expectf(t, f.eng.last_restyle.marked == marked, "%s: %d restyled, %d expected", what, f.eng.last_restyle.marked, marked, loc = loc)
		testing.expect_value(t, verify_styles(f.eng, f.doc, f.st, context.temp_allocator), "", loc = loc)
	}
	mid := dom.create_element(f.doc, "li")
	dom.insert_before(f.doc, l, mid, dom.find_by_id(f.doc, "d"))
	step(t, f, 1, "in the middle: itself")
	x := dom.create_element(f.doc, "li")
	dom.append_child(f.doc, l, x)
	step(t, f, 3, "at the end: itself and the two before it")
	y := dom.create_element(f.doc, "li")
	dom.insert_before(f.doc, l, y, dom.find_by_id(f.doc, "a"))
	step(t, f, 3, "first: itself and the two after it")
	dom.remove_child(f.doc, l, y)
	step(t, f, 2, "gone from the front: the two that stand there now")
	dom.remove_child(f.doc, l, mid)
	step(t, f, 0, "gone from the middle: nothing")
	dom.remove_child(f.doc, l, x)
	step(t, f, 2, "gone from the end: the two that stand there now")
	dom.append_child(f.doc, l, x)
	z, u := dom.create_element(f.doc, "li"), dom.create_element(f.doc, "li")
	dom.append_child(f.doc, l, z)
	dom.append_child(f.doc, l, u)
	step(t, f, 5, "three at the end (one of them back): they and the two before them")
}

// A class rewritten with the same tokens, an attribute that keeps its answer: the selectors are asked of the old value and the new, and nothing passes.
@(test)
restyle_dom_attribute_selectors_read_old_and_new :: proc(t: ^testing.T) {
	f := load(`<!doctype html><style>[class*="ab"] .k { color: red } [data-a^="x"] + p { margin: 1px } [data-a] { padding: 1px } a:any-link .k { margin: 2px }</style>
		<div id=d class="ab  c" data-a=x1><p class=k id=k>k</p></div><p id=n>n</p><a id=l><b class=k>l</b></a>`)
	defer fixture_unload(f)
	d := dom.find_by_id(f.doc, "d")
	step :: proc(t: ^testing.T, f: ^Fixture, marked: int, what: string, loc := #caller_location) {
		_, ok := restyle_dom(f.eng, f.doc, f.st)
		testing.expectf(t, ok, "%s: not partial (%s)", what, f.eng.last_restyle.fallback, loc = loc)
		testing.expectf(t, marked < 0 || f.eng.last_restyle.marked == marked, "%s: %d restyled", what, f.eng.last_restyle.marked, loc = loc)
		testing.expect_value(t, verify_styles(f.eng, f.doc, f.st, context.temp_allocator), "", loc = loc)
	}
	dom.set_attribute(f.doc, d, "class", "ab c")
	step(t, f, 0, "the same tokens")
	dom.set_attribute(f.doc, d, "class", "c abc")
	step(t, f, 0, "another value, the same answer")
	dom.set_attribute(f.doc, d, "class", "c")
	step(t, f, 1, "the answer flips: its reach")
	testing.expect(t, style_of(f.st, dom.find_by_id(f.doc, "k")).color.r == 0, "and what it reached is restyled")
	dom.set_attribute(f.doc, d, "data-a", "x2")
	step(t, f, 0, "the prefix holds, and [data-a] too")
	dom.set_attribute(f.doc, d, "data-a", "y")
	step(t, f, 1, "the prefix does not")
	dom.remove_attribute(f.doc, d, "data-a")
	step(t, f, -1, "gone: [data-a] flips")
	testing.expect(t, style_of(f.st, d).padding[.Top].v == 0, "and the rule is out")
	dom.set_attribute(f.doc, dom.find_by_id(f.doc, "l"), "href", "x")
	step(t, f, -1, "a pseudo-class reads no value: it reaches what it reaches")
	dom.set_attribute(f.doc, dom.find_by_id(f.doc, "l"), "href", "y")
	step(t, f, -1, "and again, at any value")
}
