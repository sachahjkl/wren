package browser

// Downloads: a navigation whose answer is not a document the browser shows (Content-Disposition: attachment, or a type
// it does not display: archives, executables, PDF, media...) becomes a download, as in every browser:
//   * the connection that brought the answer goes on as the download (fetch.task_hand_over): nothing is asked twice,
//     a POST or a one-time link work;
//   * the tab keeps the page it showed (the navigation does not happen: no history entry, the held page comes back);
//     a tab opened only for it closes;
//   * the body streams to a temporary file next to the destination ("name.ext.wrenpart"), written on the blocking
//     threads one chunk at a time; while a chunk is being written the request is paused (fetch.task_pause), so what
//     arrives meanwhile stays in the network stack, at most network.queue.high_water_bytes: a disk slower than the
//     network slows the download down instead of filling memory, and the interface thread never writes;
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
import desktop "toolkit:desktop"
import "wb:base"
import "wb:config"
import "wb:fetch"
import "wb:host"
import "wb:http"
import "wb:images"
import "wb:page"
import "wb:url"

// The longest file name made for a download, in bytes (the extension kept).
DOWNLOAD_NAME_MAX_BYTES :: 200
// The speed is measured over at least this long, for a steady figure.
DOWNLOAD_SPEED_SAMPLE_MS :: 350
// A download with no data for this long counts as stalled: its speed is not shown (downloads_ui.odin too).
DOWNLOAD_STALLED_MS :: 2500
// How often a finished download's file is checked to still exist.
DOWNLOAD_EXISTS_CHECK_MS :: 1500

DOWNLOAD_PREFS := [?]config.Def{
	{name = "browser.download.ask", kind = .Bool, default = {b = false},
		description = "Ask where to save each download (the Save dialog of Windows). Off (the default): downloads go at once to browser.download.directory, the Downloads folder of Windows when it is empty, under a name that is free."},
	{name = "browser.download.directory", kind = .String, default = {s = ""},
		description = "Folder downloads go to (and where the Save dialog starts). Empty: the Downloads folder of Windows."},
	{name = "browser.download.max_bytes", kind = .Int, default = {i = 0}, bounded = true, min = 0, max = 1 << 50, bytes = true, unit = "bytes",
		description = "Largest download accepted; 0 = no limit."},
	{name = "browser.download.flush_bytes", kind = .Int, default = {i = 1 << 20}, bounded = true, min = 4 << 10, max = 256 << 20, bytes = true, unit = "bytes",
		description = "Bytes gathered before a chunk is written to disk (on a background thread)."},
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
	case mime == "application/octet-stream" && base.ascii_has_suffix_fold(path, ".wasm"): return .Wasm
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
	attachment = base.ascii_equal_fold(strings.trim_space(kind), "attachment")
	plain, extended: string
	has_ext := false
	for len(s) > 0 {
		s = strings.trim_left_space(s)
		eq := strings.index_byte(s, '=')
		if eq < 0 { break }
		key := base.ascii_lower(strings.trim_space(s[:eq]))
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
	charset := base.ascii_lower(v[:q1])
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
download_file_name :: proc(suggested, address, mime: string, max_bytes := DOWNLOAD_NAME_MAX_BYTES, allocator := context.temp_allocator) -> string {
	name := suggested
	if strings.trim_space(name) == "" {
		p := address
		if i := strings.index_any(p, "?#"); i >= 0 { p = p[:i] }
		if i := strings.last_index_byte(p, '/'); i >= 0 { p = p[i + 1:] }
		name = url.percent_decode(p)
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
	stem := name
	if i := strings.index_byte(name, '.'); i >= 0 { stem = name[:i] }
	upper := base.ascii_upper(strings.trim_right(stem, " "))
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
// Chrome (the page loads it again through the image cache). Once decoded it is a viewer: zoom, pan, rotation
// (page/image_document.odin, its input: image_document_shell.odin).
show_image_document :: proc(app: ^App, load: ^Doc_Load) {
	t := load.tab
	name := download_file_name("", t.url, "", allocator = context.temp_allocator)
	// (style attributes, not a <style> sheet: a sheet of a document written with load_html into a page of a web origin
	// is not applied, see the report of the chrome branch)
	html := fmt.tprintf(`<!doctype html><html style="color-scheme: dark; background: #0e0e0e; overflow: hidden"><head><meta charset="utf-8"><title>%s</title></head><body style="margin: 0"><img style="position: absolute; top: 0; right: 0; bottom: 0; left: 0; margin: auto; display: block; max-width: 100%%; max-height: 100%%" src="%s" alt=""></body></html>`,
		escape_html(name), escape_html(t.url))
	// (the page is made now, with the document right away: the image response itself made none)
	if load.page == nil {
		load.page = page.page_create(&app.loop, &app.loader, &app.page_settings, t.nav, load.final_url, console_sink, t)
		nav_adopt(app, t, load.page)
	}
	page.load_html(load.page, transmute([]byte)html)
	page.image_document_begin(load.page)
	set_status(t, fmt.tprintf("HTTP %d, image", load.status))
}

////////////////////////////////
// Downloads
//
// One state per download, changed only by download_to (the transitions download_transition_ok allows):
//
//     Receiving ──net done──▶ Flushing ──all on disk, place known──▶ Moving ──moved──▶ Done
//                               │   └──all on disk, Save dialog open──▶ Awaiting_Path ──answered──▶ Moving
//     any of the first three ──cancel, dialog cancelled──▶ Cancelled;   ──network or disk error──▶ Failed   (Moving ──▶ Failed)
//
// Work of ours that holds a pointer to the download (`out`: a chunk write, the Save dialog, the move) is not a state: it
// can run in several states, and a download leaves the list only when none is out. The temporary file belongs to the
// state machine: download_to closes it for the move, and download_temp_drop removes it once the download ends without
// it (at once, or when the write out comes back).

Download_State :: enum u8 {
	Receiving,       // the body streams in; full chunks go to the temporary file
	Flushing,        // the body is all here; what is left goes to the temporary file
	Awaiting_Path,   // all of it is in the temporary file; the Save dialog has not answered yet
	Moving,          // the temporary file goes to its place (a job of the blocking pool)
	Done,
	Failed,
	Cancelled,
}

// Work of ours that is out with a pointer to the download.
Download_Work :: enum u8 { Write, Dialog, Move }

Download :: struct {
	app:       ^App,
	id:        u64,
	url:       string,          // owned
	name:      string,          // owned: the file name suggested
	dir:       string,          // owned: the folder of the temporary file
	temp:      string,          // owned: the temporary file ("" once moved or removed)
	path:      string,          // owned: the destination ("" until known)
	handle:    ^os.File,        // the open temporary file (nil: none)
	task:      base.Handle,
	scope:     ^base.Scope,     // the request's (child of the process scope)
	total:     i64,             // Content-Length, -1 unknown
	received:  i64,
	queued:    i64,             // offset of the next chunk handed to the disk
	pending:   [dynamic]byte,   // received, not handed to the disk yet
	state:     Download_State,
	out:       bit_set[Download_Work],
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
	checked_ms: i64,            // when `missing` was last asked for (downloads_check_files)
}

Downloads :: struct {
	list:  [dynamic]^Download,
	ids:   u64,
	cfg:   struct { ask: bool, dir: string, max_bytes, flush, list_max: int, suffix: string, button: string },
	// the applications that open the file of the download whose menu is open (downloads_ui.odin "Open with"): read once
	// when its menu shows them, not at every frame
	handlers_for: u64,
	handlers:     []desktop.Handler,
	file:         host.Profile_File,   // downloads.txt (profile_writes.odin)
	checking:     bool,           // a job looks whether saved files are still there
	closing:      bool,           // downloads_shutdown runs: the list is no longer written at each end
}

// Whether a download may go from `from` to `to` (pure: download_test.odin).
download_transition_ok :: proc(from, to: Download_State) -> bool {
	switch from {
	case .Receiving:     return to == .Flushing || to == .Failed || to == .Cancelled
	case .Flushing:      return to == .Awaiting_Path || to == .Moving || to == .Failed || to == .Cancelled
	case .Awaiting_Path: return to == .Moving || to == .Failed || to == .Cancelled
	case .Moving:        return to == .Done || to == .Failed
	case .Done, .Failed, .Cancelled:
	}
	return false
}

// The folder picker of the downloads page: the folder chosen becomes browser.download.directory.
@(private = "file")
Folder_Job :: struct { app: ^App, owner: ^platform.Window, start, chosen: string }

download_pick_folder :: proc(app: ^App) {
	if app.dl_picking { return }
	job := new(Folder_Job)
	job.app, job.start = app, strings.clone(download_dir(app))
	job.owner = active_window(app).win   // (read here: the dialog's thread does not touch the App)
	// (a thread of its own, host.run_dialog: the dialog holds it until the user answers)
	started := host.run_dialog(&app.dialogs, proc(data: rawptr) {
		j := (^Folder_Job)(data)
		dlg := platform.File_Dialog{owner = j.owner, title = "Folder for the downloads", start_dir = j.start, start_known = .Downloads, remember_id = "download_dir"}
		res := platform.pick_folder_dialog(dlg, context.allocator)
		defer platform.dialog_result_destroy(&res, context.allocator)
		if res.status == .Chosen && len(res.paths) > 0 { j.chosen = strings.clone(res.paths[0]) }
	}, proc(data: rawptr) {
		j := (^Folder_Job)(data)
		j.app.dl_picking = false
		if j.chosen != "" {
			if err := config.set_from_string(&j.app.prefs, "browser.download.directory", j.chosen, .User); err != .None {
				ui.toast(.Warn, "browser.download.directory: %s", config.set_error_text(err))
			}
		}
		request_frames(j.app, 2)
		delete(j.start); delete(j.chosen); free(j)
	}, job, proc(data: rawptr) {   // (the browser ended before the answer was read)
		j := (^Folder_Job)(data)
		delete(j.start); delete(j.chosen); free(j)
	})
	if !started {
		ui.toast(.Bad, "The folder dialog could not be opened")
		delete(job.start); free(job)
		return
	}
	app.dl_picking = true
}

// Back to the Downloads folder of Windows.
download_folder_default :: proc(app: ^App) {
	_ = config.set_from_string(&app.prefs, "browser.download.directory", "", .User)
	request_frames(app, 2)
}

dl_now_ms :: proc() -> i64 { return time.time_to_unix_nano(time.now()) / 1e6 }

@(private = "file")
download_cfg :: proc(app: ^App) {
	delete(app.dls.cfg.dir); delete(app.dls.cfg.suffix); delete(app.dls.cfg.button)
	p := &app.prefs
	app.dls.cfg.button = strings.clone(config.string_of(p, "browser.download.button"))
	app.dls.cfg.ask = config.bool_of(p, "browser.download.ask")
	app.dls.cfg.dir = strings.clone(config.string_of(p, "browser.download.directory"))
	app.dls.cfg.max_bytes = int(config.int_of(p, "browser.download.max_bytes"))
	app.dls.cfg.flush = int(config.int_of(p, "browser.download.flush_bytes"))
	app.dls.cfg.list_max = int(config.int_of(p, "browser.download.list_max"))
	suffix := config.string_of(p, "browser.download.temp_suffix")
	app.dls.cfg.suffix = strings.clone(suffix != "" ? suffix : ".wrenpart")
}

// The folder downloads go to: the preference, else the system's Downloads folder, else the profile.
download_dir :: proc(app: ^App) -> string {
	if app.dls.cfg.dir != "" { return app.dls.cfg.dir }
	if d := platform.known_folder_path(.Downloads, context.temp_allocator); d != "" { return d }
	return app.profile_dir
}

@(private = "file")
path_join :: proc(dir, name: string, allocator := context.temp_allocator) -> string {
	if dir == "" || strings.has_suffix(dir, "\\") || strings.has_suffix(dir, "/") { return strings.concatenate({dir, name}, allocator) }
	return strings.concatenate({dir, filepath.SEPARATOR_STRING, name}, allocator)
}

// The navigation `load` got an answer to save rather than show (`task` is its request, `r` the answer).
download_from_navigation :: proc(app: ^App, load: ^Doc_Load, task: base.Handle, r: ^fetch.Response, disposition: string) {
	if app.dls.cfg.suffix == "" { download_cfg(app) }
	downloads_prune(app)   // (only here: no download is being worked on)
	_, suggested := parse_content_disposition(disposition)
	mime := r.has_mime ? http.mime_essence(r.mime) : ""
	d := new(Download)
	app.dls.ids += 1
	d.app, d.id, d.total = app, app.dls.ids, -1
	d.started_ms = dl_now_ms()
	d.sample_ms = d.started_ms
	d.url = strings.clone(r.url)
	d.name = download_file_name(suggested, r.url, mime, allocator = context.allocator)
	if v, ok := http.get_header(r.headers, "content-length"); ok {
		if n, nok := strconv.parse_i64(strings.trim_space(v)); nok && n >= 0 { d.total = n }
	}
	d.scope = base.scope_make("download", app.process)
	d.task = task
	max_body := app.dls.cfg.max_bytes > 0 ? app.dls.cfg.max_bytes : max(int)
	fetch.task_hand_over(&app.loader, task, d.scope, download_event, d, collect = false, max_body = max_body)
	base.on_close(d.scope, proc(data: rawptr) {
		dl := (^Download)(data)
		dl.task, dl.scope = base.NIL_HANDLE, nil   // the scope's own cleanup cancels the request
		// (the process ends, or the download is freed: a download still running is cancelled the usual way)
		if dl.state == .Receiving || dl.state == .Flushing || dl.state == .Awaiting_Path { download_to(dl, .Cancelled) }
	}, d)
	append(&app.dls.list, d)
	load.task = base.NIL_HANDLE

	// the temporary file, next to where it will most likely go
	d.dir = strings.clone(download_dir(app))
	if !download_open_temp(app, d) {
		download_to(d, .Failed, fmt.tprintf("cannot write in %s", d.dir))
	} else {
		window_ask(app, .Downloads_Panel)   // the button's drop-down shows it running (downloads_ui.odin)
		if app.dls.cfg.button == "never" { ui.toast(.Info, "Downloading %s", d.name) }
		if app.dls.cfg.ask { download_dialog_open(app, d) }
	}
	nav_cancel(app, load.tab, load, .Downloaded)   // `load` is gone after this
	request_frames(app, 2)
}

@(private = "file")
download_open_temp :: proc(app: ^App, d: ^Download) -> bool {
	for i in 0 ..< 1000 {
		base_name := i == 0 ? d.name : fmt.tprintf("%s (%d)", d.name, i)
		path := path_join(d.dir, strings.concatenate({base_name, app.dls.cfg.suffix}, context.temp_allocator))
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

@(private = "file")
download_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	d := (^Download)(user)
	#partial switch ev.kind {
	case .Data:
		if d.state != .Receiving { return }
		append(&d.pending, ..ev.data)
		d.received += i64(len(ev.data))
		// the speed: measured over at least a third of a second, smoothed (a steady figure for the bar and the time left)
		if now := dl_now_ms(); now - d.sample_ms >= DOWNLOAD_SPEED_SAMPLE_MS {
			inst := f64(d.received - d.sample_bytes) * 1000 / f64(now - d.sample_ms)
			d.speed = d.speed > 0 ? d.speed * 0.65 + inst * 0.35 : inst
			d.sample_ms, d.sample_bytes = now, d.received
		}
	case .Done:
		d.task = base.NIL_HANDLE
		download_to(d, .Flushing)
	case .Failed:
		d.task = base.NIL_HANDLE
		download_to(d, .Failed, ev.detail)
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

// Writes `buf` at `offset` (positional: the offset is the download's, not a cursor of the file that a worker thread would
// share). os.write_at is pwrite on POSIX and WriteFile with an OVERLAPPED on Windows.
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

// The one place a download changes state (see the top of this part). Entering an end state stops the request, lets the
// temporary file go, says so and writes the list; entering Moving hands the file to the move job.
@(private = "file")
download_to :: proc(d: ^Download, to: Download_State, why := "") {
	if !download_transition_ok(d.state, to) { return }
	d.state = to
	app := d.app
	switch to {
	case .Receiving, .Flushing, .Awaiting_Path:
	case .Moving:
		if d.handle != nil { os.close(d.handle); d.handle = nil }
		job := new(Move_Job)
		job^ = {d = d, temp = strings.clone(d.temp), dir = strings.clone(d.dir), name = strings.clone(d.name), path = strings.clone(d.path)}
		d.out += {.Move}
		if profile_pool_ready(app) {
			host.run_blocking(&app.blocking, download_move_work, download_move_done, job)
		} else {
			download_move_work(job)
			download_move_done(job)
		}
	case .Done:
		d.size = d.received
		ui.toast(.Good, "Saved %s", filepath.base(d.path))
		notification_download(app, d)   // notification_shell.odin: told by the system when Wren is not in front
		download_ended(d)
	case .Failed, .Cancelled:
		if d.task != base.NIL_HANDLE { fetch.cancel(&app.loader, d.task); d.task = base.NIL_HANDLE }
		if to == .Failed {
			delete(d.error)
			d.error = strings.clone(why)
			ui.toast(.Bad, "Download failed: %s", d.name)
		}
		download_temp_drop(d)
		download_ended(d)
	}
}

// What comes next for a download that receives or writes: a chunk to the disk, the bound on memory, the next state.
@(private = "file")
download_advance :: proc(d: ^Download) {
	app := d.app
	#partial switch d.state {
	case .Receiving, .Flushing:
		if .Write not_in d.out && len(d.pending) > 0 && (len(d.pending) >= app.dls.cfg.flush || d.state == .Flushing) {
			job := new(Write_Job)
			job.d, job.handle, job.offset = d, d.handle, d.queued
			job.buf = make([]byte, len(d.pending))
			copy(job.buf, d.pending[:])
			d.queued += i64(len(d.pending))
			clear(&d.pending)
			d.out += {.Write}
			if profile_pool_ready(app) {
				host.run_blocking(&app.blocking, proc(data: rawptr) {
					j := (^Write_Job)(data)
					j.ok, j.err = write_at(j.handle, j.buf, j.offset)
				}, write_done, job)
			} else {
				job.ok, job.err = write_at(job.handle, job.buf, job.offset)
				write_done(job)
				return   // (write_done advanced it)
			}
		}
		// the request waits while a chunk is written: what the network brings meanwhile stays in it, one window at most
		// (net.pause), so `pending` holds what came between two writes and the disk sets the pace
		if d.task != base.NIL_HANDLE { fetch.task_pause(&app.loader, d.task, .Write in d.out) }
		if d.state == .Flushing && .Write not_in d.out && len(d.pending) == 0 {
			// (no place yet and no dialog: the move job picks a free name in the folder)
			download_to(d, d.path == "" && .Dialog in d.out ? .Awaiting_Path : .Moving)
		}
	case .Awaiting_Path:
		if d.path != "" { download_to(d, .Moving) }
	}
}

@(private = "file")
write_done :: proc(data: rawptr) {
	j := (^Write_Job)(data)
	d := j.d
	defer { delete(j.buf); free(j) }
	d.out -= {.Write}
	if !j.ok { download_to(d, .Failed, fmt.tprintf("cannot write %s (%v)", d.temp, j.err)) }
	if download_finished(d) { download_temp_drop(d); return }   // (it ended while the write was out)
	download_advance(d)
	request_frames(d.app, 2)
}

// The temporary file of a download that ended without it goes (once no write holds its handle; again later is nothing).
@(private = "file")
download_temp_drop :: proc(d: ^Download) {
	if .Write in d.out { return }   // (write_done calls it again)
	clear(&d.pending)
	shrink(&d.pending)
	if d.handle != nil { os.close(d.handle); d.handle = nil }
	if d.temp != "" { os.remove(d.temp); delete(d.temp); d.temp = "" }
}

// The move of the temporary file to its place. The move can cross volumes (the Save dialog may put the file on another
// drive than the download folder the temporary file sits in), so it goes through download_move (download_move_<os>.odin),
// which copies across volumes when a rename cannot. Without a place chosen, a free name of the folder is found here too:
// the lookups are the disk's, off the interface thread.
@(private = "file")
Move_Job :: struct {
	d:                     ^Download,
	temp, dir, name, path: string,   // owned; `path` "": a free name in `dir`
	error:                 string,   // owned: why it failed ("": moved)
}

@(private = "file")
download_move_work :: proc(data: rawptr) {
	j := (^Move_Job)(data)
	if j.path == "" {
		taken :: proc(name: string, user: rawptr) -> bool { return os.exists(path_join((^string)(user)^, name)) }
		delete(j.path)
		j.path = path_join(j.dir, unique_file_name(j.name, taken, &j.dir), context.allocator)
	}
	if ok, why := download_move(j.temp, j.path); !ok { j.error = fmt.aprintf("cannot move it to %s (%s)", j.path, why) }
}

@(private = "file")
download_move_done :: proc(data: rawptr) {
	j := (^Move_Job)(data)
	d := j.d
	defer { delete(j.temp); delete(j.dir); delete(j.name); delete(j.path); delete(j.error); free(j) }
	d.out -= {.Move}
	if d.path == "" { d.path, j.path = j.path, "" }
	if j.error != "" {
		download_to(d, .Failed, j.error)
	} else {
		delete(d.temp)
		d.temp = ""   // (it is the file now)
		download_to(d, .Done)
	}
	request_frames(d.app, 3)
}

// A download is over (saved, failed or cancelled): when, and the list is written to the profile.
@(private = "file")
download_ended :: proc(d: ^Download) {
	d.done_ms = dl_now_ms()
	d.speed = 0
	d.unseen = true
	if d.app.dls.closing { return }
	downloads_save(d.app)
	request_frames(d.app, 2)
}

// Stops a download in progress (Menu > Downloads, or the Save dialog cancelled). A download being moved finishes.
download_cancel :: proc(d: ^Download) {
	download_to(d, .Cancelled)
}

////////////////////////////////
// The Save dialog (a thread of its own: it blocks until the user answers; host.run_dialog)

@(private = "file")
Dialog_Job :: struct {
	d:      ^Download,
	owner:  ^platform.Window,
	name:   string,   // owned
	dir:    string,   // owned
	chosen: string,   // owned: the answer ("": cancelled)
}

@(private = "file")
download_dialog_open :: proc(app: ^App, d: ^Download) {
	job := new(Dialog_Job)
	job^ = {d = d, owner = active_window(app).win, name = strings.clone(d.name), dir = strings.clone(d.dir)}
	if !host.run_dialog(&app.dialogs, download_dialog_work, download_dialog_done, job, download_dialog_discard) {
		download_dialog_discard(job)
		return   // (no dialog: it goes to the folder under a free name, as with browser.download.ask off)
	}
	d.out += {.Dialog}
}

@(private = "file")
download_dialog_work :: proc(data: rawptr) {
	j := (^Dialog_Job)(data)
	dlg := platform.File_Dialog{
		owner            = j.owner,
		suggested_name   = j.name,
		start_dir        = j.dir,
		start_known      = .Downloads,
		all_files        = true,
		overwrite_prompt = true,
		remember_id      = "download",
	}
	ext := filepath.ext(j.name)
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
	if res.status == .Chosen && len(res.paths) > 0 { j.chosen = strings.clone(res.paths[0]) }
}

// The browser ended after the answer came and before it was read (host.dialogs_destroy).
@(private = "file")
download_dialog_discard :: proc(data: rawptr) {
	j := (^Dialog_Job)(data)
	delete(j.name); delete(j.dir); delete(j.chosen); free(j)
}

@(private = "file")
download_dialog_done :: proc(data: rawptr) {
	j := (^Dialog_Job)(data)
	d := j.d
	defer download_dialog_discard(j)
	d.out -= {.Dialog}
	if download_finished(d) { return }   // (it ended meanwhile: failed, or cancelled from the list)
	if j.chosen == "" { download_to(d, .Cancelled); request_frames(d.app, 2); return }
	delete(d.path)
	d.path, j.chosen = j.chosen, ""
	download_advance(d)
	request_frames(d.app, 2)
}

////////////////////////////////
// List, menu, life cycle

// Not ended yet: receiving, writing, waiting for its place or being moved.
download_running :: proc(d: ^Download) -> bool { return !download_finished(d) }

downloads_active :: proc(app: ^App) -> int {
	n := 0
	for d in app.dls.list { if download_running(d) { n += 1 } }
	return n
}

// Stops every download in progress (wren ctl reset).
downloads_cancel_all :: proc(app: ^App) {
	for d in app.dls.list { download_cancel(d) }
}

// The finished downloads past browser.download.list_max go (never one with work still out).
@(private = "file")
downloads_prune :: proc(app: ^App) {
	finished := 0
	for d in app.dls.list { if download_finished(d) { finished += 1 } }
	k := 0
	for d in app.dls.list {
		if finished > app.dls.cfg.list_max && downloads_removable(d) {
			download_free(d)
			finished -= 1
			continue
		}
		app.dls.list[k] = d
		k += 1
	}
	resize(&app.dls.list, k)
}

@(private = "file")
download_free :: proc(d: ^Download) {
	if d.scope != nil { base.scope_close(d.scope) }   // (nil once the process scope closed it; a running one is cancelled)
	if d.handle != nil { os.close(d.handle) }
	if d.state != .Done && d.temp != "" { os.remove(d.temp) }
	delete(d.url); delete(d.name); delete(d.dir); delete(d.temp); delete(d.path); delete(d.error)
	delete(d.pending)
	free(d)
}

////////////////////////////////
// The list: what the page and the button read and do (downloads_ui.odin shows it)

download_finished :: proc(d: ^Download) -> bool { return d.state == .Done || d.state == .Failed || d.state == .Cancelled }

// A finished download no work of ours still points at: its row may go.
downloads_removable :: proc(d: ^Download) -> bool { return download_finished(d) && d.out == {} }

// Takes a finished download off the list (the file stays where it is).
download_remove :: proc(app: ^App, d: ^Download) {
	if !downloads_removable(d) { return }
	for x, i in app.dls.list { if x == d { ordered_remove(&app.dls.list, i); break } }
	download_free(d)
	downloads_save(app)
	request_frames(app, 2)
}

// "Clear list": every finished download goes off the list (the files stay).
download_clear_finished :: proc(app: ^App) {
	k := 0
	for d in app.dls.list {
		if downloads_removable(d) { download_free(d); continue }
		app.dls.list[k] = d
		k += 1
	}
	resize(&app.dls.list, k)
	downloads_save(app)
	request_frames(app, 2)
}

// Is the saved file still there? What was last found out: the page asks at every frame, and the lookups (at most every
// DOWNLOAD_EXISTS_CHECK_MS per download) run on the blocking pool (downloads_check_files).
download_file_present :: proc(d: ^Download) -> bool {
	if d.state != .Done || d.path == "" { return false }
	if dl_now_ms() - d.checked_ms > DOWNLOAD_EXISTS_CHECK_MS { downloads_check_files(d.app) }
	return !d.missing
}

@(private = "file")
Exists_Job :: struct {
	app:     ^App,
	ids:     []u64,
	paths:   []string,   // owned
	missing: []bool,
}

// Looks up, in one job, whether the files of the saved downloads due for it are still there.
@(private = "file")
downloads_check_files :: proc(app: ^App) {
	if app.dls.checking { return }
	now := dl_now_ms()
	ids := make([dynamic]u64, context.temp_allocator)
	paths := make([dynamic]string, context.temp_allocator)
	for d in app.dls.list {
		if d.state != .Done || d.path == "" || now - d.checked_ms <= DOWNLOAD_EXISTS_CHECK_MS { continue }
		d.checked_ms = now
		append(&ids, d.id)
		append(&paths, strings.clone(d.path))
	}
	if len(ids) == 0 { return }
	job := new(Exists_Job)
	job.app = app
	job.ids = make([]u64, len(ids))
	copy(job.ids, ids[:])
	job.paths = make([]string, len(paths))
	copy(job.paths, paths[:])
	job.missing = make([]bool, len(ids))
	work :: proc(data: rawptr) {
		j := (^Exists_Job)(data)
		for p, i in j.paths { j.missing[i] = !os.exists(p) }
	}
	done :: proc(data: rawptr) {
		j := (^Exists_Job)(data)
		app := j.app
		app.dls.checking = false
		changed := false
		for id, i in j.ids {
			for d in app.dls.list {
				if d.id != id { continue }
				if d.missing != j.missing[i] { d.missing = j.missing[i]; changed = true }
				break
			}
		}
		for p in j.paths { delete(p) }
		delete(j.ids); delete(j.paths); delete(j.missing); free(j)
		if changed { request_frames(app, 2) } else { host.quiet_note(&app.loop) }
	}
	app.dls.checking = true
	if profile_pool_ready(app) { host.run_blocking(&app.blocking, work, done, job) } else { work(job); done(job) }
}

download_open_file :: proc(d: ^Download) {
	if !download_file_present(d) { ui.toast(.Warn, "%s is no longer there", d.name); return }
	platform.open_path(d.path)
}

download_reveal :: proc(d: ^Download) {
	platform.reveal_in_folder(d.path)   // (the folder, when the file is gone)
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

downloads_mark_seen :: proc(app: ^App) {
	for d in app.dls.list { d.unseen = false }
}

// What the button shows: how many are running, how far they are all together (known: every size is announced), and the
// speed of the whole.
downloads_progress :: proc(app: ^App) -> (active: int, frac: f32, known: bool, speed: f64) {
	got, of: i64
	known = true
	for d in app.dls.list {
		if !download_running(d) { continue }
		active += 1
		// (past Receiving everything is here: the bar is full)
		if d.state == .Receiving && d.total <= 0 { known = false } else { got += d.state == .Receiving ? d.received : max(d.total, d.received); of += max(d.total, d.received) }
		if d.state == .Receiving && dl_now_ms() - d.sample_ms < DOWNLOAD_STALLED_MS { speed += d.speed }
	}
	if active > 0 && known && of > 0 { frac = clamp(f32(f64(got) / f64(of)), 0, 1) }
	return
}

////////////////////////////////
// The list in the profile (downloads.txt): the finished downloads, so about:downloads is a history that survives a restart.
// One line each: state (2 saved, 3 failed, 4 cancelled), started, ended (unix ms), size, address, path, name, error; tabs
// and line ends of them are spaces.

DOWNLOADS_FILE :: "downloads.txt"
DOWNLOADS_HEADER :: "wren-downloads 1"

// The code of an end state in downloads.txt (0: not written), and back.
@(private = "file")
download_state_code :: proc(s: Download_State) -> int {
	#partial switch s {
	case .Done:      return 2
	case .Failed:    return 3
	case .Cancelled: return 4
	}
	return 0
}

@(private = "file")
download_state_of_code :: proc(code: int) -> (Download_State, bool) {
	switch code {
	case 2: return .Done, true
	case 3: return .Failed, true
	case 4: return .Cancelled, true
	}
	return .Failed, false
}

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

// The text is made here; the blocking pool writes it (profile_writes.odin: one write at a time, a failure tried again).
downloads_save :: proc(app: ^App) {
	path := downloads_path(app)
	if path == "" { return }
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "%s\n", DOWNLOADS_HEADER)
	for d in app.dls.list {
		if !download_finished(d) { continue }
		fmt.sbprintf(&sb, "%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\n", download_state_code(d.state), d.started_ms, d.done_ms, d.size, line_safe(d.url), line_safe(d.path), line_safe(d.name), line_safe(d.error))
	}
	host.profile_file_init(&app.dls.file, &app.writer, path, flush = true)
	host.profile_file_write(&app.dls.file, strings.to_string(sb))
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
		code, ok := strconv.parse_int(f[0])
		started, ok1 := strconv.parse_i64(f[1])
		ended, ok2 := strconv.parse_i64(f[2])
		size, ok3 := strconv.parse_i64(f[3])
		st, sok := download_state_of_code(code)
		if !ok || !ok1 || !ok2 || !ok3 || !sok || f[6] == "" { continue }
		d := new(Download)
		app.dls.ids += 1
		d.app, d.id, d.restored = app, app.dls.ids, true
		d.state = st
		d.started_ms, d.done_ms, d.size = started, ended, size
		d.received, d.total = size, size
		d.url, d.path, d.name, d.error = strings.clone(f[4]), strings.clone(f[5]), strings.clone(f[6]), strings.clone(f[7])
		append(&app.dls.list, d)
	}
}

// What a download-less profile shows on its button: nothing, until one happens (restored ones do not count).
downloads_session_started :: proc(app: ^App) -> bool {
	for d in app.dls.list { if !d.restored { return true } }
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

downloads_init :: proc(app: ^App) {
	download_cfg(app)
	downloads_load(app)
	downloads_prune(app)
}

// Preferences changed.
downloads_apply :: proc(app: ^App) { download_cfg(app) }

// After the blocking threads stopped (nothing writes any more, no callback will come): the list is written once, then what
// is left goes; unfinished downloads lose their temporary file (each one's scope cancels it).
downloads_shutdown :: proc(app: ^App) {
	app.dls.closing = true
	host.profile_file_flush(&app.dls.file)   // (written on this thread from now on)
	for d in app.dls.list { download_free(d) }
	delete(app.dls.list)
	host.profile_file_destroy(&app.dls.file)
	desktop.handlers_destroy(app.dls.handlers, base.process_allocator())
	delete(app.dls.cfg.dir); delete(app.dls.cfg.suffix); delete(app.dls.cfg.button)
	app.dls = {}
}
