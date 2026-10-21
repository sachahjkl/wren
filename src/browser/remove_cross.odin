package browser

// The cross at the end of a row that removes it (about:history, the address bar's suggestions): a thin cross in a round
// button, shown on the row under the pointer or the active one (`shown`), red with a light red disc under the pointer
// itself (toolkit theme: "remove_button hot text", "remove_button hover_fill"). Clickable even while hidden: the
// pointer on it is on its row, which shows it.

import "core:math"
import "toolkit:draw"
import "toolkit:ui"

remove_cross :: proc(id: string, shown: bool, em: f32, tooltip := "Remove from history") -> ui.Signal {
	cs := math.round(em * 1.6)
	ui.next({width = ui.px(cs), height = ui.px(cs), radius = cs * 0.5, cursor = .Hand})
	sig: ui.Signal
	if ui.tags("remove_button", "icon_button", "weak") {
		b := ui.build_box({.Clickable, .Draw_Background, .Draw_Hot_Effects}, id)
		sig = ui.signal(b)
		col := ui.frame_new(draw.Color)
		col^ = b.text_color   // weak, or red under the pointer
		if !shown && !sig.hovering { col.a = 0 }
		b.custom, b.custom_user = remove_cross_draw, col
	}
	if sig.box != nil { tip(sig, tooltip) }
	return sig
}

@(private = "file")
remove_cross_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	col := (^draw.Color)(user)^
	if col.a <= 0 { return }
	c := draw.rect_center(b.rect)
	arm := (b.rect.max.x - b.rect.min.x) * 0.2
	th := max(math.round(1.25 * ui.scale()), 1)
	for angle in ([2]f32{math.PI / 4, -math.PI / 4}) {
		draw.push_transform(dc, draw.affine_around(draw.affine_rotate(angle), c))
		draw.rect(dc, {{c.x - arm, c.y - th * 0.5}, {c.x + arm, c.y + th * 0.5}}, col, th * 0.5)
		draw.pop_transform(dc)
	}
}
