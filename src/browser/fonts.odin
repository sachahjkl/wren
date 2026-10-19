package browser

import "core:strings"
import win "core:sys/windows"
import "toolkit:font"
import "toolkit:platform"
import "toolkit:ui"
import "wb:host"
import lay "wb:layout"
import "wb:style"

// Page fonts: CSS family names to font files. The Windows font registry (HKLM and HKCU
// "SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts": "Arial Bold (TrueType)" -> "arialbd.ttf") lists every installed
// face; a built-in table of the usual Windows families stands in when it cannot be read. Generic families (serif,
// monospace...) map to concrete ones through the `font.family.*` preferences. Faces load on first use; a family that is
// missing, or a weight / slant it lacks, falls back to the nearest face of the family, then to the next family of the
// list, then to the default generic family, then to the UI font. Web fonts (@font-face, loaded elsewhere) join with
// `register_face` and win over system faces of the same name.

Face_File :: struct {
	path:   string,   // owned
	weight: u16,
	italic: bool,
}

Font_Family :: struct {
	faces: [dynamic]Face_File,
}

Web_Face :: struct {
	family: string,   // owned, lower case
	weight: u16,
	italic: bool,
	id:     font.Font_Id,
}

Page_Fonts :: struct {
	state:    ^font.State,
	ui:       font.Font_Id,
	families: map[string]^Font_Family,   // lower-case family name
	loaded:   map[string]font.Font_Id,   // path -> face (0: could not be loaded)
	web:      [dynamic]Web_Face,
	resolved: map[string]font.Font_Id,   // "family,family|weight|italic" -> face
	scanned:  bool,
}

@(private = "file")
Builtin :: struct { name: string, files: [4]string }   // regular, bold, italic, bold italic

@(private = "file")
BUILTIN := [?]Builtin{
	{"segoe ui", {"segoeui.ttf", "segoeuib.ttf", "segoeuii.ttf", "segoeuiz.ttf"}},
	{"times new roman", {"times.ttf", "timesbd.ttf", "timesi.ttf", "timesbi.ttf"}},
	{"arial", {"arial.ttf", "arialbd.ttf", "ariali.ttf", "arialbi.ttf"}},
	{"consolas", {"consola.ttf", "consolab.ttf", "consolai.ttf", "consolaz.ttf"}},
	{"georgia", {"georgia.ttf", "georgiab.ttf", "georgiai.ttf", "georgiaz.ttf"}},
	{"verdana", {"verdana.ttf", "verdanab.ttf", "verdanai.ttf", "verdanaz.ttf"}},
	{"tahoma", {"tahoma.ttf", "tahomabd.ttf", "", ""}},
	{"courier new", {"cour.ttf", "courbd.ttf", "couri.ttf", "courbi.ttf"}},
	{"comic sans ms", {"comic.ttf", "comicbd.ttf", "comici.ttf", "comicz.ttf"}},
	{"impact", {"impact.ttf", "", "", ""}},
	{"trebuchet ms", {"trebuc.ttf", "trebucbd.ttf", "trebucit.ttf", "trebucbi.ttf"}},
	{"calibri", {"calibri.ttf", "calibrib.ttf", "calibrii.ttf", "calibriz.ttf"}},
	{"cambria", {"cambria.ttc", "cambriab.ttf", "cambriai.ttf", "cambriaz.ttf"}},
	{"candara", {"candara.ttf", "candarab.ttf", "candarai.ttf", "candaraz.ttf"}},
	{"palatino linotype", {"pala.ttf", "palab.ttf", "palai.ttf", "palabi.ttf"}},
	{"lucida console", {"lucon.ttf", "", "", ""}},
	{"cascadia mono", {"CascadiaMono.ttf", "", "", ""}},
	{"cascadia code", {"CascadiaCode.ttf", "", "", ""}},
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
}

page_fonts_init :: proc(pf: ^Page_Fonts, state: ^font.State, ui: font.Font_Id) {
	pf.state, pf.ui = state, ui
	pf.families = make(map[string]^Font_Family)
	pf.loaded = make(map[string]font.Font_Id)
	pf.resolved = make(map[string]font.Font_Id)
}

page_fonts_destroy :: proc(pf: ^Page_Fonts) {
	for name, fam in pf.families {
		for f in fam.faces { delete(f.path) }
		delete(fam.faces)
		free(fam)
		delete(name)
	}
	delete(pf.families)
	for path in pf.loaded { delete(path) }
	delete(pf.loaded)
	for w in pf.web { delete(w.family) }
	delete(pf.web)
	page_fonts_forget(pf)
	delete(pf.resolved)
	pf^ = {}
}

// Drops the resolution cache (preferences changed, a face was registered).
page_fonts_forget :: proc(pf: ^Page_Fonts) {
	for k in pf.resolved { delete(k) }
	clear(&pf.resolved)
}

// A web font face (already loaded into the font state) for `family`. It is preferred over a system face of that name.
register_face :: proc(pf: ^Page_Fonts, family: string, weight: u16, italic: bool, id: font.Font_Id) {
	append(&pf.web, Web_Face{strings.to_lower(strings.trim_space(family)), weight, italic, id})
	page_fonts_forget(pf)
}

@(private = "file")
add_face :: proc(pf: ^Page_Fonts, family, path: string, weight: u16, italic: bool) {
	name := strings.to_lower(strings.trim_space(family), context.temp_allocator)
	if name == "" { return }
	fam, ok := pf.families[name]
	if !ok {
		fam = new(Font_Family)
		pf.families[strings.clone(name)] = fam
	}
	for f in fam.faces { if f.weight == weight && f.italic == italic { return } }
	append(&fam.faces, Face_File{strings.clone(path), weight, italic})
}

// Style words at the end of a registry face name: "Segoe UI Semibold Italic".
@(private = "file")
split_style :: proc(name: string) -> (family: string, weight: u16, italic: bool) {
	WORDS :: [?]struct { w: string, weight: u16, italic: bool }{
		{"italic", 0, true}, {"oblique", 0, true}, {"bold", 700, false}, {"semibold", 600, false}, {"demibold", 600, false},
		{"light", 300, false}, {"semilight", 350, false}, {"extralight", 200, false}, {"thin", 100, false},
		{"black", 900, false}, {"heavy", 900, false}, {"extrabold", 800, false}, {"medium", 500, false}, {"regular", 400, false},
		{"normal", 400, false},
	}
	words := WORDS
	family = strings.trim_space(name)
	weight = 400
	for {
		i := strings.last_index_byte(family, ' ')
		if i < 0 { break }
		last := strings.to_lower(family[i + 1:], context.temp_allocator)
		hit := false
		for w in words {
			if last == w.w {
				if w.italic { italic = true } else if w.weight != 400 || weight == 400 { weight = w.weight }
				hit = true
				break
			}
		}
		if !hit { break }
		family = strings.trim_space(family[:i])
	}
	return
}

@(private = "file")
scan_registry_key :: proc(pf: ^Page_Fonts, root: win.HKEY, fonts_dir: string) {
	key: win.HKEY
	sub := win.utf8_to_wstring(`SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts`, context.temp_allocator)
	if win.RegOpenKeyExW(root, sub, 0, win.KEY_READ, &key) != 0 { return }
	defer win.RegCloseKey(key)
	name_buf: [512]u16
	data_buf: [1024]u16
	for i: u32 = 0; i < 100_000; i += 1 {
		nlen := u32(len(name_buf))
		dlen := u32(size_of(data_buf))
		typ: u32
		r := win.RegEnumValueW(key, i, &name_buf[0], &nlen, nil, &typ, cast(win.LPBYTE)&data_buf[0], &dlen)
		if r != 0 { break }
		if typ != win.REG_SZ && typ != win.REG_EXPAND_SZ { continue }
		name, e1 := win.wstring_to_utf8(win.wstring(&name_buf[0]), int(nlen), context.temp_allocator)
		file, e2 := win.wstring_to_utf8(win.wstring(&data_buf[0]), int(dlen / 2), context.temp_allocator)
		if e1 != nil || e2 != nil { continue }
		file = strings.trim_right(file, "\x00")
		lower := strings.to_lower(file, context.temp_allocator)
		if !strings.has_suffix(lower, ".ttf") && !strings.has_suffix(lower, ".ttc") && !strings.has_suffix(lower, ".otf") { continue }
		path := file
		if !strings.contains(file, `\`) && !strings.contains(file, "/") { path = strings.concatenate({fonts_dir, `\`, file}, context.temp_allocator) }
		// "Family Style (TrueType)"; collections list their families joined by " & "
		if p := strings.last_index_byte(name, '('); p > 0 { name = name[:p] }
		for part in strings.split(name, "&", context.temp_allocator) {
			fam, weight, italic := split_style(part)
			add_face(pf, fam, path, weight, italic)
			// "Arial Black", "Segoe UI Semibold" are also family names of their own
			if full := strings.trim_space(part); len(full) > len(fam) { add_face(pf, full, path, weight, italic) }
		}
	}
}

@(private = "file")
scan :: proc(pf: ^Page_Fonts) {
	if pf.scanned { return }
	pf.scanned = true
	fonts_dir := strings.trim_right(platform.system_font_path(""), `\`)
	scan_registry_key(pf, win.HKEY_LOCAL_MACHINE, fonts_dir)
	scan_registry_key(pf, win.HKEY_CURRENT_USER, fonts_dir)
	// families the registry did not give (or an unreadable registry): the usual files by name
	for b in BUILTIN {
		if _, ok := pf.families[b.name]; ok { continue }
		for f, i in b.files {
			if f == "" { continue }
			add_face(pf, b.name, platform.system_font_path(f), (i & 1) != 0 ? 700 : 400, (i & 2) != 0)
		}
	}
}

@(private = "file")
load_path :: proc(pf: ^Page_Fonts, path: string) -> font.Font_Id {
	if id, ok := pf.loaded[path]; ok { return id }
	id, ok := font.load_from_file(pf.state, path)
	if !ok { id = 0 }
	pf.loaded[strings.clone(path)] = id
	return id
}

// The face of `name` nearest to weight / slant (CSS Fonts §5.2, simplified), or 0.
@(private = "file")
pick_face :: proc(pf: ^Page_Fonts, name: string, weight: u16, italic: bool) -> font.Font_Id {
	best_web := -1
	best_d := max(int)
	for w, i in pf.web {
		if w.family != name { continue }
		d := abs(int(w.weight) - int(weight)) + (w.italic != italic ? 10_000 : 0)
		if d < best_d { best_d, best_web = d, i }
	}
	if best_web >= 0 { return pf.web[best_web].id }
	target := name
	if _, ok := pf.families[target]; !ok {
		for a in ALIASES { if a[0] == name { target = a[1]; break } }
	}
	fam, ok := pf.families[target]
	if !ok { return 0 }
	// try faces from the nearest match outwards until one loads
	tried := make([dynamic]int, 0, len(fam.faces), context.temp_allocator)
	for len(tried) < len(fam.faces) {
		bi, bd := -1, max(int)
		for f, i in fam.faces {
			skip := false
			for t in tried { if t == i { skip = true } }
			if skip { continue }
			d := abs(int(f.weight) - int(weight)) + (f.italic != italic ? 10_000 : 0)
			if d < bd { bd, bi = d, i }
		}
		if bi < 0 { break }
		append(&tried, bi)
		if id := load_path(pf, fam.faces[bi].path); id != 0 { return id }
	}
	return 0
}

// The face for a computed font-family list, weight and slant.
resolve_font :: proc(pf: ^Page_Fonts, families: []string, weight: u16, italic: bool, settings: ^style.Settings) -> font.Font_Id {
	scan(pf)
	sb := strings.builder_make(context.temp_allocator)
	for f in families { strings.write_string(&sb, f); strings.write_byte(&sb, ',') }
	strings.write_byte(&sb, '|')
	strings.write_int(&sb, int(weight))
	strings.write_byte(&sb, italic ? 'i' : 'n')
	key := strings.to_string(sb)
	if id, ok := pf.resolved[key]; ok { return id }
	id := font.Font_Id(0)
	for f in families {
		name := strings.to_lower(strings.trim_space(f), context.temp_allocator)
		if settings != nil {
			if g := style.generic_family(settings, name); g != "" { name = strings.to_lower(g, context.temp_allocator) }
		}
		if id = pick_face(pf, name, weight, italic); id != 0 { break }
	}
	if id == 0 && settings != nil {
		if g := style.generic_family(settings, settings.default_generic); g != "" { id = pick_face(pf, strings.to_lower(g, context.temp_allocator), weight, italic) }
	}
	if id == 0 { id = pf.ui }
	pf.resolved[strings.clone(key)] = id
	return id
}

////////////////////////////////
// Start-up: fonts loaded while the renderer starts

// The renderer's start-up (device, shaders) is the longest step before the first frame and touches no font. Meanwhile a
// thread loads the interface fonts, reads the font registry and loads the faces the first page most likely asks for
// (the generic families, regular and bold). The font state belongs to that thread until fonts_preload_finish.
Font_Preload :: struct {
	th:       ^host.Thread,
	fonts:    ^font.State,
	pf:       Page_Fonts,     // registry and faces loaded, adopted by page_render.fonts
	generics: [dynamic]string,
	ui_font, icons: font.Font_Id,
	ui_ok, icons_ok: bool,
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
		fp.ui_font, fp.ui_ok, _ = font.load_system_or_embedded(fp.fonts, platform.system_font_path("segoeui.ttf"), font.FALLBACK_UI_DATA)
		fp.icons, fp.icons_ok = font.load_embedded(fp.fonts, ui.ICON_FONT_DATA)
		page_fonts_init(&fp.pf, fp.fonts, fp.ui_font)
		scan(&fp.pf)
		for name in fp.generics {
			for weight in ([]u16{400, 700}) { _ = pick_face(&fp.pf, name, weight, false) }
		}
	}, fp)   // nil (no thread): fonts_preload_finish does the work
	return fp
}

// Joins the thread (or does its work here if it could not start). The interface fonts go to `app`.
fonts_preload_finish :: proc(app: ^App, fp: ^Font_Preload) -> (ok: bool) {
	if fp.th != nil {
		host.thread_join(fp.th)
	} else {
		fp.ui_font, fp.ui_ok, _ = font.load_system_or_embedded(fp.fonts, platform.system_font_path("segoeui.ttf"), font.FALLBACK_UI_DATA)
		fp.icons, fp.icons_ok = font.load_embedded(fp.fonts, ui.ICON_FONT_DATA)
	}
	app.ui_font, app.icons = fp.ui_font, fp.icons
	return fp.ui_ok && fp.icons_ok
}

// After page_render_init: the page fonts take over what the thread read and loaded. Frees `fp`.
fonts_preload_adopt :: proc(pf: ^Page_Fonts, fp: ^Font_Preload) {
	if fp.pf.scanned {
		for name, fam in pf.families { for f in fam.faces { delete(f.path) }; delete(fam.faces); free(fam); delete(name) }
		delete(pf.families)
		for path in pf.loaded { delete(path) }
		delete(pf.loaded)
		pf.families, pf.loaded, pf.scanned = fp.pf.families, fp.pf.loaded, true
		fp.pf.families, fp.pf.loaded = nil, nil
	}
	page_fonts_destroy(&fp.pf)
	for g in fp.generics { delete(g) }
	delete(fp.generics)
	free(fp)
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
		width = proc(user: rawptr, f: lay.Font, size: f32, text: string) -> f32 {
			t := (^Text_Ctx)(user)
			return measure_width(t.measure, t.fonts.state, font.Font_Id(f), size, text)
		},
		metrics = proc(user: rawptr, f: lay.Font, size: f32) -> lay.Font_Metrics {
			t := (^Text_Ctx)(user)
			m := font.metrics(t.fonts.state, font.Font_Id(f), size)
			g := font.glyph(t.fonts.state, font.Font_Id(f), size, 'x')
			xh := g.size.y > 0 ? -g.offset.y : size * 0.5
			return {ascent = m.ascent, descent = m.descent, x_height = xh}
		},
		concurrent = true,   // measure_width locks around the toolkit
	}
}
