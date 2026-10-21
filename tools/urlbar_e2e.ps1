# End-to-end test of the address bar's suggestions in the real browser window (not part of test_all.ps1: it moves the
# real pointer and types on the real keyboard; screenshot.ps1 holds desktop.lock while its window is open). A profile
# with a known history; in one window: the inline completion of an address of the test server and Enter (a visit of
# it is recorded), Shift+Delete on the completed row (gitlab.com leaves the history), a click on the cross of a row
# (git-scm.com leaves it), Down / Escape. The profile's history.txt says what happened; captures in build\urlbar_e2e\.
#   powershell -File tools\urlbar_e2e.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
. (Join-Path $PSScriptRoot 'test_env.ps1')
$failed = 0
function Check($ok, $what) { if ($ok) { "PASS $what" } else { "FAIL $what"; $script:failed++ } }

$out = Join-Path $root 'build\urlbar_e2e'
New-Item -ItemType Directory -Force $out | Out-Null
$profile = Join-Path $out 'profile'
if (Test-Path $profile) { Get-ChildItem $profile -File -Recurse | Remove-Item -Force }
New-Item -ItemType Directory -Force $profile | Out-Null

$srv = Start-WrenTestServer
try {
    $origin = $srv.Origin   # http://127.0.0.1:<port>
    $hostport = $origin -replace '^http://', ''
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $rows = @(
        @('https://github.com/', 'GitHub', 8), @('https://github.com/odin-lang/Odin', 'GitHub - odin-lang/Odin', 4),
        @('https://gitlab.com/', 'GitLab', 6), @('https://git-scm.com/docs/git-rebase', 'Git - git-rebase Documentation', 2),
        @("$origin/site/index.html", 'Wren demos and tests', 3))
    $lines = @('wren-history 1'); $id = 0
    foreach ($r in $rows) { for ($k = 0; $k -lt $r[2]; $k++) { $id++; $lines += "v`t$id`t$($now - 3600000 + $id * 1000)`t$($r[0])`t$($r[1])`t" } }
    [IO.File]::WriteAllText((Join-Path $profile 'history.txt'), ($lines -join "`n") + "`n")

    # window-relative pixels of a 1280 x 800 window, the interface at the scale 1.5 whatever the display's
    # (browser.ui.scale): the chrome's layout is in logical pixels
    $s = 1.5
    function P([double]$x, [double]$y) { "{0},{1}" -f [int]($x * $s), [int]($y * $s) }
    $bar = P 400 62
    $row = { param($i) [int]((105.3 + 31.6 * $i) * $s) }   # the centre of row i of the list
    $cross = -[int](69.5 * $s)                              # from the window's right edge
    $ex = "--profile,$profile,--pref,history.global.save_delay_ms=50,--pref,browser.ui.scale=$s"
    $actions = @(
        "mclick:$bar", 'wait:300', "type:$($hostport)/site/ind", 'wait:400', "pshot:$out\01 completion.png", 'key:Enter', 'wait:1500',
        "mclick:$bar", 'wait:300', 'type:gitl', 'wait:300', "pshot:$out\02 gitlab completed.png", 'key:Shift+Delete', 'wait:500', "pshot:$out\03 gitlab removed.png",
        'key:Backspace', 'key:Backspace', 'key:Backspace', 'wait:300', "hover:$cross,$(& $row 3)", 'wait:300', "pshot:$out\04 cross hovered.png",
        "mclick:$cross,$(& $row 3)", 'wait:500', "pshot:$out\05 after the cross.png",
        'key:Down', 'wait:200', "pshot:$out\06 down.png", 'key:Escape', 'wait:200', "pshot:$out\07 escape.png", 'wait:600')
    powershell -NoProfile -File tools\screenshot.ps1 -Url about:history -Out "$out\00 start.png" -WaitMs 2000 -Width 1280 -Height 800 -Extra $ex -Actions ($actions -join ';')
    $h = [IO.File]::ReadAllText((Join-Path $profile 'history.txt'))
    $visits = ($h -split "`n" | Where-Object { $_ -like "v`t*" })
    Check (($visits | Where-Object { $_ -like "*`t$origin/site/index.html`t*" }).Count -eq 4) 'Enter on the completed address of the test server opened it (a fourth visit)'
    Check (-not ($h -match 'gitlab\.com')) 'Shift+Delete removed every visit of gitlab.com from the profile'
    Check (-not ($h -match 'git-scm\.com')) 'the cross removed every visit of git-scm.com from the profile'
    Check ($h -match 'https://github\.com/odin-lang/Odin') 'the other addresses stay'
} finally { Stop-WrenTestServer $srv }
if ($failed) { "$failed failed"; exit 1 }
"all passed (captures: $out)"
