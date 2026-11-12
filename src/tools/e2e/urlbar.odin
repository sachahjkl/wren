package e2e_scenarios

// The address bar with a real history and a real page (urlbar.odin), a profile of a known history: the inline completion of an address of the test server and Enter (a visit of it is
// recorded), what the profile's history.txt says. (The list's keys and the cross of a row, with no browser around it: chrome_address_bar.odin.)

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:e2e"

@(private = "file") URLBAR_SIZE :: [2]int{1280, 800}
@(private = "file") HISTORY_FILE :: "history.txt"
@(private = "file") SITE_INDEX :: "/site/index.html"
@(private = "file") GITLAB :: "gitlab.com"
@(private = "file") ODIN_REPOSITORY :: "https://github.com/odin-lang/Odin"
@(private = "file") SITE_VISITS :: 3
@(private = "file") SITE_VISITS_AFTER :: SITE_VISITS + 1
@(private = "file") HISTORY_AGE_MS :: 3600_000     // the visits were an hour ago
@(private = "file") VISIT_APART_MS :: 1000

@(private = "file") Known :: struct { url, title: string, visits: int }

// The profile's history: `wren-history 2`, a line per visit.
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
	strings.write_string(&b, "wren-history 2\n")
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
	testing.expect(t, strings.contains(history, ODIN_REPOSITORY), "the other addresses stay")
}

// A new tab puts the keyboard in the address bar with no list (browser.newtab.focus_address, on by default); a letter typed goes to the field and
// lists, a click on the field lists the pages visited (browser.urlbar.top_sites).
@(test)
urlbar_new_tab_focus_without_the_list :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	profile := e2e.temp_profile(t)
	write_history(profile, server.origin)
	s := e2e.start(t, {size = URLBAR_SIZE, profile = profile, url = "about:history"})

	e2e.run_command(s, "tab.new")
	e2e.wait_chrome_still(s)
	testing.expect(t, !e2e.urlbar(s).open, "a new tab shows no list")
	type_until_completed(s, "gitl", GITLAB)   // the letters went to the field: it had the keyboard

	e2e.key(s, "Escape")
	e2e.run_command(s, "tab.new")
	e2e.wait_chrome_still(s)
	testing.expect(t, !e2e.urlbar(s).open, "the second new tab shows no list either")
	click_field(s)
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { bar := e2e.urlbar(s); return bar.open && len(bar.rows) > 0 }, "the list of a click")
}

// Ctrl+T at the keyboard, from a page of any kind, and the letters typed at once are the address bar's: from a page at rest, with a text
// field of its own holding the keyboard, and while its scripts keep the thread.
@(private = "file") NEW_TAB_TYPED :: "abc"
@(private = "file") NEW_TAB_PAGE :: `<!doctype html><input id=f value=mine>`
@(private = "file") HOLD_THE_THREAD :: `setTimeout(() => { const end = performance.now() + 400; while (performance.now() < end) {} }, 0); 1`

@(private = "file")
new_tab_takes_the_letters :: proc(t: ^testing.T, s: ^e2e.Session, what: string) {
	e2e.key(s, "Ctrl+T")
	e2e.type_text(s, NEW_TAB_TYPED)
	e2e.wait_chrome_still(s)
	testing.expectf(t, e2e.urlbar(s).text == NEW_TAB_TYPED, "%s: the address bar has %q", what, e2e.urlbar(s).text)
}

@(test)
ctrl_t_gives_the_keyboard_to_the_address_bar :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = URLBAR_SIZE, url = "about:blank"})
	e2e.eval(s, "document.open(); document.write(`" + NEW_TAB_PAGE + "`); document.close(); 1")
	new_tab_takes_the_letters(t, s, "from a page at rest")
	e2e.key(s, "Ctrl+W")
	e2e.wait_chrome_still(s)
	e2e.eval(s, "f.focus(); 1")
	new_tab_takes_the_letters(t, s, "from a page's field")
	e2e.key(s, "Ctrl+W")
	e2e.wait_chrome_still(s)
	e2e.eval(s, HOLD_THE_THREAD)
	new_tab_takes_the_letters(t, s, "from a busy page")
}

// The home page of a new tab comes after the address bar took the keyboard: a document that arrives gave it back to the page, and what
// was typed went nowhere, more often the slower the page.
@(private = "file") SLOW_HOME :: "/slow"

@(test)
a_home_page_that_arrives_leaves_the_keyboard_in_the_address_bar :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = URLBAR_SIZE, url = "about:blank"})
	e2e.pref_set(s, "browser.homepage", strings.concatenate({server.origin, SLOW_HOME}, context.temp_allocator))
	e2e.key(s, "Ctrl+T")
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return strings.contains(e2e.location(s), SLOW_HOME) }, "the home page's document")
	e2e.wait_chrome_still(s)
	e2e.type_text(s, NEW_TAB_TYPED)
	e2e.wait_chrome_still(s)
	testing.expectf(t, strings.has_prefix(e2e.urlbar(s).text, NEW_TAB_TYPED), "the address bar has %q", e2e.urlbar(s).text)
}
