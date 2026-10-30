#!/usr/bin/env bash
# Downloads the official Wasmtime C API release for Linux (the version of tools/fetch_wasmtime.ps1, SHA-256 checked) into
# build/wasmtime-linux (lib/libwasmtime.a is linked by src/wasm/wasmtime.odin; include/ for reference).
# Usage: tools/fetch_wasmtime.sh [--force]
# To move to another release: change VERSION here and in tools/fetch_wasmtime.ps1, and the digests (GitHub shows them
# for each *-c-api asset), then WASMTIME_VERSION in src/wasm/wasmtime.odin.
set -euo pipefail
VERSION=49.0.3
case "$(uname -m)" in
  x86_64)  ARCH=x86_64;  SHA256=49c9641ac1f6158ed90404115315b36a9ae68338acda16fcf00f0819622ccd97 ;;
  aarch64) ARCH=aarch64; SHA256=fb9c1a101c092cd3b4536ddb4c68ae31ad70d78bbdbc408d0e007f05a2fdd409 ;;
  *) echo "no Wasmtime C API release pinned for $(uname -m)" >&2; exit 1 ;;
esac
NAME="wasmtime-v$VERSION-$ARCH-linux-c-api"
URL="https://github.com/bytecodealliance/wasmtime/releases/download/v$VERSION/$NAME.tar.xz"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/wasmtime-linux"
STAMP="$VERSION-$ARCH-sealed"
if [ "${1:-}" != "--force" ] && [ -f "$OUT/lib/libwasmtime.a" ] && [ "$(cat "$OUT/VERSION" 2>/dev/null)" = "$STAMP" ]; then
  echo "wasmtime $VERSION already in $OUT"; exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "downloading $URL"
curl -fsSL -o "$TMP/$NAME.tar.xz" "$URL"
GOT="$(sha256sum "$TMP/$NAME.tar.xz" | cut -d' ' -f1)"
if [ "$GOT" != "$SHA256" ]; then echo "SHA-256 mismatch for $NAME.tar.xz: expected $SHA256, got $GOT" >&2; exit 1; fi
tar -xJf "$TMP/$NAME.tar.xz" -C "$TMP"
rm -rf "$OUT"
mkdir -p "$OUT"
cp -r "$TMP/$NAME/include" "$OUT/"
mkdir -p "$OUT/lib"
# Sealed: the archive carries its own copy of Rust's standard library, and so does build/native-linux/libwren_native.a.
# GNU ld pulls members of both and stops on the symbols they share unmangled (rust_eh_personality, the allocator and
# panic shims); and two standard libraries of different compilers must never call into each other anyway. So the
# archive is linked into one relocatable object and every symbol but the C API's (wasm_*, wasmtime_*, wasi_*, wat_*)
# made local: the program sees the C API only, each Rust keeps its own runtime. (On Windows the MSVC toolchain has no
# such shared symbol: wasmtime.lib links as shipped.)
ld -r --whole-archive "$TMP/$NAME/lib/libwasmtime.a" -o "$TMP/wasmtime.o"
nm -g --defined-only "$TMP/wasmtime.o" | awk '{print $3}' | grep -E '^(wasm_|wasmtime_|wasi_|wat_)' > "$TMP/keep.txt"
objcopy --keep-global-symbols="$TMP/keep.txt" "$TMP/wasmtime.o"
ar rcs "$OUT/lib/libwasmtime.a" "$TMP/wasmtime.o"
# The licence text src/browser/third_party.odin bundles (the C API archive has none; the tag's LICENSE file is the same text
# as the Windows archive's), at the place build.bat's step puts it
LICENSE_SHA256=268872b9816f90fd8e85db5a28d33f8150ebb8dd016653fb39ef1f94f2686bc5
mkdir -p "$ROOT/build/wasmtime"
curl -fsSL -o "$ROOT/build/wasmtime/LICENSE" "https://raw.githubusercontent.com/bytecodealliance/wasmtime/v$VERSION/LICENSE"
LGOT="$(sha256sum "$ROOT/build/wasmtime/LICENSE" | cut -d' ' -f1)"
if [ "$LGOT" != "$LICENSE_SHA256" ]; then echo "SHA-256 mismatch for the Wasmtime LICENSE: expected $LICENSE_SHA256, got $LGOT" >&2; exit 1; fi
echo "$STAMP" > "$OUT/VERSION"
echo "wasmtime $VERSION ($ARCH) in $OUT"
