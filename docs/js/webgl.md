# WebGL

`canvas.getContext("webgl")` and `("webgl2")`: OpenGL ES 2 and 3 for pages, drawn on the GPU through
[wgpu](https://github.com/gfx-rs/wgpu), with shaders translated by a rewrite of GLSL ES in front of
[naga](https://github.com/gfx-rs/wgpu/tree/trunk/naga). A page that never asks pays nothing but the size of the code: the script is
evaluated at the first `getContext` or the first read of an interface, the GPU process is started once a page has shown its first content
(`webgl.gpu_start_ahead`; off: by the first context of the browser), and the program does not link `d3d12.dll` (wgpu loads it when it is
asked to, in that process).

Checked: the Three.js examples (a crate, Littlest Tokyo, a Ferrari, shadow maps, particles, bloom, instancing), MapLibre GL JS on
its own site, and a conformance set of ours (`examples/jsweb/webgl.js`, `native/webgl/src/tests.rs`). The `webgl` folder of
web-platform-tests is in `wpt/suites.txt`.

## The layers

| Layer | File | What |
|---|---|---|
| the interfaces | `native/js/odin/web_webgl.js`, `web_webgl.odin` | Web IDL: objects, overloads, conversions; which object is whose. Calls become words in a command buffer. |
| the crossing | `api/webgl.widl`, `src/page/bindings_webgl.odin`, `src/webgl` | A context on its canvas's backing; command buffers, questions, frames. |
| the process | `native/webgl`: `parent.rs` (browser), `child.rs` (GPU process), `ipc/` | Starts, watches and ends the GPU process; what crosses, checked on both sides. |
| the device | `native/webgl`: `host.rs`, `gl.rs`, `draw.rs`, `capture.rs`, `query.rs`, `formats.rs`, `ops.rs` | In the GPU process, a thread with a wgpu device per context: OpenGL ES's state machine, all its rules and its errors. |
| the shaders | `native/webgl/src/translate.rs` | GLSL ES to what naga reads, and what WebGL must know of a shader. |

Calls are written to a buffer and sent at the end of the task, when the buffer is full, or when the page has to wait for something
(`getError`, `readPixels`, `getShaderParameter`, `getParameter`). What the realm answers by itself (`isContextLost`,
`getContextAttributes`, `getShaderPrecisionFormat`) crosses nothing. So a frame of a thousand draws is one host call; a
`getError` per draw is a round trip to another process per draw, as in other browsers.

The numbers of operations and the layout of the stream are in `native/webgl/src/ops.rs`, the same as in `web_webgl.js`.

## Why this design

The toolkit draws with Direct3D 11 on Windows and wgpu-native on Linux, and neither can run a page's shaders. ANGLE is not
available. So:

- **One backend for both systems: wgpu**, on a device of its own (Vulkan on a real GPU and Direct3D 12 otherwise on Windows, Vulkan
  on Linux, software adapters where there is no GPU). Only Rust crates are added, built with the one Rust library of `wren.exe`.
- **A process of its own, a thread per context in it.** The page's thread never compiles anything and never waits for the GPU except when a
  page asks for an answer, and then with a deadline. A panic, a device lost or a shader that takes for ever to compile loses a context; a
  crash in a driver or FXC, or a thread that cannot come back, loses every context and nothing else ([the GPU process](#the-gpu-process)).
- **Frames by the CPU.** A frame is copied to a staging buffer, then into the shared section of its canvas, then into the canvas's bitmap,
  then to the toolkit's texture: the path of a 2D canvas, slow in principle (about 2 ms a frame for 2 megapixels here) and free of any
  sharing of textures between two devices. A shared texture is the way to save that copy, later.

### What wgpu has not, and what stands for it

| GL | Here |
|---|---|
| state changes between draws | a cache of pipelines per program, by the state that makes them |
| writes between draws | what the open encoder used is written through the encoder (buffers) or after a submit (textures) |
| uniforms | a block per stage (std140) kept by the context, copied per draw into a ring with dynamic offsets |
| window coordinates | framebuffers hold their bottom row first: the vertex shader negates y, front faces swap; a canvas is flipped when shown, and textures rendered to read back as GL says |
| clip z from -w to w | rewritten at the end of the vertex shader |
| `gl_PointSize`, `gl_PointCoord` | a variant of the vertex shader draws each point as an instanced quad (made on the first draw of points) |
| triangle fans, line loops, byte indices | indices generated into the ring |
| vertex formats wgpu lacks, strides that are not multiples of 4 | converted once per buffer version |
| RGB, luminance, alpha, 16-bit packed textures | expanded to RGBA on upload |
| incomplete textures | a fallback texture of opaque black |
| `generateMipmap`, scaled blits, clears with a mask or scissor | drawn |
| transform feedback | a variant of the vertex stage stores its varyings in storage buffers, in a pass of its own (`capture.rs`) |
| occlusion queries of GL, which last across passes | an occlusion slot per pass they cross, resolved at each submit; the result is any of them |
| a vertex attribute divisor above 1 | the values written out per instance |

### Shaders

naga's GLSL front end reads Vulkan-flavoured GLSL 450: it has the type checker and the lowering, it does not read GLSL ES. After the
preprocessor (pp-rs, naga's own), `translate.rs` rewrites the token stream: no expression is parsed, only declarations.

- attributes and varyings get locations (decided at link: a shader is translated again then);
- default uniforms go into a block per stage; structures, global constants and uniforms are hoisted above the code;
- a sampler becomes a texture and a sampler, `texture2D(map, uv)` becomes `texture(sampler2D(map_t, map_s), uv)`, and a sampler
  passed to a function two parameters. An array of samplers takes a constant index, as GLSL ES 1.00 and 3.00 require;
- `bool` and matrices of two rows, which uniforms cannot hold, are held as `uint` and `vec4` and copied to a private variable when `main`
  starts; matrices as attributes and varyings become their columns;
- `modf` and `matrixCompMult`, which naga has not, are written into shaders that name them.

`getActiveUniform` and friends come from what was declared; offsets from naga's module. What naga does not check is not checked:
implicit conversions from `int` to `float` compile, and the loop restrictions of GLSL ES 1.00 are not enforced.

## The GPU process

One per browser: the same executable, started with `--wren-gpu-process=<handles>`. (A package initializer of `src/webgl` looks at the
arguments before `main`, so any program that links the browser can be one. It costs that look. Tests: `src/tools/e2e/webgl_process.odin`.)
A process with no context left goes after `webgl.gpu_idle_exit_s`.

**Made ahead.** A page's thread waits for its `getContext`: for a process to start (about 200 ms on a desktop with a GPU) and for a
device to be made in it (70 ms; a quarter of it the context's own shaders). So both are made before a page asks:

- the browser starts the process when a page has shown its first content (`webgl.gpu_start_ahead`, on by default), on a thread of its own, with the
  attributes a context would have (`wg_start_ahead`): the page's thread never waits for it. Nothing when a process runs, or when one ended
  badly within `webgl.gpu_restart_window_s`: a restart is for a page that asks. Off: the first context of the browser starts it, and a
  browser that sees no WebGL starts nothing;
- the process holds the next context's device, made on a thread of its own (`native/webgl/src/spare.rs`, a state machine: empty, being
  made, ready): after its start (`Prepare`), and after each context that took one. A context waits for the one being made rather than
  make a second; one made for other preferences (`webgl.force_software`, `webgl.backend`) is dropped. Not on a software adapter, where
  devices are made in turns and a context's first messages would wait for one nobody may ask for.

What a page sees does not change: `getContext` still answers once its device exists, null when there is none, with the same
attributes and extensions; `getError`, `readPixels` and `getParameter` are the device's answers as before. On npr.org a script asks for
four contexts after the load event, two in `OffscreenCanvas` (one in a worker): 380 ms of the window thread before, X after
([round 60](../performance.md#what-changed-round-60-webgl-contexts-made-ahead)).

| What crosses | How |
|---|---|
| commands, questions, answers | two byte rings (16 MiB each way) in one section of shared memory; a message longer than a ring goes through in pieces as the reader takes them. A reader spins a little, then sleeps; a doorbell wakes it |
| frames | a section per canvas with three pictures: the child fills one and swaps it with the one published, the browser swaps that with the one it holds. Neither ever waits for the other, and the bitmap's copy is the same as before the process existed |
| the end of the other side | the doorbell: on Windows an event and the other process's handle, on Linux a socket pair, whose end is the end of the stream |
| sections | made by the browser. Windows: a handle duplicated into the child, with rights to map it only. Linux: a sealed memfd (a child that could shrink it would make the browser fault on a copy), its descriptor passed over a second socket |

**When it goes wrong.** A process that ends, a process that breaks the protocol, a context with work to do that does nothing for
`webgl.gpu_hang_ms` (twice that on a software adapter: FXC is slow there, and one hung context costs them all) or a ring nobody takes from: the
process is killed, every context of the browser gets `webglcontextlost`, and a page that prevented its default gets `webglcontextrestored` once
a new process has given it a device. A question keeps its deadline (`webgl.wait_ms`): the context that does not answer is lost at once, and the
watcher kills the process if its thread does not come back; no thread is left behind. More than `webgl.gpu_max_restarts` bad ends within
`webgl.gpu_restart_window_s`: `getContext` gives null and contexts stay lost, until that time has passed. A crash there writes no crash report of
Wren's (the handler is installed by the browser's `main`, which the process never reaches): the page's console says how it ended, with the exit code.

**It ends with its parent, even a killed one.** Windows: a Job object with `KILL_ON_JOB_CLOSE` named at the process's creation
(`PROC_THREAD_ATTRIBUTE_JOB_LIST`, so that no moment exists when a child is outside it; started suspended and assigned afterwards, a parent killed
in between left suspended orphans), and the child watches the parent's handle too. Linux: `PR_SET_PDEATHSIG` set by a thread that lives as long
as the child (the signal follows the thread, not the process), and the socket's end.

**What the child gives up**, before any driver is loaded (`webgl.gpu_keep_rights` keeps it all, for a driver that needs it):

| | Done | Not done, and why |
|---|---|---|
| Windows | Low integrity (no writing to what the user's programs own, no opening their processes; a driver's shader cache under the user's profile is not written); every privilege removed; a job that allows no other process, no clipboard, no desktops, no display settings, no global atoms, no handles of other processes' windows; no extension points (AppInit DLLs, hooks); no images from the network or of Low label; no DLL search in the working directory, which is the program's own folder; only the handles it needs are inherited; no error dialogs | An AppContainer or a restricted token (a driver opens registry keys, files and kernel objects no list here could name); Win32k lockdown and no dynamic code (drivers need GDI, and compile shaders to machine code); the network |
| Linux | `PR_SET_NO_NEW_PRIVS`; no core dumps; every descriptor closed but its own | seccomp, namespaces, Landlock (drivers open `/dev/dri` and `/sys`, read caches, call ioctls no list here could name); the network. The environment stays, for what drivers read from it |

**Nothing that crosses is believed.** The child ends on an unknown kind, a length past its kind's limit or an index that cannot be true; refuses attributes
that cannot be; ignores contexts it does not know; the commands themselves are checked word by word (`Ctx::exec`). The browser kills it for the same, for a
context or a question that was never asked, a count of finished work that does not add up, rows of pixels that do not fit or overflow, a frame larger than its
section or a slot that does not exist; an answer larger than the asker's buffer is not kept, so that a length costs the browser no memory the page did not offer. Everything in
shared memory is copied out before it is looked at.

**The cost**, measured on `examples/site/webgl.html` and `examples/site/webgl-stress.html` with `wrentool bench webgl` (the same pages, before and after, alternating, the best of the runs):

| | before | after |
|---|---|---|
| `webgl.html`, frames a second | 60 | 60 |
| stress page (5000 draws a frame, 1920 x 1080), frames a second | 17.5 | 17.9 |
| its script's time per frame | 40 ms | 36 ms |
| the browser's first context (the process starts with it) | 249 ms | 264 ms |
| a later context | 133 ms | 112 ms |
| `getError` (a round trip) | 23 us | 21 us |
| `readPixels`, one pixel | 0.16 ms | 0.18 ms |
| `readPixels`, 8 MB | 8.2 ms | 9.8 ms |
| `texImage2D`, 4096 x 4096 (64 MB), with `finish` | 54 ms | 48 ms |
| `bufferData`, 64 MB, with `finish` | 41 ms | 47 ms |
| working set on `webgl.html` (browser + process) | 465 MB | 187 + 334 MB |
| on the stress page | 727 MB | 407 + 482 MB |
| a page without WebGL | no process | no process (since round 60, by default: a process with one device, made ahead; `webgl.gpu_start_ahead`) |

On a machine (RTX 4070 SUPER, 16 logical processors) that other jobs were using: differences of a few percent mean nothing here. What can be told: frames cost the same, since a frame takes the same copies; large messages pay one copy more through a ring; the memory grows by what a second process has (its copy of the runtime's data and of the drivers' loaded state, its rings, a canvas's three pictures: about 55 MB on `webgl.html`, 160 MB on the stress page, of which the shared memory is counted on both sides).

## Workers

`OffscreenCanvas.getContext("webgl")` and `("webgl2")` work in a worker as in a window, their interfaces evaluated when first read there. What a page has with a
context, a worker has: questions, shaders, lost and restored. `requestAnimationFrame` is the worker's 60 Hz clock.

- `transferToImageBitmap()` asks for the drawing buffer (it waits, as `readPixels` does) and the frame ends: the buffer starts again as after a present.
- An OffscreenCanvas no element shows makes no frames by itself: its pixels are fetched when it is read (`convertToBlob`, `transferToImageBitmap`, `drawImage`).
- `canvas.transferControlToOffscreen()` makes the element a placeholder, and the OffscreenCanvas transferable in a message (`Canvas_Placeholder`, `src/page/canvas_offscreen.odin`).
  What it draws, WebGL or 2D, is copied at the end of each turn of its thread's loop into the placeholder, and from there into the element's bitmap by the page's thread: from a section to the
  worker's bitmap, then the placeholder, then the element's bitmap. Two copies more than a canvas of the page, one of them on the worker's thread (below 2 ms each for 2 megapixels).
- Not done: the layout of a placeholder keeps following its `width` and `height` attributes, not the size the worker chooses (the picture is scaled to fit), and setting those on a placeholder does not throw. `ImageBitmap` is still not transferable in a message.

## Limits

- **Transform feedback**: needs vertex shaders that write to storage (`VERTEX_WRITABLE_STORAGE`, everywhere Direct3D 12 and Vulkan have it). An adapter
  without it says `MAX_TRANSFORM_FEEDBACK_*` are 0, and `beginTransformFeedback` is `INVALID_OPERATION`. A vertex of the capture runs in a pass of its own: a program's
  vertex stage runs twice when it is also drawn. Strips, fans and loops copy their primitives vertex by vertex, which is slow for many.
- **Queries**: no timers (`EXT_disjoint_timer_query`). `ANY_SAMPLES_PASSED_CONSERVATIVE` is `ANY_SAMPLES_PASSED`.
- **Compressed textures**: S3TC only (`WEBGL_compressed_texture_s3tc`), 2D, where the adapter has BC formats. No ETC, ASTC, RGTC, BPTC.
- **Rendering**: lines are 1 pixel wide. A vertex attribute divisor above 1 is written out, per instance, on each draw count. Points cannot be instanced. `SAMPLE_COVERAGE` is ignored.
  A framebuffer's depth and stencil must be one attachment. Depth blits are whole copies of the same size and samples.

- **Videos** are textures when their picture is on the CPU (software decoding); a picture only on the GPU uploads nothing.
- **`gl.getError` from a Wasm module of a page**: as JavaScript's; a malformed stream loses the context.
- **Objects collected**: buffers, textures and programs a page drops without deleting stay until the page or the context goes.

## Security

Shaders and draws come from any page.

- `drawArrays` and `drawElements` check every attribute against its buffer, and every index against the vertices (a scan, kept per range
  until the buffer changes): out of range is `INVALID_OPERATION`, never a read. wgpu checks the same on its side, and zeroes buffers and
  textures on creation.
- Sizes and counts are limited: `canvas.max_dimension`, `webgl.max_mb` per context, `webgl.max_contexts` per page.
- A cross-origin image or a tainted canvas in `texImage2D` throws `SecurityError`.
- `WEBGL_debug_renderer_info` is left out; `RENDERER` says `Wren WebGL`.
- The translator bounds the source (2 MiB), the tokens after macro expansion, nesting, operators per statement, `else` per function and the
  size of types: naga recurses, and its thread has a stack of 256 MiB. Each of these limits has a hostile test
  (`a_hostile_shader_is_an_error_in_the_log`). A panic in naga or wgpu loses the context; a question that gets no answer in
  `webgl.wait_ms` (10 s) loses it too.
- A driver's own bugs, a crash inside a driver or FXC: they end the GPU process, and every context of the browser is lost
  ([the GPU process](#the-gpu-process)). A page that can crash a driver can do so again, and costs other pages their contexts each time, up to
  `webgl.gpu_max_restarts`. Windows' TDR turns a shader that hangs the GPU into a device lost. Software adapters have no such thing: their contexts lose out at the
  deadline, and the process is killed when the thread has not come back at twice `webgl.gpu_hang_ms`.
- What the GPU process can reach if a driver is compromised through a shader is what the table above leaves it: on both systems it can read what the user can and
  use the network.

Microsoft's software rasterizer (WARP) crashes when several devices of a process work at once (seen here): software contexts take turns, in the GPU process.

A page's thread that waits for an answer is still running its script: `javascript.slow_script_ms` counts the wait. On a software adapter, where
FXC compiles every pipeline, a page that asks right after a burst of new programs can reach that limit under load.

## Preferences

`webgl.enabled`, `webgl.webgl2`, `webgl.allow_software`, `webgl.force_software`, `webgl.backend` (`auto`, `dx12`, `vulkan`),
`webgl.max_contexts`, `webgl.max_mb`, `webgl.wait_ms`, `webgl.gpu_hang_ms`, `webgl.gpu_max_restarts`, `webgl.gpu_restart_window_s`,
`webgl.gpu_idle_exit_s`, `webgl.gpu_keep_rights`, `webgl.gpu_start_ahead` (the tests' browsers have it off unless they ask).

## Tests

- `cargo test -p wren_webgl`: the translator, formats, and a context through the C ABI on the software adapter. They pass with `WREN_WEBGL_TEST_GPU=1`
  on a real GPU too. A machine with no adapter skips them.
  `src/ipc_tests.rs`: the channel on its own; a real child killed while drawing, hung, stalled, made hostile in each way the browser checks for, fed malformed commands and broken streams; its
  parent killed; the limit on restarts. A test binary is its own child (`gpu_child_entry`); a hook is accepted only by a child started with hooks, which a browser never asks for.
- the web test `jsweb_webgl_api` (`examples/jsweb/webgl.js`): the interfaces and their rules on the software adapter; contexts in workers and `transferControlToOffscreen`. A machine with no adapter checks that `getContext` gives null.
- `src/tools/e2e/webgl_process.odin` (in `test_all`): the process's life in the real browser, on the machine's GPU: its id is a number of `api.Stats`, and it is killed and suspended from outside under a page, its contexts and a worker's. `wrentool smoke` does the same under xvfb on Linux.
- `wrentool bench webgl`: what WebGL costs on this machine (opt-in, not a test).
- Demos: `examples/site/webgl.html` and `webgl-stress.html`, in `about:demos`.
