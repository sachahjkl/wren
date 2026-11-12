package page

// Offscreen documents (docs/extensions.md, section 3.8): offscreen.createDocument, hasDocument, closeDocument. An
// offscreen document is a page of the extension that shows nothing; the shell hosts it (Ext_Embedder.offscreen_open: a
// tab that belongs to no window). One per extension, as in Chrome. Its context kind is Offscreen: it has runtime only.
//
// The states of one record (Ext_Offscreen):
//   Loading -- its document's load event (ext_page_loaded) --> Ready: every createDocument waiting is answered
//   Loading -- EXT_OFFSCREEN_LOAD_MS without a load --> gone: the callers get an error
//   Ready -- a CLIPBOARD-only document's lifetime (extensions.offscreen.max_lifetime_ms) ends --> gone
//   Loading / Ready -- closeDocument, the extension stops --> gone
// The record goes first, then the shell closes the page in a task of its own (never inside a call of a page). One timer
// per record: the load deadline while it loads, its lifetime once ready (a CLIPBOARD-only one).

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:extensions"
import "wb:host"
import "wb:url"

// A document that does not load in this time is closed and its createDocument fails.
EXT_OFFSCREEN_LOAD_MS :: 30_000

EXT_OFFSCREEN_REASONS := [?]string{
	"TESTING", "AUDIO_PLAYBACK", "IFRAME_SCRIPTING", "DOM_SCRAPING", "BLOBS", "DOM_PARSER", "USER_MEDIA", "DISPLAY_MEDIA",
	"WEB_RTC", "CLIPBOARD", "LOCAL_STORAGE", "WORKERS", "BATTERY_STATUS", "MATCH_MEDIA", "GEOLOCATION",
}

Ext_Offscreen :: struct {
	serial:   u64,                    // what its timer names it by (a record that went is not found)
	ext:      string,                 // owned
	url:      string,                 // owned: the document's absolute URL
	ready:    bool,                   // its load event fired
	lifetime: f64,                    // ms once ready (0: until it is closed)
	waiting:  [dynamic]Ext_Target,    // the createDocument calls to answer when it loads
	timer:    base.Handle,
}

@(private = "file")
ext_offscreen_free :: proc(rec: ^Ext_Offscreen) {
	r := ext_router()
	if rec.timer != base.NIL_HANDLE && r.loop != nil { host.clear_timer(r.loop, rec.timer) }
	delete(rec.ext); delete(rec.url); delete(rec.waiting)
	free(rec)
}

// The router ends (the App ends): the records go (the shell's tabs hold the pages and go with them).
ext_offscreen_destroy_all :: proc() {
	r := ext_router()
	for _, rec in r.offscreen { ext_offscreen_free(rec) }
	delete(r.offscreen)
	r.offscreen = nil
}

// The absolute URL of a file of the extension named by `u` (absolute in its origin, or relative to its root). False:
// not a file of this extension.
ext_own_file_url :: proc(e: ^extensions.Extension, u: string) -> (string, bool) {
	im := e.image
	base_u, bok := url.parse(im.base_url, nil, context.temp_allocator)
	if !bok { return "", false }
	abs, ok := url.parse(u, &base_u, context.temp_allocator)
	if !ok || !strings.has_prefix(abs.href, im.base_url) { return "", false }
	rel := abs.href[len(im.base_url):]
	if i := strings.index_any(rel, "?#"); i >= 0 { rel = rel[:i] }
	n, nok := extensions.package_path_normalize(url.percent_decode(rel), context.temp_allocator)
	if !nok || !extensions.image_has_file(im, n) { return "", false }
	return abs.href, true
}

ext_offscreen_create :: proc(x: ^Ext_Call) {
	params, ok := ext_arg(x, 0).(json.Object)
	if !ok { ext_fail(x, "Error in invocation of offscreen.createDocument: parameters must be an object"); return }
	u, uok := jstr(params, "url")
	reasons, rok := params["reasons"].(json.Array)
	_, jok := jstr(params, "justification")
	if !uok || !rok || len(reasons) == 0 || !jok {
		ext_fail(x, "Error in invocation of offscreen.createDocument: url, reasons and justification are required")
		return
	}
	clipboard_only := true
	for v in reasons {
		s, sok := v.(json.String)
		known := false
		if sok { for k in EXT_OFFSCREEN_REASONS { if k == s { known = true; break } } }
		if !known { ext_fail(x, fmt.tprintf("Error in invocation of offscreen.createDocument: %s is not a reason", extensions.json_text(v))); return }
		if s != "CLIPBOARD" { clipboard_only = false }
	}
	abs, fok := ext_own_file_url(x.e, u)
	if !fok { ext_fail(x, fmt.tprintf("the offscreen document's URL %q is not a file of the extension", u)); return }
	r := ext_router()
	if x.e.id in r.offscreen { ext_fail(x, "Only a single offscreen document may be created."); return }
	if r.embedder.offscreen_open == nil || r.loop == nil { ext_fail(x, "offscreen documents are not available here"); return }
	rec := new(Ext_Offscreen)
	rec.serial = ext_next_id()
	rec.ext, rec.url = strings.clone(x.e.id), strings.clone(abs)
	rec.lifetime = clipboard_only ? f64(x.reg.settings.offscreen_max_ms) : 0
	append(&rec.waiting, x.to)
	if r.offscreen == nil { r.offscreen = make(map[string]^Ext_Offscreen) }
	r.offscreen[rec.ext] = rec
	rec.timer = host.set_timer(r.loop, EXT_OFFSCREEN_LOAD_MS, 0, ext_offscreen_timer, rawptr(uintptr(rec.serial)))
	x.answered = true   // (once its document loaded: ext_page_loaded)
	ext_task_post(.Offscreen_Open, x.e.id, rec.url)   // ext_tabs.odin: the shell makes the page from a task of its own
}

// Its timer: a document still loading missed its deadline (its callers fail); a ready one reached its lifetime.
@(private = "file")
ext_offscreen_timer :: proc(data: rawptr) {
	serial := u64(uintptr(data))
	for id, rec in ext_router().offscreen {
		if rec.serial != serial { continue }
		rec.timer = base.NIL_HANDLE
		if !rec.ready {
			for to in rec.waiting { ext_answer(to, "!the offscreen document did not load") }
			clear(&rec.waiting)
		}
		ext_offscreen_close(id)
		return
	}
}

// A document's load event fired (js_load.odin): a tab's document is "complete" (tabs.onUpdated: a tab that is not shown
// never paints, so its load is the moment); an offscreen document answers the createDocument calls waiting for it.
ext_page_loaded :: proc(p: ^Page) {
	if len(ext_registry().list) == 0 { return }
	ext_tab_loaded(p)   // ext_tabs.odin
	r := ext_router()
	if len(r.offscreen) == 0 { return }
	o := p.env.origin
	if o.opaque || o.scheme != extensions.SCHEME_CHROME { return }
	rec := r.offscreen[o.host]
	if rec == nil || rec.ready { return }
	em := &r.embedder
	if em.page_kind == nil || em.page_kind(em.user, p) != .Offscreen { return }
	rec.ready = true
	for to in rec.waiting { ext_answer(to, "") }
	clear(&rec.waiting)
	if rec.timer != base.NIL_HANDLE && r.loop != nil { host.clear_timer(r.loop, rec.timer); rec.timer = base.NIL_HANDLE }
	if rec.lifetime > 0 && r.loop != nil {
		rec.timer = host.set_timer(r.loop, rec.lifetime, 0, ext_offscreen_timer, rawptr(uintptr(rec.serial)))
	}
}

ext_offscreen_has :: proc(x: ^Ext_Call) {
	ext_ok(x, jbool_text(x.e.id in ext_router().offscreen))
}

ext_offscreen_close_call :: proc(x: ^Ext_Call) {
	if x.e.id not_in ext_router().offscreen { ext_fail(x, "No current offscreen document."); return }
	ext_offscreen_close(x.e.id)
	ext_ok(x, "")
}

// The offscreen document of `ext` goes (closeDocument, its timer, the extension stops). The callers still waiting for
// it get an error; the shell closes the page from a task of its own.
ext_offscreen_close :: proc(ext: string) {
	r := ext_router()
	rec, ok := r.offscreen[ext]
	if !ok { return }
	delete_key(&r.offscreen, ext)
	for to in rec.waiting { ext_answer(to, "!the offscreen document was closed") }
	clear(&rec.waiting)
	ext_task_post(.Offscreen_Close, rec.ext, "")
	ext_offscreen_free(rec)
}
