package layout

import "core:math"
import "core:testing"
import "wb:dom"

// Row heights: a cell's height is a minimum, content taller than it makes its row taller (CSS 2.1 §17.5.3; a design
// system's compact data table, `td { height: var(--_row-h) }`, with a description that wraps and a flex row of chips).

@(private = "file")
TH_VP_W :: 800
@(private = "file")
TH_VP_H :: 600

@(test)
table_cell_height_is_a_minimum :: proc(t: ^testing.T) {
	f := fixture_load(`<!doctype html><style>*{box-sizing:border-box;margin:0}td{height:36px;padding:4px 12px}</style><body style="font:14px main">
<table style="border-spacing:0"><tbody>
<tr><td id=a><div style="height:100px;width:50px"></div></td><td id=b><div style="display:flex;flex-wrap:wrap;width:60px"><div style="width:40px;height:20px"></div><div style="width:40px;height:20px"></div></div></td></tr>
<tr><td id=c><div style="height:10px;width:50px"></div></td><td id=d></td></tr></tbody></table></body>`, TH_VP_W, TH_VP_H)
	defer fixture_unload(f)
	Want :: struct { id: string, y, h: f32 }
	for c in ([]Want{{"a", 0, 108}, {"b", 0, 108}, {"c", 108, 36}, {"d", 108, 36}}) {
		r, ok := box_of(&f.l, dom.find_by_id(f.doc, c.id), f.vp, 0)
		got := r.border
		testing.expectf(t, ok && math.abs(got.min.y - c.y) < 0.02 && math.abs(got.max.y - got.min.y - c.h) < 0.02, "%s: y %v h %v, want y %v h %v", c.id, got.min.y, got.max.y - got.min.y, c.y, c.h)
	}
}
