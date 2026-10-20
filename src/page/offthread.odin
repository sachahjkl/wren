package page

// Work of a page done on the blocking pool (host.Blocking_Pool, reached through the loader), so that a large document
// or stylesheet does not freeze the window while it is parsed:
//   * documents: decoding (html.decode_document) and Lexbor parsing into a fresh dom.Document made without a scope, plus
//     the parse of its larger <style> elements; the UI thread then adopts the result (`adopt_document`);
//   * stylesheets from <link> and @import: decoding and css.parse_stylesheet, then registration in the style engine.
//
// Why this is safe: a dom.Document and a css.Stylesheet are plain heap memory with no thread affinity (the allocator is
// the process heap or a locking tracker), parsing touches no shared state (Lexbor builds and frees its own parser per
// call; the CSS parser has its own arena), and the result is handed over exactly once, through the pool's `done` on the
// UI thread. Nothing of the page is read on the pool thread: a job copies its inputs.
//
// A job outlives its page if the page closes meanwhile: the page forgets it (`page` becomes nil) and the job frees its
// result when it comes back. Every path has a synchronous fallback with the same result (preferences page.threads.*).

import "core:strings"
import "wb:base"
import "wb:config"
import "wb:css"
import "wb:dom"
import "wb:host"
import "wb:html"
import "wb:style"

Thread_Settings :: struct {
	parse_html:             bool,
	parse_html_min_bytes:   int,
	parse_css:              bool,
	parse_css_min_bytes:    int,
	inline_style_min_bytes: int,
	style_threads:          int,   // -1 = automatic
	style_min_nodes:        int,
}

THREAD_PREFS := [?]config.Def{
	{name = "page.threads.parse_html", kind = .Bool, default = {b = true},
		description = "Decode and parse HTML documents on a background thread, so the window stays responsive while a large page loads. Off: on the interface thread (same result)."},
	{name = "page.threads.parse_html_min_bytes", kind = .Int, default = {i = 16 << 10}, bounded = true, min = 0, max = 1 << 40, bytes = true, unit = "bytes",
		description = "Documents smaller than this are parsed on the interface thread: handing them to another thread would cost more than it saves."},
	{name = "page.threads.parse_css", kind = .Bool, default = {b = true},
		description = "Parse stylesheets loaded with <link> and @import on a background thread. Off: on the interface thread (same result)."},
	{name = "page.threads.parse_css_min_bytes", kind = .Int, default = {i = 4 << 10}, bounded = true, min = 0, max = 1 << 40, bytes = true, unit = "bytes",
		description = "Loaded stylesheets smaller than this are parsed on the interface thread."},
	{name = "page.threads.inline_style_min_bytes", kind = .Int, default = {i = 4 << 10}, bounded = true, min = 0, max = 1 << 40, bytes = true, unit = "bytes",
		description = "<style> elements at least this large are parsed together with their document on the background thread (when page.threads.parse_html applies). Style elements added later by scripts are always parsed at once, as the specification requires."},
	{name = "page.threads.style", kind = .Int, default = {i = -1}, bounded = true, min = -1, max = 256,
		description = "Threads that compute the styles of a large document together with the interface thread (the result is the same as on one thread). -1 = one less than the logical processors, at most 7; 0 = only the interface thread."},
	{name = "page.threads.style_min_nodes", kind = .Int, default = {i = 4000}, bounded = true, min = 0, max = 1 << 40, unit = "nodes",
		description = "Documents with fewer nodes are styled on the interface thread alone: sharing the work out would cost more than it saves."},
}

// Helpers of the full style pass, shared by every page (the UI thread runs one pass at a time). Made on first use with
// page.threads.style threads, remade when that changes; `shutdown_threads` releases them.
@(private)
style_pool: ^host.Thread_Pool
@(private)
style_pool_size: int

@(private)
style_threads :: proc(p: ^Page) -> ^host.Thread_Pool {
	n := p.settings.threads.style_threads
	if n < 0 { n = min(host.processor_count() - 1, 7) }
	if n != style_pool_size || (n > 0 && style_pool == nil) {
		host.thread_pool_destroy(style_pool)
		style_pool = n > 0 ? host.thread_pool_make(n) : nil
		style_pool_size = n
	}
	return style_pool
}

// Joins the threads the page package keeps for all pages. Call once every page is closed, before exiting.
shutdown_threads :: proc() {
	host.thread_pool_destroy(style_pool)
	style_pool, style_pool_size = nil, 0
}

thread_settings_from_prefs :: proc(p: ^config.Prefs) -> Thread_Settings {
	return Thread_Settings{
		parse_html = config.bool_of(p, "page.threads.parse_html"),
		parse_html_min_bytes = int(config.int_of(p, "page.threads.parse_html_min_bytes")),
		parse_css = config.bool_of(p, "page.threads.parse_css"),
		parse_css_min_bytes = int(config.int_of(p, "page.threads.parse_css_min_bytes")),
		inline_style_min_bytes = int(config.int_of(p, "page.threads.inline_style_min_bytes")),
		style_threads = int(config.int_of(p, "page.threads.style")),
		style_min_nodes = int(config.int_of(p, "page.threads.style_min_nodes")),
	}
}

Bg_Job :: struct {
	page: ^Page,   // nil once the page closed: the job only frees what it made
}

Offthread_State :: struct {
	jobs:        [dynamic]^Bg_Job,
	next_serial: u64,
}

@(private)
offthread_destroy :: proc(p: ^Page) {
	for j in p.offthread.jobs { j.page = nil }
	delete(p.offthread.jobs)
}

@(private)
job_forget :: proc(j: ^Bg_Job) {
	if j.page == nil { return }
	for x, i in j.page.offthread.jobs { if x == j { ordered_remove(&j.page.offthread.jobs, i); break } }
}

@(private)
blocking_pool :: proc(p: ^Page) -> ^host.Blocking_Pool {
	if p.loader == nil { return nil }
	return p.loader.blocking
}

////////////////////////////////
// Documents

// A <style> element's sheet, parsed with its document.
Parsed_Sheet :: struct {
	owner: base.Handle,
	media: string,                // owned: the media attribute
	sheet: ^css.Stylesheet,
}

Parsed_Document :: struct {
	doc:       ^dom.Document,     // nil when the bytes could not be decoded; owned until adopted
	result:    html.Parse_Result,
	encoding:  string,            // owned: the encoding the bytes were decoded with
	decoded:   bool,
	sheets:    [dynamic]Parsed_Sheet,
	offthread: bool,              // was parsed on a background thread
}

Document_Parsed :: #type proc(p: ^Page, user: rawptr, d: ^Parsed_Document)

@(private)
Html_Job :: struct {
	using job:  Bg_Job,
	data:       []byte,           // owned
	decode:     bool,
	charset:    string,           // owned
	default_encoding: string,     // owned
	max_nodes:  int,
	style_min:  int,
	css_opt:    css.Parse_Options,
	max_sheet:  int,
	scripting:  bool,             // parsed with the scripting flag: <noscript> holds text (js_load_write.odin)
	out:        Parsed_Document,
	done:       Document_Parsed,
	user:       rawptr,
}

@(private)
html_job_make :: proc(p: ^Page, data: []byte, decode: bool, header_charset: string) -> ^Html_Job {
	j := new(Html_Job)
	j.page = p
	j.data = make([]byte, len(data))
	copy(j.data, data)
	j.decode = decode
	j.charset = strings.clone(header_charset)
	j.default_encoding = strings.clone(p.settings.html.default_encoding)
	j.max_nodes = p.settings.html.max_nodes
	j.style_min = p.settings.threads.inline_style_min_bytes
	j.scripting = p.worker == nil && js_enabled(p)
	if p.engine != nil {
		j.css_opt = style.parse_options(&p.engine.settings)
		j.max_sheet = p.engine.settings.author_stylesheets ? p.engine.settings.max_sheet_bytes : -1
	}
	return j
}

// Any thread: decoding, the tree, the larger style sheets. Reads nothing but the job.
@(private)
html_work :: proc(data: rawptr) {
	j := (^Html_Job)(data)
	text := j.data
	if j.decode {
		d, ok := html.decode_document(j.data, j.charset, j.default_encoding)
		if !ok { return }
		j.out.encoding = strings.clone(d.encoding)
		text = d.text
	}
	defer if j.decode { delete(text) }
	j.out.decoded = true
	doc := dom.document_create(nil)
	j.out.doc = doc
	j.out.result = html.parse_into(doc, doc.root, text, j.max_nodes)
	if j.scripting { noscript_as_text(doc) }
	if j.max_sheet < 0 { return }
	stack := make([dynamic]base.Handle, context.temp_allocator)
	append(&stack, doc.root)
	for len(stack) > 0 {
		h := pop(&stack)
		n := dom.get(doc, h)
		if n.kind == .Element && n.name == "style" {
			src := dom.text_content(doc, h, context.temp_allocator)
			if len(src) >= j.style_min && len(src) <= j.max_sheet {
				media, _ := dom.get_attribute(doc, h, "media")
				append(&j.out.sheets, Parsed_Sheet{h, strings.clone(media), css.parse_stylesheet(src, j.css_opt)})
			}
			continue
		}
		for c := n.last_child; c != base.NIL_HANDLE; c = dom.get(doc, c).prev { append(&stack, c) }
	}
}

@(private)
html_job_free :: proc(j: ^Html_Job) {
	parsed_document_destroy(&j.out)
	delete(j.data); delete(j.charset); delete(j.default_encoding)
	free(j)
}

// Frees what was not adopted.
parsed_document_destroy :: proc(d: ^Parsed_Document) {
	if d.doc != nil { dom.document_destroy(d.doc) }
	for s in d.sheets {
		delete(s.media)
		if s.sheet != nil { css.stylesheet_destroy(s.sheet); free(s.sheet) }
	}
	delete(d.sheets)
	delete(d.encoding)
	d^ = {}
}

@(private)
html_done :: proc(data: rawptr) {
	j := (^Html_Job)(data)
	if p := j.page; p != nil {
		job_forget(j)
		j.done(p, j.user, &j.out)
	}
	html_job_free(j)
}

// Decodes (BOM, `header_charset`, <meta> prescan, then html.default_encoding) and parses `data` into a new document,
// on the blocking pool when preferences allow, then calls `done` on the UI thread with the result, which `done` gives to
// `adopt_document` (or drops). Called synchronously, before returning, on the fallback path. Not called at all if the
// page closes first.
parse_document :: proc(p: ^Page, data: []byte, header_charset: string, done: Document_Parsed, user: rawptr) {
	j := html_job_make(p, data, true, header_charset)
	j.done, j.user = done, user
	ts := &p.settings.threads
	if pool := blocking_pool(p); pool != nil && ts.parse_html && len(data) >= ts.parse_html_min_bytes {
		j.out.offthread = true
		append(&p.offthread.jobs, &j.job)
		host.run_blocking(pool, html_work, html_done, j)
		return
	}
	j.page = nil   // not listed: finished right here
	html_work(j)
	done(p, user, &j.out)
	html_job_free(j)
}

// Replaces the page's document by a parsed one (which must not belong to anything yet): the old tree, its listeners
// and the stylesheets that came from it go; <meta> policies of the new one apply; the sheets parsed with it are
// registered. Takes `d.doc` and `d.sheets`. Returns the parse result.
adopt_document :: proc(p: ^Page, d: ^Parsed_Document) -> html.Parse_Result {
	if d.doc == nil { return d.result }
	old := p.doc
	dom.document_attach(d.doc, p.scope)
	p.doc = d.doc
	d.doc = nil
	// everything that holds the document pointer follows it: the form-control model is rebuilt on the new tree
	if p.formctl != nil { forms_detach(p); forms_attach(p) }
	dom.document_destroy(old)
	if p.engine != nil {
		// owners of the old sheets are handles into the old tree, which the new one reuses: start from nothing
		for _, l in p.link_loads { free_load(p, l) }
		clear(&p.link_loads)
		for l in p.import_loads { free_load(p, l) }
		clear(&p.import_loads)
		style.engine_clear_document_sheets(p.engine)
		style.styled_destroy(p.styled)
		p.styled = nil
		p.style_stale = true
	}
	p.doc_el = dom.find_first_by_tag(p.doc, "html")
	p.head = dom.find_first_by_tag(p.doc, "head")
	p.body = dom.find_first_by_tag(p.doc, "body")
	if p.body == base.NIL_HANDLE { blank_document(p) }   // parse failure: keep the page usable
	for &s in d.sheets {
		if p.engine != nil { style.engine_add_parsed_sheet(p.engine, s.sheet, s.owner, s.media, p.env.location.href) } else { css.stylesheet_destroy(s.sheet); free(s.sheet) }
		s.sheet = nil
	}
	apply_meta(p)
	render_begin(p)   // its stylesheets start loading now; the first paint waits for them (render_blocking.odin)
	return d.result
}

////////////////////////////////
// Stylesheets from <link> and @import

@(private)
Css_Job :: struct {
	using job: Bg_Job,
	data:      []byte,            // owned: the response body
	opt:       css.Parse_Options,
	max_bytes: int,
	sheet:     ^css.Stylesheet,   // result
	text:      []byte,            // result when too large to parse: the engine refuses it as the synchronous path does
	is_import: bool,
	owner:     base.Handle,
	serial:    u64,
	media:     string,            // owned
	url:       string,            // owned
	sheet_id:  u64,
	slot:      int,
}

@(private)
css_work :: proc(data: rawptr) {
	j := (^Css_Job)(data)
	text := decode_css(j.data, j.max_bytes)
	if len(text) > j.max_bytes { j.text = text; return }
	j.sheet = css.parse_stylesheet(string(text), j.opt)
	delete(text)
}

@(private)
css_job_free :: proc(j: ^Css_Job) {
	if j.sheet != nil { css.stylesheet_destroy(j.sheet); free(j.sheet) }
	delete(j.text); delete(j.data); delete(j.media); delete(j.url)
	free(j)
}

@(private)
css_done :: proc(data: rawptr) {
	j := (^Css_Job)(data)
	defer css_job_free(j)
	p := j.page
	if p == nil { return }
	job_forget(j)
	css_apply(p, j)
}

@(private)
css_apply :: proc(p: ^Page, j: ^Css_Job) {
	if j.is_import {
		if j.sheet != nil {
			style.engine_resolve_import_parsed(p.engine, j.sheet_id, j.slot, j.sheet, j.url)
			j.sheet = nil
		} else {
			style.engine_resolve_import_by_id(p.engine, j.sheet_id, j.slot, string(j.text), j.url)
		}
	} else {
		l, still := p.link_loads[j.owner]
		if !still || l.serial != j.serial { return }   // the <link> went away or changed meanwhile
		s: ^style.Sheet
		if j.sheet != nil {
			s = style.engine_add_parsed_sheet(p.engine, j.sheet, j.owner, j.media, j.url, from_link = true, scope = l.scope)
			j.sheet = nil
		} else {
			s = style.engine_add_sheet(p.engine, string(j.text), j.owner, j.media, j.url, from_link = true, scope = l.scope)
		}
		if s == nil { log(p, .Warn, strings.concatenate({"stylesheet ", j.url, ": too large or disabled"}, context.temp_allocator)) }
	}
	p.style_stale = true
	start_pending_imports(p)
}

// A fetched stylesheet: parsed off the UI thread when preferences allow, then registered. False when the caller must
// handle it synchronously.
@(private)
parse_sheet_offthread :: proc(p: ^Page, l: ^Style_Load, body: []byte) -> bool {
	ts := &p.settings.threads
	pool := blocking_pool(p)
	if pool == nil || !ts.parse_css || len(body) < ts.parse_css_min_bytes { return false }
	j := new(Css_Job)
	j.page = p
	j.data = make([]byte, len(body))
	copy(j.data, body)
	j.opt = style.parse_options(&p.engine.settings)
	j.max_bytes = p.engine.settings.max_sheet_bytes
	j.is_import, j.owner, j.serial = l.is_import, l.owner, l.serial
	j.media, j.url = strings.clone(l.media), strings.clone(l.url)
	j.sheet_id, j.slot = l.sheet_id, l.slot
	append(&p.offthread.jobs, &j.job)
	host.run_blocking(pool, css_work, css_done, j)
	return true
}
