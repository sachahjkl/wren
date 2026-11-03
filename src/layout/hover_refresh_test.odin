package layout

import "core:testing"
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
