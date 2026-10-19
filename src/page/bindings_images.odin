package page

// Module "images": HTMLImageElement (<img> or <input type=image>; anything else is not a live HTMLImageElement) and
// Image_decode. naturalWidth / naturalHeight are density-corrected CSS pixels (0 until the image is available), complete
// says whether it is, currentSrc is the absolute URL of the chosen source ("" when none).
//
// decode() returns a promise fulfilled (value 0) once the image is decoded at its natural size, rejected with
// Encoding when it is broken or the element's source changes first.
//
// Image_decode(buffer) decodes the image file in an ArrayBuffer (PNG, JPEG, GIF, BMP, ICO, TIFF, WebP / AVIF where the
// codecs exist) on the decoding threads. The promise is fulfilled with a new buffer of RGBA8 pixels (straight alpha,
// sRGB, rows top-down, width * 4 bytes each) as value and "<width>x<height>" as text; the first frame of an animation.
// Rejected with Encoding (not an image, corrupt, over the limits) or Quota (the pixels do not fit in the page's memory).

HTMLImageElement_naturalWidth :: proc(c: ^Call, image: Api_HTMLImageElement) -> i32 {
	w, _, ok := image_intrinsic(c.page, image.data.node)
	return ok ? i32(w) : 0
}

HTMLImageElement_naturalHeight :: proc(c: ^Call, image: Api_HTMLImageElement) -> i32 {
	_, h, ok := image_intrinsic(c.page, image.data.node)
	return ok ? i32(h) : 0
}

HTMLImageElement_complete :: proc(c: ^Call, image: Api_HTMLImageElement) -> bool { return element_complete(image.data) }
HTMLImageElement_currentSrc :: proc(c: ^Call, image: Api_HTMLImageElement) -> string { return image.data.current_url }
HTMLImageElement_decode :: proc(c: ^Call, image: Api_HTMLImageElement) -> u64 { return element_decode(c.page, image.data, c.owner) }
Image_decode :: proc(c: ^Call, data: Api_Buffer) -> u64 { return guest_decode_start(c.page, data.data.bytes[:], c.owner) }