package browser

// The system clipboard with several flavours at once, through the toolkit (platform.clipboard_set): Unicode text,
// HTML (the "HTML Format" with its header of byte offsets and the page's address), images (PNG and a bitmap with alpha,
// and a bitmap over white for programs that ignore alpha).

import "wb:page"
import "toolkit:platform"

// Text, and markup when given: what Copy puts on the clipboard for a selection.
clipboard_set_rich :: proc(app: ^App, text, html, source_url: string) -> bool {
	return platform.clipboard_set(app.win, {text = text, html = html, source_url = source_url})
}

// An image (RGBA8, straight alpha, sRGB, rows of `stride` bytes).
clipboard_set_image :: proc(app: ^App, rgba: []u8, w, h, stride: int) -> bool {
	if w <= 0 || h <= 0 || len(rgba) < stride * (h - 1) + w * 4 { return false }
	px := rgba
	if stride != w * 4 {
		px = make([]u8, w * h * 4, context.temp_allocator)
		for y in 0 ..< h { copy(px[y * w * 4:][:w * 4], rgba[y * stride:][:w * 4]) }
	}
	return platform.clipboard_set_image(app.win, {px[:w * h * 4], {w, h}})
}

// navigator.clipboard.writeText / readText (page/js_clipboard.odin decides who may; this is the clipboard they reach).
clipboard_js_init :: proc(app: ^App) {
	page.clipboard_embedder = {
		read = proc() -> (string, bool) { return clip_get(), the_app != nil },
		write = proc(text: string) -> bool { return the_app != nil && clipboard_set_rich(the_app, text, "", "") },
	}
}

clipboard_js_destroy :: proc() { page.clipboard_embedder = {} }
