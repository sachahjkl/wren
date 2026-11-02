package e2e_scenarios

// The address bar's suggestions with no browser around it (chrome_world.odin), on a history of known visits: the inline completion as a hand types, Shift+Delete on the completed row, the
// cross of a row under the pointer, Down and Escape. (Enter and the load it leads to: urlbar.odin.)

import "core:strings"
import "core:testing"
import "core:time"
import session "toolkit:testkit/session"
import "toolkit:ui"
import "wb:browser"

@(private = "file") GITLAB :: "gitlab.com"
@(private = "file") GIT_SCM :: "git-scm.com"
@(private = "file") ADDRESS_BOX :: "address"
@(private = "file") VISIT_APART_MS :: 1000
@(private = "file") KNOWN := []struct { url, title: string, visits: int }{
	{"https://github.com/", "GitHub", 8},
	{"https://github.com/odin-lang/Odin", "GitHub - odin-lang/Odin", 4},
	{"https://gitlab.com/", "GitLab", 6},
	{"https://git-scm.com/docs/git-rebase", "Git - git-rebase Documentation", 2},
}

// The history the bar reads, as a profile's would give it.
@(private = "file")
known_history :: proc(t: ^testing.T, w: ^Chrome_World) {
	w.app.hcfg = browser.history_settings_from_prefs(&w.app.prefs)
	now := time.time_to_unix_nano(time.now()) / i64(time.Millisecond)
	id: u64
	for k in KNOWN {
		for _ in 0 ..< k.visits {
			id += 1
			append(&w.app.ghist.visits, browser.Visit{id = id, at_ms = now - i64(id) * VISIT_APART_MS, url = strings.clone(k.url), title = strings.clone(k.title)})
		}
	}
	w.app.ghist.serial = 1
	testing.cleanup(t, proc(data: rawptr) {
		app := (^browser.App)(data)
		browser.visits_destroy(&app.ghist.visits)
		app.ghist = {}
	}, w.app)
}

@(private = "file")
visits_of :: proc(w: ^Chrome_World, part: string) -> (n: int) {
	for v in w.app.ghist.visits { if strings.contains(v.url, part) { n += 1 } }
	return
}

@(private = "file")
listed :: proc(w: ^Chrome_World, part: string) -> bool {
	for r in browser.control_urlbar(w.app).rows { if strings.contains(r.url, part) { return true } }
	return false
}

@(test)
chrome_address_bar_suggestions :: proc(t: ^testing.T) {
	w := chrome_start(t)
	known_history(t, w)
	session.click(w.s, ADDRESS_BOX)
	testing.expect(t, ui.focus_key() == w.wnd.own.address_key, "a click gives the field the keyboard")

	// the inline completion, each letter in a frame of its own (a text that grows at its end is completed, a text pasted over the field is not)
	session.type_slowly(w.s, "gitl")
	testing.expect_value(t, ui.field_string(&w.wnd.address), "gitlab.com/")
	testing.expect(t, listed(w, GITLAB), "the first row is what it completes to")

	// Shift+Delete on the completed row: out of the list and out of the history
	session.key(w.s, .Delete, {.Shift})
	session.frames(w.s, 2)
	testing.expect_value(t, visits_of(w, GITLAB), 0)
	testing.expect(t, !listed(w, GITLAB), "gone from the list")

	// the cross of a row, under the pointer: a click takes it out too
	session.key(w.s, .Backspace, repeat = 3)
	session.frames(w.s, 2)
	testing.expect(t, listed(w, GIT_SCM), "the list has another row")
	cross: [2]f32
	for r in browser.control_urlbar(w.app).rows {
		if strings.contains(r.url, GIT_SCM) && r.has_cross { c := r.cross; cross = {f32(c.x + c.w / 2), f32(c.y + c.h / 2)} }
	}
	testing.expect(t, cross != {}, "its cross is laid out")
	session.click_at(w.s, cross)
	session.frames(w.s, 2)
	testing.expect_value(t, visits_of(w, GIT_SCM), 0)
	testing.expect(t, !listed(w, GIT_SCM), "gone from the list")

	session.key(w.s, .Down)
	testing.expect(t, browser.control_urlbar(w.app).open, "Down keeps the list open")
	session.key(w.s, .Escape)
	testing.expect(t, !browser.control_urlbar(w.app).open, "Escape closes the list")
}
