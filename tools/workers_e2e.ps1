# Shared workers and module workers end to end, in a Wren with no window shown (wren ctl), against the test server:
# examples/site/workers/ connects to the shared worker "w" (shared.js) from two tabs and checks they share one worker
# (connect events, ports both ways, self.name, its global's interfaces), that it stops when the last tab closes and
# that close() makes the next constructor start another one; then a module worker (module.js: static imports, relative
# and absolute, a dynamic import, import.meta.url, importScripts refused); then nested workers (nested.js: a chain of
# three, errors, transfers, a child of another origin, terminate() taking the children along, workers.max_depth).
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
  $base = "$($srv.Origin)/site/workers"
  $name = if ($Check) { Start-WrenChecked } else { Start-Wren -Size 1000x700 }
  $env:WREN_REMOTE = $name
  Wren-Ctl nav "$base/index.html" --wait load | Out-Null
  $tab1 = (Wren-Ctl tabs | Select-Object -First 1) -replace '^(\d+).*', '$1'
  $who = Wren-Ctl eval 'ask("who")' --await
  Expect ($who -eq 'w 1 true function undefined undefined') 'connect event (ports[0] is its source), self.name, a SharedWorkerGlobalScope without DedicatedWorkerGlobalScope or FetchEvent' $who
  $echo = Wren-Ctl eval 'ask("hi")' --await
  Expect ($echo -eq 'echo hi') 'messages both ways through the port' $echo
  $types = Wren-Ctl eval '[typeof SharedWorker, typeof FetchEvent, typeof Clients, typeof ServiceWorkerGlobalScope, shared.port instanceof MessagePort].join(" ")'
  Expect ($types -eq 'function undefined undefined undefined true') 'a page has SharedWorker but none of the service worker interfaces' $types

  $tab2 = Wren-Ctl tab new "$base/index.html" --wait load
  $who2 = Wren-Ctl eval 'ask("who")' --await --tab-id $tab2
  Expect ($who2 -eq 'w 2 true function undefined undefined') 'a second tab of the origin connects to the same worker' $who2
  $joined = Wren-Ctl eval 'got.join(",")' --tab-id $tab1
  Expect ($joined -match 'joined 2') 'the first tab hears of the second connection (one worker shared)' $joined
  $other = Wren-Ctl eval 'new Promise((ok) => { const o = new SharedWorker("shared.js", {name: "other"}); o.port.onmessage = (e) => ok(e.data); o.port.postMessage("who"); })' --await --tab-id $tab2
  Expect ($other -eq 'other 1 true function undefined undefined') 'another name is another worker' $other
  $bad = Wren-Ctl eval 'new Promise((ok) => { const b = new SharedWorker("missing.js"); b.onerror = (e) => ok(e.type + " " + e.constructor.name); setTimeout(() => ok("no error"), 5000); })' --await --tab-id $tab2
  Expect ($bad -eq 'error Event') 'a script that cannot be fetched: error event at the SharedWorker' $bad
  $xo = Wren-Ctl eval 'try { new SharedWorker("http://example.invalid/x.js"); "made" } catch (e) { e.name }' --tab-id $tab2
  Expect ($xo -eq 'SecurityError') 'a script of another origin throws SecurityError' $xo
  Wren-Ctl tab close $tab2 | Out-Null
  $who3 = Wren-Ctl eval 'ask("who")' --await --tab-id $tab1
  Expect ($who3 -eq 'w 2 true function undefined undefined') 'the worker outlives a tab while another uses it' $who3
  $closing = Wren-Ctl eval 'ask("close")' --await --tab-id $tab1
  Expect ($closing -eq 'closing') 'close() in the worker' $closing
  Start-Sleep -Milliseconds 400
  $fresh = Wren-Ctl eval 'new Promise((ok) => { const n = new SharedWorker("shared.js", "w"); n.port.onmessage = (e) => ok(e.data); n.port.postMessage("who"); })' --await --tab-id $tab1
  Expect ($fresh -eq 'w 1 true function undefined undefined') 'after close() the constructor starts a new worker' $fresh

  $mod = Wren-Ctl eval 'new Promise((ok) => { const w = new Worker("module.js", {type: "module"}); w.onmessage = (e) => { ok(e.data); w.terminate(); }; w.onerror = (e) => ok("error " + e.message); w.postMessage(21); })' --await
  Expect ($mod -eq '42 module dynamic /site/workers/module.js TypeError') 'module worker: static imports (relative, absolute, nested), import(), import.meta.url, importScripts throws TypeError' $mod
  $modsh = Wren-Ctl eval 'new Promise((ok) => { const s = new SharedWorker("module.js", {name: "m", type: "module"}); s.port.onmessage = (e) => ok(e.data); s.onerror = () => ok("error"); setTimeout(() => ok("connected"), 1500); })' --await
  Expect ($modsh -eq 'connected') 'a module shared worker starts (no error)' $modsh
  $blob = Wren-Ctl eval 'new Promise((ok) => { const u = URL.createObjectURL(new Blob(["postMessage(\"dedicated \" + self.location.protocol)"], {type: "text/javascript"})); const w = new Worker(u); URL.revokeObjectURL(u); w.onmessage = (e) => { const su = URL.createObjectURL(new Blob(["onconnect = (e) => e.ports[0].postMessage(\"shared\")"])); const s = new SharedWorker(su); s.port.onmessage = (m) => ok(e.data + " " + m.data); }; w.onerror = () => ok("error"); setTimeout(() => ok("timeout"), 5000); })' --await
  Expect ($blob -eq 'dedicated blob: shared') 'workers from blob: URLs (dedicated, revoked right after; shared)' $blob
  $sx = Wren-Ctl eval 'new Promise((ok) => { const src = "const x = new XMLHttpRequest(); x.open(\"GET\", location.origin + \"/site/workers/index.html\", false); x.send(); postMessage(x.status + \" \" + (x.responseText.length > 0) + \" \" + x.readyState);"; const w = new Worker(URL.createObjectURL(new Blob([src]))); w.onmessage = (e) => { ok(e.data); w.terminate(); }; w.onerror = (e) => ok("error " + e.message); setTimeout(() => ok("timeout"), 5000); })' --await
  Expect ($sx -eq '200 true 4') 'a synchronous XMLHttpRequest in a dedicated worker' $sx
  $pipe = Wren-Ctl eval 'new Promise((ok) => { const got = []; new ReadableStream({ start(c) { c.enqueue("a"); c.enqueue("b"); c.close(); } }).pipeTo(new WritableStream({ write(x) { got.push(x); } })).then(() => ok(got.join("")), (e) => ok("error " + e)); })' --await
  Expect ($pipe -eq 'ab') 'ReadableStream.pipeTo a WritableStream' $pipe
  $broken = Wren-Ctl eval 'new Promise((ok) => { const w = new Worker("data:text/javascript,import \"./nowhere.js\";", {type: "module"}); w.onerror = (e) => ok("error"); setTimeout(() => ok("no error"), 5000); })' --await
  Expect ($broken -eq 'error') 'a module worker whose import cannot be resolved fires error' $broken

  # --- nested workers (examples/site/workers/nested.js)
  $ask = 'new Promise((ok) => { const w = new Worker("nested.js", {name: "level3"}); w.onmessage = (e) => { ok(e.data); w.terminate(); }; w.onerror = (e) => ok("error " + e.message); w.postMessage(MSG); setTimeout(() => ok("timeout"), 8000); })'
  $chain = Wren-Ctl eval ($ask -replace 'MSG', '{op: "chain", depth: 3}') --await
  Expect ($chain -eq 'bottom level1 < level2 < level3') 'a chain of three workers, each started by the one above: messages down and up' $chain
  $types = Wren-Ctl eval ($ask -replace 'MSG', '{op: "types"}') --await
  Expect ($types -eq 'function undefined') 'a worker has Worker but not SharedWorker (HTML: [Exposed=Window])' $types
  $throw = Wren-Ctl eval ($ask -replace 'MSG', '{op: "throw"}') --await
  Expect ($throw -eq 'child error true') 'an uncaught error of a nested worker: error event at its Worker object in the parent' $throw
  $tr = Wren-Ctl eval ($ask -replace 'MSG', '{op: "transfer"}') --await
  Expect ($tr -eq 'back 8 detached true port 8') 'a buffer and a MessagePort transferred to a nested worker, the buffer back' $tr
  $cross = Wren-Ctl eval ($ask -replace 'MSG', '{op: "cross"}') --await
  Expect ($cross -eq 'error event') 'a nested worker of another origin: an error event in the parent' $cross
  $keep = Wren-Ctl eval 'new Promise((ok) => { const w = new Worker("nested.js"); let n = 0; w.onmessage = () => { n++; if (n === 5) { w.terminate(); setTimeout(() => { const at = n; setTimeout(() => ok(n === at ? "stopped" : "still ticking " + (n - at)), 300); }, 100); } }; w.postMessage({op: "keep"}); setTimeout(() => ok("timeout " + n), 8000); })' --await
  Expect ($keep -eq 'stopped') 'terminating a worker terminates the workers it started' $keep
  Wren-Ctl pref set workers.max_depth 2 | Out-Null
  $deep = Wren-Ctl eval ($ask -replace 'MSG', '{op: "chain", depth: 3}') --await
  Expect ($deep -eq 'error at level2 < level3') 'workers.max_depth: the worker one level too deep is refused with an error event' $deep
  Wren-Ctl pref set workers.max_depth 16 | Out-Null
} finally {
  if ($name -and $Check) { $leaks = Stop-WrenChecked; Expect (Test-WrenCheckClean $leaks) 'the check build exits with nothing left allocated' $leaks } elseif ($name) { Stop-Wren $name }
  Stop-WrenTestServer $srv
}
if ($fails -gt 0) { "workers_e2e: $fails failure(s)"; exit 1 }
'workers_e2e: all passed'
