package canvas2d

// The GPU path of a context: what it records instead of rasterizing, and the services its owner (the shell) provides. The
// records are plain data laid out exactly as the toolkit's render.Canvas_* types (render/canvas_types.odin): the shell hands
// the lists to the renderer without converting them (it asserts the sizes). This package still knows nothing of the GPU.

// One primitive (see render.Canvas_Inst): a quad of device pixels, its geometry, paint and operator. 96 bytes.
Gpu_Inst :: struct #packed {
	box:   [4]f32,
	geom:  [4]f32,
	geom2: [4]f32,
	inv:   [4]f32,
	misc:  [4]f32,
	ids:   [4]u32,
}
#assert(size_of(Gpu_Inst) == 96)

GG_RECT :: 1
GG_RRECT :: 2
GG_ELLIPSE :: 3
GG_SHAPE :: 4
GF_EVENODD :: 16
GF_UNBOUNDED :: 32
GF_CLIP :: 64
GF_MASK_OUT :: 128
GF_OP_SHIFT :: 8

Gpu_Paint :: struct #packed {
	color: [4]f32,
	m:     [4]f32,
	t:     [4]f32,
	p:     [4]f32,
	q:     [4]f32,
	kind:  u32,
	nstops: u32,
	stops: u32,
	flags: u32,
}
#assert(size_of(Gpu_Paint) == 96)

GP_SOLID :: 0
GP_LINEAR :: 1
GP_RADIAL :: 2
GP_CONIC :: 3
GP_IMAGE :: 4
GP_FILTER_SHIFT :: 4
GP_FILTER_NEAREST :: 0
GP_FILTER_BILINEAR :: 1
GP_FILTER_MIPS :: 2
GP_FILTER_ANISO :: 3
GPF_LINEAR_SRC :: 256
GPF_TINT :: 512

Gpu_Cmd_Kind :: enum u8 { Draw, Clip_Make, Clip_Free, Put, Snapshot, Layer_Begin, Layer_End, Layer_Fx, Layer_Free, Clear }
Gpu_Fx :: enum u8 { Matrix, Blur, Copy }

GPU_SRC_NONE :: -1
GPU_SRC_SNAPSHOT :: -2
GPU_SRC_LAYER0 :: -3

Gpu_Cmd :: struct {
	kind:   Gpu_Cmd_Kind,
	op:     u8,
	fx:     Gpu_Fx,
	source: i32,
	clip:   i32,
	id:     i32,
	id2:    i32,
	box:    [4]i32,
	first, count: int,
	pix:    int,
	sigma:  f32,
	color_matrix: [20]f32,
	color:  [4]f32,
}

Gpu_Source_Kind :: enum u8 { Bitmap, Canvas, Video }

// Where the pixels a draw samples come from; the owner turns it into a texture when the draw is recorded (and keeps it alive
// until the list that uses it is submitted or dropped).
Gpu_Source :: struct {
	kind:   Gpu_Source_Kind,
	bmp:    ^Bitmap,     // Bitmap: premultiplied pixels (its version tells when they changed)
	canvas: ^Gpu,        // Canvas: the GPU canvas that is drawn from
	id:     u64,         // Video: the element's key
	owner:  rawptr,      // Video: the page the element is in
	w, h:   int,         // the size of the source, in its pixels
	token:  rawptr,      // the owner's note of what it resolved (for unpin)
}

// What the owner of a GPU canvas provides.
Gpu_Host :: struct {
	user:      rawptr,
	// Makes the target texture of `g` if it has none (size g.w x g.h, g.opaque), then draws the lists. false: it cannot
	// (no device, out of memory): the context goes back to software.
	submit:    proc(user: rawptr, g: ^Gpu) -> bool,
	// Premultiplied sRGB RGBA8 of a block of the canvas (packed rows; outside the canvas: transparent).
	read:      proc(user: rawptr, g: ^Gpu, x, y, w, h: int, out: []u8) -> bool,
	// The texture a source is, for draws recorded now: its handle, whether it holds linear light, and its size in texels.
	// 0: the source cannot be drawn (the draw is dropped).
	resolve:   proc(user: rawptr, s: ^Gpu_Source) -> (tex: i64, linear: bool, size: [2]int),
	// The list that held `s` was submitted or dropped.
	unpin:     proc(user: rawptr, s: ^Gpu_Source),
	// The coverage (0..255, canvas size, rows packed) of clip mask `id` of `g`.
	read_mask: proc(user: rawptr, g: ^Gpu, id: i32, out: []u8) -> bool,
	// Frees the target texture of `g`.
	destroy:   proc(user: rawptr, g: ^Gpu),
	// Changes whenever the device was recreated: every texture lost its contents.
	generation: proc(user: rawptr) -> u64,
}

// Settings of the GPU path (Options.gpu).
Gpu_Options :: struct {
	max_insts:     int,   // instances recorded before the lists are submitted without waiting for a frame
	max_shape_edges: int, // edges one path may have (a larger one is not drawn)
	glyph_cache_entries: int,
	read_penalty:  int,   // score of reads that follow drawing at which the canvas goes back to software (each such read adds 2, each frame shown takes 1 off)
}

DEFAULT_GPU_OPTIONS :: Gpu_Options{max_insts = 200_000, max_shape_edges = 4_000_000, glyph_cache_entries = 4096, read_penalty = 10}
