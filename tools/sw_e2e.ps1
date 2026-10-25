# Service workers, the Cache API and BroadcastChannel end to end, in a Wren with no window shown (wren ctl), against
# the test server (http://127.0.0.1: a secure context): examples/site/sw/ registers sw.js, which caches data.txt at
# install, claims the page, answers virtual.txt and a whole navigation (virtual-page.html) itself, serves data.txt from
# its cache and answers messages. Checks the page's view (ready, controller, the answers, the messages, caches.keys)
# and that a page with no service worker in its scope is not intercepted.
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
  $base = "$($srv.Origin)/site/sw"
  $name = Start-Wren -Size 1000x700
  $env:WREN_REMOTE = $name
  Wren-Ctl nav "$base/index.html" --wait load | Out-Null
  $scope = Wren-Ctl eval 'registered' --await
  Expect ($scope -eq "$base/") 'register() resolves with the registration (its scope)' $scope
  $state = Wren-Ctl eval 'navigator.serviceWorker.ready.then((r) => r.active && r.active.state)' --await
  Expect ($state -eq 'activated') 'ready: the worker installed (cache filled, skipWaiting) and activated' $state
  Start-Sleep -Milliseconds 300
  $ctl = Wren-Ctl eval '!!navigator.serviceWorker.controller'
  Expect ($ctl -eq 'true') 'clients.claim() made the registering page controlled' $ctl
  $txt = Wren-Ctl eval 'fetch("virtual.txt").then((r) => r.text())' --await
  Expect ($txt -eq 'from the service worker') 'a request of the controlled page answered by respondWith(new Response)' $txt
  $keys = Wren-Ctl eval 'caches.keys().then((k) => k.join(","))' --await
  Expect ($keys -eq 'v1') 'the page sees the cache the worker made (caches.keys)' $keys
  $cached = Wren-Ctl eval 'caches.open("v1").then((c) => c.match("data.txt")).then((r) => r ? r.text() : "none")' --await
  Expect ($cached -match 'data from the network') 'cache.addAll stored the response (cache.match from the page)' $cached
  $data = Wren-Ctl eval 'fetch("data.txt").then((r) => r.text())' --await
  Expect ($data -match 'data from the network') 'a request answered from the cache (respondWith(caches.match))' $data
  $only = Wren-Ctl eval 'fetch("cached-only.txt").then((r) => r.text())' --await
  Expect ($only -eq 'put by the worker') 'a response the worker put in its cache, which the network does not have' $only
  Wren-Ctl eval 'navigator.serviceWorker.controller.postMessage("ping"); "sent"' | Out-Null
  Start-Sleep -Milliseconds 800
  $msgs = Wren-Ctl eval 'swMessages.join(",")'
  Expect ($msgs -eq 'pong:ping') 'postMessage both ways (the worker answers through event.source)' $msgs
  $bc = Wren-Ctl eval 'new Promise((ok) => { const a = new BroadcastChannel("t"), b = new BroadcastChannel("t"); b.onmessage = (e) => { ok(e.data + " " + e.origin); a.close(); b.close(); }; a.postMessage("hello"); })' --await
  Expect ($bc -eq "hello $($srv.Origin)") 'BroadcastChannel: a message to another channel of the same name, with the origin' $bc
  $oc = Wren-Ctl eval 'new Promise((ok) => { const src = "const c = new OffscreenCanvas(40, 30); const g = c.getContext(\"2d\"); g.fillStyle = \"#f00\"; g.fillRect(0, 0, 40, 30); const px = g.getImageData(5, 5, 1, 1).data; c.convertToBlob().then((b) => postMessage(px[0] + \",\" + px[3] + \" \" + b.type + \" \" + (b.size > 0)));"; const w = new Worker("data:text/javascript," + encodeURIComponent(src)); w.onmessage = (e) => { ok(e.data); w.terminate(); }; w.onerror = (e) => ok("error " + e.message); })' --await
  Expect ($oc -eq '255,255 image/png true') 'OffscreenCanvas in a worker: drawn, read back, encoded' $oc
  $coi = Wren-Ctl eval 'String(crossOriginIsolated)'
  Expect ($coi -eq 'false') 'crossOriginIsolated is false (realms share no memory)' $coi

  Wren-Ctl nav "$base/virtual-page.html" --wait load | Out-Null
  $page = Wren-Ctl eval 'document.getElementById("x") ? document.getElementById("x").textContent : document.body.textContent.slice(0, 80)'
  Expect ($page -eq 'a page the service worker made') 'a navigation in the scope answered by the worker' $page
  $ctl2 = Wren-Ctl eval '!!navigator.serviceWorker.controller'
  Expect ($ctl2 -eq 'true') 'a page loaded in the scope after activation is controlled' $ctl2

  Wren-Ctl nav "$($srv.Origin)/site/index.html" --wait load | Out-Null
  $out = Wren-Ctl eval 'String(navigator.serviceWorker.controller)'
  Expect ($out -eq 'null') 'a page outside the scope is not controlled' $out
  $un = Wren-Ctl eval 'navigator.serviceWorker.getRegistrations().then((rs) => Promise.all(rs.map((r) => r.unregister()))).then((x) => x.join(","))' --await
  Expect ($un -eq 'true') 'unregister()' $un
} finally {
  if ($name) { Stop-Wren $name }
  Stop-WrenTestServer $srv
}
if ($fails -gt 0) { "sw_e2e: $fails failure(s)"; exit 1 }
'sw_e2e: all passed'
