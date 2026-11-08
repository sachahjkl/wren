package browser

// Installing an update (docs/updates.md). The check (update_check.odin) says that a newer release exists; this file makes it safe to
// take. Nothing is installed by itself: the person presses "Install the update" (about:wren, or the command), and only a release
// that is signed by Froment Software is ever written over the program.
//
//   1. a newer release is announced: its signed manifest and the signature are fetched (two small files of the release, over
//      https) and checked at once (package update): the signature with the key built into Wren, then that the manifest is for
//      this platform, for the version the release announced, and newer than this program. Failing any, nothing more is done.
//   2. "Install": the program is downloaded (to memory: 70 MB, checked whole before anything is written), its length and SHA-256
//      are compared with the signed ones, it is written beside the program, read back and compared again, and only then does
//      the running program's file go aside (to .old) and the new one take its place. A failure at any step leaves the program as it was.
//   3. Wren says that it is installed; the new version runs at the next start (the old copy is deleted then).
//
// Windows only for now (the Linux build is a tar.gz: it checks and says where the file is). A labelled build and a development build
// are not releases and are updated by hand.

import "core:fmt"
import "core:os"
import "core:strings"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:desktop"
import "wb:fetch"
import update "toolkit:update"
import wren_update "wb:update"

UPDATE_DOWNLOAD_BASE :: "https://github.com/sachahjkl/wren/releases/download/"

Update_Phase :: enum u8 {
	Idle,          // nothing known, or nothing to install
	Verifying,     // a newer release was announced: its manifest and signature are being fetched and checked
	Ready,         // a newer release, signed: "Install the update" is offered
	Downloading,   // the program is being fetched
	Installed,     // written: the new version runs at the next start
	Failed,        // the last attempt failed (app.upd.problem says why); the program is untouched
}

// What the page and the command say.
Update_Summary :: struct {
	shown:       bool,
	text:        string,    // one sentence, in the temporary allocator
	can_check:   bool,
	can_install: bool,
	busy:        bool,
}

update_install_supported :: proc() -> bool {
	when ODIN_OS == .Windows { return true } else { return false }
}

update_platform :: proc() -> string {
	when ODIN_OS == .Windows { return update.PLATFORM } else { return "" }
}

// The key manifests are checked with: the one built in, unless about:config names another (for the tests of this feature).
update_public_key :: proc(app: ^App) -> string {
	if k := config.string_of(&app.prefs, "browser.update.public_key"); k != "" { return k }
	return wren_update.PRODUCT.public_key
}

// Whether a manifest must be signed (browser.update.require_signature, on unless a channel of the person's own says otherwise).
update_signature_required :: proc(app: ^App) -> bool {
	return config.bool_of(&app.prefs, "browser.update.require_signature")
}

// Where the release files are: "<base>v<version>/<file>". A mirror or a test server sets it; anything but an address ending in / is the default.
update_base_url :: proc(app: ^App) -> string {
	b := config.string_of(&app.prefs, "browser.update.base_url")
	if b == "" || !strings.has_suffix(b, "/") || !(strings.has_prefix(b, "https://") || strings.has_prefix(b, "http://127.0.0.1") || strings.has_prefix(b, "http://localhost")) {
		return UPDATE_DOWNLOAD_BASE
	}
	for c in transmute([]u8)b { if c <= ' ' || c == 0x7f { return UPDATE_DOWNLOAD_BASE } }
	return b
}

// Whether this program may install an update, and if not why (said to the person).
update_install_allowed :: proc(app: ^App) -> (ok: bool, why: string) {
	if !update_install_supported() { return false, "Installing updates from Wren is available on Windows for now: download the new version from its release page." }
	if APP_VERSION_LABEL != "" { return false, "This is a labelled build, not a release: update it by hand." }
	if IS_DEV_BUILD && !config.bool_of(&app.prefs, "browser.update.allow_development_build") { return false, "This is a development build, not a release: update it by hand." }
	if !update.version_valid(APP_VERSION) { return false, "This build's version is not X.Y.Z: update it by hand." }
	if update_signature_required(app) && update_public_key(app) == "" { return false, "This build has no update key, so it cannot check an update." }
	return true, ""
}

@(private)
update_install_reset :: proc(app: ^App) {
	update.manifest_destroy(&app.upd.manifest)
	delete(app.upd.man_bytes); app.upd.man_bytes = nil
	delete(app.upd.sig_text); app.upd.sig_text = ""
	delete(app.upd.tag); app.upd.tag = ""
	app.upd.got_manifest, app.upd.got_sig = false, false
	app.upd.man_status, app.upd.sig_status, app.upd.bin_status = 0, 0, 0
}

update_install_destroy :: proc(app: ^App) {
	update_install_reset(app)
	delete(app.upd.problem); app.upd.problem = ""
	delete(app.upd.installed); app.upd.installed = ""
}

@(private = "file")
update_fail :: proc(app: ^App, why: string) {
	delete(app.upd.problem); app.upd.problem = strings.clone(why)
	app.upd.phase = .Failed
	if app.upd.forced || app.upd.install_asked { ui.toast(.Warn, "Update: %s", why) }
	request_frames(app, 3)
}

////////////////////////////////
// 1. The signed manifest

// A newer release was announced (update_check.odin): fetch and check its signed manifest. No-op when this program may not install.
update_verify_start :: proc(app: ^App, version: string) {
	if ok, _ := update_install_allowed(app); !ok { return }
	if app.upd.phase == .Verifying || app.upd.phase == .Downloading { return }
	if app.upd.phase == .Ready && app.upd.manifest.version == version { return }   // already verified
	update_install_reset(app)
	app.upd.phase = .Verifying
	app.upd.tag = strings.clone(version)
	delete(app.upd.problem); app.upd.problem = ""
	release := fmt.tprintf("%sv%s/", update_base_url(app), version)
	name := update.manifest_name(update_platform(), "", context.temp_allocator)   // (Wren has no channels)
	fetch.start(&app.loader, {
		request = {url = strings.concatenate({release, name}, context.temp_allocator), mode = .Navigate, credentials = .Omit, redirect = .Follow, destination = .Empty, max_body = update.MAX_MANIFEST},
		on_event = update_manifest_event, user = app, scope = app.process, collect = true,
	})
	if !update_signature_required(app) {
		app.upd.got_sig = true   // nothing to fetch: the channel is not signed (and the person said so)
		return
	}
	fetch.start(&app.loader, {
		request = {url = strings.concatenate({release, name, ".sig"}, context.temp_allocator), mode = .Navigate, credentials = .Omit, redirect = .Follow, destination = .Empty, max_body = update.MAX_SIGNATURE_TEXT},
		on_event = update_signature_event, user = app, scope = app.process, collect = true,
	})
}

@(private = "file")
update_manifest_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	app := (^App)(user)
	if app.upd.phase != .Verifying { return }
	#partial switch ev.kind {
	case .Response:
		app.upd.man_status = int(ev.response.status)
	case .Done:
		if app.upd.man_status != 200 { update_fail(app, "this release has no signed update manifest: update it by hand"); return }
		app.upd.man_bytes = make([]byte, len(ev.data)); copy(app.upd.man_bytes, ev.data)
		app.upd.got_manifest = true
		update_verify_both(app)
	case .Failed:
		update_fail(app, fmt.tprintf("could not fetch the update manifest: %s", ev.detail))
	}
}

@(private = "file")
update_signature_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	app := (^App)(user)
	if app.upd.phase != .Verifying { return }
	#partial switch ev.kind {
	case .Response:
		app.upd.sig_status = int(ev.response.status)
	case .Done:
		if app.upd.sig_status != 200 { update_fail(app, "this release has no signature for its update manifest: update it by hand"); return }
		app.upd.sig_text = strings.clone(string(ev.data))
		app.upd.got_sig = true
		update_verify_both(app)
	case .Failed:
		update_fail(app, fmt.tprintf("could not fetch the update signature: %s", ev.detail))
	}
}

@(private = "file")
update_verify_both :: proc(app: ^App) {
	if !app.upd.got_manifest || !app.upd.got_sig { return }
	product := wren_update.PRODUCT
	product.public_key = update_public_key(app)
	m, err := update.check_release(product, app.upd.man_bytes, app.upd.sig_text, update_platform(), "", APP_VERSION, app.upd.tag, require_signature = update_signature_required(app))
	if err != .None { update_fail(app, update.error_text(err)); return }
	update.manifest_destroy(&app.upd.manifest)
	app.upd.manifest = m
	app.upd.phase = .Ready
	if app.upd.forced {
		ui.toast(.Info, "%s v%s is available and was checked (see About Wren). About Wren has the button that installs it.", APP_NAME, m.version)
		tab_open(app, WREN_URL, origin = .User)
	} else {
		ui.toast(.Info, "%s v%s is available (signed). Menu > Install the update, or About Wren.", APP_NAME, m.version)
	}
	request_frames(app, 3)
}

////////////////////////////////
// 2. The download and the replacement

// The command and the button: download the verified release, check it, and replace the program.
update_install :: proc(app: ^App) {
	if ok, why := update_install_allowed(app); !ok { ui.toast(.Warn, "%s", why); return }
	app.upd.install_asked = true
	switch app.upd.phase {
	case .Downloading: ui.toast(.Info, "Already downloading the update…"); return
	case .Installed:   ui.toast(.Info, "Wren v%s is installed already: restart Wren to use it.", app.upd.installed); return
	case .Idle, .Verifying, .Failed:
		ui.toast(.Info, "No verified update is waiting: use \"Check for updates\" first.")
		return
	case .Ready:
	}
	m := app.upd.manifest
	app.upd.phase = .Downloading
	app.upd.bin_status = 0
	url := fmt.tprintf("%sv%s/%s", update_base_url(app), m.version, m.file)
	fetch.start(&app.loader, {
		request = {url = url, mode = .Navigate, credentials = .Omit, redirect = .Follow, destination = .Empty, max_body = int(m.size)},
		on_event = update_download_event, user = app, scope = app.process, collect = true,
	})
	ui.toast(.Info, "Downloading %s v%s (%d MB)…", APP_NAME, m.version, m.size / (1024 * 1024))
	request_frames(app, 3)
}

@(private = "file")
update_download_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	app := (^App)(user)
	if app.upd.phase != .Downloading { return }
	#partial switch ev.kind {
	case .Response:
		app.upd.bin_status = int(ev.response.status)
	case .Done:
		if app.upd.bin_status != 200 { update_fail(app, "the release file could not be downloaded"); return }
		exe := desktop.executable_path(context.temp_allocator)
		if problem := update_apply(exe, app.upd.manifest, ev.data); problem != "" { update_fail(app, problem); return }
		delete(app.upd.installed); app.upd.installed = strings.clone(app.upd.manifest.version)
		app.upd.phase = .Installed
		ui.toast(.Good, "%s v%s is installed. Restart Wren to use it.", APP_NAME, app.upd.installed)
		request_frames(app, 3)
	case .Failed:
		update_fail(app, fmt.tprintf("could not download the update: %s", ev.detail))
	}
}

// The downloaded bytes become the program at `exe`, or nothing changes (update.place: the signed length and SHA-256, a program of
// this system, written beside it and read back, then put in its place; the old one put back on failure). Returns "" on success,
// else what to say.
update_apply :: proc(exe: string, m: update.Manifest, data: []byte) -> string {
	if exe == "" || !os.is_file(exe) { return "cannot tell which file is the running program" }
	if e := update.place(exe, data, m); e != .None { return update.error_text(e) }
	return ""
}

////////////////////////////////
// What is said

update_summary :: proc(app: ^App) -> Update_Summary {
	s := Update_Summary{shown = true, can_check = app.upd.phase != .Downloading && !app.upd.checking}
	latest, _ := update_available(app)
	_, why := update_install_allowed(app)
	allowed, _ := update_install_allowed(app)
	switch app.upd.phase {
	case .Verifying:
		s.text, s.busy = fmt.tprintf("v%s is available: checking its signature…", app.upd.tag), true
	case .Ready:
		if update_signature_required(app) {
			s.text = fmt.tprintf("v%s is available and its signature is valid (%d MB). Nothing is installed until you press the button.", app.upd.manifest.version, app.upd.manifest.size / (1024 * 1024))
		} else {
			s.text = fmt.tprintf("v%s is available, UNSIGNED: signature checking is turned off (browser.update.require_signature), so only the file's checksum is checked, not who made it (%d MB). Nothing is installed until you press the button.", app.upd.manifest.version, app.upd.manifest.size / (1024 * 1024))
		}
		s.can_install = allowed
	case .Downloading:
		s.text, s.busy = fmt.tprintf("Downloading v%s…", app.upd.manifest.version), true
	case .Installed:
		s.text = fmt.tprintf("v%s is installed. Restart Wren to use it.", app.upd.installed)
	case .Failed:
		s.text = fmt.tprintf("An update (v%s) was found, but it was not installed: %s.", latest != "" ? latest : app.upd.tag, strings.trim_right(app.upd.problem, "."))
	case .Idle:
		switch {
		case latest != "" && !allowed: s.text = fmt.tprintf("v%s is available. %s", latest, why)
		case latest != "":             s.text = fmt.tprintf("v%s is available.", latest)
		case app.upd.checked != 0:     s.text = fmt.tprintf("Wren is up to date (v%s).", APP_VERSION)
		case:                          s.text = "Not checked yet. Wren asks GitHub only when you press the button (or once a day, if you ticked it in Setup)."
		}
	}
	if !allowed && s.text != "" && app.upd.phase == .Idle && latest == "" { s.text = fmt.tprintf("%s %s", s.text, why) }
	return s
}

// The command is offered when a verified update is waiting.
update_install_ready :: proc(app: ^App) -> bool { return app.upd.phase == .Ready }

// At start, before anything else: the files a previous update left (the old program, a half-written new one). Local, no network.
update_cleanup :: proc() {
	exe := desktop.executable_path(context.temp_allocator)
	if exe != "" { update.remove_leftovers(exe) }
}
