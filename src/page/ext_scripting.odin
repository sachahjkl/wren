package page

// scripting (api/ext_scripting.widl; docs/extensions.md, section 3.6): executeScript, insertCSS, removeCSS and the
// registered content scripts.
//
// One record (Ext_Exec) per call that acts on documents, in the router (Ext_Router.execs). Its states:
//   Reading -- the package files it needs are read on the blocking pool (never on the loop thread) --> Ready
//   Ready   -- a task of the loop of its own (never inside the caller's call: the caller may be one of the targets)
//              runs it in each document still there --> Waiting, or Done
//   Waiting -- each isolated world answers its function's value (Ext_respond, through the hidden hook of ext_api.js),
//              or its context goes --> Done
//   Done    -- the call is answered with every document's result; the record goes
// A record whose extension reloaded or went fails its call.
//
// Results: a function's value (a promise's, once settled) in an isolated world, as JSON; null for files and for the
// MAIN world (the page's realm has no way back to the browser that the page could not forge).

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "wb:base"
import "wb:extensions"
import "wb:host"

Ext_Exec_Kind :: enum u8 { Script, Insert_Css, Remove_Css, Register }

Ext_Exec_Doc :: struct {
	page:     u64,
	document: string,   // owned: its documentId when the call was made (a document that replaced it is not the target)
	frame:    i64,
	ctx:      u64,      // the world's context whose answer is awaited (0: none)
	result:   string,   // owned JSON
	done:     bool,
}

Ext_Exec :: struct {
	id:      u64,
	kind:    Ext_Exec_Kind,
	ext:     string,              // owned
	image:   ^extensions.Image,   // retained: the package the call named its files in
	to:      Ext_Target,
	docs:    [dynamic]Ext_Exec_Doc,
	files:   [dynamic]string,     // owned: package paths, normalised
	func:    string,              // owned: a function's source ("" : files)
	args:    string,              // owned: its arguments, a JSON list
	css:     string,              // owned: insertCSS / removeCSS text ("" : files)
	world:   extensions.World,
	author:  bool,
	running: bool,                // its documents are being run now: an answer does not end it yet
}

@(private = "file")
ext_exec_free :: proc(ex: ^Ext_Exec) {
	for d in ex.docs { delete(d.document); delete(d.result) }
	delete(ex.docs)
	for f in ex.files { delete(f) }
	delete(ex.files)
	delete(ex.ext); delete(ex.func); delete(ex.args); delete(ex.css)
	extensions.image_release(ex.image)
	free(ex)
}

// The router ends: the records go (their callers are gone with it).
ext_execs_destroy :: proc() {
	r := ext_router()
	for _, ex in r.execs { ext_exec_free(ex) }
	delete(r.execs)
	r.execs = nil
}

@(private = "file")
ext_exec_new :: proc(x: ^Ext_Call, kind: Ext_Exec_Kind) -> ^Ext_Exec {
	r := ext_router()
	ex := new(Ext_Exec)
	ex.id = ext_next_id()
	ex.kind = kind
	ex.ext = strings.clone(x.e.id)
	ex.image = extensions.image_retain(x.e.image)
	ex.to = x.to
	if r.execs == nil { r.execs = make(map[u64]^Ext_Exec) }
	r.execs[ex.id] = ex
	x.answered = true   // (the record answers)
	return ex
}

// Ends a record: its call gets `text` ("" : every document's result for a script; undefined otherwise).
@(private = "file")
ext_exec_end :: proc(ex: ^Ext_Exec, text: string) {
	r := ext_router()
	delete_key(&r.execs, ex.id)
	answer := text
	if answer == "" && ex.kind == .Script {
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		for d, i in ex.docs {
			if i > 0 { strings.write_byte(&b, ',') }
			fmt.sbprintf(&b, `{{"documentId":%s,"frameId":%d,"result":%s}}`, extensions.json_quote(d.document), d.frame, d.result != "" ? d.result : "null")
		}
		strings.write_byte(&b, ']')
		answer = strings.to_string(b)
	}
	ext_answer(ex.to, answer)
	ext_exec_free(ex)
}

// Ends the record when every document answered (and it is not running them now).
@(private = "file")
ext_exec_check :: proc(ex: ^Ext_Exec) {
	if ex.running { return }
	for d in ex.docs { if !d.done { return } }
	ext_exec_end(ex, "")
}

@(private = "file")
ext_exec_doc_done :: proc(ex: ^Ext_Exec, i: int, result: string) {
	d := &ex.docs[i]
	if d.done { return }
	d.done = true
	d.ctx = 0
	delete(d.result)
	d.result = strings.clone(result)
	ext_exec_check(ex)
}

// A world answered (Ext_respond): true when `reply` is a record's, which takes the answer of that world's context only.
ext_exec_respond :: proc(context_id: u64, reply: u64, value: string) -> bool {
	ex, ok := ext_router().execs[reply]
	if !ok { return false }
	for d, i in ex.docs {
		if d.ctx != 0 && d.ctx == context_id {
			// (a value too large or not JSON is null: the call's answer is JSON)
			v := value
			if len(v) > ext_registry().settings.message_max_bytes { v = "null" }
			if _, err := json.parse_string(v, .JSON, false, context.temp_allocator); err != .None { v = "null" }
			ext_exec_doc_done(ex, i, v)
			break
		}
	}
	return true
}

// A context went (ext_context_detach): the documents waiting for it answer null.
ext_exec_context_gone :: proc(context_id: u64) {
	r := ext_router()
	if len(r.execs) == 0 { return }
	ids := make([dynamic]u64, 0, 4, context.temp_allocator)
	for id, ex in r.execs { for d in ex.docs { if d.ctx == context_id { append(&ids, id); break } } }
	for id in ids {
		ex, ok := r.execs[id]
		if !ok { continue }
		for i := 0; i < len(ex.docs); i += 1 {
			if ex.docs[i].ctx != context_id { continue }
			ext_exec_doc_done(ex, i, "null")
			if id not_in r.execs { break }   // (it ended: the record is gone)
		}
	}
}

////////////////////////////////
// Targets

// The documents an InjectionTarget names, each one the extension may act on (temp). An error: no such tab or frame,
// or a document named on its own that the extension has no grant for (Chrome's message).
@(private = "file")
ext_injection_documents :: proc(x: ^Ext_Call, t: Ext_Scripting_Injection_Target) -> (out: []^Page, err: string) {
	top := ext_tab_top_page(t.tab_id)   // ext_webnavigation.odin
	if top == nil { return nil, fmt.tprintf("No tab with id: %d.", t.tab_id) }
	all := ext_tab_documents(top)
	list := make([dynamic]^Page, 0, len(all), context.temp_allocator)
	no_access :: "Cannot access contents of the page. Extension manifest must request permission to access the respective host."
	frames, has_frames := t.frame_ids.?
	docs, has_docs := t.document_ids.?
	all_frames := t.all_frames.? or_else false
	switch {
	case has_frames && has_docs:
		return nil, "Cannot specify both 'frameIds' and 'documentIds'."
	case has_frames:
		if all_frames { return nil, "Cannot specify both 'allFrames' and 'frameIds'." }
		for id in frames {
			found: ^Page
			for q in all { if ext_frame_id(q) == id { found = q; break } }
			if found == nil { return nil, fmt.tprintf("No frame with id %d in tab with id %d", id, t.tab_id) }
			if !ext_doc_allowed(x.reg, x.e, found) { return nil, no_access }
			append(&list, found)
		}
	case has_docs:
		if all_frames { return nil, "Cannot specify both 'allFrames' and 'documentIds'." }
		for id in docs {
			found: ^Page
			for q in all { if q.ext_doc != nil && q.ext_doc.document_id == id { found = q; break } }
			if found == nil { return nil, fmt.tprintf("No document with id %s in tab with id %d", id, t.tab_id) }
			if !ext_doc_allowed(x.reg, x.e, found) { return nil, no_access }
			append(&list, found)
		}
	case all_frames:
		if !ext_doc_allowed(x.reg, x.e, top) { return nil, no_access }
		for q in all { if ext_doc_allowed(x.reg, x.e, q) { append(&list, q) } }
	case:
		if !ext_doc_allowed(x.reg, x.e, top) { return nil, no_access }
		append(&list, top)
	}
	return list[:], ""
}

@(private = "file")
ext_exec_add_docs :: proc(ex: ^Ext_Exec, docs: []^Page) {
	for q in docs {
		append(&ex.docs, Ext_Exec_Doc{page = page_id(q), document = strings.clone(ext_document_id(q)), frame = ext_frame_id(q)})
	}
}

// The package paths of `files`, normalised (an error: one that is not a file of the extension).
@(private = "file")
ext_exec_files :: proc(ex: ^Ext_Exec, e: ^extensions.Extension, files: []string) -> string {
	for f in files {
		n, ok := extensions.package_path_normalize(strings.trim_prefix(f, "/"), context.temp_allocator)
		if !ok || !extensions.image_has_file(e.image, n) { return fmt.tprintf("Could not load file: '%s'.", f) }
		append(&ex.files, strings.clone(n))
	}
	return ""
}

////////////////////////////////
// Reading the files, then running

@(private = "file")
Ext_Read_Job :: struct {
	exec:  u64,
	image: ^extensions.Image,   // retained
	rels:  []string,            // process allocator
	texts: [][]byte,            // process allocator (nil: not read)
	max:   int,
}

// Reads the files of `ex` the extension has no text of yet, on the blocking pool; then runs it from a task of its own.
@(private = "file")
ext_exec_start :: proc(ex: ^Ext_Exec) {
	reg := ext_registry()
	e := extensions.registry_find(reg, ex.ext)
	missing := make([dynamic]string, 0, 4, context.temp_allocator)
	if e != nil { for f in ex.files { if extensions.extension_source(e, f) == nil { append(&missing, f) } } }
	if len(missing) == 0 {
		loop := ext_loop()
		if loop == nil { ext_exec_end(ex, "!the browser cannot do this now"); return }
		host.post(loop, ext_exec_task, rawptr(uintptr(ex.id)))
		return
	}
	ld := the_pages.sw_registry.loader
	if ld == nil || ld.blocking == nil { ext_exec_end(ex, "!the extension's files cannot be read now"); return }
	pa := base.process_allocator()
	j := new(Ext_Read_Job, pa)
	j.exec = ex.id
	j.image = extensions.image_retain(ex.image)
	j.rels = make([]string, len(missing), pa)
	for m, i in missing { j.rels[i] = strings.clone(m, pa) }
	j.texts = make([][]byte, len(missing), pa)
	j.max = int(reg.settings.package_max_bytes)
	host.run_blocking(ld.blocking, ext_read_work, ext_read_done, j, ext_read_discard)
}

@(private = "file")
ext_read_work :: proc(data: rawptr) {
	j := (^Ext_Read_Job)(data)
	pa := base.process_allocator()
	context.allocator = pa
	for rel, i in j.rels {
		entry, found := j.image.files[rel]
		if !found || entry.size > i64(j.max) { continue }
		bytes, err := os.read_entire_file(strings.concatenate({j.image.root, "/", rel}, context.temp_allocator), pa)
		if err != nil { continue }
		j.texts[i] = bytes
	}
}

@(private = "file")
ext_read_discard :: proc(data: rawptr) {
	j := (^Ext_Read_Job)(data)
	pa := base.process_allocator()
	for t in j.texts { delete(t, pa) }
	for r in j.rels { delete(r, pa) }
	delete(j.texts, pa); delete(j.rels, pa)
	extensions.image_release(j.image)
	free(j, pa)
}

@(private = "file")
ext_read_done :: proc(data: rawptr) {
	j := (^Ext_Read_Job)(data)
	defer ext_read_discard(data)
	ex, ok := ext_router().execs[j.exec]
	if !ok { return }
	e := extensions.registry_find(ext_registry(), ex.ext)
	if e == nil || e.image != ex.image { ext_exec_end(ex, "!the extension was reloaded"); return }
	for rel, i in j.rels {
		if j.texts[i] == nil { ext_exec_end(ex, fmt.tprintf("!Could not load file: '%s'.", rel)); return }
		extensions.extension_source_put(e, rel, j.texts[i])
		j.texts[i] = nil   // (moved)
	}
	ext_exec_task(rawptr(uintptr(ex.id)))
}

// Runs a record in each of its documents (a task of the loop of its own).
@(private = "file")
ext_exec_task :: proc(data: rawptr) {
	id := u64(uintptr(data))
	r := ext_router()
	ex, ok := r.execs[id]
	if !ok { return }
	reg := ext_registry()
	e := extensions.registry_running(reg, extensions.SCHEME_CHROME, ex.ext)
	if e == nil || e.image != ex.image { ext_exec_end(ex, "!the extension was reloaded"); return }
	if ex.kind == .Register { ext_exec_end(ex, ""); return }   // (its files are read: the registration answers)
	ex.running = true
	for i := 0; i < len(ex.docs); i += 1 {
		d := &ex.docs[i]
		if d.done { continue }
		p := page_by_id(d.page)
		if p == nil || p.ext_doc == nil || p.ext_doc.document_id != d.document || !ext_doc_allowed(reg, e, p) {
			ext_exec_doc_done(ex, i, "null")
			continue
		}
		ext_exec_in(ex, i, e, p)
		// (what ran may have closed pages, stopped the extension or reloaded it)
		if extensions.registry_running(reg, extensions.SCHEME_CHROME, ex.ext) != e { break }
	}
	ex.running = false
	if extensions.registry_running(reg, extensions.SCHEME_CHROME, ex.ext) != e { ext_exec_end(ex, "!the extension was reloaded"); return }
	ext_exec_check(ex)
}

// One document of a record.
@(private = "file")
ext_exec_in :: proc(ex: ^Ext_Exec, i: int, e: ^extensions.Extension, p: ^Page) {
	switch ex.kind {
	case .Insert_Css, .Remove_Css:
		texts := make([dynamic]string, 0, 2, context.temp_allocator)
		keys := make([dynamic]string, 0, 2, context.temp_allocator)
		if len(ex.files) == 0 {
			append(&texts, ex.css)
			append(&keys, ext_css_key(ex.css, ""))
		}
		for f in ex.files {
			append(&texts, string(extensions.extension_source(e, f)))
			append(&keys, ext_css_key("", f))
		}
		for k, n in keys {
			if ex.kind == .Insert_Css { ext_css_add(p, ex.ext, k, texts[n], ex.author) } else { ext_css_remove(p, ex.ext, k) }
		}
		ext_exec_doc_done(ex, i, "null")
	case .Script:
		if ex.func == "" {
			for f in ex.files {
				src := extensions.extension_source(e, f)
				if src == nil || p.closed { break }
				ext_run_script(p, e, src, extensions.image_url(e.image, f), ex.world)
			}
			ext_exec_doc_done(ex, i, "null")
			return
		}
		script_url := extensions.image_url(e.image, "_generated_execute_script.js")
		if ex.world == .Main {
			src := fmt.tprintf("(%s).apply(null, %s);", ex.func, ex.args)
			ext_run_script(p, e, transmute([]byte)src, script_url, .Main)
			ext_exec_doc_done(ex, i, "null")
			return
		}
		w := world_open(p, e)
		if w == nil || w.x == nil { ext_exec_doc_done(ex, i, "null"); return }
		ex.docs[i].ctx = w.x.ctx_id
		// the value comes back through the world's hidden hook (ext_api.js), as the answer to this record's id
		src := fmt.tprintf(`(function(){{var d=globalThis[Symbol.for("wren.extensions.done")];try{{var v=(%s).apply(null,%s);Promise.resolve(v).then(function(r){{d(%d,r,false)}},function(x){{d(%d,x,true)}})}}catch(x){{d(%d,x,true)}}}})();`,
			ex.func, ex.args, ex.id, ex.id, ex.id)
		if !world_run(p, w, transmute([]byte)src, script_url) {
			// (a syntax error in the function: nothing will answer)
			if i < len(ex.docs) && !ex.docs[i].done { ext_exec_doc_done(ex, i, "null") }
		}
	case .Register:
	}
}

////////////////////////////////
// The methods

ext_scripting_execute_script :: proc(x: ^Ext_Call, a: Ext_Scripting_Execute_Script_Args) {
	inj := a.injection
	files, has_files := inj.files.?
	fn, has_func := inj.func.?
	if has_files == has_func { ext_fail(x, "Exactly one of 'func' and 'files' must be specified"); return }
	if has_files && len(files) == 0 { ext_fail(x, "At least one file must be specified."); return }
	if _, has_args := inj.args.?; has_args && !has_func { ext_fail(x, "'args' may only be used with 'func'."); return }
	docs, err := ext_injection_documents(x, inj.target)
	if err != "" { ext_fail(x, err); return }
	args := "[]"
	if list, has := inj.args.?; has {
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		for v, i in list { if i > 0 { strings.write_byte(&b, ',') }; strings.write_string(&b, extensions.json_text(v)) }
		strings.write_byte(&b, ']')
		args = strings.to_string(b)
	}
	world := inj.world.? or_else "ISOLATED"
	ex := ext_exec_new(x, .Script)
	if e := ext_exec_files(ex, x.e, files); e != "" { ext_exec_end(ex, strings.concatenate({"!", e}, context.temp_allocator)); return }
	ex.func = strings.clone(fn)
	ex.args = strings.clone(args)
	ex.world = world == "MAIN" ? extensions.World.Main : extensions.World.Isolated
	ext_exec_add_docs(ex, docs)
	ext_exec_start(ex)
}

// insertCSS and removeCSS (x.method says which).
ext_scripting_css :: proc(x: ^Ext_Call, a: Ext_Scripting_Css_Args) {
	inj := a.injection
	files, has_files := inj.files.?
	text, has_css := inj.css.?
	if has_files == has_css { ext_fail(x, "Exactly one of 'css' and 'files' must be specified."); return }
	docs, err := ext_injection_documents(x, inj.target)
	if err != "" { ext_fail(x, err); return }
	ex := ext_exec_new(x, strings.has_suffix(x.method, "removeCSS") ? Ext_Exec_Kind.Remove_Css : Ext_Exec_Kind.Insert_Css)
	if e := ext_exec_files(ex, x.e, files); e != "" { ext_exec_end(ex, strings.concatenate({"!", e}, context.temp_allocator)); return }
	ex.css = strings.clone(text)
	ex.author = (inj.origin.? or_else "AUTHOR") == "AUTHOR"
	ext_exec_add_docs(ex, docs)
	ext_exec_start(ex)
}

////////////////////////////////
// Registered content scripts

// The registered scripts as specs (temp; strings are the registry's: use them before it changes).
@(private = "file")
ext_registered_specs :: proc(e: ^extensions.Extension) -> [dynamic]extensions.Registered_Spec {
	r := &e.registered
	out := make([dynamic]extensions.Registered_Spec, 0, len(r.list), context.temp_allocator)
	for cs, i in r.list {
		s := extensions.Registered_Spec{id = r.ids[i], js = cs.js, css = cs.css, run_at = cs.run_at, all_frames = cs.all_frames,
			match_origin_as_fallback = cs.match_origin_as_fallback, world = cs.world, persist = r.persist[i]}
		m := make([]string, len(cs.matches), context.temp_allocator)
		for p, k in cs.matches { m[k] = p.source }
		x := make([]string, len(cs.exclude_matches), context.temp_allocator)
		for p, k in cs.exclude_matches { x[k] = p.source }
		s.matches, s.exclude_matches = m, x
		append(&out, s)
	}
	return out
}

// One entry of a call, checked and applied on `into` (an update keeps what it does not give). "" : fine.
@(private = "file")
ext_registered_apply :: proc(x: ^Ext_Call, c: Ext_Scripting_Registered_Content_Script, into: ^extensions.Registered_Spec, update: bool) -> string {
	if c.id == "" { return "Content script's ID must not be empty." }
	if strings.has_prefix(c.id, "_") { return fmt.tprintf("Content script's ID '%s' must not start with '_'.", c.id) }
	into.id = c.id
	if v, ok := c.matches.?; ok {
		for s in v { if _, pok := extensions.pattern_parse(s); !pok { return fmt.tprintf("Script with ID '%s' has invalid match pattern '%s'.", c.id, s) } }
		into.matches = v
	}
	if v, ok := c.exclude_matches.?; ok {
		for s in v { if _, pok := extensions.pattern_parse(s); !pok { return fmt.tprintf("Script with ID '%s' has invalid match pattern '%s'.", c.id, s) } }
		into.exclude_matches = v
	}
	check_files :: proc(x: ^Ext_Call, list: []string) -> ([]string, string) {
		out := make([]string, len(list), context.temp_allocator)
		for f, i in list {
			n, ok := extensions.package_path_normalize(strings.trim_prefix(f, "/"), context.temp_allocator)
			if !ok || !extensions.image_has_file(x.e.image, n) { return nil, fmt.tprintf("Could not load file: '%s'.", f) }
			out[i] = n
		}
		return out, ""
	}
	if v, ok := c.js.?; ok { out, e := check_files(x, v); if e != "" { return e }; into.js = out }
	if v, ok := c.css.?; ok { out, e := check_files(x, v); if e != "" { return e }; into.css = out }
	if v, ok := c.all_frames.?; ok { into.all_frames = v }
	if v, ok := c.match_origin_as_fallback.?; ok { into.match_origin_as_fallback = v }
	if v, ok := c.run_at.?; ok {
		switch v {
		case "document_start": into.run_at = .Document_Start
		case "document_end":   into.run_at = .Document_End
		case:                  into.run_at = .Document_Idle
		}
	} else if !update {
		into.run_at = .Document_Idle
	}
	if v, ok := c.world.?; ok { into.world = v == "MAIN" ? extensions.World.Main : extensions.World.Isolated }
	if v, ok := c.persist_across_sessions.?; ok { into.persist = v } else if !update { into.persist = true }
	if len(into.matches) == 0 { return fmt.tprintf("Script with ID '%s' must specify at least one match.", c.id) }
	if len(into.js) == 0 && len(into.css) == 0 { return fmt.tprintf("Script with ID '%s' must specify at least one js or css file.", c.id) }
	return ""
}

// Sets the registered scripts to `specs`, then answers once their files are read.
@(private = "file")
ext_registered_commit :: proc(x: ^Ext_Call, specs: []extensions.Registered_Spec) {
	if x.reg.settings.scripting_max_registered > 0 && len(specs) > x.reg.settings.scripting_max_registered {
		ext_fail(x, "too many registered content scripts (extensions.scripting.max_registered)")
		return
	}
	if !extensions.registered_set(&x.e.registered, specs) { ext_fail(x, "out of memory"); return }
	ex := ext_exec_new(x, .Register)
	for s in specs {
		for f in s.js { append(&ex.files, strings.clone(f)) }
		for f in s.css { append(&ex.files, strings.clone(f)) }
	}
	ext_exec_start(ex)
}

ext_scripting_register_content_scripts :: proc(x: ^Ext_Call, a: Ext_Scripting_Register_Content_Scripts_Args) {
	specs := ext_registered_specs(x.e)
	for c in a.scripts {
		for s in specs { if s.id == c.id { ext_fail(x, fmt.tprintf("Duplicate script ID '%s'", c.id)); return } }
		s: extensions.Registered_Spec
		if e := ext_registered_apply(x, c, &s, false); e != "" { ext_fail(x, e); return }
		append(&specs, s)
	}
	ext_registered_commit(x, specs[:])
}

ext_scripting_update_content_scripts :: proc(x: ^Ext_Call, a: Ext_Scripting_Update_Content_Scripts_Args) {
	specs := ext_registered_specs(x.e)
	for c in a.scripts {
		at := -1
		for s, i in specs { if s.id == c.id { at = i; break } }
		if at < 0 { ext_fail(x, fmt.tprintf("Content script with ID '%s' does not exist or is not fully registered", c.id)); return }
		if e := ext_registered_apply(x, c, &specs[at], true); e != "" { ext_fail(x, e); return }
	}
	ext_registered_commit(x, specs[:])
}

@(private = "file")
ext_filter_has :: proc(f: Maybe(Ext_Scripting_Content_Script_Filter), id: string) -> bool {
	fv, ok := f.?
	if !ok { return true }
	ids, has := fv.ids.?
	if !has { return true }
	for x in ids { if x == id { return true } }
	return false
}

ext_scripting_get_registered_content_scripts :: proc(x: ^Ext_Call, a: Ext_Scripting_Get_Registered_Content_Scripts_Args) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	first := true
	list :: proc(b: ^strings.Builder, key: string, items: []string) {
		fmt.sbprintf(b, `,"%s":[`, key)
		for s, i in items { if i > 0 { strings.write_byte(b, ',') }; strings.write_string(b, extensions.json_quote(s)) }
		strings.write_byte(b, ']')
	}
	for s in ext_registered_specs(x.e) {
		if !ext_filter_has(a.filter, s.id) { continue }
		if !first { strings.write_byte(&b, ',') }
		first = false
		run_at := s.run_at == .Document_Start ? "document_start" : (s.run_at == .Document_End ? "document_end" : "document_idle")
		fmt.sbprintf(&b, `{{"id":%s,"allFrames":%s,"matchOriginAsFallback":%s,"runAt":"%s","world":"%s","persistAcrossSessions":%s`,
			extensions.json_quote(s.id), jbool_text(s.all_frames), jbool_text(s.match_origin_as_fallback), run_at, s.world == .Main ? "MAIN" : "ISOLATED", jbool_text(s.persist))
		list(&b, "matches", s.matches)
		if len(s.exclude_matches) > 0 { list(&b, "excludeMatches", s.exclude_matches) }
		if len(s.js) > 0 { list(&b, "js", s.js) }
		if len(s.css) > 0 { list(&b, "css", s.css) }
		strings.write_byte(&b, '}')
	}
	strings.write_byte(&b, ']')
	ext_ok(x, strings.to_string(b))
}

ext_scripting_unregister_content_scripts :: proc(x: ^Ext_Call, a: Ext_Scripting_Unregister_Content_Scripts_Args) {
	specs := ext_registered_specs(x.e)
	// every id named must exist (Chrome's rule)
	if f, ok := a.filter.?; ok {
		if ids, has := f.ids.?; has {
			for id in ids {
				found := false
				for s in specs { if s.id == id { found = true; break } }
				if !found { ext_fail(x, fmt.tprintf("Nonexistent script ID '%s'", id)); return }
			}
		}
	}
	keep := make([dynamic]extensions.Registered_Spec, 0, len(specs), context.temp_allocator)
	for s in specs { if !ext_filter_has(a.filter, s.id) { append(&keep, s) } }
	if !extensions.registered_set(&x.e.registered, keep[:]) { ext_fail(x, "out of memory"); return }
	ext_ok(x, "")
}
