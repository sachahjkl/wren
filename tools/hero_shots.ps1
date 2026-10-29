# The four pictures of the home page's hero (site\img\hero-css|js|shadow|config.webp): one Wren window with the same four tabs
# open (CSS effects, JavaScript in Wren, shadow DOM, Configuration), each picture with another tab in front: index.html puts
# clickable zones over the tabs of the picture, so the four must show the same strip, only the selected tab changing.
#   powershell -NoProfile -File tools\hero_shots.ps1 [-Out build\shots] [-NoConvert] [-Exe build\wren.exe]
# The window is read from the renderer (wren ctl shot): no window on the screen, nothing else to hold the desktop for.
param([string]$Out = 'build\shots', [switch]$NoConvert, [string]$Exe = '', [int]$Width = 1600, [int]$Height = 1000)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
if ($Exe) { $env:WREN_EXE = (Resolve-Path $Exe).Path }
. "$PSScriptRoot\wrenctl.ps1"
New-Item -ItemType Directory -Force $Out | Out-Null
$site = 'file:///' + ((Join-Path $root 'examples\site') -replace '\\', '/')
$pages = @(
    @{ n = 'hero-css';    u = "$site/effects.html" }
    @{ n = 'hero-js';     u = "$site/js.html" }
    @{ n = 'hero-shadow'; u = "$site/shadow-dom.html" }
    @{ n = 'hero-config'; u = 'about:config' }
)
Start-Wren -Size "${Width}x$Height" -Dpi 96 -Pref @('blocker.welcome_toast=false') | Out-Null
try {
    $ids = @()
    for ($i = 0; $i -lt $pages.Count; $i++) {
        if ($i -eq 0) { Wren-Nav -Url $pages[0].u -Wait stable | Out-Null } else { Wren-Ctl tab new $pages[$i].u | Out-Null; Wren-Ctl wait stable --timeout 30000 | Out-Null }
    }
    # the ids, in the order of the strip
    $ids = @((Wren-Ctl tabs) -split "\r?\n" | ForEach-Object { if ($_ -match '^\s*(\d+)') { $Matches[1] } } | Where-Object { $_ })
    if ($ids.Count -ne $pages.Count) { throw "expected $($pages.Count) tabs, got $($ids.Count): $($ids -join ', ')" }
    for ($i = 0; $i -lt $pages.Count; $i++) {
        Wren-Ctl tab activate $ids[$i] | Out-Null
        Wren-Ctl wait stable --timeout 30000 | Out-Null
        Start-Sleep -Milliseconds 600
        $png = Join-Path $Out "$($pages[$i].n).png"
        Wren-Ctl shot (Resolve-PathHere $png) --window --settle 6 | Out-Null
        if (-not (Test-Path $png)) { throw "no capture for $($pages[$i].n)" }
        "shot $($pages[$i].n)"
    }
} finally { try { Stop-Wren } catch { } }
if ($NoConvert) { return }
foreach ($p in $pages) { & magick (Join-Path $Out "$($p.n).png") -quality 82 "site\img\$($p.n).webp" }
"converted to site\img"
