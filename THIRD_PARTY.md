# Third-party components

Wren's own code is MIT licensed ([LICENSE](LICENSE)). `wren.exe` (`build\browser.exe`) statically links the
components below; the release zip carries their license texts in `licenses\`.

| Component | Version | License | Where |
|---|---|---|---|
| [gui_toolkit](https://github.com/sachahjkl/gui_toolkit) | submodule `ext/gui_toolkit` | MIT | window, UI, renderer, text; see its `NOTICE.md` |
| RAD Debugger icon font (`ui/icons.ttf` of gui_toolkit) | | MIT (Epic Games Tools) | toolkit icons |
| Roboto, Inconsolata (gui_toolkit fallback fonts) | | Apache-2.0, SIL OFL 1.1 | used only when Segoe UI / Consolas are missing |
| [Wasmtime](https://github.com/bytecodealliance/wasmtime) C API | 49.0.3 | Apache-2.0 WITH LLVM-exception | `build\wasmtime` (`tools\fetch_wasmtime.ps1`) |
| [Lexbor](https://github.com/lexbor/lexbor) | 3.0.1 | Apache-2.0 | submodule `ext/lexbor` |
| [Public Suffix List](https://publicsuffix.org) | `src/url/public_suffix_list.dat` | MPL-2.0 | embedded |
| [resvg / usvg / tiny-skia](https://github.com/linebender/resvg) | 0.48.1 | Apache-2.0 OR MIT (tiny-skia: BSD-3-Clause) | `native/media` |
| [image-webp](https://github.com/image-rs/image-webp) | 0.2.4 | MIT OR Apache-2.0 | `native/media` |
| [zenavif-parse](https://crates.io/crates/zenavif-parse) | 0.6.2 | MPL-2.0 | `native/media` |
| [rav1d](https://github.com/memorysafety/rav1d) | 1.1.0 | BSD-2-Clause | `native/media` |
| [qcms](https://github.com/FirefoxGraphics/qcms) | 0.3.0 | MIT | `native/media` |
| [brotli-decompressor](https://github.com/dropbox/rust-brotli-decompressor) | 6.1.0 | BSD-3-Clause OR MIT | `native/media` |
| other Rust crates | `native/media/Cargo.lock` | MIT, Apache-2.0, BSD, Zlib, Unicode-3.0… | `licenses\rust-crates.txt` in the release lists each one |

Build-time only (not shipped): [Odin](https://github.com/odin-lang/Odin) (BSD-3-Clause), [NASM](https://www.nasm.us)
2.16.03 (BSD-2-Clause), MSVC, Rust, Go.

Test and demo data: the fonts of `examples/site/fonts` and `native/media/tests/fonts` keep their licenses next to them
(Roboto: Apache-2.0; Fira Code, Noto Sans JP: SIL OFL 1.1; Twemoji graphics: CC-BY 4.0; color font test files:
Apache-2.0 / OFL, see each `*-LICENSE*.txt`).
