package browser

import "core:strings"
import licence "toolkit:licence"
import "toolkit:platform"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:fetch"
import "wb:host"
import "wb:license"
import "wb:page"
import "wb:url"

////////////////////////////////
// The shell's side of the support licence: Wren's product (src/license) in the toolkit's store (gt:licence). The licence is
// a small file in the profile (license.wrenlicense; browser.license.path elsewhere), or memory only when the profile is not
// kept. The store reads and writes it on the blocking pool, never on the interface's thread; about:wren shows the last
// status it gave, and is built again when a new one comes. It changes what about:wren says and nothing else: no feature
// depends on it, nothing reminds of it. No network is used.

SUPPORT_URL :: "https://sachahjkl.github.io/wren/pricing/"

LICENSE_PREFS := [?]config.Def{
	{name = "browser.license.path", kind = .String, default = {s = ""}, restart = true,
		description = "Where the license key is kept, a file. Empty: license.wrenlicense in the profile folder (or in memory only when browser.profile.persist is off)."},
	{name = "browser.license.public_key", kind = .String, default = {s = ""}, restart = true,
		description = "The public key (base64url) licenses are checked with. Empty: the key built into this version of Wren. Another key reads the licenses of another issuer."},
	{name = "browser.license.support_url", kind = .String, default = {s = SUPPORT_URL},
		description = "The page the 'Support Wren' link of about:wren opens."},
}

register_license_prefs :: proc(p: ^config.Prefs) { config.register(p, LICENSE_PREFS[:]) }

// An experimental build (wrentool experimental: build.bat with WREN_ACCEPT_DEV_LICENSE_KEY=1) accepts the development pair's licences too, so that
// the demonstration licence it is handed out with shows its card with no setting. A release never does.
@(private = "file") ACCEPT_DEV_LICENSE_KEY :: IS_DEV_BUILD || #config(WREN_ACCEPT_DEV_LICENSE_KEY, false)

// The licence a build is handed out with, as the text of a .wrenlicense (build.bat: WREN_EMBEDDED_LICENSE; wrentool experimental sets it
// for an experimental build): "" in every other build, a release above all. The store puts it in place once (Store_Options.seed).
EMBEDDED_LICENSE :: #config(WREN_EMBEDDED_LICENSE, "")

// What the App keeps of its licence (App.licence).
Licence_Shell :: struct {
	store:   licence.Store,
	made:    bool,             // the store is made (at its first use: the preferences and the profile are known then)
	status:  licence.Status,   // the last the store gave (base.process_allocator)
	read:    bool,             // a status came
	pending: int,              // jobs of the store under way
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
	return strings.concatenate({app.profile_dir, "/license", license.WREN.file_extension}, context.temp_allocator)
}

@(private = "file")
licence_store :: proc(app: ^App) -> ^licence.Store {
	l := &app.licence
	if !l.made {
		path := license_path(app)
		licence.store_init(&l.store, {
			product = license.WREN,
			path = path, memory = path == "",
			public_key = strings.trim_space(config.string_of(&app.prefs, "browser.license.public_key")),
			accept_dev = ACCEPT_DEV_LICENSE_KEY,
			seed = EMBEDDED_LICENSE,
		})
		l.made = true
	}
	return &l.store
}

licence_shell_destroy :: proc(app: ^App) {
	l := &app.licence
	licence.status_destroy(&l.status, base.process_allocator())
	if l.made { licence.store_destroy(&l.store) }
	l^ = {}
}

// The status about:wren shows, and whether it is known yet (the first look starts its read).
license_status :: proc(app: ^App) -> (status: licence.Status, known: bool) {
	if !app.licence.read && app.licence.pending == 0 { licence_job(app, .Read) }
	return app.licence.status, app.licence.read
}

////////////////////////////////
// The store's jobs: on the blocking pool, then the status and about:wren again on the loop's thread.

@(private = "file")
Licence_Act :: enum u8 { Read, Install, Install_File, Remove }

@(private = "file")
Licence_Job :: struct {
	app:    ^App,
	act:    Licence_Act,
	text:   string,           // the key (Install) or the file (Install_File); owned
	err:    licence.Error,
	status: licence.Status,   // after the act (base.process_allocator)
}

@(private = "file")
licence_job :: proc(app: ^App, act: Licence_Act, text := "") {
	j := new(Licence_Job)
	j^ = {app = app, act = act, text = strings.clone(text)}
	_ = licence_store(app)   // (made here, on the loop's thread: the job only uses it)
	app.licence.pending += 1
	host.run_blocking(&app.blocking, licence_job_work, licence_job_done, j, licence_job_drop)
}

@(private = "file")
licence_job_work :: proc(data: rawptr) {
	j := (^Licence_Job)(data)
	s := &j.app.licence.store   // (made before the job: the store has its own lock)
	switch j.act {
	case .Read:
	case .Install:      j.err = licence.store_install(s, j.text)
	case .Install_File: j.err = licence.store_install_file(s, j.text)
	case .Remove:       _ = licence.store_remove(s)
	}
	j.status = licence.store_read(s, base.process_allocator())
	free_all(context.temp_allocator)
}

@(private = "file")
licence_job_done :: proc(data: rawptr) {
	j := (^Licence_Job)(data)
	app := j.app
	defer licence_job_drop(j)
	app.licence.pending -= 1
	licence.status_destroy(&app.licence.status, base.process_allocator())
	app.licence.status, j.status = j.status, {}
	app.licence.read = true
	notice: Wren_Notice
	switch j.act {
	case .Read:
	case .Install, .Install_File:
		notice = j.err == .None ? Wren_Notice{"License accepted. Thank you for supporting Wren!", false} : Wren_Notice{license_error_text(j.err), true}
	case .Remove:
		notice = {"The license was removed from this computer.", false}
	}
	// every about:wren shows what the store holds now (the tab that acted says how it went)
	for t in tabs_all(app) {
		if t.url == WREN_URL { show_wren_page(app, t, WREN_URL, notice = notice) }
	}
	request_frames(app, 3)
}

@(private = "file")
licence_job_drop :: proc(data: rawptr) {
	j := (^Licence_Job)(data)
	licence.status_destroy(&j.status, base.process_allocator())
	delete(j.text)
	free(j)
}

// Wren's words for what is wrong with a licence (the toolkit's are neutral).
license_error_text :: proc(e: licence.Error) -> string {
	#partial switch e {
	case .Bad_Format:    return "That is not a Wren license key: it should start with WREN1 and have three parts separated by dots."
	case .Bad_Signature: return "The signature does not match: the key was altered or was not issued by Froment Software."
	case .No_Public_Key: return "This build of Wren has no license key to check it with."
	case .Not_Read:      return "That license file could not be read."
	}
	return licence.error_text(e)
}

// Checks `text` and keeps it (nothing is written when it does not check out); about:wren then says how it went.
license_install :: proc(app: ^App, text: string) { licence_job(app, .Install, text) }

// Reads a licence file (a licence is small: a larger file is not one) and installs it.
license_install_file :: proc(app: ^App, path: string) { licence_job(app, .Install_File, path) }

license_remove :: proc(app: ^App) { licence_job(app, .Remove) }

////////////////////////////////
// A .wrenlicense file: dropped on the window, given on the command line, typed in the address bar, or chosen with the
// button of about:wren. navigate hands the address here instead of loading the file.

is_license_file_address :: proc(a: string) -> bool {
	if !strings.has_prefix(a, "file:") { return false }
	end := strings.index_any(a, "?#")
	path := end >= 0 ? a[:end] : a
	return base.ascii_has_suffix_fold(path, license.WREN.file_extension)
}

// Installs the key of the file of a file: address; about:wren then says how it went.
license_open_file :: proc(app: ^App, t: ^Tab, address: string) {
	notice := Wren_Notice{"That license file could not be read.", true}
	if u, ok := url.parse(address, allocator = context.temp_allocator); ok {
		if path, pok := fetch.file_path_from_url(u, context.temp_allocator); pok {
			license_install_file(app, path)
			notice = {"Checking the license…", false}
		}
	}
	// the tab's entry is about:wren, not the file
	show_wren_page(app, t, WREN_URL, notice = notice)
	page.session_replace(&t.session, WREN_URL)
	sync_history(app, t)
}

// The "Choose a file…" button: the system's Open dialog (ui.file_dialog: on the toolkit's chores), then the file installed.
license_choose_file :: proc(app: ^App) {
	d := licence.file_dialog(license.WREN, "Choose a Wren license file", "Wren license")
	d.owner = active_window(app).win
	ui.file_dialog(active_window(app).ui, .Open, d, proc(r: platform.Dialog_Result, user: rawptr) {
		if r.status != .Chosen || len(r.paths) == 0 { return }
		license_install_file((^App)(user), r.paths[0])   // (the job copies the path: r's are freed after this call)
	}, app)
}
