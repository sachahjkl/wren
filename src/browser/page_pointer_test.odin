package browser

import "core:strings"
import "core:testing"
import "wb:dom"
import "wb:html"

@(test)
pointer_events_order :: proc(t: ^testing.T) {
	doc := dom.document_create(nil)
	defer dom.document_destroy(doc)
	html.parse_into(doc, doc.root, transmute([]byte)string(`<!doctype html><body><div id=p><span id=a>a</span><span id=b>b</span></div><div id=q>q</div></body>`), 100_000)
	a, b, p, q := dom.find_by_id(doc, "a"), dom.find_by_id(doc, "b"), dom.find_by_id(doc, "p"), dom.find_by_id(doc, "q")
	names :: proc(doc: ^dom.Document, plan: []Pointer_Event) -> string {
		sb := strings.builder_make(context.temp_allocator)
		for e in plan {
			id, _ := dom.get_attribute(doc, e.target, "id")
			if id == "" { id = dom.get(doc, e.target).name }
			strings.write_string(&sb, e.type); strings.write_byte(&sb, '@'); strings.write_string(&sb, id); strings.write_byte(&sb, ' ')
		}
		return strings.trim_space(strings.to_string(sb))
	}
	// still over the same element: a move
	testing.expect_value(t, names(doc, pointer_plan(doc, a, a)), "pointermove@a mousemove@a")
	// between two siblings: the parent is neither left nor entered
	testing.expect_value(t, names(doc, pointer_plan(doc, a, b)),
		"pointerout@a pointerleave@a mouseout@a mouseleave@a pointerover@b pointerenter@b mouseover@b mouseenter@b pointermove@b mousemove@b")
	// from one subtree to another: leave deepest first, enter outermost first, the shared body and html stay
	testing.expect_value(t, names(doc, pointer_plan(doc, a, q)),
		"pointerout@a pointerleave@a pointerleave@p mouseout@a mouseleave@a mouseleave@p pointerover@q pointerenter@q mouseover@q mouseenter@q pointermove@q mousemove@q")
	// into the page from outside: every element on the way is entered, outermost first
	into := names(doc, pointer_plan(doc, {}, a))
	testing.expect(t, strings.has_prefix(into, "pointerover@a pointerenter@html pointerenter@body pointerenter@p pointerenter@a mouseover@a mouseenter@html"), into)
	// out of the page: leaves only, no move
	out := names(doc, pointer_plan(doc, a, {}))
	testing.expect_value(t, out, "pointerout@a pointerleave@a pointerleave@p pointerleave@body pointerleave@html mouseout@a mouseleave@a mouseleave@p mouseleave@body mouseleave@html")
	// over and out bubble and may be cancelled; enter and leave do neither
	for e in pointer_plan(doc, a, b) {
		bubbling := strings.has_suffix(e.type, "over") || strings.has_suffix(e.type, "out") || strings.has_suffix(e.type, "move")
		testing.expectf(t, e.bubbles == bubbling && e.cancelable == bubbling, "%s: bubbles %v cancelable %v", e.type, e.bubbles, e.cancelable)
	}
	_ = p
}
