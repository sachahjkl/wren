package page

// The 2D canvas of a page (api/canvas.widl, module canvas; the rasterizer is package canvas2d).
//
// Every <canvas> that was asked for a context has a Canvas_Backing in its page's table: the bitmap, the 2D context
// and the taint flag. The bitmap follows the element's width / height attributes (a change of either clears it and
// resets the context, as HTML says); the shell paints the element from `canvas_view` and uploads the part of the
// bitmap that changed since the last frame, so a canvas nobody draws on costs nothing. An OffscreenCanvas is a backing
// without an element, owned by its script object. Everything else a script holds (contexts, gradients, patterns,
// Path2D, TextMetrics, ImageBitmap) is a Canvas_Obj of one kind in the page's object registry (objects.odin).
//
// Memory: bitmaps count against canvas.max_page_bytes per page, and each is bounded by canvas.max_dimension and
// canvas.max_pixels; a canvas that gets no bitmap keeps working as an object (its draws do nothing) and the page's
// console says so once. Nothing here outlives its page: the table is torn down before the objects are, and
// objects tolerate their backing being gone.

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:canvas2d"
import "wb:css"
import "wb:dom"
import "wb:style"

// Textures of canvases are keyed in the shell by their backing's id with this bit, apart from the image cache's ids.
CANVAS_TEXTURE_BIT :: u64(1) << 62

Canvas_Kind :: enum u8 { Context, Gradient, Pattern, Path, Metrics, Offscreen, Bitmap }

Canvas_Obj :: struct {
	kind:      Canvas_Kind,
	page:      ^Page,
	self:      u64,                       // its handle (OBJECT_TAG set)
	backing:   ^Canvas_Backing,           // Context, Offscreen: nil once the canvas is gone
	ctx:       canvas2d.Context,          // Context
	grad:      ^canvas2d.Gradient,        // Gradient
	pat:       ^canvas2d.Pattern,         // Pattern
	path:      canvas2d.Path,             // Path (Path2D)
	metrics:   canvas2d.Text_Metrics,     // Metrics
	bmp:       canvas2d.Bitmap,           // Bitmap (ImageBitmap): premultiplied pixels
	tainted:   bool,                      // Bitmap: made from something the page may not read
	fill_obj:  u64,                       // Context: the script objects the styles were set from (style getters)
	stroke_obj: u64,
	alpha:     bool,                      // Context: getContext's alpha
	read_freq: bool,
}

Canvas_Backing :: struct {
	id:        u64,                       // texture key (with CANVAS_TEXTURE_BIT)
	page:      ^Page,
	node:      base.Handle,               // the element; NIL_HANDLE for an OffscreenCanvas
	bmp:       canvas2d.Bitmap,
	width, height: int,                   // the size asked for (the bitmap is 0 x 0 when it could not be had)
	ctx_obj:   ^Canvas_Obj,
	ctx_handle: u64,
	owner:     ^Canvas_Obj,               // the OffscreenCanvas object
	opaque:    bool,                      // getContext("2d", { alpha: false })
	tainted:   bool,                      // drew something the page may not read back
	seen:      u64,                       // doc.mutations when the attributes were last looked at
	warned:    bool,
}

@(private)
Cached_Image :: struct {
	generation: u64,
	bmp:        canvas2d.Bitmap,
	tainted:    bool,
	used:       u64,
}

@(private)
Canvas_Page :: struct {
	backings:    map[base.Handle]^Canvas_Backing,
	all:         [dynamic]^Canvas_Backing,
	images:      map[u64]^Cached_Image,       // premultiplied copies of decoded images, by cache entry id
	image_bytes: int,
	bytes:       int,                         // bitmaps held
	tick:        u64,
}

@(private)
canvas_pages: map[^Page]^Canvas_Page

// Ids of backings that died: the shell frees their textures.
@(private)
canvas_released: [dynamic]u64
@(private)
canvas_next_id: u64

// What the shell provides for text (fonts, shaping, glyph outlines). Set once at start-up; `user` is replaced by the
// page when a context is made.
canvas_text_engine: canvas2d.Text_Engine

canvas_vt := Object_VTable{
	name = "Canvas",
	destroy = proc(p: ^Page, data: rawptr) {
		o := (^Canvas_Obj)(data)
		switch o.kind {
		case .Context:
			canvas2d.context_destroy(&o.ctx)
			if o.backing != nil && o.backing.ctx_obj == o { o.backing.ctx_obj, o.backing.ctx_handle = nil, 0 }
		case .Gradient: canvas2d.gradient_release(o.grad)
		case .Pattern: canvas2d.pattern_release(o.pat)
		case .Path: canvas2d.path_destroy(&o.path)
		case .Metrics:
		case .Offscreen:
			if o.backing != nil {
				o.backing.owner = nil
				canvas_backing_free(o.backing)
			}
		case .Bitmap: canvas_bitmap_free(p, &o.bmp)
		}
		free(o)
	},
}

@(private)
canvas_obj :: proc(c: ^Call, h: u64) -> ^Canvas_Obj { return (^Canvas_Obj)(object_data(c.page, h, &canvas_vt)) }

@(private)
canvas_obj_of :: proc(p: ^Page, h: u64) -> ^Canvas_Obj { return (^Canvas_Obj)(object_data(p, h, &canvas_vt)) }

@(private)
canvas_of_kind :: proc(c: ^Call, h: u64, kind: Canvas_Kind) -> ^Canvas_Obj {
	o := canvas_obj(c, h)
	if o == nil || o.kind != kind { return nil }
	return o
}

lookup_CanvasRenderingContext2D :: proc(c: ^Call, h: u64) -> ^Canvas_Obj { return canvas_of_kind(c, h, .Context) }
lookup_CanvasGradient :: proc(c: ^Call, h: u64) -> ^Canvas_Obj { return canvas_of_kind(c, h, .Gradient) }
lookup_CanvasPattern :: proc(c: ^Call, h: u64) -> ^Canvas_Obj { return canvas_of_kind(c, h, .Pattern) }
lookup_Path2D :: proc(c: ^Call, h: u64) -> ^Canvas_Obj { return canvas_of_kind(c, h, .Path) }
lookup_TextMetrics :: proc(c: ^Call, h: u64) -> ^Canvas_Obj { return canvas_of_kind(c, h, .Metrics) }
lookup_OffscreenCanvas :: proc(c: ^Call, h: u64) -> ^Canvas_Obj { return canvas_of_kind(c, h, .Offscreen) }
lookup_ImageBitmap :: proc(c: ^Call, h: u64) -> ^Canvas_Obj { return canvas_of_kind(c, h, .Bitmap) }

lookup_CanvasPathTarget :: proc(c: ^Call, h: u64) -> ^Canvas_Obj {
	o := canvas_obj(c, h)
	if o == nil || (o.kind != .Context && o.kind != .Path) { return nil }
	return o
}

lookup_HTMLCanvasElement :: proc(c: ^Call, h: u64) -> ^dom.Node {
	n := lookup_Element(c, h)
	if n == nil || n.name != "canvas" { return nil }
	return n
}

@(private)
canvas_page :: proc(p: ^Page) -> ^Canvas_Page {
	if cp, ok := canvas_pages[p]; ok { return cp }
	cp := new(Canvas_Page)
	canvas_pages[p] = cp
	// runs before page_cleanup frees the objects (registered after it): the backings go first, and the objects that
	// outlive them see their backing gone
	base.on_close(p.scope, proc(data: rawptr) {
		pg := (^Page)(data)
		cp, ok := canvas_pages[pg]
		if !ok { return }
		for len(cp.all) > 0 { canvas_backing_free(cp.all[len(cp.all) - 1]) }
		for _, im in cp.images { canvas2d.bitmap_destroy(&im.bmp); free(im) }
		delete(cp.images)
		delete(cp.backings)
		delete(cp.all)
		free(cp)
		delete_key(&canvas_pages, pg)
		if len(canvas_pages) == 0 { delete(canvas_pages); canvas_pages = nil }
	}, p)
	return cp
}

////////////////////////////////
// Bitmaps and their budget

// A transparent bitmap within the page's limits.
@(private)
canvas_bitmap :: proc(p: ^Page, w, h: int) -> (bmp: canvas2d.Bitmap, ok: bool) {
	s := &p.settings.canvas
	if w < 0 || h < 0 || w > s.max_dimension || h > s.max_dimension || w * h > s.max_pixels { return }
	cp := canvas_page(p)
	n := w * h * 4
	if cp.bytes + n > s.max_page_bytes {
		canvas_image_cache_trim(p, 0)   // the premultiplied copies of images go before a canvas is refused
		if cp.bytes + n > s.max_page_bytes { return }
	}
	bmp, ok = canvas2d.bitmap_create(w, h, n)
	if ok { cp.bytes += len(bmp.pix) }
	return
}

@(private)
canvas_bitmap_free :: proc(p: ^Page, bmp: ^canvas2d.Bitmap) {
	if !p.closed {
		if cp, ok := canvas_pages[p]; ok { cp.bytes -= len(bmp.pix) }
	}
	canvas2d.bitmap_destroy(bmp)
}

@(private)
canvas_note :: proc(p: ^Page, b: ^Canvas_Backing, text: string) {
	if b.warned { return }
	b.warned = true
	log(p, .Warn, text)
}

////////////////////////////////
// Backings

@(private)
parse_canvas_dim :: proc(s: string, fallback: int) -> int {
	// HTML "rules for parsing non-negative integers": white space, an optional +, digits (the rest is ignored)
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r' || s[i] == '\f') { i += 1 }
	if i < len(s) && s[i] == '+' { i += 1 }
	start := i
	v := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		v = v * 10 + int(s[i] - '0')
		if v > 2147483647 { return fallback }   // (an unsigned long that does not fit: the default)
		i += 1
	}
	if i == start { return fallback }
	return v
}

canvas_dims :: proc(d: ^dom.Document, node: base.Handle) -> (w, h: int) {
	wv, _ := dom.get_attribute(d, node, "width")
	hv, _ := dom.get_attribute(d, node, "height")
	return parse_canvas_dim(wv, 300), parse_canvas_dim(hv, 150)
}

@(private)
canvas_backing_new :: proc(p: ^Page, node: base.Handle, w, h: int) -> ^Canvas_Backing {
	cp := canvas_page(p)
	canvas_next_id += 1
	b := new(Canvas_Backing)
	b.page, b.node, b.id = p, node, canvas_next_id | CANVAS_TEXTURE_BIT
	b.width, b.height = w, h
	if p.doc != nil { b.seen = p.doc.mutations }
	append(&cp.all, b)
	if node != base.NIL_HANDLE { cp.backings[node] = b }
	return b
}

// The bitmap of a backing at its current size (transparent, or opaque black for alpha: false). false: it could not be had.
@(private)
canvas_backing_alloc :: proc(b: ^Canvas_Backing) -> bool {
	p := b.page
	bmp, ok := canvas_bitmap(p, b.width, b.height)
	b.bmp = bmp
	if !ok {
		b.bmp = {}
		if b.width > 0 && b.height > 0 {
			canvas_note(p, b, fmt.tprintf("canvas of %d x %d pixels: no memory for its bitmap (canvas.max_dimension, canvas.max_pixels, canvas.max_page_bytes); drawing on it does nothing", b.width, b.height))
		}
		return false
	}
	b.bmp.opaque = b.opaque
	canvas2d.bitmap_reset_contents(&b.bmp)
	return true
}

// Frees a backing, its context and its bookkeeping. The texture id is reported to the shell.
@(private)
canvas_backing_free :: proc(b: ^Canvas_Backing) {
	p := b.page
	if cp, ok := canvas_pages[p]; ok {
		if b.node != base.NIL_HANDLE { delete_key(&cp.backings, b.node) }
		for x, i in cp.all { if x == b { unordered_remove(&cp.all, i); break } }
	}
	if b.ctx_obj != nil {
		o := b.ctx_obj
		o.backing = nil
		b.ctx_obj = nil
		h := b.ctx_handle
		b.ctx_handle = 0
		object_release(p, h)   // (its destructor sees the backing gone)
	}
	if b.owner != nil { b.owner.backing = nil }
	canvas_bitmap_free(p, &b.bmp)
	if canvas_released.allocator.procedure == nil { canvas_released.allocator = base.permanent_allocator() }
	append(&canvas_released, b.id)
	free(b)
}

// The element's backing (made when `create`). The bitmap is allocated with the context, not before.
@(private)
canvas_element_backing :: proc(p: ^Page, node: base.Handle, create: bool) -> ^Canvas_Backing {
	cp := canvas_page(p)
	if b, ok := cp.backings[node]; ok { return b }
	if !create || p.doc == nil { return nil }
	w, h := canvas_dims(p.doc, node)
	return canvas_backing_new(p, node, w, h)
}

// An element's attributes may have changed since the backing last looked (setAttribute, the parser, innerHTML): a new
// size clears the canvas and resets its context. Checked when the document's mutation counter moved.
@(private)
canvas_sync :: proc(b: ^Canvas_Backing) {
	if b == nil || b.node == base.NIL_HANDLE { return }
	d := b.page.doc
	if d == nil || b.seen == d.mutations { return }
	b.seen = d.mutations
	if dom.get(d, b.node) == nil { return }
	w, h := canvas_dims(d, b.node)
	if w != b.width || h != b.height { canvas_backing_resize(b, w, h) }
}

@(private)
canvas_backing_resize :: proc(b: ^Canvas_Backing, w, h: int) {
	b.width, b.height = w, h
	canvas_bitmap_free(b.page, &b.bmp)
	b.warned = false
	if b.ctx_obj != nil { canvas_backing_alloc(b) }
	if b.ctx_obj != nil { canvas2d.context_reset(&b.ctx_obj.ctx) }
	b.tainted = false
}

// The context a Context object stands for, its canvas brought up to date; nil when the canvas is gone.
@(private)
cx :: proc(o: ^Canvas_Obj) -> ^canvas2d.Context {
	if o == nil || o.backing == nil { return nil }
	canvas_sync(o.backing)
	return &o.ctx
}

// What the element inherits for text and `currentcolor`: its computed font size, direction and color.
@(private)
canvas_refresh_inherit :: proc(o: ^Canvas_Obj) {
	b := o.backing
	if b == nil { return }
	inh := canvas2d.Inherited{font_size = 10, color = {0, 0, 0, 1}}
	p := b.page
	if b.node != base.NIL_HANDLE && p.styled != nil {
		i := int(base.handle_index(b.node))
		if i < len(p.styled.by_node) {
			if cs := p.styled.by_node[i]; cs != nil {
				inh = canvas2d.Inherited{rtl = cs.direction == .Rtl, font_size = f64(cs.font_size), color = cs.color}
			}
		}
	}
	o.ctx.inherit = inh
}

@(private)
canvas_new_object :: proc(p: ^Page, owner: u32, kind: Canvas_Kind) -> (^Canvas_Obj, u64) {
	o := new(Canvas_Obj)
	o.kind, o.page = kind, p
	o.self = object_create(p, &canvas_vt, o, owner)
	return o, o.self
}

// The 2D context object of a backing, made on first use.
@(private)
canvas_make_context :: proc(c: ^Call, b: ^Canvas_Backing, alpha, read_freq: bool) -> u64 {
	if b.ctx_handle != 0 { return b.ctx_handle }
	p := c.page
	b.opaque = !alpha
	canvas_backing_alloc(b)
	o, h := canvas_new_object(p, c.owner, .Context)
	o.backing, o.alpha, o.read_freq = b, alpha, read_freq
	canvas2d.context_init(&o.ctx, &b.bmp, canvas2d.options_of(&p.settings.canvas))
	o.ctx.text = canvas_text_engine
	o.ctx.text.user = p
	b.ctx_obj, b.ctx_handle = o, h
	canvas_refresh_inherit(o)
	return h
}

////////////////////////////////
// What the shell paints

Canvas_View :: struct {
	ok:  bool,
	id:  u64,                 // the texture key
	bmp: ^canvas2d.Bitmap,    // premultiplied pixels; version and dirty rectangle say what to upload
}

// The pixels of a <canvas> element (ok = false: nothing to draw, no script asked for a context or the bitmap could not
// be had).
canvas_view :: proc(p: ^Page, node: base.Handle) -> Canvas_View {
	cp, has := canvas_pages[p]
	if !has { return {} }
	b, found := cp.backings[node]
	if !found || b.ctx_obj == nil { return {} }
	canvas_sync(b)
	if b.bmp.w == 0 || b.bmp.h == 0 { return {} }
	return Canvas_View{ok = true, id = b.id, bmp = &b.bmp}
}

// Once per frame: backings of elements the document freed go (their textures with them).
canvas_frame :: proc(p: ^Page) {
	cp, has := canvas_pages[p]
	if !has || len(cp.backings) == 0 || p.doc == nil { return }
	gone: [dynamic]^Canvas_Backing
	gone.allocator = context.temp_allocator
	for node, b in cp.backings { if dom.get(p.doc, node) == nil { append(&gone, b) } }
	for b in gone { canvas_backing_free(b) }
	canvas_image_cache_trim(p, p.settings.canvas.max_image_cache_bytes)
}

// Changes whenever a canvas of the page was drawn on (effects that cache what is under them look at it).
canvas_generation :: proc(p: ^Page) -> u64 {
	cp, ok := canvas_pages[p]
	if !ok { return 0 }
	g: u64
	for b in cp.all { g += b.bmp.version }
	return g
}

// Ids of the textures to free.
canvas_drain_released :: proc(out: ^[dynamic]u64) {
	append(out, ..canvas_released[:])
	clear(&canvas_released)
}

// How many canvas bytes the page holds (for the memory view and tests).
canvas_bytes :: proc(p: ^Page) -> int {
	if cp, ok := canvas_pages[p]; ok { return cp.bytes + cp.image_bytes }
	return 0
}

////////////////////////////////
// Parsing the CSS strings of the API

@(private)
canvas_parse_options :: proc(p: ^Page) -> css.Parse_Options {
	if p.engine != nil { return style.parse_options(&p.engine.settings) }
	return css.Parse_Options{}
}

// A CSS color: false when it does not parse (the API then ignores the assignment). `currentcolor` is the canvas
// element's color.
@(private)
canvas_color :: proc(o: ^Canvas_Obj, s: string) -> (col: [4]f32, ok: bool) {
	p := o.page
	vals := css.parse_component_values(strings.trim_space(s), canvas_parse_options(p), context.temp_allocator)
	cv, good := css.parse_color(vals, nil)
	if !good { return }
	if cv.kind == .Current_Color {
		canvas_refresh_inherit(o)
		return o.ctx.inherit.color, true
	}
	return cv.rgba, true
}

// fillStyle's serialization: #rrggbb, or rgba(r, g, b, a) with the alpha as short as keeps its 8-bit value.
@(private)
canvas_color_text :: proc(c: [4]f32) -> string {
	q :: proc(v: f32) -> int { return int(math.round(clamp(v, 0, 1) * 255)) }
	r, g, b, a := q(c.r), q(c.g), q(c.b), q(c.a)
	if a == 255 { return fmt.tprintf("#%02x%02x%02x", r, g, b) }
	buf: [32]u8
	text := strings.trim_prefix(strconv.write_float(buf[:], f64(a) / 255, 'f', 2, 64), "+")
	back, _ := strconv.parse_f64(text)
	if q(f32(back)) != a { text = strings.trim_prefix(strconv.write_float(buf[:], f64(a) / 255, 'f', 3, 64), "+") }
	text = strings.trim_right(text, "0")
	text = strings.trim_right(text, ".")
	return fmt.tprintf("rgba(%d, %d, %d, %s)", r, g, b, text)
}
