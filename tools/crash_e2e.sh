#!/usr/bin/env bash
# The crash reports of Linux (src/tools/crashtrace/crashtrace_linux.odin), end to end: src/tools/crashmodes dies in each
# way a Wren has died, and each death must leave its report (the stack, the build) or, for a death no handler sees, an
# "unclean exit" report at the next start. What tools\crash_e2e.ps1 checks on Windows.
#   tools/crash_e2e.sh [odin]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ODIN="${1:-odin}"
mkdir -p build/linux
EXE=build/linux/crashmodes
"$ODIN" build src/tools/crashmodes -collection:wb=src -vet -debug -o:speed -out:"$EXE" -extra-linker-flags:"-Wl,--build-id" || exit 1
fail=0
check() {   # mode, what is expected: report | unclean | report-or-unclean
  local mode="$1" want="$2" dir
  dir="$(mktemp -d)"
  "$EXE" "$mode" "$dir" > "$dir/out.txt" 2>&1
  local code=$?
  "$EXE" clean "$dir" > /dev/null 2>&1   # the next start: a session left behind becomes an "unclean exit" report
  local report unclean
  report="$(ls "$dir"/crash*.txt 2>/dev/null | head -1)"
  unclean="$(ls "$dir"/unclean*.txt 2>/dev/null | head -1)"
  local ok=0
  case "$want" in
    report) [ -n "$report" ] && grep -q '^\*\*\* crash:' "$report" && grep -q 'end of the stack' "$report" && grep -q 'crashmodes' "$report" && grep -q '^  build crashmodes' "$report" && ok=1 ;;
    unclean) [ -n "$unclean" ] && [ -z "$report" ] && ok=1 ;;
    report-or-unclean) [ -n "$report$unclean" ] && ok=1 ;;
  esac
  if [ $ok = 1 ]; then
    echo "ok    $mode (exit $code$( [ -n "$report" ] && echo ", report: $(grep -c '^  #' "$report") frames")$( [ -n "$unclean" ] && echo ", unclean exit"))"
  else
    echo "FAIL  $mode (exit $code): want $want"; cat "$dir/out.txt" | head -30; [ -n "$report" ] && cat "$report"; fail=1
  fi
  rm -rf "$dir"
}
check access report
check bounds report
check assert report
check overflow report
check heap report
check failfast report
check overflow_thread report-or-unclean
check exit unclean
exit $fail
