#!/usr/bin/env bash
# The Linux part of the CI (and of a local check in WSL): odin check for Linux of every package that is portable now,
# then the unit tests of those that have tests, with the flags of tools\test_all.ps1 (-vet, the memory check; a 32 MiB
# stack: what /STACK:33554432 is on Windows). Needs build/wasmtime-linux (tools/fetch_wasmtime.sh), build/lexbor-linux
# (tools/build_lexbor.sh) and build/native-linux (tools/build_native.sh).
#   tools/linux_ci.sh [odin] [package...]   ODIN: the compiler (default: odin on PATH); packages: only those (of the lists)
# Packages move from "not yet" to these lists as they are ported (docs/portability.md); tests that measure time stay out.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ODIN="${1:-odin}"
[ $# -gt 0 ] && shift
ONLY=("$@")
COLL=(-collection:wb=src -collection:toolkit=ext/gui_toolkit)
# (js/image is out until the JS engine's wasm can be built on Linux: it #loads build/js/wren_js.wasm. idb is checked but its tests
# are out: two of them, a failed request and a failed write, fail on the GitHub runner and pass in WSL; not understood yet)
# (browser is the first package that imports toolkit:render, so its check needs libwgpu_native.a beside Odin's wgpu
# vendor package; it is skipped below when the library is absent so the rest of the check still runs)
CHECK=(base host config css http i18n xml adblock canvas2d license dom url html cookies csp forms style layout
       webfont wasm js idb httpcache images webauthn desktop remote tools/testenv
       net fetch media page blocker remote/client tools/crashtrace browser)
# (name, extra flags): wasm, remote and remote/client run on one thread, as on Windows (one channel per process)
TESTS=(base host css http xml adblock canvas2d dom url html cookies csp forms style layout webfont js
       httpcache webauthn desktop "wasm:-define:ODIN_TEST_THREADS=1" "remote:-define:ODIN_TEST_THREADS=1"
       net fetch media blocker page "remote/client:-define:ODIN_TEST_THREADS=1" tools/crashtrace)
wanted() {
  [ ${#ONLY[@]} -eq 0 ] && return 0
  for o in "${ONLY[@]}"; do [ "$o" = "$1" ] && return 0; done
  return 1
}
ulimit -s 32768
mkdir -p build/linux
# (package js_image #loads build/js/wren_js.wasm, which only a Windows build makes: an empty file lets odin check go through, and the tests
# that run the JS engine (page, blocker) are skipped while it is a stub)
JS_STUB=0
if [ ! -s build/js/wren_js.wasm ]; then mkdir -p build/js; : > build/js/wren_js.wasm; JS_STUB=1; fi
# (package browser #loads the third-party licence texts bundled into the executable (third_party.odin): the build fetches them
# with ./build.sh deps, but odin check needs them present. Empty stubs let the check go through when the real files are absent.)
for f in build/wasmtime/LICENSE ext/lexbor/LICENSE ext/lexbor/NOTICE; do
  if [ ! -e "$f" ]; then mkdir -p "$(dirname "$f")"; : > "$f"; fi
done
# libwgpu_native.a beside Odin's wgpu vendor package: present on the CI runner, maybe not in a bare WSL checkout. Without
# it the wgpu vendor panics at check time, so a package that imports toolkit:render (browser) is skipped with a note.
WGPU_LIB=0
if ls "$("$ODIN" root 2>/dev/null)"/vendor/wgpu/lib/wgpu-linux-*/lib/libwgpu_native.a >/dev/null 2>&1; then WGPU_LIB=1; fi
fail=0
for p in "${CHECK[@]}"; do
  wanted "$p" || continue
  if [ "$p" = browser ] && [ $WGPU_LIB -eq 0 ]; then echo "check skip src/browser (needs libwgpu_native.a for toolkit:render)"; continue; fi
  if out=$("$ODIN" check "src/$p" -target:linux_amd64 -no-entry-point -vet "${COLL[@]}" 2>&1); then
    echo "check ok   src/$p"
  else
    echo "check FAIL src/$p"; echo "$out" | head -20; fail=1
  fi
done
for t in "${TESTS[@]}"; do
  p="${t%%:*}"; extra=""; [ "$p" != "$t" ] && extra="${t#*:}"
  wanted "$p" || continue
  if [ $JS_STUB -eq 1 ] && { [ "$p" = page ] || [ "$p" = blocker ]; }; then echo "test skip  src/$p (needs the JS engine's wasm)"; continue; fi
  name="$(echo "$p" | tr '/' '_')"
  out=$("$ODIN" test "src/$p" -vet "${COLL[@]}" -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true $extra -out:"build/linux/${name}_test" 2>&1)
  if echo "$out" | grep -qE "All tests were successful|The test was successful"; then
    echo "test ok    src/$p $(echo "$out" | grep -oE 'Finished [0-9]+ tests?')"
  else
    echo "test FAIL  src/$p"; echo "$out" | grep -E "\[ERROR|Error|FAILED|undefined|Segmentation" | head -30; fail=1
  fi
done
exit $fail
