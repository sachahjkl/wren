# The origin private file system and File System Access end to end, in a Wren with no window shown (wren ctl), against
# the test server (examples/site/fs/): handles, names, writables (atomic replacement, keepExistingData, seek,
# truncate, abort), directories and their iteration, resolve / isSameEntry / removeEntry, a sync access handle in a
# worker and its lock, structuredClone through IndexedDB and postMessage, the quota and navigator.storage.estimate(),
# then the pickers on real files (browser.dialogs.test_answer stands for the system's dialog: it needs a person), the
# user gesture they need, and the permission to write.
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
$tmp = Join-Path $env:TEMP "wren-fs-e2e-$PID"
New-Item -ItemType Directory -Force $tmp | Out-Null
$srv = Start-WrenTestServer
$name = $null
try {
  $name = if ($Check) { Start-WrenChecked } else { Start-Wren -Size 1000x700 }
  $env:WREN_REMOTE = $name
  Wren-Ctl nav "$($srv.Origin)/site/fs/index.html" --wait load | Out-Null
  $r0 = Wren-Ctl eval 'navigator.storage.getDirectory().then(async (r) => { window.R = r; for (const n of await names(r).then((s) => s ? s.split(",") : [])) await r.removeEntry(n.split(":")[0], {recursive: true}); return r.kind + " " + JSON.stringify(r.name) + " " + (r instanceof FileSystemDirectoryHandle); })' --await
  Expect ($r0 -eq 'directory "" true') 'navigator.storage.getDirectory(): the root, a FileSystemDirectoryHandle named ""' $r0
  $w1 = Wren-Ctl eval 'R.getFileHandle("Notes.txt", {create: true}).then(async (h) => { await put(h, "hello"); return h.kind + " " + h.name + " " + await text(h); })' --await
  Expect ($w1 -eq 'file Notes.txt hello') 'getFileHandle({create}), createWritable, write, close, getFile' $w1
  $case = Wren-Ctl eval 'R.getFileHandle("notes.txt", {create: true}).then(async (h) => { await put(h, "lower"); return await text(await R.getFileHandle("Notes.txt")) + " " + await text(h); })' --await
  Expect ($case -eq 'hello lower') 'names differing only by case are two files (the disk ignores case)' $case
  $atomic = Wren-Ctl eval 'R.getFileHandle("Notes.txt").then(async (h) => { const w = await h.createWritable(); await w.write("new"); const during = await text(h); await w.close(); const after = await text(h); const w2 = await h.createWritable(); await w2.write("dropped"); await w2.abort(); return during + " " + after + " " + await text(h); })' --await
  Expect ($atomic -eq 'hello new new') 'a writable replaces the file only at close() (abort leaves it)' $atomic
  $keep = Wren-Ctl eval 'R.getFileHandle("Notes.txt").then(async (h) => { const w = await h.createWritable({keepExistingData: true}); await w.seek(3); await w.write("!!"); await w.write({type: "write", position: 0, data: "N"}); await w.close(); const a = await text(h); const w2 = await h.createWritable({keepExistingData: true}); await w2.truncate(2); await w2.close(); return a + " " + await text(h); })' --await
  Expect ($keep -eq 'New!! Ne') 'keepExistingData, seek, write at a position, truncate' $keep
  $writer = Wren-Ctl eval 'R.getFileHandle("w.txt", {create: true}).then(async (h) => { const s = await h.createWritable(); const wr = s.getWriter(); await wr.write(new TextEncoder().encode("ab")); await wr.write(new Blob(["cd"])); await wr.close(); return s.locked + " " + await text(h); })' --await
  Expect ($writer -eq 'true abcd') 'a WritableStream writer on it (BufferSource, Blob)' $writer
  $ws = Wren-Ctl eval 'new Promise((ok) => { const got = []; const s = new WritableStream({write(c) { got.push(c); }, close() { ok(got.join("+") + " closed"); }}); const w = s.getWriter(); w.write("a"); w.write("b"); w.close(); })' --await
  Expect ($ws -eq 'a+b closed') 'new WritableStream(sink): chunks in order, then close' $ws
  $dirs = Wren-Ctl eval 'R.getDirectoryHandle("d1", {create: true}).then(async (d) => { const d2 = await d.getDirectoryHandle("d2", {create: true}); const f = await d2.getFileHandle("x", {create: true}); return (await names(R)) + " " + (await R.resolve(f)).join("/") + " " + (await d.resolve(R)) + " " + await f.isSameEntry(await (await d.getDirectoryHandle("d2")).getFileHandle("x")); })' --await
  Expect ($dirs -eq 'Notes.txt:f,d1:d,notes.txt:f,w.txt:f d1/d2/x null true') 'directories, async iteration, resolve, isSameEntry' $dirs
  $errs = Wren-Ctl eval 'Promise.all([err(R.getFileHandle("a/b", {create: true})), err(R.getFileHandle("..")), err(R.getDirectoryHandle("Notes.txt")), err(R.getFileHandle("missing")), err(R.removeEntry("d1")), err(R.removeEntry("d1", {recursive: true}))]).then((a) => a.join(" "))' --await
  Expect ($errs -eq 'TypeError TypeError TypeMismatchError NotFoundError InvalidModificationError ok') 'names, kinds, absent entries, removing a directory' $errs
  $est = Wren-Ctl eval 'navigator.storage.estimate().then(async (e1) => { const h = await R.getFileHandle("big", {create: true}); await put(h, new Uint8Array(100000)); const e2 = await navigator.storage.estimate(); return (e2.usage - e1.usage >= 100000) + " " + (e2.quota > e1.usage); })' --await
  Expect ($est -eq 'true true') 'navigator.storage.estimate() counts the origin private file system' $est
  $wk = Wren-Ctl eval 'R.getFileHandle("Notes.txt").then((h) => new Promise((ok) => { const w = new Worker("worker.js"); w.onmessage = (e) => { ok(e.data); w.terminate(); }; w.onerror = (e) => ok("error " + e.message); w.postMessage(h); }))' --await
  Expect ($wk -eq 'NoModificationAllowedError 11 world 5 NoModificationAllowedError removed Ne') 'sync access handle in a worker (read, write, truncate, getSize, flush, its exclusive lock), a handle posted to it' $wk
  $idb = Wren-Ctl eval 'new Promise((ok, ko) => { const rq = indexedDB.open("fs-e2e", 1); rq.onupgradeneeded = () => rq.result.createObjectStore("h"); rq.onsuccess = async () => { const db = rq.result; const h = await R.getFileHandle("Notes.txt"); const tx = db.transaction("h", "readwrite"); tx.objectStore("h").put(h, "k"); tx.oncomplete = () => { const g = db.transaction("h").objectStore("h").get("k"); g.onsuccess = async () => ok((g.result instanceof FileSystemFileHandle) + " " + await text(g.result) + " " + await g.result.isSameEntry(h)); }; }; rq.onerror = () => ko(rq.error); })' --await
  Expect ($idb -eq 'true Ne true') 'a handle kept in IndexedDB (structured clone) comes back usable' $idb
  $bk = Wren-Ctl eval 'navigator.storageBuckets.open("e2e").then(async (b) => { const d = await b.getDirectory(); await put(await d.getFileHandle("b.txt", {create: true}), "in bucket"); const seen = (await names(R)).includes("b.txt"); const t = await text(await d.getFileHandle("b.txt")); await navigator.storageBuckets.delete("e2e"); return seen + " " + t + " " + await err(b.getDirectory()); })' --await
  Expect ($bk -eq 'false in bucket InvalidStateError') 'StorageBucket.getDirectory(): a file system of its own, gone with the bucket' $bk
  Wren-Ctl pref set opfs.max_bytes_per_origin 1048576 | Out-Null
  $quota = Wren-Ctl eval 'R.getFileHandle("huge", {create: true}).then((h) => err(put(h, new Uint8Array(2 << 20))))' --await
  Expect ($quota -eq 'QuotaExceededError') 'opfs.max_bytes_per_origin: QuotaExceededError' $quota
  Wren-Ctl pref set opfs.max_bytes_per_origin 1073741824 | Out-Null

  # --- File System Access, on files of the disk
  [IO.File]::WriteAllText((Join-Path $tmp 'a.txt'), 'from the disk')
  New-Item -ItemType Directory -Force (Join-Path $tmp 'folder') | Out-Null
  [IO.File]::WriteAllText((Join-Path $tmp 'folder\inner.txt'), 'inner')
  $nog = Wren-Ctl eval 'err(showOpenFilePicker())' --await
  Expect ($nog -eq 'SecurityError') 'a picker without a user gesture: SecurityError' $nog
  Wren-Ctl pref set browser.dialogs.test_answer (Join-Path $tmp 'a.txt') | Out-Null
  Wren-Ctl click --selector '#open' | Out-Null
  Start-Sleep -Milliseconds 600
  $op = Wren-Ctl eval 'picked ? Promise.all([picked.length, picked[0].name, text(picked[0]), picked[0].queryPermission(), picked[0].queryPermission({mode: "readwrite"})]).then((a) => a.join(" ")) : "error " + pickError' --await
  Expect ($op -eq '1 a.txt from the disk granted prompt') 'showOpenFilePicker: a file of the disk, read granted, write to be asked' $op
  Wren-Ctl click --selector '#open' | Out-Null   # (a gesture for requestPermission)
  Start-Sleep -Milliseconds 400
  $wr = Wren-Ctl eval 'picked[0].requestPermission({mode: "readwrite"}).then(async (s) => { await put(picked[0], "written by the page"); return s; })' --await
  $disk = [IO.File]::ReadAllText((Join-Path $tmp 'a.txt'))
  Expect ($wr -eq 'granted' -and $disk -eq 'written by the page') 'requestPermission (the prompt answered), then createWritable writes the file on the disk' "$wr / $disk"
  Wren-Ctl pref set browser.dialogs.test_answer (Join-Path $tmp 'folder') | Out-Null
  Wren-Ctl click --selector '#dir' | Out-Null
  Start-Sleep -Milliseconds 600
  $dp = Wren-Ctl eval 'picked && picked.kind === "directory" ? names(picked).then(async (n) => { const f = await picked.getFileHandle("made.txt", {create: true}); await put(f, "m"); return picked.name + " " + n + " " + await picked.queryPermission({mode: "readwrite"}); }) : "error " + pickError' --await
  $made = Test-Path (Join-Path $tmp 'folder\made.txt')
  Expect ($dp -eq 'folder inner.txt:f granted' -and $made) 'showDirectoryPicker({mode: "readwrite"}): its entries, a file made in it' "$dp $made"
  Wren-Ctl pref set browser.dialogs.test_answer cancel | Out-Null
  Wren-Ctl eval 'window.pickError = null; 1' | Out-Null
  Wren-Ctl click --selector '#save' | Out-Null
  Start-Sleep -Milliseconds 600
  $ab = Wren-Ctl eval 'String(pickError)'
  Expect ($ab -eq 'AbortError') 'a cancelled picker rejects with AbortError' $ab
  Wren-Ctl pref set browser.dialogs.test_answer '' | Out-Null
} finally {
  if ($name -and $Check) { $leaks = Stop-WrenChecked; Expect (Test-WrenCheckClean $leaks) 'the check build exits with nothing left allocated' $leaks } elseif ($name) { Stop-Wren $name }
  Stop-WrenTestServer $srv
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fails -gt 0) { "fs_e2e: $fails failure(s)"; exit 1 }
'fs_e2e: all passed'
