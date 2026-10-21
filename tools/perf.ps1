# Measures the browser on real pages with real input. Needs build\browser_prof.exe (build.bat profile).
#   powershell -File tools\perf.ps1 [-Only name,name] [-NoSample] [-Exe browser_prof.exe] [-Tag suffix] [-Prefs '--pref a=b ...']
# -GpuSteps 1: the GPU time of each step of the frame too (a timestamp per step: totals grow a little; see the report's
# "GPU steps" table and the gpu_*_ms CSV columns). -GpuSteps 2: every draw call timed, the slowest listed.
# -Prefs is added to every run (e.g. '--pref wasm.wasmtime.compiler=winch' with -Tag _winch to compare the Wasm compilers).
# Scenarios ending in _full run with layout.incremental.enabled=false (the reference for incremental layout).
# Writes build\perf\<run>.txt (per-phase statistics, CPU time, sampling profile) and <run>.csv (one row per frame).
# Each scenario holds bench.lock (tools\test_env.ps1) while its browser runs: the measurements of several worktrees take
# turns instead of skewing each other. Input is posted to the window: no desktop.lock.
param([string[]]$Only = @(), [switch]$NoSample, [string]$Exe = 'browser_prof.exe', [string]$Tag = '', [string]$Prefs = '', [int]$GpuSteps = 0)
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
. (Join-Path $PSScriptRoot 'test_env.ps1')
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
# The same items in a grid and in a wrapping flex container (grid vs flex at an equal number of boxes)
function Make-ItemsPage($name, [string]$container, [string]$item, [int]$count) {
    $path = Join-Path $out "$name.html"
    if (Test-Path $path) { return $path }
    $words = 'lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor'.Split(' ')
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("<!doctype html><html><head><meta charset=utf-8><title>$name</title><style>body{margin:0;font-size:14px;background:#f4f6fb} .c{$container;padding:8px} .it{$item;background:#fff;border:1px solid #ccd;border-radius:6px;padding:6px} .it b{display:block}</style></head><body><div class=c>")
    for ($i = 0; $i -lt $count; $i++) {
        [void]$sb.Append("<div class=it><b>Item $i</b>$($words[$i % $words.Length]) $($words[($i * 7) % $words.Length]) $($words[($i * 3) % $words.Length])</div>")
    }
    [void]$sb.AppendLine("</div></body></html>")
    [IO.File]::WriteAllText($path, $sb.ToString())
    return $path
}
$g10k = Make-ItemsPage 'grid10k' 'display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:6px' '' 10000
$f10k = Make-ItemsPage 'flex10k' 'display:flex;flex-wrap:wrap;gap:6px' 'flex:1 1 140px' 10000

# A text field (focused on load) above a long page: typing restyles and lays out one line
function Make-TypingPage($name) {
    $path = Join-Path $out "$name.html"
    if (Test-Path $path) { return $path }
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("<!doctype html><html><head><meta charset=utf-8><title>$name</title><style>body{margin:0;font:15px sans-serif} input,textarea{display:block;margin:12px;width:600px;font-size:16px} p{margin:4px 12px}</style></head><body>")
    [void]$sb.AppendLine("<input autofocus value='start '><textarea rows=4>notes</textarea>")
    for ($i = 0; $i -lt 2000; $i++) { [void]$sb.AppendLine("<p>Paragraph $i lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor.</p>") }
    [void]$sb.AppendLine("</body></html>")
    [IO.File]::WriteAllText($path, $sb.ToString())
    return $path
}
$typing = Make-TypingPage 'typing'
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
    $env:WREN_GPU_STEPS = "$GpuSteps"
    $argv = (@($Prefs, $extra, $url) | Where-Object { $_ }) -join ' '
    # one measurement at a time on the machine (tools\test_env.ps1): another run's would skew it; input is posted, so
    # the desktop is not needed
    $bench = Enter-WrenLock bench "perf.ps1 $name"
    $p = $null
    try {
        $p = if ($argv) { Start-Process (Join-Path $root "build\$Exe") -ArgumentList $argv -PassThru } else { Start-Process (Join-Path $root "build\$Exe") -PassThru }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $script:runSw = $sw; $script:actMs = -1
        while (-not $p.HasExited -and $p.MainWindowHandle -eq 0 -and $sw.ElapsedMilliseconds -lt 10000) { Start-Sleep -Milliseconds 20; $p.Refresh() }
        $h = $p.MainWindowHandle
        & $actions $h
        # when the input began (Mark), on the profile's clock (ms since the process started, about): perf_summary -Budget
        # counts the frames from there on
        if ($script:actMs -ge 0) { [IO.File]::WriteAllText("$prefix.act", "$script:actMs") } elseif (Test-Path "$prefix.act") { Remove-Item "$prefix.act" }
        [PF]::PostMessage($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null   # WM_CLOSE: the report is written on a clean exit
        if (-not $p.WaitForExit(30000)) { Write-Host "$name did not exit, killed"; $p.Kill() }
    } finally { if ($p -and -not $p.HasExited) { $p.Kill(); $p.WaitForExit(5000) | Out-Null }; Exit-WrenLock $bench }
    Write-Host ("done {0}" -f $name)
}
function Mark { $script:actMs = $script:runSw.ElapsedMilliseconds }   # the measured part starts (after the load)
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
# A fast wheel: one notch (or `units` / 120 of one: a high-resolution wheel, a touchpad) every `every` ms
function WheelStream($h, [int]$ms, [int]$every = 4, [int]$units = -120) {
    $c = Client $h; $sw = [Diagnostics.Stopwatch]::StartNew(); $next = 0
    while ($sw.ElapsedMilliseconds -lt $ms) {
        if ($sw.ElapsedMilliseconds -ge $next) { Wheel $h ($c.R / 2) ($c.B / 2) ($units / 120.0); $next += $every }
        # back and forth so a long run never sits at an end of the page
        if ([int]($sw.ElapsedMilliseconds / 2000) % 2 -eq 1) { $units = [Math]::Abs($units) } else { $units = -[Math]::Abs($units) }
        [Threading.Thread]::Yield() | Out-Null
    }
}
function Key($h, [int]$vk) {
    [PF]::PostMessage($h, 0x0100, [IntPtr]$vk, [IntPtr]1) | Out-Null
    [PF]::PostMessage($h, 0x0101, [IntPtr]$vk, [IntPtr](0xC0000001 -band 0xFFFFFFFF)) | Out-Null
}
# Keyboard scrolling: Page Down x4, Page Up x4, arrows held (auto-repeat rate), Space, Home, End
function Keys($h, [int]$ms) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        foreach ($vk in 0x22, 0x22, 0x22, 0x22, 0x21, 0x21, 0x21, 0x21) { Key $h $vk; Start-Sleep -Milliseconds 220 }
        for ($i = 0; $i -lt 30; $i++) { [PF]::PostMessage($h, 0x0100, [IntPtr]0x28, [IntPtr](0x40000001)) | Out-Null; Start-Sleep -Milliseconds 33 }
        [PF]::PostMessage($h, 0x0101, [IntPtr]0x28, [IntPtr](0xC0000001 -band 0xFFFFFFFF)) | Out-Null
        Key $h 0x20; Start-Sleep -Milliseconds 300; Key $h 0x23; Start-Sleep -Milliseconds 400; Key $h 0x24; Start-Sleep -Milliseconds 400
    }
}
# Typing in the focused field: a character every 30 ms, a Backspace now and then
function Typing($h, [int]$ms) {
    $sw = [Diagnostics.Stopwatch]::StartNew(); $text = 'the quick brown fox jumps over the lazy dog '; $i = 0
    while ($sw.ElapsedMilliseconds -lt $ms) {
        $ch = [int][char]$text[$i % $text.Length]; $i++
        [PF]::PostMessage($h, 0x0102, [IntPtr]$ch, [IntPtr]1) | Out-Null
        if ($i % 17 -eq 0) { Key $h 0x08 }
        Start-Sleep -Milliseconds 30
    }
}
# Fast pointer: a move every 2 ms (a 1000 Hz mouse sends more; the window coalesces them anyway)
function HoverFast($h, [int]$ms) {
    $c = Client $h; $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        $t = $sw.ElapsedMilliseconds / 1000.0
        MouseTo $h ([int]($c.R * (0.5 + 0.4 * [Math]::Sin($t * 7)))) ([int]($c.B * (0.55 + 0.35 * [Math]::Sin($t * 4.3))))
        $sw2 = [Diagnostics.Stopwatch]::StartNew(); while ($sw2.ElapsedTicks -lt [Diagnostics.Stopwatch]::Frequency / 500) { }
    }
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
function ResizeDrag($h, [int]$ms, [int]$every = 4) {
    $r = New-Object PF+RECT; [PF]::GetWindowRect($h, [ref]$r) | Out-Null
    $w0 = $r.R - $r.L; $h0 = $r.B - $r.T; $sw = [Diagnostics.Stopwatch]::StartNew(); $next = 0
    while ($sw.ElapsedMilliseconds -lt $ms) {
        if ($sw.ElapsedMilliseconds -ge $next) {
            $w = [int]($w0 * (0.8 + 0.2 * [Math]::Sin($sw.ElapsedMilliseconds / 400.0)))
            [PF]::SetWindowPos($h, [IntPtr]::Zero, $r.L, $r.T, $w, $h0, 0x14) | Out-Null
            $next = $sw.ElapsedMilliseconds + $every
        }
        [Threading.Thread]::Yield() | Out-Null
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
Run 'grid10k_load'   (FileUrl $g10k) { param($h) Start-Sleep 8 }
Run 'grid10k_resize' (FileUrl $g10k) { param($h) Start-Sleep 5; Resize $h 6000 }
Run 'flex10k_load'   (FileUrl $f10k) { param($h) Start-Sleep 8 }
Run 'flex10k_resize' (FileUrl $f10k) { param($h) Start-Sleep 5; Resize $h 6000 }
$site = Join-Path $root 'examples\site'
Run 'anim'       (FileUrl (Join-Path $site 'animations.html')) { param($h) Start-Sleep 10 } $false
Run 'transforms' (FileUrl (Join-Path $site 'transforms.html')) { param($h) Start-Sleep 10 } $false
Run 'transforms_sample' (FileUrl (Join-Path $site 'transforms.html')) { param($h) Start-Sleep 10 }
Run 'effects'    (FileUrl (Join-Path $site 'effects.html')) { param($h) Start-Sleep 10 } $false
Run 'effects_hover' (FileUrl (Join-Path $site 'effects.html')) { param($h) Start-Sleep 3; Hover $h 8000 }
# a module changes one text of a ~17 000-node page every 16 ms (examples/mutation): incremental layout
if ($Only.Count -eq 0 -or $Only -contains 'mutation' -or $Only -contains 'mutation_full') {
    $wasm = Join-Path $site 'mutation.wasm'
    if (-not (Test-Path $wasm)) {
        & odin build (Join-Path $root 'examples\mutation') -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator "-collection:web=$(Join-Path $root 'sdk\odin')" "-out:$wasm" -o:size
    }
}
Run 'mutation'   (FileUrl (Join-Path $site 'mutation.html')) { param($h) Start-Sleep 12 } $false
# a module toggles a class on the section in the middle of the same page every 16 ms, with rules that reach its
# descendants, children and next sibling (examples/mutation_class): incremental restyle
if ($Only.Count -eq 0 -or ($Only | Where-Object { $_ -like 'mutation_class*' })) {
    $wasm = Join-Path $site 'mutation_class.wasm'
    if (-not (Test-Path $wasm)) {
        & odin build (Join-Path $root 'examples\mutation_class') -target:freestanding_wasm32 -no-entry-point -default-to-nil-allocator "-collection:web=$(Join-Path $root 'sdk\odin')" "-out:$wasm" -o:size
    }
}
Run 'mutation_class' (FileUrl (Join-Path $site 'mutation_class.html')) { param($h) Start-Sleep 12 } $false
# the same with the partial restyle off (every mutation restyles the whole page): the reference
Run 'mutation_class_fullstyle' (FileUrl (Join-Path $site 'mutation_class.html')) { param($h) Start-Sleep 12 } $false '--pref style.incremental.enabled=false'
Run 'mutation_fullstyle' (FileUrl (Join-Path $site 'mutation.html')) { param($h) Start-Sleep 12 } $false '--pref style.incremental.enabled=false'
# the same with incremental layout off (every mutation lays the whole page out): the reference
$env:WREN_EXTRA_ARGS = ''
Run 'mutation_full' (FileUrl (Join-Path $site 'mutation.html')) { param($h) Start-Sleep 12 } $false '--pref layout.incremental.enabled=false'
Run 'p10k_resize_full' (FileUrl $p10k) { param($h) Start-Sleep 5; Resize $h 6000 } $true '--pref layout.incremental.enabled=false'
Run 'anim_full' (FileUrl (Join-Path $site 'animations.html')) { param($h) Start-Sleep 10 } $false '--pref layout.incremental.enabled=false'
# the same pages drawn item by item (no retained pictures): the reference for the compositor
Run 'transforms_nocomp' (FileUrl (Join-Path $site 'transforms.html')) { param($h) Start-Sleep 10 } $false '--pref render.compositor.enabled=false'
Run 'p10k_scroll_nocomp' (FileUrl $p10k) { param($h) Start-Sleep 5; Scroll $h 8000 } $true '--pref render.compositor.enabled=false'
Run 'gradients' (FileUrl (Join-Path $site 'gradients.html')) { param($h) Start-Sleep 8 } $false
# frame pacing at the monitor's rate (pacing.odin, smooth_scroll.odin): the report's first lines compare every frame to
# the budget (1000 / rate), count missed refreshes and the input -> screen latency. Add -Prefs '--pref
# browser.frame.target_hz=60' -Tag _60 (or 120, 144, 240) to simulate another rate.
Run 'p10k_wheel'     (FileUrl $p10k) { param($h) Start-Sleep 5; Mark; WheelStream $h 8000 4 -120 } $false
Run 'p50k_wheel'     (FileUrl $p50k) { param($h) Start-Sleep 20; Mark; WheelStream $h 8000 4 -120 } $false
Run 'p10k_touchpad'  (FileUrl $p10k) { param($h) Start-Sleep 5; Mark; WheelStream $h 8000 4 -30 } $false
Run 'p10k_keys'      (FileUrl $p10k) { param($h) Start-Sleep 5; Mark; Keys $h 8000 } $false
Run 'p10k_hover_fast' (FileUrl $p10k) { param($h) Start-Sleep 5; Mark; HoverFast $h 8000 } $false
Run 'typing'         (FileUrl $typing) { param($h) Start-Sleep 4; Mark; Typing $h 8000 } $false
Run 'p10k_resize_pacing' (FileUrl $p10k) { param($h) Start-Sleep 5; Mark; Resize $h 6000 } $false
# a window edge dragged by a fast mouse: a new width every 4 ms, on a steady clock (Resize sleeps 16 ms, which the timer
# resolution turns into 16 or 31 ms, and pauses let the compositor settle and record between steps)
Run 'p10k_resize_drag' (FileUrl $p10k) { param($h) Start-Sleep 5; Mark; ResizeDrag $h 6000 4 } $false
Run 'p50k_resize_drag' (FileUrl $p50k) { param($h) Start-Sleep 20; Mark; ResizeDrag $h 6000 4 } $false
# the same page with a media query on the width (as most sites have): every step restyles the whole page
$p10kmq = Join-Path $out 'p10k_mq.html'
if (-not (Test-Path $p10kmq)) { [IO.File]::WriteAllText($p10kmq, [IO.File]::ReadAllText($p10k).Replace('</style>', '@media (max-width: 400px) { h3 { font-size: 14px } }</style>')) }
Run 'p10k_mq_resize_drag' (FileUrl $p10kmq) { param($h) Start-Sleep 5; Mark; ResizeDrag $h 6000 4 } $false
Run 'anim_pacing'       (FileUrl (Join-Path $site 'animations.html')) { param($h) Start-Sleep 3; Mark; Start-Sleep 8 } $false
Run 'transforms_pacing' (FileUrl (Join-Path $site 'transforms.html')) { param($h) Start-Sleep 3; Mark; Start-Sleep 8 } $false
Run 'effects_pacing'    (FileUrl (Join-Path $site 'effects.html')) { param($h) Start-Sleep 3; Mark; Start-Sleep 8 } $false
Run 'effects_wheel'     (FileUrl (Join-Path $site 'effects.html')) { param($h) Start-Sleep 3; Mark; WheelStream $h 8000 4 -120 } $false
# JavaScript (examples/jsbench): pages driven by their scripts, at 180 Hz (frames are what the script costs, plus the
# restyle and layout it causes): 1000 boxes moved through style.transform each frame, 10 000 nodes built and removed
# each frame, 50 querySelectorAll per frame without a mutation
$jsb = Join-Path $root 'examples\jsbench'
Run 'js_anim1000' (FileUrl (Join-Path $jsb 'anim1000.html')) { param($h) Start-Sleep 3; Mark; Start-Sleep 8 } $false '--pref browser.frame.target_hz=180'
Run 'js_nodes10k' (FileUrl (Join-Path $jsb 'nodes10k.html')) { param($h) Start-Sleep 3; Mark; Start-Sleep 8 } $false '--pref browser.frame.target_hz=180'
Run 'js_qsa'      (FileUrl (Join-Path $jsb 'qsa_loop.html')) { param($h) Start-Sleep 3; Mark; Start-Sleep 8 } $false '--pref browser.frame.target_hz=180'
Run 'js_qsa_sample' (FileUrl (Join-Path $jsb 'qsa_loop.html')) { param($h) Start-Sleep 3; Mark; Start-Sleep 8 } $true '--pref browser.frame.target_hz=180'
Run 'js_anim1000_sample' (FileUrl (Join-Path $jsb 'anim1000.html')) { param($h) Start-Sleep 3; Mark; Start-Sleep 8 } $true '--pref browser.frame.target_hz=180'
# 1000 custom elements with shadow roots (adopted and own sheets, :host, ::slotted(), ::part(), :state()), 50 hosts'
# state and 20 slotted texts changed each frame: the scoped cascade and its partial restyle
Run 'js_shadow1000' (FileUrl (Join-Path $jsb 'shadow1000.html')) { param($h) Start-Sleep 4; Mark; Start-Sleep 8 } $false '--pref browser.frame.target_hz=180'
# real sites with JavaScript (network: figures depend on the connection; the style and layout phases do not)
Run 'site_sacha'   'https://sacha.house/' { param($h) Start-Sleep 10 } $false
Run 'site_clockin' 'https://clockin.sacha.house/' { param($h) Start-Sleep 10 } $false
Run 'site_mdn'     'https://developer.mozilla.org/en-US/docs/Web/JavaScript' { param($h) Start-Sleep 12 } $false
Run 'js_shadow1000_sample' (FileUrl (Join-Path $jsb 'shadow1000.html')) { param($h) Start-Sleep 4; Mark; Start-Sleep 8 } $true '--pref browser.frame.target_hz=180'
# JavaScript off: pages without scripts must cost what they cost before the engine existed. Compare these with the same
# scenarios of a build without JavaScript (-Exe <that build> -Tag _main): load, hover, scroll, an animation
Run 'nojs_p10k_load'   (FileUrl $p10k) { param($h) Start-Sleep 8 } $true '--pref javascript.enabled=false'
Run 'nojs_p10k_scroll' (FileUrl $p10k) { param($h) Start-Sleep 5; Mark; Scroll $h 8000 } $false '--pref javascript.enabled=false'
Run 'nojs_anim'        (FileUrl (Join-Path $site 'animations.html')) { param($h) Start-Sleep 3; Mark; Start-Sleep 8 } $false '--pref javascript.enabled=false'
