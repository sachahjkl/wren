package page

// Images for guests (import module "images"). Elements are <img> or <input type=image> handles; anything else gives
// Invalid_Handle. Values follow HTMLImageElement: naturalWidth / naturalHeight are density-corrected CSS pixels (0 until
// the image is available), complete is 1 or 0, currentSrc the absolute URL of the chosen source ("" when none).
//
// decode() returns a promise fulfilled (value 0) once the image is decoded at its natural size, rejected with
// WEB_ERR_ENCODING when it is broken or the element's source changes first.
//
// Image_decode(buffer) decodes the image file in an ArrayBuffer (PNG, JPEG, GIF, BMP, ICO, TIFF, WebP / AVIF where the
// codecs exist) on the decoding threads. The promise is fulfilled with a new buffer of RGBA8 pixels (straight alpha,
// sRGB, rows top-down, width * 4 bytes each) as value and "<width>x<height>" as text; the first frame of an animation.
// Rejected with WEB_ERR_ENCODING (not an image, corrupt, over the limits), WEB_ERR_QUOTA (the pixels do not fit in the
// page's memory). Usable from workers (the element functions there fail: no document).

import "wb:wasm"

@(private)
image_el :: proc(env: wasm.Exec_Env, node: u64) -> ^Img_Element {
	d := doc_of(env)
	if d == nil { return nil }
	return image_element(page_of(env), H(node))
}

n_HTMLImageElement_naturalWidth :: proc "c" (env: wasm.Exec_Env, node: u64) -> i32 {
	context = ctx()
	el := image_el(env, node)
	if el == nil { return i32(NO_DOCUMENT) }
	w, _, ok := image_intrinsic(page_of(env), el.node)
	return ok ? i32(w) : 0
}

n_HTMLImageElement_naturalHeight :: proc "c" (env: wasm.Exec_Env, node: u64) -> i32 {
	context = ctx()
	el := image_el(env, node)
	if el == nil { return i32(NO_DOCUMENT) }
	_, h, ok := image_intrinsic(page_of(env), el.node)
	return ok ? i32(h) : 0
}

n_HTMLImageElement_complete :: proc "c" (env: wasm.Exec_Env, node: u64) -> i32 {
	context = ctx()
	el := image_el(env, node)
	if el == nil { return i32(NO_DOCUMENT) }
	return element_complete(el) ? 1 : 0
}

n_HTMLImageElement_currentSrc :: proc "c" (env: wasm.Exec_Env, node: u64, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	el := image_el(env, node)
	if el == nil { return i32(NO_DOCUMENT) }
	return out_string(el.current_url, buf, cap)
}

n_HTMLImageElement_decode :: proc "c" (env: wasm.Exec_Env, node: u64) -> u64 {
	context = ctx()
	el := image_el(env, node)
	if el == nil { return 0 }
	return element_decode(page_of(env), el, inst_of(env).index)
}

n_Image_decode :: proc "c" (env: wasm.Exec_Env, buffer: u64) -> u64 {
	context = ctx()
	p := page_of(env)
	b := buffer_get(p, buffer)
	if b == nil { return 0 }
	return guest_decode_start(p, b.bytes[:], inst_of(env).index)
}

images_symbols := [?]wasm.Native_Symbol{
	{"HTMLImageElement_naturalWidth", rawptr(n_HTMLImageElement_naturalWidth), "(I)i", nil},
	{"HTMLImageElement_naturalHeight", rawptr(n_HTMLImageElement_naturalHeight), "(I)i", nil},
	{"HTMLImageElement_complete", rawptr(n_HTMLImageElement_complete), "(I)i", nil},
	{"HTMLImageElement_currentSrc", rawptr(n_HTMLImageElement_currentSrc), "(I*~)i", nil},
	{"HTMLImageElement_decode", rawptr(n_HTMLImageElement_decode), "(I)I", nil},
	{"Image_decode", rawptr(n_Image_decode), "(I)I", nil},
}
