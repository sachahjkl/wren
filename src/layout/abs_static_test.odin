package layout

import "core:math"
import "core:testing"
import "wb:dom"

// The static position of an absolutely positioned child of a flex or grid container: where it would be as the sole item
// (CSS Flexbox §4.1, CSS Grid §9.1; a search field's icon over its input, centred by align-items). Expected values
// measured in Edge.

@(private = "file")
AS_VP_W :: 800
@(private = "file")
AS_VP_H :: 600

@(test)
abs_static_position_aligned_in_flex_and_grid :: proc(t: ^testing.T) {
	f := fixture_load(`<!doctype html><style>*{box-sizing:border-box;margin:0}i{position:absolute;width:16px;height:16px}div{position:relative;width:200px;height:36px}</style><body style="font:14px main">
<div style="display:flex;align-items:center"><i id=a></i></div>
<div style="display:flex;align-items:flex-end;justify-content:center"><i id=b></i></div>
<div style="display:flex;flex-direction:column;justify-content:flex-end;align-items:center"><i id=c></i></div>
<div style="display:flex;flex-direction:row-reverse"><i id=d></i></div>
<div style="display:flex;align-items:center"><i id=e style="top:2px"></i></div>
<div style="display:grid;place-items:center end"><i id=g></i></div>
<div style="display:flex;align-items:center;padding:4px 10px"><i id=p style="align-self:start"></i></div></body>`, AS_VP_W, AS_VP_H)
	defer fixture_unload(f)
	Want :: struct { id: string, x, y: f32 }
	for c in ([]Want{{"a", 0, 10}, {"b", 92, 36 + 20}, {"c", 92, 72 + 20}, {"d", 184, 108}, {"e", 0, 144 + 2}, {"g", 184, 180 + 10}, {"p", 10, 216 + 4}}) {
		r, ok := box_of(&f.l, dom.find_by_id(f.doc, c.id), f.vp, 0)
		got := r.border
		testing.expectf(t, ok && math.abs(got.min.x - c.x) < 0.02 && math.abs(got.min.y - c.y) < 0.02, "%s: at %v, want %v %v", c.id, got.min, c.x, c.y)
	}
}
