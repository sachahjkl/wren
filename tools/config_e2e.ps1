# End-to-end test of about:config, driven through `wren ctl` (no window shown, nothing taken from the desktop): the keys
# a user would press, and the registry (`wren ctl pref get`) says what they did.
#   * Ctrl+F, a search of several words, Down into the list, Enter on a switch: the preference flips;
#   * a number: Enter edits it, typed value and Enter apply it; a value out of range is refused (the value stays);
#     Delete puts the default back;
#   * a choice: Enter, Down (opens the list), Down, Enter: the next value;
#   * the categories: Shift+Tab from the list, type-ahead to a category, Right into its list, Enter on its first preference;
#   * Right / Left open and close a preference's details (a capture before and after must differ).
# Captures in build\config_e2e\.
#   powershell -NoProfile -File tools\config_e2e.ps1 [-Exe build\wren.exe]
param([string]$Exe = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $Exe) { $Exe = Join-Path $root 'build\wren.exe' }
$env:WREN_EXE = (Resolve-Path $Exe).Path
. "$PSScriptRoot\wrenctl.ps1"
$failed = 0
function Check([bool]$ok, [string]$what, [string]$detail = '') { if ($ok) { "PASS $what" } else { "FAIL $what  $detail"; $script:failed++ } }
function Key([string]$k) { Wren-Ctl key $k | Out-Null; if ($global:WrenExit -ne 0) { throw "key $k failed: $global:WrenErr" } }
function Typed([string]$t) { Wren-Ctl type $t | Out-Null; if ($global:WrenExit -ne 0) { throw "type failed: $global:WrenErr" } }
function Pref([string]$n) { return (Wren-Ctl pref get $n).Trim() }
function Settle { Wren-Ctl wait frames 3 | Out-Null }
# a search from the field: select what is there, type over it, go down to the first preference under the header
function Search([string]$q) { Key 'Ctrl+F'; Settle; Typed $q; Settle; Key 'Down'; Settle; Key 'Down'; Settle }

$out = Join-Path $root 'build\config_e2e'
New-Item -ItemType Directory -Force $out | Out-Null
$name = Start-Wren -Size 1280x900 -Dpi 100
try {
    Wren-Nav 'about:config' | Out-Null
    Settle

    $before = Pref 'blocker.badge.enabled'
    Search 'blocker badge enabled'
    Key 'Enter'; Settle
    $after = Pref 'blocker.badge.enabled'
    Check ($before -match 'true' -and $after -match 'false') 'search, Down into the list, Enter flips a switch' "before '$before' after '$after'"
    Key 'Delete'; Settle
    Check ((Pref 'blocker.badge.enabled') -match 'true') 'Delete resets it to its default'

    Search 'cosmetic max selectors'
    Key 'Enter'; Settle
    Typed '12345'; Key 'Enter'; Settle
    $v = Pref 'blocker.cosmetic.max_selectors'
    Check ($v -match '12345') 'Enter edits a number, Enter applies it' "got '$v'"
    Wren-Shot (Join-Path $out '01 number edited.png') | Out-Null
    Key 'Enter'; Settle
    Typed '5'; Key 'Enter'; Settle
    $v = Pref 'blocker.cosmetic.max_selectors'
    Check ($v -match '12345') 'a value out of range is refused' "got '$v'"
    Wren-Shot (Join-Path $out '02 out of range.png') | Out-Null
    Key 'Delete'; Settle
    $v = Pref 'blocker.cosmetic.max_selectors'
    Check ($v -match '20000') 'Delete puts the default back' "got '$v'"

    Search 'badge style'
    Key 'Enter'; Settle; Key 'Down'; Settle; Key 'Down'; Settle; Key 'Enter'; Settle
    $v = Pref 'blocker.badge.style'
    Check ($v -match 'inside') 'a choice: Enter, Down opens it, Down, Enter picks the next value' "got '$v'"
    Wren-Ctl pref reset 'blocker.badge.style' | Out-Null

    # the details fold of the active row
    $a = Join-Path $out '03 details closed.png'; $b = Join-Path $out '04 details open.png'
    Wren-Shot $a | Out-Null
    Key 'Right'; Settle
    Wren-Shot $b | Out-Null
    Wren-Ctl diff $a $b | Out-Null
    Check ($global:WrenExit -ne 0) 'Right opens the details of a preference (the page changes)'
    Key 'Left'; Settle

    # a category by the keyboard: the search emptied, back to the list, Shift+Tab to the categories, type-ahead, Right
    # into its list
    Key 'Ctrl+F'; Settle; Key 'Backspace'; Settle; Key 'Down'; Settle
    Key 'Shift+Tab'; Settle
    Typed 'cookies'; Settle
    Key 'Right'; Settle
    $before = Pref 'cookies.enabled'
    Key 'Enter'; Settle
    $after = Pref 'cookies.enabled'
    Check ($before -match 'true' -and $after -match 'false') 'a category picked by type-ahead, Right into it, Enter on its first preference' "before '$before' after '$after'"
    Wren-Shot (Join-Path $out '05 cookies category.png') | Out-Null
} finally {
    Stop-Wren $name
}
if ($failed) { "$failed failed"; exit 1 }
"all passed (captures: $out)"
