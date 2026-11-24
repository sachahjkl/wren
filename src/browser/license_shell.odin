package browser

import "core:strings"
import prefs_page "toolkit:prefs_page"
import "wb:base"
import config "toolkit:config"
import "wb:fetch"
import "wb:license"
import "wb:page"
import "wb:url"

////////////////////////////////
// The shell's side of the support licence: Wren's product (src/license) in the toolkit's Licence page (prefs_page.Licence,
// src/md/features/licence.md). Wren gives the store's options, its name, its pricing page, its logo and its vendor; the
// page, its wording, its card (ui.licence_card) and its tasks on the store are the toolkit's, the same as in the other
// programs of Froment Software. The licence is a small file in the profile (license.wrenlicense; browser.license.path
// elsewhere), or memory only when the profile is not kept. It changes what the settings and about:wren say and nothing
// else: no feature depends on it, nothing reminds of it. No network is used.

SUPPORT_URL :: "https://sachahjkl.github.io/wren/pricing/"

LICENSE_PREFS := [?]config.Def{
	{name = "browser.license.path", kind = .String, default = {s = ""}, restart = true,
		description = "Where the license key is kept, a file. Empty: license.wrenlicense in the profile folder (or in memory only when browser.profile.persist is off)."},
	{name = "browser.license.public_key", kind = .String, default = {s = ""}, restart = true,
		description = "The public key (base64url) licenses are checked with. Empty: the key built into this version of Wren. Another key reads the licenses of another issuer."},
	{name = "browser.license.support_url", kind = .String, default = {s = SUPPORT_URL},
		description = "The page the 'Support Wren' link of about:wren and the 'Buy a licence' button of the settings open."},
}

register_license_prefs :: proc(p: ^config.Prefs) { config.register(p, LICENSE_PREFS[:]) }

// An experimental build (wrentool experimental: build.bat with WREN_ACCEPT_DEV_LICENSE_KEY=1) accepts the development pair's licences too, so that
// the demonstration licence it is handed out with shows its card with no setting. A release never does.
@(private = "file") ACCEPT_DEV_LICENSE_KEY :: IS_DEV_BUILD || #config(WREN_ACCEPT_DEV_LICENSE_KEY, false)

// The licence a build is handed out with, as the text of a .wrenlicense (build.bat: WREN_EMBEDDED_LICENSE; wrentool experimental sets it
// for an experimental build): "" in every other build, a release above all. The store puts it in place once (Store_Options.seed).
EMBEDDED_LICENSE :: #config(WREN_EMBEDDED_LICENSE, "")

// The settings' Licence page, as an address: about:settings opened on that page (show_settings).
SETTINGS_LICENCE_URL :: SETTINGS_URL + "#" + prefs_page.LICENCE_PAGE

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

// The store and its first read, once the first window's toolkit state exists (app_ui_init): the page's tasks answer in
// that State, whichever window shows the settings.
licence_start :: proc(app: ^App) {
	w := active_window(app)
	path := license_path(app)
	prefs_page.licence_init(&app.licence, w.ui, {
		store = {
			product = license.WREN,
			path = path, memory = path == "",
			public_key = strings.trim_space(config.string_of(&app.prefs, "browser.license.public_key")),
			accept_dev = ACCEPT_DEV_LICENSE_KEY,
			seed = EMBEDDED_LICENSE,
		},
		name = APP_NAME,
		// (the page keeps the address and never copies it, and the preference's string goes when it changes: a copy of the
		// start's, freed by licence_stop)
		pricing_url = strings.clone(license_support_url(app), base.process_allocator()),
		owner = w.win,
		logo = APP_LOGO_PNG,
		vendor = "Froment Software",
	})
}

// Once the windows' toolkit states are closed (app_free): nothing when licence_start did not run (a test's App without
// a window).
licence_stop :: proc(app: ^App) {
	if app.licence.store == nil { return }
	pricing := app.licence.options.pricing_url
	prefs_page.licence_end(&app.licence)
	delete(pricing, base.process_allocator())
}

// Retargets app.licence away from a window that is closing, before its ui.State and platform.Window are freed.
// When closing the last window (heir == nil), clears both pointers.
licence_retarget :: proc(app: ^App, closing, heir: ^Browser_Window) {
	if closing == nil { return }
	if app.licence.state != nil && app.licence.state == closing.ui {
		app.licence.state = heir != nil ? heir.ui : nil
	}
	if app.licence.options.owner != nil && app.licence.options.owner == closing.win {
		app.licence.options.owner = heir != nil ? heir.win : nil
	}
}

// about:wren says the store's last status: each answer of the store (the first read, a change on the settings' page)
// builds it again. The page's answers come in a build (ui.task), so the frame looks after it.
licence_frame :: proc(app: ^App) {
	l := &app.licence
	if l.read == app.licence_seen.read && l.busy == app.licence_seen.busy { return }
	answered := (app.licence_seen.busy && !l.busy) || (!app.licence_seen.read && l.read)
	app.licence_seen = {read = l.read, busy = l.busy}
	if !answered { return }
	for t in tabs_all(app) {
		if t.url == WREN_URL { show_wren_page(app, t, WREN_URL) }
	}
	request_frames(app, 3)
}

// What about:wren last saw of the Licence (licence_frame).
Licence_Seen :: struct {
	read, busy: bool,
}

////////////////////////////////
// A .wrenlicense file: dropped on the window, given on the command line, or typed in the address bar. navigate hands the
// address here instead of loading the file.

is_license_file_address :: proc(a: string) -> bool {
	if !strings.has_prefix(a, "file:") { return false }
	end := strings.index_any(a, "?#")
	path := end >= 0 ? a[:end] : a
	return base.ascii_has_suffix_fold(path, license.WREN.file_extension)
}

// Installs the key of the file of a file: address (the page says how it went), and shows the settings' Licence page.
license_open_file :: proc(app: ^App, t: ^Tab, address: string) {
	if u, ok := url.parse(address, allocator = context.temp_allocator); ok {
		if path, pok := fetch.file_path_from_url(u, context.temp_allocator); pok {
			prefs_page.licence_install_file(&app.licence, path)
		}
	}
	// the tab's entry is the settings' page, not the file
	show_settings(app, t, SETTINGS_LICENCE_URL)
	page.session_replace(&t.session, SETTINGS_LICENCE_URL)
	sync_history(app, t)
}
