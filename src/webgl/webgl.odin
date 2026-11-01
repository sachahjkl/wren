package webgl

// WebGL's device side from the browser: the C ABI of native/webgl (in the one Rust static library of wren.exe; the devices are in
// the GPU process, one thread and one wgpu device per context) and its preferences. Everything of the page is in
// src/page/bindings_webgl.odin.

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
// A context with work to do that does nothing for this long ends the GPU process, by default (webgl.gpu_hang_ms). More than
// wait_ms: the page has long been let go by then, and the others lose their contexts with it.
DEFAULT_GPU_HANG_MS :: 30_000
// Ends of the process the browser takes in a window of time before it stops starting another (webgl.gpu_max_restarts).
DEFAULT_GPU_MAX_RESTARTS :: 3
DEFAULT_GPU_RESTART_WINDOW_S :: 60
// A process with no context left goes after this long (webgl.gpu_idle_exit_s).
DEFAULT_GPU_IDLE_EXIT_S :: 60
MS_PER_S :: 1000

// A program started as a GPU process (the same executable with a role argument) is that and nothing else from here on: every
// program that links this package can be one, before its main and anything of the browser is set up. The look at the arguments is
// all it costs the others.
@(init)
gpu_process_role :: proc "contextless" () { wg_process_role() }

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
	wait_ms, hang_ms, max_restarts, restart_window_ms, idle_exit_ms: u32,
	keep_rights: i32,
	notify: proc "c" (user: rawptr),
	notify_user: rawptr,
}
#assert(size_of(Attrs) == 104)

// What the test programs may ask of a GPU process started with the hooks (ipc::test_kind in native/webgl).
TEST_HANG_CONTEXT :: 2

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
	wg_commit :: proc(h: Handle) -> i32 ---
	wg_take_frame :: proc(h: Handle, dst: [^]u8, w, height, stride: u32) -> i32 ---
	wg_busy :: proc(h: Handle) -> i32 ---
	wg_resize :: proc(h: Handle, w, height: u32) ---
	wg_is_lost :: proc(h: Handle) -> i32 ---
	wg_lose :: proc(h: Handle) ---
	wg_restore :: proc(h: Handle) -> i32 ---
	wg_console :: proc(h: Handle, out: [^]u8, cap: uint) -> uint ---
	wg_process_role :: proc() ---
	// Test programs only: no page reaches these, and a process started without the hooks takes one for a broken stream.
	wg_test_enable_hooks :: proc() ---
	wg_test_process_id :: proc() -> u64 ---
	wg_test_process_starts :: proc() -> u64 ---
	wg_test_kill_process :: proc() ---
	wg_test_misbehave :: proc(h: Handle, kind: u32) -> i32 ---
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
	gpu_hang_ms, gpu_max_restarts, gpu_restart_window_ms, gpu_idle_exit_ms: u32,
	gpu_keep_rights: bool,
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
		description = "Most WebGL contexts a page may have at once (each is a thread and a device in the GPU process). Past it the oldest is lost, as other browsers do."},
	{name = "webgl.max_mb", kind = .Int, default = {i = 4096}, bounded = true, min = 16, max = 1 << 20, unit = "MB",
		description = "GPU memory a context may hold in buffers and textures, as counted by the browser. Past it allocating gives OUT_OF_MEMORY to the page."},
	{name = "webgl.wait_ms", kind = .Int, default = {i = DEFAULT_WAIT_MS}, bounded = true, min = 100, max = 600_000, unit = "ms",
		description = "How long the page's thread waits for a context's answer (getError, readPixels, a shader's status). Past it the context is lost: a shader that takes for ever to compile or a hung driver cannot hang the page."},
	{name = "webgl.gpu_hang_ms", kind = .Int, default = {i = DEFAULT_GPU_HANG_MS}, bounded = true, min = 100, max = 600_000, unit = "ms",
		description = "A context with work to do that does nothing for this long (twice that on a software adapter) ends the GPU process: every context of the browser is lost and a new process can restore them. A thread stuck in a driver cannot be freed any other way."},
	{name = "webgl.gpu_max_restarts", kind = .Int, default = {i = DEFAULT_GPU_MAX_RESTARTS}, bounded = true, min = 0, max = 1000,
		description = "How many times the GPU process may end badly within webgl.gpu_restart_window_s before WebGL is off for what is left of that time: a driver that crashes each time should not take the machine's time with it."},
	{name = "webgl.gpu_restart_window_s", kind = .Int, default = {i = DEFAULT_GPU_RESTART_WINDOW_S}, bounded = true, min = 1, max = 86_400, unit = "s",
		description = "The time webgl.gpu_max_restarts counts within."},
	{name = "webgl.gpu_idle_exit_s", kind = .Int, default = {i = DEFAULT_GPU_IDLE_EXIT_S}, bounded = true, min = 0, max = 86_400, unit = "s",
		description = "How long the GPU process stays with no WebGL context left: a page that comes back soon does not pay for its start, the memory of the drivers is given back after. 0: it stays."},
	{name = "webgl.gpu_keep_rights", kind = .Bool, default = {b = false},
		description = "The GPU process keeps the rights it would give up (Windows: Low integrity, privileges, some DLL loading; Linux: new privileges). For a driver that needs them; less protection against a compromised process."},
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
		gpu_hang_ms    = u32(config.int_of(p, "webgl.gpu_hang_ms")),
		gpu_max_restarts = u32(config.int_of(p, "webgl.gpu_max_restarts")),
		gpu_restart_window_ms = u32(config.int_of(p, "webgl.gpu_restart_window_s")) * MS_PER_S,
		gpu_idle_exit_ms = u32(config.int_of(p, "webgl.gpu_idle_exit_s")) * MS_PER_S,
		gpu_keep_rights = config.bool_of(p, "webgl.gpu_keep_rights"),
	}
}
