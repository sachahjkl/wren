package e2e_scenarios

// The address bar's suggestions (urlbar.odin), with a profile of a known history: the inline completion of an address of the test server and
// Enter (a visit of it is recorded), Shift+Delete on the completed row (gitlab.com leaves the history), a click on the cross of a row (git-scm.com
// leaves it), Down and Escape. The profile's history.txt says what happened.

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:e2e"

@(private = "file") URLBAR_SIZE :: [2]int{1280, 800}
@(private = "file") HISTORY_FILE :: "history.txt"
@(private = "file") SITE_INDEX :: "/site/index.html"
@(private = "file") GITLAB :: "gitlab.com"
@(private = "file") GIT_SCM :: "git-scm.com"
@(private = "file") ODIN_REPOSITORY :: "https://github.com/odin-lang/Odin"
@(private = "file") SITE_VISITS :: 3
@(private = "file") SITE_VISITS_AFTER :: SITE_VISITS + 1
@(private = "file") HISTORY_AGE_MS :: 3600_000     // the visits were an hour ago
@(private = "file") VISIT_APART_MS :: 1000

@(private = "file") Known :: struct { url, title: string, visits: int }

// The profile's history: `wren-history 1`, a line per visit.
@(private = "file")
write_history :: proc(profile, origin: string) {
	known := []Known{
		{"https://github.com/", "GitHub", 8},
		{ODIN_REPOSITORY, "GitHub - odin-lang/Odin", 4},
		{"https://gitlab.com/", "GitLab", 6},
		{"https://git-scm.com/docs/git-rebase", "Git - git-rebase Documentation", 2},
		{fmt.tprintf("%s%s", origin, SITE_INDEX), "Wren demos and tests", SITE_VISITS},
	}
	now := time.to_unix_nanoseconds(time.now()) / i64(time.Millisecond)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "wren-history 1\n")
	id := 0
	for k in known {
		for _ in 0 ..< k.visits {
			id += 1
			fmt.sbprintf(&b, "v\t%d\t%d\t%s\t%s\t\n", id, now - HISTORY_AGE_MS + i64(id * VISIT_APART_MS), k.url, k.title)
		}
	}
	e2e.write_text(fmt.tprintf("%s/%s", profile, HISTORY_FILE), strings.to_string(b))
}

// The field gets the keyboard from a click on it, a click of its own however soon after the last.
@(private = "file")
click_field :: proc(s: ^e2e.Session, loc := #caller_location) {
	e2e.forget_clicks(s, loc)
	e2e.click_at(s, e2e.center(e2e.urlbar(s, loc).field), .Window, loc = loc)
}

// Typed as a hand does, each letter in a frame of its own (a text that grows at its end is completed, a text pasted over the field is not); it has
// its inline completion: the first row of the list is this address.
@(private = "file")
type_until_completed :: proc(s: ^e2e.Session, text, part: string, loc := #caller_location) {
	for i in 0 ..< len(text) { e2e.type_text(s, text[i:i + 1], loc) }
	e2e.wait_until(s, part, proc(s: ^e2e.Session, part: string) -> bool {
		bar := e2e.urlbar(s)
		return bar.open && len(bar.rows) > 0 && strings.contains(bar.rows[0].url, part)
	}, "the inline completion", loc = loc)
}

// The list has a row of this address, with its cross laid out.
@(private = "file")
row_with_cross :: proc(s: ^e2e.Session, part: string) -> (e2e.Urlbar_Row, bool) {
	for r in e2e.urlbar(s).rows { if strings.contains(r.url, part) && r.has_cross { return r, true } }
	return {}, false
}

@(test)
urlbar_suggestions :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	profile := e2e.temp_profile(t)
	write_history(profile, server.origin)
	s := e2e.start(t, {size = URLBAR_SIZE, profile = profile, url = "about:history"})
	e2e.shot(s, "00 start.png")

	// the inline completion of an address of the test server, and Enter
	click_field(s)
	type_until_completed(s, fmt.tprintf("%s/site/ind", strings.trim_prefix(server.origin, "http://")), SITE_INDEX)
	e2e.shot(s, "01 completion.png")
	e2e.key(s, "Enter")
	e2e.wait_load(s)
	testing.expect_value(t, e2e.location(s), fmt.tprintf("%s%s", server.origin, SITE_INDEX))

	// Shift+Delete on the completed row
	click_field(s)
	type_until_completed(s, "gitl", GITLAB)
	e2e.shot(s, "02 gitlab completed.png")
	e2e.key(s, "Shift+Delete")
	e2e.shot(s, "03 gitlab removed.png")

	// the cross of a row: shown under the pointer, a click removes the row
	e2e.key(s, "Backspace", repeat = 3)
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { _, ok := row_with_cross(s, GIT_SCM); return ok }, "the row of git-scm.com in the list")
	row, _ := row_with_cross(s, GIT_SCM)
	cross := e2e.center(row.cross)
	e2e.hover(s, cross, .Window)
	e2e.shot(s, "04 cross hovered.png")
	e2e.forget_clicks(s)
	e2e.click_at(s, cross, .Window)
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool {
		for r in e2e.urlbar(s).rows { if strings.contains(r.url, GIT_SCM) { return false } }
		return true
	}, "the row of git-scm.com to leave the list")
	e2e.shot(s, "05 after the cross.png")

	e2e.key(s, "Down")
	e2e.shot(s, "06 down.png")
	testing.expect(t, e2e.urlbar(s).open, "Down keeps the list open")
	e2e.key(s, "Escape")
	e2e.shot(s, "07 escape.png")
	testing.expect(t, !e2e.urlbar(s).open, "Escape closes the list")

	// (the browser ends here: what it keeps is written)
	e2e.stop(s)
	history := e2e.read_text(fmt.tprintf("%s/%s", profile, HISTORY_FILE))
	visits := 0
	site := fmt.tprintf("\t%s%s\t", server.origin, SITE_INDEX)
	for line in strings.split_lines(history, context.temp_allocator) {
		if strings.has_prefix(line, "v\t") && strings.contains(line, site) { visits += 1 }
	}
	testing.expect_value(t, visits, SITE_VISITS_AFTER)   // Enter on the completed address of the test server opened it: one more visit
	testing.expect(t, !strings.contains(history, GITLAB), "Shift+Delete removed every visit of gitlab.com from the profile")
	testing.expect(t, !strings.contains(history, GIT_SCM), "the cross removed every visit of git-scm.com from the profile")
	testing.expect(t, strings.contains(history, ODIN_REPOSITORY), "the other addresses stay")
}
