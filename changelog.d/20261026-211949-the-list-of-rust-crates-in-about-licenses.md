type: Fixed

**The list of Rust crates in `about:licenses` includes those of the native text backend** (`tools/rust_crates.ps1` reads the graph with all features: `gt_text`, the optional `text` feature of `native/media` that the release builds with, brings ICU4X (Unicode-3.0), Fontations and HarfRust into `wren.exe`; 108 crates listed before, 141 now). `tools/package.ps1` refused to package with the old list.
