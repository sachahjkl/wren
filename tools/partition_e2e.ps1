# Storage partitioning end to end (storage.partitioned), in a Wren with no window shown (wren ctl), against the test
# server: http://127.0.0.1 (site A) embeds the third party http://localhost (T, examples/site/partition/t.html), which
# is also opened as a tab of its own. T's cookies, localStorage, sessionStorage, Cache API, BroadcastChannel and service
# worker registrations under A differ from its first-party ones, and are the same under another origin of site A (the
# partition is per top-level site); its requests say Sec-Fetch-Storage-Access; a click in T inside A asks for storage
# access (document.requestStorageAccess(): the prompt answered by browser.dialogs.test_answer) and T then uses its
# first-party data there. (Two different sites embedding the same third party need a third host name: the keys of
# that case are checked by src/page/storage_partition_test.odin.) -Check: on the check build, which must exit with
# nothing left allocated.
param([switch]$Check)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'wrenctl.ps1')
. (Join-Path $PSScriptRoot 'test_env.ps1')
Set-Location $root
$fails = 0
function Expect([bool]$ok, [string]$what, [string]$got) {
  if ($ok) { "PASS $what" } else { "FAIL $what (got: $got)"; $script:fails++ }
}
$srv = Start-WrenTestServer
$name = $null
try {
  $p = $srv.BasePort
  $t = "http://localhost:$p/site/partition/t.html"
  $name = if ($Check) { Start-WrenChecked } else { Start-Wren -Size 1000x700 }
  $env:WREN_REMOTE = $name
  $ask = { param($tab, $msg) Wren-Ctl eval "loaded.then(() => ask($msg))" --await --tab-id $tab }

  # T as a tab of its own: its first-party data
  Wren-Ctl nav $t --wait load | Out-Null
  $tabT = (Wren-Ctl tabs | Select-Object -First 1) -replace '^(\d+).*', '$1'
  $w = Wren-Ctl eval 'run({op: "write", v: "first"})' --await --tab-id $tabT
  Expect ($w -eq 'written') 'the third party writes its first-party data' $w

  $tabA = Wren-Ctl tab new "http://127.0.0.1:$p/site/partition/top.html?t=$t" --wait load
  $r = & $ask $tabA '{op: "read"}'
  Expect ($r -eq 'none|none|none|none') 'embedded in site A, it sees none of its first-party data (localStorage, sessionStorage, cookie, Cache API)' $r
  $r = & $ask $tabA '{op: "write", v: "a"}'
  $ra = & $ask $tabA '{op: "read"}'
  $rt = Wren-Ctl eval 'run({op: "read"})' --await --tab-id $tabT
  Expect ($ra -eq 'a|a|a|a' -and $rt -eq 'first|first|first|first') 'two partitions: under A, first-party' "$ra / $rt"
  $tabA2 = Wren-Ctl tab new "http://127.0.0.1:$($p + 2)/site/partition/top.html?t=$t" --wait load
  $r2 = & $ask $tabA2 '{op: "read"}'
  Expect ($r2 -eq 'a|none|a|a') 'under another origin of site A it finds the same partition (sessionStorage is per tab)' $r2
  $h = & $ask $tabA '{op: "hdr"}'
  Expect ($h -eq 'none v=a') 'a credentialed request of the embedded third party: Sec-Fetch-Storage-Access none and its partition''s cookie' $h
  $h = Wren-Ctl eval 'run({op: "hdr"})' --await --tab-id $tabT
  Expect ($h -eq '- v=first') 'first-party: no Sec-Fetch-Storage-Access, its own cookie' $h

  $l = & $ask $tabA '{op: "listen"}'
  Wren-Ctl eval 'run({op: "post", v: "from-first"})' --await --tab-id $tabT | Out-Null
  & $ask $tabA2 '{op: "post", v: "from-a2"}' | Out-Null
  Start-Sleep -Milliseconds 300
  $g = & $ask $tabA '{op: "got"}'
  Expect ($l -eq 'listening' -and $g -eq 'from-a2') 'BroadcastChannel: the third party under A hears its copy in the same partition, not its first-party tab' $g

  $s = & $ask $tabA '{op: "sw"}'
  $st = Wren-Ctl eval 'run({op: "swcount"})' --await --tab-id $tabT
  $s2 = & $ask $tabA2 '{op: "swcount"}'
  Expect ($s -eq '1' -and $st -eq '0' -and $s2 -eq '1') 'a service worker registered by the third party under A is its partition''s, not first-party' "$s / $st / $s2"

  $n = & $ask $tabA '{op: "request"}'
  Expect ($n -eq 'refused NotAllowedError') 'requestStorageAccess() without a click in the frame: NotAllowedError' $n
  $has = & $ask $tabA '{op: "has"}'
  Expect ($has -eq 'false') 'hasStorageAccess() is false in a partition' $has
  Wren-Ctl pref set browser.dialogs.test_answer allow | Out-Null
  Wren-Ctl tab activate $tabA | Out-Null
  Wren-Ctl click '200,100' --tab-id $tabA | Out-Null   # (in the frame: its button fills it)
  $said = Wren-Ctl eval 'new Promise((ok) => { const go = () => said.length ? ok(said.join(",")) : setTimeout(go, 50); go(); setTimeout(() => ok("nothing"), 5000); })' --await --tab-id $tabA
  Expect ($said -eq 'granted') 'a click in the frame, then requestStorageAccess(): granted (the prompt allowed)' $said
  Wren-Ctl pref set browser.dialogs.test_answer '""' | Out-Null
  $has = & $ask $tabA '{op: "has"}'
  $r = & $ask $tabA '{op: "read"}'
  Expect ($has -eq 'true' -and $r -eq 'first|none|first|first') 'with storage access the third party under A uses its first-party data (sessionStorage stays the tab''s)' "$has $r"
  $h = & $ask $tabA '{op: "hdr"}'
  Expect ($h -eq 'active v=first') 'its requests say Sec-Fetch-Storage-Access: active and carry its first-party cookie' $h
  $h2 = & $ask $tabA2 '{op: "hdr"}'
  $n2 = & $ask $tabA2 '{op: "request"}'
  Expect ($h2 -eq 'inactive v=a' -and $n2 -eq 'granted') 'another document of the pair: inactive until it asks, then granted without a gesture' "$h2 / $n2"
} finally {
  if ($name -and $Check) { $leaks = Stop-WrenChecked; Expect (Test-WrenCheckClean $leaks) 'the check build exits with nothing left allocated' $leaks } elseif ($name) { Stop-Wren $name }
  Stop-WrenTestServer $srv
}
if ($fails -gt 0) { "partition_e2e: $fails failure(s)"; exit 1 }
'partition_e2e: all passed'
