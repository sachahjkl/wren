package layout

import "core:testing"
import "wb:dom"

// A <button> whose width is auto is as wide as its content, also when the page makes it a block or a flex container
// (HTML §15.5.x); a <div> of the same display fills its line.
@(test)
button_auto_width_is_fit_content :: proc(t: ^testing.T) {
	x := fixture_load(`<body style="margin:0"><div style="width:400px">
<button id=f style="display:flex;margin:0 auto;padding:0;border:0">Search</button>
<button id=b style="display:block;padding:0;border:0">Search</button>
<div id=d style="display:flex">Search</div></div></body>`)
	defer fixture_unload(x)
	f, _ := box_of(&x.l, dom.find_by_id(x.doc, "f"), x.vp, 0)
	b, _ := box_of(&x.l, dom.find_by_id(x.doc, "b"), x.vp, 0)
	d, _ := box_of(&x.l, dom.find_by_id(x.doc, "d"), x.vp, 0)
	testing.expect(t, f.border.max.x - f.border.min.x < 100, "button, display: flex: its content")
	testing.expect(t, b.border.max.x - b.border.min.x < 100, "button, display: block: its content")
	testing.expect_value(t, d.border.max.x - d.border.min.x, f32(400))
	testing.expect(t, f.border.min.x > 100, "the auto margins center the button")
}
