# Long-run memory test of the browser: tabs opened and closed by the hundred, pages navigated by the hundred (JavaScript,
# images, forms, animations, the back/forward cache, the HTTP cache), with the memory measured after every cycle: the
# tracker's live bytes (every Odin allocation, src\base\memory.odin), the process's private bytes and working set (the
# native libraries, Direct3D, DirectWrite, the arenas), its kernel, GDI and USER handles. Fails when, once the caches
# have filled (the first -Warmup cycles), any of them still grows by more than its threshold, or when anything is left
# allocated at exit. A leak at exit is the check build's report; a growth here is memory that is freed at exit but not
# while the browser runs (a cache without a bound, a map never purged, a handle per page).
#   powershell -File tools\endurance.ps1 [-Cycles 40] [-TabsPerCycle 10] [-Warmup 20] [-NoNative] [-NoBuild] [-Out build\endurance] [-IdleMs 6500]
# After the last cycle the browser is left alone for -IdleMs (0: skipped): the "idle" row of the statistics is what it
# keeps once it has trimmed (browser.memory.trim_idle_ms, 5 s by default).
# Default: 400 tabs, 1 200 page loads and 800 back/forward steps; the native memory (Direct3D, the drivers, Wasmtime,
# the heap's own pages) settles after about 200 tabs, hence the long warm-up; the tracked memory and the handles are flat
# after the first cycles (a short run with -NoNative checks them: test_all -CI). The native memory is compared by its
# highest value over 5 cycles (it drops when caches trim: every ~100 tabs), the tracked bytes by their median.
# Writes <Out>\stats.csv (one line per cycle), <Out>\endurance.svg (the curves) and the places whose blocks grew after the
# warm-up (base.mem_snapshot). The check build drives itself (tools\memcheck_e2e.ps1: WREN_MEMCHECK_SCRIPT).
param([int]$Cycles = 40, [int]$TabsPerCycle = 10, [int]$Warmup = 20, [switch]$NoBuild, [switch]$NoNative, [string]$Out = '', [string]$Exe = '', [int]$IdleMs = 6500, [string[]]$Pref = @(),
    [double]$MaxLiveGrowthMB = 0.5, [double]$MaxPrivateGrowthMB = 64, [int]$MaxHandleGrowth = 100, [int]$MaxGdiGrowth = 30, [int]$MaxUserGrowth = 20,
    [int]$TimeoutSec = 3600)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $Out) { $Out = Join-Path $root 'build\endurance' }
New-Item -ItemType Directory -Force $Out | Out-Null
$e2eArgs = @{ NoBuild = [bool]$NoBuild; Out = $Out; TimeoutSec = $TimeoutSec }
if ($Exe) { $e2eArgs.Exe = $Exe }
. (Join-Path $PSScriptRoot 'memcheck_e2e.ps1') @e2eArgs

$pages = 'js.html', 'images.html', 'forms.html', 'js-dom.html', 'animations.html', 'mutation.html', 'shadow-dom.html', 'layout.html',
    'media.html', 'style.html', 'text.html', 'grid.html', 'effects.html', 'modern-css.html', 'transforms.html', 'interaction.html'
$s = New-Object System.Collections.Generic.List[string]
$s.Add('load'); $s.Add('stats start')
$k = 0
for ($c = 1; $c -le $Cycles; $c++) {
    for ($t = 0; $t -lt $TabsPerCycle; $t++) {
        $a = $pages[$k % $pages.Count]; $b = $pages[($k + 5) % $pages.Count]; $d = $pages[($k + 11) % $pages.Count]; $k++
        $s.Add("open {o}/site/$a"); $s.Add('load')
        $s.Add("go {o}/site/$b"); $s.Add('load')
        $s.Add("go {o}/site/$d"); $s.Add('load'); $s.Add('frames 3')
        $s.Add('command nav.back'); $s.Add('load')        # the back/forward cache
        $s.Add('command nav.forward'); $s.Add('load'); $s.Add('frames 3')
    }
    for ($t = 0; $t -lt $TabsPerCycle; $t++) { $s.Add('command tab.close') }
    $s.Add('frames 10'); $s.Add('wait 200')
    $s.Add("stats cycle$c")
    if ($c -eq $Warmup -or $c -eq $Cycles) { $s.Add("snapshot $(Join-Path $Out "snapshot_$c.txt")") }
    if ($c -eq 1 -or $c -eq $Cycles) { $s.Add("vmmap $(Join-Path $Out "vmmap_$c.txt")") }   # the biggest private allocations (memory_map_report)
}
# left alone: the browser gives memory back (browser.memory.trim_idle_ms, memory_trim.odin); the row "idle" is what stays
if ($IdleMs -gt 0) { $s.Add("idle $IdleMs"); $s.Add('frames 2'); $s.Add('stats idle') }
$s.Add('quit')
$csv = Join-Path $Out 'stats.csv'
# the browsing history is the user's data, kept up to history.global.max_visits: at its least here, so that it is full
# before the warm-up ends and its growth is not taken for a leak
$extraPrefs = @($Pref | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { '--pref'; $_ })
$code = Invoke-CheckSession 'endurance' $s.ToArray() $csv (@('--pref', 'history.global.max_visits=10') + $extraPrefs)
if (-not (Test-Path $csv)) { "FAIL no statistics written"; exit 1 }

$allRows = @(Import-Csv $csv)
$rows = @($allRows | Where-Object { $_.label -like 'cycle*' })
$idleRow = $allRows | Where-Object { $_.label -eq 'idle' } | Select-Object -First 1
if ($idleRow) { "after $IdleMs ms left alone: private $([math]::Round([double]$idleRow.private_bytes / 1MB, 1)) MB, working set $([math]::Round([double]$idleRow.working_set / 1MB, 1)) MB (heap used $([math]::Round([double]$idleRow.heap_allocated / 1MB, 1)) MB)" }
"cycles measured: $($rows.Count)"
$rows | Select-Object label, @{n = 'live MB'; e = { [math]::Round([double]$_.live_bytes / 1MB, 2) } }, live_blocks,
    @{n = 'private MB'; e = { [math]::Round([double]$_.private_bytes / 1MB, 1) } }, @{n = 'WS MB'; e = { [math]::Round([double]$_.working_set / 1MB, 1) } },
    handles, gdi, user, tabs | Format-Table -AutoSize | Out-String -Width 200
# who holds what: the process heaps (allocated / committed), the other private pages (read-write / executable), the
# Wasmtime module cache and instances, the bytecode, image and web-font caches (columns written when the build has them)
if ($rows.Count -gt 0 -and $rows[0].PSObject.Properties['heap_allocated']) {
    "who holds the private bytes (MB; caches: entries / MB):"
    $rows | Select-Object label, @{n = 'private'; e = { [math]::Round([double]$_.private_bytes / 1MB, 1) } },
        @{n = 'heap used'; e = { [math]::Round([double]$_.heap_allocated / 1MB, 1) } }, @{n = 'heap committed'; e = { [math]::Round([double]$_.heap_committed / 1MB, 1) } },
        @{n = 'vm rw'; e = { [math]::Round([double]$_.vm_rw / 1MB, 1) } }, @{n = 'vm exec'; e = { [math]::Round([double]$_.vm_exec / 1MB, 1) } },
        @{n = 'wasm modules'; e = { "$($_.wasm_modules) / $([math]::Round([double]$_.wasm_code_bytes / 1MB, 1))" } }, @{n = 'wasm inst'; e = { $_.wasm_instances } },
        @{n = 'js bytecode'; e = { "$($_.js_entries) / $([math]::Round([double]$_.js_bytes / 1MB, 1))" } },
        @{n = 'images'; e = { "$($_.img_entries) / $([math]::Round([double]$_.img_bytes / 1MB, 1))" } },
        @{n = 'fonts'; e = { "$($_.font_entries) / $([math]::Round([double]$_.font_bytes / 1MB, 1))" } } | Format-Table -AutoSize | Out-String -Width 220
}

function Median($v) { $x = @($v | Sort-Object); if ($x.Count -eq 0) { return 0 }; return [double]$x[[int][math]::Floor($x.Count / 2)] }
$failed = $code -ne 0
if ($rows.Count -lt $Warmup + 4) { "FAIL too few cycles after the warm-up ($($rows.Count))"; exit 1 }
$win = [math]::Min(5, [math]::Max(1, [int]($rows.Count - $Warmup) / 2))
$base = $rows[$Warmup..($Warmup + $win - 1)]
$last = $rows[($rows.Count - $win)..($rows.Count - 1)]
function Highest($v) { return [double]($v | Measure-Object -Maximum).Maximum }
$checks = @(
    @{ Name = 'tracked live bytes'; Col = 'live_bytes'; Max = $MaxLiveGrowthMB * 1MB; Unit = 1MB; U = 'MB'; Agg = 'Median' }
    @{ Name = 'private bytes'; Col = 'private_bytes'; Max = $MaxPrivateGrowthMB * 1MB; Unit = 1MB; U = 'MB'; Agg = 'Highest'; Native = $true }
    @{ Name = 'kernel handles'; Col = 'handles'; Max = $MaxHandleGrowth; Unit = 1; U = '' }
    @{ Name = 'GDI objects'; Col = 'gdi'; Max = $MaxGdiGrowth; Unit = 1; U = '' }
    @{ Name = 'USER objects'; Col = 'user'; Max = $MaxUserGrowth; Unit = 1; U = '' }
)
foreach ($ch in $checks) {
    $agg = if ($ch.Agg) { $ch.Agg } else { 'Highest' }
    $b0 = & $agg ($base | ForEach-Object { [double]$_.($ch.Col) }); $b1 = & $agg ($last | ForEach-Object { [double]$_.($ch.Col) })
    $g = $b1 - $b0
    $ok = $g -le $ch.Max
    if ($ch.Native -and $NoNative) { "INFO {0}: {1:N1} MB after the warm-up, {2:N1} MB at the end (not checked: -NoNative)" -f $ch.Name, ($b0 / 1MB), ($b1 / 1MB); continue }
    if (-not $ok) { $failed = $true }
    "{0} {1}: {2:N2}{4} after the warm-up, {3:N2}{4} at the end (growth {5:N2}{4}, at most {6:N2}{4})" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $ch.Name, ($b0 / $ch.Unit), ($b1 / $ch.Unit), $ch.U, ($g / $ch.Unit), ($ch.Max / $ch.Unit)
}

# what grew between the end of the warm-up and the end, by place of allocation
$snapA = Join-Path $Out "snapshot_$Warmup.txt"; $snapB = Join-Path $Out "snapshot_$Cycles.txt"
if ((Test-Path $snapA) -and (Test-Path $snapB)) {
    $before = @{}; foreach ($l in Get-Content $snapA) { $f3 = $l -split "`t", 3; $before[$f3[2]] = @([int]$f3[0], [long]$f3[1]) }
    $grew = foreach ($l in Get-Content $snapB) {
        $f3 = $l -split "`t", 3; $o = $before[$f3[2]]; $db = [int]$f3[0] - $(if ($o) { $o[0] } else { 0 }); $dz = [long]$f3[1] - $(if ($o) { $o[1] } else { 0 })
        if ($db -gt 0 -or $dz -gt 4096) { [pscustomobject]@{ Blocks = $db; Bytes = $dz; Place = $f3[2] -replace '.*/(src|ext)/', '' } }
    }
    if ($grew) { "grew after the warm-up (blocks, bytes, place):"; $grew | Sort-Object Bytes -Descending | Select-Object -First 25 | ForEach-Object { "  {0,6} {1,10} {2}" -f $_.Blocks, $_.Bytes, $_.Place } }
}

# the curves (SVG): every series scaled to its own range, one line each
$w = 900; $h = 360; $padL = 50; $padB = 30
$series = @(@{ Col = 'live_bytes'; Color = '#d33'; Name = 'tracked live bytes' }, @{ Col = 'private_bytes'; Color = '#36c'; Name = 'private bytes' },
    @{ Col = 'working_set'; Color = '#9a3'; Name = 'working set' }, @{ Col = 'handles'; Color = '#a5c'; Name = 'handles' }, @{ Col = 'gdi'; Color = '#e90'; Name = 'GDI' })
$svg = New-Object System.Text.StringBuilder
[void]$svg.Append("<svg xmlns='http://www.w3.org/2000/svg' width='$w' height='$h' font-family='Segoe UI' font-size='12'><rect width='100%' height='100%' fill='white'/>")
[void]$svg.Append("<line x1='$padL' y1='$($h - $padB)' x2='$($w - 10)' y2='$($h - $padB)' stroke='#888'/><text x='$padL' y='$($h - 8)'>cycle 1</text><text x='$($w - 70)' y='$($h - 8)'>cycle $($rows.Count)</text>")
$wx = $padL + ($w - $padL - 10) * $Warmup / [math]::Max(1, $rows.Count - 1)
[void]$svg.Append("<line x1='$wx' y1='10' x2='$wx' y2='$($h - $padB)' stroke='#bbb' stroke-dasharray='4'/><text x='$($wx + 4)' y='22' fill='#888'>warm-up</text>")
$ly = 40
foreach ($se in $series) {
    $v = @($rows | ForEach-Object { [double]$_.($se.Col) }); $mn = ($v | Measure-Object -Minimum).Minimum; $mx = ($v | Measure-Object -Maximum).Maximum
    $span = [math]::Max($mx - $mn, [math]::Max(1, $mx * 0.05))
    $pts = for ($i = 0; $i -lt $v.Count; $i++) { "{0:F1},{1:F1}" -f ($padL + ($w - $padL - 10) * $i / [math]::Max(1, $v.Count - 1)), (($h - $padB - 10) - ($h - $padB - 30) * ($v[$i] - $mn) / $span) }
    [void]$svg.Append("<polyline fill='none' stroke='$($se.Color)' stroke-width='2' points='$($pts -join ' ')'/>")
    $label = if ($se.Col -like '*bytes' -or $se.Col -eq 'working_set') { '{0}: {1:N1} - {2:N1} MB' -f $se.Name, ($mn / 1MB), ($mx / 1MB) } else { '{0}: {1} - {2}' -f $se.Name, $mn, $mx }
    [void]$svg.Append("<text x='$($w - 300)' y='$ly' fill='$($se.Color)'>$label</text>"); $ly += 16
}
[void]$svg.Append('</svg>')
[IO.File]::WriteAllText((Join-Path $Out 'endurance.svg'), $svg.ToString())
"curves: $(Join-Path $Out 'endurance.svg'), statistics: $csv"
if ($failed) { 'FAIL endurance'; exit 1 }
'PASS endurance'
exit 0
