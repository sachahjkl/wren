# A/B speed of several jsrt judge builds (and optionally QuickJS) on micro.js, interleaved, best of N rounds.
#   powershell -File tools\jsrt_ab.ps1 -Exes base=build\jsrt_judge_base.exe,new=build\jsrt_judge.exe,qjs=build\qjs_ref.exe [-Rounds 5]
# An exe whose label starts with "qjs" is run as a plain shell (no "eval" verb). Table: ns per iteration, and the
# ratio of each exe to the first one (>100 % = faster than the first).
param(
    [Parameter(Mandatory = $true)][string[]]$Exes,
    [int]$Rounds = 5,
    [string]$Script = "examples\jsbench\micro.js"
)
$ErrorActionPreference = "Continue"
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$labels = @(); $paths = @()
foreach ($e in ($Exes | ForEach-Object { $_ -split "," })) { $p = $e -split "=", 2; $labels += $p[0]; $paths += $p[1] }
$best = @{}; $order = @(); $sums = @{}
foreach ($l in $labels) { $best[$l] = @{} }
for ($i = 0; $i -lt $Rounds; $i++) {
    for ($k = 0; $k -lt $labels.Count; $k++) {
        $l = $labels[$k]
        [string[]]$argv = if ($l -like "qjs*") { ,$Script } else { "eval", $Script }
        $out = & $paths[$k] @argv 2>$null | Out-String
        foreach ($line in ($out -split "`n")) {
            $p = $line.Trim() -split "`t"
            if ($p.Count -ge 3 -and $p[0] -eq "MICRO") {
                if ($p[1] -eq "checksum") { $sums[$l] = $p[2]; continue }
                if ($order -notcontains $p[1]) { $order += $p[1] }
                $v = [double]($p[2] -replace ",", ".")
                if (-not $best[$l].ContainsKey($p[1]) -or $v -lt $best[$l][$p[1]]) { $best[$l][$p[1]] = $v }
            }
        }
    }
}
$hdr = "| case | " + (($labels | ForEach-Object { "$_ ns" }) -join " | ") + " | " + (($labels | Select-Object -Skip 1 | ForEach-Object { "$_ vs $($labels[0])" }) -join " | ") + " |"
$hdr
"|---|" + ("---:|" * (2 * $labels.Count - 1))
$logs = @{}; foreach ($l in $labels) { $logs[$l] = 0.0 }; $n = 0
foreach ($c in $order) {
    $row = "| $c |"
    foreach ($l in $labels) { $row += " {0:N2} |" -f $best[$l][$c] }
    $b0 = $best[$labels[0]][$c]
    foreach ($l in ($labels | Select-Object -Skip 1)) {
        $r = $b0 / $best[$l][$c]; $logs[$l] += [Math]::Log($r)
        $row += " {0:P0} |" -f $r
    }
    $n++
    $row
}
$row = "| **geomean** |" + (" |" * $labels.Count)
foreach ($l in ($labels | Select-Object -Skip 1)) { $row += " **{0:P1}** |" -f [Math]::Exp($logs[$l] / $n) }
$row
"checksums: " + (($labels | ForEach-Object { "$_=$($sums[$_])" }) -join ", ")
