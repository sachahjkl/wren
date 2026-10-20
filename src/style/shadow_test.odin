package style

import "core:testing"
import "wb:base"
import "wb:css"
import "wb:dom"
import "wb:html"

// Shadow trees: scoped rules, :host, ::slotted(), ::part(), the cascade's encapsulation contexts, inheritance through
// the flat tree, and partial restyles (each compared with a full pass).

@(private = "file")
Sx :: struct {
	doc: ^dom.Document,
	eng: ^Engine,
	st:  ^Styled,
}

@(private = "file")
sx_load :: proc(src: string) -> ^Sx {
	f := new(Sx)
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	ss := settings_default()
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
sx_unload :: proc(f: ^Sx) {
	styled_destroy(f.st)
	engine_destroy(f.eng)
	dom.document_destroy(f.doc)
	free(f)
}

// An element by id, in the document or in any shadow tree.
@(private = "file")
sid :: proc(f: ^Sx, id: string) -> base.Handle {
	for h := f.doc.root; h != base.NIL_HANDLE; h = dom.next_shadow_including(f.doc, h, f.doc.root) {
		n := dom.get(f.doc, h)
		if n.kind != .Element { continue }
		if v, ok := attr(n, "id"); ok && v == id { return h }
	}
	return base.NIL_HANDLE
}

@(private = "file")
color_of :: proc(f: ^Sx, id: string) -> css.Color {
	c := style_of(f.st, sid(f, id))
	if c == nil { return {} }
	return c.color
}

@(private = "file")
BLACK :: css.Color{0, 0, 0, 1}
@(private = "file")
SGREEN :: css.Color{0, 128.0 / 255, 0, 1}

// Restyles after mutations (sheets synced first, as the page does) and compares with a full pass.
@(private = "file")
sx_step :: proc(t: ^testing.T, f: ^Sx, what: string, want_partial := true, loc := #caller_location) {
	sync_document_sheets(f.eng, f.doc, "about:test")
	_, ok := restyle_dom(f.eng, f.doc, f.st)
	if !ok {
		old := f.st
		f.st = compute_styles(f.eng, f.doc, {})
		journal_diff(old, f.st)
		styled_destroy(old)
	}
	if want_partial { testing.expectf(t, ok, "%s: not partial (%s)", what, f.eng.last_restyle.fallback, loc = loc) }
	diff := verify_styles(f.eng, f.doc, f.st, context.temp_allocator)
	testing.expectf(t, diff == "", "%s: %s", what, diff, loc = loc)
}

@(test)
shadow_encapsulation_and_inheritance :: proc(t: ^testing.T) {
	f := sx_load(`<!doctype html><style>p { color: red } x-card { color: blue } .doc-only { color: red }</style>
		<x-card id=host><template shadowrootmode=open><style>p { color: green } span { color: green }</style>
		<p id=inner>in</p><div id=wrap><slot id=s></slot></div><i id=plain class=doc-only>i</i></template>
		<span id=light>slotted</span><p id=lightp>lp</p></x-card><span id=out>out</span>`)
	defer sx_unload(f)
	testing.expect_value(t, color_of(f, "inner"), SGREEN)   // the document's p rule does not enter
	testing.expect_value(t, color_of(f, "light"), BLUE)    // the shadow's span rule does not leave; inherits via the slot
	testing.expect_value(t, color_of(f, "lightp"), RED)
	testing.expect_value(t, color_of(f, "plain"), BLUE)    // .doc-only is a document rule: inherited from the host
	testing.expect_value(t, color_of(f, "out"), BLACK)
	// the slot is display: contents and in the flat tree
	testing.expect_value(t, style_of(f.st, sid(f, "s")).display, Display.Contents)
}

@(test)
shadow_host_slotted_part_and_contexts :: proc(t: ^testing.T) {
	f := sx_load(`<!doctype html><style>
		x-a { color: blue; padding-left: 1px }
		x-a::part(label) { color: blue }
		x-a::part(out) { margin-left: 9px }
		.theme x-a::part(label) { text-decoration-line: underline }
		</style>
		<div class=theme id=theme><x-a id=h1 class=on><template shadowrootmode=open><style>
			:host { color: red; padding-left: 5px !important; display: block }
			:host(.on) { margin-top: 7px }
			:host-context(.theme) b { color: green }
			::slotted(em) { color: green }
			::slotted(*) { margin-left: 3px }
			[part~=label] { color: red; padding-left: 2px }
			x-b::part(deep) { padding-top: 4px }
			</style>
			<b id=b1>b</b><span id=lab part=label>l</span>
			<x-b id=h2 exportparts="deep: out"><template shadowrootmode=open><i id=deep part=deep>d</i></template></x-b>
			<slot></slot></template><em id=e1>e</em><strong id=st1>s</strong></x-a></div>`)
	defer sx_unload(f)
	h1 := style_of(f.st, sid(f, "h1"))
	testing.expect_value(t, h1.color, BLUE)               // outer normal beats :host
	testing.expect_value(t, h1.padding[.Left].v, 5)          // inner !important beats outer normal
	testing.expect_value(t, h1.margin[.Top].v, 7)           // :host(.on)
	testing.expect_value(t, color_of(f, "b1"), SGREEN)     // :host-context(.theme)
	testing.expect_value(t, color_of(f, "e1"), SGREEN)     // ::slotted(em)
	testing.expect_value(t, style_of(f.st, sid(f, "st1")).margin[.Left].v, 3)
	lab := style_of(f.st, sid(f, "lab"))
	testing.expect_value(t, lab.color, BLUE)              // ::part from outside beats the tree's own rule (normal)
	testing.expect_value(t, lab.padding[.Left].v, 2)
	testing.expect(t, .Underline in lab.text_decoration)
	deep := style_of(f.st, sid(f, "deep"))
	testing.expect_value(t, deep.padding[.Top].v, 4)        // ::part of a host in the same tree
	testing.expect_value(t, deep.margin[.Left].v, 9)         // forwarded by exportparts: ::part(out) from the document

	// partial restyles
	dom.remove_attribute(f.doc, sid(f, "h1"), "class")
	sx_step(t, f, ":host(.on) off")
	testing.expect_value(t, style_of(f.st, sid(f, "h1")).margin[.Top].v, 0)
	dom.remove_attribute(f.doc, sid(f, "theme"), "class")
	sx_step(t, f, ":host-context and ancestors' ::part off")
	testing.expect_value(t, color_of(f, "b1"), BLUE)
	dom.set_attribute(f.doc, sid(f, "lab"), "part", "other")
	sx_step(t, f, "part renamed")
	testing.expect_value(t, color_of(f, "lab"), BLUE)    // inherits from the host now
	dom.set_attribute(f.doc, sid(f, "h2"), "exportparts", "")
	sx_step(t, f, "exportparts emptied")
	testing.expect_value(t, style_of(f.st, sid(f, "deep")).margin[.Left].v, 0)
}

@(test)
shadow_restyle_partial :: proc(t: ^testing.T) {
	f := sx_load(`<!doctype html><style>.x { color: blue }</style>
		<div id=host><template shadowrootmode=open><style>.k { color: green } .k + i { color: red } slot[name=a] { color: red }</style>
		<p id=p class=k>p</p><i id=after>i</i><slot name=a id=sa></slot><section id=sec><slot id=sd></slot></section></template>
		<b id=b1 slot=a>b</b><b id=b2>c</b></div>`)
	defer sx_unload(f)
	testing.expect_value(t, color_of(f, "after"), RED)
	testing.expect_value(t, color_of(f, "b1"), RED)
	p := sid(f, "p")
	dom.remove_attribute(f.doc, p, "class")
	sx_step(t, f, "class in a shadow tree")
	testing.expect_value(t, color_of(f, "after"), BLACK)
	dom.set_attribute(f.doc, p, "class", "k")
	sx_step(t, f, "class back")
	// reassignment: b1 to the default slot, b2 away
	dom.remove_attribute(f.doc, sid(f, "b1"), "slot")
	sx_step(t, f, "slot attribute removed")
	testing.expect_value(t, color_of(f, "b1"), BLACK)
	dom.set_attribute(f.doc, sid(f, "b2"), "slot", "nowhere")
	sx_step(t, f, "slotted node unassigned")
	testing.expect(t, style_of(f.st, sid(f, "b2")) == nil)
	// a new light child, assigned at once
	nb := dom.create_element(f.doc, "b")
	dom.set_attribute(f.doc, nb, "id", "b3")
	dom.set_attribute(f.doc, nb, "slot", "a")
	dom.append_child(f.doc, sid(f, "host"), nb)
	sx_step(t, f, "light child inserted")
	testing.expect_value(t, color_of(f, "b3"), RED)
	// a slot removed: its nodes leave the flat tree
	sa := sid(f, "sa")
	dom.detach(f.doc, sa)
	sx_step(t, f, "slot removed")
	testing.expect(t, style_of(f.st, sid(f, "b3")) == nil)
	// a style element in the shadow tree: only that tree is restyled, no full pass
	root := dom.shadow_root_of(f.doc, sid(f, "host"))
	st := dom.create_element(f.doc, "style")
	dom.append_child(f.doc, st, dom.create_text(f.doc, "#sec { color: blue }"))
	dom.append_child(f.doc, root, st)
	sx_step(t, f, "style element added to a shadow tree")
	testing.expect_value(t, color_of(f, "sec"), BLUE)
	testing.expect_value(t, color_of(f, "b1"), BLUE)   // inherits through the default slot
	// attachShadow on an element with children
	div := dom.create_element(f.doc, "div")
	kid := dom.create_element(f.doc, "span")
	dom.set_attribute(f.doc, kid, "id", "kid")
	dom.append_child(f.doc, div, kid)
	body := dom.find_first_by_tag(f.doc, "body")
	dom.append_child(f.doc, body, div)
	sx_step(t, f, "host-to-be inserted")
	testing.expect(t, style_of(f.st, kid) != nil)
	r2, _ := dom.attach_shadow(f.doc, div, {mode = .Open})
	sx_step(t, f, "attachShadow")
	testing.expect(t, style_of(f.st, kid) == nil)
	sl := dom.create_element(f.doc, "slot")
	dom.append_child(f.doc, r2, sl)
	sx_step(t, f, "slot added to a new shadow root")
	testing.expect(t, style_of(f.st, kid) != nil)
}

@(test)
shadow_adopted_and_constructed :: proc(t: ^testing.T) {
	f := sx_load(`<!doctype html><div id=host><template shadowrootmode=open><p id=p>p</p></template></div><p id=dp>d</p>`)
	defer sx_unload(f)
	root := dom.shadow_root_of(f.doc, sid(f, "host"))
	id := engine_constructed_create(f.eng, "p { color: green }")
	engine_set_adopted(f.eng, root, {id}, false)
	sx_step(t, f, "sheet adopted by a shadow root")
	testing.expect_value(t, color_of(f, "p"), SGREEN)
	testing.expect_value(t, color_of(f, "dp"), BLACK)
	engine_constructed_replace(f.eng, id, "p { color: blue }")
	sx_step(t, f, "adopted sheet replaced")
	testing.expect_value(t, color_of(f, "p"), BLUE)
	engine_set_adopted(f.eng, f.doc.root, {id}, true)
	sx_step(t, f, "adopted by the document", want_partial = false)
	testing.expect_value(t, color_of(f, "dp"), BLUE)
	engine_constructed_destroy(f.eng, id)
	sx_step(t, f, "sheet gone", want_partial = false)
	testing.expect_value(t, color_of(f, "p"), BLACK)
}

@(test)
shadow_state_restyle :: proc(t: ^testing.T) {
	f := sx_load(`<!doctype html><div id=host><template shadowrootmode=open><style>:host(:hover) b { color: red } :host(:focus) i { color: green }</style>
		<b id=b>b</b><i id=i>i</i><input id=in></template></div>`)
	defer sx_unload(f)
	inp := sid(f, "in")
	_, ok := restyle_state(f.eng, f.doc, f.st, State{hover = inp})
	testing.expect(t, ok)
	testing.expect_value(t, color_of(f, "b"), RED)
	_, ok = restyle_state(f.eng, f.doc, f.st, State{focus = inp})
	testing.expect(t, ok)
	testing.expect_value(t, color_of(f, "b"), BLACK)
	testing.expect_value(t, color_of(f, "i"), SGREEN)   // the host matches :focus while its tree holds the focus
	diff := verify_styles(f.eng, f.doc, f.st, context.temp_allocator)
	testing.expectf(t, diff == "", "state: %s", diff)
}
