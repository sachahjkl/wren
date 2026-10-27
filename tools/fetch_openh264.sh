#!/usr/bin/env bash
# Downloads Cisco's prebuilt OpenH264 decoder for Linux into build/openh264-linux/libopenh264.so (dlopen'ed by
# src/media/h264_linux.odin). The binary is Cisco's own release: the patent licence Cisco pays covers only the
# binaries it ships, never a library built from source, so this never compiles OpenH264.
#   tools/fetch_openh264.sh [--force]
# To move to another release: change VERSION and the per-arch SHA-256 below (Cisco publishes the digests on the
# openh264 releases page; the asset is the bzip2 of the .so for the matching architecture).
set -euo pipefail
VERSION=2.4.1
case "$(uname -m)" in
  x86_64)  ARCH=linux64;  SHA256=REPLACE_WITH_openh264-${VERSION}-linux64.7.so.bz2_SHA256 ;;
  aarch64) ARCH=linux-arm64; SHA256=REPLACE_WITH_openh264-${VERSION}-linux-arm64.7.so.bz2_SHA256 ;;
  *) echo "no OpenH264 binary pinned for $(uname -m)" >&2; exit 1 ;;
esac
# Cisco serves the compressed shared object; the ".7" is the soname version the loader also tries.
ASSET="libopenh264-${VERSION}-${ARCH}.7.so.bz2"
URL="http://ciscobinary.openh264.org/${ASSET}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/openh264-linux"
SO="$OUT/libopenh264.so.7"
if [ "${1:-}" != "--force" ] && [ -f "$SO" ] && [ "$(cat "$OUT/VERSION" 2>/dev/null)" = "$VERSION" ]; then
  echo "openh264 $VERSION already in $OUT"; exit 0
fi
case "$SHA256" in REPLACE_WITH_*) echo "set the SHA-256 for $ASSET in $0 before fetching" >&2; exit 1 ;; esac
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "downloading $URL"
curl -fsSL -o "$TMP/$ASSET" "$URL"
GOT="$(sha256sum "$TMP/$ASSET" | cut -d' ' -f1)"
if [ "$GOT" != "$SHA256" ]; then echo "SHA-256 mismatch for $ASSET: expected $SHA256, got $GOT" >&2; exit 1; fi
mkdir -p "$OUT"
bunzip2 -c "$TMP/$ASSET" > "$SO"
chmod 0644 "$SO"
# A plain soname link so a loader that asks for "libopenh264.so" also finds it.
ln -sf "libopenh264.so.7" "$OUT/libopenh264.so"
echo "$VERSION" > "$OUT/VERSION"
echo "openh264 $VERSION in $OUT (set media.h264.openh264_path to $SO, or add $OUT to the library path)"
