# The back/forward cache measured (wren ctl stats: bfcache), in a Wren with no window shown: a page left by a
# navigation is kept and comes back from the cache (a hit), a page with an unload handler is not kept (its reason is
# counted) and going back to it loads it again (a miss).
#   powershell -NoProfile -File tools\bfcache_e2e.ps1 [-Check]   (-Check: the check build, nothing left allocated)
param([switch]$Check)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'test_env.ps1')
. (Join-Path $PSScriptRoot 'wrenctl.ps1')
Set-Location $root
$fails = 0
function Expect([bool]$ok, [string]$what, [string]$got) {
  if ($ok) { "PASS $what" } else { "FAIL $what (got: $got)"; $script:fails++ }
}
function Bf { ((Wren-Ctl stats --json) -join '' | ConvertFrom-Json).bfcache }
$srv = Start-WrenTestServer
$name = $null
try {
  $name = if ($Check) { Start-WrenChecked } else { Start-Wren -Size 1000x700 }
  $env:WREN_REMOTE = $name
  $o = $srv.Origin
  Wren-Ctl nav "$o/site/history/other.html" --wait load | Out-Null
  Wren-Ctl nav "$o/site/history/next.html" --wait load | Out-Null
  Wren-Ctl eval 'history.back(); 1' | Out-Null
  Start-Sleep -Milliseconds 800
  $b = Bf
  Expect ($b.traversals -ge 1 -and $b.restores -ge 1 -and $b.hitRate -gt 0) 'going back finds the page in the cache (a hit)' ($b | ConvertTo-Json -Compress)
  # a page with an unload handler may not be kept
  Wren-Ctl eval 'addEventListener("unload", () => {}); 1' | Out-Null
  Wren-Ctl nav "$o/site/history/next.html" --wait load | Out-Null
  Wren-Ctl eval 'history.back(); 1' | Out-Null
  Start-Sleep -Milliseconds 800
  $b2 = Bf
  $reasons = ($b2.reasons | ConvertTo-Json -Compress)
  Expect ($b2.refusals -ge 1 -and $reasons -match 'Unload') 'a page with an unload handler is refused, its reason counted' $reasons
  Expect ($b2.misses -ge 1 -and $b2.traversals -ge 2) 'going back to it is a miss' ($b2 | ConvertTo-Json -Compress)
} finally {
  if ($name -and $Check) { $leaks = Stop-WrenChecked; Expect (Test-WrenCheckClean $leaks) 'the check build exits with nothing left allocated' $leaks } elseif ($name) { Stop-Wren $name }
  Stop-WrenTestServer $srv
}
if ($fails -gt 0) { "bfcache_e2e: $fails failure(s)"; exit 1 }
'bfcache_e2e: all passed'
