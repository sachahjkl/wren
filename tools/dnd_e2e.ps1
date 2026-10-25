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
# "WxH@x,y" of the system's drag picture against what is expected in CSS px times the device pixel ratio (a pixel of
# rounding either way)
function Near-Image([string]$got, [double[]]$css, [double]$dpr) {
  if ($got -notmatch '^(\d+)x(\d+)@(-?\d+),(-?\d+)$') { return $false }
  for ($i = 0; $i -lt 4; $i++) { if ([math]::Abs([double]$Matches[$i + 1] - $css[$i] * $dpr) -gt 1) { return $false } }
  return $true
}
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
  $dpr = [double](Wren-Ctl eval 'devicePixelRatio')

  # out of the window and back onto the zone: the system's drag (through the window's own drop target, never the real
  # mouse) brings drop to the page before dragend, which carries the drop's effect; the ghost of the element went with it
  Wren-Ctl eval "log.length = 0; 'ok'" | Out-Null
  Wren-Ctl drag '50,30' '-300,30' '100,150' --steps 8 | Out-Null
  Start-Sleep -Milliseconds 200
  $log = Wren-Ctl eval "log.join(' | ')"
  $iDrop = $log.IndexOf('drop@zone'); $iEnd = $log.IndexOf('dragend@src')
  Expect ($iDrop -ge 0 -and $iEnd -gt $iDrop) 'out of the window and back: drop before dragend' $log
  Expect ($log -match 'dragend@src effect=copy') '... dragend with the effect of the drop' $log
  $st = Wren-Ctl stats --json | ConvertFrom-Json
  Expect (Near-Image $st.dragImage @(100, 40, 40, 20) $dpr) "the ghost of the dragged element (100x40 grabbed at 40,20) went to the system's drag" $st.dragImage

  # setDragImage with a canvas: its pixels, its hot spot
  Wren-Ctl eval "log.length = 0; useImage = true; 'ok'" | Out-Null
  Wren-Ctl drag '50,30' '-300,30' '100,150' --steps 8 | Out-Null
  Start-Sleep -Milliseconds 200
  $st = Wren-Ctl stats --json | ConvertFrom-Json
  Expect (Near-Image $st.dragImage @(20, 10, 5, 4) $dpr) "setDragImage(canvas, 5, 4) is the system's picture" $st.dragImage
  # setDragImage of an element 1000 px above the page: painted alone offscreen (its orange, opaque)
  Wren-Ctl eval "useImage = 'far'; 'ok'" | Out-Null
  Wren-Ctl drag '50,30' '-300,30' '100,150' --steps 8 | Out-Null
  Start-Sleep -Milliseconds 200
  $st = Wren-Ctl stats --json | ConvertFrom-Json
  Expect ((Near-Image $st.dragImage @(60, 30, 6, 3) $dpr) -and $st.dragPicture -match 'rgba=255,136,0,255$') 'setDragImage of an element off the screen: painted alone' "$($st.dragImage) / $($st.dragPicture)"
  Wren-Ctl eval "useImage = false; 'ok'" | Out-Null

  # selected text of the document dragged: a picture of the selection (its lines highlighted), not the system's cursor
  Wren-Ctl eval "log.length = 0; const r = document.createRange(); r.selectNodeContents(txt); getSelection().removeAllRanges(); getSelection().addRange(r); 'ok'" | Out-Null
  Wren-Ctl drag '360,212' '-300,212' '100,150' --steps 8 | Out-Null
  Start-Sleep -Milliseconds 200
  $st = Wren-Ctl stats --json | ConvertFrom-Json
  $log = Wren-Ctl eval "log.join(' | ')"
  $selOk = $st.dragPicture -match '^(\d+)x(\d+)@' -and [int]$Matches[1] -ge 100 * $dpr -and [int]$Matches[2] -ge 18 * $dpr -and $st.dragPicture -notmatch ',0$'
  Expect ($selOk -and $st.dragImage -ne '') 'a selection of the document dragged: a picture of its text for the system' "$($st.dragImage) / $($st.dragPicture)"
  Expect ($log -match 'drop@zone files=0 text=select this text') '... and its text dropped on the zone' $log
  Wren-Ctl eval "getSelection().removeAllRanges(); 'ok'" | Out-Null

  # selected text of a field dragged into another: moved (deleteByDrag, insertFromDrop), dragend with move
  Wren-Ctl eval "log.length = 0; in1.focus(); in1.setSelectionRange(0, 5); 'ok'" | Out-Null
  Wren-Ctl drag '362,112' '450,162' --steps 6 | Out-Null
  Start-Sleep -Milliseconds 200
  $vals = Wren-Ctl eval "in1.value + '|' + in2.value"
  $log = Wren-Ctl eval "log.join(' | ')"
  Expect ($vals -eq ' world|hello') 'a field selection dragged to another field moves the text' "$vals / $log"
  Expect ($log -match 'beforeinput@in1 deleteByDrag' -and $log -match 'input@in2 insertFromDrop' -and $log -match 'dragend@in1 effect=move') '... with deleteByDrag, insertFromDrop and dragend move' $log

  # a file dropped on a file input (no script): it takes it, input and change
  Wren-Ctl eval "log.length = 0; 'ok'" | Out-Null
  Wren-Ctl drop $file --at '450,265' | Out-Null
  Start-Sleep -Milliseconds 300
  $fin = Wren-Ctl eval "fin.files.length + ' ' + (fin.files[0] && fin.files[0].name) + ' ' + location.pathname.endsWith('dnd.html')"
  $log = Wren-Ctl eval "log.join(' | ')"
  Expect ($fin -eq '1 dnd_e2e_drop.txt true') 'a file dropped on <input type=file> fills it (the page stays)' $fin
  Expect ($log -match 'input@fin' -and $log -match 'change@fin') '... with input and change' $log
  $st = Wren-Ctl stats --json | ConvertFrom-Json
  $net0 = $st.prefsNetApplied
  Wren-Ctl pref set browser.tabs.sidebar_width 300 | Out-Null
  $st = Wren-Ctl stats --json | ConvertFrom-Json
  Expect ($st.prefsNetApplied -eq $net0) 'writing browser.tabs.sidebar_width configures nothing of the network again' "$net0 -> $($st.prefsNetApplied)"

  Wren-Ctl drop $file --at '100,300' | Out-Null
  Start-Sleep -Milliseconds 800
  $href = Wren-Ctl eval 'location.href'
  Expect ($href -match 'dnd_e2e_drop\.txt$') 'a file dropped where nothing takes it opens' $href
} finally { Stop-Wren $name }
if ($fails -gt 0) { "dnd_e2e: $fails failure(s)"; exit 1 }
'dnd_e2e: all passed'
