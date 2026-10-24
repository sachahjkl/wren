# Sums up a guest profile (Firefox Profiler format, written by jsengine run -profile / wasm.profile_finish, or by the browser with
# WREN_WASM_PROFILE=<prefix>): the functions with the most time, self (the function itself was running) and total (it was on the stack).
#   powershell -NoProfile -File tools\wasm_profile.ps1 <profile.json> [-Top 30]
# Each sample weighs the time since the one before (the ticks come from the wall clock, while a call into the engine is in progress):
# what the host did in between (a DOM call, a style or layout pass, a chrome frame made from the epoch callback) lands on the engine
# function that ran next. -Count weighs every sample 1 instead.
#   -Sort total       by the time the function had on the stack (default: self)
#   -Callers <name>   the stacks (innermost 8 functions) that most often end in <name> when it is the running function
#   -Under <name>     what runs below <name>: the functions that were running while <name> was on the stack, by self
#   -Timeline <name>  milliseconds per second of the profile that had <name> on the stack (what the page did when)
# For names, profile an engine built with tools\build_js.ps1 -Names (the browser: swap build\js\wren_js.wasm for the one it makes in
# its -Out folder, build.bat profile; the jsengine tool: -Names -Out build\js-prof -NoSnapshot, then
#   jsengine run -image build\js-prof\wren_js_raw.wasm -raw -profile out.json script.js).
param([Parameter(Mandatory = $true)][string]$Path, [int]$Top = 30, [ValidateSet('self', 'total')][string]$Sort = 'self',
      [string]$Callers = '', [string]$Under = '', [string]$Timeline = '', [switch]$Count)
$ErrorActionPreference = 'Stop'
$p = Get-Content $Path -Raw | ConvertFrom-Json
$th = $p.threads[0]
$strings = if ($p.shared -and $p.shared.stringArray) { $p.shared.stringArray } else { $th.stringArray }
$frameFunc = $th.frameTable.func
$funcName = $th.funcTable.name
$stackFrame = $th.stackTable.frame
$stackPrefix = $th.stackTable.prefix
$deltas = $th.samples.timeDeltas
$weighted = [bool]$deltas -and -not $Count
$self = @{}; $total = @{}; $chains = @{}; $beneath = @{}; $perSecond = @{}
$n = 0; $sum = 0.0; $clock = 0.0; $idx = -1
$wantChain = $Callers -or $Under -or $Timeline
foreach ($s in $th.samples.stack) {
    $idx++
    if ($deltas) { $clock += $deltas[$idx] }
    if ($null -eq $s) { continue }
    $n++
    $w = if ($weighted) { [double]$deltas[$idx] } else { 1.0 }
    $sum += $w
    $names = @()
    for ($cur = $s; $null -ne $cur; $cur = $stackPrefix[$cur]) { $names += $strings[$funcName[$frameFunc[$stackFrame[$cur]]]] }
    $self[$names[0]] = $w + [double]$self[$names[0]]
    foreach ($name in ($names | Select-Object -Unique)) { $total[$name] = $w + [double]$total[$name] }
    if ($wantChain) {
        if ($Callers -and $names[0] -eq $Callers) { $k = ($names | Select-Object -First 8) -join ' <- '; $chains[$k] = $w + [double]$chains[$k] }
        if ($Under -and $names -contains $Under) { $beneath[$names[0]] = $w + [double]$beneath[$names[0]] }
        if ($Timeline -and $names -contains $Timeline) { $sec = [int][Math]::Floor($clock / 1000); $perSecond[$sec] = $w + [double]$perSecond[$sec] }
    }
}
$unit = if ($weighted) { 'ms' } else { 'ticks' }
"$n samples, $([int]$sum) $unit"
''
if ($Callers) { $chains.Keys | Sort-Object { -$chains[$_] } | Select-Object -First $Top | ForEach-Object { '{0,7:N0}  {1}' -f $chains[$_], $_ }; return }
if ($Under) { $beneath.Keys | Sort-Object { -$beneath[$_] } | Select-Object -First $Top | ForEach-Object { '{0,7:N0}  {1}' -f $beneath[$_], $_ }; return }
if ($Timeline) { $perSecond.Keys | Sort-Object { [int]$_ } | ForEach-Object { '{0,4} s  {1,7:N0} {2}' -f $_, $perSecond[$_], $unit }; return }
'| function | self | total |'
'|---|---:|---:|'
$order = if ($Sort -eq 'total') { { -$total[$_] }, { -[double]$self[$_] } } else { { -[double]$self[$_] }, { -$total[$_] } }
$total.Keys | Sort-Object -Property $order | Select-Object -First $Top | ForEach-Object {
    '| {0} | {1:N1} % | {2:N1} % |' -f $_, (100 * [double]$self[$_] / $sum), (100 * $total[$_] / $sum)
}
