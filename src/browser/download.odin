package browser

// Downloads: a navigation whose answer is not a document the browser shows (Content-Disposition: attachment, or a type
// it does not display: archives, executables, PDF, media...) becomes a download, as in every browser:
//   * the connection that brought the answer goes on as the download (fetch.task_hand_over): nothing is asked twice,
//     a POST or a one-time link work;
//   * the tab keeps the page it showed (the navigation does not happen: no history entry, the held page comes back);
//     a tab opened only for it closes;
//   * the body streams to a temporary file next to the destination ("name.ext.wrenpart"), written on the blocking
//     threads one chunk at a time: memory holds at most browser.download.max_buffered_bytes (past it, the interface
//     thread writes too, so a disk slower than the network slows the download instead of filling memory);
//   * meanwhile the Save dialog of Windows asks where (browser.download.ask; off: the downloads folder, a free name);
//     cancelled, or the network fails: the temporary file is deleted; done: it is moved to its place;
//   * The toolbar's button and about:downloads (Ctrl+J) list them (progress, cancel, open, show in folder, delete): downloads_ui.odin;
//     the finished ones are kept in the profile (downloads.txt); a notice says when one is saved or fails.
// Images and text are shown, not downloaded (an image document; text as text), like Chrome.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import "toolkit:platform"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:fetch"
import "wb:host"
import "wb:http"
import "wb:images"
import "wb:page"

DOWNLOAD_PREFS := [?]config.Def{
	{name = "browser.download.ask", kind = .Bool, default = {b = false},
		description = "Ask where to save each download (the Save dialog of Windows). Off (the default): downloads go at once to browser.download.directory, the Downloads folder of Windows when it is empty, under a name that is free."},
	{name = "browser.download.directory", kind = .String, default = {s = ""},
		description = "Folder downloads go to (and where the Save dialog starts). Empty: the Downloads folder of Windows."},
	{name = "browser.download.max_bytes", kind = .Int, default = {i = 0}, bounded = true, min = 0, max = 1 << 50, bytes = true, unit = "bytes",
		description = "Largest download accepted; 0 = no limit."},
	{name = "browser.download.flush_bytes", kind = .Int, default = {i = 1 << 20}, bounded = true, min = 4 << 10, max = 256 << 20, bytes = true, unit = "bytes",
		description = "Bytes gathered before a chunk is written to disk (on a background thread)."},
	{name = "browser.download.max_buffered_bytes", kind = .Int, default = {i = 64 << 20}, bounded = true, min = 64 << 10, max = 4 << 30, bytes = true, unit = "bytes",
		description = "Most bytes of a download kept in memory while the disk is busy; past it they are written at once, which slows the download down to the disk's pace."},
	{name = "browser.download.list_max", kind = .Int, default = {i = 200}, bounded = true, min = 1, max = 5000,
		description = "Finished downloads about:downloads keeps listing, across restarts (the oldest go first)."},
	{name = "browser.download.button", kind = .String, default = {s = "auto"}, choices = {"auto", "always", "never"},
		description = "The downloads button of the toolbar: auto shows it once a download has run in this session, always keeps it, never hides it (Ctrl+J opens the list)."},
	{name = "browser.download.temp_suffix", kind = .String, default = {s = ".wrenpart"},
		description = "Suffix of the temporary file a download is written to until it is complete."},
}

register_download_prefs :: proc(p: ^config.Prefs) { config.register(p, DOWNLOAD_PREFS[:]) }

////////////////////////////////
// What to do with a navigation's answer (pure: download_test.odin)

Doc_Action :: enum u8 { Render, Text, Image, Wasm, Download }

// From the response's type (essence, lower case; "" = none), its Content-Disposition (raw, "" = none) and its URL.
doc_action :: proc(mime: string, disposition: string, address: string) -> Doc_Action {
	if attachment, _ := parse_content_disposition(disposition); attachment { return .Download }
	path := address
	if i := strings.index_any(path, "?#"); i >= 0 { path = path[:i] }
	switch {
	case mime == "": return .Render   // sniffed as HTML (or a module) once the bytes are there
	case mime == "text/html" || mime == "application/xhtml+xml": return .Render
	case mime == "application/wasm": return .Wasm
	case mime == "application/octet-stream" && strings.has_suffix(strings.to_lower(path, context.temp_allocator), ".wasm"): return .Wasm
	case strings.has_prefix(mime, "text/"), mime == "application/json", mime == "application/javascript", mime == "application/ecmascript",
	     mime == "application/xml", strings.has_suffix(mime, "+xml") && !strings.has_prefix(mime, "image/"), strings.has_suffix(mime, "+json"):
		return .Text
	case strings.has_prefix(mime, "image/") && images.format_of_mime(mime) != .Unknown: return .Image
	}
	return .Download
}

// RFC 6266: whether the disposition is "attachment", and the file name it gives (filename* in RFC 8187 form
// preferred, UTF-8 or ISO-8859-1; else filename, quoted or a token). The name is returned as given (sanitized later).
parse_content_disposition :: proc(value: string, allocator := context.temp_allocator) -> (attachment: bool, name: string) {
	s := strings.trim_space(value)
	if s == "" { return false, "" }
	kind := s
	if i := strings.index_byte(s, ';'); i >= 0 { kind = s[:i]; s = s[i + 1:] } else { s = "" }
	attachment = strings.equal_fold(strings.trim_space(kind), "attachment")
	plain, extended: string
	has_ext := false
	for len(s) > 0 {
		s = strings.trim_left_space(s)
		eq := strings.index_byte(s, '=')
		if eq < 0 { break }
		key := strings.to_lower(strings.trim_space(s[:eq]), context.temp_allocator)
		s = strings.trim_left_space(s[eq + 1:])
		v: string
		if len(s) > 0 && s[0] == '"' {
			// quoted-string: backslash escapes
			sb := strings.builder_make(context.temp_allocator)
			i := 1
			for i < len(s) && s[i] != '"' {
				if s[i] == '\\' && i + 1 < len(s) { i += 1 }
				strings.write_byte(&sb, s[i])
				i += 1
			}
			v = strings.to_string(sb)
			s = i < len(s) ? s[i + 1:] : ""
			if j := strings.index_byte(s, ';'); j >= 0 { s = s[j + 1:] } else { s = "" }
		} else {
			j := strings.index_byte(s, ';')
			if j >= 0 { v, s = strings.trim_space(s[:j]), s[j + 1:] } else { v, s = strings.trim_space(s), "" }
		}
		switch key {
		case "filename": plain = v
		case "filename*":
			if d, ok := decode_ext_value(v); ok { extended, has_ext = d, true }
		}
	}
	name = has_ext ? extended : plain
	return attachment, strings.clone(name, allocator)
}

// RFC 8187 ext-value: charset'language'percent-encoded. UTF-8 and ISO-8859-1 (converted to UTF-8).
@(private = "file")
decode_ext_value :: proc(v: string) -> (string, bool) {
	q1 := strings.index_byte(v, '\'')
	if q1 < 0 { return "", false }
	rest := v[q1 + 1:]
	q2 := strings.index_byte(rest, '\'')
	if q2 < 0 { return "", false }
	charset := strings.to_lower(v[:q1], context.temp_allocator)
	enc := rest[q2 + 1:]
	raw := make([dynamic]u8, 0, len(enc), context.temp_allocator)
	for i := 0; i < len(enc); i += 1 {
		if enc[i] == '%' {
			if i + 2 >= len(enc) { return "", false }
			b, ok := strconv.parse_int(enc[i + 1:i + 3], 16)
			if !ok { return "", false }
			append(&raw, u8(b))
			i += 2
		} else { append(&raw, enc[i]) }
	}
	switch charset {
	case "utf-8": return string(raw[:]), true
	case "iso-8859-1":
		sb := strings.builder_make(context.temp_allocator)
		for b in raw { strings.write_rune(&sb, rune(b)) }
		return strings.to_string(sb), true
	}
	return "", false
}

// A file name Windows accepts, from what the server suggested (else the URL's last segment, else "download"): no
// folder part, no reserved character or control character, no trailing dot or space, not a device name, at most
// `max_bytes` bytes (the extension kept), and an extension from the type when there is none.
download_file_name :: proc(suggested, address, mime: string, max_bytes := 200, allocator := context.temp_allocator) -> string {
	name := suggested
	if strings.trim_space(name) == "" {
		p := address
		if i := strings.index_any(p, "?#"); i >= 0 { p = p[:i] }
		if i := strings.last_index_byte(p, '/'); i >= 0 { p = p[i + 1:] }
		name = percent_decode_name(p)
	}
	// only the last component: a name never chooses the folder
	if i := strings.last_index_any(name, "/\\"); i >= 0 { name = name[i + 1:] }
	sb := strings.builder_make(context.temp_allocator)
	for r in name {
		switch r {
		case '<', '>', ':', '"', '|', '?', '*': strings.write_rune(&sb, '_')
		case 0 ..< 32, 0x7f, 0x202e, 0x202d, 0x200e, 0x200f: // controls and bidi overrides (a name could pretend another extension)
		case: strings.write_rune(&sb, r)
		}
	}
	out := strings.trim(strings.to_string(sb), " .")
	if out == "" { out = "download" }
	ext := filepath.ext(out)
	if ext == "" || len(ext) > 12 {
		if e := extension_of_mime(mime); e != "" { out = strings.concatenate({out, e}, context.temp_allocator); ext = e }
	}
	out = fit_file_name(out, max_bytes)
	// device names, with or without extensions (Windows reads the part before the first dot: con.tar.gz is CON); the prefix
	// is one byte more, and what it makes cannot be a device
	if is_device_name(out) { out = fit_file_name(strings.concatenate({"_", out}, context.temp_allocator), max_bytes) }
	return strings.clone(out, allocator)
}

// `name` in at most `max_bytes` bytes (one at least): whole characters only, the extension kept when it fits (one as long
// as the limit is not one: the name is then cut as a whole), no dot or space left at the end of what is cut.
@(private = "file")
fit_file_name :: proc(name: string, max_bytes: int) -> string {
	limit := max(max_bytes, 1)
	if len(name) <= limit { return name }
	ext := filepath.ext(name)
	if len(ext) >= limit { ext = "" }
	stem := name[:len(name) - len(ext)]
	cut := min(limit - len(ext), len(stem))
	for cut > 0 && cut < len(stem) && (stem[cut] & 0xC0) == 0x80 { cut -= 1 }
	head := strings.trim_right(stem[:cut], " .")
	if head == "" && ext == "" { return "_" }
	return strings.concatenate({head, ext}, context.temp_allocator)
}

// CON, PRN, AUX, NUL, CONIN$, CONOUT$, COM0-9 and LPT0-9 (also with the superscript digits ¹ ² ³), whatever follows the first dot.
@(private = "file")
is_device_name :: proc(name: string) -> bool {
	base := name
	if i := strings.index_byte(name, '.'); i >= 0 { base = name[:i] }
	upper := strings.to_upper(strings.trim_right(base, " "), context.temp_allocator)
	switch upper {
	case "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$": return true
	}
	if strings.has_prefix(upper, "COM") || strings.has_prefix(upper, "LPT") {
		digit := upper[3:]
		return (len(digit) == 1 && digit[0] >= '0' && digit[0] <= '9') || digit == "\u00b9" || digit == "\u00b2" || digit == "\u00b3"
	}
	return false
}

@(private = "file")
percent_decode_name :: proc(s: string) -> string {
	out := make([dynamic]u8, 0, len(s), context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 2 < len(s) {
			if v, ok := strconv.parse_int(s[i + 1:i + 3], 16); ok { append(&out, u8(v)); i += 2; continue }
		}
		append(&out, s[i])
	}
	return string(out[:])
}

@(private = "file")
extension_of_mime :: proc(mime: string) -> string {
	switch mime {
	case "application/pdf": return ".pdf"
	case "application/zip", "application/x-zip-compressed": return ".zip"
	case "application/gzip", "application/x-gzip": return ".gz"
	case "application/x-tar": return ".tar"
	case "application/x-7z-compressed": return ".7z"
	case "application/vnd.rar", "application/x-rar-compressed": return ".rar"
	case "application/x-msdownload", "application/vnd.microsoft.portable-executable": return ".exe"
	case "application/x-msi": return ".msi"
	case "application/json": return ".json"
	case "application/xml", "text/xml": return ".xml"
	case "text/plain": return ".txt"
	case "text/csv": return ".csv"
	case "text/html": return ".html"
	case "audio/mpeg": return ".mp3"
	case "audio/ogg": return ".ogg"
	case "audio/wav", "audio/x-wav": return ".wav"
	case "video/mp4": return ".mp4"
	case "video/webm": return ".webm"
	case "font/woff2": return ".woff2"
	case "font/woff": return ".woff"
	case "application/wasm": return ".wasm"
	}
	return ""
}

// "name (1).ext", "name (2).ext"... the first that `taken` says is free (`name` itself first).
unique_file_name :: proc(name: string, taken: proc(name: string, user: rawptr) -> bool, user: rawptr, allocator := context.temp_allocator) -> string {
	if !taken(name, user) { return strings.clone(name, allocator) }
	ext := filepath.ext(name)
	stem := name[:len(name) - len(ext)]
	for i in 1 ..< 10_000 {
		c := fmt.tprintf("%s (%d)%s", stem, i, ext)
		if !taken(c, user) { return strings.clone(c, allocator) }
	}
	return strings.clone(name, allocator)
}

// An image opened as a document: the image alone, centred on a dark background and fitted to the window, as in
// Chrome (the page loads it again through the image cache).
show_image_document :: proc(app: ^App, load: ^Doc_Load) {
	t := load.tab
	name := download_file_name("", t.url, "", allocator = context.temp_allocator)
	// (style attributes, not a <style> sheet: a sheet of a document written with load_html into a page of a web origin
	// is not applied, see the report of the chrome branch)
	html := fmt.tprintf(`<!doctype html><html style="color-scheme: dark; background: #0e0e0e"><head><meta charset="utf-8"><title>%s</title></head><body style="margin: 0"><img style="position: absolute; top: 0; right: 0; bottom: 0; left: 0; margin: auto; display: block; max-width: 100%%; max-height: 100%%" src="%s" alt=""></body></html>`,
		escape_html(name), escape_html(t.url))
	// (the page is made now, with the document right away: the image response itself made none)
	if load.page == nil {
		load.page = page.page_create(&app.loop, &app.loader, &app.page_settings, t.nav, load.final_url, console_sink, t)
		attach_page(app, t, load.page)
		t.page = load.page
	}
	page.load_html(load.page, transmute([]byte)html)
	set_status(t, fmt.tprintf("HTTP %d, image", load.status))
}

////////////////////////////////
// Downloads

Download_State :: enum u8 { Receiving, Saving, Done, Failed, Cancelled }

Download :: struct {
	app:       ^App,
	id:        u64,
	url:       string,          // owned
	name:      string,          // owned: the file name suggested
	dir:       string,          // owned: the folder of the temporary file
	temp:      string,          // owned: the temporary file
	path:      string,          // owned: the destination ("" until known)
	handle:    ^os.File,        // the open temporary file (nil: none)
	task:      base.Handle,
	scope:     ^base.Scope,     // the request's (child of the process scope)
	total:     i64,             // Content-Length, -1 unknown
	received:  i64,
	queued:    i64,             // offset of the next chunk handed to the disk
	pending:   [dynamic]byte,   // received, not handed to the disk yet
	writing:   bool,            // a write job is out
	asking:    bool,            // the Save dialog is open
	moving:    bool,            // the temporary file is being moved into place
	net_done:  bool,
	state:     Download_State,
	error:     string,          // owned
	// what the list and the progress bars show (downloads_ui.odin)
	started_ms: i64,            // unix ms
	done_ms:   i64,             // unix ms of the end (Done, Failed, Cancelled)
	size:      i64,             // the file's size once Done
	speed:     f64,             // bytes per second, smoothed while Receiving
	sample_ms: i64,             // when `speed` was last measured, and the bytes received then
	sample_bytes: i64,
	restored:  bool,            // read from the profile's list: no connection, file or scope of its own
	unseen:    bool,            // ended since the downloads were last looked at (the button's dot)
	missing:   bool,            // the file is no longer where it was saved
	checked_ms: i64,            // when `missing` was last looked up
}

Downloads :: struct {
	list:  [dynamic]^Download,
	ids:   u64,
	cfg:   struct { ask: bool, dir: string, max_bytes, flush, max_buffered, list_max: int, suffix: string, button: string },
}

dls: Downloads

// The folder picker of the downloads page: the folder chosen becomes browser.download.directory.
@(private = "file")
Folder_Job :: struct { app: ^App, start, chosen: string }

@(private = "file")
dl_picking: bool

download_pick_folder :: proc(app: ^App) {
	if dl_picking { return }
	dl_picking = true
	job := new(Folder_Job)
	job.app, job.start = app, strings.clone(download_dir(app))
	host.run_blocking(&app.blocking, proc(data: rawptr) {
		j := (^Folder_Job)(data)
		dlg := platform.File_Dialog{owner = active_window(j.app).win, title = "Folder for the downloads", start_dir = j.start, start_known = .Downloads, remember_id = "download_dir"}
		res := platform.pick_folder_dialog(dlg, context.allocator)
		defer platform.dialog_result_destroy(&res, context.allocator)
		if res.status == .Chosen && len(res.paths) > 0 { j.chosen = strings.clone(res.paths[0]) }
	}, proc(data: rawptr) {
		j := (^Folder_Job)(data)
		dl_picking = false
		if j.chosen != "" {
			if err := config.set_from_string(&j.app.prefs, "browser.download.directory", j.chosen, .User); err != .None {
				ui.toast(.Warn, "browser.download.directory: %s", config.set_error_text(err))
			}
		}
		request_frames(j.app, 2)
		delete(j.start); delete(j.chosen); free(j)
	}, job)
}

// Back to the Downloads folder of Windows.
download_folder_default :: proc(app: ^App) {
	_ = config.set_from_string(&app.prefs, "browser.download.directory", "", .User)
	request_frames(app, 2)
}

dl_now_ms :: proc() -> i64 { return time.time_to_unix_nano(time.now()) / 1e6 }

@(private = "file")
download_cfg :: proc(app: ^App) {
	delete(dls.cfg.dir); delete(dls.cfg.suffix); delete(dls.cfg.button)
	p := &app.prefs
	dls.cfg.button = strings.clone(config.string_of(p, "browser.download.button"))
	dls.cfg.ask = config.bool_of(p, "browser.download.ask")
	dls.cfg.dir = strings.clone(config.string_of(p, "browser.download.directory"))
	dls.cfg.max_bytes = int(config.int_of(p, "browser.download.max_bytes"))
	dls.cfg.flush = int(config.int_of(p, "browser.download.flush_bytes"))
	dls.cfg.max_buffered = int(config.int_of(p, "browser.download.max_buffered_bytes"))
	dls.cfg.list_max = int(config.int_of(p, "browser.download.list_max"))
	suffix := config.string_of(p, "browser.download.temp_suffix")
	dls.cfg.suffix = strings.clone(suffix != "" ? suffix : ".wrenpart")
}

// The folder downloads go to: the preference, else the system's Downloads folder, else the profile.
download_dir :: proc(app: ^App) -> string {
	if dls.cfg.dir != "" { return dls.cfg.dir }
	if d := platform.known_folder_path(.Downloads, context.temp_allocator); d != "" { return d }
	return app.profile_dir
}

@(private = "file")
path_join :: proc(dir, name: string, allocator := context.temp_allocator) -> string {
	if dir == "" || strings.has_suffix(dir, "\\") || strings.has_suffix(dir, "/") { return strings.concatenate({dir, name}, allocator) }
	return strings.concatenate({dir, filepath.SEPARATOR_STRING, name}, allocator)
}

@(private = "file")
file_exists :: proc(path: string) -> bool {
	return os.exists(path)
}

// The navigation `load` got an answer to save rather than show (`task` is its request, `r` the answer).
download_from_navigation :: proc(app: ^App, load: ^Doc_Load, task: base.Handle, r: ^fetch.Response, disposition: string) {
	if dls.cfg.suffix == "" { download_cfg(app) }
	downloads_prune()   // (only here: no download is being worked on)
	_, suggested := parse_content_disposition(disposition)
	mime := r.has_mime ? http.mime_essence(r.mime) : ""
	d := new(Download)
	dls.ids += 1
	d.app, d.id, d.total = app, dls.ids, -1
	d.started_ms = dl_now_ms()
	d.sample_ms = d.started_ms
	d.url = strings.clone(r.url)
	d.name = download_file_name(suggested, r.url, mime, allocator = context.allocator)
	if v, ok := http.get_header(r.headers, "content-length"); ok {
		if n, nok := strconv.parse_i64(strings.trim_space(v)); nok && n >= 0 { d.total = n }
	}
	d.scope = base.scope_make("download", app.process)
	d.task = task
	max_body := dls.cfg.max_bytes > 0 ? dls.cfg.max_bytes : max(int)
	fetch.task_hand_over(&app.loader, task, d.scope, download_event, d, collect = false, max_body = max_body)
	base.on_close(d.scope, proc(data: rawptr) {
		dl := (^Download)(data)
		dl.task, dl.scope = base.NIL_HANDLE, nil   // the scope's own cleanup cancels the request
		if dl.state == .Receiving { dl.state = .Cancelled }
	}, d)
	append(&dls.list, d)
	load.task = base.NIL_HANDLE

	// the temporary file, next to where it will most likely go
	d.dir = strings.clone(download_dir(app))
	if !download_open_temp(d) {
		download_fail(d, fmt.tprintf("cannot write in %s", d.dir))
	} else {
		window_own(app).downloads_panel_request = true   // the button's drop-down shows it running (downloads_ui.odin)
		if dls.cfg.button == "never" { ui.toast(.Info, "Downloading %s", d.name) }
		if dls.cfg.ask {
			d.asking = true
			host.run_blocking(&app.blocking, download_dialog_work, download_dialog_done, d)
		}
	}
	download_restore_tab(app, load)   // `load` is gone after this
	request_frames(app, 2)
}

@(private = "file")
download_open_temp :: proc(d: ^Download) -> bool {
	for i in 0 ..< 1000 {
		base_name := i == 0 ? d.name : fmt.tprintf("%s (%d)", d.name, i)
		path := path_join(d.dir, strings.concatenate({base_name, dls.cfg.suffix}, context.temp_allocator))
		// O_EXCL: the open fails when the name is taken (CREATE_NEW), so a name free when it opens stays this download's.
		// A taken name is tried again under the next number; any other failure (an unwritable folder) stops at once, which
		// os.exists distinguishes without inspecting a platform-specific error code.
		h, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_EXCL)
		if err == nil {
			d.handle = h
			d.temp = strings.clone(path)
			return true
		}
		if !os.exists(path) { return false }
	}
	return false
}

// The navigation did not happen: the tab shows what it showed before (the held page, else the previous entry), or
// closes when it was opened for this alone.
@(private = "file")
download_restore_tab :: proc(app: ^App, load: ^Doc_Load) {
	t := load.tab
	if load.pushed {
		page.session_drop_current(&t.session)
		sync_history(t)
	}
	if t.hold.active && t.hold.page != nil {
		h := &t.hold
		old := t.nav
		t.nav, t.page = h.nav, h.page
		t.layout, h.layout = h.layout, t.layout
		t.scroll = h.scroll
		h.active, h.nav, h.page, h.bf_entry = false, nil, nil, 0
		t.nav_state.left = nil
		page.page_thaw(t.page)   // frozen for the back/forward cache when it was left (bfcache.odin)
		t.load = nil
		base.scope_close(old)   // the navigation's scope: its Doc_Load (the request is the download's now)
		delete(t.url)
		t.url = strings.clone(t.page.env.location.href)
		delete(t.title)
		t.title = default_tab_title(t.url, context.allocator)
		tab_icon_destroy(&t.icon)   // the title and icon are read again from the page
		set_status(t, "Done")
		address_set(app, t, t.url == HOME_URL ? "" : t.url)
		return
	}
	if cur := page.session_current(&t.session); cur != nil && bfcache_restore(app, t, cur) { return }
	if e := page_session_current(t); e != "" {
		navigate(app, t, e, record = false, restore = true, origin = .Replay)
		return
	}
	if w, _ := window_of_tab(app, t); w != nil && (len(window_tabs(app, w)) > 1 || len(app.windows) > 1) {
		tab_close_tab(app, t)
		return
	}
	navigate(app, t, "", record = false)
}

@(private = "file")
page_session_current :: proc(t: ^Tab) -> string {
	cur := page.session_current(&t.session)
	if cur == nil { return "" }
	return strings.clone(cur.url, context.temp_allocator)
}

@(private = "file")
download_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	d := (^Download)(user)
	#partial switch ev.kind {
	case .Data:
		if d.state != .Receiving { return }
		append(&d.pending, ..ev.data)
		d.received += i64(len(ev.data))
		// the speed: measured over at least a third of a second, smoothed (a steady figure for the bar and the time left)
		if now := dl_now_ms(); now - d.sample_ms >= 350 {
			inst := f64(d.received - d.sample_bytes) * 1000 / f64(now - d.sample_ms)
			d.speed = d.speed > 0 ? d.speed * 0.65 + inst * 0.35 : inst
			d.sample_ms, d.sample_bytes = now, d.received
		}
	case .Done:
		d.task = base.NIL_HANDLE
		d.net_done = true
	case .Failed:
		d.task = base.NIL_HANDLE
		download_fail(d, ev.detail)
		return
	}
	download_advance(d)
	request_frames(d.app, 2)
}

Write_Job :: struct {
	d:      ^Download,
	handle: ^os.File,
	buf:    []byte,   // owned
	offset: i64,
	ok:     bool,
	err:    os.Error,
}

// Writes `buf` at `offset` (positional: several writes of one file may be out at once, at different offsets). os.write_at
// is pwrite on POSIX and WriteFile with an OVERLAPPED on Windows, so writes at different offsets do not move a shared
// cursor.
@(private = "file")
write_at :: proc(h: ^os.File, buf: []byte, offset: i64) -> (ok: bool, err: os.Error) {
	done := 0
	for done < len(buf) {
		n, werr := os.write_at(h, buf[done:], offset + i64(done))
		if werr != nil || n <= 0 { return false, werr }
		done += n
	}
	return true, nil
}

// What comes next: a chunk to the disk, the bound on memory, the end.
@(private = "file")
download_advance :: proc(d: ^Download) {
	if d.state != .Receiving { return }
	app := d.app
	if !d.writing && len(d.pending) > 0 && (len(d.pending) >= dls.cfg.flush || d.net_done) {
		job := new(Write_Job)
		job.d, job.handle, job.offset = d, d.handle, d.queued
		job.buf = make([]byte, len(d.pending))
		copy(job.buf, d.pending[:])
		d.queued += i64(len(d.pending))
		clear(&d.pending)
		d.writing = true
		host.run_blocking(&app.blocking, proc(data: rawptr) {
			j := (^Write_Job)(data)
			j.ok, j.err = write_at(j.handle, j.buf, j.offset)
		}, write_done, job)
	} else if d.writing && len(d.pending) > dls.cfg.max_buffered {
		// the disk is slower than the network: this thread writes too (the network waits meanwhile)
		ok, err := write_at(d.handle, d.pending[:], d.queued)
		if !ok { download_fail(d, fmt.tprintf("cannot write %s (%v)", d.temp, err)); return }
		d.queued += i64(len(d.pending))
		clear(&d.pending)
	}
	if d.net_done && !d.writing && len(d.pending) == 0 && !d.asking && d.path != "" { download_finish(d) }
	if d.net_done && !d.writing && len(d.pending) == 0 && !d.asking && d.path == "" && !dls.cfg.ask {
		taken :: proc(name: string, user: rawptr) -> bool { return file_exists(path_join((^Download)(user).dir, name)) }
		d.path = path_join(d.dir, unique_file_name(d.name, taken, d), context.allocator)
		download_finish(d)
	}
}

@(private = "file")
write_done :: proc(data: rawptr) {
	j := (^Write_Job)(data)
	d := j.d
	defer { delete(j.buf); free(j) }
	d.writing = false
	if !j.ok && d.state == .Receiving { download_fail(d, fmt.tprintf("cannot write %s (%v)", d.temp, j.err)) }
	if d.state == .Failed || d.state == .Cancelled { download_discard(d); return }
	download_advance(d)
	request_frames(d.app, 2)
}

// Complete, and its place known: the temporary file becomes the file. The move can cross volumes (the Save dialog may
// put the file on another drive than the download folder the temporary file sits in), so it goes through download_move
// (download_move_<os>.odin), which copies across volumes when a rename cannot.
@(private = "file")
download_finish :: proc(d: ^Download) {
	os.close(d.handle)
	d.handle = nil
	d.state, d.moving = .Saving, true
	host.run_blocking(&d.app.blocking, proc(data: rawptr) {
		dl := (^Download)(data)
		if ok, why := download_move(dl.temp, dl.path); !ok {
			dl.error = fmt.aprintf("cannot move it to %s (%s)", dl.path, why)
		}
	}, proc(data: rawptr) {
		dl := (^Download)(data)
		dl.moving = false
		if dl.error != "" {
			dl.state = .Failed
			os.remove(dl.temp)
			ui.toast(.Bad, "Download failed: %s", dl.name)
		} else {
			dl.state = .Done
			dl.size = dl.received
			ui.toast(.Good, "Saved %s", filepath.base(dl.path))
		}
		download_ended(dl)
		request_frames(dl.app, 3)
	}, d)
}

@(private = "file")
download_fail :: proc(d: ^Download, why: string) {
	if d.state != .Receiving { return }
	d.state = .Failed
	delete(d.error)
	d.error = strings.clone(why)
	if d.task != base.NIL_HANDLE { fetch.cancel(&d.app.loader, d.task); d.task = base.NIL_HANDLE }
	ui.toast(.Bad, "Download failed: %s", d.name)
	if !d.writing { download_discard(d) }
	download_ended(d)
}

// A download is over (saved, failed or cancelled): when, and the list is written to the profile.
@(private = "file")
download_ended :: proc(d: ^Download) {
	d.done_ms = dl_now_ms()
	d.speed = 0
	d.unseen = true
	downloads_save(d.app)
	request_frames(d.app, 2)
}

// Stops a download in progress (Menu > Downloads, or the Save dialog cancelled).
download_cancel :: proc(d: ^Download) {
	if d.state != .Receiving { return }
	d.state = .Cancelled
	if d.task != base.NIL_HANDLE { fetch.cancel(&d.app.loader, d.task); d.task = base.NIL_HANDLE }
	if !d.writing { download_discard(d) }
	download_ended(d)
}

// A download that will not complete: its temporary file goes.
@(private = "file")
download_discard :: proc(d: ^Download) {
	clear(&d.pending)
	shrink(&d.pending)
	if d.handle != nil { os.close(d.handle); d.handle = nil }
	if d.temp != "" { os.remove(d.temp) }
}

////////////////////////////////
// The Save dialog (a worker thread: it blocks until the user answers)

@(private = "file")
download_dialog_work :: proc(data: rawptr) {
	d := (^Download)(data)
	dlg := platform.File_Dialog{
		owner            = active_window(d.app).win,
		suggested_name   = d.name,
		start_dir        = d.dir,
		start_known      = .Downloads,
		all_files        = true,
		overwrite_prompt = true,
		remember_id      = "download",
	}
	ext := filepath.ext(d.name)
	filters: [1]platform.File_Filter
	if len(ext) > 1 {
		dlg.default_ext = ext[1:]
		label := strings.concatenate({strings.to_upper(ext[1:], context.temp_allocator), " file"}, context.temp_allocator)
		patterns := [1]string{strings.concatenate({"*", ext}, context.temp_allocator)}
		filters[0] = {name = label, patterns = patterns[:]}
		dlg.filters = filters[:]
	}
	res := platform.save_file_dialog(dlg, context.allocator)
	defer platform.dialog_result_destroy(&res, context.allocator)
	if res.status == .Chosen && len(res.paths) > 0 { d.path = strings.clone(res.paths[0]) }
}

@(private = "file")
download_dialog_done :: proc(data: rawptr) {
	d := (^Download)(data)
	d.asking = false
	if d.path == "" { download_cancel(d); return }   // the dialog was cancelled
	if d.state == .Receiving { download_advance(d) } else if !d.writing { download_discard(d) }
	request_frames(d.app, 2)
}

////////////////////////////////
// List, menu, life cycle

downloads_active :: proc() -> int {
	n := 0
	for d in dls.list { if d.state == .Receiving || d.state == .Saving { n += 1 } }
	return n
}

// Stops every download in progress (wren ctl reset).
downloads_cancel_all :: proc() {
	for d in dls.list { download_cancel(d) }
}

// The finished downloads past browser.download.list_max go (never one with work still out).
@(private = "file")
downloads_prune :: proc() {
	finished := 0
	for d in dls.list { if d.state == .Done || d.state == .Failed || d.state == .Cancelled { finished += 1 } }
	for i := 0; i < len(dls.list) && finished > dls.cfg.list_max; {
		d := dls.list[i]
		if (d.state == .Done || d.state == .Failed || d.state == .Cancelled) && !d.writing && !d.asking && !d.moving {
			ordered_remove(&dls.list, i)
			download_free(d)
			finished -= 1
		} else { i += 1 }
	}
}

@(private = "file")
download_free :: proc(d: ^Download) {
	if d.handle != nil { os.close(d.handle) }
	if d.state != .Done && d.temp != "" { os.remove(d.temp) }
	if d.scope != nil { base.scope_close(d.scope) }   // (nil once the process scope closed it)
	delete(d.url); delete(d.name); delete(d.dir); delete(d.temp); delete(d.path); delete(d.error)
	delete(d.pending)
	free(d)
}

////////////////////////////////
// The list: what the page and the button read and do (downloads_ui.odin shows it)

download_finished :: proc(d: ^Download) -> bool { return d.state == .Done || d.state == .Failed || d.state == .Cancelled }

// A finished download no job of ours still points at: its row may go.
downloads_removable :: proc(d: ^Download) -> bool { return download_finished(d) && !d.writing && !d.asking && !d.moving }

// Takes a finished download off the list (the file stays where it is).
download_remove :: proc(app: ^App, d: ^Download) {
	if !downloads_removable(d) { return }
	for x, i in dls.list { if x == d { ordered_remove(&dls.list, i); break } }
	download_free(d)
	downloads_save(app)
	request_frames(app, 2)
}

// "Clear list": every finished download goes off the list (the files stay).
download_clear_finished :: proc(app: ^App) {
	for i := 0; i < len(dls.list); {
		if d := dls.list[i]; downloads_removable(d) { ordered_remove(&dls.list, i); download_free(d) } else { i += 1 }
	}
	downloads_save(app)
	request_frames(app, 2)
}

// Is the saved file still there? (looked up at most every 1.5 s per download: the page asks every frame)
download_file_present :: proc(d: ^Download) -> bool {
	if d.state != .Done || d.path == "" { return false }
	if now := dl_now_ms(); now - d.checked_ms > 1500 { d.checked_ms = now; d.missing = !os.exists(d.path) }
	return !d.missing
}

download_open_file :: proc(d: ^Download) {
	if !download_file_present(d) { ui.toast(.Warn, "%s is no longer there", d.name); return }
	platform.open_path(d.path)
}

download_reveal :: proc(d: ^Download) {
	if !download_file_present(d) { platform.reveal_in_folder(d.path); return }   // (the folder, when the file is gone)
	platform.reveal_in_folder(d.path)
}

// Deletes the saved file (it does not go to the recycle bin); the row stays, saying so.
download_delete_file :: proc(app: ^App, d: ^Download) {
	if d.state != .Done || d.path == "" { return }
	if err := os.remove(d.path); err != nil && os.exists(d.path) {
		ui.toast(.Bad, "Could not delete %s", d.name)
		return
	}
	d.missing, d.checked_ms = true, dl_now_ms()
	ui.toast(.Info, "Deleted %s", filepath.base(d.path))
	request_frames(app, 2)
}

// The address again, in a new tab: the server answers with the file as before.
download_retry :: proc(app: ^App, d: ^Download) {
	if d.url == "" { return }
	tab_open(app, strings.clone(d.url, context.temp_allocator), origin = .User)
}

downloads_mark_seen :: proc() {
	for d in dls.list { d.unseen = false }
}

// What the button shows: how many are running, how far they are all together (known: every size is announced), and the
// speed of the whole.
downloads_progress :: proc() -> (active: int, frac: f32, known: bool, speed: f64) {
	got, of: i64
	known = true
	for d in dls.list {
		if d.state != .Receiving && d.state != .Saving { continue }
		active += 1
		if d.state == .Receiving && d.total <= 0 { known = false } else { got += d.state == .Saving ? d.total : d.received; of += d.total }
		if d.state == .Receiving && dl_now_ms() - d.sample_ms < 2500 { speed += d.speed }
	}
	if active > 0 && known && of > 0 { frac = clamp(f32(f64(got) / f64(of)), 0, 1) }
	return
}

////////////////////////////////
// The list in the profile (downloads.txt): the finished downloads, so about:downloads is a history that survives a restart.
// One line each: state, started, ended (unix ms), size, address, path, name, error; tabs and line ends of them are spaces.

DOWNLOADS_FILE :: "downloads.txt"
DOWNLOADS_HEADER :: "wren-downloads 1"

@(private = "file")
downloads_path :: proc(app: ^App) -> string {
	if app.profile_dir == "" { return "" }
	return path_join(app.profile_dir, DOWNLOADS_FILE)
}

@(private = "file")
line_safe :: proc(s: string) -> string {
	if !strings.contains_any(s, "\t\r\n") { return s }
	out := make([]byte, len(s), context.temp_allocator)
	for i in 0 ..< len(s) { out[i] = s[i] == '\t' || s[i] == '\r' || s[i] == '\n' ? ' ' : s[i] }
	return string(out)
}

downloads_save :: proc(app: ^App) {
	path := downloads_path(app)
	if path == "" { return }
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "%s\n", DOWNLOADS_HEADER)
	for d in dls.list {
		if !download_finished(d) { continue }
		fmt.sbprintf(&sb, "%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\n", int(d.state), d.started_ms, d.done_ms, d.size, line_safe(d.url), line_safe(d.path), line_safe(d.name), line_safe(d.error))
	}
	_ = base.file_write_atomic(path, transmute([]byte)strings.to_string(sb), flush = true)
}

downloads_load :: proc(app: ^App) {
	path := downloads_path(app)
	if path == "" { return }
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return }
	lines := strings.split_lines(string(data), context.temp_allocator)
	if len(lines) == 0 || lines[0] != DOWNLOADS_HEADER { return }
	for line in lines[1:] {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 8 { continue }
		st, ok := strconv.parse_int(f[0])
		started, ok1 := strconv.parse_i64(f[1])
		ended, ok2 := strconv.parse_i64(f[2])
		size, ok3 := strconv.parse_i64(f[3])
		if !ok || !ok1 || !ok2 || !ok3 || st < int(Download_State.Done) || st > int(Download_State.Cancelled) || f[6] == "" { continue }
		d := new(Download)
		dls.ids += 1
		d.app, d.id, d.restored = app, dls.ids, true
		d.state = Download_State(st)
		d.started_ms, d.done_ms, d.size = started, ended, size
		d.received, d.total = size, size
		d.url, d.path, d.name, d.error = strings.clone(f[4]), strings.clone(f[5]), strings.clone(f[6]), strings.clone(f[7])
		append(&dls.list, d)
	}
}

// What a download-less profile shows on its button: nothing, until one happens (restored ones do not count).
downloads_session_started :: proc() -> bool {
	for d in dls.list { if !d.restored { return true } }
	return false
}

human_bytes :: proc(n: i64) -> string {
	switch {
	case n >= 1 << 30: return fmt.tprintf("%.1f GB", f64(n) / f64(1 << 30))
	case n >= 1 << 20: return fmt.tprintf("%.1f MB", f64(n) / f64(1 << 20))
	case n >= 1 << 10: return fmt.tprintf("%.0f kB", f64(n) / f64(1 << 10))
	}
	return fmt.tprintf("%d B", n)
}

// Shows the file in the system's file manager with it selected (platform.reveal_in_folder: Explorer /select on Windows,
// the file manager through the portal / xdg on Linux).
@(private = "file")
show_in_folder :: proc(path: string) {
	platform.reveal_in_folder(path)
}

downloads_init :: proc(app: ^App) {
	download_cfg(app)
	downloads_load(app)
	downloads_prune()
}

// Preferences changed.
downloads_apply :: proc(app: ^App) { download_cfg(app) }

// After the blocking threads stopped (nothing writes any more, no callback will come): what is left goes; unfinished
// downloads lose their temporary file.
downloads_shutdown :: proc() {
	for d in dls.list { download_free(d) }
	delete(dls.list)
	delete(dls.cfg.dir); delete(dls.cfg.suffix); delete(dls.cfg.button)
	dls = {}
}
