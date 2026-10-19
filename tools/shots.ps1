# The screenshots of the README (docs\screenshots\*.png) and of the site (site\img\*.webp and *-640.webp), all taken
# the same way: the whole window (integrated title bar with the tabs, address bar, page, status bar), one size, one pass.
#   powershell -NoProfile -File tools\shots.ps1 [-Only home,css-grid] [-Width 1600] [-Height 1000] [-NoConvert]
# Takes the shared lock (S:\wb_wt\shared.lock when it exists) around the run: other runs wait instead of taking the
# screen at the same time. Needs ImageMagick (magick) for the WebP files of the site.
param([string[]]$Only = @(), [int]$Width = 1600, [int]$Height = 1000, [switch]$NoConvert)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$site = 'file:///' + ((Join-Path $root 'examples\site') -replace '\\', '/')
$raw = Join-Path $root 'build\shots'
New-Item -ItemType Directory -Force $raw, docs\screenshots | Out-Null

# name, address, actions (tools\screenshot.ps1 -Actions), extra browser arguments
$shots = @(
    @{ n = 'home';                   u = 'about:home' }
    @{ n = 'demos';                  u = 'about:demos' }
    @{ n = 'css-effects';            u = "$site/effects.html" }
    @{ n = 'css-transforms';         u = "$site/transforms.html" }
    @{ n = 'css-grid';               u = "$site/grid.html" }
    @{ n = 'css-gradients';          u = "$site/gradients.html" }
    @{ n = 'masks-and-color-glyphs'; u = "$site/paint.html" }
    @{ n = 'text';                   u = "$site/text.html" }
    @{ n = 'wasm-counter';           u = "$site/index.html" }
    @{ n = 'sacha-house';            u = 'https://sacha.house'; w = 7000 }
    @{ n = 'webassembly-org';        u = 'https://webassembly.org/news/2026-01-21-states-of-webassembly/'; w = 7000 }
    @{ n = 'odin-lang-org';          u = 'https://odin-lang.org'; w = 7000 }
    @{ n = 'frame-statistics';       u = "$site/transforms.html"; a = 'wait:1500; key:Ctrl+Shift+B; wait:1200' }
    @{ n = 'about-config';           u = 'about:config' }
    @{ n = 'find';                   u = 'https://sacha.house/cv'; w = 6000; a = 'key:Ctrl+F; wait:300; type:Angular; wait:900' }
    @{ n = 'context-menu';           u = 'https://sacha.house/cv'; w = 6000; a = 'dclick:470,695; wait:300; rclick:470,695; wait:700' }
    @{ n = 'tabs';                   u = 'about:home'; a = 'key:Ctrl+L; wait:200; type:https://webassembly.org; key:Enter; wait:4000; key:Ctrl+T; wait:400; key:Ctrl+L; wait:200; type:https://sacha.house; key:Enter; wait:5000; key:Ctrl+T; wait:400; key:Ctrl+L; wait:200; type:about:demos; key:Enter; wait:1200; click:1500,560; wait:400' }
    @{ n = 'daylight';               u = 'https://sacha.house/cv'; w = 6000; x = @('--pref browser.ui.theme=daylight') }
)
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })   # powershell -File passes a,b,c as one string
if ($Only.Count) { $shots = $shots | Where-Object { $Only -contains $_.n } }

$lock = $null
if (Test-Path 'S:\wb_wt') { while ($true) { try { $lock = [IO.File]::Open('S:\wb_wt\shared.lock', 'OpenOrCreate', 'ReadWrite', 'None'); break } catch { Start-Sleep -Milliseconds 500 } } }
try {
    foreach ($s in $shots) {
        $png = Join-Path $raw "$($s.n).png"
        $wait = if ($s.w) { $s.w } else { 3000 }
        $args2 = @('-NoProfile', '-File', 'tools\screenshot.ps1', '-Url', $s.u, '-Width', $Width, '-Height', $Height, '-WaitMs', $wait)
        if ($s.x) { $args2 += @('-Extra') + $s.x }
        if ($s.a) { $args2 += @('-Out', (Join-Path $raw "$($s.n)_before.png"), '-Actions', "$($s.a); shot:$png") } else { $args2 += @('-Out', $png) }
        & powershell @args2 2>&1 | Out-String | Where-Object { $_.Trim() } | ForEach-Object { "$($s.n): $_" }
        if (Test-Path $png) { "shot $($s.n)" } else { "MISSING $($s.n)" }
    }
} finally { if ($lock) { $lock.Close() } }

if ($NoConvert) { return }
foreach ($s in $shots) {
    $png = Join-Path $raw "$($s.n).png"
    if (-not (Test-Path $png)) { continue }
    Copy-Item $png "docs\screenshots\$($s.n).png" -Force
    & magick $png -quality 82 "site\img\$($s.n).webp"
    & magick $png -resize 640x -quality 80 "site\img\$($s.n)-640.webp"
}
"converted to docs\screenshots and site\img"
