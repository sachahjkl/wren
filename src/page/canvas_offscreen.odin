package page

// canvas.transferControlToOffscreen() (HTML §4.12.5): an element gives its drawing to an OffscreenCanvas, usually in a worker, and
// shows what that one draws. The element's backing becomes a placeholder: no context, a bitmap filled from a Canvas_Placeholder, a
// counted object both threads hold. The OffscreenCanvas's backing draws as any other; whenever its bitmap changed, the thread that
// runs it copies it into the Placeholder and wakes the page's loop, which copies it into the element's bitmap, and the shell shows
// that as any canvas. Nothing on one thread points into the other's memory.
//
// Moving an OffscreenCanvas to a worker goes as a MediaSourceHandle does (mse_worker.odin): the structured clone takes a token here and
// the receiving realm adopts it.

import "core:sync"
import "wb:base"
import "wb:canvas2d"
import "wb:host"

Canvas_Placeholder :: struct {
	refs:     i32,            // atomic
	mu:       sync.Mutex,     // everything below but ui_loop
	pix:      []u8,           // the latest picture, premultiplied, top row first (process allocator)
	w, h:     int,
	opaque:   bool,
	fresh:    bool,           // a picture the element has not taken yet
	posted:   bool,           // a wake of the page's loop is on its way
	backing:  ^Canvas_Backing,  // the element's (only the page's thread reads it); nil once it went
	ui_loop:  ^host.Loop,
}

@(private = "file")
placeholder_retain :: proc(ph: ^Canvas_Placeholder) { sync.atomic_add(&ph.refs, 1) }

@(private)
placeholder_release :: proc(ph: ^Canvas_Placeholder) {
	if ph == nil || sync.atomic_sub(&ph.refs, 1) != 1 { return }
	delete(ph.pix, base.process_allocator())
	free(ph, base.process_allocator())
}

// The element's backing goes (canvas_backing_free): no more pictures for it.
@(private)
placeholder_forget :: proc(b: ^Canvas_Backing) {
	ph := b.placeholder
	if ph == nil { return }
	b.placeholder = nil
	if b.node != base.NIL_HANDLE {
		sync.mutex_lock(&ph.mu)
		ph.backing = nil
		sync.mutex_unlock(&ph.mu)
	}
	placeholder_release(ph)
}

// (the page's loop) A picture may wait.
@(private = "file")
placeholder_wake :: proc(data: rawptr) {
	ph := (^Canvas_Placeholder)(data)
	sync.mutex_lock(&ph.mu)
	ph.posted = false
	b := ph.backing
	sync.mutex_unlock(&ph.mu)
	if b != nil { placeholder_take(b) }
	placeholder_release(ph)
}

// (the page's thread) The newest picture into the element's bitmap, at the picture's size.
@(private)
placeholder_take :: proc(b: ^Canvas_Backing) {
	ph := b.placeholder
	if ph == nil { return }
	sync.mutex_lock(&ph.mu)
	defer sync.mutex_unlock(&ph.mu)
	if !ph.fresh { return }
	ph.fresh = false
	if b.width != ph.w || b.height != ph.h || len(b.bmp.pix) != ph.w * ph.h * 4 {
		canvas_bitmap_free(b.page, &b.bmp)
		b.width, b.height = ph.w, ph.h
		b.warned = false
		b.opaque = ph.opaque
		canvas_backing_alloc(b)
	}
	if len(b.bmp.pix) != len(ph.pix) { return }
	copy(b.bmp.pix, ph.pix)
	b.bmp.all_opaque = ph.opaque
	canvas2d.bitmap_touch_all(&b.bmp)
}

// (the OffscreenCanvas's thread) What it drew since the last time goes to the element.
@(private)
placeholder_commit :: proc(b: ^Canvas_Backing) {
	ph := b.placeholder
	if ph == nil || b.node != base.NIL_HANDLE || b.ctx_obj == nil || b.bmp.version == b.committed || b.bmp.w <= 0 || b.bmp.h <= 0 { return }
	b.committed = b.bmp.version
	n := len(b.bmp.pix)
	post := false
	sync.mutex_lock(&ph.mu)
	if len(ph.pix) != n {
		delete(ph.pix, base.process_allocator())
		ph.pix = make([]u8, n, base.process_allocator())
	}
	if len(ph.pix) == n {
		copy(ph.pix, b.bmp.pix)
		ph.w, ph.h = b.bmp.w, b.bmp.h
		ph.opaque = b.opaque || b.bmp.all_opaque
		ph.fresh = true
		if !ph.posted {
			ph.posted = true
			post = true
		}
	}
	sync.mutex_unlock(&ph.mu)
	if post {
		placeholder_retain(ph)   // (the wake's)
		host.post(ph.ui_loop, placeholder_wake, ph)
	}
}

// canvas.transferControlToOffscreen(): the OffscreenCanvas, in this realm, for now.
HTMLCanvasElement_transferControl :: proc(c: ^Call, canvas: Api_HTMLCanvasElement) -> (u64, Api_Error) {
	p := c.page
	if !p.settings.canvas.enabled || p.worker != nil { return 0, fail(c, .Not_Supported, "This canvas cannot be transferred.") }
	b := canvas_element_backing(p, base.Handle(canvas.handle), true)
	if b == nil { return 0, fail(c, .Not_Supported, "This canvas cannot be transferred.") }
	canvas_sync(b)
	if b.ctx_obj != nil { return 0, fail(c, .Invalid_State, "Cannot transfer control from a canvas that has a rendering context.") }
	if b.placeholder != nil { return 0, fail(c, .Invalid_State, "Cannot transfer control from a canvas for a second time.") }
	ph := new(Canvas_Placeholder, base.process_allocator())
	ph.refs = 2   // the element's and the OffscreenCanvas's
	ph.backing, ph.ui_loop = b, p.loop
	ph.w, ph.h = b.width, b.height
	b.placeholder = ph
	b.read_freq = true   // (a bitmap with pixels, always: pictures are copied into it)
	o, h := canvas_new_object(p, c.owner, .Offscreen)
	nb := canvas_backing_new(p, base.NIL_HANDLE, b.width, b.height)
	nb.owner, o.backing, nb.placeholder = o, nb, ph
	nb.read_freq = true
	return h, .None
}

// What travels in a message: the canvas's size and its placeholder. Taken, not adopted yet (any thread: under the lock).
@(private = "file")
Offscreen_Token :: struct {
	w, h: int,
	ph:   ^Canvas_Placeholder,
}
@(private = "file") offscreen_tokens: [dynamic]^Offscreen_Token
@(private = "file") offscreen_tokens_mu: sync.Mutex

// The structured clone's transfer steps: Invalid_State for a canvas that has a context or was transferred before. The object is
// left detached.
OffscreenCanvas_takeForTransfer :: proc(c: ^Call, canvas: Api_OffscreenCanvas) -> (u64, Api_Error) {
	o := canvas.data
	b := o.backing
	if b == nil { return 0, fail(c, .Data_Clone, "An OffscreenCanvas could not be transferred: it was transferred before.") }
	if b.ctx_obj != nil { return 0, fail(c, .Invalid_State, "An OffscreenCanvas with a rendering context could not be transferred.") }
	t := new(Offscreen_Token, base.process_allocator())
	t.w, t.h, t.ph = b.width, b.height, b.placeholder
	b.placeholder = nil   // (its reference goes with the token)
	sync.mutex_lock(&offscreen_tokens_mu)
	if offscreen_tokens.allocator.procedure == nil { offscreen_tokens.allocator = base.process_allocator() }
	append(&offscreen_tokens, t)
	sync.mutex_unlock(&offscreen_tokens_mu)
	b.owner = nil
	o.backing = nil
	canvas_backing_free(b)
	return u64(uintptr(t)), .None
}

OffscreenCanvas_adoptTransfer :: proc(c: ^Call, token: u64) -> (u64, Api_Error) {
	t := (^Offscreen_Token)(uintptr(token))
	found := false
	sync.mutex_lock(&offscreen_tokens_mu)
	for x, i in offscreen_tokens { if x == t { unordered_remove(&offscreen_tokens, i); found = true; break } }
	sync.mutex_unlock(&offscreen_tokens_mu)
	if !found { return 0, fail(c, .Data_Clone, "DataCloneError: no such OffscreenCanvas in transfer.") }
	p := c.page
	o, h := canvas_new_object(p, c.owner, .Offscreen)
	b := canvas_backing_new(p, base.NIL_HANDLE, t.w, t.h)
	b.owner, o.backing, b.placeholder = o, b, t.ph
	b.read_freq = t.ph != nil
	free(t, base.process_allocator())
	return h, .None
}

// Process end: the tokens of messages never received.
offscreen_tokens_shutdown :: proc() {
	sync.mutex_lock(&offscreen_tokens_mu)
	for t in offscreen_tokens {
		placeholder_release(t.ph)
		free(t, base.process_allocator())
	}
	delete(offscreen_tokens)
	offscreen_tokens = nil
	sync.mutex_unlock(&offscreen_tokens_mu)
}

// A worker's loop, each time round: frames of its contexts, what its canvases drew. A worker has no shell to ask for this.
canvas_worker_tick :: proc(p: ^Page) {
	if p.canvases != nil { canvas_frame(p) }
}
