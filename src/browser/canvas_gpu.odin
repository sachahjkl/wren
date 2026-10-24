package browser

// Canvases drawn on the GPU, the shell's part (package canvas2d records, the toolkit's render.canvas_* draws): the services a
// recording canvas asks of its owner (canvas2d.Gpu_Host), the textures of the pictures canvases draw from, and showing a
// canvas as the texture it is, with no copy.
//
// A canvas texture is made when the canvas first draws or is shown, lives as long as the canvas, and is the very texture the
// page shows (draw.image of it): nothing is uploaded for a frame, and a canvas nobody draws on costs nothing at all.
// Pictures a canvas draws from (an ImageBitmap, an <img> as the page's image cache keeps it, a pattern, a software canvas)
// are uploaded once, keyed by the identity of their bitmap, and kept while a recorded list needs them and for a while after.

import "core:mem"
import "toolkit:render"
import "wb:base"
import "wb:canvas2d"
import "wb:page"

#assert(size_of(canvas2d.Gpu_Inst) == size_of(render.Canvas_Inst))
#assert(size_of(canvas2d.Gpu_Paint) == size_of(render.Canvas_Paint))
#assert(size_of(canvas2d.Gpu_Cmd) == size_of(render.Canvas_Cmd))
#assert(offset_of(canvas2d.Gpu_Cmd, first) == offset_of(render.Canvas_Cmd, first))
#assert(offset_of(canvas2d.Gpu_Cmd, color_matrix) == offset_of(render.Canvas_Cmd, color_matrix))
#assert(offset_of(canvas2d.Gpu_Cmd, color) == offset_of(render.Canvas_Cmd, color))
#assert(offset_of(canvas2d.Gpu_Cmd, box) == offset_of(render.Canvas_Cmd, box))
#assert(canvas2d.GG_SHAPE == render.CG_SHAPE && canvas2d.GF_UNBOUNDED == render.CF_UNBOUNDED && canvas2d.GF_MASK_OUT == render.CF_MASK_OUT)
#assert(canvas2d.GPU_SRC_LAYER0 == render.CANVAS_SRC_LAYER0 && canvas2d.GPU_SRC_SNAPSHOT == render.CANVAS_SRC_SNAPSHOT)
#assert(canvas2d.GPF_TINT == render.CPF_TINT && canvas2d.GP_IMAGE == render.CP_IMAGE)

@(private = "file")
Source_Entry :: struct {
	tex:     render.Texture,
	w, h:    int,
	version: u64,
	pins:    int,        // lists recorded and not yet submitted that draw it
	epoch:   u64,
	uid:     u64,
	orphan:  bool,       // not in the table any more: freed when its last list is done
}

@(private = "file")
Canvas_Gpu :: struct {
	host:    canvas2d.Gpu_Host,
	r:       ^render.Renderer,
	limit:   int,               // bytes of source pictures kept
	sources: map[u64]^Source_Entry,
	bytes:   int,
	epoch:   u64,
	on:      bool,
	uploads: int,
	app:     ^App,
}

@(private = "file")
cgpu: Canvas_Gpu

// Connects the canvas renderer: from now on a page's canvases draw on the GPU (unless canvas.gpu.enabled is off).
canvas_gpu_init :: proc(app: ^App) {
	canvas_gpu_setup(&app.r, app.page_settings.canvas.max_image_cache_bytes, app)
}

// The same for any renderer (tests draw on an offscreen one). pp is what the video shell needs (nil: no videos).
canvas_gpu_setup :: proc(r: ^render.Renderer, limit: int, app: ^App = nil) -> ^canvas2d.Gpu_Host {
	when render.USE_WGPU { return nil } else {
		if !render.canvas_supported(r) { return nil }
		cgpu = {}
		cgpu.r, cgpu.limit, cgpu.app = r, limit, app
		cgpu.sources = make(map[u64]^Source_Entry)
		cgpu.host = canvas2d.Gpu_Host{
			user = nil,
			submit = gpu_submit, read = gpu_read, read_mask = gpu_read_mask, resolve = gpu_resolve, unpin = gpu_unpin,
			destroy = gpu_destroy_target, generation = proc(user: rawptr) -> u64 { return cgpu.r.device_generation },
		}
		cgpu.on = true
		page.canvas_gpu_host = &cgpu.host
		return &cgpu.host
	}
}

canvas_gpu_destroy :: proc(app: ^App) {
	canvas_gpu_teardown()
}

canvas_gpu_teardown :: proc() {
	if !cgpu.on { return }
	page.canvas_gpu_host = nil
	canvas2d.gpu_glyphs_destroy()
	for _, e in cgpu.sources { render.destroy_texture(cgpu.r, e.tex); free(e) }
	delete(cgpu.sources)
	// (the host stays: a canvas that outlives the shell calls it, and it does nothing)
	cgpu.sources = nil
	cgpu.on = false
}

// Once per frame, before the pages are painted: the age of the pictures counts, and the ones nobody needs go.
canvas_gpu_begin_frame :: proc(app: ^App) {
	if !cgpu.on { return }
	cgpu.epoch += 1
	limit := cgpu.limit
	// pictures unused for a while, or the oldest when the budget is passed
	for uid, e in cgpu.sources {
		if e.pins > 0 { continue }
		idle := cgpu.epoch - e.epoch
		if idle > 1200 || (cgpu.bytes > limit && idle > 30) { source_free(cgpu.r, e); delete_key(&cgpu.sources, uid) }
	}
}

@(private = "file")
source_free :: proc(r: ^render.Renderer, e: ^Source_Entry) {
	render.destroy_texture(r, e.tex)
	cgpu.bytes -= e.w * e.h * 4 * 4 / 3
	free(e)
}

// The texture of a canvas drawn on the GPU, brought up to date (what was recorded is drawn now). false: it has none.
canvas_gpu_present :: proc(g: ^canvas2d.Gpu) -> (render.Texture, bool) {
	if g == nil || !cgpu.on { return 0, false }
	canvas2d.gpu_flush(g)
	if !ensure_target(g) { return 0, false }
	canvas2d.gpu_frame(g)
	return render.Texture(g.target), true
}

// The canvas's texture, made (transparent, or opaque black for alpha: false) when it has none.
@(private = "file")
ensure_target :: proc(g: ^canvas2d.Gpu) -> bool {
	r := cgpu.r
	if g.target != 0 { return true }
	if r.lost { return false }
	tex := render.canvas_texture_create(r, g.w, g.h, true, min(g.w, g.h) >= 32)
	if tex == 0 { return false }
	render.canvas_set_opaque(r, tex, g.opaque)
	if g.opaque { render.canvas_clear(r, tex, {0, 0, 0, 1}) }
	g.target = i64(tex)
	return true
}

@(private = "file")
gpu_submit :: proc(user: rawptr, g: ^canvas2d.Gpu) -> bool {
	if !cgpu.on { return true }
	r := cgpu.r
	// (a lost device: the frame recovers it; what was recorded is dropped with the contents)
	if r.lost { return true }
	if !ensure_target(g) { return false }
	if len(g.cmds) == 0 { return true }
	l := render.Canvas_List{
		insts   = mem.slice_ptr((^render.Canvas_Inst)(raw_data(g.insts)), len(g.insts)),
		heap    = g.heap[:],
		paints  = mem.slice_ptr((^render.Canvas_Paint)(raw_data(g.paints)), len(g.paints)),
		stops   = g.stops[:],
		cmds    = mem.slice_ptr((^render.Canvas_Cmd)(raw_data(g.cmds)), len(g.cmds)),
		pixels  = g.pixels[:],
		sources = mem.slice_ptr((^render.Texture)(raw_data(g.source_tex)), len(g.source_tex)),
	}
	return render.canvas_submit(r, render.Texture(g.target), &l)
}

@(private = "file")
gpu_read :: proc(user: rawptr, g: ^canvas2d.Gpu, x, y, w, h: int, out: []u8) -> bool {
	if !cgpu.on || !ensure_target(g) { return false }
	return render.canvas_read(cgpu.r, render.Texture(g.target), x, y, w, h, out)
}

@(private = "file")
gpu_read_mask :: proc(user: rawptr, g: ^canvas2d.Gpu, id: i32, out: []u8) -> bool {
	if !cgpu.on || g.target == 0 { return false }
	return render.canvas_read_mask(cgpu.r, render.Texture(g.target), id, out)
}

@(private = "file")
gpu_destroy_target :: proc(user: rawptr, g: ^canvas2d.Gpu) {
	if cgpu.on && g.target != 0 { render.destroy_texture(cgpu.r, render.Texture(g.target)) }
	g.target = 0
}

@(private = "file")
gpu_unpin :: proc(user: rawptr, s: ^canvas2d.Gpu_Source) {
	e := (^Source_Entry)(s.token)
	s.token = nil
	if e == nil || !cgpu.on { return }
	e.pins -= 1
	if e.pins <= 0 && e.orphan { source_free(cgpu.r, e) }
}

@(private = "file")
gpu_resolve :: proc(user: rawptr, s: ^canvas2d.Gpu_Source) -> (tex: i64, linear: bool, size: [2]int) {
	if !cgpu.on { return }
	r := cgpu.r
	if r.lost { return }
	switch s.kind {
	case .Canvas:
		g := s.canvas
		if g == nil || g.failed || !ensure_target(g) { return }
		return g.target, false, {g.w, g.h}
	case .Video:
		p := (^page.Page)(s.owner)
		vt, vsize, ok := video_texture_for_canvas(cgpu.app, p, base.Handle(s.id))
		if !ok { return }
		return i64(vt), render.texture_space(r, vt) == .Linear, vsize
	case .Bitmap:
		b := s.bmp
		if b == nil || b.uid == 0 || b.w <= 0 || b.h <= 0 || len(b.pix) < b.w * b.h * 4 { return }
		e := cgpu.sources[b.uid]
		if e != nil && (e.w != b.w || e.h != b.h) {
			delete_key(&cgpu.sources, b.uid)
			if e.pins > 0 { e.orphan = true } else { source_free(r, e) }
			e = nil
		}
		fresh := false
		if e != nil && e.version != b.version && e.pins > 0 {
			// another version of a picture that a recorded list still draws: the list keeps its texture, this one gets its own
			delete_key(&cgpu.sources, b.uid)
			e.orphan = true
			e = nil
		}
		if e == nil {
			t := render.canvas_texture_create(r, b.w, b.h, false, true)
			if t == 0 { return }
			e = new(Source_Entry)
			e.tex, e.w, e.h, e.uid = t, b.w, b.h, b.uid
			cgpu.sources[b.uid] = e
			cgpu.bytes += b.w * b.h * 4 * 4 / 3
			fresh = true
		}
		if fresh || e.version != b.version {
			render.canvas_upload(r, e.tex, 0, 0, b.w, b.h, b.pix)
			e.version = b.version
			cgpu.uploads += 1
		}
		e.pins += 1
		e.epoch = cgpu.epoch
		s.token = e
		return i64(e.tex), false, {b.w, b.h}
	}
	return
}
