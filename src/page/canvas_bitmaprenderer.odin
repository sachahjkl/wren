package page

// ImageBitmapRenderingContext (the "bitmaprenderer" context of a <canvas> or an OffscreenCanvas; api/canvas.widl).
// It displays an ImageBitmap directly, with no drawing surface of its own: transferFromImageBitmap(bitmap) takes the
// bitmap's pixels into the canvas's backing (and detaches the bitmap, as the specification says); clearing it
// (transferFromImageBitmap(null)) blanks the backing. The context keeps a reference to its canvas so .canvas works.
//
// Native-first: the whole thing is a pixel copy into the existing canvas backing (the shell already presents that
// backing as a texture), no JavaScript involved.

import "wb:base"
import "wb:canvas2d"

// getContext("bitmaprenderer") on an element <canvas>. One context per canvas (shared slot with the 2D context):
// asking for bitmaprenderer after a 2D context, or vice versa, returns null (the specification forbids mixing).
HTMLCanvasElement_bitmapRenderer :: proc(c: ^Call, canvas: Api_HTMLCanvasElement, alpha: bool) -> (u64, Api_Error) {
	if !c.page.settings.canvas.enabled || c.page.worker != nil { return 0, .None }
	b := canvas_element_backing(c.page, base.Handle(canvas.handle), true)
	if b == nil { return 0, .None }
	canvas_sync(b)
	return canvas_make_bitmap_renderer(c, b, alpha), .None
}

OffscreenCanvas_bitmapRenderer :: proc(c: ^Call, canvas: Api_OffscreenCanvas, alpha: bool) -> (u64, Api_Error) {
	b := canvas.data.backing
	if b == nil || !c.page.settings.canvas.enabled { return 0, .None }
	return canvas_make_bitmap_renderer(c, b, alpha), .None
}

// Makes (or returns) the single presentation context of a backing as an ImageBitmapRenderingContext. 0 when a 2D
// context already holds the backing (the kinds cannot be mixed on one canvas).
@(private)
canvas_make_bitmap_renderer :: proc(c: ^Call, b: ^Canvas_Backing, alpha: bool) -> u64 {
	if b.ctx_obj != nil {
		return b.ctx_obj.kind == .Bitmap_Renderer ? b.ctx_handle : 0
	}
	p := c.page
	b.opaque = !alpha
	canvas_backing_alloc(b)
	o, h := canvas_new_object(p, c.owner, .Bitmap_Renderer)
	o.backing, o.alpha = b, alpha
	b.ctx_obj, b.ctx_handle = o, h
	// start from a transparent (black when opaque) output per the spec
	canvas2d.bitmap_reset_contents(&b.bmp)
	canvas2d.bitmap_touch_all(&b.bmp)
	return h
}

// context.canvas: the owning <canvas> element (Node handle) or OffscreenCanvas object.
ImageBitmapRenderingContext_canvas :: proc(c: ^Call, ctx: Api_ImageBitmapRenderingContext) -> u64 {
	o := ctx.data
	if o == nil || o.backing == nil { return 0 }
	if o.backing.node != base.NIL_HANDLE { return u64(o.backing.node) }
	if o.backing.owner != nil { return o.backing.owner.self }
	return 0
}

// transferFromImageBitmap(bitmap): display `bitmap` in the canvas; null blanks it. The bitmap is detached (closed).
// `has_bitmap` is false for the null argument (clear).
ImageBitmapRenderingContext_transferFromImageBitmap :: proc(c: ^Call, ctx: Api_ImageBitmapRenderingContext, bitmap: u64, has_bitmap: bool) -> Api_Error {
	o := ctx.data
	if o == nil || o.backing == nil { return .None }
	b := o.backing
	if !has_bitmap {
		// null: the canvas is resized to 0 x 0 per the spec; we present it transparent at its current size instead,
		// which is the visible result a page sees (a cleared canvas) without churning the texture size.
		canvas2d.bitmap_reset_contents(&b.bmp)
		canvas2d.bitmap_touch_all(&b.bmp)
		b.tainted = false
		return .None
	}
	src := canvas_obj_of(c.page, bitmap)
	if src == nil || src.kind != .Bitmap { return fail(c, .Type, "transferFromImageBitmap: the argument is not an ImageBitmap") }
	if src.bmp.pix == nil { return fail(c, .Invalid_State, "transferFromImageBitmap: the ImageBitmap has been detached") }
	// the canvas takes the bitmap's size and pixels (resize the backing to match, then blit)
	canvas_backing_resize(b, src.bmp.w, src.bmp.h)
	dst := canvas_backing_bitmap(b)
	if dst != nil && len(dst.pix) == len(src.bmp.pix) {
		copy(dst.pix, src.bmp.pix)
		canvas2d.bitmap_touch_all(dst)
	}
	b.tainted = src.tainted
	// detach the source bitmap (close it): its pixels now live in the canvas
	canvas_bitmap_free(c.page, &src.bmp)
	return .None
}
