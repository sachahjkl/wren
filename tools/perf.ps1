# Measures the browser on real pages with real input. Needs build\browser_prof.exe (build.bat profile).
#   powershell -File tools\perf.ps1 [-Only name,name] [-NoSample] [-Exe browser_prof.exe] [-Tag suffix]
# Scenarios ending in _full run with layout.incremental.enabled=false (the reference for incremental layout).
# Writes build\perf\<run>.txt (per-phase statistics, CPU time, sampling profile) and <run>.csv (one row per frame).
param([string[]]$Only = @(), [switch]$NoSample, [string]$Exe = 'browser_prof.exe', [string]$Tag = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build\perf'
New-Item -ItemType Directory -Force $out | Out-Null
Add-Type @"
using System; using System.Runtime.InteropServices;
public class PF {
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X,Y; }
}
"@
[PF]::SetProcessDPIAware() | Out-Null
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

# ---------- test pages ----------
function Make-Page($name, [int]$elements, [int]$rules) {
    $path = Join-Path $out "$name.html"
    if (Test-Path $path) { return $path }
    $rnd = New-Object Random 42
    $css = New-Object Text.StringBuilder
    [void]$css.AppendLine("body{margin:0;font-size:15px;color:#223;background:#fafbff} .sec{margin:8px 16px;padding:8px;border:1px solid #ccd} article{padding:6px;margin:4px 0;background:#fff} h3{margin:0 0 4px;font-size:16px} p{margin:2px 0}")
    for ($i = 0; $i -lt $rules; $i++) {
        $c = '{0:x6}' -f ($rnd.Next(0x222222, 0xdddddd))
        switch ($i % 7) {
            0 { [void]$css.AppendLine(".c$i { color: #$c }") }
            1 { [void]$css.AppendLine(".sec .c$i p { padding: $($i % 5)px }") }
            2 { [void]$css.AppendLine("article > p.c$i { margin-left: $($i % 9)px }") }
            3 { [void]$css.AppendLine("[data-k='$i'] { border-left: 2px solid #$c }") }
            4 { [void]$css.AppendLine("article:nth-child(3n+$($i % 3)) span.c$i { font-weight: bold }") }
            5 { [void]$css.AppendLine("section article span.c$i, h3.c$i { text-decoration: underline }") }
            6 { [void]$css.AppendLine(".c$i:hover { background: #$c }") }
        }
    }
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("<!doctype html><html><head><meta charset=utf-8><title>$name</title><style>$($css.ToString())</style></head><body><main>")
    $words = 'lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua'.Split(' ')
    $made = 0; $k = 0
    while ($made -lt $elements) {
        [void]$sb.Append("<section class='sec c$($k % $rules)'>"); $made++
        for ($a = 0; $a -lt 5; $a++) {
            [void]$sb.Append("<article data-k='$($k % $rules)'><h3 class='c$(($k * 3) % $rules)'>Title $k</h3>"); $made += 2
            [void]$sb.Append("<p class='c$(($k * 7) % $rules)'>")
            $made++
            for ($s = 0; $s -lt 3; $s++) {
                $txt = (1..8 | ForEach-Object { $words[$rnd.Next($words.Length)] }) -join ' '
                [void]$sb.Append("<span class='c$(($k * 11 + $s) % $rules)'>$txt </span>"); $made++
            }
            [void]$sb.Append("</p></article>"); $k++
        }
        [void]$sb.AppendLine("</section>")
    }
    [void]$sb.AppendLine("</main></body></html>")
    [IO.File]::WriteAllText($path, $sb.ToString())
    return $path
}
$p1k  = Make-Page 'p1k'  1000 300
$p10k = Make-Page 'p10k' 10000 2000
$p50k = Make-Page 'p50k' 50000 5000
function FileUrl($p) { 'file:///' + ($p -replace '\\', '/') }

# ---------- driver ----------
function Run($name, $url, [scriptblock]$actions, [bool]$sample = $true, [string]$extra = '') {
    if ($Only.Count -gt 0 -and $Only -notcontains $name) { return }
    $prefix = Join-Path $out "$name$Tag"
    $env:WREN_PROF = $prefix
    $env:WREN_SAMPLE = if ($sample -and -not $NoSample) { '1' } else { '0' }
    $argv = (@($extra, $url) | Where-Object { $_ }) -join ' '
    $p = if ($argv) { Start-Process (Join-Path $root "build\$Exe") -ArgumentList $argv -PassThru } else { Start-Process (Join-Path $root "build\$Exe") -PassThru }
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not $p.HasExited -and $p.MainWindowHandle -eq 0 -and $sw.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 20; $p.Refresh() }
        $h = $p.MainWindowHandle
        & $actions $h
        [PF]::PostMessage($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null   # WM_CLOSE: the report is written on a clean exit
        if (-not $p.WaitForExit(30000)) { Write-Host "$name did not exit, killed"; $p.Kill() }
    } finally { if (-not $p.HasExited) { $p.Kill() } }
    Write-Host ("done {0}" -f $name)
}
function Client($h) { $r = New-Object PF+RECT; [PF]::GetClientRect($h, [ref]$r) | Out-Null; $r }
function MouseTo($h, $x, $y) { [PF]::PostMessage($h, 0x0200, [IntPtr]::Zero, [IntPtr](($y -shl 16) -bor ($x -band 0xFFFF))) | Out-Null }
function Wheel($h, $x, $y, $notches) {
    $pt = New-Object PF+POINT; $pt.X = $x; $pt.Y = $y; [PF]::ClientToScreen($h, [ref]$pt) | Out-Null
    $delta = [int](120 * $notches)
    $w = [IntPtr](($delta -shl 16) -band 0xFFFFFFFF)
    $l = [IntPtr](($pt.Y -shl 16) -bor ($pt.X -band 0xFFFF))
    [PF]::PostMessage($h, 0x020A, $w, $l) | Out-Null
}
function Hover($h, [int]$ms) {
    $c = Client $h; $sw = [Diagnostics.Stopwatch]::StartNew(); $i = 0
    while ($sw.ElapsedMilliseconds -lt $ms) {
        $t = $sw.ElapsedMilliseconds / 1000.0
        $x = [int]($c.R * (0.5 + 0.25 * [Math]::Sin($t * 3)))
        $y = [int]($c.B * (0.55 + 0.30 * [Math]::Sin($t * 1.7)))
        MouseTo $h $x $y; Start-Sleep -Milliseconds 8; $i++
    }
}
function Scroll($h, [int]$ms) {
    $c = Client $h; $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) { Wheel $h ($c.R / 2) ($c.B / 2) (-3); Start-Sleep -Milliseconds 16 }
}
function Resize($h, [int]$ms) {
    $r = New-Object PF+RECT; [PF]::GetWindowRect($h, [ref]$r) | Out-Null
    $w0 = $r.R - $r.L; $h0 = $r.B - $r.T; $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        $w = [int]($w0 * (0.8 + 0.2 * [Math]::Sin($sw.ElapsedMilliseconds / 400.0)))
        [PF]::SetWindowPos($h, [IntPtr]::Zero, $r.L, $r.T, $w, $h0, 0x14) | Out-Null; Start-Sleep -Milliseconds 16
    }
    [PF]::SetWindowPos($h, [IntPtr]::Zero, $r.L, $r.T, $w0, $h0, 0x14) | Out-Null
}

Run 'home_idle'  ''   { param($h) Start-Sleep 8 } $false
Run 'home_hover' ''   { param($h) Start-Sleep 2; Hover $h 8000 }
Run 'p1k_load'   (FileUrl $p1k)  { param($h) Start-Sleep 5 }
Run 'p1k_hover'  (FileUrl $p1k)  { param($h) Start-Sleep 3; Hover $h 8000 }
Run 'p1k_scroll' (FileUrl $p1k)  { param($h) Start-Sleep 3; Scroll $h 8000 }
Run 'p10k_load'  (FileUrl $p10k) { param($h) Start-Sleep 8 }
Run 'p10k_idle'  (FileUrl $p10k) { param($h) Start-Sleep 10 } $false
Run 'p10k_hover' (FileUrl $p10k) { param($h) Start-Sleep 5; Hover $h 8000 }
Run 'p10k_hover_nosample' (FileUrl $p10k) { param($h) Start-Sleep 5; Hover $h 8000 } $false
Run 'p10k_scroll' (FileUrl $p10k) { param($h) Start-Sleep 5; Scroll $h 8000 }
Run 'p10k_resize' (FileUrl $p10k) { param($h) Start-Sleep 5; Resize $h 6000 }
Run 'p50k_load'  (FileUrl $p50k) { param($h) Start-Sleep 20 }
Run 'p50k_scroll' (FileUrl $p50k) { param($h) Start-Sleep 20; Scroll $h 8000 }
$site = Join-Path $root 'examples\site'
Run 'anim'       (FileUrl (Join-Path $site 'animations.html')) { param($h) Start-Sleep 10 } $false
Run 'transforms' (FileUrl (Join-Path $site 'transforms.html')) { param($h) Start-Sleep 10 } $false
Run 'transforms_sample' (FileUrl (Join-Path $site 'transforms.html')) { param($h) Start-Sleep 10 }
# a module changes one text of a ~17 000-node page every 16 ms (examples/mutation): incremental layout
if ($Only.Count -eq 0 -or $Only -contains 'mutation' -or $Only -contains 'mutation_full') {
    $wasm = Join-Path $site 'mutation.wasm'
    if (-not (Test-Path $wasm)) {
        & odin build (Join-Path $root 'examples\mutation') -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator "-collection:web=$(Join-Path $root 'sdk\odin')" "-out:$wasm" -o:size
    }
}
Run 'mutation'   (FileUrl (Join-Path $site 'mutation.html')) { param($h) Start-Sleep 12 } $false
# the same with incremental layout off (every mutation lays the whole page out): the reference
$env:WREN_EXTRA_ARGS = ''
Run 'mutation_full' (FileUrl (Join-Path $site 'mutation.html')) { param($h) Start-Sleep 12 } $false '--pref layout.incremental.enabled=false'
Run 'p10k_resize_full' (FileUrl $p10k) { param($h) Start-Sleep 5; Resize $h 6000 } $true '--pref layout.incremental.enabled=false'
