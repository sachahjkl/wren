package page

// toDataURL, toBlob and convertToBlob: the pixels of a canvas as a PNG (straight alpha) or JPEG (quality from the page
// or canvas.encode.jpeg_quality; transparent pixels become black, as browsers do). Encoding is WIC's (package images);
// it runs here, on the calling thread, which is the price of the specification's synchronous toDataURL.

import "wb:base"
import "wb:canvas2d"
import "wb:images"

Canvas_encode :: proc(c: ^Call, canvas: u64, type: string, quality: f64) -> (u64, Api_Error) {
	p := c.page
	var_bmp: ^canvas2d.Bitmap
	blank: canvas2d.Bitmap
	defer if blank.pix != nil { canvas_bitmap_free(p, &blank) }
	tainted := false
	w, h := 0, 0
	if is_object(canvas) {
		o := canvas_obj_of(p, canvas)
		if o == nil || o.kind != .Offscreen { return 0, fail(c, .Invalid_Handle, "not an OffscreenCanvas") }
		b := o.backing
		if b == nil { return buffer_create(p, nil, c.owner), .None }
		w, h = b.width, b.height
		var_bmp, tainted = canvas_backing_bitmap(b), b.tainted
		if b.ctx_obj == nil && w > 0 && h > 0 {
			// no context yet: a transparent image of the canvas's size
			bm, ok := canvas_bitmap(p, w, h)
			if !ok { return 0, fail(c, .Quota, "Not enough memory to encode the canvas.") }
			blank, var_bmp = bm, &blank
		}
	} else {
		node := base.Handle(canvas)
		b := canvas_element_backing(p, node, false)
		if b != nil {
			canvas_sync(b)
			w, h = b.width, b.height
			var_bmp, tainted = canvas_backing_bitmap(b), b.tainted
		} else {
			w, h = canvas_dims(p.doc, node)
		}
		if b == nil || b.ctx_obj == nil {
			if w > 0 && h > 0 {
				bm, ok := canvas_bitmap(p, w, h)
				if !ok { return 0, fail(c, .Quota, "Not enough memory to encode the canvas.") }
				blank, var_bmp = bm, &blank
			}
		}
	}
	if tainted { return 0, fail(c, .Security, "Tainted canvases may not be exported.") }
	if w == 0 || h == 0 || var_bmp == nil || var_bmp.w != w || var_bmp.h != h { return buffer_create(p, nil, c.owner), .None }
	format := images.Encode_Format.Png
	if type == "image/jpeg" { format = .Jpeg }
	q := quality
	if !(q >= 0 && q <= 1) { q = p.settings.canvas.jpeg_quality }
	bytes, ok := images.encode_rgba(var_bmp.pix, w, h, format, f32(q), true)
	if !ok { return 0, fail(c, .Not_Supported, "The image could not be encoded.") }
	defer delete(bytes)
	h2 := buffer_create(p, bytes, c.owner)
	if h2 == 0 { return 0, fail(c, .Quota, "Not enough memory for the encoded image.") }
	return h2, .None
}
