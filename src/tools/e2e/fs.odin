package e2e_scenarios

// The origin private file system and File System Access, against the test server (examples/site/fs/): handles, names, writables (atomic replacement,
// keepExistingData, seek, truncate, abort), directories and their iteration, resolve / isSameEntry / removeEntry, a sync access handle in a worker and
// its lock, structuredClone through IndexedDB and postMessage, the quota and navigator.storage.estimate(), then the pickers on real files
// (browser.dialogs.test_answer stands for the system's dialog: it needs a person), the user gesture they need, and the permission to write.

import "core:fmt"
import "core:os"
import "core:testing"
import "wb:e2e"

@(private = "file") FS_SIZE :: [2]int{1000, 700}
@(private = "file") FS_PAGE :: "/site/fs/index.html"
@(private = "file") SMALL_QUOTA :: "1048576"
@(private = "file") USUAL_QUOTA :: "1073741824"
@(private = "file") PICK_DONE :: "!!window.picked || !!window.pickError"

// A button whose click opens a picker: its outcome has come when this returns. Whichever came before has been forgotten.
@(private = "file")
click_picker :: proc(s: ^e2e.Session, button: string) {
	e2e.eval(s, "window.picked = null; window.pickError = null; 1")
	e2e.click(s, button)
	e2e.wait_js(s, PICK_DONE)
}

@(test)
origin_private_file_system :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = FS_SIZE, url = e2e.url(server, FS_PAGE)})
	e2e.expect_eval(s, `navigator.storage.getDirectory().then(async (r) => { window.R = r; return r.kind + " " + JSON.stringify(r.name) + " " + (r instanceof FileSystemDirectoryHandle); })`, `directory "" true`, `navigator.storage.getDirectory(): the root, a FileSystemDirectoryHandle named ""`)
	e2e.expect_eval(s, `R.getFileHandle("Notes.txt", {create: true}).then(async (h) => { await put(h, "hello"); return h.kind + " " + h.name + " " + await text(h); })`, "file Notes.txt hello", "getFileHandle({create}), createWritable, write, close, getFile")
	e2e.expect_eval(s, `R.getFileHandle("notes.txt", {create: true}).then(async (h) => { await put(h, "lower"); return await text(await R.getFileHandle("Notes.txt")) + " " + await text(h); })`, "hello lower", "names differing only by case are two files (the disk ignores case)")
	e2e.expect_eval(s, `R.getFileHandle("Notes.txt").then(async (h) => { const w = await h.createWritable(); await w.write("new"); const during = await text(h); await w.close(); const after = await text(h); const w2 = await h.createWritable(); await w2.write("dropped"); await w2.abort(); return during + " " + after + " " + await text(h); })`, "hello new new", "a writable replaces the file only at close() (abort leaves it)")
	e2e.expect_eval(s, `R.getFileHandle("Notes.txt").then(async (h) => { const w = await h.createWritable({keepExistingData: true}); await w.seek(3); await w.write("!!"); await w.write({type: "write", position: 0, data: "N"}); await w.close(); const a = await text(h); const w2 = await h.createWritable({keepExistingData: true}); await w2.truncate(2); await w2.close(); return a + " " + await text(h); })`, "New!! Ne", "keepExistingData, seek, write at a position, truncate")
	e2e.expect_eval(s, `R.getFileHandle("w.txt", {create: true}).then(async (h) => { const s = await h.createWritable(); const wr = s.getWriter(); await wr.write(new TextEncoder().encode("ab")); await wr.write(new Blob(["cd"])); await wr.close(); return s.locked + " " + await text(h); })`, "true abcd", "a WritableStream writer on it (BufferSource, Blob)")
	e2e.expect_eval(s, `new Promise((ok) => { const got = []; const s = new WritableStream({write(c) { got.push(c); }, close() { ok(got.join("+") + " closed"); }}); const w = s.getWriter(); w.write("a"); w.write("b"); w.close(); })`, "a+b closed", "new WritableStream(sink): chunks in order, then close")
	e2e.expect_eval(s, `R.getDirectoryHandle("d1", {create: true}).then(async (d) => { const d2 = await d.getDirectoryHandle("d2", {create: true}); const f = await d2.getFileHandle("x", {create: true}); return (await names(R)) + " " + (await R.resolve(f)).join("/") + " " + (await d.resolve(R)) + " " + await f.isSameEntry(await (await d.getDirectoryHandle("d2")).getFileHandle("x")); })`, "Notes.txt:f,d1:d,notes.txt:f,w.txt:f d1/d2/x null true", "directories, async iteration, resolve, isSameEntry")
	e2e.expect_eval(s, `Promise.all([err(R.getFileHandle("a/b", {create: true})), err(R.getFileHandle("..")), err(R.getDirectoryHandle("Notes.txt")), err(R.getFileHandle("missing")), err(R.removeEntry("d1")), err(R.removeEntry("d1", {recursive: true}))]).then((a) => a.join(" "))`, "TypeError TypeError TypeMismatchError NotFoundError InvalidModificationError ok", "names, kinds, absent entries, removing a directory")
	e2e.expect_eval(s, `navigator.storage.estimate().then(async (e1) => { const h = await R.getFileHandle("big", {create: true}); await put(h, new Uint8Array(100000)); const e2 = await navigator.storage.estimate(); return (e2.usage - e1.usage >= 100000) + " " + (e2.quota > e1.usage); })`, "true true", "navigator.storage.estimate() counts the origin private file system")
	e2e.expect_eval(s, `R.getFileHandle("Notes.txt").then((h) => new Promise((ok) => { const w = new Worker("worker.js"); w.onmessage = (e) => { ok(e.data); w.terminate(); }; w.onerror = (e) => ok("error " + e.message); w.postMessage(h); }))`, "NoModificationAllowedError 11 world 5 NoModificationAllowedError removed Ne", "sync access handle in a worker (read, write, truncate, getSize, flush, its exclusive lock), a handle posted to it")
	e2e.expect_eval(s, `new Promise((ok, ko) => { const rq = indexedDB.open("fs-e2e", 1); rq.onupgradeneeded = () => rq.result.createObjectStore("h"); rq.onsuccess = async () => { const db = rq.result; const h = await R.getFileHandle("Notes.txt"); const tx = db.transaction("h", "readwrite"); tx.objectStore("h").put(h, "k"); tx.oncomplete = () => { const g = db.transaction("h").objectStore("h").get("k"); g.onsuccess = async () => ok((g.result instanceof FileSystemFileHandle) + " " + await text(g.result) + " " + await g.result.isSameEntry(h)); }; }; rq.onerror = () => ko(rq.error); })`, "true Ne true", "a handle kept in IndexedDB (structured clone) comes back usable")
	e2e.expect_eval(s, `navigator.storageBuckets.open("e2e").then(async (b) => { const d = await b.getDirectory(); await put(await d.getFileHandle("b.txt", {create: true}), "in bucket"); const seen = (await names(R)).includes("b.txt"); const t = await text(await d.getFileHandle("b.txt")); await navigator.storageBuckets.delete("e2e"); return seen + " " + t + " " + await err(b.getDirectory()); })`, "false in bucket InvalidStateError", "StorageBucket.getDirectory(): a file system of its own, gone with the bucket")
	e2e.pref_set(s, "opfs.max_bytes_per_origin", SMALL_QUOTA)
	e2e.expect_eval(s, `R.getFileHandle("huge", {create: true}).then((h) => err(put(h, new Uint8Array(2 << 20))))`, "QuotaExceededError", "opfs.max_bytes_per_origin: QuotaExceededError")
	e2e.pref_set(s, "opfs.max_bytes_per_origin", USUAL_QUOTA)
}

// File System Access, on files of the disk.
@(test)
file_system_access_on_the_disk :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	dir := e2e.temp_folder(t, "picked")
	file := fmt.tprintf("%s/a.txt", dir)
	folder := fmt.tprintf("%s/folder", dir)
	e2e.write_text(file, "from the disk")
	_ = os.make_directory_all(folder)
	e2e.write_text(fmt.tprintf("%s/inner.txt", folder), "inner")

	s := e2e.start(t, {size = FS_SIZE, url = e2e.url(server, FS_PAGE)})
	e2e.expect_eval(s, "err(showOpenFilePicker())", "SecurityError", "a picker without a user gesture: SecurityError")
	e2e.pref_set(s, "browser.dialogs.test_answer", file)
	click_picker(s, "#open")
	e2e.expect_eval(s, `picked ? Promise.all([picked.length, picked[0].name, text(picked[0]), picked[0].queryPermission(), picked[0].queryPermission({mode: "readwrite"})]).then((a) => a.join(" ")) : "error " + pickError`, "1 a.txt from the disk granted prompt", "showOpenFilePicker: a file of the disk, read granted, write to be asked")
	click_picker(s, "#open")   // (a gesture for requestPermission)
	e2e.expect_eval(s, `picked[0].requestPermission({mode: "readwrite"}).then(async (s) => { await put(picked[0], "written by the page"); return s; })`, "granted", "requestPermission (the prompt answered)")
	testing.expect_value(t, e2e.read_text(file), "written by the page")
	e2e.pref_set(s, "browser.dialogs.test_answer", folder)
	click_picker(s, "#dir")
	e2e.expect_eval(s, `picked && picked.kind === "directory" ? names(picked).then(async (n) => { const f = await picked.getFileHandle("made.txt", {create: true}); await put(f, "m"); return picked.name + " " + n + " " + await picked.queryPermission({mode: "readwrite"}); }) : "error " + pickError`, "folder inner.txt:f granted", `showDirectoryPicker({mode: "readwrite"}): its entries, a file made in it`)
	testing.expect(t, os.exists(fmt.tprintf("%s/made.txt", folder)), "the file made in the folder is on the disk")
	e2e.pref_set(s, "browser.dialogs.test_answer", "cancel")
	click_picker(s, "#save")
	e2e.expect_eval(s, "String(pickError)", "AbortError", "a cancelled picker rejects with AbortError")
	e2e.pref_set(s, "browser.dialogs.test_answer", "")
}
