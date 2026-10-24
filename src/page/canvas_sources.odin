package page

// Where a canvas gets pixels from besides its own drawing: images (<img>), other canvases, ImageBitmaps; patterns,
// createImageBitmap and OffscreenCanvas (api/canvas.widl).
//
// An <img>'s decoded pixels are straight-alpha; a canvas works on premultiplied ones. The conversion is kept per image
// (canvas.image_cache_bytes, least recently used first): drawing the same sprite sheet every frame converts it once.
// What the page may not read (a cross-origin image shown without CORS) taints the canvas that draws it, and then
// getImageData, toDataURL and toBlob raise a SecurityError.

import "core:fmt"
import "wb:base"
import "wb:canvas2d"
import "wb:dom"

Source_Status :: enum u8 {
	Ok,
	Pending,   // not there yet (the image is loading, a canvas has no context): nothing is drawn
	Broken,    // the image failed
	Empty,     // a canvas or bitmap with no pixels
	Bad,       // not an image source
}

Canvas_Source :: struct {
	status:  Source_Status,
	bmp:     ^canvas2d.Bitmap,   // premultiplied; borrowed (a canvas, a bitmap, the page's image cache). nil for a canvas on the GPU: canvas_source_bitmap reads it back
	tainted: bool,
	nat:     [2]f64,             // the size drawImage uses by default: CSS pixels for an <img>, pixels otherwise
	size:    [2]int,             // the size of its pixels
	gpu:     ^canvas2d.Gpu,      // a canvas drawn on the GPU
	backing: ^Canvas_Backing,    // the canvas it is
	video:   base.Handle,        // a <video> element (its current picture): not NIL_HANDLE
}

// The pixels of a source on the CPU: a canvas that is drawn on the GPU is read back (nil when that cannot be done).
canvas_source_bitmap :: proc(s: ^Canvas_Source) -> ^canvas2d.Bitmap {
	if s.bmp != nil { return s.bmp }
	if s.backing != nil { s.bmp = canvas_backing_bitmap(s.backing) }
	return s.bmp
}

// How a drawImage names a source for a context drawing on the GPU.
canvas_gpu_source :: proc(p: ^Page, s: ^Canvas_Source) -> canvas2d.Gpu_Source {
	switch {
	case s.video != base.NIL_HANDLE: return canvas2d.Gpu_Source{kind = .Video, id = u64(s.video), owner = p, w = s.size.x, h = s.size.y}
	case s.gpu != nil: return canvas2d.Gpu_Source{kind = .Canvas, canvas = s.gpu, w = s.size.x, h = s.size.y}
	}
	return canvas2d.Gpu_Source{kind = .Bitmap, bmp = s.bmp, w = s.size.x, h = s.size.y}
}

// Resolves a `source` handle of the API: an element (img, canvas, video) or an object (ImageBitmap, OffscreenCanvas).
canvas_source :: proc(p: ^Page, h: u64) -> Canvas_Source {
	s: Canvas_Source
	if is_object(h) {
		o := canvas_obj_of(p, h)
		if o == nil { s.status = .Bad; return s }
		#partial switch o.kind {
		case .Bitmap:
			if o.bmp.w == 0 || o.bmp.h == 0 { s.status = .Empty; return s }
			s.bmp, s.tainted = &o.bmp, o.tainted
			s.size = {o.bmp.w, o.bmp.h}
		case .Offscreen:
			b := o.backing
			if b == nil || b.width == 0 || b.height == 0 { s.status = .Empty; return s }
			if b.bmp.w == 0 { s.status = .Pending; return s }
			canvas_source_of_backing(&s, b)
		case: s.status = .Bad; return s
		}
		s.nat = {f64(s.size.x), f64(s.size.y)}
		return s
	}
	if p.doc == nil { s.status = .Bad; return s }
	n := dom.get(p.doc, base.Handle(h))
	if n == nil || n.kind != .Element { s.status = .Bad; return s }
	switch n.name {
	case "canvas":
		b := canvas_element_backing(p, base.Handle(h), false)
		if b == nil {
			w, hh := canvas_dims(p.doc, base.Handle(h))
			s.status = w == 0 || hh == 0 ? .Empty : .Pending   // a canvas nobody drew on is transparent
			return s
		}
		canvas_sync(b)
		if b.width == 0 || b.height == 0 { s.status = .Empty; return s }
		if b.bmp.w == 0 { s.status = .Pending; return s }
		canvas_source_of_backing(&s, b)
		s.nat = {f64(b.bmp.w), f64(b.bmp.h)}
	case "img":
		px := canvas_image_pixels(p, base.Handle(h))
		switch px.status {
		case .Pending: s.status = .Pending; return s
		case .Broken: s.status = .Broken; return s
		case .Ready:
		}
		im := canvas_cached_image(p, px)
		if im == nil { s.status = .Pending; return s }
		s.bmp, s.tainted = &im.bmp, px.opaque
		s.size = {im.bmp.w, im.bmp.h}
		s.nat = {f64(px.natural[0]), f64(px.natural[1])}
		if s.nat[0] <= 0 || s.nat[1] <= 0 { s.nat = {f64(im.bmp.w), f64(im.bmp.h)} }
	case "video":
		v, vok := media_view(p, base.Handle(h), false)
		if !vok || !v.ready || v.width <= 0 || v.height <= 0 { s.status = .Pending; return s }
		s.video = base.Handle(h)
		s.size = {v.width, v.height}
		s.nat = {f64(v.width), f64(v.height)}
		// (a page's video is the page's own picture: it never taints)
	case "image":
		s.status = .Pending
	case:
		s.status = .Bad
	}
	return s
}

canvas_source_done :: proc(s: ^Canvas_Source) {}

@(private)
canvas_source_of_backing :: proc(s: ^Canvas_Source, b: ^Canvas_Backing) {
	s.tainted = b.tainted
	s.size = {b.bmp.w, b.bmp.h}
	s.backing = b
	if b.ctx_obj != nil && b.ctx_obj.ctx.gpu != nil { s.gpu = b.ctx_obj.ctx.gpu } else { s.bmp = &b.bmp }
}

// The premultiplied copy of a decoded image, converted on first use and again when the decode changed.
@(private)
canvas_cached_image :: proc(p: ^Page, px: Canvas_Pixels) -> ^Cached_Image {
	cp := canvas_page(p)
	cp.tick += 1
	if im, ok := cp.images[px.id]; ok {
		if im.generation == px.generation && im.bmp.w == px.width && im.bmp.h == px.height {
			im.used = cp.tick
			return im
		}
		cp.image_bytes -= len(im.bmp.pix)
		canvas_bitmap_free(p, &im.bmp)
		free(im)
		delete_key(&cp.images, px.id)
	}
	bmp, ok := canvas_bitmap(p, px.width, px.height)
	if !ok { return nil }
	for y in 0 ..< px.height {
		src := px.pixels[y * px.stride:][:px.width * 4]
		dst := bmp.pix[y * px.width * 4:][:px.width * 4]
		for i := 0; i < len(src); i += 4 {
			a := u32(src[i + 3])
			switch a {
			case 255: dst[i], dst[i + 1], dst[i + 2], dst[i + 3] = src[i], src[i + 1], src[i + 2], 255
			case 0: dst[i], dst[i + 1], dst[i + 2], dst[i + 3] = 0, 0, 0, 0
			case:
				dst[i] = u8((u32(src[i]) * a + 127) / 255)
				dst[i + 1] = u8((u32(src[i + 1]) * a + 127) / 255)
				dst[i + 2] = u8((u32(src[i + 2]) * a + 127) / 255)
				dst[i + 3] = u8(a)
			}
		}
	}
	im := new(Cached_Image)
	im.generation, im.bmp, im.used = px.generation, bmp, cp.tick
	cp.images[px.id] = im
	cp.image_bytes += len(bmp.pix)
	return im
}

// Drops cached image copies, least recently used first, until at most `limit` bytes are left. The one used by the call
// in progress stays.
@(private)
canvas_image_cache_trim :: proc(p: ^Page, limit: int) {
	cp, ok := canvas_pages[p]
	if !ok { return }
	for cp.image_bytes > limit {
		oldest: u64 = 0
		best := max(u64)
		for id, im in cp.images {
			if im.used != cp.tick && im.used < best { oldest, best = id, im.used }
		}
		if best == max(u64) { return }
		im := cp.images[oldest]
		cp.image_bytes -= len(im.bmp.pix)
		canvas_bitmap_free(p, &im.bmp)
		free(im)
		delete_key(&cp.images, oldest)
	}
}

////////////////////////////////
// Patterns, bitmaps, OffscreenCanvas

Canvas_createPattern :: proc(c: ^Call, ctx: Api_CanvasRenderingContext2D, source: u64, repetition: string) -> (u64, Api_Error) {
	rx, ry := true, true
	switch repetition {
	case "", "repeat":
	case "repeat-x": ry = false
	case "repeat-y": rx = false
	case "no-repeat": rx, ry = false, false
	case: return 0, fail(c, .Syntax, fmt.tprintf("The provided type ('%s') is not recognized.", repetition))
	}
	src := canvas_source(c.page, source)
	switch src.status {
	case .Ok:
	case .Pending: return 0, .Not_Found
	case .Broken, .Empty: return 0, fail(c, .Invalid_State, "The image argument is a canvas element with a width or height of 0, or a broken image.")
	case .Bad: return 0, fail(c, .Type, "The provided value is not of a type that can be used as a pattern.")
	}
	sbmp := canvas_source_bitmap(&src)
	if sbmp == nil && src.video != base.NIL_HANDLE { return 0, fail(c, .Not_Supported, "A video cannot be used as a pattern.") }
	if sbmp == nil { return 0, fail(c, .Quota, "Not enough memory for the pattern.") }
	pat := canvas2d.pattern_create(sbmp, rx, ry, c.page.settings.canvas.max_page_bytes)
	if pat == nil { return 0, fail(c, .Quota, "Not enough memory for the pattern.") }
	o, h := canvas_new_object(c.page, c.owner, .Pattern)
	o.pat = pat
	o.tainted = src.tainted
	return h, .None
}

@(private)
canvas_bitmap_object :: proc(c: ^Call, w, h: int) -> (o: ^Canvas_Obj, handle: u64, ok: bool) {
	bmp, bok := canvas_bitmap(c.page, w, h)
	if !bok { return nil, 0, false }
	o, handle = canvas_new_object(c.page, c.owner, .Bitmap)
	o.bmp = bmp
	return o, handle, true
}

Canvas_createBitmap :: proc(c: ^Call, source: u64, form: i32, sx: f64, sy: f64, sw: f64, sh: f64, flip_y: bool) -> (u64, Api_Error) {
	src := canvas_source(c.page, source)
	switch src.status {
	case .Ok:
	case .Pending: return 0, .Not_Found
	case .Broken, .Empty: return 0, fail(c, .Invalid_State, "The source image cannot be decoded.")
	case .Bad: return 0, fail(c, .Type, "The provided value is not of a type that can be made into a bitmap.")
	}
	sbmp := canvas_source_bitmap(&src)
	if sbmp == nil { return 0, fail(c, .Quota, "Not enough memory for the bitmap.") }
	x, y, w, h := 0, 0, sbmp.w, sbmp.h
	if form == 4 {
		if sw == 0 || sh == 0 || !canvas2d.is_finite(sx + sy + sw + sh) { return 0, fail(c, .Index_Size, "The crop rectangle has a width or height of zero.") }
		fx, fy := f64(sbmp.w) / src.nat.x, f64(sbmp.h) / src.nat.y
		rx, ry, rw, rh := sx * fx, sy * fy, sw * fx, sh * fy
		if rw < 0 { rx += rw; rw = -rw }
		if rh < 0 { ry += rh; rh = -rh }
		x, y, w, h = int(rx), int(ry), max(int(rw), 1), max(int(rh), 1)
	}
	o, handle, ok := canvas_bitmap_object(c, w, h)
	if !ok { return 0, fail(c, .Quota, "Not enough memory for the bitmap.") }
	o.tainted = src.tainted
	for dy in 0 ..< h {
		sy_ := y + dy
		row := flip_y ? h - 1 - dy : dy
		if sy_ < 0 || sy_ >= sbmp.h { continue }
		for dx in 0 ..< w {
			sx_ := x + dx
			if sx_ < 0 || sx_ >= sbmp.w { continue }
			copy(o.bmp.pix[(row * w + dx) * 4:][:4], sbmp.pix[(sy_ * sbmp.w + sx_) * 4:][:4])
		}
	}
	return handle, .None
}

Canvas_bitmapFromPixels :: proc(c: ^Call, data: []u8, width: i32, height: i32, flip_y: bool) -> (u64, Api_Error) {
	if width <= 0 || height <= 0 || int(width) * int(height) * 4 > len(data) { return 0, fail(c, .Index_Size, "The source width or height is 0.") }
	o, handle, ok := canvas_bitmap_object(c, int(width), int(height))
	if !ok { return 0, fail(c, .Quota, "Not enough memory for the bitmap.") }
	w, h := int(width), int(height)
	canvas2d.bitmap_write_straight(&o.bmp, data, w, 0, 0, w, h, 0, 0)
	if flip_y {
		row := make([]u8, w * 4, context.temp_allocator)
		for y in 0 ..< h / 2 {
			a, b := o.bmp.pix[y * w * 4:][:w * 4], o.bmp.pix[(h - 1 - y) * w * 4:][:w * 4]
			copy(row, a)
			copy(a, b)
			copy(b, row)
		}
	}
	return handle, .None
}

OffscreenCanvas_create :: proc(c: ^Call, width: u64, height: u64) -> (u64, Api_Error) {
	if !c.page.settings.canvas.enabled || width > 0x7fffffff || height > 0x7fffffff { return 0, fail(c, .Not_Supported, "OffscreenCanvas is not available.") }
	o, h := canvas_new_object(c.page, c.owner, .Offscreen)
	b := canvas_backing_new(c.page, base.NIL_HANDLE, int(width), int(height))
	b.owner, o.backing = o, b
	return h, .None
}

OffscreenCanvas_width :: proc(c: ^Call, canvas: Api_OffscreenCanvas) -> u64 {
	if b := canvas.data.backing; b != nil { return u64(b.width) }
	return 0
}

OffscreenCanvas_height :: proc(c: ^Call, canvas: Api_OffscreenCanvas) -> u64 {
	if b := canvas.data.backing; b != nil { return u64(b.height) }
	return 0
}

@(private)
offscreen_resize :: proc(c: ^Call, canvas: Api_OffscreenCanvas, w, h: u64) -> Api_Error {
	b := canvas.data.backing
	if b == nil { return .None }
	if w > 0x7fffffff || h > 0x7fffffff { return fail(c, .Range, "The size is out of range.") }
	canvas_backing_resize(b, int(w), int(h))
	return .None
}

OffscreenCanvas_set_width :: proc(c: ^Call, canvas: Api_OffscreenCanvas, value: u64) -> Api_Error {
	b := canvas.data.backing
	return offscreen_resize(c, canvas, value, b != nil ? u64(b.height) : 0)
}

OffscreenCanvas_set_height :: proc(c: ^Call, canvas: Api_OffscreenCanvas, value: u64) -> Api_Error {
	b := canvas.data.backing
	return offscreen_resize(c, canvas, b != nil ? u64(b.width) : 0, value)
}

OffscreenCanvas_context2d :: proc(c: ^Call, canvas: Api_OffscreenCanvas, alpha: bool, will_read_frequently: bool) -> (u64, Api_Error) {
	b := canvas.data.backing
	if b == nil || !c.page.settings.canvas.enabled { return 0, .None }
	return canvas_make_context(c, b, alpha, will_read_frequently), .None
}

OffscreenCanvas_transferToImageBitmap :: proc(c: ^Call, canvas: Api_OffscreenCanvas) -> (u64, Api_Error) {
	b := canvas.data.backing
	if b == nil || b.ctx_obj == nil { return 0, fail(c, .Invalid_State, "The OffscreenCanvas has no context.") }
	w, h := b.bmp.w, b.bmp.h
	o, handle, ok := canvas_bitmap_object(c, w, h)
	if !ok { return 0, fail(c, .Quota, "Not enough memory for the bitmap.") }
	cur := canvas_backing_bitmap(b)
	if cur == nil || len(cur.pix) != len(o.bmp.pix) { return 0, fail(c, .Quota, "Not enough memory for the bitmap.") }
	copy(o.bmp.pix, cur.pix)
	o.tainted = b.tainted
	// the canvas starts again: transparent (black when opaque)
	if k := &b.ctx_obj.ctx; k.gpu != nil {
		canvas2d.gpu_reset(k.gpu)
	} else {
		canvas2d.bitmap_reset_contents(&b.bmp)
	}
	return handle, .None
}

// Canvas_encode: see canvas_encode.odin.
