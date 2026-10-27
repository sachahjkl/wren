#!/usr/bin/env bash
# Wren's build on Linux, beside build.bat. What is portable today builds and is checked here; the browser itself needs the
# toolkit's Linux platform layer and the shell's port first (docs/portability.md), so there is no build/wren yet.
#   ./build.sh deps       the native libraries for this system: Wasmtime (pinned release, SHA-256), Lexbor, the Rust library
#   ./build.sh check      odin check for Linux and the unit tests of every portable package (tools/linux_ci.sh)
#   ./build.sh crash      the crash reports end to end (tools/crash_e2e.sh)
#   ./build.sh all        deps, check, crash
#   ./build.sh help
# ODIN: the compiler (default: odin on PATH). PROFILE: the Rust profile (quick, the default, or release).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
ODIN="${ODIN:-odin}"
PROFILE="${PROFILE:-quick}"
deps() {
  tools/fetch_wasmtime.sh
  CC="${CC:-clang}" tools/build_lexbor.sh
  tools/build_native.sh --profile "$PROFILE"
}
case "${1:-help}" in
  deps)  deps ;;
  check) tools/linux_ci.sh "$ODIN" ;;
  crash) tools/crash_e2e.sh "$ODIN" ;;
  all)   deps; tools/linux_ci.sh "$ODIN"; tools/crash_e2e.sh "$ODIN" ;;
  wren)  echo "build.sh: the browser does not build on Linux yet (the toolkit's platform layer and the shell come next: docs/portability.md)" >&2; exit 1 ;;
  *)     sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
