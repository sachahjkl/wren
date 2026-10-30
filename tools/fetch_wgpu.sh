#!/usr/bin/env bash
# Downloads wgpu-native for Linux (the release Odin's vendor:wgpu is written for, SHA-256 checked) and puts it where that
# package looks for it: $(odin root)/vendor/wgpu/lib/wgpu-linux-x86_64-release/lib/libwgpu_native.a. Needed to link
# src/browser (toolkit:render draws through wgpu on Linux).
# Usage: tools/fetch_wgpu.sh [--force]      ODIN: the compiler (default: odin on PATH)
# To move to another release: change VERSION and SHA256 (the digest of wgpu-linux-x86_64-release.zip), as Odin's own
# vendor/wgpu/wgpu.odin names the version it expects.
set -euo pipefail
VERSION=v29.0.1.1
case "$(uname -m)" in
  x86_64) ARCH=x86_64; SHA256=95a4d90c071005a98d03eab348beaa6b07e16eb00d1dcdb9f8348f75eb97ec5a ;;
  *) echo "no wgpu-native release pinned for $(uname -m)" >&2; exit 1 ;;
esac
ODIN="${ODIN:-odin}"
ROOT="$("$ODIN" root)"
DEST="$ROOT/vendor/wgpu/lib/wgpu-linux-$ARCH-release/lib"
if ! grep -q "releases/tag/$VERSION" "$ROOT/vendor/wgpu/wgpu.odin" 2>/dev/null; then
  echo "warning: Odin's vendor/wgpu does not name wgpu-native $VERSION: check the version it expects" >&2
fi
if [ "${1:-}" != "--force" ] && [ -f "$DEST/libwgpu_native.a" ] && [ "$(cat "$DEST/VERSION" 2>/dev/null)" = "$VERSION-sealed" ]; then
  echo "wgpu-native $VERSION already in $DEST"; exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
URL="https://github.com/gfx-rs/wgpu-native/releases/download/$VERSION/wgpu-linux-$ARCH-release.zip"
echo "downloading $URL"
curl -fsSL -o "$TMP/wgpu.zip" "$URL"
GOT="$(sha256sum "$TMP/wgpu.zip" | cut -d' ' -f1)"
if [ "$GOT" != "$SHA256" ]; then echo "SHA-256 mismatch for wgpu-linux-$ARCH-release.zip: expected $SHA256, got $GOT" >&2; exit 1; fi
unzip -q "$TMP/wgpu.zip" -d "$TMP/x"
# Sealed, as tools/fetch_wasmtime.sh does: the archive carries its own copy of Rust's standard library, and so does
# build/native-linux/libwren_native.a; the program sees the C API (wgpu*) only, each Rust keeps its own runtime.
ld -r --whole-archive "$TMP/x/lib/libwgpu_native.a" -o "$TMP/wgpu.o"
nm -g --defined-only "$TMP/wgpu.o" | awk '{print $3}' | grep -E '^wgpu' > "$TMP/keep.txt"
objcopy --keep-global-symbols="$TMP/keep.txt" "$TMP/wgpu.o"
mkdir -p "$DEST"
rm -f "$DEST/libwgpu_native.a"
ar rcs "$DEST/libwgpu_native.a" "$TMP/wgpu.o"
echo "$VERSION-sealed" > "$DEST/VERSION"
echo "wgpu-native $VERSION ($ARCH) in $DEST"
