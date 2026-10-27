# The package-level variables of src/browser (not the constants, procedures and types: `name :: ...`), against the list of those
# allowed (tools\globals_allowed.txt, one line each: "<file> <name> <class>  # why"). A global that is not in the list fails: the
# shell is moving its per-window state into the window (Browser_Window, windows.odin) and its per-tab state into the tab, so a new
# global of a window or a tab is to go there, not beside the others. One the list names that is gone fails too (the list follows
# the code). Classes:
#   process   the process's (the profile, the network, the fonts, the renderer, the loop, a table built once, statistics)
#   window    one window's, read as the active window's: to move into
#             Browser_Window.own (Window_Own)
#   page      one page's or tab's: to move into Page / Tab
#   test      a test's own
#   powershell -NoProfile -File tools\lint_globals.ps1 [-List]     (-List: print every global with its class)
#   powershell -NoProfile -File tools\lint_globals.ps1 -Write      (rewrite the list from the code, keeping the classes known; new
#                                                                   ones get "window?": to classify by hand)
param([switch]$List, [switch]$Write)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$listPath = Join-Path $PSScriptRoot 'globals_allowed.txt'
$decl = [regex]'^(?:@\([^)]*\)\s*)?([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*:(?![:])\s*(?:=|[^=]).*$'
$found = New-Object Collections.Generic.List[object]
foreach ($f in Get-ChildItem (Join-Path $root 'src\browser') -Filter *.odin | Sort-Object Name) {
    $class = if ($f.Name -match '_test\.odin$') { 'test' } else { '' }
    $depth = 0
    foreach ($l in [IO.File]::ReadAllLines($f.FullName)) {
        # (only what is at the top level: not inside a procedure, a struct, a foreign block or a `when`)
        if ($depth -eq 0 -and $l.Length -gt 0 -and -not [char]::IsWhiteSpace($l[0]) -and $l -notmatch '^(package|import|foreign|when|//|#|\})') {
            $m = $decl.Match($l)
            if ($m.Success -and $l -notmatch '^[^:]*::') {
                foreach ($n in ($m.Groups[1].Value -split '\s*,\s*')) { $found.Add([pscustomobject]@{ File = $f.Name; Name = $n; Test = $class }) }
            }
        }
        $code = $l -replace '//.*$', '' -replace '"([^"\\]|\\.)*"', '""' -replace "'([^'\\]|\\.)*'", "''" -replace '`[^`]*`', ''
        $depth += ($code.ToCharArray() | Where-Object { $_ -eq '{' }).Count - ($code.ToCharArray() | Where-Object { $_ -eq '}' }).Count
        if ($depth -lt 0) { $depth = 0 }
    }
}
$known = @{}
if (Test-Path $listPath) {
    foreach ($l in [IO.File]::ReadAllLines($listPath)) {
        if ($l -match '^\s*(#|$)') { continue }
        if ($l -match '^(\S+)\s+(\S+)\s+(\S+)(\s+#\s*(.*))?$') { $known["$($Matches[1]) $($Matches[2])"] = [pscustomobject]@{ Class = $Matches[3]; Why = $Matches[5] } }
    }
}
if ($Write) {
    $out = New-Object Collections.Generic.List[string]
    if (Test-Path $listPath) { foreach ($l in [IO.File]::ReadAllLines($listPath)) { if ($l -match '^#') { $out.Add($l) } else { break } } }
    foreach ($g in $found) {
        $k = "$($g.File) $($g.Name)"
        $c = if ($known.ContainsKey($k)) { $known[$k] } elseif ($g.Test) { [pscustomobject]@{ Class = 'test'; Why = '' } } else { [pscustomobject]@{ Class = 'window?'; Why = '' } }
        $out.Add(("{0} {1} {2}{3}" -f $g.File, $g.Name, $c.Class, $(if ($c.Why) { "  # $($c.Why)" } else { '' })))
    }
    [IO.File]::WriteAllText($listPath, (($out -join "`r`n") + "`r`n"))
    "$($found.Count) globals written to $listPath"
    exit 0
}
if ($List) { foreach ($g in $found) { $k = "$($g.File) $($g.Name)"; '{0,-34} {1,-34} {2}' -f $g.File, $g.Name, $(if ($known.ContainsKey($k)) { $known[$k].Class } else { 'NEW' }) } }
$fail = 0
$seen = @{}
foreach ($g in $found) {
    $k = "$($g.File) $($g.Name)"
    $seen[$k] = $true
    if (-not $known.ContainsKey($k)) { "error: src\browser\$($g.File): a new global '$($g.Name)'. A window's state goes into Browser_Window (windows.odin), a tab's into Tab; a global of the process is added to tools\globals_allowed.txt with its class and why"; $fail++ }
}
foreach ($k in $known.Keys) { if (-not $seen.ContainsKey($k)) { "error: tools\globals_allowed.txt names '$k', which is no longer a global: take it out of the list"; $fail++ } }
$byClass = $found | ForEach-Object { $k = "$($_.File) $($_.Name)"; if ($known.ContainsKey($k)) { $known[$k].Class } else { 'NEW' } } | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Count)" }
"globals of src\browser: $($found.Count) ($($byClass -join ', '))"
if ($fail) { exit 1 }
