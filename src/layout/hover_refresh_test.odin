package layout

import "core:fmt"
import "core:math"
import "core:testing"
import "wb:base"
import "wb:dom"
import "wb:style"

// A paint-only hover over one of alike links (they share one style record: style/share.odin) refreshes the display list
// (refresh.odin): the hovered link's items take its new record, the others keep theirs.

@(private = "file")
HOVER_LINKS :: `<style>
body { margin: 0 }
nav a { display: inline-block; color: rgb(0, 0, 255); background-color: rgb(255, 255, 255) }
nav a:hover { color: rgb(255, 0, 0); background-color: rgb(0, 0, 0) }
</style><nav><a id=a1 href=/1>one</a> <a id=a2 href=/2>two</a> <a id=a3 href=/3>three</a> <a id=a4 href=/4>four</a></nav>`

// A script that turns an element by its inline style at every frame (the licence card of about:wren, tilted by the pointer) makes
// refresh passes, not layouts: the transform and a custom property are paint-only, and the document changed in nothing but a style
// attribute. The plane's matrix follows. A style attribute that changes a size is laid out again, and so is another attribute.
@(test)
inline_transform_refreshes :: proc(t: ^testing.T) {
	f := fixture_load(`<style>body { margin: 0 } #c { width: 100px; height: 60px; transform: rotateY(1deg) }</style><div style="perspective: 900px"><div id=c>card</div></div>`, o = {journal = true})
	defer fixture_unload(f)
	c := dom.find_by_id(f.doc, "c")
	write :: proc(t: ^testing.T, f: ^Fixture, h: base.Handle, name, value: string) {
		dom.set_attribute(f.doc, h, name, value)
		_, ok := style.restyle_dom(f.eng, f.doc, f.st)
		testing.expect(t, ok, "restyled in place")
		fixture_run(f)
	}
	for deg in ([]f32{5, 10, 15}) {
		write(t, f, c, "style", fmt.tprintf("transform: rotateY(%.0fdeg); --rx: %.0f", deg, deg))
		testing.expectf(t, f.l.last_pass == .Refresh, "rotateY(%.0fdeg) written in the style attribute: a refresh (%v)", deg, f.l.last_pass)
		testing.expect(t, f.l.mutations == f.doc.mutations, "the layout has caught up with the document")
		turned := false
		for &sp in f.l.spaces {
			if sp.proj && f.l.boxes[sp.box].node == c { turned = abs(sp.mat4[0] - math.cos(deg * math.PI / 180)) < 1e-4 }
		}
		testing.expectf(t, turned, "the plane is turned by %.0fdeg", deg)
	}
	write(t, f, c, "style", "transform: rotateY(15deg); width: 120px")
	testing.expectf(t, f.l.last_pass != .Refresh, "a size in the style attribute is laid out (%v)", f.l.last_pass)
	write(t, f, c, "title", "card")
	testing.expectf(t, f.l.last_pass != .Refresh, "another attribute is not taken for a style (%v)", f.l.last_pass)
}

@(test)
hover_refreshes_one_link_of_alike_ones :: proc(t: ^testing.T) {
	f := fixture_load(HOVER_LINKS, o = {journal = true})
	defer fixture_unload(f)
	ids := []string{"a1", "a2", "a3", "a4"}
	testing.expect(t, style.style_of(f.st, dom.find_by_id(f.doc, "a1")) == style.style_of(f.st, dom.find_by_id(f.doc, "a3")), "alike links share a record")
	for hovered in ids {
		_, ok := style.restyle_state(f.eng, f.doc, f.st, style.State{hover = dom.find_by_id(f.doc, hovered)})
		testing.expect(t, ok)
		fixture_run(f)
		testing.expectf(t, f.l.last_pass == .Refresh, "a paint-only hover refreshes: %v", f.l.last_pass)
		for id in ids {
			h := dom.find_by_id(f.doc, id)
			red := id == hovered
			boxes, texts := 0, 0
			for &it in f.l.items {
				if it.node != h { continue }
				switch it.kind {
				case .Box:
					boxes += 1
					testing.expectf(t, (it.cs.background_color.r < 0.5) == red, "hover on %s: the background of %s", hovered, id)
				case .Text:
					texts += 1
					testing.expectf(t, (it.cs.color.r > 0.5) == red, "hover on %s: the text of %s", hovered, id)
				case .Inline_Box, .Marker, .Replaced, .Control, .Outline, .Scrollbar, .Column_Rule:
				}
			}
			testing.expectf(t, boxes == 1 && texts == 1, "%s: a box and a text item (%d, %d)", id, boxes, texts)
		}
	}
}
