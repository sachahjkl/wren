# Frame costs while a real page is resized, WITHOUT any window on the desktop: a profile build (build\wren_prof.exe) started
# --headless (its window is never shown, frames are rendered into the render target), driven by `wren ctl` (window --size,
# synthetic mouse events). One line per scenario: frames of the resize, CPU time of a frame (without its waits and its present)
# p50 / p95 / max, the phases that took it, layouts and style passes.
#   powershell -File tools\rsz_headless_bench.ps1 -Url https://sacha.house [-Mode win|split|both] [-Steps 120] [-Tag x] [-Pref a=b] [-Tab console] [-Out dir]
# -Url may be repeated by commas (about:home,https://sacha.house). Needs no desktop.lock: nothing is shown, nothing takes the focus.
param([string]$Url = 'about:home', [string]$Mode = 'both', [int]$Steps = 120, [string]$Tag = '', [string[]]$Pref = @(), [string]$Tab = 'console',
      [string]$Out = '', [string]$Exe = 'wren_prof.exe', [string]$Size = '1280x800', [string]$Dock = 'right')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'test_env.ps1')
. (Join-Path $PSScriptRoot 'wrenctl.ps1')
$script:WrenExe = Join-Path $root "build\$Exe"
if (-not $Out) { $Out = Join-Path $root 'build\rszhead' }
New-Item -ItemType Directory -Force $Out | Out-Null
$Pref = @($Pref | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$ww, $wh = $Size -split 'x' | ForEach-Object { [int]$_ }

function Pct($v, $p) { if ($v.Count -eq 0) { return 0 }; $s = @($v | Sort-Object); $s[[Math]::Min($s.Count - 1, [Math]::Max(0, [int][Math]::Ceiling($s.Count * $p / 100) - 1))] }
function Rnd($x, $n = 2) { [math]::Round([double]$x, $n) }

function Run-One([string]$name, [string]$url, [string]$what) {
    $prefix = Join-Path $Out "$name$Tag"
    Remove-Item "$prefix.*" -ErrorAction SilentlyContinue
    $env:WREN_PROF = $prefix; $env:WREN_SAMPLE = '0'
    $prefs = if ($what -eq 'split') { @('browser.devtools.visible=true', "browser.devtools.tab=$Tab", "browser.devtools.dock=$Dock") } else { @('browser.devtools.visible=false') }
    $prefs = @($prefs) + @($Pref)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $null = Start-Wren -Size $Size -Dpi 96 -Pref $prefs -Url $url   # no window is shown
    try {
        Wren-Ctl wait load --timeout 60000 | Out-Null
        Start-Sleep -Seconds 6   # the page settles (scripts, fonts, images)
        $t0 = $clock.ElapsedMilliseconds
        if ($what -eq 'win') {
            for ($i = 0; $i -lt $Steps; $i++) {
                $t = $i / 12.0
                $w = [int]($ww * (0.8 + 0.2 * [Math]::Sin($t)))
                $h = [int]($wh * (0.8 + 0.2 * [Math]::Sin($t * 0.7)))
                Wren-Ctl window --size "${w}x$h" | Out-Null
            }
        } else {
            # the splitter of the panel docked at the right: 5 px wide, left of the 300 px panel
            $sc = 1.0
            $x0 = [int]($ww - 302.5 * $sc); $y = [int]($wh * 0.5)
            # (ctl drag injects its steps at once: one frame; a call per step gives each its own frame)
            function Mouse([string]$type, [int]$x, [int]$y) {
                Wren-Ctl raw ('{"method":"Input.dispatchMouseEvent","params":{"type":"' + $type + '","x":' + $x + ',"y":' + $y + ',"button":"left","space":"window"}}') | Out-Null
            }
            Mouse mouseMoved $x0 $y; Mouse mousePressed $x0 $y
            for ($i = 1; $i -le $Steps; $i++) { Mouse mouseMoved ([int]($x0 - 250 * [Math]::Sin($i / ($Steps / 3.0)) * 0.5 - 125 * (1 - [Math]::Cos($i / ($Steps / 3.0))) * 0.0)) $y }
            Mouse mouseReleased ($x0 - 100) $y
        }
        $t1 = $clock.ElapsedMilliseconds
        Start-Sleep -Milliseconds 300
    } finally { Wren-Ctl quit | Out-Null; if ($global:WrenExit -ne 0) { Stop-Wren }; Start-Sleep -Milliseconds 500 }   # (quit waits for the end: the profile is written then)
    [IO.File]::WriteAllText("$prefix.act", "$t0 $t1")
    if (-not (Test-Path "$prefix.csv")) { Write-Host "$name : no profile"; return }
    $d = @(Import-Csv "$prefix.csv" | Where-Object { [double]$_.t_ms -ge $t0 -and [double]$_.t_ms -le $t1 })
    if ($d.Count -lt 3) { Write-Host "$name : $($d.Count) frames"; return }
    $cpu = @($d | ForEach-Object { [double]$_.Frame - [double]$_.Wait - [double]$_.Present })
    function Avg($c) { Rnd (($d | ForEach-Object { [double]$_.$c } | Measure-Object -Average).Average) }
    $laid = @($d | Where-Object { [double]$_.Layout -gt 0 }).Count
    $txt = if (Test-Path "$prefix.txt") { (Get-Content "$prefix.txt" | Select-String 'style passes:' | Select-Object -First 1).Line } else { '' }
    $full = if ($txt -match 'full (\d+) \((\d+) ms') { "$($Matches[1]) ($($Matches[2]) ms)" } else { '?' }
    $cqp = if ($txt -match 'container sizes (\d+) \((\d+) ms') { "$($Matches[1]) ($($Matches[2]) ms)" } else { '-' }
    [pscustomobject]@{ run = "$name$Tag"; frames = $d.Count; cpu_p50 = Rnd (Pct $cpu 50); cpu_p95 = Rnd (Pct $cpu 95); cpu_max = Rnd ($cpu | Measure-Object -Maximum).Maximum
        gpu_p50 = Rnd (Pct @($d | ForEach-Object { [double]$_.gpu_ms }) 50); styles = Avg 'Styles'; layout = Avg 'Layout'; build = Avg 'Build_UI'; draw = Avg 'UI_Draw'; paint = Avg 'Paint_Items'
        laid = $laid; full_style = $full; cq_partial = $cqp }
}

$rows = @()
foreach ($u in ($Url -split ',')) {
    $short = ($u -replace '[^A-Za-z0-9]+', '_').Trim('_')
    if ($Mode -in 'win', 'both') { $r = Run-One "win_$short" $u 'win'; if ($r) { $rows += $r } }
    if ($Mode -in 'split', 'both') { $r = Run-One "split_$short" $u 'split'; if ($r) { $rows += $r } }
}
foreach ($r in $rows) { Write-Host (($r.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' ') }
