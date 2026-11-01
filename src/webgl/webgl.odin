package webgl

// WebGL's device side from the browser: the C ABI of native/webgl (one thread and one wgpu device per context, in the one Rust
// static library of wren.exe) and its preferences. Everything of the page is in src/page/bindings_webgl.odin.

import "wb:config"

when ODIN_OS == .Windows {
	foreign import wren_native {
		"../../build/native/wren_native.lib",
		"system:ws2_32.lib",
		"system:advapi32.lib",
		"system:userenv.lib",
		"system:ntdll.lib",
		"system:kernel32.lib",
		"system:bcrypt.lib",
		"system:msvcrt.lib",
		"system:ucrt.lib",
		"system:libvcruntime.lib",
	}
} else {
	foreign import wren_native { "../../build/native-" + ODIN_OS_STRING + "/libwren_native.a", "system:dl", "system:pthread", "system:m" }
}

// How much of a waiting page's life a context may take when it does not answer, by default (webgl.wait_ms).
DEFAULT_WAIT_MS :: 10_000

Handle :: distinct rawptr

// What wg_take_frame says.
FRAME_NONE :: 0
FRAME_NEW :: 1
FRAME_OPAQUE :: 2   // new, and every alpha is 1

BACKEND_AUTO :: 0
BACKEND_DX12 :: 1
BACKEND_VULKAN :: 2

// wg_create's input: the same layout as WgAttrs in native/webgl/src/lib.rs.
Attrs :: struct #packed {
	webgl2, alpha, depth, stencil, antialias, premultiplied, preserve, fail_if_major_performance_caveat: i32,
	width, height, max_dimension: u32,
	allow_software, force_software: i32,
	backend: i32,
	max_bytes: u64,
	wait_ms: u32,
	_pad1: u32,
	notify: proc "c" (user: rawptr),
	notify_user: rawptr,
}
#assert(size_of(Attrs) == 88)

// What wg_create learned: the same layout as WgInfo.
Info :: struct {
	software, has_s3tc, has_float_linear, has_float_blend: i32,
	max_samples, width, height: u32,
	antialias: i32,
}

@(default_calling_convention = "c")
foreign wren_native {
	wg_create :: proc(attrs: ^Attrs, info: ^Info, err: [^]u8, err_cap: uint, err_len: ^uint) -> Handle ---
	wg_destroy :: proc(h: Handle) ---
	wg_submit :: proc(h: Handle, a: [^]u8, an: uint, b: [^]u8, bn: uint) ---
	wg_query :: proc(h: Handle, req: [^]u8, n: uint, out: [^]u8, cap: uint) -> i64 ---
	wg_present :: proc(h: Handle) ---
	wg_snapshot :: proc(h: Handle) -> i32 ---
	wg_take_frame :: proc(h: Handle, dst: [^]u8, w, height, stride: u32) -> i32 ---
	wg_busy :: proc(h: Handle) -> i32 ---
	wg_resize :: proc(h: Handle, w, height: u32) ---
	wg_is_lost :: proc(h: Handle) -> i32 ---
	wg_lose :: proc(h: Handle) ---
	wg_restore :: proc(h: Handle) -> i32 ---
	wg_console :: proc(h: Handle, out: [^]u8, cap: uint) -> uint ---
}

Settings :: struct {
	enabled:        bool,
	webgl2:         bool,
	allow_software: bool,
	force_software: bool,
	backend:        i32,       // BACKEND_*
	max_contexts:   int,
	max_bytes:      u64,
	wait_ms:        u32,
}

WEBGL_PREFS := [?]config.Def{
	{name = "webgl.enabled", kind = .Bool, default = {b = true},
		description = "WebGL: canvas.getContext(\"webgl\") and (\"webgl2\"). Off: getContext gives null and the interfaces read as undefined, what a script tests for."},
	{name = "webgl.webgl2", kind = .Bool, default = {b = true},
		description = "WebGL 2 (GLSL ES 3.00, uniform blocks, 3D textures). Off: getContext(\"webgl2\") gives null, WebGL 1 stays."},
	{name = "webgl.allow_software", kind = .Bool, default = {b = true},
		description = "Without a GPU, draw on the system's software rasterizer (WARP on Windows, lavapipe on Linux). Slow, and for most pages better than nothing. Off: getContext gives null there."},
	{name = "webgl.force_software", kind = .Bool, default = {b = false},
		description = "Draw on the software rasterizer even with a GPU (for tests)."},
	{name = "webgl.backend", kind = .String, default = {s = "auto"}, choices = {"auto", "dx12", "vulkan"},
		description = "Windows: what WebGL draws through. auto: Vulkan on a real GPU that has it (shaders compile much sooner), else Direct3D 12. dx12, vulkan: that one first."},
	{name = "webgl.max_contexts", kind = .Int, default = {i = 16}, bounded = true, min = 1, max = 256,
		description = "Most WebGL contexts a page may have at once (each is a thread and a device). Past it the oldest is lost, as other browsers do."},
	{name = "webgl.max_mb", kind = .Int, default = {i = 4096}, bounded = true, min = 16, max = 1 << 20, unit = "MB",
		description = "GPU memory a context may hold in buffers and textures, as counted by the browser. Past it allocating gives OUT_OF_MEMORY to the page."},
	{name = "webgl.wait_ms", kind = .Int, default = {i = DEFAULT_WAIT_MS}, bounded = true, min = 100, max = 600_000, unit = "ms",
		description = "How long the page's thread waits for a context's answer (getError, readPixels, a shader's status). Past it the context is lost: a shader that takes for ever to compile or a hung driver cannot hang the page."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, WEBGL_PREFS[:]) }

settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	backend: i32 = BACKEND_AUTO
	switch config.string_of(p, "webgl.backend") {
	case "dx12": backend = BACKEND_DX12
	case "vulkan": backend = BACKEND_VULKAN
	}
	return Settings{
		backend        = backend,
		enabled        = config.bool_of(p, "webgl.enabled"),
		webgl2         = config.bool_of(p, "webgl.webgl2"),
		allow_software = config.bool_of(p, "webgl.allow_software"),
		force_software = config.bool_of(p, "webgl.force_software"),
		max_contexts   = int(config.int_of(p, "webgl.max_contexts")),
		max_bytes      = u64(config.int_of(p, "webgl.max_mb")) << 20,
		wait_ms        = u32(config.int_of(p, "webgl.wait_ms")),
	}
}
