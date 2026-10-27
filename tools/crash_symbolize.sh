#!/usr/bin/env bash
# Names the frames of a Linux crash report (crashtrace_linux.odin) from the executable's debug information: each
# "[<module>+0x<offset>]" of the build's own module goes through addr2line (binutils). The executable must be the build
# that crashed: its GNU build id is checked against the report's "build" line.
#   tools/crash_symbolize.sh <report.txt> <executable>
set -euo pipefail
report="$1"; exe="$2"
want="$(grep -m1 '^  build ' "$report" | awk '{print $3}' | tr -d ',')"
got="$(readelf -n "$exe" 2>/dev/null | awk '/Build ID/ {print $3}')"
if [ -n "$want" ] && [ "$want" != "(no" ] && [ "$want" != "$got" ]; then
  echo "the report is of build $want, $exe is $got: give the executable that crashed" >&2; exit 1
fi
mod="$(basename "$exe")"
while IFS= read -r line; do
  if [[ "$line" =~ ^\ \ #([0-9]+).*\[$mod\+0x([0-9A-Fa-f]+)\] ]]; then
    where="$(addr2line -f -C -i -e "$exe" "0x${BASH_REMATCH[2]}" | paste -sd ' ' -)"
    echo "$line  $where"
  else
    echo "$line"
  fi
done < "$report"
