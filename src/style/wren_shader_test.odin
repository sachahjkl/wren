package style

import "core:math"
import "core:testing"
import "wb:dom"
import "wb:html"

@(private = "file")
Sx :: struct {
	doc: ^dom.Document,
	eng: ^Engine,
	st:  ^Styled,
	tl:  ^Timeline,
}

@(private = "file")
open :: proc(src: string, internal: bool) -> Sx {
	f: Sx
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 2_000_000)
	s := settings_default()
	s.internal_document = internal
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
close :: proc(f: ^Sx) {
	timeline_destroy(f.tl, f.st)
	styled_destroy(f.st)
	engine_destroy(f.eng)
	dom.document_destroy(f.doc)
}

@(private = "file")
node :: proc(f: ^Sx, id: string) -> ^Computed { return style_of(f.st, dom.find_by_id(f.doc, id)) }

SRC :: `<style>
	@property --s { syntax: '<number>'; inherits: true; initial-value: 0 }
	#a { -wren-shader: Card-Foil 1 0.5 50% calc(1 + 1) }
	#n { -wren-shader: none }
	#bad1 { -wren-shader: 5 }
	#bad2 { -wren-shader: foil red }
	#bad3 { -wren-shader: none 1 }
	#bad4 { -wren-shader: foil(1) }
	#bad5 { -wren-shader: foil 1px }
	#bad6 { -wren-shader: ../x }
	#v { -wren-shader: foil var(--s) var(--missing, 7) }
	#anim { -wren-shader: foil var(--s); animation: k 1s linear forwards }
	@keyframes k { from { --s: 0 } to { --s: 1 } }
	#kid { -wren-shader: foil 1 }
</style><div id=a></div><div id=n></div><div id=bad1></div><div id=bad2></div><div id=bad3></div><div id=bad4></div><div id=bad5></div>
<div id=bad6></div><div id=v style="--s: 0.25"></div><div id=anim></div><div id=none></div><div id=p><div id=kid></div></div>`

@(test)
shader_property_parses_names_and_numbers :: proc(t: ^testing.T) {
	f := open(SRC, true)
	defer close(&f)
	a := node(&f, "a")
	testing.expect_value(t, a.wren_shader.name, "card-foil")
	testing.expectf(t, len(a.wren_shader.args) == 4 && a.wren_shader.args[0] == 1 && a.wren_shader.args[1] == 0.5 && a.wren_shader.args[2] == 0.5 && a.wren_shader.args[3] == 2, "args %v (a percentage is a fraction, calc() of numbers works)", a.wren_shader.args)
	testing.expect(t, has_shader(a) && !has_shader(node(&f, "n")) && !has_shader(node(&f, "none")), "none and unset")
	for id in ([]string{"bad1", "bad2", "bad3", "bad4", "bad5", "bad6"}) {
		testing.expectf(t, !has_shader(node(&f, id)), "%s: an invalid value has no effect", id)
	}
	testing.expect(t, has_shader(node(&f, "kid")) && !has_shader(node(&f, "p")), "not inherited")
	testing.expect_value(t, prop_name(.Wren_Shader), "-wren-shader")
}

@(test)
shader_property_refused_outside_built_in_pages :: proc(t: ^testing.T) {
	f := open(SRC, false)
	defer close(&f)
	for id in ([]string{"a", "v", "anim", "kid"}) {
		c := node(&f, id)
		testing.expectf(t, !has_shader(c) && c.wren_shader.args == nil, "%s: a document that is not the browser's own cannot name a shader", id)
	}
	// ... and not through the CSSOM-like inline style either
	g := open(`<div id=i style="-wren-shader: foil 1"></div>`, false)
	defer close(&g)
	testing.expect(t, !has_shader(node(&g, "i")), "style attribute")
	h := open(`<div id=i style="-wren-shader: foil 1"></div>`, true)
	defer close(&h)
	testing.expect(t, has_shader(node(&h, "i")), "style attribute of a built-in page")
}

@(test)
shader_arguments_follow_custom_properties_and_animations :: proc(t: ^testing.T) {
	f := open(SRC, true)
	defer close(&f)
	v := node(&f, "v")
	testing.expectf(t, len(v.wren_shader.args) == 2 && v.wren_shader.args[0] == 0.25 && v.wren_shader.args[1] == 7, "var() and its fallback: %v", v.wren_shader.args)
	timeline_tick(f.tl, f.doc, f.st, 500)
	an := node(&f, "anim")
	testing.expectf(t, len(an.wren_shader.args) == 1 && math.abs(an.wren_shader.args[0] - 0.5) < 0.01, "a registered property animated by CSS reaches the argument: %v", an.wren_shader.args)
	timeline_tick(f.tl, f.doc, f.st, 1200)
	testing.expectf(t, math.abs(node(&f, "anim").wren_shader.args[0] - 1) < 0.001, "after the animation: %v", node(&f, "anim").wren_shader.args)
}

// The animation of `anim` ends with a restyle while the effective style of the last frame (the overlay) holds the shader's name and arguments
// the animation made: update_transitions compares that style with the new one, so the run's memory must still be there (it crashed).
@(test)
shader_arguments_survive_the_end_of_their_animation :: proc(t: ^testing.T) {
	f := open(SRC, true)
	defer close(&f)
	timeline_tick(f.tl, f.doc, f.st, 500)
	testing.expect(t, has_shader(node(&f, "anim")), "the overlay of the running animation")
	dom.set_attribute(f.doc, dom.find_by_id(f.doc, "anim"), "style", "animation: none")
	old := f.st
	f.st = compute_styles(f.eng, f.doc, {})
	timeline_restyled(f.tl, f.doc, old, f.st, 600)
	styled_destroy(old)
	timeline_tick(f.tl, f.doc, f.st, 700)
	an := node(&f, "anim")
	testing.expectf(t, len(an.wren_shader.args) == 1 && an.wren_shader.args[0] == 0, "back to the cascaded value (--s at its initial value): %v", an.wren_shader.args)
}

@(test)
shader_is_a_paint_only_property :: proc(t: ^testing.T) {
	testing.expect(t, prop_tier(.Wren_Shader) == .Paint, "a change of the arguments does not ask for a layout")
}
