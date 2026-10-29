# Compares how Wren and Microsoft Edge (headless) draw the same pages: one screenshot of each, a side-by-side image
# (Edge on the left, Wren on the right), and the share of pixels that differ.
#   powershell -NoProfile -File tools\site_compare.ps1 -OutDir <folder> [-Urls a,b,c | -List sites.txt] [-Dark] [-Wait stable|load] [-Height 690]
# -Height 2400 draws a taller viewport in both browsers: the content further down the page, without scrolling (Wren's window is
# 110 px taller than its page area).
# The two browsers are asked for the same viewport (1280 x 690, the size of Wren's page area in a 1280 x 800 window at
# 96 dpi). Pages change between two loads (news, ads, dates): the number is a hint, the images are the judge.
param([string]$OutDir, [string[]]$Urls = @(), [string]$List = '', [switch]$Dark, [string]$Wait = 'stable', [int]$TimeoutMs = 45000, [string]$Exe = '', [int]$Height = 690)
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
if (-not $OutDir) { throw '-OutDir is required' }
if ($List) { $Urls += @(Get-Content $List | Where-Object { $_ -and $_ -notmatch '^\s*#' } | ForEach-Object { $_.Trim() }) }
$Urls = @($Urls | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if ($Urls.Count -eq 0) { throw 'no url: -Urls a,b or -List file' }
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$env:WREN_EXE = (Resolve-Path $Exe).Path
. "$PSScriptRoot\wrenctl.ps1"
Add-Type -AssemblyName System.Drawing
$edge = @('C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe', 'C:\Program Files\Microsoft\Edge\Application\msedge.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge is not installed' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$W = 1280; $H = $Height

function Slug([string]$u) { $s = ($u -replace '^https?://', '' -replace '[^A-Za-z0-9]+', '-').Trim('-'); if ($s.Length -gt 50) { $s = $s.Substring(0, 50) }; return $s }

# (Edge's children outlive a killed main process and keep the profile locked: the next shot then fails)
function Stop-CompareEdge {
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like '*wren-compare-edge*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Edge-Shot([string]$url, [string]$dest) {
    Stop-CompareEdge
    Remove-Item $dest -ErrorAction SilentlyContinue
    # (Edge takes its arguments unquoted from Start-Process: a path with a space would be several targets)
    $file = Join-Path $env:TEMP 'wren-compare-edge-shot.png'
    Remove-Item $file -ErrorAction SilentlyContinue
    $a = @('--headless=new', '--disable-gpu', '--hide-scrollbars', "--screenshot=$file", "--window-size=$W,$H", '--virtual-time-budget=10000', ('--user-data-dir=' + (Join-Path $env:TEMP 'wren-compare-edge')))
    $a += '--lang=en-US', '--accept-lang=en-US'
    # (observed with this Edge: no option follows Windows' dark theme, preferredColorScheme=1 gives the light one)
    if (-not $Dark) { $a += '--blink-settings=preferredColorScheme=1' }
    $p = Start-Process $edge -ArgumentList ($a + $url) -PassThru -NoNewWindow -RedirectStandardError (Join-Path $env:TEMP 'wren-compare-edge.err')
    if (-not $p.WaitForExit(90000)) { $p.Kill() }
    Stop-CompareEdge
    if (Test-Path $file) { Copy-Item $file $dest -Force; return $true }
    return $false
}

function Diff-Share([string]$a, [string]$b) {
    $x = New-Object System.Drawing.Bitmap $a; $y = New-Object System.Drawing.Bitmap $b
    try {
        $w = [Math]::Min($x.Width, $y.Width); $h = [Math]::Min($x.Height, $y.Height); $d = 0; $n = 0
        for ($j = 0; $j -lt $h; $j += 3) { for ($i = 0; $i -lt $w; $i += 3) {
            $p = $x.GetPixel($i, $j); $q = $y.GetPixel($i, $j); $n++
            if ([Math]::Abs($p.R - $q.R) + [Math]::Abs($p.G - $q.G) + [Math]::Abs($p.B - $q.B) -gt 60) { $d++ } } }
        return [Math]::Round(100.0 * $d / [Math]::Max($n, 1), 1)
    } finally { $x.Dispose(); $y.Dispose() }
}

function Side-By-Side([string]$left, [string]$right, [string]$out, [string]$title) {
    $x = New-Object System.Drawing.Bitmap $left; $y = New-Object System.Drawing.Bitmap $right
    $h = [Math]::Max($x.Height, $y.Height); $bar = 26
    $bmp = New-Object System.Drawing.Bitmap ($x.Width + $y.Width + 8), ($h + $bar)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(40, 40, 40))
    $font = New-Object System.Drawing.Font 'Segoe UI', 11
    $g.DrawString("Edge   |   $title   |   Wren", $font, [System.Drawing.Brushes]::White, 6, 3)
    $g.DrawImage($x, 0, $bar); $g.DrawImage($y, $x.Width + 8, $bar)
    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose(); $x.Dispose(); $y.Dispose(); $font.Dispose()
}

$rows = @()
Start-Wren -Size ("${W}x" + ($H + 110)) -Dpi 96 -Pref @('blocker.welcome_toast=false', ('style.color_scheme=' + $(if ($Dark) { 'dark' } else { 'light' }))) | Out-Null
try {
    $i = 0
    foreach ($u in $Urls) {
        $i++
        $slug = "{0:D2} - {1}" -f $i, (Slug $u)
        $wf = Join-Path $OutDir "$slug (wren).png"
        $ef = Join-Path $OutDir "$slug (edge).png"
        $t0 = Get-Date
        $null = Wren-Ctl nav $u --wait $Wait --timeout $TimeoutMs
        $navExit = $global:WrenExit
        Wren-Ctl wait frames 10 | Out-Null
        $null = Wren-Ctl shot $wf --tab
        $secs = [Math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
        $okEdge = Edge-Shot $u $ef
        $share = ''
        if ((Test-Path $wf) -and $okEdge) {
            $share = Diff-Share $ef $wf
            Side-By-Side $ef $wf (Join-Path $OutDir "$slug (cote a cote).png") $u
        }
        $rows += [pscustomobject]@{ n = $i; url = $u; navExit = $navExit; secs = $secs; diffPct = $share }
        "{0,2} {1,-52} nav={2} {3,5}s  diff={4} %" -f $i, $u, $navExit, $secs, $share
    }
} finally { try { Stop-Wren } catch { } }
$rows | ConvertTo-Csv -NoTypeInformation | Set-Content (Join-Path $OutDir 'resultats.csv') -Encoding UTF8
