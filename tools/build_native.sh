#!/usr/bin/env bash
# Builds Wren's one Rust static library (the native/ workspace, crate wren_native) for this system into
# build/native-<os>/libwren_native.a: what tools\build_native.ps1 does on Windows, with the same Cargo.lock (--locked).
#   tools/build_native.sh [--profile quick|release] [--features text,a11y]
# Needs cargo and nasm (rav1d's assembly kernels). Default features: none but the image decoders and WOFF2 (what the
# engine's packages link); the toolkit's text backend (text) and accessibility adapter (a11y) are added when the
# browser itself is built here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE=quick
FEATURES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --features) FEATURES="$2"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
OUT="$ROOT/build/native-$OS"
TARGET="${CARGO_TARGET_DIR:-$ROOT/build/native-$OS/target}"
mkdir -p "$OUT"
args=(build --profile "$PROFILE" --locked --manifest-path "$ROOT/native/Cargo.toml" --target-dir "$TARGET" -p wren_native)
[ -n "$FEATURES" ] && args+=(--features "$FEATURES")
cargo "${args[@]}"
cp "$TARGET/$PROFILE/libwren_native.a" "$OUT/libwren_native.a"
echo "built $OUT/libwren_native.a ($PROFILE${FEATURES:+, $FEATURES})"
