package browser

// What the Network tab's Preview shows of a response besides JSON: an image (decoded by the images package, drawn fitted or
// at its size on a checkerboard, with its natural size, format and bytes; the Response tab shows the same as a thumbnail), a
// font (a specimen: sizes, alphabets, digits, set in the font itself, read from the bytes by DirectWrite), an HTML page (a
// reader view of its markup: titles, paragraphs, lists, links, code, with the text wrapped to the pane; the page itself
// opens in a tab from the toolbar), and audio and video (devtools_net_media.odin). The decoded things belong to the request
// that is chosen and go when another is.

import "core:fmt"
import "core:math"
import "core:strings"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:render"
import "toolkit:ui"
import "wb:base"
import "wb:dom"
import "wb:html"
import "wb:images"

Pv_Kind :: enum u8 { None, Image, Font, Html, Media }

Preview_State :: struct {
	id:      u64,             // the request this is of
	len:     int,             // the bytes it was made from
	kind:    Pv_Kind,
	// an image
	tex:     render.Texture,
	tex_ok:  bool,
	nw, nh:  int,             // the natural size
	frames:  int,
	format:  string,          // (a literal)
	err:     string,          // owned: why it could not be shown
	fit:     bool,            // fitted to the pane (else its own size)
	unfit:   bool,            // `fit` was set by the user
	// a font
	font:    font.Font_Id,
	font_ok: bool,
	// an HTML page
	html:    Html_Reader,
	source:  bool,            // the markup as text instead
	list:    Dt_List,
	scroll:  ui.Key,
}

preview_kind_of :: proc(e: ^Net_Entry) -> Pv_Kind {
	m := net_mime_base(e.mime)
	path := e.url
	if q := strings.index_any(path, "?#"); q >= 0 { path = path[:q] }
	switch {
	case e.type == .Img || strings.has_prefix(m, "image/"): return .Image
	case e.type == .Font || strings.has_prefix(m, "font/") || strings.has_suffix(m, "font-woff") || strings.has_suffix(m, "font-woff2") || strings.has_suffix(path, ".ttf") || strings.has_suffix(path, ".otf") || strings.has_suffix(path, ".woff") || strings.has_suffix(path, ".woff2"): return .Font
	case e.type == .Media || strings.has_prefix(m, "video/") || strings.has_prefix(m, "audio/") || m == "application/ogg": return .Media
	case m == "text/html" || m == "application/xhtml+xml": return .Html
	}
	return .None
}

preview_release :: proc(pv: ^Preview_State) {
	app := the_app
	if app != nil {
		if pv.tex_ok { render.destroy_texture(&app.r, pv.tex) }
		if pv.font_ok { font.unload(&app.fonts, pv.font) }
	}
	html_reader_free(&pv.html)
	dt_list_destroy(&pv.list)
	delete(pv.err)
	net_media_release()
	pv^ = {}
}

// Makes the preview of `e` when it is not made (or its bytes grew).
@(private = "file")
preview_ensure :: proc(app: ^App, d: ^Net_Detail, e: ^Net_Entry, kind: Pv_Kind) {
	pv := &d.pv
	if pv.id == e.id && pv.kind == kind && pv.len == len(e.body) { return }
	keep_fit, keep_unfit := pv.fit, pv.unfit
	preview_release(pv)
	pv.id, pv.kind, pv.len = e.id, kind, len(e.body)
	pv.fit, pv.unfit = keep_fit, keep_unfit
	if !pv.unfit { pv.fit = true }
	body := e.body[:]
	if len(body) == 0 { return }
	switch kind {
	case .Image:
		lim := app.page_settings.images.limits
		opts := images.Decode_Options{limits = lim, target_w = 4096, target_h = 4096, downscale_below = 0.99, first_frame_only = true, mime = net_mime_base(e.mime)}
		img, info, err := images.decode_now(body, opts)
		if err != .None || img == nil || len(img.frames) == 0 {
			pv.err = strings.clone(fmt.tprintf("The image could not be decoded (%v).", err))
			if img != nil { images.image_destroy(img) }
			return
		}
		pv.nw, pv.nh, pv.frames, pv.format = info.width, info.height, info.frames, image_format_name(info.format)
		pv.tex = render.create_texture_rgba(&app.r, img.width, img.height)
		render.update_texture_rgba(&app.r, pv.tex, 0, 0, img.width, img.height, img.frames[0].pixels, img.stride)
		pv.tex_ok = true
		images.image_destroy(img)
	case .Font:
		copied := make([]byte, len(body))
		copy(copied, body)
		id, ok := font.load_from_memory(&app.fonts, copied)
		if ok { pv.font, pv.font_ok = id, true } else { pv.err = strings.clone("This font could not be read (WOFF2 and collections are not read by the preview).") }
	case .Html:
		html_reader_make(&pv.html, body)
	case .Media, .None:
	}
}

@(private = "file")
image_format_name :: proc(f: images.Format) -> string {
	switch f {
	case .Png: return "PNG"
	case .Jpeg: return "JPEG"
	case .Gif: return "GIF"
	case .Webp: return "WebP"
	case .Bmp: return "BMP"
	case .Ico: return "ICO"
	case .Tiff: return "TIFF"
	case .Avif: return "AVIF"
	case .Heif: return "HEIF"
	case .Svg: return "SVG"
	case .Unknown: return "image"
	}
	return "image"
}

// The Preview tab for the kinds of this file; false: the caller shows what it shows for the others (JSON, text).
net_preview :: proc(app: ^App, d: ^Net_Detail, e: ^Net_Entry) -> bool {
	kind := preview_kind_of(e)
	if kind == .None { return false }
	if len(e.body) == 0 {
		why, hint := "No body to preview", "A body appears here once the request is done."
		switch {
		case e.ms < 0: why, hint = "The request is still going", "Its body shows when it is complete."
		case e.failed: why, hint = "The request failed", e.error
		case e.body_total > 0: why, hint = "The body was not kept", "It was over the limit of one body, or was freed to make room (browser.devtools.network.max_body_kb, max_body_mb)."
		}
		dt_empty("###dt_pv_nobody", kind == .Font ? .File_Font : (kind == .Media ? .File_Media : .File_Image), why, hint)
		return true
	}
	preview_ensure(app, d, e, kind)
	switch kind {
	case .Image: preview_image(app, d, e, false)
	case .Font: preview_font(app, d, e)
	case .Html: preview_html(app, d, e)
	case .Media: net_media_preview(app, d, e)
	case .None:
	}
	return true
}

////////////////////////////////
// An image

@(private = "file")
Img_Draw :: struct { tex: render.Texture, ok: bool, nw, nh: int, fit: bool, thumb: bool, err: string }

@(private = "file")
checkerboard :: proc(dc: ^draw.Context, r: draw.Rect) {
	sq := dt_px(8)
	a, b := draw.Color{0.80, 0.80, 0.80, 1}, draw.Color{0.64, 0.64, 0.64, 1}
	if dtc.dark { a, b = draw.Color{0.30, 0.30, 0.31, 1}, draw.Color{0.22, 0.22, 0.23, 1} }
	draw.rect(dc, r, a)
	draw.push_clip(dc, r)
	y := r.min.y
	row := 0
	for y < r.max.y {
		x := r.min.x + (row % 2 == 0 ? sq : 0)
		for x < r.max.x { draw.rect(dc, {{x, y}, {x + sq, y + sq}}, b); x += sq * 2 }
		y += sq
		row += 1
	}
	draw.pop_clip(dc)
}

@(private = "file")
img_paint :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Img_Draw)(user)
	r := b.rect
	draw.rect(dc, r, dtc.bg)
	if !d.ok { return }
	avail := draw.Vec2{r.max.x - r.min.x - dt_px(16), r.max.y - r.min.y - dt_px(16)}
	w, h := f32(d.nw) * dtm.sc, f32(d.nh) * dtm.sc   // a pixel of the image is a CSS pixel: as many device pixels as the interface's scale
	if d.fit || d.thumb {
		s := min(avail.x / max(w, 1), avail.y / max(h, 1), 1)   // larger than the pane: shrunk to it; smaller: as it is
		w, h = w * s, h * s
	}
	c := draw.rect_center(r)
	dst := draw.Rect{{math.round(c.x - w * 0.5), math.round(c.y - h * 0.5)}, {math.round(c.x + w * 0.5), math.round(c.y + h * 0.5)}}
	if !d.fit && !d.thumb { dst = draw.Rect{{r.min.x + dt_px(8), r.min.y + dt_px(8)}, {r.min.x + dt_px(8) + w, r.min.y + dt_px(8) + h}} }
	checkerboard(dc, dst)
	draw.push_clip(dc, r)
	draw.image(dc, d.tex, dst)
	draw.pop_clip(dc)
	draw.rect(dc, dst, with_alpha(dtc.text, 0.25), 0, dtm.line)
}

@(private = "file")
Info_Draw :: struct { text: string }

preview_image :: proc(app: ^App, d: ^Net_Detail, e: ^Net_Entry, thumb: bool) {
	pv := &d.pv
	if pv.err != "" { dt_empty("###dt_pv_imgerr", .File_Image, "No preview", pv.err); return }
	if !thumb { image_bar(app, pv, e) }
	id := ui.frame_new(Img_Draw)
	id.tex, id.ok, id.nw, id.nh, id.fit, id.thumb = pv.tex, pv.tex_ok, pv.nw, pv.nh, pv.fit, thumb
	ui.next({width = ui.fill(), height = thumb ? ui.px(dt_px(150)) : ui.fill()})
	box := ui.build_box({.Clip}, thumb ? "###dt_pi_thumb" : "###dt_pi_canvas")
	box.custom, box.custom_user = img_paint, id
}

@(private = "file")
image_bar :: proc(app: ^App, pv: ^Preview_State, e: ^Net_Entry) {
	if dt_bar("###dt_pi_bar", dtm.bar - dt_px(4)) {
		dt_gap(5)
		if dt_chip("###dt_pi_fit", "Fit", pv.fit, "Fit the image to the pane").clicked { pv.fit, pv.unfit = true, true }
		if dt_chip("###dt_pi_actual", "Actual size", !pv.fit, "The image at its own size").clicked { pv.fit, pv.unfit = false, true }
		ui.next({width = ui.fill(), height = ui.pct(1)})
		ui.custom("###dt_pi_info", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			dt_text_r(dc, dtm.ui_font, dtm.fs, b.rect.max.x - dt_px(8), (b.rect.min.y + b.rect.max.y) * 0.5, dtc.weak, (^string)(user)^)
		}, new_clone(dt_frame_str(image_info_text(pv, e)), ui.frame_allocator()))
		if dt_btn("###dt_pi_open", .Detach, tooltip = "Open the image in a new tab").clicked { open_in_new_tab(app, strings.clone(e.url, context.temp_allocator), inspected_page(app)) }
		dt_gap(3)
	}
}
@(private = "file")
image_info_text :: proc(pv: ^Preview_State, e: ^Net_Entry) -> string {
	anim := pv.frames > 1 ? fmt.tprintf(", %d frames (the first is shown)", pv.frames) : ""
	return fmt.tprintf("%d \u00d7 %d px, %s, %s%s", pv.nw, pv.nh, pv.format, dt_size_text(i64(len(e.body))), anim)
}

// The Response tab of an image: what it is, a thumbnail on a checkerboard, and the bytes under it.
response_image :: proc(app: ^App, d: ^Net_Detail, e: ^Net_Entry) {
	preview_ensure(app, d, e, .Image)
	pv := &d.pv
	if dt_bar("###dt_ri_bar", dtm.bar - dt_px(4)) {
		dt_gap(6)
		ui.next({width = ui.fill(), height = ui.pct(1)})
		ui.custom("###dt_ri_info", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			dt_text(dc, dtm.ui_font, dtm.fs, b.rect.min.x, (b.rect.min.y + b.rect.max.y) * 0.5, dtc.text, (^string)(user)^, b.rect.max.x - b.rect.min.x - dt_px(8))
		}, new_clone(dt_frame_str(pv.err != "" ? pv.err : image_info_text(pv, e)), ui.frame_allocator()))
		if dt_btn("###dt_ri_copy", .Copy, tooltip = "Copy the address of the image").clicked { clip_set(e.url) }
		dt_gap(3)
	}
	if pv.err == "" { preview_image(app, d, e, true) }
	hex_view(d, e)
}

////////////////////////////////
// A font

@(private = "file")
Font_Draw :: struct { id: font.Font_Id }

@(private = "file")
font_paint :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Font_Draw)(user)
	r := b.rect
	draw.rect(dc, r, dtc.bg)
	draw.push_clip(dc, r)
	defer draw.pop_clip(dc)
	x := r.min.x + dt_px(16)
	y := r.min.y + dt_px(14)
	lines := [?]struct { text: string, px: f32 }{
		{"The quick brown fox jumps over the lazy dog", 12}, {"The quick brown fox jumps over the lazy dog", 18}, {"The quick brown fox jumps over the lazy dog", 28},
		{"ABCDEFGHIJKLMNOPQRSTUVWXYZ", 32}, {"abcdefghijklmnopqrstuvwxyz", 32}, {"0123456789 .,;:!?\u2018\u2019\u201c\u201d()[]{}<>/\\|@#$%&*+-=_~", 28},
		{"\u00c0\u00c9\u00ce\u00d5\u00dc \u00e7\u00f1\u00df \u0394\u03a3\u03a9 \u0416\u0424\u042f \u2192\u2260\u2264 \u20ac\u00a3\u00a5", 28},
	}
	for l in lines {
		size := math.round(l.px * dtm.sc)
		m := font.metrics(&the_app.fonts, d.id, size)
		draw.text(dc, d.id, size, {math.round(x), math.round(y + m.ascent)}, dtc.text, l.text)
		y += m.line_height + dt_px(8)
		if y > r.max.y { break }
	}
}

@(private = "file")
preview_font :: proc(app: ^App, d: ^Net_Detail, e: ^Net_Entry) {
	pv := &d.pv
	if !pv.font_ok { dt_empty("###dt_pv_fonterr", .File_Font, "No preview", pv.err); return }
	if dt_bar("###dt_pf_bar", dtm.bar - dt_px(4)) {
		dt_gap(6)
		ui.next({width = ui.fill(), height = ui.pct(1)})
		ui.custom("###dt_pf_info", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			dt_text(dc, dtm.ui_font, dtm.fs, b.rect.min.x, (b.rect.min.y + b.rect.max.y) * 0.5, dtc.weak, (^string)(user)^, b.rect.max.x - b.rect.min.x - dt_px(8))
		}, new_clone(dt_frame_str(fmt.tprintf("%s, %s", net_name_of(e.url), dt_size_text(i64(len(e.body))))), ui.frame_allocator()))
	}
	fd := ui.frame_new(Font_Draw)
	fd.id = pv.font
	ui.next({width = ui.fill(), height = ui.fill()})
	box := ui.build_box({.Clip}, "###dt_pf_canvas")
	box.custom, box.custom_user = font_paint, fd
}

////////////////////////////////
// An HTML page, as a reader sees it

Rd_Style :: enum u8 { Bold, Italic, Link, Code, Weak }

Rd_Run :: struct { text: string, style: bit_set[Rd_Style; u8] }   // text: a view of the block's own

Rd_Kind :: enum u8 { Text, Pre, Rule, Heading, Item, Quote }

Rd_Block :: struct {
	kind:   Rd_Kind,
	level:  int,            // a heading's, 1..6
	indent: int,            // list and quote depth
	runs:   [dynamic]Rd_Run,
	text:   [dynamic]string,   // what the runs' strings were cut from (owned)
}

Rd_Line :: struct { runs: []Rd_Run, kind: Rd_Kind, level: int, indent: int, h: f32, x: f32 }

Html_Reader :: struct {
	title:  string,         // owned
	blocks: [dynamic]Rd_Block,
	lines:  [dynamic]Rd_Line,
	offs:   [dynamic]f32,
	wrap_w: f32,            // the width the lines were made for (0: not yet)
	nodes:  int,
	raw:    []string,       // the markup's lines (the Source view; views of the body: valid while the entry keeps its body)
}

html_reader_free :: proc(h: ^Html_Reader) {
	for &b in h.blocks { for s in b.text { delete(s) }; delete(b.text); delete(b.runs) }
	delete(h.blocks)
	for l in h.lines { delete(l.runs) }
	delete(h.lines); delete(h.offs); delete(h.title); delete(h.raw)
	h^ = {}
}

@(private = "file")
Rd_Ctx :: struct { h: ^Html_Reader, d: ^dom.Document, cur: ^Rd_Block, style: bit_set[Rd_Style; u8], indent: int, budget: int, pending_gap: bool }

@(private = "file")
rd_flush :: proc(c: ^Rd_Ctx) { c.cur = nil }

@(private = "file")
rd_block :: proc(c: ^Rd_Ctx, kind: Rd_Kind, level := 0) -> ^Rd_Block {
	append(&c.h.blocks, Rd_Block{kind = kind, level = level, indent = c.indent})
	c.cur = &c.h.blocks[len(c.h.blocks) - 1]
	return c.cur
}

@(private = "file")
rd_text :: proc(c: ^Rd_Ctx, s: string, pre: bool) {
	if c.budget <= 0 { return }
	t := s
	if !pre {
		// whitespace collapses: runs of it are one space, and a block does not start with one
		b := strings.builder_make(context.temp_allocator)
		space := c.cur == nil || len(c.cur.runs) == 0
		for r in t {
			if r == ' ' || r == '\n' || r == '\t' || r == '\r' { if !space { strings.write_byte(&b, ' '); space = true } } else { strings.write_rune(&b, r); space = false }
		}
		t = strings.to_string(b)
		if t == "" { return }
	}
	if c.cur == nil { rd_block(c, .Text) }
	own := strings.clone(t)
	append(&c.cur.text, own)
	append(&c.cur.runs, Rd_Run{text = own, style = c.style})
	c.budget -= len(t)
}

@(private = "file")
rd_walk :: proc(c: ^Rd_Ctx, h: base.Handle) {
	n := dom.get(c.d, h)
	if n == nil || c.budget <= 0 { return }
	#partial switch n.kind {
	case .Text:
		pre := c.cur != nil && c.cur.kind == .Pre
		rd_text(c, n.text, pre)
		return
	case .Element:
	case .Document, .Fragment:
		for ch := n.first_child; ch != base.NIL_HANDLE; { cn := dom.get(c.d, ch); if cn == nil { break }; rd_walk(c, ch); ch = cn.next }
		return
	case: return
	}
	name := n.name
	switch name {
	case "script", "style", "template", "noscript", "head", "svg", "canvas": 
		if name == "head" {
			// the title
			for ch := n.first_child; ch != base.NIL_HANDLE; { cn := dom.get(c.d, ch); if cn == nil { break }; if cn.kind == .Element && cn.name == "title" && c.h.title == "" { c.h.title = strings.clone(strings.trim_space(dom.text_content(c.d, ch))) }; ch = cn.next }
		}
		return
	}
	saved_style, saved_indent := c.style, c.indent
	block := false
	switch name {
	case "h1", "h2", "h3", "h4", "h5", "h6":
		rd_flush(c); rd_block(c, .Heading, int(name[1] - '0')); block = true
	case "p", "div", "section", "article", "header", "footer", "main", "nav", "aside", "form", "fieldset", "figure", "figcaption", "table", "tr", "dl", "dt", "dd", "address", "details", "summary", "body", "html":
		rd_flush(c); block = true
		if name == "dd" { c.indent += 1 }
	case "ul", "ol": rd_flush(c); c.indent += 1; block = true
	case "li": rd_flush(c); rd_block(c, .Item); block = true
	case "blockquote": rd_flush(c); c.indent += 1; rd_block(c, .Quote); block = true
	case "pre": rd_flush(c); rd_block(c, .Pre); block = true
	case "hr": rd_flush(c); rd_block(c, .Rule); rd_flush(c); return
	case "br": rd_flush(c); if c.cur == nil { rd_block(c, .Text) }; c.cur = nil; return
	case "td", "th":
		if c.cur != nil && len(c.cur.runs) > 0 { rd_text(c, "   ", true) }
	case "b", "strong": c.style += {.Bold}
	case "i", "em", "cite", "var": c.style += {.Italic}
	case "code", "kbd", "samp", "tt": c.style += {.Code}
	case "a": c.style += {.Link}
	case "img":
		alt, _ := dom.get_attribute(c.d, h, "alt")
		src, _ := dom.get_attribute(c.d, h, "src")
		old := c.style; c.style += {.Weak}
		rd_text(c, alt != "" ? fmt.tprintf("[image: %s]", alt) : fmt.tprintf("[image %s]", net_name_of(src)), true)
		c.style = old
		return
	case "input", "button", "select", "textarea":
		old := c.style; c.style += {.Weak}
		label, _ := dom.get_attribute(c.d, h, "value")
		if label == "" { label, _ = dom.get_attribute(c.d, h, "placeholder") }
		if label == "" { label = strings.trim_space(dom.text_content(c.d, h)) }
		rd_text(c, fmt.tprintf("[ %s ]", label != "" ? label : name), true)
		c.style = old
		return
	}
	for ch := n.first_child; ch != base.NIL_HANDLE; { cn := dom.get(c.d, ch); if cn == nil { break }; rd_walk(c, ch); ch = cn.next }
	if block { rd_flush(c) }
	c.style, c.indent = saved_style, saved_indent
}

html_reader_make :: proc(h: ^Html_Reader, body: []byte) {
	d := dom.document_create()
	defer dom.document_destroy(d)
	res := html.parse_into(d, d.root, body, 20000)
	h.nodes = res.nodes
	c := Rd_Ctx{h = h, d = d, budget = 400_000}
	rd_walk(&c, d.root)
	if h.title == "" { h.title = strings.clone(strings.trim_space(html.title(d))) }
	h.raw = strings.split_lines(string(body))
}

@(private = "file") HEADING_SCALE := [6]f32{1.9, 1.7, 1.5, 1.3, 1.15, 1.05}

// The size and weight of a line's text.
@(private = "file")
rd_font :: proc(kind: Rd_Kind, level: int, st: bit_set[Rd_Style; u8]) -> (id: font.Font_Id, size: f32) {
	size = dtm.fs * 1.1
	id = dtm.ui_font
	if kind == .Heading { size = dtm.fs * HEADING_SCALE[clamp(level, 1, 6) - 1] }
	if .Code in st || kind == .Pre { id, size = dtm.mono, dtm.mono_fs * 1.05 }
	return
}

@(private = "file")
rd_color :: proc(kind: Rd_Kind, st: bit_set[Rd_Style; u8]) -> draw.Color {
	switch {
	case .Link in st: return dtc.accent
	case .Weak in st: return dtc.weak
	case .Code in st: return syn_color(.Name)
	case kind == .Heading: return dtc.text
	case kind == .Quote: return dtc.weak
	}
	return dtc.text
}

// The blocks as lines of the width `w`: words laid left to right, a line when the next word does not fit.
@(private = "file")
rd_wrap :: proc(h: ^Html_Reader, w: f32) {
	for l in h.lines { delete(l.runs) }
	clear(&h.lines); clear(&h.offs)
	y: f32
	for &b in h.blocks {
		indent := dt_px(18) * f32(b.indent) + (b.kind == .Item ? dt_px(14) : 0)
		x0 := dt_px(14) + indent
		avail := max(w - x0 - dt_px(14), dt_px(60))
		gap_before := b.kind == .Heading ? dt_px(8) : 0
		y += gap_before
		if b.kind == .Rule {
			append(&h.lines, Rd_Line{kind = .Rule, h = dt_px(14), x = x0})
			append(&h.offs, y); y += dt_px(14)
			continue
		}
		cur := make([dynamic]Rd_Run, 0, 8)
		line_w: f32
		_, base_size := rd_font(b.kind, b.level, {})
		lh := math.round(base_size * 1.45)
		first := true
		flush :: proc(h: ^Html_Reader, b: ^Rd_Block, cur: ^[dynamic]Rd_Run, x0, lh: f32, y: ^f32, offs: ^[dynamic]f32, bullet: bool) {
			runs := make([]Rd_Run, len(cur))
			copy(runs, cur[:])
			append(&h.lines, Rd_Line{runs = runs, kind = b.kind, level = b.level, indent = bullet ? 1 : 0, h = lh, x = x0})
			append(offs, y^)
			y^ += lh
			clear(cur)
		}
		for r in b.runs {
			id, size := rd_font(b.kind, b.level, r.style)
			if b.kind == .Pre {
				// code keeps its lines: each is a line (long ones are cut by the pane)
				for ln in strings.split_lines(r.text, context.temp_allocator) {
					append(&cur, Rd_Run{text = ln, style = r.style})
					flush(h, &b, &cur, x0, lh, &y, &h.offs, false)
				}
				continue
			}
			rest := r.text
			for len(rest) > 0 {
				sp := strings.index_byte(rest, ' ')
				word := sp < 0 ? rest : rest[:sp + 1]
				rest = sp < 0 ? "" : rest[sp + 1:]
				ww := dt_w(id, size, word)
				if line_w + ww > avail && line_w > 0 {
					flush(h, &b, &cur, x0, lh, &y, &h.offs, first && b.kind == .Item)
					first = false
					line_w = 0
					word = strings.trim_left(word, " ")
					ww = dt_w(id, size, word)
				}
				append(&cur, Rd_Run{text = word, style = r.style})
				line_w += ww
			}
		}
		if len(cur) > 0 || len(b.runs) == 0 { flush(h, &b, &cur, x0, lh, &y, &h.offs, first && b.kind == .Item) }
		delete(cur)
		y += dt_px(5)
		if b.kind == .Heading { y += dt_px(3) }
	}
	append(&h.offs, y)
	h.wrap_w = w
}

@(private = "file")
Rd_Draw :: struct { l: ^Rd_Line }

@(private = "file")
rd_paint :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Rd_Draw)(user)
	l := d.l
	r := b.rect
	cy := r.min.y + l.h * 0.5
	x := r.min.x + l.x
	if l.kind == .Rule { draw.rect(dc, {{x, cy}, {r.max.x - dt_px(14), cy + dtm.line}}, dtc.border); return }
	if l.kind == .Quote { draw.rect(dc, {{r.min.x + l.x - dt_px(8), r.min.y}, {r.min.x + l.x - dt_px(6), r.max.y}}, dtc.border) }
	if l.kind == .Item && l.indent == 1 { draw.rect(dc, {{x - dt_px(11), cy - dt_px(2)}, {x - dt_px(7), cy + dt_px(2)}}, dtc.weak, dt_px(2)) }
	for run in l.runs {
		id, size := rd_font(l.kind, l.level, run.style)
		col := rd_color(l.kind, run.style)
		w := dt_w(id, size, run.text)
		draw.text(dc, id, size, {math.round(x), dt_baseline(id, size, cy)}, col, run.text)
		if .Link in run.style { draw.rect(dc, {{x, dt_baseline(id, size, cy) + dt_px(2)}, {x + w, dt_baseline(id, size, cy) + dt_px(2) + dtm.line}}, with_alpha(col, 0.7)) }
		if .Code in run.style && l.kind != .Pre { draw.rect(dc, {{x - 1, cy - size * 0.6}, {x + w + 1, cy + size * 0.6}}, with_alpha(dtc.weak, 0.12), dt_px(2)) }
		x += w
	}
}

@(private = "file")
Src_Line :: struct { text: string }

@(private = "file")
preview_html :: proc(app: ^App, d: ^Net_Detail, e: ^Net_Entry) {
	pv := &d.pv
	hr := &pv.html
	if dt_bar("###dt_ph_bar", dtm.bar - dt_px(4)) {
		dt_gap(5)
		if dt_chip("###dt_ph_read", "Rendered", !pv.source, "The page as a reader sees it: titles, text, lists, links").clicked { pv.source = false }
		if dt_chip("###dt_ph_src", "Source", pv.source, "The markup").clicked { pv.source = true }
		ui.next({width = ui.fill(), height = ui.pct(1)})
		ui.custom("###dt_ph_info", proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
			dt_text_r(dc, dtm.ui_font, dtm.fs, b.rect.max.x - dt_px(8), (b.rect.min.y + b.rect.max.y) * 0.5, dtc.weak, (^string)(user)^, b.rect.max.x - b.rect.min.x - dt_px(120))
		}, new_clone(dt_frame_str(hr.title != "" ? hr.title : net_name_of(e.url)), ui.frame_allocator()))
		if dt_btn("###dt_ph_open", .Detach, tooltip = "Open the page in a new tab (as the browser renders it)").clicked { open_in_new_tab(app, strings.clone(e.url, context.temp_allocator), inspected_page(app)) }
		dt_gap(3)
	}
	if pv.source {
		n := len(hr.raw)
		if lst, ok := dt_list("###dt_ph_src_list", &pv.list, n, dtm.row, nil, ui.fill(), ui.fill()); ok {
			for k in lst.first ..< lst.last {
				ld := ui.frame_new(Src_Draw)
				ln := hr.raw[k]
				if len(ln) > 2000 { ln = ln[:2000] }
				ld.text, ld.n = dt_frame_str(ln), k + 1
				ui.next({width = ui.fill(), height = ui.px(dtm.row), cursor = .Text})
				rb := ui.build_box({}, fmt.tprintf("###phs%d", k))
				rb.custom, rb.custom_user = src_paint, ld
			}
		}
		return
	}
	// the width the lines are wrapped to: the pane's, as of the last frame
	box := ui.box_from_key(pv.scroll)
	w := box != nil && box.size.x > 0 ? box.size.x - dt_px(10) : dev.rect.max.x - dev.rect.min.x
	if math.abs(hr.wrap_w - w) > 1 || len(hr.offs) == 0 { rd_wrap(hr, w) }
	n := len(hr.lines)
	if n == 0 { dt_empty("###dt_ph_empty", .File_Doc, "Nothing to show", "The page has no text."); return }
	if lst, ok := dt_list("###dt_ph_list", &pv.list, n, dtm.row, hr.offs[:], ui.fill(), ui.fill()); ok {
		pv.scroll = pv.list.key
		for k in lst.first ..< lst.last {
			l := &hr.lines[k]
			rd := ui.frame_new(Rd_Draw)
			rd.l = l
			ui.next({width = ui.fill(), height = ui.px(l.h), cursor = .Arrow})
			rb := ui.build_box({}, fmt.tprintf("###phl%d", k))
			rb.custom, rb.custom_user = rd_paint, rd
		}
	}
}

@(private = "file")
Src_Draw :: struct { text: string, n: int }

@(private = "file")
src_paint :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Src_Draw)(user)
	r := b.rect
	cy := (r.min.y + r.max.y) * 0.5
	gut := dt_px(46)
	draw.rect(dc, {r.min, {r.min.x + gut, r.max.y}}, with_alpha(dtc.bar, 0.9))
	dt_text_r(dc, dtm.mono, dtm.mono_fs * 0.92, r.min.x + gut - dt_px(6), cy, dtc.faint, fmt.tprintf("%d", d.n))
	dt_runs(dc, dtm.mono, dtm.mono_fs, r.min.x + gut + dt_px(8), cy, syn_runs(d.text, .HTML), r.max.x - dt_px(4))
}
