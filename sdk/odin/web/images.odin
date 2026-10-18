package web

// Images (import module "images"): HTMLImageElement state and decoding image files into pixels.
//
// Image events: listen for "load" and "error" on the element (EventTarget_addEventListener); they do not bubble.
// HTMLImageElement_decode resolves once the image is decoded at its natural size (EncodingError otherwise).
// Image_decode turns an ArrayBuffer holding an image file into a buffer of RGBA8 pixels (straight alpha, sRGB, rows
// top-down, width * 4 bytes per row); the fulfilled promise's value is that buffer, its text "<width>x<height>"
// (image_decode_size reads it). Also available in workers.

ERR_ENCODING :: Error(-21)   // EncodingError

foreign import images_mod "images"

@(default_calling_convention = "contextless")
foreign images_mod {
	HTMLImageElement_naturalWidth :: proc(img: Handle) -> i32 ---
	HTMLImageElement_naturalHeight :: proc(img: Handle) -> i32 ---
	HTMLImageElement_complete :: proc(img: Handle) -> i32 ---
	@(link_name = "HTMLImageElement_currentSrc") raw_imageCurrentSrc :: proc(img: Handle, buf: [^]u8, cap: i32) -> i32 ---
	HTMLImageElement_decode :: proc(img: Handle) -> Handle ---
	Image_decode :: proc(buffer: Handle) -> Handle ---
}

image_complete :: proc "contextless" (img: Handle) -> bool { return HTMLImageElement_complete(img) == 1 }

// currentSrc into `buf`; `needed` is the full length (retry with a larger buffer when it is more than len(buf)).
image_current_src :: proc "contextless" (img: Handle, buf: []u8) -> (s: string, needed: int) {
	n := raw_imageCurrentSrc(img, raw_data(buf), i32(len(buf)))
	if n < 0 { return "", 0 }
	return string(buf[:min(int(n), len(buf))]), int(n)
}

// Width and height of an Image_decode result, from its fulfilled promise.
image_decode_size :: proc "contextless" (promise: Handle) -> (w, h: int, ok: bool) {
	buf: [32]u8
	s := promise_text(promise, buf[:])
	x := -1
	for i in 0 ..< len(s) { if s[i] == 'x' { x = i; break } }
	if x <= 0 { return 0, 0, false }
	num :: proc "contextless" (t: string) -> (int, bool) {
		if len(t) == 0 { return 0, false }
		v := 0
		for c in transmute([]u8)t {
			if c < '0' || c > '9' { return 0, false }
			v = v * 10 + int(c - '0')
		}
		return v, true
	}
	wv, wok := num(s[:x])
	hv, hok := num(s[x + 1:])
	return wv, hv, wok && hok
}
