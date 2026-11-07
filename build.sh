#!/usr/bin/env bash
# Wren's build on Linux, beside build.bat. What is portable today builds and is checked here; the toolkit now has a
# Linux window (Wayland + X11, dlopen so no window library is hard-linked) and a wgpu render path, and src/browser now
# type-checks for Linux too (docs/portability.md). Linking build/wren needs libwgpu_native.a beside Odin's wgpu vendor
# package and the native libraries from `./build.sh deps`; `./build.sh wren` attempts it so any remaining errors show.
#   ./build.sh deps       the native libraries for this system: Wasmtime (pinned release, SHA-256), Lexbor, the Rust library, the JavaScript engine
#   ./build.sh check      odin check for Linux and the unit tests of every portable package (src/tools/test_all)
#   ./build.sh crash      the crash reports end to end (wrentool crash-e2e)
#   ./build.sh wren       attempt to link build/wren (needs libwgpu_native.a and ./build.sh deps; src/browser type-checks now)
#   ./build.sh wren-check build/wren_check, as build.bat check: debug, every allocation tracked, freed memory poisoned
#   ./build.sh release    build/wren as the release has it: the release channel, the Rust library with fat LTO (wrentool package packs it)
#   ./build.sh all        deps, check, crash
#   ./build.sh help
# ODIN: the compiler (default: odin on PATH). PROFILE: the Rust profile (quick, the default, or release).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
ODIN="${ODIN:-odin}"
PROFILE="${PROFILE:-quick}"

# src/tools/wrentool: built when this script needs it (a second or two), it needs nothing of what it fetches.
wrentool() {
  if [ -z "${WRENTOOL_BUILT:-}" ]; then
    mkdir -p build
    "$ODIN" build src/tools/wrentool -collection:wb=src -out:build/wrentool
    WRENTOOL_BUILT=1
  fi
  WREN_ODIN="$ODIN" build/wrentool "$@"
}

deps() {
  wrentool fetch wasmtime
  wrentool fetch wgpu
  CC="${CC:-clang}" wrentool build lexbor
  # the features of the browser's (wren below): the unit tests link the same library (src/tools/test_all: the browser's own shape text)
  wrentool build native -Profile "$PROFILE" -Features text,a11y
  # the JavaScript engine's image (build/js: nothing to do when up to date), which the browser embeds: without it the browser runs
  # no script, and the tests that need the engine are skipped. Its pre-initialization calls the module, which needs the 64 MiB stack
  # (wasm.wasmtime.max_stack_bytes); the linker is the system's wasm-ld (lld), which Odin's Linux release does not ship.
  ( ulimit -s 65536 && "$ODIN" run src/tools/buildjs -collection:wb=src -out:build/buildjs )
}

# odin check and the unit tests: the test program of the repository, built each time (a second).
tests() {
  mkdir -p build
  "$ODIN" build src/tools/test_all -collection:wb=src -vet -out:build/test_all
  build/test_all -Odin "$ODIN"
}

# The linker flags the browser executable needs on Linux, the counterpart of build.bat's
# "/STACK:67108864 /NODEFAULTLIB:... /MAP":
#   --build-id        a build id in the binary, so a crash report can name the build (wrentool crash-symbolize,
#                     docs/portability.md "An executable linked without --build-id ...")
#   -z noexecstack    a non-executable stack (the Rust and C objects are already marked; make it explicit)
#   -lpthread -ldl    threads (host.thread_start) and dlopen (openh264, libfido2, libva loaded at run time)
#   -lm               the maths the Rust and C libraries use
#   -Wl,--no-as-needed keeps -lpthread even when the direct references are pulled in only from the static archives
# The static archives themselves (build/*-linux: libwren_native.a, libwasmtime.a, liblexbor.a) are named by each
# package's foreign import; Odin passes their directories. The 64 MiB stack is set with a soft ulimit at run time
# (ulimit -s), as the Linux CI does, since the main-thread stack size is not a link option on Linux.
link_flags() {
  echo "-Wl,--build-id -Wl,-z,noexecstack -Wl,--no-as-needed -lpthread -ldl -lm -lopus -lasound"
}

wren() {
  local out="${WREN_OUT:-build/wren}"
  # The text and accessibility backends are compiled into the native library here (build.bat's default features);
  # the toolkit is then told not to link them itself (-define:FONT_NATIVE_LINK=false / -define:A11Y_NATIVE_LINK=false).
  wrentool build native -Profile "$PROFILE" -Features text,a11y
  # an empty image is the stub that lets odin check go through (src/tools/test_all/desktop_other.odin): a browser linked with it runs no script
  if [ ! -s build/js/wren_js.wasm ]; then
    echo "build/js/wren_js.wasm is missing or empty (a stub): ./build.sh deps builds the JavaScript engine" >&2
    exit 1
  fi
  # the engine's machine code, which the program ships: made here, it is this system's (from build/js/wren_js.wasm, ./build.sh deps)
  wrentool build jscode
  local flags=(-collection:toolkit=ext/gui_toolkit -collection:wb=src -vet -target:linux_amd64 -define:WREN_SHIPPED_CODE=true)
  flags+=(-extra-linker-flags:"$(link_flags)")
  # as build.bat: the channel, the first block of each thread's temporary allocator (1 MiB), the version of the sources
  flags+=(-define:WREN_CHANNEL="${WREN_CHANNEL:-dev}" -define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=65536)
  local commit
  if commit="g$(git rev-parse --short HEAD 2>/dev/null)"; then
    git diff --quiet HEAD -- 2>/dev/null || commit="$commit+"
    flags+=(-define:WREN_COMMIT="$commit" -define:WREN_COMMIT_DATE="$(git log -1 --format=%cs)")
  fi
  flags+=(-define:FONT_BACKEND=native -define:FONT_NATIVE_LINK=false -define:A11Y_ACCESSKIT=true -define:A11Y_NATIVE_LINK=false)
  echo "linking $out (needs the build artifacts from ./build.sh deps; the system's libopus, libasound and libfontconfig; at run time libwayland-client / libxkbcommon or libxcb, and Vulkan or GL for wgpu)"
  "$ODIN" build src/browser -out:"$out" "${flags[@]}" ${WREN_ODIN_FLAGS:--o:speed}
}

case "${1:-help}" in
  deps)  deps ;;
  check) tests ;;
  crash) wrentool crash-e2e ;;
  wren)  wren ;;
  wren-check) WREN_OUT=build/wren_check WREN_ODIN_FLAGS="-debug -use-separate-modules -define:WREN_TRACK_MEMORY=true -define:WREN_POISON_MEMORY=true"; wren ;;
  release) PROFILE=release; WREN_CHANNEL=release; wren ;;
  all)   deps; tests; wrentool crash-e2e ;;
  *)     sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
