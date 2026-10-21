# GPU time by step on a few pages and window sizes (needs build\browser_prof.exe, build.bat profile).
#   powershell -File tools\gpu_diag.ps1 [-Cases blank_anim,home,text_scroll,effects] [-Sizes 2000x1250,1280x800] [-Seconds 8]
#                                       [-Exe browser_prof.exe] [-Tag _x] [-Out dir] [-ExtraArgs '--pref a=b'] [-GpuSteps 1|2]
#                                       [-Load]   (-Load: build\gpuload.exe, odin build src/tools/gpuload, runs alongside to keep
#                                       the graphics clock at its maximum: the driver lowers it at low load, which inflates durations)
# Each run: the window is set to the client size, the page loads, the measured part (Seconds) starts, nvidia-smi samples the
# graphics clock and the performance state every 200 ms. Frames of the measured part are summarised per step (mean / p50 /
# p95, ms) in <Out>\summary.txt and summary.csv. The runs hold bench.lock (tools\test_env.ps1).
param([string[]]$Cases = @('blank_anim', 'blank_caret', 'home', 'text_scroll', 'effects'), [string[]]$Sizes = @('2000x1250', '1280x800'),
      [int]$Seconds = 8, [string]$Exe = 'browser_prof.exe', [string]$Tag = '', [string]$Out = '', [string]$ExtraArgs = '', [int]$GpuSteps = 1, [switch]$Load)
$ErrorActionPreference = 'Stop'
$Cases = @($Cases | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Sizes = @($Sizes | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$root = Split-Path $PSScriptRoot -Parent
if (-not $Out) { $Out = Join-Path $root 'build\gpudiag' }
if (-not [IO.Path]::IsPathRooted($Out)) { $Out = Join-Path (Get-Location).Path $Out }
New-Item -ItemType Directory -Force $Out | Out-Null
Add-Type @"
using System; using System.Runtime.InteropServices;
public class GD {
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
}
"@
[GD]::SetProcessDPIAware() | Out-Null
. (Join-Path $PSScriptRoot 'test_env.ps1')

$pages = Join-Path $Out 'pages'
New-Item -ItemType Directory -Force $pages | Out-Null
function FileUrl($p) { 'file:///' + ($p -replace '\\', '/') }
[IO.File]::WriteAllText("$pages\blank_anim.html", '<!doctype html><meta charset=utf-8><title>blank_anim</title><style>body{margin:0;background:#fff} .s{width:3px;height:3px;border-radius:2px;animation:slide 2s ease-in-out infinite alternate} @keyframes slide{from{margin-left:0;background-color:#2f9e44}to{margin-left:60px;background-color:#f08c00}}</style><body><div class=s></div></body>')
[IO.File]::WriteAllText("$pages\blank_caret.html", '<!doctype html><meta charset=utf-8><title>blank_caret</title><style>body{margin:0} input{margin:8px;width:300px}</style><input autofocus>')
$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine('<!doctype html><meta charset=utf-8><title>text_scroll</title><style>body{margin:0;font:15px sans-serif;color:#223} p{margin:6px 16px;max-width:900px}</style>')
$words = 'lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua'.Split(' ')
$rnd = New-Object Random 7
for ($i = 0; $i -lt 3000; $i++) { [void]$sb.AppendLine("<p>" + ((1..40 | % { $words[$rnd.Next($words.Length)] }) -join ' ') + "</p>") }
[IO.File]::WriteAllText("$pages\text_scroll.html", $sb.ToString())

function Client($h) { $r = New-Object GD+RECT; [GD]::GetClientRect($h, [ref]$r) | Out-Null; $r }
function MouseTo($h, $x, $y) { [GD]::PostMessage($h, 0x0200, [IntPtr]::Zero, [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF))) | Out-Null }
function Wheel($h, $x, $y, $notches) {
    $pt = New-Object GD+POINT; $pt.X = $x; $pt.Y = $y; [GD]::ClientToScreen($h, [ref]$pt) | Out-Null
    $w = [IntPtr](([int](120 * $notches) -shl 16) -band 0xFFFFFFFF)
    [GD]::PostMessage($h, 0x020A, $w, [IntPtr](($pt.Y -shl 16) -bor ($pt.X -band 0xFFFF))) | Out-Null
}
function Hover($h, [int]$ms) {
    $c = Client $h; $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        $t = $sw.ElapsedMilliseconds / 1000.0
        MouseTo $h ([int]($c.R * (0.5 + 0.25 * [Math]::Sin($t * 3)))) ([int]($c.B * (0.55 + 0.30 * [Math]::Sin($t * 1.7))))
        Start-Sleep -Milliseconds 8
    }
}
function Scroll($h, [int]$ms) {
    $c = Client $h; $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        $dir = if ([int]($sw.ElapsedMilliseconds / 2000) % 2 -eq 1) { 1 } else { -1 }
        Wheel $h ($c.R / 2) ($c.B / 2) (3 * $dir); Start-Sleep -Milliseconds 16
    }
}

$defs = @{
    blank_anim  = @{ url = (FileUrl "$pages\blank_anim.html"); act = { param($h, $ms) Start-Sleep -Milliseconds $ms } }
    blank_caret = @{ url = (FileUrl "$pages\blank_caret.html"); act = { param($h, $ms) Start-Sleep -Milliseconds $ms } }
    home        = @{ url = ''; act = { param($h, $ms) Hover $h $ms } }
    text_scroll = @{ url = (FileUrl "$pages\text_scroll.html"); act = { param($h, $ms) Scroll $h $ms } }
    effects     = @{ url = (FileUrl (Join-Path $root 'examples\site\effects.html')); act = { param($h, $ms) Start-Sleep -Milliseconds $ms } }
}

function Stat($v) {
    if (-not $v -or $v.Count -eq 0) { return @(0, 0, 0) }
    $s = @($v | Sort-Object); $n = $s.Count
    @((($s | Measure-Object -Average).Average), $s[[int][Math]::Floor(($n - 1) * 0.5)], $s[[int][Math]::Floor(($n - 1) * 0.95)])
}

$rows = New-Object Collections.Generic.List[object]
$report = New-Object Text.StringBuilder
foreach ($case in $Cases) {
    foreach ($size in $Sizes) {
        $cw, $ch = [int[]]($size -split 'x')
        $name = "${case}_${size}$Tag"
        $prefix = Join-Path $Out $name
        $env:WREN_PROF = $prefix; $env:WREN_SAMPLE = '0'; $env:WREN_GPU_STEPS = "$GpuSteps"
        $argv = (@($ExtraArgs, $defs[$case].url) | Where-Object { $_ }) -join ' '
        $bench = Enter-WrenLock bench "gpu_diag.ps1 $name"
        $p = $null; $smi = $null; $loadProc = $null
        try {
            if ($Load) { $loadProc = Start-Process (Join-Path $root 'build\gpuload.exe') -ArgumentList ($Seconds + 40) -PassThru -WindowStyle Hidden; Start-Sleep -Milliseconds 500 }
            $p = if ($argv) { Start-Process (Join-Path $root "build\$Exe") -ArgumentList $argv -PassThru } else { Start-Process (Join-Path $root "build\$Exe") -PassThru }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while (-not $p.HasExited -and $p.MainWindowHandle -eq 0 -and $sw.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 20; $p.Refresh() }
            $h = $p.MainWindowHandle
            # the outer size that gives the wanted client size
            $wr = New-Object GD+RECT; [GD]::GetWindowRect($h, [ref]$wr) | Out-Null; $c0 = Client $h
            $dw = ($wr.R - $wr.L) - $c0.R; $dh = ($wr.B - $wr.T) - $c0.B
            [GD]::SetWindowPos($h, [IntPtr]::Zero, 20, 20, $cw + $dw, $ch + $dh, 0x14) | Out-Null
            Start-Sleep -Seconds 4
            $c1 = Client $h; $dpi = [GD]::GetDpiForWindow($h)
            $smiFile = "$prefix.smi.csv"
            $smi = Start-Process nvidia-smi -ArgumentList '--query-gpu=timestamp,clocks.gr,clocks.max.gr,pstate,utilization.gpu,power.draw','--format=csv,noheader','-lms','200' -RedirectStandardOutput $smiFile -PassThru -WindowStyle Hidden
            $actMs = $sw.ElapsedMilliseconds
            $action = $defs[$case].act
            & $action $h ($Seconds * 1000)
            [IO.File]::WriteAllText("$prefix.act", "$actMs")
            Stop-Process -Id $smi.Id -Force; $smi = $null
            [GD]::PostMessage($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
            if (-not $p.WaitForExit(30000)) { Write-Host "$name did not exit, killed"; $p.Kill() }
        } finally {
            if ($smi -and -not $smi.HasExited) { Stop-Process -Id $smi.Id -Force }
            if ($loadProc -and -not $loadProc.HasExited) { Stop-Process -Id $loadProc.Id -Force }
            if ($p -and -not $p.HasExited) { $p.Kill(); $p.WaitForExit(5000) | Out-Null }
            Exit-WrenLock $bench
        }
        # summary of the measured part
        $csv = Import-Csv "$prefix.csv"
        $actT = [double][IO.File]::ReadAllText("$prefix.act")
        $f = @($csv | Where-Object { [double]$_.t_ms -ge $actT + 1000 -and $_.gpu_ms -ne '' -and [double]$_.gpu_ms -gt 0 })
        $all = @($csv | Where-Object { [double]$_.t_ms -ge $actT + 1000 })
        $span = if ($all.Count -gt 1) { ([double]$all[-1].t_ms - [double]$all[0].t_ms) / 1000 } else { 0 }
        $fps = if ($span -gt 0) { $all.Count / $span } else { 0 }
        $clk = @(Get-Content $smiFile | % { $x = $_ -split ','; if ($x.Count -ge 4) { [double](($x[1] -replace '[^0-9.]', '')) } } | Where-Object { $_ })
        $ps = @(Get-Content $smiFile | % { $x = $_ -split ','; if ($x.Count -ge 6) { $x[3].Trim() } } | Group-Object | % { "$($_.Name)x$($_.Count)" }) -join ' '
        $clkMean = if ($clk.Count) { ($clk | Measure-Object -Average).Average } else { 0 }
        $row = [ordered]@{ case = $case; size = $size; client = "$($c1.R)x$($c1.B)"; dpi = $dpi; frames = $all.Count; fps = [Math]::Round($fps, 1); gpu_frames = $f.Count; clk_mhz = [Math]::Round($clkMean); pstates = $ps }
        $cols = @('gpu_ms') + @($csv[0].PSObject.Properties.Name | Where-Object { $_ -like 'gpu_*_ms' })
        foreach ($col in $cols) {
            $s = Stat @($f | % { [double]$_.$col })
            $key = $col -replace '^gpu_', '' -replace '_ms$', ''
            if ($col -eq 'gpu_ms') { $key = 'total' }
            $row["$key.mean"] = [Math]::Round($s[0], 3); $row["$key.p50"] = [Math]::Round($s[1], 3); $row["$key.p95"] = [Math]::Round($s[2], 3)
        }
        $rows.Add([pscustomobject]$row)
        Write-Host ("{0} {1}: client {2} dpi {3}, {4} frames @ {5} fps, GPU {6} ms (p95 {7}), clock {8} MHz [{9}]" -f $case, $size, $row.client, $dpi, $row.frames, $row.fps, $row['total.mean'], $row['total.p95'], $row.clk_mhz, $ps)
    }
}
$rows | Export-Csv (Join-Path $Out "summary$Tag.csv") -NoTypeInformation
$rows | Format-List | Out-File (Join-Path $Out "summary$Tag.txt") -Width 250
