package browser

import "core:fmt"
import "core:hash/xxhash"
import "core:strings"
import "toolkit:font"
import "wb:base"
import "wb:config"
import "wb:host"
import "wb:page"
import "wb:style"

////////////////////////////////
// Web faces shared between pages and tabs
//
// A page's @font-face files become DirectWrite faces (fonts.odin register_web_face). The same bytes under the same
// descriptors are one face for every tab and every page: going from page to page of a site (or opening it in another
// tab) loads nothing again, and the instances made from a face (variable axes, synthesized bold and slant, the cascades
// of the font-family lists) stay too, with their shaped words and glyph bitmaps. A face no page uses any more is kept
// for the pages to come (font.web_faces.kept of them, least recently left out first), then unloaded with everything
// made from it. The key is the bytes' hash, the family name, the nominal weight and the style.

WEB_FACE_PREFS := [?]config.Def{
	{name = "font.web_faces.kept", kind = .Int, default = {i = 64}, bounded = true, min = 0, max = 100_000,
		description = "Web fonts (DirectWrite faces of the pages' @font-face) kept loaded once no page uses them, for the next pages of the site and for other tabs: they then show at once, without being loaded and shaped again. The least recently left go first."},
}

register_web_face_prefs :: proc(p: ^config.Prefs) { config.register(p, WEB_FACE_PREFS[:]) }

Shared_Face :: struct {
	key:        string,
	id:         font.Font_Id,
	refs:       int,                    // web faces (pages) using it
	derived:    [dynamic]font.Font_Id,  // instances and cascades made from it, unloaded with it
	idle_since: u64,                    // when its last page let it go (order of eviction)
}

Shared_Faces :: struct {
	by_key:   map[string]^Shared_Face,
	by_id:    map[font.Font_Id]^Shared_Face,   // the face and what is made from it
	idle_seq: u64,
	hits:     int,                             // faces a page got without loading them
	loads:    int,
}

@(private = "file")
web_faces_kept :: proc() -> int {
	if the_app == nil || config.ref_of(&the_app.prefs, "font.web_faces.kept") == config.NO_REF { return 64 }
	return int(config.int_of(&the_app.prefs, "font.web_faces.kept"))
}

shared_face_acquire :: proc(pf: ^Page_Fonts, data: []byte, family: string, weight: int, style: font.Font_Style) -> (font.Font_Id, bool) {
	sh := &pf.shared
	key := fmt.tprintf("%016x %d %s %d %v", xxhash.XXH3_64_default(data), len(data), strings.to_lower(strings.trim_space(family), context.temp_allocator), weight, style)
	if sf, ok := sh.by_key[key]; ok && font.valid(pf.state, sf.id) {
		sf.refs += 1
		sh.hits += 1
		return sf.id, true
	}
	copied := make([]byte, len(data))
	copy(copied, data)
	id, ok := font.load_memory(pf.state, copied, true, 0, {}, family, weight, style)
	if !ok { return 0, false }
	sh.loads += 1
	sf := new(Shared_Face)
	sf.key = strings.clone(key)
	sf.id = id
	sf.refs = 1
	if sh.by_key == nil { sh.by_key = make(map[string]^Shared_Face); sh.by_id = make(map[font.Font_Id]^Shared_Face) }
	sh.by_key[sf.key] = sf
	sh.by_id[id] = sf
	return id, true
}

// A page lets go of web face `id`: kept for later (or unloaded when it is not a shared face).
shared_face_release :: proc(pf: ^Page_Fonts, id: font.Font_Id) {
	sh := &pf.shared
	sf := sh.by_id[id] or_else nil
	if sf == nil || sf.id != id { font.unload(pf.state, id); return }
	sf.refs -= 1
	if sf.refs > 0 { return }
	sh.idle_seq += 1
	sf.idle_since = sh.idle_seq
	shared_faces_trim(pf, web_faces_kept())
}

// An instance made from web face `w` (variable axes, synthesis): unloaded with its face.
own_web :: proc(pf: ^Page_Fonts, w: Web_Face, id: font.Font_Id) {
	sf := pf.shared.by_id[w.id] or_else nil
	if sf == nil || sf.id != w.id { own(pf, w.owner, id); return }
	attach_derived(&pf.shared, sf, id)
}

// A cascade made of web faces (and others): unloaded with the first of its shared faces to go.
own_cascade :: proc(pf: ^Page_Fonts, id: font.Font_Id, entries: []font.Cascade_Entry) {
	attached := false
	for e in entries {
		sf := pf.shared.by_id[e.font] or_else nil
		if sf == nil { continue }
		attach_derived(&pf.shared, sf, id)
		attached = true
	}
	if !attached { own(pf, pf.scope, id) }
}

@(private = "file")
attach_derived :: proc(sh: ^Shared_Faces, sf: ^Shared_Face, id: font.Font_Id) {
	if id == 0 || id == sf.id { return }
	for d in sf.derived { if d == id { return } }
	append(&sf.derived, id)
	if id not_in sh.by_id { sh.by_id[id] = sf }
}

// Keeps at most `kept` faces no page uses.
shared_faces_trim :: proc(pf: ^Page_Fonts, kept: int) {
	sh := &pf.shared
	for {
		idle, oldest := 0, (^Shared_Face)(nil)
		for _, sf in sh.by_key {
			if sf.refs > 0 { continue }
			idle += 1
			if oldest == nil || sf.idle_since < oldest.idle_since { oldest = sf }
		}
		if idle <= kept || oldest == nil { return }
		shared_face_unload(pf, oldest)
		page_fonts_forget(pf)
	}
}

@(private = "file")
shared_face_unload :: proc(pf: ^Page_Fonts, sf: ^Shared_Face) {
	sh := &pf.shared
	for d in sf.derived {
		if (sh.by_id[d] or_else nil) == sf { delete_key(&sh.by_id, d) }
		font.unload(pf.state, d)
	}
	delete_key(&sh.by_id, sf.id)
	font.unload(pf.state, sf.id)
	delete_key(&sh.by_key, sf.key)
	delete(sf.derived)
	delete(sf.key)
	free(sf)
}

shared_faces_destroy :: proc(pf: ^Page_Fonts) {
	sh := &pf.shared
	all := make([dynamic]^Shared_Face, context.temp_allocator)
	for _, sf in sh.by_key { append(&all, sf) }
	for sf in all { shared_face_unload(pf, sf) }
	delete(sh.by_key)
	delete(sh.by_id)
	sh^ = {}
}

////////////////////////////////
// Invisible text in a block period (CSS Fonts 4 §4.9)
//
// Once a page is shown, text whose first usable family is a web font still loading in its block period
// (page.fonts_blocking_families: font-display auto / block, the short period of fallback / optional, a font the HTTP
// cache holds) is laid out with the fallback font, as other browsers do, but not drawn; it appears with its font, or
// in the fallback font when the period ends. (Before the first paint, the paint itself waits: page/render_blocking.odin.)

Blocking_Text :: struct {
	families: [dynamic]string,   // owned, lower case
	layout:   rawptr,            // the layout these apply to (a held frame of another page is drawn as it was)
	memo:     map[rawptr]bool,   // by font-family list (shared by inheritance): invisible?
	timer:    base.Handle,       // a frame when the earliest period ends
}

blocking_text_destroy :: proc(b: ^Blocking_Text) {
	for f in b.families { delete(f) }
	delete(b.families)
	delete(b.memo)
	if b.timer != base.NIL_HANDLE && the_app != nil { host.clear_timer(&the_app.loop, b.timer) }
	b^ = {}
}

// The families of `t`'s page that are in their block period now (called before its layout is painted).
blocking_text_update :: proc(pf: ^Page_Fonts, t: ^Tab) {
	b := &pf.blocking
	for f in b.families { delete(f) }
	clear(&b.families)
	clear(&b.memo)
	b.layout = &t.layout
	if t.page == nil { return }
	fams, next_ms := page.fonts_blocking_families(t.page)
	for f in fams { append(&b.families, strings.clone(f)) }
	if next_ms >= 0 && the_app != nil {
		if b.timer != base.NIL_HANDLE { host.clear_timer(&the_app.loop, b.timer) }
		b.timer = host.set_timer(&the_app.loop, next_ms + 1, 0, proc(data: rawptr) {
			page_render.fonts.blocking.timer = base.NIL_HANDLE
			the_app.frames_requested = max(the_app.frames_requested, 2)
		}, nil)
	}
}

@(private = "file")
GENERIC_FAMILIES := [?]string{"serif", "sans-serif", "monospace", "cursive", "fantasy", "system-ui", "ui-serif", "ui-sans-serif", "ui-monospace", "ui-rounded", "emoji", "math", "fangsong"}

// Whether the text of a display item of layout `l` is to be drawn invisible now.
web_text_invisible :: proc(l: ^Layout, cs: ^style.Computed) -> bool {
	pf := &page_render.fonts
	b := &pf.blocking
	if len(b.families) == 0 || rawptr(l) != b.layout || cs == nil || len(cs.font_family) == 0 { return false }
	key := rawptr(raw_data(cs.font_family))
	if v, ok := b.memo[key]; ok { return v }
	invisible := false
	walk: for fam in cs.font_family {
		name := strings.to_lower(strings.trim_space(fam), context.temp_allocator)
		has_web := false
		for w in pf.web { if w.family == name && (w.owner == pf.scope || w.owner == nil) { has_web = true; break } }
		if has_web { break walk }   // a face of the family is there: it (or the system fallback) draws
		for p in b.families { if p == name { invisible = true; break walk } }
		for g in GENERIC_FAMILIES { if g == name { break walk } }
		if font.has_system_family(pf.state, name) { break walk }
	}
	b.memo[key] = invisible
	return invisible
}

