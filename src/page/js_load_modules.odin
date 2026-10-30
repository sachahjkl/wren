package page

// ES modules (HTML "fetch a module script graph", "resolve a module specifier", import maps, import()).
//
// The page keeps a module map (URL -> the module's source and what it imports). A graph is fetched by the browser,
// in parallel, before the engine sees it: each module, once it arrived, is handed to the engine to be compiled
// (wj_module_prepare), which tells the browser what it imports (Module_request: resolved here, import maps included,
// and fetched if new). A graph is complete when every module reachable from its root is compiled; then a module
// script runs (wj_module_run), or an import() settles (wj_module_import_done, from a task of its own). A module that
// fails to arrive or to compile fails every graph that needs it: the script element gets an error event, the
// import() promise a TypeError.
//
// Module scripts are fetched with CORS (their crossorigin attribute: "anonymous" by default), as JavaScript (or JSON
// for `with {type: "json"}`); an inline module is named after its document with a "#inline-module-<n>" fragment.

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "wb:base"
import "wb:fetch"
import "wb:js"
import "wb:url"
import "wb:wasm"

Module_Entry_State :: enum u8 { Fetching, Fetched, Prepared, Failed }

Module_Entry :: struct {
	page:      ^Page,
	key:       string,              // owned: its name (the requested URL, or the inline name)
	type:      Api_ModuleType,
	state:     Module_Entry_State,
	source:    [dynamic]byte,
	deps:      [dynamic]string,     // owned: the keys of what it imports
	task:      base.Handle,
	cors:      Cors_Setting,
	error:     string,              // owned
	rethrow:   bool,                // it does not compile (or an import cannot be resolved): the engine keeps the error
	compiling: bool,                // its bytecode is being made on another thread (js_load_compile.odin)
}

Module_Graph_State :: enum u8 { Pending, Ready, Failed }

Module_Graph :: struct {
	root:      string,              // owned: the key of its root module
	state:     Module_Graph_State,
	script:    ^Page_Script,        // the module script that waits for it (nil for import())
	import_id: i32,                 // import(): the engine's id of the promise
	is_import: bool,
	worker_root: bool,              // the graph of a module worker's script (js_worker_module_start)
	error:     string,              // owned: why it failed; with `rethrow`, the module whose error is to be rethrown
	rethrow:   bool,                // failed because of a module's error to rethrow (reported / rejected with it)
}

Import_Map_Entry :: struct { key: string, value: string, null: bool }   // owned strings

Import_Map_Scope :: struct { prefix: string, imports: [dynamic]Import_Map_Entry }

Module_State :: struct {
	entries:   map[string]^Module_Entry,
	graphs:    [dynamic]^Module_Graph,
	imports:   [dynamic]Import_Map_Entry,   // sorted: longest keys first
	scopes:    [dynamic]Import_Map_Scope,   // sorted: longest prefixes first
	inline_n:  int,
	preparing: ^Module_Entry,               // the module wj_module_prepare is compiling (Module_request)
	checking:  bool,
}

@(private)
modules_of :: proc(p: ^Page) -> ^Module_State {
	s := scripts_of(p)
	if s.modules == nil { s.modules = new(Module_State) }
	return s.modules
}

@(private)
modules_free :: proc(p: ^Page, ms: ^Module_State) {
	for _, e in ms.entries {
		if e.task != base.NIL_HANDLE && p.worker != nil {
			module_worker_release(p, e.task)
		} else if e.task != base.NIL_HANDLE && !p.closed {
			fetch.cancel(p.loader, e.task)
		}
		delete(e.key); delete(e.source); delete(e.error)
		for d in e.deps { delete(d) }
		delete(e.deps)
		free(e)
	}
	delete(ms.entries)
	for g in ms.graphs { graph_free(g) }
	delete(ms.graphs)
	import_map_entries_free(&ms.imports)
	for &sc in ms.scopes { delete(sc.prefix); import_map_entries_free(&sc.imports) }
	delete(ms.scopes)
	free(ms)
}

@(private)
graph_free :: proc(g: ^Module_Graph) {
	delete(g.root)
	delete(g.error)
	free(g)
}

@(private)
import_map_entries_free :: proc(l: ^[dynamic]Import_Map_Entry) {
	for e in l { delete(e.key); delete(e.value) }
	delete(l^)
}

////////////////////////////////
// Fetching and compiling modules

// The entry of `key`, fetched if new. nil when the page has too many modules.
@(private)
module_fetch :: proc(p: ^Page, key: string, type: Api_ModuleType, cors: Cors_Setting) -> ^Module_Entry {
	ms := modules_of(p)
	if e, ok := ms.entries[key]; ok { return e }
	if len(ms.entries) >= p.settings.js_load.module_max_count {
		log(p, .Error, fmt.tprintf("module %s: this page has %d modules already (javascript.modules.max_count)", key, len(ms.entries)))
		return nil
	}
	e := new(Module_Entry)
	e.page = p
	e.key = strings.clone(key)
	e.type = type
	e.cors = cors
	e.state = .Fetching
	ms.entries[e.key] = e
	cred := cors == .Use_Credentials ? fetch.Credentials.Include : fetch.Credentials.Same_Origin
	if p.worker != nil {
		// a worker's requests run on the interface thread (worker.odin): a record of the realm, relayed
		h, f := base.pool_insert(&p.fetches, Fetch{page = p, instance = max(u32), module = e})
		f.self = h
		options := FETCH_OPTION_MODULE_SCRIPT | (type == .Json ? FETCH_OPTION_JSON_MODULE : 0) | (cors == .Use_Credentials ? 2 << 2 : 0)
		worker_fetch_start(p, f, e.key, "GET", "", nil, options)
		e.task = h
		return e
	}
	e.task = fetch.start(p.loader, {
		request = {url = e.key, mode = .Cors, credentials = cred, destination = .Script, initiator = &p.env,
			script = type == .Json ? .Json_Module : .Module},
		on_event = module_fetch_event, user = e, scope = p.scope, collect = true,
	})
	return e
}

@(private)
module_fetch_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	e := (^Module_Entry)(user)
	p := e.page
	#partial switch ev.kind {
	case .Response:
		r := ev.response
		if r.status < 200 || r.status >= 300 { delete(e.error); e.error = fmt.aprintf("HTTP %d", r.status) }
	case .Done:
		e.task = base.NIL_HANDLE
		module_arrived(p, e, ev.data, "")
	case .Failed:
		e.task = base.NIL_HANDLE
		module_arrived(p, e, nil, ev.detail)
	}
}

// A module's request finished: its source (or why it failed, `failure`), then the graphs waiting for it move on.
@(private)
module_arrived :: proc(p: ^Page, e: ^Module_Entry, source: []byte, failure: string) {
	if failure != "" { delete(e.error); e.error = strings.clone(failure) }
	if e.error != "" {
		e.state = .Failed
		log(p, .Error, fmt.tprintf("module %s: %s", e.key, e.error))
	} else {
		append(&e.source, ..source)
		e.state = .Fetched
		if !compile_module_offthread(p, e) { module_prepare(p, e) }
	}
	modules_check(p)
}

// Option bits of a worker's relayed request: a module script (destination script, a JavaScript MIME type required),
// and a JSON module.
FETCH_OPTION_MODULE_SCRIPT :: u32(1) << 15
FETCH_OPTION_JSON_MODULE :: u32(1) << 16

// A worker realm: the request of a module of its graph finished (worker.odin's worker_fetch_event).
module_worker_fetched :: proc(p: ^Page, f: ^Fetch) {
	e := f.module
	f.module = nil
	h := f.self
	e.task = base.NIL_HANDLE
	why := ""
	if f.state == 3 {
		why = f.error != "" ? strings.clone(f.error, context.temp_allocator) : "network error"
	} else if f.status < 200 || f.status >= 300 {
		why = fmt.tprintf("HTTP %d", f.status)
	}
	body := make([]byte, len(f.body), context.temp_allocator)
	copy(body, f.body[:])
	module_worker_release(p, h)
	module_arrived(p, e, body, why)
}

// Forgets a worker realm's module request (cancelled when still running).
@(private)
module_worker_release :: proc(p: ^Page, h: base.Handle) {
	f := base.pool_get(&p.fetches, h)
	if f == nil { return }
	fetch_abort(p, f)
	p.held -= len(f.body)
	removed, _ := base.pool_remove(&p.fetches, h)
	free_fetch(&removed)
}

// A module worker's script arrived (js_workers.odin): the root of the realm's graph, whose imports are fetched next;
// it runs once the graph is complete (worker_root_settled).
js_worker_module_start :: proc(p: ^Page, root_url: string, source: []byte) {
	ms := modules_of(p)
	e := new(Module_Entry)
	e.page = p
	e.key = strings.clone(root_url)
	e.cors = .Anonymous
	e.state = .Fetched
	append(&e.source, ..source)
	ms.entries[e.key] = e
	module_prepare(p, e)
	g := new(Module_Graph)
	g.root = strings.clone(root_url)
	g.worker_root = true
	append(&ms.graphs, g)
	modules_check(p)
}

// The module worker's graph is complete (it runs: a service worker's events may come after) or failed (an error
// event at the Worker object, the console says why).
@(private)
worker_root_settled :: proc(p: ^Page, g: ^Module_Graph) {
	defer graph_free(g)
	defer worker_release_held(p)
	if g.state == .Ready || g.rethrow {
		module_graph_run(p, g)
		if g.state == .Ready && p.worker != nil { sw_script_ran(p) }
		return
	}
	if p.worker != nil && !realm_halted(p) { worker_send_error(p.worker, g.error, code = 1) }
}

// Hands a fetched module to the engine: compiled (not run), its imports requested.
@(private)
module_prepare :: proc(p: ^Page, e: ^Module_Entry) {
	if e.state != .Fetched || e.compiling { return }
	r := js_realm(p)
	if r == nil { e.state = .Failed; return }
	ms := modules_of(p)
	g := Guest_Strings{inst = r.inst}
	defer guest_strings_free(&g)
	kp, kl, ok := guest_string(&g, e.key)
	if !ok { e.state = .Failed; return }
	saved := ms.preparing
	ms.preparing = e
	res := wasm.Call_Result.Ok
	status := i32(3)   // 3: not done yet (no bytecode in the cache, or it cannot be read)
	// a module compiled before is read from the bytecode cache, as a classic script is (js_run): the same source, URL and engine
	cacheable := p.worker == nil && e.type == .JavaScript && js.cacheable(len(e.source))
	key: js.Key
	if cacheable {
		key = js.key_of(js_version(), transmute(i32)js.Eval_Flags{.Module}, e.key, e.source[:])
		if code := js.lookup(key, context.temp_allocator); code != nil {
			if cp := js.guest_copy(r.inst, code, false); cp != 0 {
				argv := [4]u32{cp, u32(len(code)), kp, kl}
				res = js_call(p, r.inst, "wj_module_prepare_bytecode", argv[:])
				status = i32(argv[0])
				js.guest_free(r.inst, cp)
			}
		}
	}
	if res == .Ok && status == 3 {
		src := js.guest_copy(r.inst, e.source[:])
		if src == 0 { ms.preparing = saved; e.state = .Failed; return }
		defer js.guest_free(r.inst, src)
		kind := u32(e.type) | (cacheable ? 1 << 8 : 0)   // bit 8: the compiled module goes to the cache (Engine_storeBytecode)
		if cacheable { r.pending_key, r.has_pending_key = key, true }
		argv := [5]u32{src, u32(len(e.source)), kp, kl, kind}
		res = js_call(p, r.inst, "wj_module_prepare", argv[:])
		status = i32(argv[0])
		r.has_pending_key = false
	}
	ms.preparing = saved
	if p.closed { return }
	e.state = res == .Ok && status == 0 ? .Prepared : .Failed
	e.rethrow = res == .Ok && status == 2
	if e.state == .Failed && e.error == "" { e.error = strings.clone("it does not compile, or an import cannot be resolved") }
}

// The engine compiled a module that imports `specifier`.
Module_request :: proc(c: ^Call, module_url: string, specifier: string, type: Api_ModuleType) -> Api_Error {
	p := c.page
	ms := modules_of(p)
	e := ms.preparing
	if e == nil || e.key != module_url {
		e = ms.entries[module_url]
		if e == nil { return fail(c, .Not_Found, "no such module") }
	}
	resolved, msg, ok := module_resolve(p, specifier, module_url)
	if !ok { return fail(c, .Type, msg) }
	append(&e.deps, strings.clone(resolved))
	if module_fetch(p, resolved, type, e.cors) == nil { return fail(c, .Quota, "too many modules (javascript.modules.max_count)") }
	return .None
}

Module_source :: proc(c: ^Call, u: string) -> (string, Api_Error) {
	ms := c.page.scripts != nil ? c.page.scripts.modules : nil
	if ms == nil { return "", .Not_Found }
	e := ms.entries[u]
	if e == nil || (e.state != .Fetched && e.state != .Prepared) { return "", .Not_Found }
	return string(e.source[:]), .None
}

Module_resolve :: proc(c: ^Call, specifier: string, base_url: string) -> (string, Api_Error) {
	r, msg, ok := module_resolve(c.page, specifier, base_url)
	if !ok { return "", fail(c, .Type, msg) }
	return r, .None
}

////////////////////////////////
// Graphs

// The graph of a module script: `src` (external) or the inline `source`.
module_graph_for_script :: proc(p: ^Page, sc: ^Page_Script, src: string, source: []byte) -> ^Module_Graph {
	ms := modules_of(p)
	g := new(Module_Graph)
	g.script = sc
	cors := sc.cors == .No_Cors ? Cors_Setting.Anonymous : sc.cors
	if src != "" {
		g.root = strings.clone(src)
		if module_fetch(p, src, .JavaScript, cors) == nil { g.state = .Failed }
	} else {
		ms.inline_n += 1
		g.root = fmt.aprintf("%s#inline-module-%d", url_without_fragment(p.env.location.href), ms.inline_n)
		e := new(Module_Entry)
		e.page = p
		e.key = strings.clone(g.root)
		e.cors = cors
		e.state = .Fetched
		append(&e.source, ..source)
		ms.entries[e.key] = e
		module_prepare(p, e)
	}
	append(&ms.graphs, g)
	modules_check(p)
	return g
}

@(private)
url_without_fragment :: proc(href: string) -> string {
	if i := strings.index_byte(href, '#'); i >= 0 { return href[:i] }
	return href
}

// Starts a module's download before its script element is reached (the preload scanner).
module_preload :: proc(p: ^Page, u: string, cors: Cors_Setting) {
	module_fetch(p, u, .JavaScript, cors == .No_Cors ? .Anonymous : cors)
}

module_graph_settled :: proc(g: ^Module_Graph) -> bool { return g.state != .Pending }
module_graph_failed :: proc(g: ^Module_Graph) -> bool { return g.state == .Failed }

// Where a graph stands: every module reachable from its root compiled, or one failed.
@(private)
graph_state :: proc(ms: ^Module_State, root: string) -> (Module_Graph_State, string) {
	seen := make(map[string]bool, 16, context.temp_allocator)
	stack := make([dynamic]string, context.temp_allocator)
	append(&stack, root)
	pending := false
	for len(stack) > 0 {
		k := pop(&stack)
		if seen[k] { continue }
		seen[k] = true
		e := ms.entries[k]
		if e == nil { return .Failed, k }
		switch e.state {
		case .Failed: return .Failed, k
		case .Fetching, .Fetched: pending = true
		case .Prepared: for d in e.deps { append(&stack, d) }
		}
	}
	return pending ? .Pending : .Ready, ""
}

// Settles the graphs that are complete or failed: their scripts may run, their import() promises settle.
@(private)
modules_check :: proc(p: ^Page) {
	ms := modules_of(p)
	if ms.checking { return }
	ms.checking = true
	settled_script := false
	for i := 0; i < len(ms.graphs); {
		g := ms.graphs[i]
		if g.state == .Pending {
			st, which := graph_state(ms, g.root)
			if st == .Failed {
				e := ms.entries[which]
				delete(g.error)
				if e != nil && e.rethrow {
					g.rethrow = true
					g.error = strings.clone(which)
				} else {
					g.error = fmt.aprintf("Failed to fetch module %s%s%s", which, e != nil && e.error != "" ? ": " : "", e != nil ? e.error : "")
				}
			}
			g.state = st
		}
		if g.state == .Pending { i += 1; continue }
		if g.is_import {
			ordered_remove(&ms.graphs, i)
			import_settle(p, g)
			continue
		}
		if g.worker_root {
			ordered_remove(&ms.graphs, i)
			worker_root_settled(p, g)   // (a worker's realm is closed by its thread, never from a task)
			continue
		}
		if g.script != nil { settled_script = true }
		i += 1
	}
	ms.checking = false
	if settled_script { scripts_pump(p) }
}

// Runs a module script's graph (its script element's turn came).
module_graph_run :: proc(p: ^Page, g: ^Module_Graph) {
	if g == nil || (g.state != .Ready && !g.rethrow) { return }
	r := js_realm(p)
	if r == nil { return }
	gs := Guest_Strings{inst = r.inst}
	defer guest_strings_free(&gs)
	up, ul, ok := guest_string(&gs, g.rethrow ? g.error : g.root)
	if !ok { return }
	argv := [2]u32{up, ul}
	// a module of the graph does not compile: its error is reported, nothing runs
	js_call(p, r.inst, g.rethrow ? "wj_module_report" : "wj_module_run", argv[:])
	if !p.closed { js_after_task(p, r, g.root) }
}

////////////////////////////////
// import()

Module_import :: proc(c: ^Call, id: i32, specifier: string, base_url: string, type: Api_ModuleType) -> Api_Error {
	p := c.page
	// HTML "HostLoadImportedModule": a referrer that is no script with a URL (code given to eval by a tool, a
	// new Function, a name such as "<input>") resolves against the document's base URL
	b := base_url
	if _, abs := url.parse_absolute(b, context.temp_allocator); !abs { b = document_base_url(p) }
	resolved, msg, ok := module_resolve(p, specifier, b)
	if !ok { return fail(c, .Type, msg) }
	ms := modules_of(p)
	g := new(Module_Graph)
	g.root = strings.clone(resolved)
	g.is_import = true
	g.import_id = id
	if module_fetch(p, resolved, type, .Anonymous) == nil { g.state = .Failed; delete(g.error); g.error = strings.clone("too many modules") }
	append(&ms.graphs, g)
	// settled from a task of its own: the engine is in the middle of import()
	post_page_task(p, proc(pg: ^Page, data: rawptr) { if pg != nil && !pg.closed { modules_check(pg) } }, nil)
	return .None
}

@(private)
Import_Done :: struct { id: i32, outcome: u32, url, msg: string }

// Tells the engine about an import()'s graph, from a task of its own.
@(private)
import_settle :: proc(p: ^Page, g: ^Module_Graph) {
	t := new(Import_Done)
	t^ = Import_Done{id = g.import_id, outcome = g.state == .Ready ? 1 : (g.rethrow ? 2 : 0), url = strings.clone(g.root), msg = strings.clone(g.error)}
	graph_free(g)
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		t := (^Import_Done)(data)
		defer { delete(t.url); delete(t.msg); free(t) }
		if pg == nil || pg.closed { return }
		r := js_realm(pg)
		if r == nil { return }
		gs := Guest_Strings{inst = r.inst}
		defer guest_strings_free(&gs)
		up, ul, ok1 := guest_string(&gs, t.url)
		mp, ml, ok2 := guest_string(&gs, t.msg)
		if !ok1 || !ok2 { return }
		argv := [6]u32{u32(t.id), up, ul, t.outcome, mp, ml}
		js_call(pg, r.inst, "wj_module_import_done", argv[:])
	}, t)
}

////////////////////////////////
// Resolution and import maps

// HTML "resolve a module specifier": import maps (scopes, then the top-level imports), then a URL-like specifier
// parsed against `base_url`. On failure the message of the TypeError.
module_resolve :: proc(p: ^Page, specifier: string, base_url: string) -> (resolved: string, message: string, ok: bool) {
	ms := modules_of(p)
	if base_url == "" {
		// the root of a graph: its name already
		if _, known := ms.entries[specifier]; known { return specifier, "", true }
		u, okabs := url.parse_absolute(specifier, context.temp_allocator)
		if !okabs { return "", fmt.tprintf("Failed to resolve module %q", specifier), false }
		return u.href, "", true
	}
	b, okb := url.parse_absolute(base_url, context.temp_allocator)
	if !okb { return "", fmt.tprintf("Failed to resolve module specifier %q: invalid base %q", specifier, base_url), false }
	as_url, has_url := url_like(specifier, &b)
	normalized := has_url ? as_url.href : specifier
	if p.settings.js_load.import_maps {
		for &sc in ms.scopes {
			if sc.prefix == b.href || (strings.has_suffix(sc.prefix, "/") && strings.has_prefix(b.href, sc.prefix)) {
				if r, m, found, good := imports_match(sc.imports[:], normalized, as_url, has_url); found {
					return r, m, good
				}
			}
		}
		if r, m, found, good := imports_match(ms.imports[:], normalized, as_url, has_url); found { return r, m, good }
	}
	if has_url { return as_url.href, "", true }
	return "", fmt.tprintf("Failed to resolve module specifier %q. Relative references must start with either \"/\", \"./\", or \"../\".", specifier), false
}

// HTML "resolve a URL-like module specifier".
@(private)
url_like :: proc(spec: string, base_url: ^url.URL) -> (url.URL, bool) {
	if strings.has_prefix(spec, "/") || strings.has_prefix(spec, "./") || strings.has_prefix(spec, "../") {
		return url.parse(spec, base_url, context.temp_allocator)
	}
	return url.parse_absolute(spec, context.temp_allocator)
}

// HTML "resolve an imports match". found = an entry decided (ok false: the specifier is blocked or the result invalid).
@(private)
imports_match :: proc(entries: []Import_Map_Entry, normalized: string, as_url: url.URL, has_url: bool) -> (resolved, message: string, found, ok: bool) {
	for e in entries {
		if e.key == normalized {
			if e.null { return "", fmt.tprintf("Failed to resolve module specifier %q: blocked by a null entry of the import map", normalized), true, false }
			return e.value, "", true, true
		}
		if strings.has_suffix(e.key, "/") && strings.has_prefix(normalized, e.key) && (!has_url || as_url.special) {
			if e.null { return "", fmt.tprintf("Failed to resolve module specifier %q: blocked by a null entry of the import map", normalized), true, false }
			after := normalized[len(e.key):]
			v, okv := url.parse_absolute(e.value, context.temp_allocator)
			if !okv { return "", "invalid import map address", true, false }
			r, okr := url.parse(after, &v, context.temp_allocator)
			if !okr || !strings.has_prefix(r.href, e.value) {
				return "", fmt.tprintf("Failed to resolve module specifier %q: it backtracks above its prefix %q", normalized, e.key), true, false
			}
			return r.href, "", true, true
		}
	}
	return "", "", false, false
}

// Registers an import map (<script type=importmap>): merged with the page's (entries already there win).
import_map_register :: proc(p: ^Page, text: string, base_url: string) {
	if !p.settings.js_load.import_maps { return }
	ms := modules_of(p)
	b, okb := url.parse_absolute(base_url, context.temp_allocator)
	if !okb { return }
	v, err := json.parse_string(text, allocator = context.temp_allocator)
	if err != nil {
		log(p, .Error, fmt.tprintf("import map: invalid JSON (%v)", err))
		return
	}
	root, is_obj := v.(json.Object)
	if !is_obj { log(p, .Error, "import map: the top level must be a JSON object"); return }
	if imp, has := root["imports"]; has {
		if obj, ok := imp.(json.Object); ok { specifier_map_merge(p, &ms.imports, obj, &b) } else { log(p, .Error, "import map: \"imports\" must be an object") }
	}
	if scopes, has := root["scopes"]; has {
		obj, ok := scopes.(json.Object)
		if !ok { log(p, .Error, "import map: \"scopes\" must be an object"); return }
		for prefix, m in obj {
			pu, okp := url.parse(prefix, &b, context.temp_allocator)
			mo, okm := m.(json.Object)
			if !okp || !okm { log(p, .Warn, fmt.tprintf("import map: scope %q ignored", prefix)); continue }
			idx := -1
			for sc, i in ms.scopes { if sc.prefix == pu.href { idx = i; break } }
			if idx < 0 {
				append(&ms.scopes, Import_Map_Scope{prefix = strings.clone(pu.href)})
				idx = len(ms.scopes) - 1
			}
			specifier_map_merge(p, &ms.scopes[idx].imports, mo, &b)
		}
		slice.sort_by(ms.scopes[:], proc(a, b: Import_Map_Scope) -> bool { return a.prefix > b.prefix })
	}
	modules_check(p)
}

// HTML "sort and normalize a specifier map", merged into `into` (keys already there keep their value).
@(private)
specifier_map_merge :: proc(p: ^Page, into: ^[dynamic]Import_Map_Entry, obj: json.Object, base_url: ^url.URL) {
	for key, value in obj {
		if key == "" { continue }
		k := key
		if ku, ok := url_like(key, base_url); ok { k = ku.href }
		exists := false
		for e in into { if e.key == k { exists = true; break } }
		if exists { continue }
		entry := Import_Map_Entry{key = strings.clone(k)}
		s, is_str := value.(json.String)
		au: url.URL
		okau := false
		if is_str { au, okau = url_like(s, base_url) }
		if !okau || (strings.has_suffix(key, "/") && !strings.has_suffix(au.href, "/")) {
			log(p, .Warn, fmt.tprintf("import map: the address of %q is invalid: it is blocked", key))
			entry.null = true
		} else {
			entry.value = strings.clone(au.href)
		}
		append(into, entry)
	}
	// longest keys first ("descending order of code units": a longer prefix is tried before a shorter one)
	slice.sort_by(into[:], proc(a, b: Import_Map_Entry) -> bool { return a.key > b.key })
}
