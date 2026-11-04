package e2e_scenarios

// Shared workers and module workers, against the test server: examples/site/workers/ connects to the shared worker "w" (shared.js) from two tabs and
// checks they share one worker (connect events, ports both ways, self.name, its global's interfaces), that it stops when the last tab closes and that
// close() makes the next constructor start another one; then a module worker (module.js: static imports, relative and absolute, a dynamic import,
// import.meta.url, importScripts refused); then nested workers (nested.js: a chain of three, errors, transfers, a child of another origin, terminate()
// taking the children along, workers.max_depth); Media Source Extensions in a dedicated worker.

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file") WORKERS_SIZE :: [2]int{1000, 700}
@(private = "file") WORKERS_PAGE :: "/site/workers/index.html"
// A parent and the child it started.
@(private = "file") PARENT_AND_CHILD :: 2
@(private = "file") USUAL_MAX_DEPTH :: "16"

@(test)
shared_workers_of_two_tabs :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	page := e2e.url(server, WORKERS_PAGE)
	s := e2e.start(t, {size = WORKERS_SIZE, url = page})
	tab1 := e2e.targets(s).tabs[0].id
	s.tab = tab1
	e2e.expect_eval(s, `ask("who")`, "w 1 true function undefined undefined", "connect event (ports[0] is its source), self.name, a SharedWorkerGlobalScope without DedicatedWorkerGlobalScope or FetchEvent")
	e2e.expect_eval(s, `ask("hi")`, "echo hi", "messages both ways through the port")
	e2e.expect_eval(s, `[typeof SharedWorker, typeof FetchEvent, typeof Clients, typeof ServiceWorkerGlobalScope, shared.port instanceof MessagePort].join(" ")`, "function undefined undefined undefined true", "a page has SharedWorker but none of the service worker interfaces")

	tab2 := e2e.new_tab(s, page)
	s.tab = tab2
	e2e.wait_load(s)
	e2e.expect_eval(s, `ask("who")`, "w 2 true function undefined undefined", "a second tab of the origin connects to the same worker")
	s.tab = tab1
	e2e.wait_js(s, `got.includes("joined 2")`)   // the first tab hears of the second connection (one worker shared)
	s.tab = tab2
	e2e.expect_eval(s, `new Promise((ok) => { const o = new SharedWorker("shared.js", {name: "other"}); o.port.onmessage = (e) => ok(e.data); o.port.postMessage("who"); })`, "other 1 true function undefined undefined", "another name is another worker")
	e2e.expect_eval(s, `new Promise((ok) => { const b = new SharedWorker("missing.js"); b.onerror = (e) => ok(e.type + " " + e.constructor.name); setTimeout(() => ok("no error"), 30000); })`, "error Event", "a script that cannot be fetched: error event at the SharedWorker")
	e2e.expect_eval(s, `try { new SharedWorker("http://example.invalid/x.js"); "made" } catch (e) { e.name }`, "SecurityError", "a script of another origin throws SecurityError")
	e2e.close_tab(s, tab2)
	s.tab = tab1
	e2e.expect_eval(s, `ask("who")`, "w 2 true function undefined undefined", "the worker outlives a tab while another uses it")
	alive := e2e.stats(s).shared_workers
	e2e.expect_eval(s, `ask("close")`, "closing", "close() in the worker")
	e2e.wait_until(s, alive, proc(s: ^e2e.Session, alive: int) -> bool { return e2e.stats(s).shared_workers < alive }, "the worker that closed itself to go")
	e2e.expect_eval(s, `new Promise((ok) => { const n = new SharedWorker("shared.js", "w"); n.port.onmessage = (e) => ok(e.data); n.port.postMessage("who"); })`, "w 1 true function undefined undefined", "after close() the constructor starts a new worker")
}

@(test)
module_and_blob_workers :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = WORKERS_SIZE, url = e2e.url(server, WORKERS_PAGE)})
	e2e.expect_eval(s, `new Promise((ok) => { const w = new Worker("module.js", {type: "module"}); w.onmessage = (e) => { ok(e.data); w.terminate(); }; w.onerror = (e) => ok("error " + e.message); w.postMessage(21); })`, "42 module dynamic /site/workers/module.js TypeError", "module worker: static imports (relative, absolute, nested), import(), import.meta.url, importScripts throws TypeError")
	e2e.expect_eval(s, `new Promise((ok) => { const s = new SharedWorker("shared_module.js", {name: "m", type: "module"}); s.port.onmessage = (e) => ok(e.data); s.onerror = () => ok("error"); })`, "module shared m 42", "a module shared worker: its import runs, connect comes, its port answers")
	e2e.expect_eval(s, `new Promise((ok) => { const u = URL.createObjectURL(new Blob(["postMessage(\"dedicated \" + self.location.protocol)"], {type: "text/javascript"})); const w = new Worker(u); URL.revokeObjectURL(u); w.onmessage = (e) => { const su = URL.createObjectURL(new Blob(["onconnect = (e) => e.ports[0].postMessage(\"shared\")"])); const s = new SharedWorker(su); s.port.onmessage = (m) => ok(e.data + " " + m.data); }; w.onerror = () => ok("error"); setTimeout(() => ok("timeout"), 30000); })`, "dedicated blob: shared", "workers from blob: URLs (dedicated, revoked right after; shared)")
	e2e.expect_eval(s, `new Promise((ok) => { const src = "const x = new XMLHttpRequest(); x.open(\"GET\", location.origin + \"/site/workers/index.html\", false); x.send(); postMessage(x.status + \" \" + (x.responseText.length > 0) + \" \" + x.readyState);"; const w = new Worker(URL.createObjectURL(new Blob([src]))); w.onmessage = (e) => { ok(e.data); w.terminate(); }; w.onerror = (e) => ok("error " + e.message); setTimeout(() => ok("timeout"), 30000); })`, "200 true 4", "a synchronous XMLHttpRequest in a dedicated worker")
	e2e.expect_eval(s, `new Promise((ok) => { const src = "try { importScripts(ORIGIN + \"/site/workers/index.html\"); postMessage(\"ran\"); } catch (e) { postMessage(e.name); }".replace("ORIGIN", JSON.stringify(location.origin.replace("127.0.0.1", "localhost"))); const w = new Worker(URL.createObjectURL(new Blob([src]))); w.onmessage = (e) => { ok(e.data); w.terminate(); }; w.onerror = (e) => ok("error " + e.message); setTimeout(() => ok("timeout"), 30000); })`, "NetworkError", "importScripts: the syntax error of a script of another origin (no CORS: its errors are muted) is a NetworkError")
	e2e.expect_eval(s, `new Promise((ok) => { const got = []; new ReadableStream({ start(c) { c.enqueue("a"); c.enqueue("b"); c.close(); } }).pipeTo(new WritableStream({ write(x) { got.push(x); } })).then(() => ok(got.join("")), (e) => ok("error " + e)); })`, "ab", "ReadableStream.pipeTo a WritableStream")
	e2e.expect_eval(s, `new Promise((ok) => { const w = new Worker("data:text/javascript,import \"./nowhere.js\";", {type: "module"}); w.onerror = (e) => ok("error"); setTimeout(() => ok("no error"), 30000); })`, "error", "a module worker whose import cannot be resolved fires error")
}

// A message for a worker of nested.js (examples/site/workers/nested.js), its answer.
@(private = "file")
nested :: proc(message: string) -> string {
	return fmt.tprintf(`new Promise((ok) => {{ const w = new Worker("nested.js", {{name: "level3"}}); w.onmessage = (e) => {{ ok(e.data); w.terminate(); }}; w.onerror = (e) => ok("error " + e.message); w.postMessage(%s); setTimeout(() => ok("timeout"), 30000); }})`, message)
}

@(test)
nested_workers :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = WORKERS_SIZE, url = e2e.url(server, WORKERS_PAGE)})
	e2e.expect_eval(s, nested(`{op: "chain", depth: 3}`), "bottom level1 < level2 < level3", "a chain of three workers, each started by the one above: messages down and up")
	e2e.expect_eval(s, nested(`{op: "types"}`), "function undefined", "a worker has Worker but not SharedWorker (HTML: [Exposed=Window])")
	e2e.expect_eval(s, nested(`{op: "throw"}`), "child error true", "an uncaught error of a nested worker: error event at its Worker object in the parent")
	e2e.expect_eval(s, nested(`{op: "transfer"}`), "back 8 detached true port 8", "a buffer and a MessagePort transferred to a nested worker, the buffer back")
	e2e.expect_eval(s, nested(`{op: "cross"}`), "error event", "a nested worker of another origin: an error event in the parent")

	// terminating a worker terminates the workers it started: both threads go, and the page hears no more ticks
	e2e.eval(s, `new Promise((ok) => { window.ticks = 0; window.keeper = new Worker("nested.js"); keeper.onmessage = () => { if (++ticks === 5) ok("ticking"); }; keeper.postMessage({op: "keep"}); setTimeout(() => ok("timeout"), 30000); })`, await = true)
	running := e2e.stats(s).workers_running
	e2e.eval(s, "keeper.terminate(); 1")
	e2e.wait_until(s, running - PARENT_AND_CHILD, proc(s: ^e2e.Session, most: int) -> bool { return e2e.stats(s).workers_running <= most }, "the worker and the child it started to stop")
	seen := e2e.eval(s, "String(ticks)")
	e2e.wait_frames(s)
	e2e.expect_eval(s, "String(ticks)", seen, "terminating a worker terminates the workers it started")

	e2e.pref_set(s, "workers.max_depth", "2")
	e2e.expect_eval(s, nested(`{op: "chain", depth: 3}`), "error at level2 < level3", "workers.max_depth: the worker one level too deep is refused with an error event")
	e2e.pref_set(s, "workers.max_depth", USUAL_MAX_DEPTH)
}

// Media Source Extensions in a dedicated worker (mse_worker.js): the handle transferred, the page's video plays.
@(test)
media_source_in_a_worker :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = WORKERS_SIZE, url = e2e.url(server, WORKERS_PAGE)})
	said := e2e.eval(s, `new Promise((ok) => { const w = new Worker("mse_worker.js"); const v = document.createElement("video"); v.muted = true; document.body.appendChild(v); let first = ""; w.onmessage = (e) => { const d = e.data; if (d.handle) { first = [d.can, d.url, d.same, d.handle instanceof MediaSourceHandle].join(" "); v.srcObject = d.handle; let again; try { structuredClone(d.handle, {transfer: [d.handle]}); again = "cloned"; } catch (x) { again = x.name; } first += " " + (v.srcObject === d.handle) + " " + again; } else if (d.done) { const end = () => ok(first + " | " + d.done + " | " + v.readyState + " " + v.duration.toFixed(1)); v.readyState >= 1 ? end() : v.addEventListener("loadedmetadata", end); } }; w.onerror = (e) => ok("error " + e.message); setTimeout(() => ok("timeout " + first), 15000); })`, await = true)
	// (the end of the appended media and the state the video has reached by then vary within these)
	parts := strings.split(said, " | ", context.temp_allocator)
	ok := len(parts) == 8 && parts[0] == "true blob: true true true DataCloneError" && parts[1] == "sourceopen open" && parts[2] == "buffers 1" && parts[3] == "updating true" &&
		strings.has_prefix(parts[4], "updated false 1 4.") && parts[5] == "ended ended" && parts[6] == "sourceended" && parts[7] >= "1 4." && parts[7] < "5"
	testing.expectf(t, ok, "MediaSource in a dedicated worker: canConstructInDedicatedWorker, an object URL that names nothing, its handle transferred once and set as a video's srcObject, appends and endOfStream in the worker, the page's video gets the metadata: got %q", said)
}
