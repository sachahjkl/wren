# Portability: Linux (Wayland, X11), then macOS

Where Wren depends on Windows, what is portable already, and the order of the work left. Measured with
`tools\portability.ps1` (`odin check <package> -target:linux_amd64 -no-entry-point` for every package of `src\` and of
the toolkit, the errors counted in the package's own files), and with the unit tests run on Linux (NixOS in WSL, Odin
dev-2026-10, the same flags as `tools\test_all.ps1`).

The counts are lower bounds: Odin stops checking a procedure body once its declarations fail, so a package can show
more errors once the first ones are fixed.

## How a package is made portable

The neutral code calls a small interface of the package; the system's side is in files named for it, which Odin picks
by their suffix: `*_windows.odin`, `*_linux.odin`, `*_unix.odin` (`#+build linux, darwin, freebsd, openbsd, netbsd`),
`*_other.odin` (`#+build !windows` and, on a second line, `#+build !linux` when both are excluded). A test that only
makes sense on one system is `*_test_windows.odin` (not `*_windows_test.odin`: the suffix must end the name).

Shared building blocks, use them rather than a new copy:

| Need | Where |
|---|---|
| Threads with a stack size, name and priority | `host.thread_start` (`thread_windows.odin`, `thread_linux.odin`) |
| Processor count | `host.processor_count` |
| Whole-file and positional I/O, atomic replace, durable rename, directory listing | `base.files` (`file_write_parts`, `file_replace`, `file_read_at`, `file_stat`, `list_files`, `make_dirs`, `file_write_atomic`) |
| Resident and private memory of the process | `base.process_memory` |
| Temporary directory | `base.temp_dir` (TEMP, else the system's) |
| Hashes, HMAC, random bytes, ECDSA P-256, RSA verification | `core:crypto` (no BCrypt) |
| Path separator in built paths | `filepath.SEPARATOR_STRING` |
| Native libraries | `build/<lib>-<os>/...`: `tools/fetch_wasmtime.sh`, `tools/build_lexbor.sh`, `tools/build_native.sh` |

## Inventory (2026-10-27)

Before: the state of `feat/linux` at `da1c927`. After: this branch. "ok" passes `odin check` for Linux; "own n" has n
errors in its own files; "deps" fails only through the packages it imports.

| Package | Before | After | What blocks it | Class |
|---|---|---|---|---|
| base | own 1 | ok | | pure |
| host | own 13 | ok | | small adapter (done) |
| config, css, http, i18n, xml, adblock, canvas2d, license, js/image | ok | ok | | pure |
| dom, url, html, cookies, csp, forms, style, layout, webfont | deps | ok | (Lexbor and the Rust library built for Linux) | pure |
| wasm | own 10 | ok | | small adapter (done) |
| js | own 7 | ok | | small adapter (done) |
| idb | own 27 | ok | | small adapter (done) |
| httpcache | own 23 | ok | | small adapter (done) |
| images | own 78 | ok | WIC only for HEIF and `images.decode.system_codecs` | done (Rust decoders) |
| webauthn | own 39 | ok | no system authenticator on Linux yet (libfido2) | crypto done; libfido2: medium |
| instance | deps | ok | | small adapter (done: flock + Unix socket) |
| desktop | own 4 | ok | Linux integration exists; file watching (inotify) not yet | small adapter |
| remote | own 1 | ok | the server is Windows only (named pipes) | medium (Unix socket server) |
| remote/client | own 47 | own 40 | Conn and spawn (pipes, CreateProcess) | medium |
| blocker | own 26 | deps | fetch, net, page, media | done in its own files |
| page | own 21 | own 6 | `js_web_media.odin` (screen metrics: toolkit), `images.odin`; fetch, net, media | small, after the toolkit's display API |
| media | own 21 | own 21 | Media Foundation, WASAPI (the backend interface exists: `backend_<os>.odin`) | large |
| net, fetch | own 23, 27 | own 23, 27 | WinHTTP: replaced by the Rust network stack (another branch) | (other branch) |
| browser | own 476 | own 457 | the shell: windows, menus, tray, drag and drop, DWM, the D3D11 compositor path | large |
| tools/crashtrace | own 116 | own 116 | dbghelp, SEH | medium (signals + libunwind / backtrace) |
| toolkit/platform | own 2 | own 2 | `Native_Window` (no Linux window yet) | large (Wayland + X11 backend) |
| toolkit/render | own 105 | own 105 | D3D11 / DXGI / DirectComposition; wgpu needs `libwgpu_native.a` for Linux | large (wgpu path only) |
| toolkit/draw, ui | own 3, 9 | own 3, 9 | render, platform | follows render / platform |
| toolkit/base, flate, font | ok | ok | | pure |

In numbers: **24 of 152 packages passed before, 45 after**; of the engine's packages (`src\` without `src\tools`),
**10 of 36 before, 30 after**. Unit tests passing on Linux: base, host, tools/testenv, idb, js, httpcache, wasm (one
thread, as on Windows), remote, desktop, instance, webauthn, url, html, dom, css, style, layout, cookies, csp, forms,
webfont, images (23 of 24: SVG text needs system fonts in the test distribution).

## Order recommended, in slices

1. **Done here**: the engine's core (threads, files, crypto, clocks, Wasm runtime, JavaScript time zone, storage, HTTP
   cache, images, Web Authentication's crypto, one instance per profile), Lexbor, Wasmtime and the Rust library built
   for Linux, `tools\portability.ps1`.
2. **After the network branch lands** (net, fetch on Rust): `page`, `blocker` and every headless tool (`pagetest`,
   `jstest`, `wpt`, `test262`...) follow; the 6 errors of `page` are screen metrics (needs the toolkit's display API)
   and `images.odin`'s use of a Windows-only helper. One slice.
3. **Media on Linux**: `backend_linux.odin` (the five procedures of `backend_windows.odin`): decoding with the Rust
   decoders already linked (rav1d for AV1, image-webp...) plus a Rust H.264 / AAC / Opus decoder, audio through
   PipeWire or PulseAudio (cpal), the null output as on Windows. Two to three slices.
4. **remote and the crash reports**: the remote-control server on a Unix socket (protocol unchanged), `wren ctl`
   spawning with posix_spawn; crashtrace with signal handlers and a symbolizer (backtrace). One slice each.
5. **The toolkit's platform layer** (Wayland first, X11 second): window, input, IME, clipboard, drag and drop,
   cursors, DPI, frame pacing (wp_presentation / present extension), the tray (StatusNotifierItem); render through wgpu
   (Vulkan) only, which needs `libwgpu_native.a` for Linux beside Odin's vendor package. The largest part: four to six
   slices.
6. **The browser shell** (`src\browser`): its Windows calls (menus, tray, DWM, shell integration, drag and drop) move
   behind the toolkit's platform API as it grows. Three to five slices.
7. **Web Authentication on Linux**: libfido2 behind `webauthn.Platform` (security keys over USB HID and NFC). One slice.
8. **Build and CI**: a `build.sh` beside `build.bat`, the Linux CI job widened from `odin check` and the engine's unit
   tests to the headless tools.

macOS after Linux: most of slices 1 and 2 is POSIX already (`*_unix.odin`); `base.process_memory`, the time zone, the
thread priorities and `instance` have a Linux-only file to extend.

## Risks

- `cargo check -p wren_media --profile quick` without NASM on PATH leaves rav1d's build script output without its
  assembly; the next quick build links but misses `dav1d_*_avx2` symbols. Rebuild with `tools\build_native.ps1
  -Profile quick -Force` (after `cargo clean -p rav1d --profile quick`).
- Linux's thread priorities are nice values: lowering one again (the boost on join) needs CAP_SYS_NICE, so it is best
  effort there.
- The Wasm compiled-code cache key is not wrapped by a keyring on Linux (a file readable by its owner only).
- The Wasm unit tests must run on one thread on every system (`-define:ODIN_TEST_THREADS=1`), as `test_all` does: the
  runtime is process-wide.
