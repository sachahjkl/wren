#!/usr/bin/env bash
# Wren's build on Linux, beside build.bat. What is portable today builds and is checked here; the browser executable
# links with the flags below, but does not build fully yet: the toolkit now has a Linux window (Wayland + X11, in
# ext/gui_toolkit/platform, loaded with dlopen so no window library is hard-linked), and what remains is the toolkit's
# render package on wgpu for Linux (libwgpu_native.a) and src/browser's own Windows calls (docs/portability.md).
# `./build.sh wren` attempts the link so the remaining errors are visible.
#   ./build.sh deps       the native libraries for this system: Wasmtime (pinned release, SHA-256), Lexbor, the Rust library
#   ./build.sh check      odin check for Linux and the unit tests of every portable package (tools/linux_ci.sh)
#   ./build.sh crash      the crash reports end to end (tools/crash_e2e.sh)
#   ./build.sh wren       attempt to link build/wren (expected to fail until the toolkit platform and the shell are ported)
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

# The linker flags the browser executable needs on Linux, the counterpart of build.bat's
# "/STACK:33554432 /NODEFAULTLIB:... /MAP":
#   --build-id        a build id in the binary, so a crash report can name the build (tools/crash_symbolize.sh,
#                     docs/portability.md "An executable linked without --build-id ...")
#   -z noexecstack    a non-executable stack (the Rust and C objects are already marked; make it explicit)
#   -lpthread -ldl    threads (host.thread_start) and dlopen (openh264, libfido2, libva loaded at run time)
#   -lm               the maths the Rust and C libraries use
#   -Wl,--no-as-needed keeps -lpthread even when the direct references are pulled in only from the static archives
# The static archives themselves (build/*-linux: libwren_native.a, libwasmtime.a, liblexbor.a) are named by each
# package's foreign import; Odin passes their directories. The 32 MiB stack is set with a soft ulimit at run time
# (ulimit -s), as the Linux CI does, since the main-thread stack size is not a link option on Linux.
link_flags() {
  echo '-Wl,--build-id -Wl,-z,noexecstack -Wl,--no-as-needed -lpthread -ldl -lm'
}

wren() {
  local out="build/wren"
  # The text and accessibility backends are compiled into the native library here (build.bat's default features);
  # the toolkit is then told not to link them itself (-define:FONT_NATIVE_LINK=false / -define:A11Y_NATIVE_LINK=false).
  tools/build_native.sh --profile "$PROFILE" --features text,a11y
  local flags=(-collection:toolkit=ext/gui_toolkit -collection:wb=src -vet -target:linux_amd64)
  flags+=(-extra-linker-flags:"$(link_flags)")
  flags+=(-define:FONT_BACKEND=native -define:FONT_NATIVE_LINK=false -define:A11Y_ACCESSKIT=true -define:A11Y_NATIVE_LINK=false)
  echo "linking $out (expected to fail until the toolkit's render package is on wgpu for Linux and src/browser is ported)"
  "$ODIN" build src/browser -out:"$out" "${flags[@]}" -o:speed
}

case "${1:-help}" in
  deps)  deps ;;
  check) tools/linux_ci.sh "$ODIN" ;;
  crash) tools/crash_e2e.sh "$ODIN" ;;
  wren)  wren ;;
  all)   deps; tools/linux_ci.sh "$ODIN"; tools/crash_e2e.sh "$ODIN" ;;
  *)     sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
