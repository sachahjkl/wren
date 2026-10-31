package page

// The rules of FontFace objects added to document.fonts (native/js/odin/web_fontface.js): a style sheet each, with no owner element.

import "wb:style"

FontFace_addRule :: proc(c: ^Call, rule: string) -> i32 {
	p := c.page
	if p.engine == nil { return -1 }
	s := style.engine_add_sheet(p.engine, rule, 0, "", p.env.location.href)
	if s == nil { return -1 }
	p.engine.restyle_needed = true
	p.style_stale = true
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
	p.engine.restyle_needed = true
	p.style_stale = true
}
