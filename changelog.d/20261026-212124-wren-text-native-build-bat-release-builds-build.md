type: Added

`WREN_TEXT=native build.bat release` builds `build\wren_native.exe`, whose text is shaped by Fontations, HarfRust and ICU4X (the toolkit's native text backend, built into the image decoders' library: one Rust library per program) instead of DirectWrite: the test pages draw the same to within 0.07 % of their pixels, shaping is 2.6 times faster, the exe is 2.2 MB larger.
