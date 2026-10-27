# End-to-end test of the search engines (search_engines.odin), driven through `wren ctl` (no window shown), against the
# test server (the engines' addresses point at it: nothing leaves the machine):
#   * a profile of before the list (browser.search.engine = custom, browser.search.custom_url) keeps its choice: words
#     typed in the address bar go to its address, and search_engines.txt is written with an engine "Custom";
#   * a list of the profile (search_engines.txt): words go to the default (browser.search.engine), a keyword first
#     ("@one x", or "t x" for a keyword without @) to its engine, an id the list lacks to its first engine;
#   * Ctrl+Down in the suggestions picks the next engine for this time;
#   * about:config, category Search: Enter on the engines' row opens the form, typed name, keyword and address, Enter
#     adds the engine (written to the profile at once), and its keyword works.
# Captures in build\search_e2e\.
#   powershell -NoProfile -File tools\search_e2e.ps1 [-Exe build\wren.exe]
param([string]$Exe = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$env:WREN_EXE = (Resolve-Path $Exe).Path
. "$PSScriptRoot\wrenctl.ps1"
. "$PSScriptRoot\test_env.ps1"
$failed = 0
function Check([bool]$ok, [string]$what, [string]$detail = '') { if ($ok) { "PASS $what" } else { "FAIL $what  $detail"; $script:failed++ } }
function Key([string]$k) { Wren-Ctl key $k | Out-Null; if ($global:WrenExit -ne 0) { throw "key $k failed: $global:WrenErr" } }
function Typed([string]$t) { Wren-Ctl type $t | Out-Null; if ($global:WrenExit -ne 0) { throw "type failed: $global:WrenErr" } }
function Settle { Wren-Ctl wait frames 3 | Out-Null }
# what the address bar opens for `text` (typed, then Enter, or `keys` before Enter)
function Address([string]$text, [string[]]$keys = @()) {
    Key 'Ctrl+L'; Settle; Typed $text; Settle
    foreach ($k in $keys) { Key $k; Settle }
    Key 'Enter'
    Wren-Ctl wait load --timeout 30000 | Out-Null
    return (Wren-Eval 'location.href').Trim()
}
function Write-Text([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false)) }

$out = Join-Path $root 'build\search_e2e'
New-Item -ItemType Directory -Force $out | Out-Null
$prof = Join-Path $env:TEMP "wren-search-e2e-$PID"
if (Test-Path $prof) { Remove-Item -Recurse -Force $prof }
New-Item -ItemType Directory -Force $prof | Out-Null
$srv = Start-WrenTestServer
$name = $null
try {
    $o = $srv.Origin
    $page = "$o/site/about.html"
    # 1. a profile of before the list
    Write-Text (Join-Path $prof 'prefs.txt') "wbprefs 1`nbrowser.search.engine`tcustom`nbrowser.search.custom_url`t$page`?custom=%s`n"
    $name = Start-Wren -Size 1280x800 -Dpi 100 -ProfileDir $prof
    $u = Address 'hello world'
    Check ($u -eq "$page`?custom=hello+world") 'a former custom search address stays the default' "got '$u'"
    $file = Join-Path $prof 'search_engines.txt'
    $text = if (Test-Path $file) { [IO.File]::ReadAllText($file) } else { '' }
    Check ($text.StartsWith('wren-search-engines 1') -and $text.Contains("custom`tCustom`t`t$page`?custom=%s")) 'the list is written with the former address as an engine' "got '$text'"
    Check ((Wren-Ctl pref get browser.search.engine).Trim() -match 'custom') 'browser.search.engine still names it'
    Stop-Wren $name; $name = $null

    # 2. the profile's list: default, keywords, an id the list lacks
    New-Item -ItemType Directory -Force $prof | Out-Null
    Write-Text $file "wren-search-engines 1`none`tOne`t@one`t$page`?one=%s`ntwo`tTwo`tt`t$page`?two=%s`n"
    $name = Start-Wren -Size 1280x800 -Dpi 100 -ProfileDir $prof
    Wren-Ctl pref set browser.search.engine two | Out-Null
    $u = Address 'a b'
    Check ($u -eq "$page`?two=a+b") 'words go to the default engine' "got '$u'"
    $u = Address '@one x y'
    Check ($u -eq "$page`?one=x+y") 'a keyword first searches with its engine' "got '$u'"
    $u = Address 't cats'
    Check ($u -eq "$page`?two=cats") 'a keyword without @' "got '$u'"
    $u = Address 'pick me' @('Ctrl+Down')
    Check ($u -eq "$page`?one=pick+me") 'Ctrl+Down in the suggestions: another engine this time' "got '$u'"
    Key 'Ctrl+L'; Settle; Typed 'see the engines'; Settle
    Wren-Shot (Join-Path $out '01 address bar suggestions.png') | Out-Null
    Key 'Escape'; Settle; Key 'Escape'; Settle
    Wren-Ctl pref set browser.search.engine gone | Out-Null
    $u = Address 'q'
    Check ($u -eq "$page`?one=q") 'an id the list lacks: its first engine' "got '$u'"
    Wren-Ctl pref set browser.search.engine one | Out-Null

    # 3. about:config: add an engine with the keyboard
    Wren-Nav 'about:config' | Out-Null
    Settle
    Key 'Ctrl+F'; Settle; Typed 'search engines'; Settle; Key 'Down'; Settle; Key 'Down'; Settle
    Wren-Shot (Join-Path $out '02 about config search.png') | Out-Null
    Key 'Enter'; Settle; Settle
    Typed 'Three'; Key 'Tab'; Settle; Typed '@3'; Key 'Tab'; Settle; Key 'Ctrl+A'; Typed "$page`?three=%s"; Settle
    Wren-Shot (Join-Path $out '03 about config adding.png') | Out-Null
    Key 'Enter'; Settle; Settle
    Wren-Shot (Join-Path $out '04 about config added.png') | Out-Null
    $text = [IO.File]::ReadAllText($file)
    Check ($text.Contains("three`tThree`t@3`t$page`?three=%s")) 'the engine added in about:config is written to the profile' "got '$text'"
    $u = Address '@3 ok'
    Check ($u -eq "$page`?three=ok") 'and its keyword works' "got '$u'"
} finally {
    if ($name) { Stop-Wren $name }
    Stop-WrenTestServer $srv
    Remove-Item -Recurse -Force $prof -ErrorAction SilentlyContinue
}
if ($failed) { "$failed failed"; exit 1 }
"all passed (captures: $out)"
