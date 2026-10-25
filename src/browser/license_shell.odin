package browser

import "core:os"
import "core:strings"
import win "core:sys/windows"
import "wb:config"
import "wb:fetch"
import "wb:host"
import "wb:license"
import "wb:page"
import "wb:url"

////////////////////////////////
// The shell's side of the support licence (package license: the format and the signature check). The licence is a
// small text file in the profile (license.wrenlicense; browser.license.path elsewhere); it is read and checked only
// when about:wren is built, so it costs nothing at start-up and nothing while browsing. It changes what about:wren
// says and nothing else: no feature depends on it, nothing reminds of it. No network is used.

SUPPORT_URL :: "https://sachahjkl.github.io/wren/support.html"

LICENSE_PREFS := [?]config.Def{
	{name = "browser.license.path", kind = .String, default = {s = ""},
		description = "Where the licence key is kept, a file. Empty: license.wrenlicense in the profile folder (or in memory only when browser.profile.persist is off)."},
	{name = "browser.license.public_key", kind = .String, default = {s = ""},
		description = "The public key (base64url) licences are checked with. Empty: the key built into this version of Wren. Another key reads the licences of another issuer."},
	{name = "browser.license.support_url", kind = .String, default = {s = SUPPORT_URL},
		description = "The page the 'Support Wren' link of about:wren opens."},
}

register_license_prefs :: proc(p: ^config.Prefs) { config.register(p, LICENSE_PREFS[:]) }

License_State :: struct {
	lic:        license.License,   // temporary allocator
	registered: bool,
	stored:     bool,              // some key is stored (it may not check out: err)
	err:        license.Error,
}

// The key kept in memory when the profile is not persisted (no allocation: a licence is a few hundred bytes).
@(private = "file") memory_text: [license.MAX_TEXT]u8
@(private = "file") memory_len: int

// An experimental build (tools\experimental.ps1: build.bat with WREN_ACCEPT_DEV_LICENSE_KEY=1) accepts the development pair's licences too, so that
// the demonstration licence it is handed out with shows its card with no setting. A release never does.
@(private = "file") ACCEPT_DEV_LICENSE_KEY :: IS_DEV_BUILD || #config(WREN_ACCEPT_DEV_LICENSE_KEY, false)

license_public_key :: proc(app: ^App) -> string {
	if k := strings.trim_space(config.string_of(&app.prefs, "browser.license.public_key")); k != "" { return k }
	return license.PRODUCTION_PUBLIC_KEY
}

// Checks a licence with the key in force; a development build also accepts the development pair's licences (tools\license.ps1
// issue -dev), so that a build being tried shows the card without settings. A release only knows the production key (an experimental build: see ACCEPT_DEV_LICENSE_KEY).
license_check :: proc(app: ^App, text: string, allocator := context.allocator) -> (license.License, license.Error) {
	lic, err := license.verify(text, license_public_key(app), allocator)
	when ACCEPT_DEV_LICENSE_KEY {
		if err != .None {
			if dev, dev_err := license.verify(text, license.DEV_PUBLIC_KEY, allocator); dev_err == .None {
				license.license_destroy(&lic)
				return dev, .None
			}
		}
	}
	return lic, err
}

license_support_url :: proc(app: ^App) -> string {
	u := strings.trim_space(config.string_of(&app.prefs, "browser.license.support_url"))
	// only a web page: the link is the one of the page's author, but a pref must not turn it into script or a file
	return strings.has_prefix(u, "https://") || strings.has_prefix(u, "http://") ? u : SUPPORT_URL
}

// The file the key is kept in; "" when it is kept in memory only.
license_path :: proc(app: ^App) -> string {
	if p := strings.trim_space(config.string_of(&app.prefs, "browser.license.path")); p != "" { return p }
	if !app.cfg.persist_profile || app.profile_dir == "" { return "" }
	return strings.concatenate({app.profile_dir, "/license", license.FILE_EXTENSION}, context.temp_allocator)
}

// The stored key (temporary allocator), "" when there is none.
@(private = "file")
license_stored_text :: proc(app: ^App) -> string {
	path := license_path(app)
	if path == "" { return string(memory_text[:memory_len]) }
	info, err := os.stat(path, context.temp_allocator)
	if err != nil || info.size <= 0 || info.size > license.MAX_TEXT { return "" }
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	return rerr == nil ? string(data) : ""
}

license_state :: proc(app: ^App) -> License_State {
	text := license_stored_text(app)
	if strings.trim_space(text) == "" { return {} }
	lic, err := license_check(app, text, context.temp_allocator)
	return {lic = lic, registered = err == .None, stored = true, err = err}
}

// Checks `text` and keeps it. Nothing is written when it does not check out.
license_install :: proc(app: ^App, text: string) -> license.Error {
	lic, err := license_check(app, text)
	if err != .None { return err }
	license.license_destroy(&lic)
	canonical := license.normalize(text, context.temp_allocator)
	path := license_path(app)
	if path == "" {
		memory_len = copy(memory_text[:], canonical)
		return .None
	}
	if dir := os.dir(path); dir != "" { _ = os.make_directory_all(dir) }
	if !write_file_atomic(path, strings.concatenate({canonical, "\n"}, context.temp_allocator)) { return .Bad_Format }
	return .None
}

license_remove :: proc(app: ^App) {
	if path := license_path(app); path != "" { _ = os.remove(path) } else { memory_len = 0 }
}

@(private = "file")
write_file_atomic :: proc(path, text: string) -> bool {
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, transmute([]byte)text) != nil { return false }
	return bool(win.MoveFileExW(win.utf8_to_wstring(tmp, context.temp_allocator), win.utf8_to_wstring(path, context.temp_allocator), win.MOVEFILE_REPLACE_EXISTING | win.MOVEFILE_WRITE_THROUGH))
}

////////////////////////////////
// A .wrenlicense file: dropped on the window, given on the command line, typed in the address bar, or chosen with the
// button of about:wren. navigate hands the address here instead of loading the file.

is_license_file_address :: proc(a: string) -> bool {
	if !strings.has_prefix(a, "file:") { return false }
	end := strings.index_any(a, "?#")
	path := end >= 0 ? a[:end] : a
	return strings.has_suffix(strings.to_lower(path, context.temp_allocator), license.FILE_EXTENSION)
}

// Reads the file of a file: address and installs the key; about:wren then says how it went.
license_open_file :: proc(app: ^App, t: ^Tab, address: string) {
	notice := Wren_Notice{"That licence file could not be read.", true}
	if u, ok := url.parse(address, allocator = context.temp_allocator); ok {
		if path, pok := fetch.file_path_from_url(u, context.temp_allocator); pok {
			notice = license_install_file(app, path)
		}
	}
	// the tab's entry is about:wren, not the file
	show_wren_page(app, t, WREN_URL, notice = notice)
	page.session_replace(&t.session, WREN_URL)
	sync_history(t)
}

// Reads `path` (a licence is small: a larger file is not one) and installs it.
license_install_file :: proc(app: ^App, path: string) -> Wren_Notice {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil || info.size <= 0 { return {"That licence file could not be read.", true} }
	if info.size > license.MAX_TEXT { return {license.error_text(.Too_Long), true} }
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil { return {"That licence file could not be read.", true} }
	if e := license_install(app, string(data)); e != .None { return {license.error_text(e), true} }
	return {"Licence accepted. Thank you for supporting Wren!", false}
}

////////////////////////////////
// The "Choose a file…" button: the Windows Open dialog on a blocking thread, then the file is installed on the UI thread.

@(private = "file")
Choose_Job :: struct {
	app:   ^App,
	tab:   u64,
	owner: win.HWND,
	path:  string,
	ok:    bool,
}

license_choose_file :: proc(app: ^App, t: ^Tab) {
	job := new(Choose_Job)
	job.app, job.tab, job.owner = app, t.id, app.win.hwnd
	host.run_blocking(&app.blocking, proc(data: rawptr) {
		job := (^Choose_Job)(data)
		_ = win.CoInitializeEx(nil, .APARTMENTTHREADED)
		defer win.CoUninitialize()
		buf: [1024]u16
		filter := win.utf8_to_wstring("Wren licence (*.wrenlicense)\x00*.wrenlicense\x00All files (*.*)\x00*.*\x00\x00", context.temp_allocator)
		title := win.utf8_to_wstring("Choose a Wren licence file", context.temp_allocator)
		ofn := win.OPENFILENAMEW{
			lStructSize = size_of(win.OPENFILENAMEW), hwndOwner = job.owner, lpstrFilter = filter, lpstrTitle = title,
			lpstrFile = &buf[0], nMaxFile = u32(len(buf)),
			Flags = u32(win.OFN_PATHMUSTEXIST | win.OFN_FILEMUSTEXIST | win.OFN_EXPLORER | win.OFN_NOCHANGEDIR | win.OFN_HIDEREADONLY),
		}
		if !win.GetOpenFileNameW(&ofn) { return }
		n := 0
		for n < len(buf) && buf[n] != 0 { n += 1 }
		if s, err := win.utf16_to_utf8(buf[:n], context.allocator); err == nil { job.path, job.ok = s, true }
		free_all(context.temp_allocator)
	}, proc(data: rawptr) {
		job := (^Choose_Job)(data)
		defer { delete(job.path); free(job) }
		if !job.ok { return }
		app := job.app
		for tab in app.tabs {
			if tab.id != job.tab { continue }
			notice := license_install_file(app, job.path)
			show_wren_page(app, tab, WREN_URL, notice = notice)
			app.frames_requested = max(app.frames_requested, 3)
			break
		}
	}, job)
}
