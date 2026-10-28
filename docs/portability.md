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
| Native libraries | `build/<lib>-<os>/...`: `./build.sh deps` (`tools/fetch_wasmtime.sh`, `tools/build_lexbor.sh`, `tools/build_native.sh`) |
| A file: path from a URL, its separator, the tree check | `fetch.file_path_from_url`, `fetch.FILE_SEP_STR`, `fetch.path_within` (POSIX paths off Windows) |
| A Unix socket of this user's only | `remote.socket_dir`, `remote.unix_connect` |
| Starting, telling again and ending a child process | `remote/client`: `process_start`, `identity_of`, `same_process`, `process_wait`, `process_kill` |
| Crash reports | `crashtrace` (`crashtrace_linux.odin`: signals, backtrace, build id; `tools/crash_symbolize.sh`) |

The Wasmtime archive for Linux is sealed by `tools/fetch_wasmtime.sh` (one relocatable object, only the C API's symbols
global): it carries its own copy of Rust's standard library, as `libwren_native.a` does, and GNU ld stops on the symbols
the two share. The Windows archive links as shipped.

## Slice 2 (2026-10-27, later): before / after

Before: master `4c37924` (slice 1 and the Rust network stack merged). After: `feat/linux`.

| | Before | After |
|---|---|---|
| Every package (Wren and the toolkit) passing `odin check` for Linux | 45 / 152 | 78 / 153 |
| The engine's (`src\` without `src\tools`) | 30 / 36 | 35 / 37 (left: `browser`, and `a11y` through the toolkit's platform) |
| Unit tests passing on Linux (`tools/linux_ci.sh`) | 27 packages | 33 packages (+ net, fetch, media, page, blocker, remote/client, tools/crashtrace) |

| Package | Before | After | How |
|---|---|---|---|
| net | own 23 | ok | WinHTTP in `client_winhttp_windows.odin`, `websocket_winhttp_windows.odin`; `winhttp_other.odin`: the Rust stack only |
| fetch | own 27 | ok | `file:` paths POSIX off Windows (`directory_unix.odin`: stat, realpath, readdir; natural name order; dot files hidden) |
| page | own 6 | ok | `screen` from `primary_screen` (Win32; the viewport elsewhere until the toolkit has a display API) |
| blocker, httpcache | deps | ok | (net, fetch, page) |
| media | own 21 | ok | `backend_linux.odin`: AV1 by the built-in rav1d decoder (`av1_soft.odin`) and VP9 by the built-in vp9dec decoder (`vp9_soft.odin`), the null audio output |
| remote/client | own 40 | ok | `conn_linux.odin` (Unix socket), `spawn_linux.odin` (posix_spawn, /proc) |
| remote | ok (no server) | ok, server | `server_linux.odin` on a Unix socket |
| tools/crashtrace | own 116 | ok | `crashtrace_linux.odin` |
| tools/crashmodes, pagetest and most headless tools | deps | ok | (their packages) |

Linux end to end: `tools/crash_e2e.sh` (8 ways of dying, each with its report or an unclean-exit report). Windows after
the slice: the unit tests of every package touched, `nettest` and `wsclosetest` on both stacks, `remote_e2e`,
`crash_e2e`, the dev build.

## Slice 3 (2026-10-27, night): what it adds

The counts do not move (78 / 153; the engine 35 / 37): no package that was blocked passes now — the blocked ones are
`browser` and the toolkit's `platform` / `render`, the shell and the window, a later chantier. Slice 3 fills the
behaviour behind packages that already passed `odin check` for Linux:

- **Audio** (`media`): real sound, not silence. `native/media` gains `audio.rs` (Symphonia for AAC-LC, MP3, FLAC,
  Vorbis, PCM; libopus for Opus) and `aout.rs` (cpal: ALSA, which PipeWire and PulseAudio serve), behind `wm_audio_*`
  and `wm_aout_*`. The Odin side (`audio_decode_rust.odin`, `audio_out_cpal.odin`) wires them to `Audio_Decoder` /
  `Audio_Output`; `backend_linux.odin` picks cpal or the null output by `media.audio.backend`. The new crates are
  target-gated to non-Windows (Opus' C and cpal's ALSA stay out of the Windows build).
- **H.264** (`media`): `h264_linux.odin` decodes through Cisco's **openh264**, `dlopen`ed at run time (never built from
  source: the patent licence covers only Cisco's binaries, `tools/fetch_openh264.sh`), behind `Video_Decoder`.
  `vaapi_linux.odin` probes the GPU's VA-API H.264 support (libva / libva-drm by `dlopen`, a DRM render node) and is
  preferred when `media.h264.backend` allows; the VA-API decode path itself (slice-level) is not written, so it falls
  back to openh264 — the first thing to try under WSL is openh264.
- **Desktop** (`desktop`): `watch_linux.odin` watches the integration directories (applications, icons, `~/.local/bin`)
  with **inotify** (an eventfd to stop, retries when a place is missing). `xdg_linux.odin` centralises the XDG base
  directories. The Linux backend gains a **PATH** part: a symlink in `~/.local/bin` (the "Add to PATH" of Linux).
- **Web Authentication** (`webauthn`): `platform_fido2_linux.odin` reaches USB / NFC security keys through
  **libfido2** (`dlopen`), behind the same `Platform` as Windows' webauthn.dll. Client PINs, on-device user
  verification and hybrid (a phone) are reported unsupported until the toolkit has a prompt.
- **`build.sh`**: a `wren` target with the Linux link flags (`--build-id`, `-lpthread`, `-ldl`, `-lm`, a
  non-executable stack); it links as far as it can and states what still blocks (the toolkit's Linux window and the
  shell).

To try under WSL (NixOS): `cargo build` once (new crates: Symphonia, opus, cpal, libc — `native/Cargo.lock` and
`native/rust-crates.txt` regenerate; symphonia is MPL-2.0, cpal Apache-2.0, libopus BSD-3-Clause); then the unit tests
of `media`, `desktop` and `webauthn` for Linux, a page with `<audio>` / `<video>` (H.264 after
`tools/fetch_openh264.sh`), and a security key for `navigator.credentials`.

## Slice 4 (2026-10-28): the toolkit's Linux window

The toolkit's `platform` package gains a **Linux window backend** — Wayland (xdg-shell, wl_seat with an xkbcommon
keymap, wl_output scale for DPI, zxdg-decoration or a client-side title bar, the CLIPBOARD through wl_data_device) and
X11 (XCB, xkbcommon, Xft.dpi, `_NET_WM_STATE`, Motif hints, the CLIPBOARD selection), chosen at `open_window` from
`WAYLAND_DISPLAY` / `DISPLAY`. Every window library is loaded with **dlopen** (libwayland-client, libxcb, libxkbcommon,
libxkbcommon-x11), so a binary starts on a machine missing one and names it; no window library is hard-linked. The
public `platform` API was made neutral where it leaked Win32 (`wake_handle` now returns an opaque `rawptr`, paired with
`wake_signal`; `native_surface_handles` hands the renderer the Wayland / X11 handles through a neutral
`Surface_Handles`). Services on Linux: the file dialogs through zenity / kdialog (the FileChooser portal is the noted
next step), `open_url` / `open_path` / `reveal_in_folder` through xdg-open, light / dark and reduce-motion from the GTK
settings, the rich clipboard (text through the selection; HTML / image / files kept by the owner). `platform` passes
`odin check` for Linux **and** still for Windows. `ext/gui_toolkit/docs/platform.md` lists what a backend must provide
and the platform differences (Wayland does not expose the window position; GNOME draws no server decorations).

What still blocks the browser executable: the toolkit's **render** package (D3D11 today) needs its **wgpu path built
for Linux** (`libwgpu_native.a`; the surface descriptor is `render/wgpu_surface_linux.odin`, from `Surface_Handles`),
and `src/browser` still calls Win32 directly in places (`windows.odin`'s foreground / client-rect, among others —
`wake_window` was made neutral). The toolkit's `a11y` on Linux (AccessKit's `accesskit_unix`) and drag-and-drop / tray
on Wayland and X11 are not wired yet (the shared `!windows` stubs answer "not supported").

## Media on Linux: decisions

- **AV1**: rav1d (already linked for AVIF), in software, on every system (`av1_soft.odin`); Windows keeps Media
  Foundation and now falls back to the software decoder when MF has no AV1 decoder (`backend_windows.odin`,
  `media.software.av1_fallback`).
- **Audio, next**: `symphonia` (AAC-LC, MP3, FLAC, Vorbis, PCM; pure Rust) for decoding, Opus by libopus (`opus` crate,
  C built by cc: no pure-Rust decoder is mature), `cpal` (ALSA, which PipeWire and PulseAudio serve) for the output, in
  `native/media`, behind `Audio_Decoder` / `Audio_Output`. New crates: pinned, `THIRD_PARTY.md`, `native/rust-crates.txt`.
  WMF / WASAPI stay the Windows default, the Rust path selectable by a preference until parity is measured.
- **H.264**: not in this slice. The choice to make: `openh264` (Cisco's decoder, BSD, built from source by the crate:
  but the patent licence Cisco pays covers only its own binaries, downloaded at run time) or the system's decoders
  (VA-API directly, or GStreamer / FFmpeg, out of scope by the brief). Proposal: VA-API for H.264 / HEVC / VP9 where the
  GPU has it (the Linux counterpart of DXVA), and openh264's downloaded binary as the software fallback, behind a
  preference, the way Firefox does.
- **VP9**: vp9dec (a from-scratch pure-Rust decoder, MIT, no C/FFI), in software, on every system (`vp9_soft.odin`),
  the same way as AV1; Windows falls back to it when Media Foundation has no VP9 decoder (`media.software.vp9_fallback`).
  YouTube serves VP9 for its high resolutions, so this is what plays them on a machine without the VP9 Store extension.
- **VP8**: no pure-Rust decoder is ready; VA-API where the GPU has it, or libvpx (C), is the remaining option.

## Inventory of slice 1 (2026-10-27)

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
| net, fetch | own 23, 27 | own 23, 27 | the Rust network stack (`native/net`, `src/net/rust.odin`) is the default and portable; the WinHTTP backend's calls still sit in `client.odin` / `websocket.odin` | small (move them to `*_windows.odin`, Rust only elsewhere) |
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

0. **Slice 2, done**: net, fetch, page, blocker; the remote channel and `wren ctl` on a Unix socket; crash reports;
   AV1 video; `build.sh`. **Left of slice 2's list**: media audio (symphonia, libopus, cpal) and H.264 (above);
   `desktop`'s file watching by inotify and XDG paths; Web Authentication through libfido2 (loaded with dlopen so that the
   library stays optional); the accessibility of Wren's side (`src/a11y`, blocked by the toolkit's platform).
1. **Done in slice 1**: the engine's core (threads, files, crypto, clocks, Wasm runtime, JavaScript time zone, storage, HTTP
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
- `tools/linux_ci.sh` as a whole takes more than 8 minutes in WSL on a Windows drive (/mnt/s): run it by package
  (`tools/linux_ci.sh odin net fetch ...`) there; the CI runner (native ext4) is well inside its 45 minutes.
- An executable linked without `--build-id` gives crash reports without a build line's id (`build.sh` and
  `tools/crash_e2e.sh` ask for it; the browser's Linux link must too).
- core:sys/linux's `getsockopt` passes the size of the pointer, not of the value: `remote.same_user` calls the system
  call itself.
- The Wasm unit tests must run on one thread on every system (`-define:ODIN_TEST_THREADS=1`), as `test_all` does: the
  runtime is process-wide.
