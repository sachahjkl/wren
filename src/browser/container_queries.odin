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
	if e == nil || !style.engine_uses_container_queries(e) || !t.layout.valid { return styled }
	passes := t.layout.passes[.Full] + t.layout.passes[.Incremental]
	if style.engine_cq_settled(e, &t.layout, passes, t.layout.serial, scale) { return styled }
	st := styled
	for _ in 0 ..< e.settings.cq_max_rounds {
		containers := style.engine_containers(e, st)
		if len(containers) == 0 && len(e.container_sizes) == 0 { break }
		sizes := make(map[base.Handle][2]f32, len(containers), context.temp_allocator)
		for h in containers {
			csz, ok := lay.content_size(&t.layout, h)
			if !ok { continue }
			sizes[h] = {csz.x / scale, csz.y / scale}
		}
		if !style.engine_set_container_sizes(e, sizes) { break }
		st = page.styles(t.page, size.x / scale, size.y / scale, f64(scale))
		if layout_stale(&t.layout, t.page.doc, st, size, scale, t.image_sizes, fonts_gen) {
			if t.view == nil {
				page_layout(app, t, st, size, scale, fonts_gen)
			} else {
				layout_document(&t.layout, t.page.doc, st, &app.measure, &app.page_settings.style, size, scale, app.cfg.layout_band_px, t.image_sizes, fonts_gen)
			}
		}
	}
	style.engine_cq_mark_settled(e, &t.layout, t.layout.passes[.Full] + t.layout.passes[.Incremental], t.layout.serial, scale)
	return st
}

@(private = "file")
page_engine :: proc(p: ^page.Page) -> ^style.Engine { return p != nil ? p.engine : nil }
