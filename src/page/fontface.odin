package page

// The rules of FontFace objects added to document.fonts (native/js/odin/web_fontface.js): a style sheet each, with no owner element.

import "wb:style"

FontFace_addRule :: proc(c: ^Call, rule: string) -> i32 {
	p := c.page
	if p.engine == nil { return -1 }
	s := style.engine_add_sheet(p.engine, rule, 0, "", p.env.location.href)
	if s == nil { return -1 }
	for &x, i in p.font_face_sheets {
		if x == nil {
			x = s
			return i32(i)
		}
	}
	append(&p.font_face_sheets, s)
	return i32(len(p.font_face_sheets) - 1)
}

FontFace_removeRule :: proc(c: ^Call, id: i32) {
	p := c.page
	if p.engine == nil || id < 0 || int(id) >= len(p.font_face_sheets) || p.font_face_sheets[id] == nil { return }
	style.engine_remove_sheet(p.engine, p.font_face_sheets[id])
	p.font_face_sheets[id] = nil
	p.engine.restyle_needed, p.engine.restyle_why = true, "a font face rule left"
	p.style_stale = true
}

// What document.fonts waits for: a face some element uses, queued or on its way. The styles first: they queue what an element
// asks for (CSS Font Loading 3: the set is pending on the environment while a style pass could ask for a font).
@(private = "file")
fonts_on_their_way :: proc(p: ^Page) -> bool {
	js_dom_styled(p)
	return p.fonts.loading > 0 || len(p.fonts.queue) > 0
}

FontFaceSet_loading :: proc(c: ^Call) -> bool { return fonts_on_their_way(c.page) }

// Fulfilled by fonts_pump once the last of them has loaded or failed.
FontFaceSet_ready :: proc(c: ^Call) -> u64 {
	pr := promise_create(c.page, c.owner)
	if fonts_on_their_way(c.page) { append(&c.page.fonts.waiting, pr) } else { promise_resolve(c.page, pr, 0) }
	return pr
}
