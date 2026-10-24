package browser

// The developer tools' icons: small vector shapes (strokes, rings, discs, triangles) drawn with the toolkit's rounded
// rectangles, so they stay sharp at any scale and take the colors of the theme. Each is laid out on a 16 x 16 grid and
// scaled to the box it is drawn in; strokes are about one logical pixel and a quarter.

import "core:math"
import "toolkit:draw"

Dt_Icon :: enum u8 {
	None,
	Close, Clear, Trash, Pause, Play, Record, Plus, Minus, Check,
	Chevron_Down, Chevron_Up, Chevron_Right, Chevron_Left, Caret_Down, Caret_Right,
	Search, Kebab, Gear, Filter, Inspect, Copy, Refresh, Download, Upload, Eye, Block,
	Dock_Bottom, Dock_Right, Dock_Left, Float, Detach,
	Info, Warn, Error, Verbose, Prompt, Result, Bracket,
	Sort_Up, Sort_Down,
	File_Doc, File_Script, File_Css, File_Image, File_Font, File_Json, File_Media, File_Socket, File_Fetch, File_Wasm, File_Other,
	Tab_Console, Tab_Elements, Tab_Network, Tab_Application, Tab_Performance, Tab_Memory,
	Cookie, Database, Folder, Lock, Throttle, Pin, Edit, Clock, Style, Layout, Event, Access, Computed,
}

Dt_Pen :: struct {
	dc:  ^draw.Context,
	o:   draw.Vec2,   // the 16 x 16 grid's origin on screen
	u:   f32,         // one grid unit in pixels
	col: draw.Color,
	th:  f32,         // stroke width in pixels
}

pen_seg :: proc(p: ^Dt_Pen, x1, y1, x2, y2: f32) {
	a, b := draw.Vec2{p.o.x + x1 * p.u, p.o.y + y1 * p.u}, draw.Vec2{p.o.x + x2 * p.u, p.o.y + y2 * p.u}
	th := p.th
	d := b - a
	l := math.sqrt(d.x * d.x + d.y * d.y)
	if l < 0.01 { return }
	if math.abs(d.y) < 0.01 {
		y := math.round(a.y - th * 0.5) + th * 0.5
		draw.rect(p.dc, {{min(a.x, b.x) - th * 0.5, y - th * 0.5}, {max(a.x, b.x) + th * 0.5, y + th * 0.5}}, p.col, th * 0.5)
		return
	}
	if math.abs(d.x) < 0.01 {
		x := math.round(a.x - th * 0.5) + th * 0.5
		draw.rect(p.dc, {{x - th * 0.5, min(a.y, b.y) - th * 0.5}, {x + th * 0.5, max(a.y, b.y) + th * 0.5}}, p.col, th * 0.5)
		return
	}
	m := (a + b) * 0.5
	draw.push_transform(p.dc, draw.affine_around(draw.affine_rotate(math.atan2(d.y, d.x)), m))
	draw.rect(p.dc, {{m.x - l * 0.5 - th * 0.5, m.y - th * 0.5}, {m.x + l * 0.5 + th * 0.5, m.y + th * 0.5}}, p.col, th * 0.5)
	draw.pop_transform(p.dc)
}

pen_poly :: proc(p: ^Dt_Pen, pts: []draw.Vec2) {
	for i in 0 ..< len(pts) - 1 { pen_seg(p, pts[i].x, pts[i].y, pts[i + 1].x, pts[i + 1].y) }
}

pen_ring :: proc(p: ^Dt_Pen, cx, cy, r: f32) {
	rr := r * p.u
	c := draw.Vec2{p.o.x + cx * p.u, p.o.y + cy * p.u}
	draw.rect(p.dc, {c - rr, c + rr}, p.col, rr, p.th)
}

pen_disc :: proc(p: ^Dt_Pen, cx, cy, r: f32) {
	rr := r * p.u
	c := draw.Vec2{p.o.x + cx * p.u, p.o.y + cy * p.u}
	draw.rect(p.dc, {c - rr, c + rr}, p.col, rr)
}

// A rectangle outline (or filled) of the grid; `r` its corner radius in grid units.
pen_box :: proc(p: ^Dt_Pen, x1, y1, x2, y2, r: f32, filled := false) {
	rect := draw.Rect{{p.o.x + x1 * p.u, p.o.y + y1 * p.u}, {p.o.x + x2 * p.u, p.o.y + y2 * p.u}}
	rect.min = {math.round(rect.min.x), math.round(rect.min.y)}
	rect.max = {math.round(rect.max.x), math.round(rect.max.y)}
	if filled { draw.rect(p.dc, rect, p.col, r * p.u) } else { draw.rect(p.dc, rect, p.col, r * p.u, p.th) }
}

// A filled triangle, in one-pixel bands so its slanted edges are antialiased across and its tops and bottoms are exact.
pen_tri :: proc(p: ^Dt_Pen, x1, y1, x2, y2, x3, y3: f32) {
	pts := [3]draw.Vec2{{p.o.x + x1 * p.u, p.o.y + y1 * p.u}, {p.o.x + x2 * p.u, p.o.y + y2 * p.u}, {p.o.x + x3 * p.u, p.o.y + y3 * p.u}}
	ymin := min(pts[0].y, pts[1].y, pts[2].y)
	ymax := max(pts[0].y, pts[1].y, pts[2].y)
	y := math.floor(ymin)
	for y < ymax {
		yc := y + 0.5
		lo, hi := f32(1e9), f32(-1e9)
		for i in 0 ..< 3 {
			a, b := pts[i], pts[(i + 1) % 3]
			if (a.y <= yc && b.y > yc) || (b.y <= yc && a.y > yc) {
				x := a.x + (yc - a.y) / (b.y - a.y) * (b.x - a.x)
				lo, hi = min(lo, x), max(hi, x)
			}
		}
		if hi > lo { draw.rect(p.dc, {{lo, y}, {hi, y + 1}}, p.col) }
		y += 1
	}
}

// `size`: the side of the square the 16 x 16 grid is scaled to.
dt_icon :: proc(dc: ^draw.Context, icon: Dt_Icon, center: draw.Vec2, size: f32, col: draw.Color, sc: f32) {
	u := size / 16
	p := Dt_Pen{dc = dc, o = {math.round(center.x - size * 0.5), math.round(center.y - size * 0.5)}, u = u, col = col, th = max(math.round(1.25 * sc), 1)}
	switch icon {
	case .None:
	case .Close: pen_seg(&p, 4, 4, 12, 12); pen_seg(&p, 12, 4, 4, 12)
	case .Clear, .Block:
		pen_ring(&p, 8, 8, 5.6)
		pen_seg(&p, 4.2, 4.2, 11.8, 11.8)
	case .Trash:
		pen_seg(&p, 2.8, 4.2, 13.2, 4.2)
		pen_poly(&p, {{6, 4.2}, {6, 2.4}, {10, 2.4}, {10, 4.2}})
		pen_poly(&p, {{4.2, 4.2}, {4.9, 13.6}, {11.1, 13.6}, {11.8, 4.2}})
		pen_seg(&p, 6.8, 6.6, 6.8, 11.4); pen_seg(&p, 9.2, 6.6, 9.2, 11.4)
	case .Pause: pen_box(&p, 4.2, 3.2, 6.9, 12.8, 0.6, true); pen_box(&p, 9.1, 3.2, 11.8, 12.8, 0.6, true)
	case .Play: pen_tri(&p, 4.6, 2.8, 13, 8, 4.6, 13.2)
	case .Record: pen_disc(&p, 8, 8, 4.4)
	case .Plus: pen_seg(&p, 8, 3, 8, 13); pen_seg(&p, 3, 8, 13, 8)
	case .Minus: pen_seg(&p, 3, 8, 13, 8)
	case .Check: pen_poly(&p, {{3.2, 8.4}, {6.6, 11.8}, {12.8, 4.6}})
	case .Chevron_Down: pen_poly(&p, {{3.6, 6}, {8, 10.4}, {12.4, 6}})
	case .Chevron_Up: pen_poly(&p, {{3.6, 10}, {8, 5.6}, {12.4, 10}})
	case .Chevron_Right: pen_poly(&p, {{6, 3.6}, {10.4, 8}, {6, 12.4}})
	case .Chevron_Left: pen_poly(&p, {{10, 3.6}, {5.6, 8}, {10, 12.4}})
	case .Caret_Down: pen_tri(&p, 3.6, 5.6, 12.4, 5.6, 8, 10.6)
	case .Caret_Right: pen_tri(&p, 5.6, 3.4, 5.6, 12.6, 10.6, 8)
	case .Search:
		pen_ring(&p, 7, 7, 4.3)
		pen_seg(&p, 10.2, 10.2, 13.6, 13.6)
	case .Kebab: pen_disc(&p, 8, 3.2, 1.35); pen_disc(&p, 8, 8, 1.35); pen_disc(&p, 8, 12.8, 1.35)
	case .Gear:
		pen_ring(&p, 8, 8, 3.1)
		for i in 0 ..< 8 {
			a := f32(i) * math.PI / 4
			c, s := math.cos(a), math.sin(a)
			pen_seg(&p, 8 + c * 5, 8 + s * 5, 8 + c * 6.7, 8 + s * 6.7)
		}
	case .Filter:
		pen_tri(&p, 2.4, 3.2, 13.6, 3.2, 8, 9.2)
		pen_box(&p, 6.9, 8.6, 9.1, 13.4, 0.4, true)
	case .Inspect:
		pen_poly(&p, {{2.4, 6}, {2.4, 2.4}, {6, 2.4}})
		pen_poly(&p, {{10, 2.4}, {13.6, 2.4}, {13.6, 6}})
		pen_poly(&p, {{2.4, 10}, {2.4, 13.6}, {6, 13.6}})
		pen_tri(&p, 6.2, 6.2, 14, 9.4, 9.8, 10.4)
		pen_tri(&p, 9.8, 10.4, 11.9, 8.6, 12.4, 13.6)
	case .Copy:
		pen_box(&p, 5.6, 5.6, 13.4, 13.4, 1.2)
		pen_poly(&p, {{4, 10.4}, {2.6, 10.4}, {2.6, 2.6}, {10.4, 2.6}, {10.4, 4}})
	case .Refresh:
		n := 12
		for i in 0 ..< n {
			a0 := -0.4 + f32(i) * (math.PI * 1.55) / f32(n)
			a1 := -0.4 + f32(i + 1) * (math.PI * 1.55) / f32(n)
			pen_seg(&p, 8 + math.cos(a0) * 5, 8 + math.sin(a0) * 5, 8 + math.cos(a1) * 5, 8 + math.sin(a1) * 5)
		}
		pen_tri(&p, 11.8, 1.6, 14.4, 6.6, 8.8, 6.2)
	case .Download: pen_seg(&p, 8, 2.6, 8, 10); pen_poly(&p, {{4.6, 7}, {8, 10.4}, {11.4, 7}}); pen_seg(&p, 3, 13.4, 13, 13.4)
	case .Upload: pen_seg(&p, 8, 13.4, 8, 6); pen_poly(&p, {{4.6, 9}, {8, 5.6}, {11.4, 9}}); pen_seg(&p, 3, 2.6, 13, 2.6)
	case .Eye:
		pen_poly(&p, {{1.8, 8}, {4.4, 4.8}, {8, 3.6}, {11.6, 4.8}, {14.2, 8}, {11.6, 11.2}, {8, 12.4}, {4.4, 11.2}, {1.8, 8}})
		pen_disc(&p, 8, 8, 2)
	case .Dock_Bottom: pen_box(&p, 1.8, 2.6, 14.2, 13.4, 1.4); pen_box(&p, 1.8, 8.8, 14.2, 13.4, 0.6, true)
	case .Dock_Right: pen_box(&p, 1.8, 2.6, 14.2, 13.4, 1.4); pen_box(&p, 9.2, 2.6, 14.2, 13.4, 0.6, true)
	case .Dock_Left: pen_box(&p, 1.8, 2.6, 14.2, 13.4, 1.4); pen_box(&p, 1.8, 2.6, 6.8, 13.4, 0.6, true)
	case .Float: pen_box(&p, 1.8, 2.6, 10.8, 10, 1.2); pen_box(&p, 5.4, 6.2, 14.2, 13.4, 1.2, true)
	case .Detach:
		pen_poly(&p, {{7, 3.4}, {3, 3.4}, {2, 4.4}, {2, 13}, {3, 14}, {11.6, 14}, {12.6, 13}, {12.6, 9}})
		pen_seg(&p, 8, 8, 14, 2)
		pen_poly(&p, {{9.6, 2}, {14, 2}, {14, 6.4}})
	case .Info:
		pen_ring(&p, 8, 8, 5.8)
		pen_disc(&p, 8, 5.2, 0.85)
		pen_seg(&p, 8, 7.4, 8, 11.2)
	case .Warn:
		pen_tri(&p, 8, 2, 14.4, 13.4, 1.6, 13.4)
	case .Error:
		pen_disc(&p, 8, 8, 6.2)
	case .Verbose:
		pen_ring(&p, 8, 8, 5.8)
		pen_seg(&p, 5.4, 8, 10.6, 8)
	case .Prompt: pen_poly(&p, {{5, 4}, {9.4, 8}, {5, 12}})
	case .Result: pen_poly(&p, {{10.6, 4}, {6.2, 8}, {10.6, 12}})
	case .Bracket: pen_poly(&p, {{6.4, 3}, {4.4, 3}, {4.4, 13}, {6.4, 13}}); pen_poly(&p, {{9.6, 3}, {11.6, 3}, {11.6, 13}, {9.6, 13}})
	case .Sort_Up: pen_tri(&p, 8, 4.4, 12.4, 11, 3.6, 11)
	case .Sort_Down: pen_tri(&p, 3.6, 5, 12.4, 5, 8, 11.6)
	case .File_Doc:
		pen_poly(&p, {{3.6, 1.8}, {9.6, 1.8}, {12.6, 4.8}, {12.6, 14.2}, {3.6, 14.2}, {3.6, 1.8}})
		pen_poly(&p, {{9.6, 1.8}, {9.6, 4.8}, {12.6, 4.8}})
		pen_seg(&p, 5.6, 8, 10.6, 8); pen_seg(&p, 5.6, 10.8, 10.6, 10.8)
	case .File_Script: pen_poly(&p, {{5.6, 3.6}, {1.8, 8}, {5.6, 12.4}}); pen_poly(&p, {{10.4, 3.6}, {14.2, 8}, {10.4, 12.4}}); pen_seg(&p, 9.2, 2.6, 6.8, 13.4)
	case .File_Css:
		pen_seg(&p, 6, 2.6, 5, 13.4); pen_seg(&p, 11, 2.6, 10, 13.4)
		pen_seg(&p, 2.6, 6, 13.4, 6); pen_seg(&p, 2.2, 10, 13, 10)
	case .File_Image:
		pen_box(&p, 1.8, 2.6, 14.2, 13.4, 1.2)
		pen_poly(&p, {{2.4, 11.6}, {6, 7.4}, {8.6, 10.2}, {10.4, 8.4}, {13.6, 11.8}})
		pen_disc(&p, 11, 5.4, 1.3)
	case .File_Font: pen_poly(&p, {{3, 13.4}, {8, 2.6}, {13, 13.4}}); pen_seg(&p, 5, 9.6, 11, 9.6)
	case .File_Json:
		pen_poly(&p, {{6.6, 2.4}, {5.2, 2.4}, {5.2, 6.6}, {3.2, 8}, {5.2, 9.4}, {5.2, 13.6}, {6.6, 13.6}})
		pen_poly(&p, {{9.4, 2.4}, {10.8, 2.4}, {10.8, 6.6}, {12.8, 8}, {10.8, 9.4}, {10.8, 13.6}, {9.4, 13.6}})
	case .File_Media: pen_box(&p, 1.8, 2.8, 14.2, 13.2, 1.4); pen_tri(&p, 6.4, 5.4, 11, 8, 6.4, 10.6)
	case .File_Socket:
		pen_seg(&p, 2.4, 5.4, 12.6, 5.4); pen_poly(&p, {{10, 2.8}, {12.8, 5.4}, {10, 8}})
		pen_seg(&p, 13.6, 10.6, 3.4, 10.6); pen_poly(&p, {{6, 8}, {3.2, 10.6}, {6, 13.2}})
	case .File_Fetch:
		pen_seg(&p, 5, 13, 5, 3.6); pen_poly(&p, {{2.4, 6.2}, {5, 3.4}, {7.6, 6.2}})
		pen_seg(&p, 11, 3, 11, 12.4); pen_poly(&p, {{8.4, 9.8}, {11, 12.6}, {13.6, 9.8}})
	case .File_Wasm:
		pen_poly(&p, {{8, 1.8}, {13.6, 5}, {13.6, 11}, {8, 14.2}, {2.4, 11}, {2.4, 5}, {8, 1.8}})
		pen_poly(&p, {{5.2, 6}, {6.6, 10.4}, {8, 7}, {9.4, 10.4}, {10.8, 6}})
	case .File_Other: pen_disc(&p, 4, 8, 1.2); pen_disc(&p, 8, 8, 1.2); pen_disc(&p, 12, 8, 1.2)
	case .Tab_Console:
		pen_box(&p, 1.8, 2.8, 14.2, 13.2, 1.4)
		pen_poly(&p, {{4.6, 6}, {7, 8}, {4.6, 10}}); pen_seg(&p, 8.4, 10.4, 11.4, 10.4)
	case .Tab_Elements: pen_poly(&p, {{5.6, 3.6}, {1.8, 8}, {5.6, 12.4}}); pen_poly(&p, {{10.4, 3.6}, {14.2, 8}, {10.4, 12.4}})
	case .Tab_Network:
		pen_seg(&p, 5, 13, 5, 3.6); pen_poly(&p, {{2.4, 6.2}, {5, 3.4}, {7.6, 6.2}})
		pen_seg(&p, 11, 3, 11, 12.4); pen_poly(&p, {{8.4, 9.8}, {11, 12.6}, {13.6, 9.8}})
	case .Tab_Application:
		pen_ring(&p, 8, 4.2, 4.6)
		pen_seg(&p, 3.4, 4.2, 3.4, 11.6); pen_seg(&p, 12.6, 4.2, 12.6, 11.6)
		pen_poly(&p, {{3.4, 11.6}, {5, 12.8}, {8, 13.4}, {11, 12.8}, {12.6, 11.6}})
		pen_poly(&p, {{3.4, 8}, {5, 9.2}, {8, 9.8}, {11, 9.2}, {12.6, 8}})
	case .Tab_Performance: pen_box(&p, 2.6, 8, 5, 13.4, 0.5, true); pen_box(&p, 6.8, 3.4, 9.2, 13.4, 0.5, true); pen_box(&p, 11, 6, 13.4, 13.4, 0.5, true)
	case .Tab_Memory:
		pen_box(&p, 3.6, 3.6, 12.4, 12.4, 1.2)
		pen_box(&p, 6, 6, 10, 10, 0.4, true)
		for k in 0 ..< 3 {
			t := 5.6 + f32(k) * 2.4
			pen_seg(&p, t, 1.6, t, 3.6); pen_seg(&p, t, 12.4, t, 14.4)
			pen_seg(&p, 1.6, t, 3.6, t); pen_seg(&p, 12.4, t, 14.4, t)
		}
	case .Cookie:
		pen_ring(&p, 8, 8, 5.8)
		pen_disc(&p, 6, 6.4, 0.9); pen_disc(&p, 9.6, 9.6, 0.9); pen_disc(&p, 6.6, 10.4, 0.8); pen_disc(&p, 10, 5.6, 0.7)
	case .Database:
		pen_ring(&p, 8, 4.2, 4.6)
		pen_seg(&p, 3.4, 4.2, 3.4, 11.6); pen_seg(&p, 12.6, 4.2, 12.6, 11.6)
		pen_poly(&p, {{3.4, 11.6}, {5, 12.8}, {8, 13.4}, {11, 12.8}, {12.6, 11.6}})
	case .Folder: pen_poly(&p, {{2, 4}, {6.2, 4}, {7.6, 5.6}, {14, 5.6}, {14, 13}, {2, 13}, {2, 4}})
	case .Lock: pen_box(&p, 3.4, 7, 12.6, 14, 1.2); pen_poly(&p, {{5.4, 7}, {5.4, 4.8}, {6.6, 2.8}, {9.4, 2.8}, {10.6, 4.8}, {10.6, 7}})
	case .Throttle:
		n := 10
		for i in 0 ..< n {
			a0 := math.PI + f32(i) * math.PI / f32(n)
			a1 := math.PI + f32(i + 1) * math.PI / f32(n)
			pen_seg(&p, 8 + math.cos(a0) * 6, 11.4 + math.sin(a0) * 6, 8 + math.cos(a1) * 6, 11.4 + math.sin(a1) * 6)
		}
		pen_seg(&p, 8, 11.4, 11.2, 6.4); pen_disc(&p, 8, 11.4, 1.2)
	case .Pin: pen_disc(&p, 8, 6, 3.4); pen_seg(&p, 8, 9, 8, 14.2)
	case .Edit: pen_poly(&p, {{2.6, 13.4}, {3.2, 10.2}, {10.8, 2.6}, {13.4, 5.2}, {5.8, 12.8}, {2.6, 13.4}})
	case .Clock: pen_ring(&p, 8, 8, 5.8); pen_poly(&p, {{8, 4.6}, {8, 8}, {10.6, 9.4}})
	case .Style: pen_seg(&p, 3, 4, 13, 4); pen_seg(&p, 3, 8, 13, 8); pen_seg(&p, 3, 12, 9, 12)
	case .Layout: pen_box(&p, 2.4, 2.4, 13.6, 13.6, 0.8); pen_box(&p, 5.4, 5.4, 10.6, 10.6, 0.4)
	case .Event: pen_tri(&p, 9.4, 1.8, 3.6, 9, 7.6, 9); pen_tri(&p, 7.6, 9, 12.4, 9, 6.6, 14.2)
	case .Access: pen_ring(&p, 8, 3.8, 1.5); pen_seg(&p, 3, 6.4, 13, 6.4); pen_seg(&p, 8, 6.4, 8, 10.6); pen_seg(&p, 8, 10.6, 5.6, 14.2); pen_seg(&p, 8, 10.6, 10.4, 14.2)
	case .Computed: pen_box(&p, 2.4, 3, 13.6, 13, 0.8); pen_seg(&p, 2.4, 6.6, 13.6, 6.6); pen_seg(&p, 6.6, 6.6, 6.6, 13)
	}
}
