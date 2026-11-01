#!/usr/bin/env bash
# The packaged Linux executable end to end, as a user unpacks it: it starts, opens a window, runs script and draws a page.
#   tools/linux_smoke.sh <wren executable>     (needs a display: xvfb-run on a machine without one, and a Vulkan or GL driver)
set -uo pipefail
STEP_TIMEOUT_S=120   # a step that takes longer has hung: the script must end and say so
WREN="$(realpath "${1:?the executable}")"
OUT="$(mktemp -d)"
NAME="smoke$$"
export WREN_DESKTOP_INTEGRATION=off WREN_SINGLE_INSTANCE=off WREN_AUDIO_OUTPUT=null
ctl() { timeout "$STEP_TIMEOUT_S" "$WREN" ctl --remote "$NAME" "$@" 2>&1; }
trap 'timeout "$STEP_TIMEOUT_S" "$WREN" ctl stop "$NAME" >/dev/null 2>&1; rm -rf "$OUT"' EXIT
fail=0
check() { # name, expected substring, actual
  case "$3" in
    *"$2"*) echo "PASS $1" ;;
    *) echo "FAIL $1: expected '$2', got '${3:0:300}'"; fail=$((fail + 1)) ;;
  esac
}
check "the version" "Wren" "$(timeout "$STEP_TIMEOUT_S" "$WREN" --version 2>&1)"
# (to a file: the Wren it starts stays in the background and keeps what it inherited, so a pipe here would never end)
timeout "$STEP_TIMEOUT_S" "$WREN" ctl start --name "$NAME" --size 1000x700 > "$OUT/start.log" 2>&1
echo "start: exit $?, $(tail -3 "$OUT/start.log")"
printf "%s" "<!doctype html><title>hello</title><h1 id=a>Wren</h1>" > "$OUT/page.html"
ctl nav "file://$OUT/page.html" | tail -1
check "script runs" "Wren 4" "$(ctl eval "document.getElementById('a').textContent + ' ' + (2 + 2)")"
check "layout" "true" "$(ctl eval "document.getElementById('a').getBoundingClientRect().height > 10")"
# deep recursion on the main thread: the same limits as on Windows, without a ulimit from the caller
check "deep recursion" "RangeError" "$(ctl eval "(function(){ function f(){ return f() + 1 } try { f() } catch (e) { return e.name } })()")"
# WebGL, on the machine's Vulkan (Mesa's lavapipe on a runner): a clear read back (null: no adapter, which is said, not failed)
webgl="$(ctl eval "(function(){ var c=document.createElement('canvas'), g=c.getContext('webgl'); if(!g) return 'no adapter'; g.clearColor(0,1,0,1); g.clear(g.COLOR_BUFFER_BIT); var p=new Uint8Array(4); g.readPixels(0,0,1,1,g.RGBA,g.UNSIGNED_BYTE,p); return 'pixel '+p.join(); })()")"
check "WebGL" "pixel 0,255,0,255" "$webgl"
# The GPU process: a child of the browser that a kill costs contexts and nothing else, and that ends with a killed browser.
gpu_of() { # the GPU process under a browser
  for candidate in $(pgrep -P "$1" 2>/dev/null); do
    case "$(tr '\0' ' ' < "/proc/$candidate/cmdline" 2>/dev/null)" in *--wren-gpu-process=*) echo "$candidate"; return ;; esac
  done
}
browser_of() { pgrep -o -f -- "$1" | head -1; } # (the oldest process that names it: the browser, not its ctl)
case "$webgl" in *pixel*)
  browser="$(browser_of "$NAME")"
  gpu="$(gpu_of "$browser")"
  if [ -n "$gpu" ]; then echo "PASS a GPU process ($gpu)"; else echo "FAIL no GPU process under $browser"; fail=$((fail + 1)); fi
  ctl eval "window.gl_events = []; window.glc = document.createElement('canvas'); glc.addEventListener('webglcontextlost', function (e) { gl_events.push('lost'); e.preventDefault(); }); glc.addEventListener('webglcontextrestored', function () { gl_events.push('restored'); }); window.gl = glc.getContext('webgl'); 1" > /dev/null
  [ -n "$gpu" ] && kill -9 "$gpu"
  events=""
  for _ in $(seq 1 "$STEP_TIMEOUT_S"); do
    events="$(ctl eval "gl_events.join()")"
    case "$events" in *restored*) break ;; esac
    sleep 1
  done
  check "the GPU process killed: lost, then restored" "lost,restored" "$events"
  check "the page carries on" "Wren" "$(ctl eval "document.getElementById('a').textContent")"
  check "it draws again" "0,255,0,255" "$(ctl eval "(function(){ gl.clearColor(0,1,0,1); gl.clear(gl.COLOR_BUFFER_BIT); var p=new Uint8Array(4); gl.readPixels(0,0,1,1,gl.RGBA,gl.UNSIGNED_BYTE,p); return p.join(); })()")"
  ;;
esac
ctl shot "$OUT/shot.png" | tail -1
size=$(stat -c %s "$OUT/shot.png" 2>/dev/null || echo 0)
if [ "$size" -gt 1000 ]; then echo "PASS a capture ($size bytes)"; else echo "FAIL a capture ($size bytes)"; fail=$((fail + 1)); fi
# (a Wren of its own, killed: its GPU process must not stay)
second="smoke$$b"
timeout "$STEP_TIMEOUT_S" "$WREN" ctl start --name "$second" --size 400x300 > "$OUT/start2.log" 2>&1
gl2="$(timeout "$STEP_TIMEOUT_S" "$WREN" ctl --remote "$second" eval "String(document.createElement('canvas').getContext('webgl') !== null)" 2>&1)"
if [ "$gl2" = "true" ]; then
  b2="$(browser_of "$second")"
  gpu2="$(gpu_of "$b2")"
  kill -9 "$b2"
  gone=0
  for _ in $(seq 1 100); do
    if [ -z "$gpu2" ] || [ ! -d "/proc/$gpu2" ] || grep -q '^State:.*[ZX]' "/proc/$gpu2/status" 2>/dev/null; then gone=1; break; fi
    sleep 0.1
  done
  if [ "$gone" = 1 ] && [ -n "$gpu2" ]; then echo "PASS the GPU process ends with a killed browser"; else echo "FAIL the GPU process '$gpu2' under $b2 is not gone"; fail=$((fail + 1)); fi
fi
timeout "$STEP_TIMEOUT_S" "$WREN" ctl stop "$second" > /dev/null 2>&1
timeout "$STEP_TIMEOUT_S" "$WREN" ctl stop "$NAME" 2>&1 | tail -1
echo "$fail failure(s)"
exit "$fail"
