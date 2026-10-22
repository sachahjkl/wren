# Compatibility sweep: Wren against Edge over a panel of sites (tools\compare_edge.ps1), without scripts and with them.
#   powershell -NoProfile -File tools\compat_sweep.ps1 [-OutDir build\sweep] [-Exe build\wren.exe] [-Sites a,b] [-WaitMs 7000]
#       [-Modes noscript,js] [-Rebuild]
# Modes: noscript compares with scripts off on both sides (compare_edge -NoScript: Edge sends Wren's User-Agent; sites
# in -SnapshotSites are rendered by Edge from the document fetched with Wren's headers, -Snapshot); js compares both
# browsers running scripts (compare_edge -Js: Wren with javascript.enabled, Edge as it is) and collects Wren's
# JavaScript errors on the page, grouped by what is missing (NotSupportedError "X.y is not supported", ReferenceError,
# TypeError...). With both modes the table is the before / after of JavaScript.
# No lock here: Wren's capture (tools\screenshot.ps1) holds desktop.lock while its window lives, Edge runs headless.
# Writes <OutDir>\summary.csv and summary.md (per site: fraction of differing pixels, mean channel difference, the
# JavaScript errors; then the missing APIs over the panel) and, per site, the captures of compare_edge (<name>_side.png,
# <name>_diff.png..., <name>_js_*.png and <name>_js_console.txt for the js mode). summary.json keeps every measure:
# -Rebuild writes the tables again from it, without measuring.
param(
    [string]$OutDir = 'build\sweep',
    [string]$Exe = '',
    [string[]]$Sites = @(
        'https://sacha.house', 'https://sacha.house/about', 'https://sacha.house/cv', 'https://sacha.house/projects',
        'https://www.google.com/', 'https://example.com', 'https://odin-lang.org', 'https://webassembly.org',
        'https://www.rust-lang.org', 'https://lobste.rs', 'https://news.ycombinator.com',
        'https://en.wikipedia.org/wiki/WebAssembly', 'https://developer.mozilla.org/en-US/docs/Web/CSS'),
    [string[]]$SnapshotSites = @('https://www.google.com/'),
    [string[]]$Modes = @('noscript'),
    [int]$WaitMs = 7000,
    [switch]$Rebuild
)
$ErrorActionPreference = 'Stop'
# (powershell -File passes "a,b" as one string)
$Sites = @($Sites | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$SnapshotSites = @($SnapshotSites | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Modes = @($Modes | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
foreach ($m in $Modes) { if ($m -notin 'noscript', 'js') { throw "unknown mode $m (noscript, js)" } }
$root = Split-Path $PSScriptRoot -Parent
if (-not [IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $root $OutDir }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$inv = [Globalization.CultureInfo]::InvariantCulture
$rows = @()
if ($Rebuild) { $rows = @((Get-Content (Join-Path $OutDir 'summary.json') -Raw | ConvertFrom-Json) | ForEach-Object { $_ }); $Sites = @() }
foreach ($site in $Sites) {
    $base = ($site -replace '^[a-z]+://', '' -replace '[^A-Za-z0-9._-]+', '_').Trim('_')
    $row = [ordered]@{ site = $site; name = $base }
    foreach ($mode in $Modes) {
        $name = if ($mode -eq 'js') { "${base}_js" } else { $base }
        $cmpArgs = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'compare_edge.ps1'), '-Url', $site, '-Name', $name, '-OutDir', $OutDir, '-WaitMs', $WaitMs)
        if ($mode -eq 'js') { $cmpArgs += '-Js' }
        else { $cmpArgs += if ($SnapshotSites -contains $site) { '-Snapshot' } else { '-NoScript' } }
        if ($Exe) { $cmpArgs += @('-Exe', $Exe) }
        $ErrorActionPreference = 'Continue'   # a site that fails is reported, the sweep goes on
        $out = & powershell @cmpArgs 2>&1 | Out-String
        $ErrorActionPreference = 'Stop'
        $json = ($out -split "`n" | Where-Object { $_ -match '^\{"name"' } | Select-Object -Last 1)
        if ($json) {
            $m = $json | ConvertFrom-Json
            $row["${mode}_diff_pixels"] = $m.diff_pixels
            $row["${mode}_mean_abs"] = $m.mean_abs
            if ($mode -eq 'js') {
                $row['js_errors'] = $m.js_errors
                $row['js_apis'] = $m.js_apis
            }
            $row["${mode}_error"] = ''
        } else {
            $row["${mode}_diff_pixels"] = ''; $row["${mode}_mean_abs"] = ''
            $row["${mode}_error"] = ($out.Trim() -split "`n" | Select-Object -First 1)
        }
        Write-Host ("{0,-50} {1,-8} {2}" -f $site, $mode, $(if ($json) { $json } else { 'failed' }))
    }
    $rows += [pscustomobject]$row
}
if (-not $Rebuild) { ConvertTo-Json @($rows) -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $OutDir 'summary.json') }
$rows | Select-Object * -ExcludeProperty js_apis | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $OutDir 'summary.csv')

function Pct($r, $mode) {
    $v = $r."${mode}_diff_pixels"
    if ($v -ne $null -and "$v" -ne '') { return ([double]$v * 100).ToString('0.0', $inv) + ' %' }
    return 'n/a (' + $r."${mode}_error" + ')'
}
$head = '| Site |'; $sep = '|---|'
foreach ($mode in $Modes) {
    $label = if ($mode -eq 'js') { 'with JavaScript' } else { 'without scripts' }
    $head += " Differing pixels, $label | Mean difference, $label |"; $sep += '---:|---:|'
}
if ($Modes -contains 'js') { $head += ' JS errors | Most frequent |'; $sep += '---:|---|' }
$md = @($head, $sep)
$apis = @{}   # what is missing -> [sites, errors]
foreach ($r in $rows) {
    $line = "| $($r.site) |"
    foreach ($mode in $Modes) { $line += " $(Pct $r $mode) | $($r."${mode}_mean_abs") |" }
    if ($Modes -contains 'js') {
        $top = ''
        if ($r.js_apis) {
            $pairs = @($r.js_apis.PSObject.Properties | Sort-Object { [int]$_.Value } -Descending)
            $top = ($pairs | Select-Object -First 3 | ForEach-Object { "``$($_.Name)`` ($($_.Value))" }) -join ', '
            foreach ($p in $pairs) {
                if (-not $apis.ContainsKey($p.Name)) { $apis[$p.Name] = @(0, 0) }
                $apis[$p.Name] = @(($apis[$p.Name][0] + 1), ($apis[$p.Name][1] + [int]$p.Value))
            }
        }
        $line += " $($r.js_errors) | $top |"
    }
    $md += $line
}
if ($apis.Count) {
    $md += ''
    $md += '| What the JavaScript errors say is missing | Sites | Errors |'
    $md += '|---|---:|---:|'
    foreach ($k in ($apis.Keys | Sort-Object { -$apis[$_][0] }, { -$apis[$_][1] })) { $md += "| ``$k`` | $($apis[$k][0]) | $($apis[$k][1]) |" }
}
[IO.File]::WriteAllText((Join-Path $OutDir 'summary.md'), ($md -join "`n") + "`n")
