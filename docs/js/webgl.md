# WebGL

`canvas.getContext("webgl")` and `("webgl2")`: OpenGL ES 2 and 3 for pages, drawn on the GPU through
[wgpu](https://github.com/gfx-rs/wgpu), with shaders translated by a rewrite of GLSL ES in front of
[naga](https://github.com/gfx-rs/wgpu/tree/trunk/naga). A page that never asks pays nothing but the size of the code: the script is
evaluated at the first `getContext` or the first read of an interface, the device is made at the first context, and the
program does not link `d3d12.dll` (wgpu loads it when it is asked to).

Checked: the Three.js examples (a crate, Littlest Tokyo, a Ferrari, shadow maps, particles, bloom, instancing), MapLibre GL JS on
its own site, and a conformance set of ours (`examples/jsweb/webgl.js`, `native/webgl/src/tests.rs`). The `webgl` folder of
web-platform-tests is in `wpt/suites.txt`.

## The layers

| Layer | File | What |
|---|---|---|
| the interfaces | `native/js/odin/web_webgl.js`, `web_webgl.odin` | Web IDL: objects, overloads, conversions; which object is whose. Calls become words in a command buffer. |
| the crossing | `api/webgl.widl`, `src/page/bindings_webgl.odin`, `src/webgl` | A context on its canvas's backing; command buffers, questions, frames. |
| the device | `native/webgl`: `gl.rs`, `draw.rs`, `capture.rs`, `query.rs`, `formats.rs`, `ops.rs` | A thread with a wgpu device per context: OpenGL ES's state machine, all its rules and its errors. |
| the shaders | `native/webgl/src/translate.rs` | GLSL ES to what naga reads, and what WebGL must know of a shader. |

Calls are written to a buffer and sent at the end of the task, when the buffer is full, or when the page has to wait for something
(`getError`, `readPixels`, `getShaderParameter`, `getParameter`). What the realm answers by itself (`isContextLost`,
`getContextAttributes`, `getShaderPrecisionFormat`) crosses nothing. So a frame of a thousand draws is one host call; a
`getError` per draw is a thread's round trip per draw, as in other browsers.

The numbers of operations and the layout of the stream are in `native/webgl/src/ops.rs`, the same as in `web_webgl.js`.

## Why this design

The toolkit draws with Direct3D 11 on Windows and wgpu-native on Linux, and neither can run a page's shaders. ANGLE is not
available. So:

- **One backend for both systems: wgpu**, on a device of its own (Vulkan on a real GPU and Direct3D 12 otherwise on Windows, Vulkan
  on Linux, software adapters where there is no GPU). Only Rust crates are added, built with the one Rust library of `wren.exe`.
- **Own thread per context.** The page's thread never compiles anything and never waits for the GPU except when a page asks for an
  answer, and then with a deadline. A panic, a device lost or a shader that takes for ever to compile loses a context.
- **Frames by the CPU.** A frame is copied to a staging buffer, then into the canvas's bitmap, then to the toolkit's texture: the path
  of a 2D canvas, slow in principle (about 2 ms a frame for 2 megapixels here) and free of any sharing of textures between two
  devices. A shared texture is the way to save that copy, later.

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

## Limits

- **Transform feedback**: needs vertex shaders that write to storage (`VERTEX_WRITABLE_STORAGE`, everywhere Direct3D 12 and Vulkan have it). An adapter
  without it says `MAX_TRANSFORM_FEEDBACK_*` are 0, and `beginTransformFeedback` is `INVALID_OPERATION`. A vertex of the capture runs in a pass of its own: a program's
  vertex stage runs twice when it is also drawn. Strips, fans and loops copy their primitives vertex by vertex, which is slow for many.
- **Queries**: no timers (`EXT_disjoint_timer_query`). `ANY_SAMPLES_PASSED_CONSERVATIVE` is `ANY_SAMPLES_PASSED`.
- **Compressed textures**: S3TC only (`WEBGL_compressed_texture_s3tc`), 2D, where the adapter has BC formats. No ETC, ASTC, RGTC, BPTC.
- **Rendering**: lines are 1 pixel wide. A vertex attribute divisor above 1 is written out, per instance, on each draw count. Points cannot be instanced. `SAMPLE_COVERAGE` is ignored.
  A framebuffer's depth and stencil must be one attachment. Depth blits are whole copies of the same size and samples.
- **Workers**: `getContext("webgl")` on an `OffscreenCanvas` works in a window; in a worker it gives null (the module is `[Exposed=Window]`, and frames and their notices go through a document's canvas: not a small change).
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
  `webgl.wait_ms` (10 s) loses it too, and the thread frees everything when it finally returns.
- What is not bounded: a driver's own bugs and a crash inside a driver or FXC take the browser down: this is in the browser's process, there
  is no GPU process. Windows' TDR turns a shader that hangs the GPU into a device lost. Software adapters have no such thing: their contexts
  lose out at the deadline, and their thread stays until the shader ends.

Microsoft's software rasterizer (WARP) crashes when several devices of a process work at once (seen here): software contexts take turns.

A page's thread that waits for an answer is still running its script: `javascript.slow_script_ms` counts the wait. On a software adapter, where
FXC compiles every pipeline, a page that asks right after a burst of new programs can reach that limit under load.

## Preferences

`webgl.enabled`, `webgl.webgl2`, `webgl.allow_software`, `webgl.force_software`, `webgl.backend` (`auto`, `dx12`, `vulkan`),
`webgl.max_contexts`, `webgl.max_mb`, `webgl.wait_ms`.

## Tests

- `cargo test -p wren_webgl`: the translator, formats, and a context through the C ABI on the software adapter. They pass with `WREN_WEBGL_TEST_GPU=1`
  on a real GPU too. A machine with no adapter skips them.
- `jswebtest webgl` (`examples/jsweb/webgl.js`): the interfaces and their rules on the software adapter; a machine with no adapter checks that
  `getContext` gives null.
- A demo: `examples/site/webgl.html`, in `about:demos`.
