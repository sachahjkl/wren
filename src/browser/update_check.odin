package browser

// The update check: once a day, when `browser.update.check_daily` is on (Setup's "Check for updates once per day"; off by
// default, so no network request is made unless the user asked), one GET of GitHub's "latest release" of sachahjkl/wren
// (browser.update.url), compared with APP_VERSION. Nothing is downloaded or installed: a notice says that a newer
// version exists and where it is (the release page). The command "Check for updates" asks once, whatever the preference
// says, and opens the release page when there is something newer.
//
// The profile keeps `update.txt` (when the last request was made, the newest version seen, its page, and which version was
// announced already, so each one is announced once). A request is made at most once per 24 hours, started before it is
// answered (a failing network is not asked again at every start). Never for profiles given with --profile or kept in the
// temporary folder, nor with WREN_DESKTOP_INTEGRATION=off or WREN_UPDATE_CHECK=off in the environment (every script of the
// tools sets the first): they would ask GitHub at every run.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:desktop"
import "wb:fetch"

UPDATE_FILE :: "update.txt"
UPDATE_EVERY_SECONDS :: 24 * 60 * 60

@(private = "file")
Update_State :: struct {
	checking: bool,
	forced:   bool,          // asked by the command: the answer is shown even when there is nothing new
	latest:   string,        // the newest version seen, without a leading v (owned)
	url:      string,        // its page (owned)
	checked:  i64,           // unix seconds of the last request
	notified: string,        // the version announced last (owned)
	loaded:   bool,
}

@(private = "file") upd: Update_State

update_destroy :: proc() {
	delete(upd.latest); delete(upd.url); delete(upd.notified)
	upd = {}
}

// The newest version known to be out, when it is newer than this one ("" when none or unknown).
update_available :: proc() -> (version, url: string) {
	if upd.latest != "" && desktop.compare_versions(upd.latest, APP_VERSION) > 0 { return upd.latest, upd.url }
	return "", ""
}

@(private = "file")
update_path :: proc(app: ^App) -> string { return strings.concatenate({app.profile_dir, "/", UPDATE_FILE}, context.temp_allocator) }

@(private = "file")
update_load :: proc(app: ^App) {
	if upd.loaded { return }
	upd.loaded = true
	data, err := os.read_entire_file(update_path(app), context.temp_allocator)
	if err != nil { return }
	for line in strings.split_lines(string(data), context.temp_allocator) {
		l := strings.trim_space(line)
		switch {
		case strings.has_prefix(l, "checked="):  upd.checked = parse_i64(l[len("checked="):])
		// (the file is the profile's, but whatever it says is checked as the answer was: a version is a version, an address one of the
		// web page that a tab opens)
		case strings.has_prefix(l, "latest="):   delete(upd.latest); upd.latest = update_version_ok(l[len("latest="):]) ? strings.clone(l[len("latest="):]) : ""
		case strings.has_prefix(l, "url="):      delete(upd.url); upd.url = update_page_ok(l[len("url="):]) ? strings.clone(l[len("url="):]) : ""
		case strings.has_prefix(l, "notified="): delete(upd.notified); upd.notified = update_version_ok(l[len("notified="):]) ? strings.clone(l[len("notified="):]) : ""
		}
	}
}

@(private = "file")
parse_i64 :: proc(s: string) -> (n: i64) {
	for c in s { if c < '0' || c > '9' { break }; n = n * 10 + i64(c - '0') }
	return
}

@(private = "file")
update_save :: proc(app: ^App) {
	if !app.cfg.persist_profile { return }
	text := fmt.tprintf("wren update check\nchecked=%d\nlatest=%s\nurl=%s\nnotified=%s\n", upd.checked, upd.latest, upd.url, upd.notified)
	_ = os.write_entire_file(update_path(app), text)
}

// At start: the daily request, when it is due.
update_startup :: proc(app: ^App, profile_explicit: bool) {
	if !config.bool_of(&app.prefs, "browser.update.check_daily") { return }
	for name in ([]string{"WREN_DESKTOP_INTEGRATION", "WREN_UPDATE_CHECK"}) {
		if v, ok := os.lookup_env(name, context.temp_allocator); ok && v == "off" { return }
	}
	if desktop_profile_is_disposable(app, profile_explicit) { return }
	update_load(app)
	if time.to_unix_seconds(time.now()) - upd.checked < UPDATE_EVERY_SECONDS && upd.checked != 0 { return }
	update_request(app, false)
}

// The command: asks now.
update_check_now :: proc(app: ^App) {
	update_load(app)
	if upd.checking { ui.toast(.Info, "Already checking for updates\u2026"); return }
	update_request(app, true)
	ui.toast(.Info, "Checking for updates\u2026")
}

@(private = "file")
update_request :: proc(app: ^App, forced: bool) {
	if upd.checking { return }
	upd.checking, upd.forced = true, forced
	upd.checked = i64(time.to_unix_seconds(time.now()))
	update_save(app)
	url := config.string_of(&app.prefs, "browser.update.url")
	fetch.start(&app.loader, {
		request = {
			url = url, mode = .Cors, credentials = .Omit, redirect = .Follow, destination = .Empty,
			headers = {{"Accept", "application/vnd.github+json"}}, max_body = 1 << 18,
		},
		on_event = update_event, scope = app.process, collect = true,
	})
}

@(private = "file")
update_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	app := the_app
	if app == nil { return }
	#partial switch ev.kind {
	case .Done:
		upd.checking = false
		tag, page, ok := update_parse(ev.data)
		if !ok { update_failed(app, "the answer is not a release"); return }
		version := strings.trim_prefix(tag, "v")   // (update_parse checked it)
		delete(upd.latest); upd.latest = strings.clone(version)
		delete(upd.url); upd.url = strings.clone(page)
		newer := desktop.compare_versions(version, APP_VERSION) > 0
		announce := newer && (upd.forced || upd.notified != version)
		if newer { delete(upd.notified); upd.notified = strings.clone(version) }
		update_save(app)
		switch {
		case announce && upd.forced:
			ui.toast(.Info, "%s v%s is available (you have v%s): opening its page", APP_NAME, version, APP_VERSION)
			if page != "" { tab_open(app, page) }
		case announce:
			ui.toast(.Info, "%s v%s is available (you have v%s). Menu > Check for updates opens its page.", APP_NAME, version, APP_VERSION)
		case upd.forced:
			ui.toast(.Good, "%s is up to date (v%s)", APP_NAME, APP_VERSION)
		}
		request_frames(app, 3)
	case .Failed:
		upd.checking = false
		update_failed(app, ev.detail)
	}
}

@(private = "file")
update_failed :: proc(app: ^App, why: string) {
	if upd.forced { ui.toast(.Warn, "Could not check for updates: %s", why) }
	request_frames(app, 2)
}

// tag_name and html_url of a "latest release" document (a draft or a prerelease is not offered).
update_parse :: proc(body: []byte) -> (tag, page: string, ok: bool) {
	v, err := json.parse(body, allocator = context.temp_allocator)
	if err != .None { return }
	obj, is_obj := v.(json.Object)
	if !is_obj { return }
	if d, has := obj["draft"].(json.Boolean); has && bool(d) { return }
	if p, has := obj["prerelease"].(json.Boolean); has && bool(p) { return }
	t, has_tag := obj["tag_name"].(json.String)
	if !has_tag || t == "" { return }
	tag = string(t)
	if !update_version_ok(strings.trim_prefix(tag, "v")) { return }   // (it is written to update.txt a line at a time, and compared: not free text)
	if h, has := obj["html_url"].(json.String); has && update_page_ok(string(h)) { page = string(h) }   // (it is opened in a tab: a web page, nothing else)
	return tag, page, true
}

// A version number as a release carries it: letters, digits, dots, plus and minus, at most 64 of them. Never a line break (the
// value is saved in update.txt, one key per line: a second line would be another key), a space or a slash.
update_version_ok :: proc(v: string) -> bool {
	if v == "" || len(v) > 64 { return false }
	for c in transmute([]u8)v {
		switch c {
		case '0' ..= '9', 'a' ..= 'z', 'A' ..= 'Z', '.', '+', '-':
		case: return false
		}
	}
	return true
}

// The page of a release: an https address on one line with no space or control character.
update_page_ok :: proc(a: string) -> bool {
	if !strings.has_prefix(a, "https://") || len(a) > 2048 { return false }
	for c in transmute([]u8)a { if c <= ' ' || c == 0x7f { return false } }
	return true
}
