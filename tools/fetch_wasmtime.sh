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
if [ "${1:-}" != "--force" ] && [ -f "$OUT/lib/libwasmtime.a" ] && [ "$(cat "$OUT/VERSION" 2>/dev/null)" = "$VERSION-$ARCH" ]; then
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
cp -r "$TMP/$NAME/include" "$TMP/$NAME/lib" "$OUT/"
echo "$VERSION-$ARCH" > "$OUT/VERSION"
echo "wasmtime $VERSION ($ARCH) in $OUT"
