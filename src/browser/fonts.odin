package browser

import "core:strings"
import "toolkit:font"
import "toolkit:ui"
import "wb:host"
import lay "wb:layout"
import "wb:page"
import "wb:style"

// Page fonts: CSS font-family lists to font cascades of the toolkit (DirectWrite). For each family of the list, in
// order: the page's web fonts of that name (@font-face, CSS Fonts 4 §5.2 matching: stretch, then style, then weight;
// every face of the chosen descriptors joins with its unicode-range, so each one only covers its range), else the
// system family of that name (DirectWrite's matching; aliases for names pages use for fonts Windows lacks), generic
// families through their preferences. Then the default generic family, the interface font, and the system fallback of
// the toolkit for characters none of them has (U+2190 in a Latin web font comes from a system font). Bold and italic a
// web family lacks are synthesized (CSS font-synthesis); variable web fonts get their weight / width axes from
// font-weight / font-stretch, and font-variation-settings on top. OpenType features (font-feature-settings,
// font-variant-*, font-kerning) are part of the cascade.
//
// Web faces belong to the tab that downloaded them and are seen only by that tab's layout (`page_fonts_scope`); they
// are unloaded when its page changes or the tab closes (`page_fonts_drop`), with every font made from them.

Web_Face :: struct {
	family:  string,             // owned, lower case
	weight:  [2]u16,             // range (variable fonts)
	style:   style.Font_Style,
	stretch: [2]f32,             // percentages
	ranges:  []font.Range,       // owned; empty: every character
	id:      font.Font_Id,
	owner:   rawptr,
	wght, wdth, ital, slnt: bool,   // variable axes of the face
}

Page_Fonts :: struct {
	state:    ^font.State,
	ui:       font.Font_Id,
	web:      [dynamic]Web_Face,
	resolved: map[string]font.Font_Id,             // request -> cascade
	owned:    map[rawptr][dynamic]font.Font_Id,    // fonts made from an owner's web faces
	scope:    rawptr,                              // whose web faces the layout sees
	emoji, math, fangsong: string,                 // owned: families of the generic families style does not map
	scanned:  bool,                                // compatibility: start-up preloading happened
	shared:   Shared_Faces,                        // web faces by content, for every tab and page (web_font_faces.odin)
	blocking: Blocking_Text,                       // text drawn invisible while its web font loads (web_font_faces.odin)
}

// Names pages use for fonts that do not exist on Windows.
@(private = "file")
ALIASES := [?][2]string{
	{"helvetica", "arial"}, {"helvetica neue", "arial"}, {"liberation sans", "arial"}, {"nimbus sans", "arial"},
	{"times", "times new roman"}, {"liberation serif", "times new roman"},
	{"courier", "courier new"}, {"liberation mono", "courier new"},
	{"menlo", "consolas"}, {"monaco", "consolas"}, {"sf mono", "consolas"}, {"dejavu sans mono", "consolas"},
	{"-apple-system", "segoe ui"}, {"blinkmacsystemfont", "segoe ui"}, {"system-ui", "segoe ui"}, {"sf pro text", "segoe ui"},
	{"roboto", "segoe ui"}, {"ubuntu", "segoe ui"}, {"open sans", "segoe ui"}, {"noto sans", "segoe ui"},
	{"apple color emoji", "segoe ui emoji"}, {"noto color emoji", "segoe ui emoji"}, {"android emoji", "segoe ui emoji"},
}

page_fonts_init :: proc(pf: ^Page_Fonts, state: ^font.State, ui_font: font.Font_Id) {
	pf.state, pf.ui = state, ui_font
	pf.resolved = make(map[string]font.Font_Id)
	pf.owned = make(map[rawptr][dynamic]font.Font_Id)
	pf.emoji, pf.math, pf.fangsong = strings.clone("Segoe UI Emoji"), strings.clone("Cambria Math"), strings.clone("FangSong")
}

page_fonts_destroy :: proc(pf: ^Page_Fonts) {
	owners := make([dynamic]rawptr, context.temp_allocator)
	for w in pf.web { append(&owners, w.owner) }
	for o in pf.owned { append(&owners, o) }
	for o in owners { page_fonts_drop(pf, o) }
	shared_faces_destroy(pf)
	blocking_text_destroy(&pf.blocking)
	delete(pf.web)
	delete(pf.owned)
	page_fonts_forget(pf)
	delete(pf.resolved)
	delete(pf.emoji); delete(pf.math); delete(pf.fangsong)
	pf^ = {}
}

// Drops the resolution cache (preferences changed, a face was registered or dropped).
page_fonts_forget :: proc(pf: ^Page_Fonts) {
	canvas_outlines_clear()   // (canvas glyph outlines are keyed by font id)
	for k in pf.resolved { delete(k) }
	clear(&pf.resolved)
}

// Families of the generic families the style settings do not map (emoji, math, fangsong).
page_fonts_set_generics :: proc(pf: ^Page_Fonts, emoji, math, fangsong: string) {
	delete(pf.emoji); delete(pf.math); delete(pf.fangsong)
	pf.emoji, pf.math, pf.fangsong = strings.clone(emoji), strings.clone(math), strings.clone(fangsong)
	page_fonts_forget(pf)
}

// The web faces of `owner` are the ones the layout sees from now on.
page_fonts_scope :: proc(pf: ^Page_Fonts, owner: rawptr) { pf.scope = owner }

// A web font face of `owner` (a downloaded, decoded @font-face). The DirectWrite face is shared with every page that
// has the same bytes under the same descriptors (web_font_faces.odin).
register_web_face :: proc(pf: ^Page_Fonts, owner: rawptr, f: ^page.Web_Font) -> bool {
	if len(f.data) == 0 { return false }
	fs := font.Font_Style.Normal
	#partial switch f.font_style {
	case .Italic: fs = .Italic
	case .Oblique: fs = .Oblique
	}
	nominal := int(f.weight[0] == f.weight[1] ? f.weight[0] : (f.weight[0] + f.weight[1]) / 2)
	id, ok := shared_face_acquire(pf, f.data, f.family, nominal, fs)
	if !ok { return false }
	w := Web_Face{
		family = strings.to_lower(strings.trim_space(f.family)), weight = f.weight, style = f.font_style, stretch = f.stretch,
		id = id, owner = owner,
	}
	if w.weight == {} { w.weight = {400, 400} }
	if w.stretch == {} { w.stretch = {100, 100} }
	if len(f.unicode_range) > 0 {
		w.ranges = make([]font.Range, len(f.unicode_range))
		for r, i in f.unicode_range { w.ranges[i] = {rune(r[0]), rune(r[1])} }
	}
	for a in font.axes(pf.state, id, context.temp_allocator) {
		// DirectWrite also reports the implicit axes of a static face (its weight, width, slant as single values):
		// only a range is a variable axis. (A static upright face taken for one with an ital axis would never get its
		// synthesized slant.)
		if a.max <= a.min { continue }
		tag := a.tag
		switch string(tag[:]) {
		case "wght": w.wght = true
		case "wdth": w.wdth = true
		case "ital": w.ital = true
		case "slnt": w.slnt = true
		}
	}
	append(&pf.web, w)
	page_fonts_forget(pf)
	return true
}

// Compatibility: a face already loaded, for `family` (every character, the whole weight range of one weight).
register_face :: proc(pf: ^Page_Fonts, family: string, weight: u16, italic: bool, id: font.Font_Id) {
	append(&pf.web, Web_Face{
		family = strings.to_lower(strings.trim_space(family)), weight = {weight, weight}, style = italic ? .Italic : .Normal,
		stretch = {100, 100}, id = id, owner = pf.scope,
	})
	page_fonts_forget(pf)
}

// Unloads the web faces of `owner` and every font made from them.
page_fonts_drop :: proc(pf: ^Page_Fonts, owner: rawptr) {
	any := false
	for i := len(pf.web) - 1; i >= 0; i -= 1 {
		w := pf.web[i]
		if w.owner != owner { continue }
		shared_face_release(pf, w.id)   // (kept loaded for the pages to come: web_font_faces.odin)
		delete(w.family)
		delete(w.ranges)
		ordered_remove(&pf.web, i)
		any = true
	}
	if list, ok := pf.owned[owner]; ok {
		for id in list { font.unload(pf.state, id) }
		delete(list)
		delete_key(&pf.owned, owner)
		any = true
	}
	if pf.scope == owner { pf.scope = nil }
	if any { page_fonts_forget(pf) }
}

// The web faces of `from` and the fonts made from them become `to`'s (dropped with it). The layout of `from` no longer
// sees them; what was laid out with them can still be painted.
page_fonts_transfer :: proc(pf: ^Page_Fonts, from, to: rawptr) {
	if from == to { return }
	for &w in pf.web { if w.owner == from { w.owner = to } }
	if list, ok := pf.owned[from]; ok {
		for id in list { own(pf, to, id) }
		delete(list)
		delete_key(&pf.owned, from)
	}
	if pf.scope == from { pf.scope = nil }
	page_fonts_forget(pf)
}

@(private)
own :: proc(pf: ^Page_Fonts, owner: rawptr, id: font.Font_Id) {
	if owner == nil || id == 0 { return }
	list := pf.owned[owner]
	for x in list { if x == id { return } }
	append(&list, id)
	pf.owned[owner] = list
}

// DirectWrite stretch class (1..9) of a font-stretch percentage.
@(private = "file")
stretch_class :: proc(pct: f32) -> int {
	CLASSES :: [9]f32{50, 62.5, 75, 87.5, 100, 112.5, 125, 150, 200}
	best, bd := 5, max(f32)
	for v, i in CLASSES {
		if d := abs(v - pct); d < bd { best, bd = i + 1, d }
	}
	return best
}

@(private = "file")
toolkit_style :: proc(s: style.Font_Style) -> font.Font_Style {
	switch s {
	case .Normal: return .Normal
	case .Italic: return .Italic
	case .Oblique: return .Oblique
	}
	return .Normal
}

// The system face of family `name` (lower case), aliases included. 0: no such family.
@(private = "file")
system_face :: proc(pf: ^Page_Fonts, name: string, req: ^lay.Font_Request) -> font.Font_Id {
	target := name
	if !font.has_system_family(pf.state, target) {
		found := false
		for a in ALIASES { if a[0] == name { target = a[1]; found = true; break } }
		if !found { return 0 }
	}
	id, _ := font.load_system(pf.state, target, int(req.weight), toolkit_style(req.style), stretch_class(req.stretch))
	return id
}

// CSS Fonts 4 §5.2: the distance of a face's descriptors from the request, compared stretch first, then style, then
// weight (smaller is better).
@(private = "file")
match_score :: proc(w: Web_Face, req: ^lay.Font_Request) -> [3]f32 {
	s: [3]f32
	// stretch: inside the range is 0; else narrower first for normal or narrower requests, wider first otherwise
	st := req.stretch
	switch {
	case st >= w.stretch[0] && st <= w.stretch[1]:
	case st <= 100: s[0] = w.stretch[1] < st ? st - w.stretch[1] : 1000 + w.stretch[0] - st
	case: s[0] = w.stretch[0] > st ? w.stretch[0] - st : 1000 + st - w.stretch[1]
	}
	// style: italic -> italic, oblique, normal; oblique -> oblique, italic, normal; normal -> normal, oblique, italic
	order: [3]style.Font_Style
	switch req.style {
	case .Italic: order = {.Italic, .Oblique, .Normal}
	case .Oblique: order = {.Oblique, .Italic, .Normal}
	case .Normal: order = {.Normal, .Oblique, .Italic}
	}
	for o, i in order { if w.style == o { s[1] = f32(i); break } }
	// weight
	d := f32(req.weight)
	lo, hi := f32(w.weight[0]), f32(w.weight[1])
	switch {
	case d >= lo && d <= hi:
	case d >= 400 && d <= 500:
		// up to 500 first, then lighter, then heavier
		if lo > d && lo <= 500 { s[2] = lo - d } else if hi < d { s[2] = 1000 + d - hi } else { s[2] = 2000 + lo - d }
	case d < 400:
		if hi < d { s[2] = d - hi } else { s[2] = 1000 + lo - d }
	case:
		if lo > d { s[2] = lo - d } else { s[2] = 1000 + d - hi }
	}
	return s
}

@(private = "file")
less :: proc(a, b: [3]f32) -> bool {
	for i in 0 ..< 3 { if a[i] != b[i] { return a[i] < b[i] } }
	return false
}

// The cascade entries of web family `name` for the request (none when the scope has no face of that name).
@(private = "file")
web_entries :: proc(pf: ^Page_Fonts, name: string, req: ^lay.Font_Request, out: ^[dynamic]font.Cascade_Entry) -> bool {
	best := -1
	best_s: [3]f32
	for w, i in pf.web {
		if w.family != name || (w.owner != pf.scope && w.owner != nil) { continue }
		s := match_score(w, req)
		if best < 0 || less(s, best_s) { best, best_s = i, s }
	}
	if best < 0 { return false }
	b := pf.web[best]
	for w in pf.web {
		if w.family != name || (w.owner != pf.scope && w.owner != nil) { continue }
		if w.weight != b.weight || w.style != b.style || w.stretch != b.stretch { continue }
		id := w.id
		// variable axes (CSS Fonts 4 §6.3): font-weight and font-stretch clamped to the face's descriptors, italic and
		// oblique on ital / slnt (the default oblique angle, 14deg, leans right: slnt -14), then
		// font-variation-settings
		vars := make([dynamic]font.Axis_Value, 0, 4, context.temp_allocator)
		if w.wght { append(&vars, font.Axis_Value{{'w', 'g', 'h', 't'}, f32(clamp(req.weight, w.weight[0], w.weight[1]))}) }
		if w.wdth { append(&vars, font.Axis_Value{{'w', 'd', 't', 'h'}, clamp(req.stretch, w.stretch[0], w.stretch[1])}) }
		slanted := false
		if req.style != .Normal && w.style == .Normal {
			if req.style == .Italic && w.ital { append(&vars, font.Axis_Value{{'i', 't', 'a', 'l'}, 1}); slanted = true } else if w.slnt { append(&vars, font.Axis_Value{{'s', 'l', 'n', 't'}, -14}); slanted = true }
		}
		for v in req.variations { append(&vars, font.Axis_Value{v.tag, v.value}) }
		if len(vars) > 0 {
			vid := font.with_variations(pf.state, id, vars[:])
			if vid != id { own_web(pf, w, vid); id = vid }
		}
		// synthesis (CSS font-synthesis: weight and style, allowed): bold for 600 and above when the face is lighter,
		// a slant when italic or oblique is asked of an upright face
		bold := req.weight >= 600 && w.weight[1] < 600
		slant := req.style != .Normal && w.style == .Normal && !slanted
		if bold || slant {
			sid := font.with_simulations(pf.state, id, bold, slant)
			if sid != id { own_web(pf, w, sid); id = sid }
		}
		// a color font whose color format this system cannot draw (COLR v1 before Windows 11 22H2): its characters come
		// from the next faces and the system fallback (the system emoji font) rather than as outlines
		if !font.color_renderable(pf.state, id) { continue }
		append(out, font.Cascade_Entry{font = id, ranges = w.ranges})
	}
	return true
}

@(private = "file")
generic_name :: proc(pf: ^Page_Fonts, name: string, settings: ^style.Settings) -> string {
	switch name {
	case "emoji": return strings.to_lower(pf.emoji, context.temp_allocator)
	case "math": return strings.to_lower(pf.math, context.temp_allocator)
	case "fangsong": return strings.to_lower(pf.fangsong, context.temp_allocator)
	}
	if settings != nil {
		if g := style.generic_family(settings, name); g != "" { return strings.to_lower(g, context.temp_allocator) }
	}
	return name
}

// The cascade for a font request of the layout.
resolve_request :: proc(pf: ^Page_Fonts, req: ^lay.Font_Request, settings: ^style.Settings) -> font.Font_Id {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_u64(&sb, u64(uintptr(pf.scope)))
	strings.write_byte(&sb, '|')
	for f in req.families { strings.write_string(&sb, f); strings.write_byte(&sb, ',') }
	strings.write_byte(&sb, '|')
	strings.write_int(&sb, int(req.weight))
	strings.write_byte(&sb, '|')
	strings.write_int(&sb, int(req.style))
	strings.write_byte(&sb, '|')
	strings.write_int(&sb, int(req.stretch * 10))
	for f in req.features { tag := f.tag; strings.write_byte(&sb, '|'); strings.write_string(&sb, string(tag[:])); strings.write_int(&sb, int(f.value)) }
	for v in req.variations { tag := v.tag; strings.write_byte(&sb, '~'); strings.write_string(&sb, string(tag[:])); strings.write_int(&sb, int(v.value * 100)) }
	key := strings.to_string(sb)
	if id, ok := pf.resolved[key]; ok { return id }

	entries := make([dynamic]font.Cascade_Entry, 0, 4, context.temp_allocator)
	web := false
	for f in req.families {
		name := generic_name(pf, strings.to_lower(strings.trim_space(f), context.temp_allocator), settings)
		if web_entries(pf, name, req, &entries) { web = true; continue }
		if id := system_face(pf, name, req); id != 0 {
			if len(req.variations) > 0 {
				// a variable system font (Bahnschrift, Segoe UI Variable...): font-variation-settings on its instance
				vars := make([]font.Axis_Value, len(req.variations), context.temp_allocator)
				for v, i in req.variations { vars[i] = {v.tag, v.value} }
				id = font.with_variations(pf.state, id, vars)
			}
			append(&entries, font.Cascade_Entry{font = id})
		}
	}
	if settings != nil {
		if g := style.generic_family(settings, settings.default_generic); g != "" {
			if id := system_face(pf, strings.to_lower(g, context.temp_allocator), req); id != 0 { append(&entries, font.Cascade_Entry{font = id}) }
		}
	}
	if pf.ui != 0 { append(&entries, font.Cascade_Entry{font = pf.ui}) }
	// a face listed twice adds nothing the second time (unless it has a unicode-range)
	dedup := make([dynamic]font.Cascade_Entry, 0, len(entries), context.temp_allocator)
	outer: for e in entries {
		if len(e.ranges) == 0 { for d in dedup { if d.font == e.font && len(d.ranges) == 0 { continue outer } } }
		append(&dedup, e)
	}
	feats := make([]font.Feature, len(req.features), context.temp_allocator)
	for f, i in req.features { feats[i] = {f.tag, f.value} }
	id := font.cascade(pf.state, dedup[:], feats)
	if web { own_cascade(pf, id, dedup[:]) }   // (with the shared faces it uses: web_font_faces.odin)
	pf.resolved[strings.clone(key)] = id
	return id
}

// The cascade for a font-family list, weight and slant (no stretch, no features).
resolve_font :: proc(pf: ^Page_Fonts, families: []string, weight: u16, italic: bool, settings: ^style.Settings) -> font.Font_Id {
	req := lay.Font_Request{families = families, weight = weight, italic = italic, style = italic ? .Italic : .Normal, stretch = 100}
	return resolve_request(pf, &req, settings)
}

////////////////////////////////
// Start-up: fonts loaded while the renderer starts

// The renderer's start-up (device, shaders) is the longest step before the first frame and touches no font. Meanwhile a
// thread loads the interface fonts and the faces the first page most likely asks for (the generic families, regular
// and bold) through DirectWrite. The font state belongs to that thread until fonts_preload_finish.
Font_Preload :: struct {
	th:       ^host.Thread,
	fonts:    ^font.State,
	generics: [dynamic]string,
	ui_font, icons: font.Font_Id,
	ui_ok, icons_ok: bool,
}

@(private = "file")
load_ui_fonts :: proc(fp: ^Font_Preload) {
	fp.ui_font, fp.ui_ok = font.load_system(fp.fonts, "Segoe UI")
	if !fp.ui_ok { fp.ui_font, fp.ui_ok = font.load_embedded(fp.fonts, font.FALLBACK_UI_DATA) }
	fp.icons, fp.icons_ok = font.load_embedded(fp.fonts, ui.ICON_FONT_DATA)
}

fonts_preload_start :: proc(app: ^App) -> ^Font_Preload {
	fp := new(Font_Preload)
	fp.fonts = &app.fonts
	ss := style.settings_from_prefs(&app.prefs)
	defer style.settings_destroy(&ss)
	for g in ([]string{ss.default_generic, "sans-serif", "serif", "monospace"}) {
		name := style.generic_family(&ss, g)
		if name == "" { continue }
		lower := strings.to_lower(name)
		dup := false
		for x in fp.generics { if x == lower { dup = true } }
		if dup { delete(lower) } else { append(&fp.generics, lower) }
	}
	fp.th = host.thread_start(proc(data: rawptr) {
		fp := (^Font_Preload)(data)
		load_ui_fonts(fp)
		for name in fp.generics {
			for weight in ([]int{400, 700}) { _, _ = font.load_system(fp.fonts, name, weight) }
		}
	}, fp, name = "wren-font-preload")   // nil (no thread): fonts_preload_finish does the work
	return fp
}

// Joins the thread (or does its work here if it could not start). The interface fonts go to `app`.
fonts_preload_finish :: proc(app: ^App, fp: ^Font_Preload) -> (ok: bool) {
	if fp.th != nil { host.thread_join(fp.th) } else { load_ui_fonts(fp) }
	app.ui_font, app.icons = fp.ui_font, fp.icons
	return fp.ui_ok && fp.icons_ok
}

// After page_render_init: frees `fp` (the faces it loaded stay in the font state, shared by every request).
fonts_preload_adopt :: proc(pf: ^Page_Fonts, fp: ^Font_Preload) {
	pf.scanned = true
	for g in fp.generics { delete(g) }
	delete(fp.generics)
	free(fp)
}

// Faces the page downloaded (@font-face) join the font registry of the painter; the layout is redone with them. A new
// page in the tab drops the faces of the one before, unless that page is still on screen while the new one prepares
// its first paint (first_paint.odin): its faces then go with the held frame (`&t.hold`, dropped by hold_release).
// font-display is the page's business (page/fonts.odin): a face too late for its period never becomes ready.
adopt_web_fonts :: proc(t: ^Tab) {
	pf := &page_render.fonts
	if t.web_font_page != rawptr(t.page) {
		if t.hold.active && t.web_font_page != nil && rawptr(t.hold.page) == t.web_font_page {
			page_fonts_drop(pf, &t.hold)
			page_fonts_transfer(pf, t, &t.hold)
		}
		page_fonts_drop(pf, t)
		t.web_font_page, t.web_fonts = t.page, 0
	}
	page_fonts_scope(pf, t)
	ready := page.fonts_ready(t.page)
	for t.web_fonts < len(ready) {
		f := ready[t.web_fonts]
		t.web_fonts += 1
		if len(f.data) == 0 { continue }
		if !register_web_face(pf, t, f) { tab_log(t, .Warn, strings.concatenate({"font \"", f.family, "\" could not be read"}, context.temp_allocator)) }
	}
	blocking_text_update(pf, t)   // text still waiting for its font is drawn invisible (web_font_faces.odin)
}

////////////////////////////////
// The text interface the layout engine measures with

@(private = "file")
Text_Ctx :: struct {
	fonts:   ^Page_Fonts,
	measure: ^Measure,
	style:   ^style.Settings,
}

@(private = "file")
text_ctx: Text_Ctx

page_text_api :: proc(pf: ^Page_Fonts, m: ^Measure, settings: ^style.Settings) -> lay.Text_Api {
	text_ctx = Text_Ctx{pf, m, settings}
	return lay.Text_Api{
		user = &text_ctx,
		font = proc(user: rawptr, families: []string, weight: u16, italic: bool) -> lay.Font {
			t := (^Text_Ctx)(user)
			return lay.Font(resolve_font(t.fonts, families, weight, italic, t.style))
		},
		font_request = proc(user: rawptr, req: ^lay.Font_Request) -> lay.Font {
			t := (^Text_Ctx)(user)
			return lay.Font(resolve_request(t.fonts, req, t.style))
		},
		width = proc(user: rawptr, f: lay.Font, size: f32, text: string) -> f32 {
			t := (^Text_Ctx)(user)
			return measure_width(t.measure, t.fonts.state, font.Font_Id(f), size, text)
		},
		metrics = proc(user: rawptr, f: lay.Font, size: f32) -> lay.Font_Metrics {
			t := (^Text_Ctx)(user)
			m := font.metrics(t.fonts.state, font.Font_Id(f), size)
			return {ascent = m.ascent, descent = m.descent, x_height = m.x_height, line_height = m.line_height, line_gap = m.line_gap}
		},
		fallback_metrics = proc(user: rawptr, f: lay.Font, size: f32, text: string, out: []lay.Font_Metrics) -> int {
			t := (^Text_Ctx)(user)
			return fallback_face_metrics(t.fonts.state, font.Font_Id(f), size, text, out)
		},
		bidi = proc(user: rawptr, text: string, rtl: bool, levels: []u8) {
			t := (^Text_Ctx)(user)
			lv := font.bidi_levels(t.fonts.state, text, rtl ? .Rtl : .Ltr, context.temp_allocator)
			copy(levels, lv)
		},
		width_spaced = proc(user: rawptr, f: lay.Font, size: f32, text: string, letter_spacing: f32) -> f32 {
			t := (^Text_Ctx)(user)
			return font.measure(t.fonts.state, font.Font_Id(f), size, text, {letter_spacing = letter_spacing})
		},
		line_break = proc(user: rawptr, text: string) -> int {
			t := (^Text_Ctx)(user)
			for b in font.line_breaks(t.fonts.state, text, context.temp_allocator) { if b.at > 0 { return b.at } }
			return -1
		},
		caret_x = proc(user: rawptr, f: lay.Font, size: f32, text: string, run: lay.Text_Run, index: int) -> f32 {
			t := (^Text_Ctx)(user)
			sh := font.shape(t.fonts.state, font.Font_Id(f), size, text, run_shape_options(run), context.temp_allocator)
			return font.caret_x(sh, text, index)
		},
		hit_index = proc(user: rawptr, f: lay.Font, size: f32, text: string, run: lay.Text_Run, x: f32) -> int {
			t := (^Text_Ctx)(user)
			sh := font.shape(t.fonts.state, font.Font_Id(f), size, text, run_shape_options(run), context.temp_allocator)
			return font.hit_index(sh, text, x)
		},
		concurrent = true,   // the toolkit measures, shapes and analyses from any thread
	}
}

// Metrics of the faces, other than the first of cascade `id`, that the glyphs of `text` come from (Text_Api
// fallback_metrics: line-height: normal makes room for them). Each face once, at most len(out).
fallback_face_metrics :: proc(s: ^font.State, id: font.Font_Id, size: f32, text: string, out: []lay.Font_Metrics) -> int {
	if len(text) == 0 || len(out) == 0 { return 0 }
	first := font.primary_face(s, id)
	sh := font.shape(s, id, size, text, {one_run = true}, context.temp_allocator)
	seen: [8]font.Font_Id
	n := 0
	outer: for g in sh.glyphs {
		if g.face == first { continue }
		for k in seen[:min(n, len(seen))] { if k == g.face { continue outer } }
		if n >= len(out) || n >= len(seen) { break }
		seen[n] = g.face
		m := font.metrics(s, g.face, size)
		out[n] = {ascent = m.ascent, descent = m.descent, x_height = m.x_height, line_height = m.line_height, line_gap = m.line_gap}
		n += 1
	}
	return n
}

// The shaping of a text fragment as the painter does it (render.odin text_shape_options).
run_shape_options :: proc(run: lay.Text_Run) -> font.Shape_Options {
	return font.Shape_Options{
		one_run = true, direction = run.rtl ? .Rtl : .Ltr,
		letter_spacing = run.letter_spacing, word_spacing = run.word_spacing, justify = run.justify,
	}
}
