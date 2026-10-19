package browser

// The system clipboard with several flavours at once: Unicode text (CRLF line ends), HTML (the CF_HTML "HTML Format"
// with its header of byte offsets), images (CF_DIB composited over white for programs that ignore alpha, and "PNG"
// with the alpha channel, which Office, image editors and browsers prefer).

import "base:runtime"
import "core:fmt"
import "core:strings"
import win "core:sys/windows"
import stbi "vendor:stb/image"

Clip_Item :: struct {
	format: u32,
	data:   []byte,
}

// Replaces the clipboard's contents by `items` (one owner, every flavour). False when the clipboard could not be had.
clipboard_put :: proc(hwnd: win.HWND, items: []Clip_Item) -> bool {
	if !win.OpenClipboard(hwnd) { return false }
	defer win.CloseClipboard()
	win.EmptyClipboard()
	all := true
	for it in items {
		mem := win.GlobalAlloc(win.GMEM_MOVEABLE, uint(max(len(it.data), 1)))
		if mem == nil { all = false; continue }
		dst := cast([^]byte)win.GlobalLock(win.HGLOBAL(mem))
		if dst == nil { win.GlobalFree(win.HGLOBAL(mem)); all = false; continue }
		copy(dst[:len(it.data)], it.data)
		win.GlobalUnlock(win.HGLOBAL(mem))
		// on success the system owns the memory; on failure it is still ours
		if win.SetClipboardData(win.UINT(it.format), win.HANDLE(mem)) == nil { win.GlobalFree(win.HGLOBAL(mem)); all = false }
	}
	return all
}

// UTF-16, NUL-terminated, CRLF line ends: what CF_UNICODETEXT holds.
@(private = "file")
unicode_text :: proc(text: string) -> []byte {
	crlf, _ := strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	crlf, _ = strings.replace_all(crlf, "\n", "\r\n", context.temp_allocator)
	wide := win.utf8_to_utf16(crlf, context.temp_allocator)
	out := make([]byte, (len(wide) + 1) * 2, context.temp_allocator)
	for w, i in wide { out[2 * i], out[2 * i + 1] = byte(w), byte(w >> 8) }
	return out
}

// The "HTML Format" payload around a fragment of markup (UTF-8, offsets in bytes).
cf_html :: proc(fragment, source_url: string) -> string {
	HEAD :: "Version:0.9\r\nStartHTML:%010d\r\nEndHTML:%010d\r\nStartFragment:%010d\r\nEndFragment:%010d\r\n"
	src := source_url != "" ? fmt.tprintf("SourceURL:%s\r\n", source_url) : ""
	pre := "<html><body>\r\n<!--StartFragment-->"
	post := "<!--EndFragment-->\r\n</body></html>"
	head_len := len(fmt.tprintf(HEAD, 0, 0, 0, 0)) + len(src)
	start_html := head_len
	start_frag := start_html + len(pre)
	end_frag := start_frag + len(fragment)
	end_html := end_frag + len(post)
	return strings.concatenate({fmt.tprintf(HEAD, start_html, end_html, start_frag, end_frag), src, pre, fragment, post}, context.temp_allocator)
}

// Text, and markup when given: what Copy puts on the clipboard for a selection.
clipboard_set_rich :: proc(app: ^App, text, html, source_url: string) -> bool {
	items := make([dynamic]Clip_Item, context.temp_allocator)
	append(&items, Clip_Item{win.CF_UNICODETEXT, unicode_text(text)})
	if html != "" {
		if f := win.RegisterClipboardFormatW(win.L("HTML Format")); f != 0 {
			payload := cf_html(html, source_url)
			b := make([]byte, len(payload) + 1, context.temp_allocator)
			copy(b, payload)
			append(&items, Clip_Item{u32(f), b})
		}
	}
	return clipboard_put(app.win.hwnd, items[:])
}

// An image (RGBA8, straight alpha, sRGB, rows of `stride` bytes): CF_DIB over white, and PNG with alpha.
clipboard_set_image :: proc(app: ^App, rgba: []u8, w, h, stride: int) -> bool {
	if w <= 0 || h <= 0 || len(rgba) < stride * (h - 1) + w * 4 { return false }
	items := make([dynamic]Clip_Item, context.temp_allocator)
	// BITMAPINFOHEADER + 32-bit BGRX rows, bottom-up
	HEADER :: 40
	dib := make([]byte, HEADER + w * h * 4, context.temp_allocator)
	put32 :: proc(b: []byte, at: int, v: u32) { b[at], b[at + 1], b[at + 2], b[at + 3] = byte(v), byte(v >> 8), byte(v >> 16), byte(v >> 24) }
	put32(dib, 0, HEADER)
	put32(dib, 4, u32(i32(w)))
	put32(dib, 8, u32(i32(h)))
	dib[12], dib[13] = 1, 0     // planes
	dib[14], dib[15] = 32, 0    // bits per pixel
	put32(dib, 16, 0)           // BI_RGB
	put32(dib, 20, u32(w * h * 4))
	for y in 0 ..< h {
		src := rgba[y * stride:]
		row := dib[HEADER + (h - 1 - y) * w * 4:]
		for x in 0 ..< w {
			r, g, b, a := u32(src[4 * x]), u32(src[4 * x + 1]), u32(src[4 * x + 2]), u32(src[4 * x + 3])
			over :: proc(c, a: u32) -> byte { return byte((c * a + 255 * (255 - a) + 127) / 255) }
			row[4 * x], row[4 * x + 1], row[4 * x + 2], row[4 * x + 3] = over(b, a), over(g, a), over(r, a), 255
		}
	}
	append(&items, Clip_Item{win.CF_DIB, dib})
	if png := encode_png(rgba, w, h, stride); len(png) > 0 {
		if f := win.RegisterClipboardFormatW(win.L("PNG")); f != 0 { append(&items, Clip_Item{u32(f), png}) }
	}
	return clipboard_put(app.win.hwnd, items[:])
}

// PNG of RGBA8 pixels (temp allocator), nil on failure.
encode_png :: proc(rgba: []u8, w, h, stride: int) -> []byte {
	out := make([dynamic]byte, 0, w * h, context.temp_allocator)
	sink :: proc "c" (ctx: rawptr, data: rawptr, size: i32) {
		context = the_context
		buf := (^[dynamic]byte)(ctx)
		append(buf, ..([^]byte)(data)[:size])
	}
	the_context = context
	if stbi.write_png_to_func(sink, &out, i32(w), i32(h), 4, raw_data(rgba), i32(stride)) == 0 { return nil }
	return out[:]
}

@(private = "file")
the_context: runtime.Context
