package browser

// Wren's updates are the toolkit's (prefs_page.Updates over update.Updater; docs/updates.md): its thread reads the latest
// release's signed manifest (update-windows-x64.json and its .sig, signed with the key of wren_update.PRODUCT), downloads
// the program it names, checks its length and SHA-256 and puts it in place of the running one; the new version runs at
// the next start. The installed copy with update.auto on does it by itself, a day apart; any other copy waits for Check
// now (the settings' System page, the command "Check for updates"). What stays Wren's: its words (update.notice in a
// message), the badge in its status bar, and its restart (App.relaunch, once this Wren let go of its profile).
//
// Only where Wren's release is a program to replace (UPDATES_SELF: Windows; Linux ships a tar.gz, or Nix updates it), and
// never in a development or labelled build: those are updated by hand.

import "core:fmt"
import "core:strings"
import "toolkit:platform"
import prefs_page "toolkit:prefs_page"
import "toolkit:ui"
import update "toolkit:update"
import "wb:base"
import "wb:host"

// The repository whose latest release is read (update.base_url, when set, names another folder: a mirror, a test).
UPDATE_REPOSITORY :: "sachahjkl/wren"

// (updates_start and UPDATES_SELF: updates_windows.odin, updates_other.odin)

// On the updater's thread: the loop wakes, and its next frame reads the state (updates_frame).
@(private)
updates_news :: proc(user: rawptr) {
	context = base.process_context()   // (the updater's thread has the heap's context)
	host.post(&(^App)(user).loop, proc(data: rawptr) { request_frames((^App)(data), 2) }, user)
}

// Each frame: update.auto applied as the preference and the install say now, and each change of the updater said once.
// The badge and the settings show the state; a message says only update.notice (a failed install, the answer to Check now).
updates_frame :: proc(app: ^App) {
	changed, st := prefs_page.updates_follow(&app.updates)
	if !changed { return }
	request_frames(app, 2)
	if words, bad := update.notice(st); words != "" { announce(app, bad ? ui.Toast_Kind.Warn : ui.Toast_Kind.Info, words) }
}

// The command "Check for updates": the answer comes as a message (update.notice). Where Wren does not update itself, the
// way a person gets a new version.
updates_check_now :: proc(app: ^App) {
	if app.updates.updater == nil {
		announce(app, .Info, fmt.tprintf("%s does not update itself here: a new version is on its release page.", APP_NAME))
		tab_open(app, "https://github.com/" + UPDATE_REPOSITORY + "/releases/latest", origin = .User)
		return
	}
	update.check_now(app.updates.updater)
}

// The command "Install the update": the version on offer, when there is one.
updates_install_now :: proc(app: ^App) {
	if app.updates.updater != nil { update.install_now(app.updates.updater) }
}

updates_on_offer :: proc(app: ^App) -> bool {
	return app.updates.updater != nil && update.status(app.updates.updater).phase == .Available
}

// The status bar shows the toolkit's badge (prefs_page.update_badge): a version on offer, its download, a restart.
updates_badge_due :: proc(app: ^App) -> bool {
	if app.updates.updater == nil { return false }
	#partial switch update.status(app.updates.updater).phase {
	case .Available, .Downloading, .Installed: return true
	}
	return false
}

// The remote channel's Wren.updateState: a check is out.
updates_checking :: proc(app: ^App) -> bool {
	return app.updates.updater != nil && update.status(app.updates.updater).phase == .Checking
}

// Restart now (the settings, the badge): this Wren ends as its last window closing does, and the new program starts once
// it let go of its profile (app_stop).
updates_restart :: proc(user: rawptr) {
	app := (^App)(user)
	if u := app.updates.updater; u != nil {
		// (the updater's thread found the path before it put the new program there: Installed was read under its lock)
		delete(app.relaunch)
		app.relaunch = strings.clone(u.options.exe)
	}
	app.quitting = true
	platform.request_close(active_window(app).win)
}

// At the end, before the windows go: no news after it.
updates_stop :: proc(app: ^App) {
	prefs_page.updates_stop(&app.updates)
}
