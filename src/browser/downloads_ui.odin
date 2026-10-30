package browser

// What the user sees of the downloads (download.odin does them): about:downloads, a native view like about:history, and the
// toolbar's button with its drop-down. Both show the same rows: a file tile (its extension on a colour of its kind), the
// name, one line of what is going on (size, speed, time left; or where and when it was saved), and, while it runs, a progress
// bar: a gradient fill that eases toward the real figure, with a light band travelling over it, and a comet turning
// instead while the size is not announced. The button carries the same progress as a ring around its arrow, and a dot when
// something ended that has not been looked at.

import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"
import "toolkit:draw"
import "toolkit:font"
import "toolkit:platform"
import "toolkit:ui"
import "wb:base"
import "wb:host"
import "wb:i18n"

DOWNLOADS_URL :: "about:downloads"

is_downloads_address :: proc(a: string) -> bool { return a == DOWNLOADS_URL || strings.has_prefix(a, DOWNLOADS_URL + "#") }

Downloads_View :: struct {
	search:       ui.Text_Field,
	focus_search: bool,
	menu_id:      u64,     // the download whose menu is open
	popup_open:   bool,    // the button's drop-down was open last frame
}

dview: Downloads_View

downloads_ui_destroy :: proc() {
	ui.field_destroy(&dview.search)
	dview = {}
}

show_downloads :: proc(app: ^App, t: ^Tab, address: string) {
	base.scope_close(t.nav)
	t.nav = base.scope_make("navigation", t.scope)
	t.page, t.load, t.kind = nil, nil, .Downloads
	layout_reset(&t.layout)
	t.scroll_target = base.NIL_HANDLE
	console_reset(t)
	delete(t.url); t.url = strings.clone(address)
	delete(t.title); t.title = strings.clone(i18n.tr("Downloads"))
	set_status(t, DOWNLOADS_URL)
	address_set(app, t, address)
	dview.focus_search = true
	downloads_mark_seen()
}

// Ctrl+J, the menu: about:downloads in a new tab (or the tab already showing it).
open_downloads :: proc(app: ^App) {
	for x in tabs_all(app) {
		if x.kind == .Downloads { tab_reveal(app, x); return }
	}
	tab_open(app, DOWNLOADS_URL, origin = .User)
}

////////////////////////////////
// What a row says

@(private = "file")
dl_by_id :: proc(id: u64) -> ^Download {
	for d in dls.list { if d.id == id { return d } }
	return nil
}

@(private = "file")
dl_running :: proc(d: ^Download) -> bool { return d.state == .Receiving || d.state == .Saving }

@(private = "file")
dl_host :: proc(url: string) -> string {
	s := url
	if i := strings.index(s, "://"); i >= 0 { s = s[i + 3:] } else { return "" }
	if i := strings.index_any(s, "/?#"); i >= 0 { s = s[:i] }
	if i := strings.last_index_byte(s, '@'); i >= 0 { s = s[i + 1:] }
	return s
}

// "8 s", "1 min 20 s", "2 h 5 min".
@(private = "file")
dl_duration :: proc(secs: f64) -> string {
	s := int(math.ceil(secs))
	switch {
	case s < 60:   return fmt.tprintf("%d s", max(s, 1))
	case s < 3600: return fmt.tprintf("%d min %d s", s / 60, s % 60)
	}
	return fmt.tprintf("%d h %d min", s / 3600, (s % 3600) / 60)
}

@(private = "file")
dl_speed_of :: proc(d: ^Download) -> f64 {
	if d.state != .Receiving || dl_now_ms() - d.sample_ms > 2500 { return 0 }   // (nothing came for a while: stalled)
	return d.speed
}

@(private = "file")
dl_status :: proc(d: ^Download) -> string {
	switch d.state {
	case .Receiving:
		if d.asking { return "Choose where to save it\u2026" }
		sp := dl_speed_of(d)
		if d.total > 0 {
			s := fmt.tprintf("%s of %s", human_bytes(d.received), human_bytes(d.total))
			if sp > 0 { s = fmt.tprintf("%s \u00b7 %s/s \u00b7 %s left", s, human_bytes(i64(sp)), dl_duration(f64(d.total - d.received) / sp)) }
			return s
		}
		return sp > 0 ? fmt.tprintf("%s \u00b7 %s/s", human_bytes(d.received), human_bytes(i64(sp))) : human_bytes(d.received)
	case .Saving: return "Finishing\u2026"
	case .Done:
		if !download_file_present(d) { return "Deleted or moved" }
		parts := make([dynamic]string, context.temp_allocator)
		if h := dl_host(d.url); h != "" { append(&parts, h) }
		append(&parts, human_bytes(d.size))
		lt := local_time(d.done_ms)
		append(&parts, fmt.tprintf("%02d:%02d", lt.hour, lt.minute))
		return strings.join(parts[:], " \u00b7 ", context.temp_allocator)
	case .Failed:    return d.error != "" ? safe_label(d.error, 90) : "Failed"
	case .Cancelled: return "Cancelled"
	}
	return ""
}

////////////////////////////////
// The file tile

Dl_Kind :: enum u8 { Other, Archive, Document, Image, Media, Program }

@(private = "file")
dl_kind_of :: proc(name: string) -> Dl_Kind {
	switch strings.to_lower(strings.trim_left(filepath.ext(name), "."), context.temp_allocator) {
	case "zip", "rar", "7z", "gz", "tgz", "tar", "xz", "bz2", "zst": return .Archive
	case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "odt", "ods", "csv", "epub", "md", "json": return .Document
	case "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "ico", "tif", "tiff", "avif", "heic": return .Image
	case "mp3", "wav", "flac", "ogg", "opus", "m4a", "aac", "mp4", "mkv", "avi", "mov", "webm", "m4v": return .Media
	case "exe", "msi", "bat", "cmd", "ps1", "apk", "dmg", "deb", "rpm", "iso", "appx", "msix": return .Program
	}
	return .Other
}

@(private = "file")
dl_kind_color :: proc(k: Dl_Kind) -> draw.Color {
	c: draw.Color
	switch k {
	case .Archive:  c = {0.96, 0.72, 0.24, 1}
	case .Document: c = {0.96, 0.42, 0.40, 1}
	case .Image:    c = {0.32, 0.80, 0.52, 1}
	case .Media:    c = {0.72, 0.54, 0.96, 1}
	case .Program:  c = {0.38, 0.66, 1.00, 1}
	case .Other:    c = {0.62, 0.68, 0.80, 1}
	}
	return ui.tuned(c)
}

Dl_Tile :: struct {
	app:   ^App,
	ext:   string,
	color: draw.Color,
	dim:   bool,       // the file is gone
	bad:   bool,       // failed or cancelled
}

@(private = "file")
dl_tile_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Dl_Tile)(user)
	r := b.rect
	s := min(r.max.x - r.min.x, r.max.y - r.min.y)
	c := draw.rect_center(r)
	sq := draw.Rect{{math.round(c.x - s * 0.5), math.round(c.y - s * 0.5)}, {}}
	sq.max = sq.min + {s, s}
	col := d.bad ? ui.tuned(draw.Color{0.96, 0.42, 0.40, 1}) : d.color
	fade: f32 = d.dim ? 0.45 : 1
	fill, edge := col, col
	fill.a, edge.a = 0.17 * fade, 0.5 * fade
	draw.rect(dc, sq, fill, s * 0.26)
	draw.rect(dc, sq, edge, s * 0.26, max(1, math.round(ui.scale())))
	// the extension, as big as the tile lets it be
	size := s * (len(d.ext) > 3 ? 0.27 : 0.33)
	tw := font.text_width(&d.app.fonts, d.app.ui_font, size, d.ext)
	txt := col
	txt.a = fade
	draw.text(dc, d.app.ui_font, size, {math.round(c.x - tw * 0.5), math.round(c.y + size * 0.36)}, txt, d.ext)
	if d.bad {
		// a small cross knocked over the corner: it did not come
		dot := s * 0.2
		dr := draw.Rect{{sq.max.x - dot * 1.1, sq.max.y - dot * 1.1}, {sq.max.x + dot * 0.2, sq.max.y + dot * 0.2}}
		draw.rect(dc, dr, col, dot)
	}
}

@(private = "file")
dl_tile :: proc(app: ^App, d: ^Download, size: f32) {
	t := ui.frame_new(Dl_Tile)
	ext := strings.to_upper(strings.trim_left(filepath.ext(d.name), "."), context.temp_allocator)
	if len(ext) > 4 { ext = ext[:4] }
	t^ = {app = app, ext = ext != "" ? ext : "FILE", color = dl_kind_color(dl_kind_of(d.name)),
		dim = d.state == .Done && d.missing, bad = d.state == .Failed || d.state == .Cancelled}
	ui.next({width = ui.px(size), height = ui.px(size)})
	ui.custom(fmt.tprintf("###dlt_%d", d.id), dl_tile_draw, t)
}

////////////////////////////////
// The progress bar

Dl_Bar :: struct {
	shown:  f32,     // 0..1, eased
	unknown: bool,   // no size announced: a comet runs
	now_ms: f64,
	accent, light, track: draw.Color,
}

@(private = "file")
dl_bar_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Dl_Bar)(user)
	r := b.rect
	w, h := r.max.x - r.min.x, r.max.y - r.min.y
	rad := h * 0.5
	draw.rect(dc, r, d.track, rad)
	if w <= 0 { return }
	fill: draw.Rect
	if d.unknown {
		seg := w * 0.34
		phase := f32(math.mod(d.now_ms, 1500) / 1500)
		e := phase * phase * (3 - 2 * phase)
		x := math.lerp(-seg, w, e)
		fill = {{r.min.x + max(0, x), r.min.y}, {r.min.x + min(w, x + seg), r.max.y}}
		if fill.max.x <= fill.min.x { return }
	} else {
		done := max(h, w * clamp(d.shown, 0, 1))
		fill = {r.min, {r.min.x + done, r.max.y}}
	}
	fw := fill.max.x - fill.min.x
	// a halo of the accent under the fill, two layers so it fades
	halo := d.accent
	halo.a = 0.10
	draw.rect(dc, {{fill.min.x, r.min.y - h * 0.7}, {fill.max.x, r.max.y + h * 0.7}}, halo, rad + h * 0.7)
	halo.a = 0.16
	draw.rect(dc, {{fill.min.x, r.min.y - h * 0.3}, {fill.max.x, r.max.y + h * 0.3}}, halo, rad + h * 0.3)
	stops := [3]draw.Gradient_Stop{{color = d.accent, pos = 0}, {color = draw.mix(d.accent, d.light, 0.55), pos = 0.65}, {color = d.light, pos = 1}}
	draw.gradient(dc, fill, draw.Gradient{kind = .Linear, start = {0, 0}, end = {fw, 0}, stops = stops[:]}, {rad, rad, rad, rad})
	draw.push_clip_rounded(dc, fill, {rad, rad, rad, rad})
	// a gloss on the upper half, like a tube of light
	gloss := [2]draw.Gradient_Stop{{color = {1, 1, 1, 0.34}, pos = 0}, {color = {1, 1, 1, 0}, pos = 1}}
	draw.gradient(dc, {fill.min, {fill.max.x, fill.min.y + h * 0.62}}, draw.Gradient{kind = .Linear, start = {0, 0}, end = {0, h * 0.62}, stops = gloss[:]})
	// a light band travelling over the fill
	bw := max(h * 5, fw * 0.28)
	pos := f32(math.mod(d.now_ms, 1500) / 1500) * (fw + bw) - bw
	band := draw.Rect{{fill.min.x + max(pos, 0), fill.min.y}, {fill.min.x + min(pos + bw, fw), fill.max.y}}
	if band.max.x > band.min.x {
		hi := [3]draw.Gradient_Stop{{color = {1, 1, 1, 0}, pos = 0}, {color = {1, 1, 1, 0.42}, pos = 0.5}, {color = {1, 1, 1, 0}, pos = 1}}
		bx := fill.min.x + pos
		draw.gradient(dc, band, draw.Gradient{kind = .Linear, start = {bx - band.min.x, 0}, end = {bx + bw - band.min.x, 0}, stops = hi[:]})
	}
	draw.pop_clip(dc)
	// a soft glow where the fill ends
	if !d.unknown && d.shown > 0.01 && d.shown < 0.995 {
		g := d.light
		g.a = 0.5
		draw.rect(dc, {{fill.max.x - h * 1.1, r.min.y - h * 0.25}, {fill.max.x + h * 0.5, r.max.y + h * 0.25}}, g, h)
	}
}

@(private = "file")
dl_bar :: proc(app: ^App, d: ^Download, height: f32) {
	b := ui.frame_new(Dl_Bar)
	frac: f32
	if d.state == .Saving { frac = 1 } else if d.total > 0 { frac = clamp(f32(f64(d.received) / f64(d.total)), 0, 1) }
	acc := ui.color("accent")
	trk := ui.color("text")   // the text's colour, faint: a track that shows on the page and on the drop-down alike
	trk.a = 0.14
	b^ = {unknown = d.state == .Receiving && d.total <= 0,
		now_ms = f64(host.now_ns(&app.loop)) / 1e6, accent = acc, light = draw.mix(acc, draw.Color{1, 1, 1, 1}, 0.4), track = trk}
	ui.next({width = ui.fill(), height = ui.px(height)})
	box := ui.custom(fmt.tprintf("###dlb_%d", d.id), dl_bar_draw, b)
	b.shown = ui.anim(ui.key_from_string(box.key, "shown"), frac, 9, 0)
	request_frames(app, 1)   // the band keeps moving
}

////////////////////////////////
// A row

Dl_Row_Act :: enum u8 { None, Open, Reveal, Cancel, Retry, Remove, Menu }

// One download. `w` < 0: the width of the parent. `compact`: the drop-down's row. The action asked for, if any.
@(private = "file")
dl_row :: proc(app: ^App, d: ^Download, w: f32, compact: bool) -> (act: Dl_Row_Act, at: draw.Rect) {
	em := ui.font_size()
	running := dl_running(d)
	h := em * (compact ? (running ? 4.1 : 3.3) : (running ? 5.1 : 4.2))
	ui.next({width = w < 0 ? ui.fill() : ui.px(w), height = ui.px(ui.dense(h)), axis = .X, cross = .Center, radius = em * 0.5, cursor = .Hand})
	ui.push_tags("list_row")
	row := ui.build_box({.Clickable, .Draw_Background, .Draw_Hot_Effects, .Hot_Within}, fmt.tprintf("###dlr_%d", d.id))
	ui.pop_tags()
	sig := ui.signal(row)
	hot := ui.hot_within(row.key)
	if ui.parent(row) {
		ui.spacer(ui.px(em * 0.7))
		dl_tile(app, d, em * (compact ? 2.3 : 3.0))
		ui.spacer(ui.px(em * 0.8))
		ui.next({width = ui.fill(), height = ui.pct(1)})
		if ui.column() {
			ui.spacer(ui.fill())
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.5))})
			if ui.row(.Center) {
				ui.next({width = ui.fill(), height = ui.pct(1)})
				ui.label(fmt.tprintf("%s###dln_%d", safe_label(d.state == .Done && d.path != "" ? filepath.base(d.path) : d.name, 120), d.id))
				if !compact && d.state == .Receiving && d.total > 0 && !d.asking {
					// the figure the bar stands for
					ui.next({width = ui.text_size(em * 0.5), height = ui.pct(1), font_size = em * 0.92})
					if ui.tags("weak") { ui.label(fmt.tprintf("%d %%###dlp_%d", int(d.received * 100 / max(d.total, 1)), d.id)) }
				}
			}
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.35)), font_size = em * 0.86})
			if ui.tags("weak") { ui.label(fmt.tprintf("%s###dls_%d", dl_status(d), d.id)) }
			if running {
				ui.spacer(ui.px(em * 0.45))
				dl_bar(app, d, em * (compact ? 0.45 : 0.6))
			}
			ui.spacer(ui.fill())
		}
		ui.spacer(ui.px(em * 0.6))
		switch {
		case running && d.state == .Receiving:
			if compact {
				if remove_cross(fmt.tprintf("###dlx_%d", d.id), true, em, "Cancel the download").clicked { act = .Cancel }
			} else if dl_button("Cancel", fmt.tprintf("dlc_%d", d.id), em * 6) { act = .Cancel }
		case d.state == .Done && download_file_present(d):
			if compact {
				if dl_folder_button(fmt.tprintf("###dlf_%d", d.id), hot, em).clicked { act = .Reveal }
			} else {
				if dl_button("Open", fmt.tprintf("dlo_%d", d.id), em * 5.5) { act = .Open }
				ui.spacer(ui.px(em * 0.4))
				if dl_button("Show in folder", fmt.tprintf("dlf_%d", d.id), em * 8) { act = .Reveal }
			}
		case download_finished(d):
			if dl_button(d.state == .Done ? "Download again" : "Try again", fmt.tprintf("dlr_%d", d.id), em * (compact ? 9 : 9.5)) { act = .Retry }
		}
		if !compact && download_finished(d) {
			ui.spacer(ui.px(em * 0.4))
			ui.next({width = ui.px(em * 2.2), height = ui.px(ui.dense(em * 2)), radius = em * CHROME_BUTTON_RADIUS})
			if ui.tags("ghost_button") {
				mb := ui.button(fmt.tprintf("\u22ef###dlm_%d", d.id))
				at = mb.box.rect
				tip(mb, "More")
				if mb.clicked { act = .Menu }
			}
		}
		ui.spacer(ui.px(em * 0.7))
	}
	if act == .None {
		switch {
		case sig.clicked && d.state == .Done && download_file_present(d): act = .Open
		case sig.right_clicked && download_finished(d): act, at = .Menu, {ui.mouse_pos(), ui.mouse_pos()}
		}
	}
	return
}

@(private = "file")
dl_button :: proc(text, id: string, w: f32) -> bool {
	em := ui.font_size()
	ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 2)), radius = em * CHROME_BUTTON_RADIUS})
	return ui.button(fmt.tprintf("%s###%s", text, id)).clicked
}

// A folder, drawn: the small button of the drop-down's finished rows.
@(private = "file")
dl_folder_button :: proc(id: string, shown: bool, em: f32) -> ui.Signal {
	cs := math.round(em * 1.6)
	ui.next({width = ui.px(cs), height = ui.px(cs), radius = cs * 0.5, cursor = .Hand})
	sig: ui.Signal
	if ui.tags("icon_button", "weak") {
		b := ui.build_box({.Clickable, .Draw_Background, .Draw_Hot_Effects}, id)
		sig = ui.signal(b)
		col := ui.frame_new(draw.Color)
		col^ = b.text_color
		if !shown && !sig.hovering { col.a *= 0.55 }
		b.custom, b.custom_user = dl_folder_draw, col
	}
	if sig.box != nil { tip(sig, "Show in folder") }
	return sig
}

@(private = "file")
dl_folder_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	col := (^draw.Color)(user)^
	c := draw.rect_center(b.rect)
	s := (b.rect.max.x - b.rect.min.x) * 0.5
	th := max(math.round(1.4 * ui.scale()), 1)
	body := draw.Rect{{c.x - s * 0.5, c.y - s * 0.25}, {c.x + s * 0.5, c.y + s * 0.4}}
	draw.rect(dc, body, col, s * 0.1, th)
	draw.rect(dc, {{body.min.x, body.min.y - s * 0.17}, {body.min.x + s * 0.4, body.min.y + th}}, col, s * 0.08, th)
}

// What a row asked for.
@(private = "file")
dl_do :: proc(app: ^App, d: ^Download, act: Dl_Row_Act, at: draw.Rect, menu_key: ui.Key, anchor: ui.Key) {
	switch act {
	case .None:
	case .Open:    download_open_file(d)
	case .Reveal:  download_reveal(d)
	case .Cancel:  download_cancel(d)
	case .Retry:   download_retry(app, d)
	case .Remove:  download_remove(app, d)
	case .Menu:
		dview.menu_id = d.id
		if at.min == at.max { ui.ctx_menu_open(menu_key, at.min) } else { ui.ctx_menu_open_rect(menu_key, at, anchor) }
	}
}

// The menu of a finished row.
@(private = "file")
dl_menu :: proc(app: ^App, menu_key: ui.Key) {
	if ui.ctx_menu(menu_key) { dl_menu_items(app) }
}

@(private = "file")
dl_menu_items :: proc(app: ^App) {
	d := dl_by_id(dview.menu_id)
	if d == nil || !download_finished(d) { ui.ctx_menu_close(); return }
	present := download_file_present(d)
	if ui.menu_item("Open", enabled = present).clicked { ui.ctx_menu_close(); download_open_file(d); return }
	if ui.menu_item("Show in folder", enabled = d.path != "").clicked { ui.ctx_menu_close(); download_reveal(d); return }
	if ui.menu_item("Copy download link", icon = GLYPH_COPY).clicked { clip_set(d.url); ui.ctx_menu_close(); return }
	if ui.menu_item("Download again", enabled = d.url != "").clicked { ui.ctx_menu_close(); download_retry(app, d); return }
	ui.menu_separator()
	if ui.menu_item("Delete the file", enabled = present).clicked { ui.ctx_menu_close(); download_delete_file(app, d); return }
	if ui.menu_item("Remove from the list").clicked { ui.ctx_menu_close(); download_remove(app, d); return }
}

////////////////////////////////
// about:downloads

downloads_page :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	menu_key := ui.key_from_string(0, "###dl_row_menu")
	if ui.style({width = ui.fill(), height = ui.fill()}) {
		ui.next({axis = .Y})
		root := ui.build_box({.Draw_Background}, "###downloads_page")
		if ui.parent(root) {
			ui.spacer(ui.px(em * 0.6))
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 0.8))
				ui.next({width = ui.text_size(0), height = ui.px(ui.dense(em * 2))})
				ui.label("Downloads###dl_title")
				ui.spacer(ui.px(em * 1.0))
				ui.next({width = ui.px(em * 22), height = ui.px(ui.dense(em * 2))})
				res := ui.line_edit("###dl_search", &dview.search, "Search downloads")
				if dview.focus_search && res.box != nil { dview.focus_search = false; ui.set_focus(res.box.key); ui.field_select_all(&dview.search) }
				ui.spacer(ui.px(em * 0.6))
				ui.next({width = ui.px(em * 8.5), height = ui.px(ui.dense(em * 2))})
				cb := ui.button("Clear the list###dl_clear")
				if cb.clicked { download_clear_finished(app); downloads_mark_seen() }
				tip(cb, "Takes the finished downloads off the list; the files stay where they are")
				ui.spacer(ui.px(em * 0.4))
				ui.next({width = ui.px(em * 9.5), height = ui.px(ui.dense(em * 2))})
				if ui.button("Open the folder###dl_folder").clicked { platform_open_dir(download_dir(app)) }
				ui.spacer(ui.fill())
				active, _, _, speed := downloads_progress()
				if ui.tags("weak") {
					ui.next({width = ui.text_size(em * 0.4), height = ui.px(ui.dense(em * 2))})
					summary := fmt.tprintf(len(dls.list) == 1 ? "%d download" : "%d downloads", len(dls.list))
					if active > 0 { summary = fmt.tprintf("%d in progress%s", active, speed > 0 ? fmt.tprintf(" \u00b7 %s/s", human_bytes(i64(speed))) : "") }
					ui.label(fmt.tprintf("%s###dl_count", summary))
				}
				ui.spacer(ui.px(em * 0.8))
			}
			ui.spacer(ui.px(em * 0.3))
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.scroll_y("###dl_scroll") { downloads_list(app, menu_key) }
		}
	}
	dl_menu(app, menu_key)
	downloads_mark_seen()
}

@(private = "file")
platform_open_dir :: proc(dir: string) {
	if dir != "" { platform.open_path(dir) }
}

@(private = "file")
downloads_list :: proc(app: ^App, menu_key: ui.Key) {
	em := ui.font_size()
	query := strings.to_lower(strings.trim_space(ui.field_string(&dview.search)), context.temp_allocator)
	matches :: proc(x: ^Download, q: string) -> bool {
		if q == "" { return true }
		return strings.contains(strings.to_lower(x.name, context.temp_allocator), q) || strings.contains(strings.to_lower(x.url, context.temp_allocator), q)
	}
	shown := 0
	// the running ones first, newest first
	for i := len(dls.list) - 1; i >= 0; i -= 1 {
		d := dls.list[i]
		if !dl_running(d) || !matches(d, query) { continue }
		shown += 1
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.5))
			act, at := dl_row(app, d, -1, false)
			ui.spacer(ui.px(em * 0.5))
			dl_do(app, d, act, at, menu_key, 0)
			if act != .None && act != .Menu { break }
		}
		ui.spacer(ui.px(em * 0.2))
	}
	// then the finished ones, by day
	now := dl_now_ms()
	tl := local_time(now)
	yl := local_time(local_midnight(now) - 1000)
	today, yesterday := tl.year * 10000 + tl.month * 100 + tl.day, yl.year * 10000 + yl.month * 100 + yl.day
	last_day := -1
	for i := len(dls.list) - 1; i >= 0; i -= 1 {
		d := dls.list[i]
		if dl_running(d) || !matches(d, query) { continue }
		lt := local_time(d.done_ms > 0 ? d.done_ms : d.started_ms)
		key := lt.year * 10000 + lt.month * 100 + lt.day
		if key != last_day {
			last_day = key
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.6))})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 1.0))
				if ui.tags("weak") {
					ui.next({width = ui.fill(), height = ui.pct(1)})
					ui.label(fmt.tprintf("%s###dld_%d", day_heading(lt, today, yesterday), key))
				}
			}
		}
		shown += 1
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.5))
			act, at := dl_row(app, d, -1, false)
			ui.spacer(ui.px(em * 0.5))
			dl_do(app, d, act, at, menu_key, 0)
			if act != .None && act != .Menu { break }
		}
		ui.spacer(ui.px(em * 0.2))
	}
	if shown == 0 {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 5))})
		if ui.tags("weak") { if ui.style({text_align = .Center}) { ui.label(query != "" ? "No download matches.###dl_none" : "No download yet. Files you download from a page show here.###dl_none") } }
	}
}

////////////////////////////////
// The toolbar's button and its drop-down

// The button shows once a download has run in this session (browser.download.button).
downloads_button_visible :: proc() -> bool {
	switch dls.cfg.button {
	case "never":  return false
	case "always": return true
	}
	return downloads_session_started() || dview.popup_open
}

Dl_Button :: struct {
	app:     ^App,
	active:  int,
	frac:    f32,
	unknown: bool,
	dot:     bool,
	now_ms:  f64,
	color, accent, track: draw.Color,
}

@(private = "file")
dl_stroke :: proc(dc: ^draw.Context, a, b: draw.Vec2, thick: f32, color: draw.Color) {
	d := b - a
	l := math.sqrt(d.x * d.x + d.y * d.y)
	mid := (a + b) * 0.5
	draw.push_transform(dc, draw.affine_around(draw.affine_rotate(math.atan2(-d.x, d.y)), mid))
	draw.rect(dc, {{mid.x - thick * 0.5, mid.y - l * 0.5 - thick * 0.5}, {mid.x + thick * 0.5, mid.y + l * 0.5 + thick * 0.5}}, color, thick * 0.5)
	draw.pop_transform(dc)
}

@(private = "file") RING_N :: 72

@(private = "file")
dl_button_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Dl_Button)(user)
	r := b.rect
	bh := r.max.y - r.min.y
	c := draw.rect_center(r)
	thick := max(2, bh * 0.075)
	s := bh * 0.5
	col := d.color
	// the arrow into a tray
	top, tip_y := c.y - s * 0.44, c.y + s * 0.1
	dl_stroke(dc, {c.x, top}, {c.x, tip_y}, thick, col)
	dl_stroke(dc, {c.x - s * 0.27, tip_y - s * 0.27}, {c.x, tip_y}, thick, col)
	dl_stroke(dc, {c.x + s * 0.27, tip_y - s * 0.27}, {c.x, tip_y}, thick, col)
	ty := c.y + s * 0.44
	dl_stroke(dc, {c.x - s * 0.44, ty - s * 0.22}, {c.x - s * 0.44, ty}, thick, col)
	dl_stroke(dc, {c.x - s * 0.44, ty}, {c.x + s * 0.44, ty}, thick, col)
	dl_stroke(dc, {c.x + s * 0.44, ty}, {c.x + s * 0.44, ty - s * 0.22}, thick, col)
	if d.active > 0 {
		// a ring around it: the track, and the part done (or a comet turning while the sizes are not known)
		ro := bh * 0.5 - 1
		ri := ro - max(2.5, bh * 0.07)
		outer, inner: [RING_N]draw.Vec2
		for i in 0 ..< RING_N {
			a := f32(i) / RING_N * 2 * math.PI
			outer[i] = {c.x + math.sin(a) * ro, c.y - math.cos(a) * ro}
			inner[i] = {c.x + math.sin(a) * ri, c.y - math.cos(a) * ri}
		}
		ring: [2 * RING_N + 4]draw.Vec2
		k := 0
		for i in 0 ..< RING_N { ring[k] = outer[i]; k += 1 }
		ring[k] = outer[0]; k += 1
		ring[k] = inner[0]; k += 1
		for i := RING_N - 1; i >= 1; i -= 1 { ring[k] = inner[i]; k += 1 }
		ring[k] = inner[0]; k += 1
		bounds := draw.Rect{{c.x - ro - 1, c.y - ro - 1}, {c.x + ro + 1, c.y + ro + 1}}
		draw.push_clip_polygon(dc, ring[:k], true)
		tr := d.track
		draw.rect(dc, bounds, tr)
		clear_c := draw.Color{d.accent.r, d.accent.g, d.accent.b, 0}
		if d.unknown {
			turn := f32(math.mod(d.now_ms, 1100) / 1100)
			stops := [4]draw.Gradient_Stop{{color = clear_c, pos = 0}, {color = d.accent, pos = 0.3}, {color = clear_c, pos = 0.3001}, {color = clear_c, pos = 1}}
			draw.gradient(dc, bounds, draw.Gradient{kind = .Conic, center = {c.x - bounds.min.x, c.y - bounds.min.y}, angle = turn * 2 * math.PI - 0.3 * 2 * math.PI, stops = stops[:]})
		} else {
			f := clamp(d.frac, 0.02, 1)
			stops := [4]draw.Gradient_Stop{{color = d.accent, pos = 0}, {color = d.accent, pos = f}, {color = clear_c, pos = min(f + 0.0001, 1)}, {color = clear_c, pos = 1}}
			draw.gradient(dc, bounds, draw.Gradient{kind = .Conic, center = {c.x - bounds.min.x, c.y - bounds.min.y}, angle = 0, stops = stops[:]})
		}
		draw.pop_clip(dc)
	} else if d.dot {
		// something ended that nobody looked at
		dr := bh * 0.11
		p := draw.Vec2{c.x + s * 0.62, c.y - s * 0.62}
		draw.rect(dc, {{p.x - dr - 1.5, p.y - dr - 1.5}, {p.x + dr + 1.5, p.y + dr + 1.5}}, ui.color("background"), dr + 1.5)
		draw.rect(dc, {{p.x - dr, p.y - dr}, {p.x + dr, p.y + dr}}, d.accent, dr)
	}
	if ui.focus_key() == b.key {
		draw.rect(dc, {{r.min.x + 1, r.min.y + 1}, {r.max.x - 1, r.max.y - 1}}, ui.color("accent"), b.radius, max(2, ui.scale() * 1.5))
	}
}

downloads_button :: proc(app: ^App, t: ^Tab) {
	if !downloads_button_visible() { return }
	em := ui.font_size()
	active, frac, known, speed := downloads_progress()
	unseen := false
	for x in dls.list { if x.unseen { unseen = true; break } }
	d := ui.frame_new(Dl_Button)
	acc := ui.color("accent")
	txt := ui.color("text")
	trk := txt
	trk.a = 0.2
	d^ = {app = app, active = active, unknown = !known, dot = unseen, now_ms = f64(host.now_ns(&app.loop)) / 1e6, color = txt, accent = acc, track = trk}
	ui.next({width = ui.px(em * 2.3), height = ui.px(ui.dense(em * 2)), radius = em * CHROME_BUTTON_RADIUS})
	ui.push_tags("icon_button")
	b := ui.custom("###downloads_icon", dl_button_draw, d, {.Clickable, .Focusable, .Draw_Background, .Draw_Hot_Effects})
	ui.pop_tags()
	d.frac = ui.anim(ui.key_from_string(b.key, "frac"), frac, 9, 0)
	sig := ui.signal(b)
	key := ui.key_from_string(b.parent.key, "###downloads_panel")
	// a download began: the drop-down opens under the button, once the button has a place (the frame it first shows, it has none)
	if own := window_own(app); own.downloads_panel_request && b.rect.max.x > b.rect.min.x {
		own.downloads_panel_request = false
		if !ui.ctx_menu_is_open(key) { ui.ctx_menu_open_rect(key, b.rect, b.key) }
	}
	if sig.clicked {
		if ui.ctx_menu_is_open(key) { ui.ctx_menu_close() } else { ui.ctx_menu_open_rect(key, b.rect, b.key) }
	}
	open := ui.ctx_menu_is_open(key)
	dview.popup_open = open
	if active > 0 { request_frames(app, 1) }
	if !open {
		text := "Downloads (Ctrl+J)"
		if active > 0 {
			text = known ? fmt.tprintf("%d downloading, %d %%%s", active, int(frac * 100), speed > 0 ? fmt.tprintf(" \u00b7 %s/s", human_bytes(i64(speed))) : "") : fmt.tprintf("%d downloading", active)
		}
		tip(sig, text)
	}
	ui.a11y_set(b, {name = "Downloads", popup = .Menu, expanded = open, shortcut = "Ctrl+J"})
	downloads_panel(app, key)
}

DL_PANEL_W_EM :: f32(30)

@(private = "file")
downloads_panel :: proc(app: ^App, key: ui.Key) {
	if ui.ctx_menu(key, ui.font_size() * DL_PANEL_W_EM) { downloads_panel_body(app) }
}

@(private = "file")
downloads_panel_body :: proc(app: ^App) {
	em := ui.font_size()
	w := em * DL_PANEL_W_EM
	downloads_mark_seen()
	ui.spacer(ui.px(em * 0.4))
	ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 2.4))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.9))
		ui.next({width = ui.fill(), height = ui.pct(1)})
		ui.label("Downloads###dlp_title")
		ui.next({width = ui.px(em * 8), height = ui.px(ui.dense(em * 2)), radius = em * CHROME_BUTTON_RADIUS})
		if ui.button("Show all###dlp_all").clicked { ui.ctx_menu_close(); open_downloads(app); return }
		ui.spacer(ui.px(em * 0.6))
	}
	ui.hline(ui.px(w))
	ui.spacer(ui.px(em * 0.3))
	n := 0
	for i := len(dls.list) - 1; i >= 0 && n < 6; i -= 1 {
		d := dls.list[i]
		n += 1
		ui.next({width = ui.px(w), height = ui.children_sum()})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 0.4))
			act, at := dl_row(app, d, w - em * 0.8, true)
			ui.spacer(ui.px(em * 0.4))
			if act == .Open || act == .Reveal { ui.ctx_menu_close() }
			dl_do(app, d, act, at, 0, 0)
			if act != .None { break }
		}
	}
	if n == 0 {
		ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 4))})
		if ui.tags("weak") { if ui.style({text_align = .Center}) { ui.label("No download yet.###dlp_none") } }
	}
	ui.spacer(ui.px(em * 0.3))
	ui.hline(ui.px(w))
	ui.spacer(ui.px(em * 0.4))
	ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 2.2))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.9))
		ui.next({width = ui.px(em * 11), height = ui.px(ui.dense(em * 2)), radius = em * CHROME_BUTTON_RADIUS})
		if ui.button("Open the folder###dlp_folder").clicked { ui.ctx_menu_close(); platform_open_dir(download_dir(app)) }
	}
	ui.spacer(ui.px(em * 0.5))
}
