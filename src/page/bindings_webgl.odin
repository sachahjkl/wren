package page

// WebGL for a page (api/webgl.widl): the browser's side of a context. The context is a Canvas_Obj of kind .WebGL on its canvas's
// backing, so that it goes with the canvas or the page. Its pixels reach the screen the way a 2D canvas's do: copied into the
// backing's bitmap (premultiplied, top row first) when a frame is ready; the toolkit shows that bitmap as a texture.
// The device's thread never touches the page: when something happens it posts to the page's loop, with ids.

import "core:strings"
import "wb:base"
import "wb:canvas2d"
import "wb:dom"
import "wb:host"
import "wb:webgl"

// The size in bytes of a message for the console, and of what a failed creation says.
@(private = "file") WEBGL_MESSAGE_BYTES :: 1024
// The words of a command at the head of a texImage from a source, before the size and alpha convention the browser fills in.
@(private = "file") SOURCE_SIZE_WORD :: 1
@(private = "file") SOURCE_HEADER_WORDS :: 13
@(private = "file") WORD :: 4

// What the device's thread posts to the page's thread: ids, never pointers that may have gone.
WebGL_Token :: struct {
	loop:    ^host.Loop,
	page_id: u64,
	self:    u64,
}

WebGL_State :: struct {
	handle:   webgl.Handle,
	callback, user, owner: u32,
	dirty:    bool,          // drawn on since the frame last asked for
	version:  u64,           // what the canvas's generation sees
	lost_said: bool,
	token:    ^WebGL_Token,
}

// Why the last getContext gave nothing (read at once by the realm's script).
@(private = "file") create_error: string

@(private = "file")
set_create_error :: proc(text: string) {
	delete(create_error, base.process_allocator())
	create_error = strings.clone(text, base.process_allocator())
}

@(private = "file")
state_of :: proc(c: ^Call, h: u64) -> ^WebGL_State {
	o := canvas_obj_of(c.page, h)
	if o == nil || o.kind != .WebGL { return nil }
	return o.gl
}

// (the device's thread) Something happened: the page's thread looks.
@(private = "file")
gl_notify :: proc "c" (user: rawptr) {
	context = base.process_context()
	tok := (^WebGL_Token)(user)
	t := new_clone(tok^, base.process_allocator())
	host.post(t.loop, gl_pump, t)
}

@(private = "file")
gl_pump :: proc(data: rawptr) {
	t := (^WebGL_Token)(data)
	id, self := t.page_id, t.self
	free(t, base.process_allocator())
	p := page_by_id(id)
	if p == nil || p.closed { return }
	o := canvas_obj_of(p, self)
	if o == nil || o.kind != .WebGL || o.gl == nil { return }
	webgl_take_frame(p, o)
	webgl_say_lost(p, o)
}

// A new frame goes into the canvas's bitmap.
@(private)
webgl_take_frame :: proc(p: ^Page, o: ^Canvas_Obj) {
	b := o.backing
	if b == nil || len(b.bmp.pix) == 0 { return }
	taken := webgl.wg_take_frame(o.gl.handle, raw_data(b.bmp.pix), u32(b.bmp.w), u32(b.bmp.h), u32(b.bmp.w) * WORD)
	if taken != webgl.FRAME_NONE {
		canvas2d.bitmap_touch_all(&b.bmp)
		b.bmp.all_opaque = taken == webgl.FRAME_OPAQUE
		o.gl.version += 1
	}
}

@(private = "file")
webgl_say_lost :: proc(p: ^Page, o: ^Canvas_Obj) {
	gl := o.gl
	webgl_console(p, gl)
	if gl.lost_said || webgl.wg_is_lost(gl.handle) == 0 { return }
	gl.lost_said = true
	inst := instance_by_index(p, gl.owner)
	if inst == nil { return }
	argv := [2]u32{gl.user, 1}
	call_guest(p, inst, gl.callback, argv[:])
}

@(private = "file")
webgl_console :: proc(p: ^Page, gl: ^WebGL_State) {
	buf: [WEBGL_MESSAGE_BYTES]u8
	for {
		n := webgl.wg_console(gl.handle, &buf[0], len(buf))
		if n == 0 { return }
		log(p, .Warn, string(buf[:n]))
	}
}

// Once per frame, for each context of the page: what was drawn since the last frame is what the canvas shows next.
@(private)
webgl_frame :: proc(p: ^Page, o: ^Canvas_Obj) {
	gl := o.gl
	if gl == nil { return }
	webgl_take_frame(p, o)
	if gl.dirty {
		gl.dirty = false
		webgl.wg_present(gl.handle)
	}
	webgl_say_lost(p, o)
}

// A canvas's new size: a new drawing buffer, and no old frame fits.
@(private)
webgl_resized :: proc(o: ^Canvas_Obj, w, h: int) {
	if o.gl == nil { return }
	webgl.wg_resize(o.gl.handle, u32(max(w, 0)), u32(max(h, 0)))
	o.gl.dirty = true
}

@(private)
webgl_destroy :: proc(o: ^Canvas_Obj) {
	gl := o.gl
	if gl == nil { return }
	o.gl = nil
	webgl.wg_destroy(gl.handle)   // (no callback after this returns)
	free(gl.token, base.process_allocator())
	free(gl)
}

// How many contexts the page holds; the oldest goes when there are too many.
@(private = "file")
webgl_make_room :: proc(p: ^Page) {
	cp := canvas_page(p)
	count := 0
	oldest: ^Canvas_Obj
	for b in cp.all {
		o := b.ctx_obj
		if o == nil || o.kind != .WebGL || o.gl == nil || webgl.wg_is_lost(o.gl.handle) != 0 { continue }
		count += 1
		if oldest == nil || o.self < oldest.self { oldest = o }
	}
	if count >= p.settings.webgl.max_contexts && oldest != nil {
		log(p, .Warn, "Too many WebGL contexts: the oldest was lost (webgl.max_contexts).")
		webgl.wg_lose(oldest.gl.handle)
	}
}

@(private = "file")
webgl_make :: proc(c: ^Call, b: ^Canvas_Backing, flags, notify: u32, user: i32, info: []u8) -> u64 {
	p := c.page
	set_create_error("")
	if b.ctx_obj != nil {
		return b.ctx_obj.kind == .WebGL ? b.ctx_handle : 0
	}
	s := &p.settings.webgl
	if !s.enabled || (flags & 1 != 0 && !s.webgl2) {
		set_create_error("WebGL is switched off (webgl.enabled, webgl.webgl2).")
		return 0
	}
	webgl_make_room(p)
	flag :: proc(flags: u32, bit: u32) -> i32 { return flags & bit != 0 ? 1 : 0 }
	attrs := webgl.Attrs{
		webgl2 = flag(flags, 1), alpha = flag(flags, 2), depth = flag(flags, 4), stencil = flag(flags, 8), antialias = flag(flags, 16),
		premultiplied = flag(flags, 32), preserve = flag(flags, 64), fail_if_major_performance_caveat = flag(flags, 128),
		width = u32(max(b.width, 0)), height = u32(max(b.height, 0)), max_dimension = u32(p.settings.canvas.max_dimension),
		allow_software = s.allow_software ? 1 : 0, force_software = s.force_software ? 1 : 0, backend = s.backend, max_bytes = s.max_bytes, wait_ms = s.wait_ms,
	}
	token := new(WebGL_Token, base.process_allocator())
	attrs.notify, attrs.notify_user = gl_notify, token
	inf: webgl.Info
	err: [WEBGL_MESSAGE_BYTES]u8
	err_len: uint
	h := webgl.wg_create(&attrs, &inf, &err[0], len(err), &err_len)
	if h == nil {
		free(token, base.process_allocator())
		set_create_error(string(err[:err_len]))
		log(p, .Warn, strings.concatenate({"WebGL: ", string(err[:err_len])}, context.temp_allocator))
		return 0
	}
	b.opaque = flags & 2 == 0
	b.read_freq = true   // (never a canvas of canvas2d's GPU path: the frames are copied into its bitmap)
	canvas_backing_alloc(b)
	o, handle := canvas_new_object(p, c.owner, .WebGL)
	o.backing, o.alpha = b, flags & 2 != 0
	gl := new(WebGL_State)
	gl.handle, gl.callback, gl.user, gl.owner, gl.token = h, notify, u32(user), c.owner, token
	gl.dirty = true   // (what is shown before anything is drawn: the cleared buffer)
	token^ = WebGL_Token{p.loop, page_id(p), handle}
	o.gl = gl
	b.ctx_obj, b.ctx_handle = o, handle
	if len(info) >= 8 * size_of(i32) {
		out := ([^]i32)(raw_data(info))
		out[0] = inf.software
		out[1] = inf.antialias
		out[2] = inf.has_s3tc
		out[3] = inf.has_float_linear
		out[4] = inf.has_float_blend
		out[5] = i32(inf.max_samples)
		out[6] = i32(inf.width)
		out[7] = i32(inf.height)
	}
	return handle
}

WebGL_enabled :: proc(c: ^Call, version: i32) -> bool {
	s := &c.page.settings.webgl
	return s.enabled && (version != 2 || s.webgl2)
}

WebGL_create :: proc(c: ^Call, canvas: Api_HTMLCanvasElement, flags: u32, notify: u32, user: i32, info: []u8) -> u64 {
	if !c.page.settings.canvas.enabled || c.page.worker != nil { return 0 }
	b := canvas_element_backing(c.page, base.Handle(canvas.handle), true)
	if b == nil { return 0 }
	canvas_sync(b)
	return webgl_make(c, b, flags, notify, user, info)
}

WebGL_createOffscreen :: proc(c: ^Call, canvas: Api_OffscreenCanvas, flags: u32, notify: u32, user: i32, info: []u8) -> u64 {
	b := canvas.data.backing
	if b == nil || !c.page.settings.canvas.enabled { return 0 }
	return webgl_make(c, b, flags, notify, user, info)
}

WebGL_createError :: proc(c: ^Call) -> string { return create_error }

WebGL_submit :: proc(c: ^Call, ctx: u64, commands: []u8, data: []u8, drew: bool) {
	gl := state_of(c, ctx)
	if gl == nil { return }
	o := canvas_obj_of(c.page, ctx)
	if o.backing != nil { canvas_sync(o.backing) }
	webgl.wg_submit(gl.handle, raw_data(commands), len(commands), raw_data(data), len(data))
	if drew {
		if !gl.dirty { gl.version += 1 }   // (a frame is wanted: the canvas's generation moves)
		gl.dirty = true
	}
}

@(private = "file")
query :: proc(c: ^Call, ctx: u64, request, text, reply: []u8, has_text: bool) -> f64 {
	gl := state_of(c, ctx)
	if gl == nil { return -1 }
	o := canvas_obj_of(c.page, ctx)
	if o.backing != nil { canvas_sync(o.backing) }
	n: i64
	if has_text {
		full := make([]u8, len(request) + WORD + (len(text) + WORD - 1) &~ (WORD - 1), context.temp_allocator)
		copy(full, request)
		(^u32)(raw_data(full[len(request):]))^ = u32(len(text))
		copy(full[len(request) + WORD:], text)
		n = webgl.wg_query(gl.handle, raw_data(full), len(full), raw_data(reply), len(reply))
	} else {
		n = webgl.wg_query(gl.handle, raw_data(request), len(request), raw_data(reply), len(reply))
	}
	webgl_console(c.page, gl)
	return f64(n)
}

WebGL_query :: proc(c: ^Call, ctx: u64, request: []u8, reply: []u8) -> f64 { return query(c, ctx, request, nil, reply, false) }

WebGL_queryText :: proc(c: ^Call, ctx: u64, request: []u8, text: []u8, reply: []u8) -> f64 { return query(c, ctx, request, text, reply, true) }

WebGL_upload :: proc(c: ^Call, ctx: u64, command: []u8, source: u64) -> (i32, Api_Error) {
	gl := state_of(c, ctx)
	if gl == nil { return 0, .None }
	p := c.page
	if len(command) < SOURCE_HEADER_WORDS * WORD { return 0, fail(c, .Invalid_Argument, "texImage2D: a bad command") }
	head := make([]u8, len(command) + WORD, context.temp_allocator)
	copy(head, command)
	words := ([^]i32)(raw_data(head))
	pixels: []u8
	w, h: int
	premultiplied := false
	// an image straight from its decode (no loss from a premultiplied copy)
	if !is_object(source) && p.doc != nil {
		if n := dom.get(p.doc, base.Handle(source)); n != nil && n.kind == .Element && n.name == "img" {
			px := canvas_image_pixels(p, base.Handle(source))
			switch px.status {
			case .Pending, .Broken: return 1, .None
			case .Ready:
			}
			if px.opaque { return 0, fail(c, .Security, "The image is cross-origin and has no CORS approval: it cannot be a texture.") }
			w, h = px.width, px.height
			if px.stride == w * WORD {
				pixels = px.pixels[:w * h * WORD]
			} else {
				tight := make([]u8, w * h * WORD, context.temp_allocator)
				for y in 0 ..< h { copy(tight[y * w * WORD:][:w * WORD], px.pixels[y * px.stride:]) }
				pixels = tight
			}
		}
	}
	if pixels == nil {
		src := canvas_source(p, source)
		defer canvas_source_done(&src)
		switch src.status {
		case .Ok:
		case .Pending, .Broken, .Empty: return 1, .None
		case .Bad: return 0, fail(c, .Type, "texImage2D: the source is not an image")
		}
		if src.tainted { return 0, fail(c, .Security, "The source is cross-origin and has no CORS approval: it cannot be a texture.") }
		if src.video != base.NIL_HANDLE {
			// (a picture only on the GPU cannot be read here: nothing is uploaded)
			tight, vw, vh, _, vok := capture_video_rgba(p, src.video)
			if !vok { return 1, .None }
			pixels, w, h = tight, vw, vh
		} else {
			bm := canvas_source_bitmap(&src)
			if bm == nil || len(bm.pix) == 0 { return 1, .None }
			pixels, w, h, premultiplied = bm.pix, bm.w, bm.h, true
		}
	}
	words[SOURCE_SIZE_WORD] = i32(w)
	words[SOURCE_SIZE_WORD + 1] = i32(h)
	words[SOURCE_SIZE_WORD + 2] = premultiplied ? 1 : 0
	words[SOURCE_HEADER_WORDS] = i32(len(pixels))
	webgl.wg_submit(gl.handle, raw_data(head), len(head), raw_data(pixels), len(pixels))
	return 0, .None
}

WebGL_width :: proc(c: ^Call, ctx: u64) -> u32 {
	o := canvas_obj_of(c.page, ctx)
	if o == nil || o.kind != .WebGL || o.backing == nil { return 0 }
	canvas_sync(o.backing)
	return u32(max(o.backing.width, 0))
}

WebGL_height :: proc(c: ^Call, ctx: u64) -> u32 {
	o := canvas_obj_of(c.page, ctx)
	if o == nil || o.kind != .WebGL || o.backing == nil { return 0 }
	canvas_sync(o.backing)
	return u32(max(o.backing.height, 0))
}

WebGL_snapshot :: proc(c: ^Call, ctx: u64) {
	o := canvas_obj_of(c.page, ctx)
	if o == nil || o.kind != .WebGL || o.gl == nil { return }
	if o.backing != nil { canvas_sync(o.backing) }
	if webgl.wg_snapshot(o.gl.handle) != 0 { webgl_take_frame(c.page, o) }
}

WebGL_isLost :: proc(c: ^Call, ctx: u64) -> bool {
	gl := state_of(c, ctx)
	return gl == nil || webgl.wg_is_lost(gl.handle) != 0
}

WebGL_lose :: proc(c: ^Call, ctx: u64) {
	gl := state_of(c, ctx)
	if gl == nil { return }
	gl.lost_said = true   // (the script says it itself)
	webgl.wg_lose(gl.handle)
}

WebGL_restore :: proc(c: ^Call, ctx: u64) -> bool {
	gl := state_of(c, ctx)
	if gl == nil { return false }
	if webgl.wg_restore(gl.handle) == 0 { return false }
	gl.lost_said = false
	gl.dirty = true
	// (the canvas may have another size by now)
	o := canvas_obj_of(c.page, ctx)
	if o != nil && o.backing != nil { webgl_resized(o, o.backing.width, o.backing.height) }
	return true
}
