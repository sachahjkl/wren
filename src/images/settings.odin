package images

import "wb:config"

// Preferences of images (about:config `images.*`): the limits of decoding and how pages load, keep and show images.
// The page package reads them into its Settings; the shell's texture cache reads `images.gpu.*`.

Settings :: struct {
	enabled:           bool,
	limits:            Limits,
	animate:           bool,
	decode_threads:    int,     // -1 = automatic
	downscale:         bool,
	downscale_below:   f32,
	allow_truncated:   bool,
	cache_max_bytes:   int,
	share_cache:       bool,
	max_parallel:      int,
	max_per_page:      int,
	lazy_margin_px:    f32,
	guest_max_bytes:   int,
	gpu_max_bytes:     int,
	background_tiles:  int,
}

PREFS := [?]config.Def{
	{name = "images.enabled", kind = .Bool, default = {b = true},
		description = "Load and show images. Off: <img> elements show their placeholder (or alt text) and CSS images are not fetched."},
	{name = "images.max_encoded_bytes", kind = .Int, default = {i = 64 << 20}, bounded = true, min = 1 << 10, max = 1 << 32, bytes = true, unit = "bytes",
		description = "Largest image file that is downloaded and decoded. Larger ones fail (the element is broken) before any decoding."},
	{name = "images.max_dimension", kind = .Int, default = {i = 32768}, bounded = true, min = 16, max = 1 << 20, unit = "px",
		description = "Widest or tallest image accepted, in image pixels. Checked from the file's header, before any pixel is allocated."},
	{name = "images.max_pixels", kind = .Int, default = {i = 64_000_000}, bounded = true, min = 1 << 10, max = 1 << 34, unit = "pixels",
		description = "Most pixels (width x height) one image may have. Decompression bombs that announce huge dimensions fail here, without allocating."},
	{name = "images.max_frames", kind = .Int, default = {i = 2000}, bounded = true, min = 1, max = 1 << 20, unit = "frames",
		description = "Most frames an animated image may have."},
	{name = "images.max_image_bytes", kind = .Int, default = {i = 512 << 20}, bounded = true, min = 1 << 16, max = 1 << 36, bytes = true, unit = "bytes",
		description = "Most memory the decoded pixels of one image may take, every frame of an animation included."},
	{name = "images.animation.enabled", kind = .Bool, default = {b = true},
		description = "Play animated images (GIF). Off: their first frame is shown."},
	{name = "images.animation.min_delay_ms", kind = .Int, default = {i = 11}, bounded = true, min = 0, max = 10_000, unit = "ms",
		description = "Animation frames meant to last less than this are shown for images.animation.default_delay_ms instead (files often say 0 or 10 ms where they mean \"as fast as reasonable\")."},
	{name = "images.animation.default_delay_ms", kind = .Int, default = {i = 100}, bounded = true, min = 1, max = 60_000, unit = "ms",
		description = "Duration given to animation frames whose delay is under images.animation.min_delay_ms."},
	{name = "images.decode.threads", kind = .Int, default = {i = -1}, bounded = true, min = -1, max = 64, restart = true,
		description = "Threads that decode images, never the interface thread. -1 = half the logical processors, between 1 and 4."},
	{name = "images.decode.downscale", kind = .Bool, default = {b = true},
		description = "Decode an image shown much smaller than its natural size directly at the smaller size (less memory, faster). It is decoded again, larger, if it is later shown larger."},
	{name = "images.decode.downscale_below", kind = .Float, default = {f = 0.5}, bounded = true, min = 0.01, max = 1,
		description = "Reduction factor (shown size / natural size) under which an image is decoded at the reduced size."},
	{name = "images.decode.allow_truncated", kind = .Bool, default = {b = false},
		description = "Show the part of a PNG, GIF or JPEG file that stops before its end. Off: such a file is a broken image (error event)."},
	{name = "images.cache.max_bytes", kind = .Int, default = {i = 512 << 20}, bounded = true, min = 1 << 20, max = 1 << 38, bytes = true, unit = "bytes",
		description = "Memory of the image cache shared by every page: encoded files and decoded pixels. Past it, the least recently shown pixels are dropped (and decoded again when needed), then the files no page uses any more."},
	{name = "images.cache.share_between_pages", kind = .Bool, default = {b = true},
		description = "A page may use an image another page of the same top-level site already downloaded (after its own Content-Security-Policy check) instead of downloading it again."},
	{name = "images.max_parallel_loads", kind = .Int, default = {i = 16}, bounded = true, min = 1, max = 1024,
		description = "Image downloads one page runs at the same time; the others wait, those nearest the viewport first."},
	{name = "images.max_per_page", kind = .Int, default = {i = 20_000}, bounded = true, min = 1, max = 1 << 24,
		description = "Distinct image URLs one page may load. Past it, further images are broken."},
	{name = "images.lazy.margin_px", kind = .Float, default = {f = 1250}, bounded = true, min = 0, max = 100_000, unit = "px",
		description = "An <img loading=lazy> starts loading when it comes within this distance (CSS pixels) of the viewport."},
	{name = "images.guest_decode_max_bytes", kind = .Int, default = {i = 256 << 20}, bounded = true, min = 1 << 10, max = 1 << 34, bytes = true, unit = "bytes",
		description = "Largest RGBA buffer a page's script may obtain from Image_decode (it also counts against page.max_fetch_bytes)."},
	{name = "images.gpu.max_bytes", kind = .Int, default = {i = 512 << 20}, bounded = true, min = 1 << 20, max = 1 << 36, bytes = true, unit = "bytes",
		description = "Video memory the painter keeps for image textures. Past it, the textures not drawn for the longest time are released."},
	{name = "images.background.max_tiles", kind = .Int, default = {i = 4096}, bounded = true, min = 1, max = 1 << 24,
		description = "Most tiles one repeated background image draws in a box; a tiny image repeated over a huge box stops there."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	return Settings{
		enabled = config.bool_of(p, "images.enabled"),
		limits = Limits{
			max_encoded_bytes = int(config.int_of(p, "images.max_encoded_bytes")),
			max_dimension = int(config.int_of(p, "images.max_dimension")),
			max_pixels = config.int_of(p, "images.max_pixels"),
			max_frames = int(config.int_of(p, "images.max_frames")),
			max_image_bytes = config.int_of(p, "images.max_image_bytes"),
			min_delay_ms = int(config.int_of(p, "images.animation.min_delay_ms")),
			default_delay_ms = int(config.int_of(p, "images.animation.default_delay_ms")),
		},
		animate = config.bool_of(p, "images.animation.enabled"),
		decode_threads = int(config.int_of(p, "images.decode.threads")),
		downscale = config.bool_of(p, "images.decode.downscale"),
		downscale_below = f32(config.float_of(p, "images.decode.downscale_below")),
		allow_truncated = config.bool_of(p, "images.decode.allow_truncated"),
		cache_max_bytes = int(config.int_of(p, "images.cache.max_bytes")),
		share_cache = config.bool_of(p, "images.cache.share_between_pages"),
		max_parallel = int(config.int_of(p, "images.max_parallel_loads")),
		max_per_page = int(config.int_of(p, "images.max_per_page")),
		lazy_margin_px = f32(config.float_of(p, "images.lazy.margin_px")),
		guest_max_bytes = int(config.int_of(p, "images.guest_decode_max_bytes")),
		gpu_max_bytes = int(config.int_of(p, "images.gpu.max_bytes")),
		background_tiles = int(config.int_of(p, "images.background.max_tiles")),
	}
}

settings_default :: proc() -> Settings {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	return settings_from_prefs(&p)
}
