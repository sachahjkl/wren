# Sums up a guest profile (Firefox Profiler format, written by jsengine run -profile / wasm.profile_finish): the
# functions with the most samples, self (the function itself was running) and total (it was on the stack).
#   powershell -NoProfile -File tools\wasm_profile.ps1 <profile.json> [-Top 30]
# For names, profile an engine built with tools\build_js.ps1 -Names -Out build\js-prof -NoSnapshot, run with
#   jsengine run -image build\js-prof\wren_js_raw.wasm -raw -profile out.json script.js
param([Parameter(Mandatory = $true)][string]$Path, [int]$Top = 30)
$ErrorActionPreference = 'Stop'
$p = Get-Content $Path -Raw | ConvertFrom-Json
$th = $p.threads[0]
$strings = if ($p.shared -and $p.shared.stringArray) { $p.shared.stringArray } else { $th.stringArray }
$frameFunc = $th.frameTable.func
$funcName = $th.funcTable.name
$stackFrame = $th.stackTable.frame
$stackPrefix = $th.stackTable.prefix
$self = @{}
$total = @{}
$n = 0
foreach ($s in $th.samples.stack) {
    if ($null -eq $s) { continue }
    $n++
    $seen = @{}
    $first = $true
    for ($cur = $s; $null -ne $cur; $cur = $stackPrefix[$cur]) {
        $name = $strings[$funcName[$frameFunc[$stackFrame[$cur]]]]
        if ($first) { $self[$name] = 1 + [int]$self[$name]; $first = $false }
        if (-not $seen.ContainsKey($name)) { $total[$name] = 1 + [int]$total[$name]; $seen[$name] = $true }
    }
}
"$n samples"
''
'| function | self | total |'
'|---|---:|---:|'
$total.Keys | Sort-Object { -[int]$self[$_] }, { -$total[$_] } | Select-Object -First $Top | ForEach-Object {
    '| {0} | {1:N1} % | {2:N1} % |' -f $_, (100 * [int]$self[$_] / $n), (100 * $total[$_] / $n)
}
