# Third-party components

Wren's own code is under the PolyForm Strict License 1.0.0 ([LICENSE](LICENSE); versions up to 0.3.0 stay MIT). Its `gui_toolkit` is a separate project and stays MIT. `wren.exe` (`build\wren.exe`) statically links the
components below; their license texts are in the executable (bout:licenses) and in the repository.

| Component | Version | License | Where |
|---|---|---|---|
| [gui_toolkit](https://github.com/sachahjkl/gui_toolkit) | submodule `ext/gui_toolkit` | MIT | window, UI, renderer, text; see its `NOTICE.md` |
| [Slug](https://github.com/EricLengyel/Slug) shaders and algorithm (Eric Lengyel), in gui_toolkit's `render/slug.wgsl` (WGSL, the one source; the Direct3D 11 backend embeds the HLSL that naga, a build tool, writes from it) | commit `be3c13eb7d63f9e8aa5c583e42d92c374cb91d98` (`ext/gui_toolkit/font/slug_ref`) | MIT (also Apache-2.0); the patent is in the public domain since 2026-03-17 | optional text renderer (`text.renderer` = `slug`); credit required, text in `licenses\Slug-LICENSE-MIT.txt` |
| RAD Debugger icon font (`ui/icons.ttf` of gui_toolkit) | | MIT (Epic Games Tools) | toolkit icons |
| Roboto, Inconsolata (gui_toolkit fallback fonts) | | Apache-2.0, SIL OFL 1.1 | used only when Segoe UI / Consolas are missing |
| [Noto Color Emoji](https://github.com/googlefonts/noto-emoji) (COLR v1, Google) | Emoji 18, Google Fonts' build, commit `142c8963e7606b510c93a644c82a4c4cdeae6ef9` of `google/fonts`; the file without its OT-SVG table (`tools\fetch_emoji.ps1` pins both SHA-256) | SIL OFL 1.1 | the built-in emoji (`text.emoji` = `builtin`): `build\emoji`, shipped as `emoji\NotoColorEmoji-COLRv1.ttf`; text in `licenses\NotoColorEmoji-OFL.txt` |
| [Unicode emoji data](https://www.unicode.org/Public/18.0.0/ucd/emoji/emoji-data.txt) (`emoji-data.txt`) | 18.0.0 | Unicode License v3 | which characters are emoji (generated `font/emoji_data.odin` of gui_toolkit) |
| [Wasmtime](https://github.com/bytecodealliance/wasmtime) C API | 49.0.3 | Apache-2.0 WITH LLVM-exception | `build\wasmtime` (`tools\fetch_wasmtime.ps1`) |
| [QuickJS-ng](https://github.com/quickjs-ng/quickjs) | 0.17.0, patched (`native/js/patches`) | MIT | the JavaScript engine, compiled to WebAssembly (`tools\build_js.ps1`) and embedded |
| [wasi-libc](https://github.com/WebAssembly/wasi-libc), as shipped by Zig 0.15.2 | | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT; parts: musl (MIT), cloudlibc (BSD-2-Clause), emmalloc (MIT / NCSA, Emscripten) | the C library of the JavaScript engine module |
| [webref](https://github.com/w3c/webref) `@webref/idl` | 3.85.2 (`native/js/webref/VERSION`) | MIT | the Web IDL the JavaScript bindings are generated from (`native/js/gen`) |
| [Lexbor](https://github.com/lexbor/lexbor) | 3.0.1 | Apache-2.0 | submodule `ext/lexbor` |
| [Public Suffix List](https://publicsuffix.org) | `src/url/public_suffix_list.dat` | MPL-2.0 | embedded |
| [resvg / usvg / tiny-skia](https://github.com/linebender/resvg) | 0.48.1 | Apache-2.0 OR MIT (tiny-skia: BSD-3-Clause) | `native/media` |
| [image-webp](https://github.com/image-rs/image-webp) | 0.2.4 | MIT OR Apache-2.0 | `native/media` |
| [zenavif-parse](https://crates.io/crates/zenavif-parse) | 0.6.2 | MPL-2.0 | `native/media` |
| [rav1d](https://github.com/memorysafety/rav1d) | 1.1.0 | BSD-2-Clause | `native/media` |
| [qcms](https://github.com/FirefoxGraphics/qcms) | 0.3.0 | MIT | `native/media` |
| [brotli-decompressor](https://github.com/dropbox/rust-brotli-decompressor) | 6.1.0 | BSD-3-Clause OR MIT | `native/media` |
| other Rust crates (with those of the toolkit's text backend and accessibility adapter) | `native/Cargo.lock` | MIT, Apache-2.0, BSD, Zlib, Unicode-3.0… | `native/rust-crates.txt` (also in `about:licenses`) lists each one |

The license texts of QuickJS-ng, wasi-libc and its parts, and webref are kept in
[`native/js/licenses`](native/js/licenses).

Build-time only (not shipped): [Odin](https://github.com/odin-lang/Odin) (BSD-3-Clause), [Zig](https://ziglang.org)
0.15.2 (MIT), [NASM](https://www.nasm.us) 2.16.03 (BSD-2-Clause), MSVC, Rust, Go.

Tests only (fetched at a pinned commit into `build\`, not shipped): [test262](https://github.com/tc39/test262)
(BSD-3-Clause) and [web-platform-tests](https://github.com/web-platform-tests/wpt) (BSD-3-Clause); `wpt/` holds the
list of folders Wren runs, their manifest and Wren's expectations.

Test and demo data: the fonts of `examples/site/fonts` and `native/media/tests/fonts` keep their licenses next to them
(Roboto: Apache-2.0; Fira Code, Noto Sans JP: SIL OFL 1.1; Twemoji graphics: CC-BY 4.0; color font test files:
Apache-2.0 / OFL, see each `*-LICENSE*.txt`).
