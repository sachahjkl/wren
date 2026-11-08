type: Changed

**`flake.nix` builds Wren from the sources**: `nix run git+https://github.com/sachahjkl/wren` and `nix profile add` build it as `wrentool build release` does (submodules, crates vendored from `native/Cargo.lock`, Rust 1.99.1, the pinned Wasmtime and wgpu-native), with the menu entry and the icons, instead of fetching the latest release. `nix flake check` builds it and runs the pre-commit hooks (alejandra, deadnix, statix); `nix fmt` formats. `nix/release.json` and the release job that rewrote it are gone.
