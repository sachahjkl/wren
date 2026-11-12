package page

// Content scripts and their style sheets (docs/extensions.md, section 3.6 "Injection"). A document goes through three
// points, each once, in order; a later point runs the earlier ones it missed:
//   Start -- the parsed document was adopted (offthread.odin), or it was parsed without one --> its CSS, then the
//            scripts with run_at document_start: the document element exists, no script of the page ran yet
//   End   -- the parser finished (parser_finish, js_load.odin) --> run_at document_end
//   Idle  -- the load event (ext_page_loaded), or extensions.content_scripts.idle_ms after End --> run_at document_idle
// At each point every running extension with a host grant for the document gets the entries of its manifest and of
// scripting.registerContentScripts that match it (src/extensions/content_scripts.odin: by host, built once). The
// scripts of an entry run in order, as classic scripts with the bytecode cache, in the extension's isolated world
// (ext_worlds.odin) or, for world MAIN, in the page's realm. A document whose site has JavaScript switched off still
// gets them: the switch is about the page's scripts (MAIN scripts excepted: they are the page's).
//
// What an extension's CSS adds is an injected sheet of the style engine: it survives the adoption of the parsed tree,
// and the page's scripts do not see it in document.styleSheets (which lists the sheets of elements).
//
// No injection in: Wren's own pages (about:), extension pages, view-source:, file: (no switch for it yet), hosts of
// extensions.restricted_hosts (extension_host_allowed), and documents without a URL of their own whose creator is one
// of those.

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:extensions"
import "wb:host"
import "wb:style"
import "wb:wasm"

Ext_Point :: enum u8 { None, Start, End, Idle }

// One sheet an extension put in the document (content_scripts css, scripting.insertCSS).
Ext_Sheet :: struct {
	ext:   string,         // owned
	key:   string,         // owned: what removeCSS names it by (ext_css_key)
	sheet: ^style.Sheet,
}

Ext_Doc :: struct {
	document_id:   string,        // owned: the documentId extensions see (random, per document)
	reached:       Ext_Point,     // the last point the document went through
	idle_timer:    base.Handle,
	message_owner: u32,           // ext_worlds.odin: the realm (instance index + 1) firing a message event now; 0: none
	sheets:        [dynamic]Ext_Sheet,
}

// The record of `p`, made on first need; it goes with the page.
ext_doc_of :: proc(p: ^Page) -> ^Ext_Doc {
	if p.ext_doc != nil { return p.ext_doc }
	d := new(Ext_Doc)
	bytes: [16]u8
	wasm.random_bytes(bytes[:])
	b := strings.builder_make()
	for x in bytes { fmt.sbprintf(&b, "%02X", x) }
	d.document_id = strings.to_string(b)
	p.ext_doc = d
	base.on_close(p.scope, proc(data: rawptr) {
		p := (^Page)(data)
		d := p.ext_doc
		if d == nil { return }
		p.ext_doc = nil
		if d.idle_timer != base.NIL_HANDLE { host.clear_timer(p.loop, d.idle_timer) }
		for s in d.sheets { delete(s.ext); delete(s.key) }   // (the sheets go with the page's style engine)
		delete(d.sheets)
		delete(d.document_id)
		free(d)
	}, p)
	return d
}

// The documentId of a document (made on first need).
ext_document_id :: proc(p: ^Page) -> string { return ext_doc_of(p).document_id }

// Whether extensions may act in this App now (cheap: every document asks at each point).
@(private)
ext_any_running :: proc() -> bool {
	if the_pages == nil { return false }
	reg := &the_pages.extensions
	return reg.settings.enabled && len(reg.list) > 0
}

////////////////////////////////
// The points (called by the page's loading code)

// The parsed document was adopted (offthread.odin): Start.
ext_doc_adopted :: proc(p: ^Page) {
	if !ext_any_running() || p.worker != nil || p.closed { return }
	ext_webnav_committed(p)   // ext_webnavigation.odin
	ext_doc_reach(p, .Start)
}

// The parser finished (js_load.odin): End, and Idle a little later unless the load event comes first.
ext_doc_parsed :: proc(p: ^Page) {
	if !ext_any_running() || p.worker != nil || p.closed { return }
	if p.ext_doc == nil || p.ext_doc.reached < .Start { ext_webnav_committed(p) }   // (a document that was not adopted)
	ext_doc_reach(p, .End)
	ext_webnav_dom_loaded(p)
	if p.closed { return }
	d := ext_doc_of(p)
	ms := ext_registry().settings.idle_after_parsed_ms
	if d.reached < .Idle && d.idle_timer == base.NIL_HANDLE {
		d.idle_timer = host.set_timer(p.loop, f64(ms), 0, proc(data: rawptr) {
			q := page_by_id(u64(uintptr(data)))
			if q == nil || q.closed || q.ext_doc == nil { return }
			q.ext_doc.idle_timer = base.NIL_HANDLE
			ext_doc_reach(q, .Idle)
		}, rawptr(uintptr(page_id(p))))
	}
}

// The load event fired (ext_page_loaded): Idle.
@(private)
ext_doc_loaded :: proc(p: ^Page) {
	if !ext_any_running() || p.worker != nil || p.closed { return }
	ext_doc_reach(p, .Idle)
	ext_webnav_completed(p)
}

// Goes through every point up to `to` the document has not reached.
ext_doc_reach :: proc(p: ^Page, to: Ext_Point) {
	d := ext_doc_of(p)
	for d.reached < to && !p.closed {
		d.reached = Ext_Point(int(d.reached) + 1)
		ext_doc_run(p, d.reached)
		if p.closed { return }
		d = p.ext_doc
		if d == nil { return }
	}
	if d != nil && d.reached >= .Idle && d.idle_timer != base.NIL_HANDLE {
		host.clear_timer(p.loop, d.idle_timer)
		d.idle_timer = base.NIL_HANDLE
	}
}

// What a document matches with: its URL, or its creator's for a document without a URL of its own (about:blank,
// about:srcdoc, data:, blob: frames). False: nothing may be injected here.
ext_target_of :: proc(p: ^Page) -> (extensions.Script_Target, bool) {
	href := p.env.location.href
	n := frame_navigable_of(p)
	top := n == nil
	if !extensions.url_needs_fallback(href) { return {href = href, top = top}, true }
	q := p
	for extensions.url_needs_fallback(q.env.location.href) {
		m := frame_navigable_of(q)
		if m == nil || m.parent == nil { return {}, false }   // (a top document of no URL: Wren's own pages among them)
		q = m.parent
	}
	return {href = q.env.location.href, top = top, fallback = true}, true
}

// Whether extension `e` may act on document `p` (rule 4 of section 3.11): a host grant for what it matches with.
ext_doc_allowed :: proc(reg: ^extensions.Registry, e: ^extensions.Extension, p: ^Page) -> bool {
	if p.closed || p.worker != nil { return false }
	t, ok := ext_target_of(p)
	return ok && extensions.extension_host_allowed(reg, e, t.href)
}

@(private)
ext_doc_run :: proc(p: ^Page, at: Ext_Point) {
	target, ok := ext_target_of(p)
	if !ok { return }
	reg := ext_registry()
	list := make([dynamic]^extensions.Extension, 0, len(reg.list), context.temp_allocator)
	for e in reg.list {
		if e.enabled && e.image != nil && e.image.ok && extensions.extension_host_allowed(reg, e, target.href) { append(&list, e) }
	}
	for e in list {
		if p.closed { return }
		if extensions.registry_find(reg, e.id) != e { continue }   // (removed by what ran before)
		im := extensions.image_retain(e.image)   // (a reload in between keeps this one alive until the end)
		defer extensions.image_release(im)
		found := make([dynamic]int, 0, 4, context.temp_allocator)
		extensions.scripts_matching(&im.script_index, im.manifest.content_scripts, target, &found)
		for i in found { ext_inject_entry(p, e, im.manifest.content_scripts[i], at) }
		clear(&found)
		extensions.scripts_matching(&e.registered.index, e.registered.list, target, &found)
		for i in found {
			if p.closed || extensions.registry_find(reg, e.id) != e { break }
			if i < len(e.registered.list) { ext_inject_entry(p, e, e.registered.list[i], at) }
		}
	}
}

// One matching entry at one point: its CSS at Start, its scripts at its run_at.
@(private)
ext_inject_entry :: proc(p: ^Page, e: ^extensions.Extension, cs: extensions.Content_Script, at: Ext_Point) {
	if at == .Start {
		for rel in cs.css {
			src := extensions.extension_source(e, rel)
			if src == nil { continue }
			ext_css_add(p, e.id, ext_css_key("", rel), string(src), true)
		}
	}
	want: Ext_Point
	switch cs.run_at {
	case .Document_Start: want = .Start
	case .Document_End:   want = .End
	case .Document_Idle:  want = .Idle
	}
	if want != at { return }
	for rel in cs.js {
		if p.closed { return }
		src := extensions.extension_source(e, rel)
		if src == nil {
			log(p, .Warn, fmt.tprintf("the content script %s of %s is not read yet: it did not run here", rel, e.id))
			continue
		}
		ext_run_script(p, e, src, extensions.image_url(e.image, rel), cs.world)
	}
}

// Runs one script of extension `e` in `p`: in its isolated world, or in the page's realm (MAIN). False: it threw, or
// it could not run.
ext_run_script :: proc(p: ^Page, e: ^extensions.Extension, source: []byte, script_url: string, world: extensions.World) -> bool {
	if world == .Main {
		if js_realm(p) == nil { return false }   // (the page's scripts are off: so is its realm)
		return js_run(p, source, script_url) == .Ok
	}
	w := world_open(p, e)
	if w == nil { return false }
	return world_run(p, w, source, script_url)
}

////////////////////////////////
// Style sheets

// What removeCSS finds a sheet by: its text, or its file.
ext_css_key :: proc(text, file: string) -> string {
	return file != "" ? strings.concatenate({"file:", file}, context.temp_allocator) : strings.concatenate({"css:", text}, context.temp_allocator)
}

// Adds a sheet of extension `ext` to the document (`author`: the author origin, else the user origin).
ext_css_add :: proc(p: ^Page, ext, key, text: string, author: bool) -> bool {
	if p.engine == nil || p.closed { return false }
	s := style.engine_add_injected_sheet(p.engine, text, author)
	if s == nil { return false }
	d := ext_doc_of(p)
	append(&d.sheets, Ext_Sheet{ext = strings.clone(ext), key = strings.clone(key), sheet = s})
	p.style_stale = true
	return true
}

// Removes the first sheet of extension `ext` added with `key` (removeCSS). False: none.
ext_css_remove :: proc(p: ^Page, ext, key: string) -> bool {
	d := p.ext_doc
	if d == nil || p.engine == nil { return false }
	for s, i in d.sheets {
		if s.ext != ext || s.key != key { continue }
		style.engine_remove_sheet(p.engine, s.sheet)
		delete(s.ext); delete(s.key)
		ordered_remove(&d.sheets, i)
		p.style_stale = true
		return true
	}
	return false
}
