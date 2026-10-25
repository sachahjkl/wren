# Drag and drop, pointer and mouse coordinates end to end, in a Wren with no window shown (wren ctl):
#   * a file of another application dropped on a drop zone: dragenter / dragover / drop with the File, read back, and
#     the browser does not open it; dropped where nothing takes it, the browser opens it (browser.drop.open_files);
#   * a drag of a draggable element onto the zone: pointerdown, mousedown, dragstart, dragenter, dragover, drop with the
#     data dragstart set, dragend, buttons = 1 while held;
#   * a click in a scrolled page: clientY in the viewport, pageY with the scroll.
# The drops go through the toolkit's drop target path (platform.drop_inject); the real mouse and Explorer are not used.
param([string]$Exe = "")
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'wrenctl.ps1')
Set-Location $root
$tmp = Join-Path $root 'build\tmp'
New-Item -ItemType Directory -Force $tmp | Out-Null
$file = Join-Path $tmp 'dnd_e2e_drop.txt'
[IO.File]::WriteAllText($file, 'dropped bytes')
$page = 'file:///' + ((Join-Path $root 'examples\dnd\dnd.html') -replace '\\', '/')
$fails = 0
function Expect([bool]$ok, [string]$what, [string]$got) {
  if ($ok) { "PASS $what" } else { "FAIL $what (got: $got)"; $script:fails++ }
}
$name = Start-Wren -Size 1000x700
try {
  $env:WREN_REMOTE = $name
  Wren-Ctl nav $page --wait load | Out-Null
  Wren-Ctl drop $file --at '100,150' | Out-Null
  Start-Sleep -Milliseconds 300
  $log = Wren-Ctl eval "log.join(' | ')"
  Expect ($log -match 'dragenter@zone' -and $log -match 'dragover@zone' -and $log -match 'drop@zone files=1') 'a dropped file reaches the drop zone with its File' $log
  Expect ($log -match 'read=dropped bytes') '... and the page reads it' $log
  $path = Wren-Ctl eval 'location.pathname'
  Expect ($path -match 'dnd\.html$') 'the zone took the drop: the browser did not open the file' $path

  Wren-Ctl eval "log.length = 0; 'ok'" | Out-Null
  Wren-Ctl drag '50,30' '100,150' --steps 6 | Out-Null
  $log = Wren-Ctl eval "log.join(' | ')"
  Expect ($log -match 'pointerdown@src cy=30 py=30 b=1 \| mousedown@src') 'pointerdown before mousedown, buttons = 1' $log
  Expect ($log -match 'dragstart@src' -and $log -match 'drop@zone files=0 text=payload' -and $log -match 'dragend@src') 'a drag from a draggable element: dragstart, drop with its data, dragend' $log
  Expect (-not ($log -match 'mouseup')) 'no mouseup after a drag' $log

  Wren-Ctl eval "log.length = 0; scrollTo(0, 200); 'ok'" | Out-Null
  Start-Sleep -Milliseconds 200
  Wren-Ctl click '100,100' | Out-Null
  $log = Wren-Ctl eval "log.join(' | ')"
  Expect ($log -match 'mousedown@plain cy=100 py=300') 'a click in a scrolled page: clientY in the viewport, pageY with the scroll' $log
  Expect ($log -match 'pointerup@plain cy=100 py=300 b=0 \| mouseup@plain') 'pointerup before mouseup, no button held' $log

  Wren-Ctl eval "scrollTo(0, 0); 'ok'" | Out-Null
  Start-Sleep -Milliseconds 100
  Wren-Ctl drop $file --at '100,300' | Out-Null
  Start-Sleep -Milliseconds 800
  $href = Wren-Ctl eval 'location.href'
  Expect ($href -match 'dnd_e2e_drop\.txt$') 'a file dropped where nothing takes it opens' $href
} finally { Stop-Wren $name }
if ($fails -gt 0) { "dnd_e2e: $fails failure(s)"; exit 1 }
'dnd_e2e: all passed'
