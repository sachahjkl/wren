package browser

import "toolkit:draw"
import "wb:base"
import lay "wb:layout"
import "wb:page"
import "wb:style"

// Container queries close a loop between style and layout (style/container.odin): after a layout, the content boxes of
// the query containers go back to the style engine; when one changed and some @container rule or cq unit depends on it,
// styles and layout are computed again, at most style.container_queries.max_rounds times in one frame.
settle_container_queries :: proc(app: ^App, t: ^Tab, styled: ^style.Styled, size: draw.Vec2, scale: f32, fonts_gen: u64) -> ^style.Styled {
	e := page_engine(t.page)
	if e == nil || !style.engine_uses_container_queries(e) { return styled }
	st := styled
	for _ in 0 ..< e.settings.cq_max_rounds {
		sizes := make(map[base.Handle][2]f32, context.temp_allocator)
		for h in style.styled_containers(st) {
			r, ok := lay.box_of(&t.layout, h, size, 0)
			if !ok { continue }
			sizes[h] = {(r.content.max.x - r.content.min.x) / scale, (r.content.max.y - r.content.min.y) / scale}
		}
		if !style.engine_set_container_sizes(e, sizes) { break }
		st = page.styles(t.page, size.x / scale, size.y / scale, f64(scale))
		if layout_stale(&t.layout, t.page.doc, st, size, scale, t.image_sizes, fonts_gen) {
			layout_document(&t.layout, t.page.doc, st, &app.measure, &app.page_settings.style, size, scale, app.cfg.layout_band_px, t.image_sizes, fonts_gen)
		}
	}
	return st
}

@(private = "file")
page_engine :: proc(p: ^page.Page) -> ^style.Engine { return p != nil ? p.engine : nil }
