package style

import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:html"

// Matching shared between siblings and cousins (sibling_match.odin): the lists an element gets are those a full match
// gives it, with selectors of every kind that tell alike elements apart; and alike elements do take their matching from
// the one before.

@(private = "file")
SIB_PAGE_MAX_NODES :: 1 << 16

@(private = "file")
SIB_CSS :: `
li { margin-top: 1px }
li:first-child span { color: rgb(0, 0, 255) }
li:nth-child(2) > span { color: rgb(255, 0, 0) }
li:nth-child(odd of .k) b { font-weight: 700 }
li + li { padding-left: 3px }
li:first-child + li span { padding-top: 2px }
li ~ li > b { padding-right: 4px }
span:hover { color: rgb(0, 255, 0) }
li:hover b { margin-left: 6px }
p:empty { margin-left: 5px }
p:not(:last-child) { margin-right: 1px }
div:has(> p:empty) p { margin-bottom: 7px }
:is(li:nth-last-child(1), section) span { padding-bottom: 8px }
[data-x="1"] span, .k span { text-indent: 9px }
`

@(private = "file")
SIB_HTML :: `<ul><li><span>a</span><b>1</b></li><li><span>b</span><b>2</b></li><li class=k><span>c</span><b>3</b></li>
<li class=k><span>d</span><b>4</b></li><li><span>e</span><b>5</b></li><li data-x=1><span>f</span><b>6</b></li></ul>
<div><p></p><p>x</p><p></p></div><div><p>y</p><p>z</p></div><section><p><span>s</span></p><p><span>t</span></p></section>`

// Walks the document as a full pass does (depths, ancestor filters), matching each element through match_element and
// again in full; returns the elements and how many differ.
@(private = "file")
sib_walk :: proc(e: ^Engine, doc: ^dom.Document, state: State) -> (elements, differ: int, classes: u32) {
	s := styled_make(e, doc, state)
	defer styled_destroy(s)
	p := pass_make(e, s, doc, state)
	defer pass_destroy(p)
	Frame :: struct { h: base.Handle, bloom: Bloom, depth: int }
	stack := make([dynamic]Frame, context.temp_allocator)
	root := dom.get(doc, doc.root)
	for c := root.last_child; c != base.NIL_HANDLE; c = dom.get(doc, c).prev { append(&stack, Frame{h = c}) }
	for len(stack) > 0 {
		f := pop(&stack)
		n := dom.get(doc, f.h)
		if n == nil || n.kind != .Element { continue }
		elements += 1
		match_element(p, f.h, n, &f.bloom, {}, f.depth)
		shared: [4][dynamic]Entry
		for i in 0 ..< 4 { shared[i] = make([dynamic]Entry, context.temp_allocator); append(&shared[i], ..p.lists[i][:]) }
		collect_entries(p, f.h, n, &f.bloom, {}, nil)
		same := true
		for i in 0 ..< 4 {
			if len(shared[i]) != len(p.lists[i]) { same = false; break }
			for x, k in shared[i] { if x.rule != p.lists[i][k].rule || x.complex != p.lists[i][k].complex { same = false } }
		}
		if !same { differ += 1 }
		child_bloom := f.bloom
		bloom_add_element(&child_bloom, n)
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).prev { append(&stack, Frame{h = ch, bloom = child_bloom, depth = f.depth + 1}) }
	}
	return elements, differ, p.sib.classes
}

@(test)
sibling_match_gives_the_full_match :: proc(t: ^testing.T) {
	doc := dom.document_create(nil)
	defer dom.document_destroy(doc)
	html.parse_into(doc, doc.root, transmute([]byte)string(`<style>` + SIB_CSS + `</style>` + SIB_HTML), SIB_PAGE_MAX_NODES)
	s := settings_default()
	e := engine_make(s)
	settings_destroy(&s)
	defer engine_destroy(e)
	sync_document_sheets(e, doc, "about:test")
	engine_rebuild(e, doc)
	elements, differ, classes := sib_walk(e, doc, {})
	testing.expectf(t, differ == 0, "%d of %d elements matched otherwise than in full", differ, elements)
	// taken from an element of their family: the second, fourth and fifth list items (like the first, the third, the
	// first), the span and b of the second and fourth (cousins of those of the first and third; the fifth's family is the
	// third's: its parent's class is another), the first div's second and third p, the second div and its two p (cousins),
	// the section's second p and its span
	testing.expectf(t, int(classes) == elements - 14, "%d of %d elements matched in full", classes, elements)

	// a state on one element: it is told apart from those it is alike to
	spans := make([dynamic]base.Handle, context.temp_allocator)
	it: u32
	for h, n in base.pool_next(&doc.nodes, &it) { if n.kind == .Element && n.name == "span" { append(&spans, h) } }
	for target in spans {
		lis := dom.get(doc, target).parent
		_, d1, _ := sib_walk(e, doc, State{hover = target})
		_, d2, _ := sib_walk(e, doc, State{hover = lis})
		testing.expect(t, d1 == 0 && d2 == 0, "a hovered element or parent: matched as in full")
	}

	// and the styles made of it: what each rule gives
	st := compute_styles(e, doc, {})
	defer styled_destroy(st)
	color_of := make([dynamic]u8, context.temp_allocator)
	for h in spans[:6] {
		c := style_of(st, h)
		append(&color_of, c.color.b == 1 ? 'b' : c.color.r == 1 ? 'r' : '-')
	}
	testing.expect_value(t, string(color_of[:]), "br----")
}
