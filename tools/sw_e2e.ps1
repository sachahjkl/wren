# Service workers, the Cache API and BroadcastChannel end to end, in a Wren with no window shown (wren ctl), against
# the test server (http://127.0.0.1: a secure context): examples/site/sw/ registers sw.js, which caches data.txt at
# install, claims the page, answers virtual.txt and a whole navigation (virtual-page.html) itself, serves data.txt from
# its cache and answers messages. Checks the page's view (ready, controller, the answers, the messages, caches.keys)
# and that a page with no service worker in its scope is not intercepted. Then the Cache API's Vary / ignoreVary and
# response URLs, which interfaces each realm has, a module service worker, and with tools/testserver/sw.go: versions
# (update(), waiting, skipWaiting, controllerchange, the update check of a navigation), clients (matchAll, get,
# openWindow, focus), an idle worker stopped and started again, navigation preload (preloadResponse, fallback).
# -Check: the same on the check build (build.bat check), which must exit with nothing left allocated.
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
  $base = "$($srv.Origin)/site/sw"
  $name = if ($Check) { Start-WrenChecked } else { Start-Wren -Size 1000x700 }
  $env:WREN_REMOTE = $name
  Wren-Ctl nav "$base/index.html" --wait load | Out-Null
  $scope = Wren-Ctl eval 'registered' --await
  Expect ($scope -eq "$base/") 'register() resolves with the registration (its scope)' $scope
  $state = Wren-Ctl eval 'navigator.serviceWorker.ready.then((r) => r.active.state === "activated" ? "activated" : new Promise((ok) => { r.active.onstatechange = () => { if (r.active.state === "activated") ok("activated"); }; }))' --await
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
  $est = Wren-Ctl eval 'navigator.storage.estimate().then((e) => e.usage > 0 && e.quota > e.usage)' --await
  Expect ($est -eq 'true') 'navigator.storage.estimate() counts the Cache API' $est
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
  $vary = Wren-Ctl eval 'caches.open("vary").then((c) => c.put(new Request("vx", {headers: {"X-L": "a"}}), new Response("A", {headers: {"Vary": "X-L"}})).then(() => c.put(new Request("vx", {headers: {"X-L": "b"}}), new Response("B", {headers: {"Vary": "X-L"}}))).then(() => Promise.all([c.match(new Request("vx", {headers: {"X-L": "b"}})).then((r) => r.text()), c.match("vx").then((r) => String(r)), c.matchAll("vx", {ignoreVary: true}).then((rs) => rs.length), c.keys().then((ks) => ks.map((k) => k.headers.get("x-l")).join(""))]))).then((a) => a.join(" "))' --await
  Expect ($vary -eq 'B undefined 2 ab') 'Cache API: Vary (one entry per varying request header), ignoreVary, the stored request headers' $vary
  $rurl = Wren-Ctl eval 'caches.open("v1").then((c) => c.match("data.txt")).then((r) => new URL(r.url).pathname)' --await
  Expect ($rurl -eq '/site/sw/data.txt') 'a response from the cache keeps its URL' $rurl
  $ptypes = Wren-Ctl eval '[typeof FetchEvent, typeof Clients, typeof ExtendableEvent, typeof ServiceWorkerGlobalScope, typeof ServiceWorker].join(" ")'
  Expect ($ptypes -eq 'undefined undefined undefined undefined function') 'a page has none of the service worker realm interfaces' $ptypes
  $mod = Wren-Ctl eval 'navigator.serviceWorker.register("module-sw.js", {scope: "./module/", type: "module"}).then((r) => new Promise((ok) => { const go = () => { const w = r.active; if (!w) { setTimeout(go, 50); return; } const n = swMessages.length; w.postMessage("hi"); const t = setInterval(() => { if (swMessages.length > n) { clearInterval(t); ok(swMessages[swMessages.length - 1]); } }, 20); }; go(); }))' --await
  Expect ($mod -eq 'module:imported TypeError') 'a module service worker ({type: "module"}): static import, no importScripts' $mod

  Wren-Ctl nav "$base/virtual-page.html" --wait load | Out-Null
  $page = Wren-Ctl eval 'document.getElementById("x") ? document.getElementById("x").textContent : document.body.textContent.slice(0, 80)'
  Expect ($page -eq 'a page the service worker made') 'a navigation in the scope answered by the worker' $page
  $ctl2 = Wren-Ctl eval '!!navigator.serviceWorker.controller'
  Expect ($ctl2 -eq 'true') 'a page loaded in the scope after activation is controlled' $ctl2

  # --- versions (tools/testserver/sw.go: /sw/ver.js changes after /sw/bump), clients, idle stop, navigation preload
  $o = $srv.Origin
  Wren-Ctl nav "$o/sw/ver/page" --wait load | Out-Null
  $tab1 = (Wren-Ctl tabs | Select-Object -First 1) -replace '^(\d+).*', '$1'
  $askJs = 'window.ask = (m) => new Promise((ok) => { const n = swMessages.length; navigator.serviceWorker.controller.postMessage(m); const t = setInterval(() => { if (swMessages.length > n) { clearInterval(t); ok(swMessages[swMessages.length - 1]); } }, 20); setTimeout(() => ok("no answer"), 30000); }); 1'
  $v1 = Wren-Ctl eval 'navigator.serviceWorker.register("/sw/ver.js", {scope: "/sw/ver/"}).then(() => navigator.serviceWorker.ready).then((r) => r.active.state === "activated" ? "activated" : new Promise((ok) => { r.active.onstatechange = () => { if (r.active.state === "activated") ok("activated"); }; }))' --await
  Expect ($v1 -eq 'activated') 'a registration of /sw/ver.js (version 1) activated' $v1
  Start-Sleep -Milliseconds 300
  Wren-Ctl eval $askJs | Out-Null
  $types = Wren-Ctl eval 'ask("types")' --await
  Expect ($types -eq 'function function undefined undefined function') 'a service worker has FetchEvent and Clients, not DedicatedWorkerGlobalScope nor SharedWorkerGlobalScope' $types
  $same = Wren-Ctl eval 'navigator.serviceWorker.getRegistration().then((r) => r.update()).then((r) => String(r.installing) + " " + String(r.waiting))' --await
  Expect ($same -eq 'null null') 'update() with an unchanged script installs nothing' $same
  Wren-Ctl eval 'fetch("/sw/bump").then((r) => r.text())' --await | Out-Null
  $wait = Wren-Ctl eval 'navigator.serviceWorker.getRegistration().then((r) => new Promise((ok) => { r.onupdatefound = () => { const w = r.installing; w.onstatechange = () => { if (w.state === "installed") ok("waiting " + (r.waiting === w) + " " + (r.active !== w)); }; }; r.update(); setTimeout(() => ok("timeout"), 30000); }))' --await
  Expect ($wait -eq 'waiting true true') 'update() of a changed script: updatefound, the new version installs and waits (the page uses the old one)' $wait
  $who1 = Wren-Ctl eval 'ask("who")' --await
  Expect ($who1 -eq 'v1') 'the waiting version does not control the page yet' $who1
  $chg = Wren-Ctl eval 'new Promise((ok) => { navigator.serviceWorker.oncontrollerchange = () => ok("changed"); navigator.serviceWorker.getRegistration().then((r) => r.waiting.postMessage("skip")); setTimeout(() => ok("timeout"), 30000); })' --await
  Expect ($chg -eq 'changed') 'skipWaiting() in the waiting version: it activates, controllerchange' $chg
  Start-Sleep -Milliseconds 300
  $who2 = Wren-Ctl eval 'ask("who")' --await
  Expect ($who2 -eq 'v2') 'the new version controls the page' $who2
  $vt = Wren-Ctl eval 'fetch("v.txt").then((r) => r.text())' --await
  Expect ($vt -eq 'v2') 'requests go to the new version' $vt
  $st = Wren-Ctl eval 'ask("state")' --await
  Expect ($st -eq 'activated true') 'the worker sees its own state and registration.active' $st
  $cl = Wren-Ctl eval 'ask("clients")' --await
  Expect ($cl -eq '1 window:/sw/ver/page') 'clients.matchAll knows the open window clients of the scope' $cl
  $get = Wren-Ctl eval 'ask("get")' --await
  Expect ($get -eq 'got true top-level') 'clients.get(id)' $get
  $nofocus = Wren-Ctl eval 'ask("focus")' --await
  Expect ($nofocus -eq 'refused InvalidAccessError') 'WindowClient.focus() without a user gesture in a window of the site is refused' $nofocus
  Wren-Ctl eval 'window.wk = new Worker("data:text/javascript,setTimeout(() => 0, 1e9)"); 1' | Out-Null
  $wcl = Wren-Ctl eval 'ask("workers")' --await
  Expect ($wcl -match '^worker:') 'clients.matchAll({type: "worker"}) lists the dedicated workers of its clients' $wcl
  $wsw = Wren-Ctl eval 'new Promise((ok) => { const t0 = Date.now(); const src = "const c = navigator.serviceWorker; c.onmessage = (e) => postMessage(c.controller.state + \" \" + e.data + \" \" + (e.source instanceof ServiceWorker)); if (c.controller) c.controller.postMessage(\"who\"); else postMessage(\"no controller\");"; const w = new Worker(URL.createObjectURL(new Blob([src]))); w.onmessage = (e) => { ok(e.data); w.terminate(); }; w.onerror = (e) => ok("error " + e.message); setTimeout(() => ok("timeout " + (Date.now() - t0) + " ms"), 30000); })' --await
  Expect ($wsw -match '^activated v\d+ true$') 'navigator.serviceWorker in a dedicated worker: its document''s controller, messages both ways' $wsw
  Wren-Ctl click --selector '#x' | Out-Null
  $op = Wren-Ctl eval 'ask("open")' --await
  Expect ($op -eq 'opened /sw/ver/opened') 'clients.openWindow opens a tab and resolves with its WindowClient' $op
  Wren-Ctl click --selector '#x' --tab-id $tab1 | Out-Null
  $fo = Wren-Ctl eval 'ask("focus")' --await --tab-id $tab1
  Expect ($fo -eq 'focused true') 'WindowClient.focus() shows the client''s tab' $fo
  Wren-Ctl pref set service_workers.idle_ms 400 | Out-Null
  $rem = Wren-Ctl eval 'ask("remember")' --await --tab-id $tab1
  Start-Sleep -Milliseconds 1500
  $rec = Wren-Ctl eval 'ask("recall")' --await --tab-id $tab1
  Expect ($rem -eq 'ok' -and $rec -eq 'nothing') 'an idle service worker stops (service_workers.idle_ms) and starts again for the next event' "$rem $rec"
  Wren-Ctl pref set service_workers.idle_ms 30000 | Out-Null
  Wren-Ctl pref set service_workers.update_check_hours 0 | Out-Null
  Wren-Ctl eval 'fetch("/sw/bump").then((r) => r.text())' --await --tab-id $tab1 | Out-Null
  Wren-Ctl nav "$o/sw/ver/page" --wait load --tab-id $tab1 | Out-Null
  $nu = Wren-Ctl eval 'navigator.serviceWorker.getRegistration().then((r) => new Promise((ok) => { const go = () => (r.waiting || r.installing) ? ok("new version") : setTimeout(go, 50); go(); setTimeout(() => ok("none"), 30000); }))' --await --tab-id $tab1
  Expect ($nu -eq 'new version') 'a navigation in the scope checks the script (service_workers.update_check_hours) and installs a changed one' $nu
  Wren-Ctl pref set service_workers.update_check_hours 24 | Out-Null
  $pre = Wren-Ctl eval 'navigator.serviceWorker.register("/sw/preload.js", {scope: "/sw/pre/"}).then((r) => new Promise((ok) => { const go = () => r.active && r.active.state === "activated" ? r.navigationPreload.getState().then((s) => ok(s.enabled + " " + s.headerValue)) : setTimeout(go, 50); go(); }))' --await --tab-id $tab1
  Expect ($pre -eq 'true wren-test') 'navigationPreload.enable / setHeaderValue / getState' $pre
  Wren-Ctl nav "$o/sw/pre/page" --wait load --tab-id $tab1 | Out-Null
  $pp = Wren-Ctl eval 'document.getElementById("x") ? document.getElementById("x").textContent : document.body.textContent' --tab-id $tab1
  Expect ($pp -eq 'preloaded 200 header=wren-test') 'FetchEvent.preloadResponse: the navigation''s request, with Service-Worker-Navigation-Preload' $pp
  Wren-Ctl nav "$o/sw/pre/fallback" --wait load --tab-id $tab1 | Out-Null
  $pf = Wren-Ctl eval 'document.body.textContent' --tab-id $tab1
  Expect ($pf -eq 'header=wren-test') 'a navigation the worker does not answer gets the preload''s response' $pf
  $unr = Wren-Ctl eval 'navigator.serviceWorker.getRegistration().then((r) => r.unregister()).then(async (ok) => ok + " " + !!navigator.serviceWorker.controller + " " + String(await navigator.serviceWorker.getRegistration()))' --await --tab-id $tab1
  Expect ($unr -eq 'true true undefined') 'unregister(): the page it controls stays controlled, the registration is no longer found' $unr
  Wren-Ctl nav "$o/sw/pre/page" --wait load --tab-id $tab1 | Out-Null
  $gone = Wren-Ctl eval 'document.body.textContent + " " + !!navigator.serviceWorker.controller' --tab-id $tab1
  Expect ($gone -eq 'header= false') 'its last client gone, the registration is too (a new page is not controlled)' $gone
  Wren-Ctl eval 'navigator.serviceWorker.getRegistrations().then((rs) => Promise.all(rs.filter((r) => new URL(r.scope).pathname.startsWith("/sw/")).map((r) => r.unregister())))' --await --tab-id $tab1 | Out-Null

  # --- frame navigations: a scope given to register() is resolved against the document (its query kept); the worker
  # answers the navigations of an <iframe> and of a <frame> with destination "iframe" / "frame" and mode "navigate"
  Wren-Ctl nav "$o/sw/sub/host" --wait load --tab-id $tab1 | Out-Null
  $fs = Wren-Ctl eval 'navigator.serviceWorker.register("/sw/frames.js", {scope: "../frm/?q"}).then((r) => new Promise((ok) => { const go = () => r.active && r.active.state === "activated" ? ok(new URL(r.scope).pathname + new URL(r.scope).search) : setTimeout(go, 50); go(); }))' --await --tab-id $tab1
  Expect ($fs -eq '/sw/frm/?q') 'register(): a given scope is parsed against the document''s URL and keeps its query' $fs
  $fr = Wren-Ctl eval 'new Promise((ok) => { for (const [tag, q] of [["iframe", "?q=i"], ["frame", "?q=f"]]) { const f = document.createElement(tag); f.src = "/sw/frm/" + q; document.body.appendChild(f); } const go = () => said.length >= 2 ? ok(said.slice().sort().join(",")) : setTimeout(go, 50); go(); setTimeout(() => ok("timeout " + said.join(",")), 8000); })' --await --tab-id $tab1
  Expect ($fr -eq 'frame navigate ?q=f,iframe navigate ?q=i') 'the worker answers frame navigations in its scope (request.destination iframe / frame, mode navigate)' $fr
  Wren-Ctl eval 'navigator.serviceWorker.getRegistrations().then((rs) => Promise.all(rs.filter((r) => new URL(r.scope).pathname.startsWith("/sw/")).map((r) => r.unregister())))' --await --tab-id $tab1 | Out-Null

  Wren-Ctl nav "$($srv.Origin)/site/index.html" --wait load --tab-id $tab1 | Out-Null
  $out = Wren-Ctl eval 'String(navigator.serviceWorker.controller)' --tab-id $tab1
  Expect ($out -eq 'null') 'a page outside the scope is not controlled' $out
  $un = Wren-Ctl eval 'navigator.serviceWorker.getRegistrations().then((rs) => Promise.all(rs.map((r) => r.unregister()))).then((x) => x.join(","))' --await --tab-id $tab1
  Expect ($un -match '^true(,true)*$') 'unregister()' $un
} finally {
  if ($name -and $Check) { $leaks = Stop-WrenChecked; Expect (Test-WrenCheckClean $leaks) 'the check build exits with nothing left allocated' $leaks } elseif ($name) { Stop-Wren $name }
  Stop-WrenTestServer $srv
}
if ($fails -gt 0) { "sw_e2e: $fails failure(s)"; exit 1 }
'sw_e2e: all passed'
