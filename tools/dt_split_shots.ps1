# The docked developer tools while their splitter is dragged: the splitter is pressed, moved to each width in -Widths (panel width
# in CSS px, from the window's right edge) and a capture of the window is taken at each, before the button is released. Each
# capture is the renderer's frame (what the window presents), so a panel drawn from a stale or stretched image shows in it.
#   powershell -NoProfile -File tools\dt_split_shots.ps1 [-Exe wren_prof.exe] [-Url u] [-Tab network] [-Dock right] [-Widths 420,520,380] [-Out dir]
param([string]$Exe = 'wren_prof.exe', [string]$Url = '', [string]$Tab = 'network', [string]$Dock = 'right', [int[]]$Widths = @(420, 560, 380),
      [string]$Out = '', [string]$Size = '1280x800')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot\test_env.ps1"
. "$PSScriptRoot\wrenctl.ps1"
$script:WrenExe = Join-Path $root "build\$Exe"
if (-not $Out) { $Out = Join-Path $root 'build\dtshots' }
New-Item -ItemType Directory -Force $Out | Out-Null
$ww, $wh = $Size -split 'x' | ForEach-Object { [int]$_ }

function Mouse([string]$type, [int]$x, [int]$y) {
    $j = '{"method":"Input.dispatchMouseEvent","params":{"type":"' + $type + '","x":' + $x + ',"y":' + $y + ',"button":"left","space":"window"}}'
    Wren-Ctl raw $j | Out-Null
}

$srv = Start-WrenTestServer
try {
    $env:WREN_TEST_BASE_PORT = "$($srv.BasePort)"
    if (-not $Url) { $Url = "$($srv.Origin)/site/devtools/dt4.html" }
    $null = Start-Wren -Size $Size -Dpi 96 -Pref 'browser.devtools.visible=true', "browser.devtools.tab=$Tab", "browser.devtools.dock=$Dock", 'browser.devtools.size=300' -Url $Url
    try {
        Wren-Ctl wait load | Out-Null
        Wren-Ctl wait frames 10 | Out-Null
        Wren-Ctl shot (Join-Path $Out 'rest.png') --window | Out-Null
        # the splitter: its middle is 2.5 px left of the panel (300 px wide)
        $x = $ww - 300 - 3; $y = [int]($wh * 0.5)
        Mouse mouseMoved $x $y
        Mouse mousePressed $x $y
        $i = 0
        foreach ($w in $Widths) {
            $i++
            $nx = $ww - $w - 3
            $steps = 6
            for ($s = 1; $s -le $steps; $s++) { Mouse mouseMoved ([int]($x + ($nx - $x) * $s / $steps)) $y }
            $x = $nx
            Wren-Ctl shot (Join-Path $Out ("drag{0}_{1}.png" -f $i, $w)) --window | Out-Null
            # the panel's filter bar, magnified
            Wren-Ctl shot (Join-Path $Out ("bar{0}_{1}.png" -f $i, $w)) --rect "$($ww - $w - 4),106,$($w + 4),30" --scale 2 | Out-Null
        }
        Mouse mouseReleased $x $y
        Wren-Ctl shot (Join-Path $Out 'after.png') --window | Out-Null
        Wren-Ctl stats
    } finally { Stop-Wren }
} finally { Stop-WrenTestServer $srv }
