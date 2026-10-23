package canvas2d

import "wb:config"

// Preferences of the 2D canvas (about:config `canvas.*`): what a page may ask of it, and how it draws. The page package
// reads them into its Settings.

Settings :: struct {
	enabled:             bool,
	max_dimension:       int,
	max_pixels:          int,
	max_page_bytes:      int,
	max_image_cache_bytes: int,
	max_image_data_bytes: int,
	max_save_depth:      int,
	max_dashes:          int,
	max_layer_bytes:     int,
	max_path_points:     int,
	max_text_bytes:      int,
	samples:             int,
	flatness:            f64,
	jpeg_quality:        f64,
	glyph_cache_entries: int,
	filters:             bool,
	smooth_default:      bool,
}

PREFS := [?]config.Def{
	{name = "canvas.enabled", kind = .Bool, default = {b = true},
		description = "Give pages the 2D canvas (canvas.getContext(\"2d\"), OffscreenCanvas, Path2D, ImageData). Off: getContext returns null, as in a browser without canvas support."},
	{name = "canvas.max_dimension", kind = .Int, default = {i = 16384}, bounded = true, min = 1, max = MAX_SIDE, unit = "px",
		description = "Widest or tallest canvas that gets a bitmap (16384 is what most GPUs take as a texture). A larger one keeps working as a script object, but nothing is drawn on it."},
	{name = "canvas.max_pixels", kind = .Int, default = {i = 67_108_864}, bounded = true, min = 1, max = 1 << 30, unit = "pixels",
		description = "Most pixels (width x height) one canvas may have: 4 bytes each in memory, once more on the GPU while it is shown. A canvas over it gets no bitmap."},
	{name = "canvas.max_page_bytes", kind = .Int, default = {i = 1 << 30}, bounded = true, min = 1 << 20, max = 1 << 36, bytes = true, unit = "bytes",
		description = "Memory all the canvases, ImageBitmaps and patterns of one page may hold together. Past it, new ones get no bitmap."},
	{name = "canvas.image_cache_bytes", kind = .Int, default = {i = 256 << 20}, bounded = true, min = 0, max = 1 << 36, bytes = true, unit = "bytes",
		description = "Premultiplied copies of images kept per page for drawImage and createPattern, so that drawing the same image every frame does not convert its pixels again. The least recently used go first."},
	{name = "canvas.max_image_data_bytes", kind = .Int, default = {i = 256 << 20}, bounded = true, min = 1 << 10, max = 1 << 32, bytes = true, unit = "bytes",
		description = "Largest ImageData a script can make or read back (getImageData, createImageData): 4 bytes per pixel. Larger ones raise a QuotaExceededError."},
	{name = "canvas.max_save_depth", kind = .Int, default = {i = 4096}, bounded = true, min = 1, max = 1_000_000,
		description = "Most states save() keeps on the stack of one context. Further save() calls are ignored (restore() then undoes fewer)."},
	{name = "canvas.max_dashes", kind = .Int, default = {i = 100_000}, bounded = true, min = 16, max = 100_000_000,
		description = "Most pieces one dashed line is cut into. A line that would need more is drawn solid (a pattern of 0.001 px dashes over a long path would never finish)."},
	{name = "canvas.max_path_points", kind = .Int, default = {i = 2_000_000}, bounded = true, min = 1000, max = 1 << 28,
		description = "Most points (line ends and curve control points) one path of a 2D context or Path2D keeps. Segments added past it are ignored."},
	{name = "canvas.max_text_bytes", kind = .Int, default = {i = 1 << 20}, bounded = true, min = 256, max = 1 << 30, bytes = true, unit = "bytes",
		description = "Longest text fillText, strokeText and measureText take (UTF-8 bytes); the rest is cut."},
	{name = "canvas.max_layer_bytes", kind = .Int, default = {i = 256 << 20}, bounded = true, min = 1 << 16, max = 1 << 34, bytes = true, unit = "bytes",
		description = "Largest temporary layer a shadow, a blur or a source-in / copy operator draws through. A shape that needs more is not drawn."},
	{name = "canvas.antialias.samples", kind = .Int, default = {i = 16}, bounded = true, min = 1, max = 64, unit = "per pixel",
		description = "Sub-scanlines per pixel row when filling shapes: coverage is exact along a row and sampled this many times down it. More is smoother on near-horizontal edges and slower; 1 draws aliased shapes."},
	{name = "canvas.flatness", kind = .Float, default = {f = 0.05}, bounded = true, min = 0.001, max = 2, unit = "px",
		description = "How far (device pixels) the straight pieces that replace a curve may stray from it."},
	{name = "canvas.encode.jpeg_quality", kind = .Float, default = {f = 0.92}, bounded = true, min = 0.01, max = 1,
		description = "JPEG quality of toDataURL(\"image/jpeg\") and toBlob when the page gives none (or one outside 0 to 1)."},
	{name = "canvas.text.max_cached_glyphs", kind = .Int, default = {i = 4096}, bounded = true, min = 64, max = 1_000_000,
		description = "Glyph outlines kept for canvas text. The cache is emptied when it reaches this size."},
	{name = "canvas.filters", kind = .Bool, default = {b = true},
		description = "Honor the filter property of the 2D context (blur(), brightness()... and drop-shadow()). Off: the property reads and writes but changes nothing."},
	{name = "canvas.image_smoothing", kind = .Bool, default = {b = true},
		description = "Initial value of imageSmoothingEnabled for new contexts (browsers smooth by default)."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	return Settings{
		enabled = config.bool_of(p, "canvas.enabled"),
		max_dimension = int(config.int_of(p, "canvas.max_dimension")),
		max_pixels = int(config.int_of(p, "canvas.max_pixels")),
		max_page_bytes = int(config.int_of(p, "canvas.max_page_bytes")),
		max_image_cache_bytes = int(config.int_of(p, "canvas.image_cache_bytes")),
		max_image_data_bytes = int(config.int_of(p, "canvas.max_image_data_bytes")),
		max_save_depth = int(config.int_of(p, "canvas.max_save_depth")),
		max_dashes = int(config.int_of(p, "canvas.max_dashes")),
		max_layer_bytes = int(config.int_of(p, "canvas.max_layer_bytes")),
		max_path_points = int(config.int_of(p, "canvas.max_path_points")),
		max_text_bytes = int(config.int_of(p, "canvas.max_text_bytes")),
		samples = int(config.int_of(p, "canvas.antialias.samples")),
		flatness = f64(config.float_of(p, "canvas.flatness")),
		jpeg_quality = f64(config.float_of(p, "canvas.encode.jpeg_quality")),
		glyph_cache_entries = int(config.int_of(p, "canvas.text.max_cached_glyphs")),
		filters = config.bool_of(p, "canvas.filters"),
		smooth_default = config.bool_of(p, "canvas.image_smoothing"),
	}
}

// The drawing options a context is made with.
options_of :: proc(s: ^Settings) -> Options {
	return Options{
		samples = s.samples, flatness = s.flatness, max_states = s.max_save_depth, max_dashes = s.max_dashes,
		max_layer_bytes = s.max_layer_bytes, max_bytes = s.max_layer_bytes, smooth_default = s.smooth_default,
		max_path_points = s.max_path_points, text_bytes = s.max_text_bytes,
		filters = s.filters,
	}
}
