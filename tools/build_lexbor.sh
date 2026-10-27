#!/usr/bin/env bash
# Builds Lexbor (ext/lexbor, the pinned release) + our shims (src/shim/*.c) into build/lexbor-<os>/liblexbor.a with the
# system's C compiler (cc, or CC=clang): what tools\build_lexbor.ps1 does with MSVC on Windows. No CMake.
#   tools/build_lexbor.sh [--force]
# Does nothing when build/lexbor-<os>/STAMP matches the Lexbor commit, the shims and this script.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
L="$ROOT/ext/lexbor/source"
[ -d "$L/lexbor" ] || { echo "ext/lexbor is empty: run  git submodule update --init" >&2; exit 1; }
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
OUT="$ROOT/build/lexbor-$OS"
CC="${CC:-cc}"
COMMIT="$(git -C "$ROOT/ext/lexbor" rev-parse HEAD 2>/dev/null || echo unknown)"
STAMP="$( { echo "$COMMIT"; cat "$ROOT"/src/shim/* "$0"; } | sha256sum | cut -d' ' -f1)"
if [ "${1:-}" != "--force" ] && [ "$COMMIT" != unknown ] && [ -f "$OUT/liblexbor.a" ] && [ "$(cat "$OUT/STAMP" 2>/dev/null)" = "$STAMP" ]; then
  echo "lexbor up to date in $OUT"; exit 0
fi
rm -rf "$OUT/obj"
mkdir -p "$OUT/obj"
FLAGS=(-c -O2 -DNDEBUG -fPIC -w -DLEXBOR_STATIC -I"$L" -I"$L/lexbor/ports/posix")
# same file names exist in several directories (state.c, res.c...): objects are named after their path
n=0
while IFS= read -r -d '' f; do
  rel="${f#$L/}"
  obj="$OUT/obj/$(echo "$rel" | tr '/' '_' | sed 's/\.c$/.o/')"
  "$CC" "${FLAGS[@]}" "$f" -o "$obj" &
  n=$((n + 1))
  if (( n % 16 == 0 )); then wait; fi
done < <(find "$L/lexbor" -name '*.c' -not -path '*/ports/windows_nt/*' -print0)
for f in "$ROOT"/src/shim/*.c; do
  "$CC" "${FLAGS[@]}" "$f" -o "$OUT/obj/shim_$(basename "${f%.c}").o" &
done
wait
want=$(( $(find "$L/lexbor" -name '*.c' -not -path '*/ports/windows_nt/*' | wc -l) + $(ls "$ROOT"/src/shim/*.c | wc -l) ))
got=$(ls "$OUT"/obj/*.o | wc -l)
[ "$got" -eq "$want" ] || { echo "build failed: $got objects of $want" >&2; exit 1; }
rm -f "$OUT/liblexbor.a"
ar rcs "$OUT/liblexbor.a" "$OUT"/obj/*.o
echo "$STAMP" > "$OUT/STAMP"
echo "built $OUT/liblexbor.a ($(ls "$OUT"/obj/*.o | wc -l) objects)"
