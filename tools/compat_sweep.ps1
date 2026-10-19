# Compatibility sweep: Wren against Edge without scripts (tools\compare_edge.ps1 -NoScript) over a panel of sites.
#   powershell -NoProfile -File tools\compat_sweep.ps1 [-OutDir build\sweep] [-Exe build\browser.exe] [-Sites a,b] [-WaitMs 7000]
# Each site is compared under the shared lock of the worktrees (S:\wb_wt\shared.lock: Wren's window and the test
# server ports are shared between agents), taken and released per site. Sites in -SnapshotSites are rendered by Edge
# from the document fetched with Wren's headers (-Snapshot: servers that tell browsers apart by other headers).
# Writes <OutDir>\summary.csv and summary.md (fraction of differing pixels, mean channel difference) and, per site, the
# captures of compare_edge (<name>_side.png, <name>_diff.png...).
param(
    [string]$OutDir = 'build\sweep',
    [string]$Exe = '',
    [string[]]$Sites = @(
        'https://sacha.house', 'https://sacha.house/about', 'https://sacha.house/cv', 'https://sacha.house/projects',
        'https://www.google.com/', 'https://example.com', 'https://odin-lang.org', 'https://webassembly.org',
        'https://www.rust-lang.org', 'https://lobste.rs', 'https://news.ycombinator.com',
        'https://en.wikipedia.org/wiki/WebAssembly', 'https://developer.mozilla.org/en-US/docs/Web/CSS'),
    [string[]]$SnapshotSites = @('https://www.google.com/'),
    [int]$WaitMs = 7000,
    [string]$LockPath = 'S:\wb_wt\shared.lock'
)
$ErrorActionPreference = 'Stop'
# (powershell -File passes "a,b" as one string)
$Sites = @($Sites | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$SnapshotSites = @($SnapshotSites | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$root = Split-Path $PSScriptRoot -Parent
if (-not [IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $root $OutDir }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$rows = @()
foreach ($site in $Sites) {
    $name = ($site -replace '^[a-z]+://', '' -replace '[^A-Za-z0-9._-]+', '_').Trim('_')
    $cmpArgs = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'compare_edge.ps1'), '-Url', $site, '-Name', $name, '-OutDir', $OutDir, '-WaitMs', $WaitMs)
    $cmpArgs += if ($SnapshotSites -contains $site) { '-Snapshot' } else { '-NoScript' }
    if ($Exe) { $cmpArgs += @('-Exe', $Exe) }
    $lock = $null
    while ($true) { try { $lock = [IO.File]::Open($LockPath, 'OpenOrCreate', 'ReadWrite', 'None'); break } catch { Start-Sleep -Milliseconds 500 } }
    try {
        $ErrorActionPreference = 'Continue'   # a site that fails is reported, the sweep goes on
        $out = & powershell @cmpArgs 2>&1 | Out-String
        $ErrorActionPreference = 'Stop'
    } finally { $lock.Close() }
    $json = ($out -split "`n" | Where-Object { $_ -match '^\{"name"' } | Select-Object -Last 1)
    if ($json) {
        $m = $json | ConvertFrom-Json
        $rows += [pscustomobject]@{ site = $site; name = $name; diff_pixels = $m.diff_pixels; mean_abs = $m.mean_abs; error = '' }
    } else {
        $rows += [pscustomobject]@{ site = $site; name = $name; diff_pixels = ''; mean_abs = ''; error = ($out.Trim() -split "`n" | Select-Object -First 1) }
    }
    Write-Host ("{0,-50} {1}" -f $site, $(if ($json) { $json } else { 'failed' }))
}
$rows | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $OutDir 'summary.csv')
$md = @('| Site | Differing pixels | Mean difference |', '|---|---:|---:|')
foreach ($r in $rows) {
    $pct = if ($r.diff_pixels -ne '') { '{0:0.0} %' -f ([double]$r.diff_pixels * 100) } else { 'n/a (' + $r.error + ')' }
    $md += ('| {0} | {1} | {2} |' -f $r.site, $pct, $r.mean_abs)
}
[IO.File]::WriteAllText((Join-Path $OutDir 'summary.md'), ($md -join "`n") + "`n")
