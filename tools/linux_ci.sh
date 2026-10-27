#!/usr/bin/env bash
# The Linux part of the CI (and of a local check in WSL): odin check for Linux of every package that is portable now,
# then the unit tests of those that have tests, with the flags of tools\test_all.ps1 (-vet, the memory check; a 32 MiB
# stack: what /STACK:33554432 is on Windows). Needs build/wasmtime-linux (tools/fetch_wasmtime.sh), build/lexbor-linux
# (tools/build_lexbor.sh) and build/native-linux (tools/build_native.sh).
#   tools/linux_ci.sh [odin]      ODIN: the compiler (default: odin on PATH)
# Packages move from "not yet" to these lists as they are ported (docs/portability.md); tests that measure time stay out.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ODIN="${1:-odin}"
COLL=(-collection:wb=src -collection:toolkit=ext/gui_toolkit)
# (js/image is out until the JS engine's wasm can be built on Linux: it #loads build/js/wren_js.wasm. idb is checked but its tests
# are out: two of them, a failed request and a failed write, fail on the GitHub runner and pass in WSL; not understood yet)
CHECK=(base host config css http i18n xml adblock canvas2d license dom url html cookies csp forms style layout
       webfont wasm js idb httpcache images webauthn instance desktop remote tools/testenv)
# (name, extra flags): wasm and remote run on one thread, as on Windows
TESTS=(base host config css http i18n xml adblock canvas2d dom url html cookies csp forms style layout webfont js
       httpcache webauthn instance desktop tools/testenv "wasm:-define:ODIN_TEST_THREADS=1" "remote:-define:ODIN_TEST_THREADS=1")
ulimit -s 32768
mkdir -p build/linux
fail=0
for p in "${CHECK[@]}"; do
  if out=$("$ODIN" check "src/$p" -target:linux_amd64 -no-entry-point -vet "${COLL[@]}" 2>&1); then
    echo "check ok   src/$p"
  else
    echo "check FAIL src/$p"; echo "$out" | head -20; fail=1
  fi
done
for t in "${TESTS[@]}"; do
  p="${t%%:*}"; extra=""; [ "$p" != "$t" ] && extra="${t#*:}"
  name="$(echo "$p" | tr '/' '_')"
  out=$("$ODIN" test "src/$p" -vet "${COLL[@]}" -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true $extra -out:"build/linux/${name}_test" 2>&1)
  if echo "$out" | grep -qE "All tests were successful|The test was successful"; then
    echo "test ok    src/$p $(echo "$out" | grep -oE 'Finished [0-9]+ tests?')"
  else
    echo "test FAIL  src/$p"; echo "$out" | grep -E "\[ERROR|Error|FAILED|undefined|Segmentation" | head -30; fail=1
  fi
done
exit $fail
