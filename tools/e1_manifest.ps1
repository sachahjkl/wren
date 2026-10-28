# Build manifests for the E1 parity judge from a test262 checkout.
#   positive.manifest : "<mode>\t<path>" for positive tests we attempt to compile (bytecode diff).
#   negparse.txt      : "<mode>\t<path>" for tests whose negative phase is "parse" (syntax verdict).
# mode is 's' (script) or 'm' (module). We skip tests that cannot be compiled standalone for a bytecode diff:
#   - flags [raw] change the harness contract; still compilable, kept.
#   - flags [module] -> mode 'm'.
#   - [CanBlockIsFalse]/[async] etc. do not affect compile; kept.
# We keep everything else; the oracle simply errors on features neither engine supports, which the judge counts
# as "both err" (agreement) rather than a divergence.
param(
    [string]$Test262 = 'C:\Users\sacha\AppData\Local\Temp\opencode\e1_oracle\test262',
    [string]$OutDir = 'C:\Users\sacha\AppData\Local\Temp\opencode\e1_oracle',
    [string]$SubPath = 'test\language',
    [int]$Stride = 1
)
$ErrorActionPreference = 'Stop'
$files = Get-ChildItem (Join-Path $Test262 $SubPath) -Recurse -Filter *.js -File
$pos = [System.Collections.Generic.List[string]]::new()
$neg = [System.Collections.Generic.List[string]]::new()
$i = 0
foreach ($f in $files) {
    $i++
    if ($Stride -gt 1 -and ($i % $Stride) -ne 0) { continue }
    $name = $f.Name
    # test262 convention: *_FIXTURE.js are not tests; skip.
    if ($name -like '*_FIXTURE.js') { continue }
    $text = [IO.File]::ReadAllText($f.FullName)
    $meta = ''
    $s = $text.IndexOf('/*---')
    if ($s -ge 0) { $e = $text.IndexOf('---*/', $s); if ($e -ge 0) { $meta = $text.Substring($s, $e - $s) } }
    $isModule = $meta -match 'flags:\s*\[[^\]]*\bmodule\b'
    $mode = if ($isModule) { 'm' } else { 's' }
    $isNegParse = ($meta -match 'negative:') -and ($meta -match 'phase:\s*parse')
    $line = "$mode`t$($f.FullName)"
    if ($isNegParse) { $neg.Add($line) } else { $pos.Add($line) }
}
[IO.File]::WriteAllLines((Join-Path $OutDir 'positive.manifest'), $pos)
[IO.File]::WriteAllLines((Join-Path $OutDir 'negparse.txt'), $neg)
"positive: $($pos.Count)  negparse: $($neg.Count)"
