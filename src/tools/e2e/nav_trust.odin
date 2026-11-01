package e2e_scenarios

// Who chose the address of a navigation (nav_trust.odin). A web page asks, by script, for the addresses a web page must never reach
// (about:sites?clear=..., a file of this computer, a share through UNC); the navigation is refused, and what is left of it (the tab's address, the
// history entry) must not turn into an order the next F5, reload or Back obeys. The same addresses given by the person still work, and the page
// of the browser that offers them (about:sites) still acts through its own links.

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:e2e"

@(private = "file") TRUST_PAGE :: "/site/remote/fixture.htm"
@(private = "file") CLEAR_ALL :: "about:sites?clear=*&type=all"
@(private = "file") SITES :: "about:sites"
@(private = "file") SECRET_TITLE :: "LOCAL-SECRET"
@(private = "file") SECRET_PAGE :: "<title>" + SECRET_TITLE + "</title>local secret"
@(private = "file") REFUSED :: "Blocked: a web page cannot open a file"

@(private = "file")
stored :: proc(s: ^e2e.Session, loc := #caller_location) -> string { return e2e.eval(s, `String(localStorage.getItem("nav_trust"))`, loc = loc) }

@(private = "file")
store :: proc(s: ^e2e.Session, value: string, loc := #caller_location) { e2e.eval(s, fmt.tprintf(`localStorage.setItem("nav_trust", "%s"); 'ok'`, value), loc = loc) }

// The page asks for it by script, out of the call that gives the script.
@(private = "file")
page_asks_for :: proc(s: ^e2e.Session, address: string, loc := #caller_location) {
	e2e.eval(s, fmt.tprintf(`setTimeout(function () {{ location.href = "%s" }}, 0); 'ok'`, address), loc = loc)
}

@(private = "file")
console_says :: proc(s: ^e2e.Session, text: string) -> bool {
	for l in e2e.console(s) { if strings.contains(l.text, text) { return true } }
	return false
}

@(private = "file")
press_f5 :: proc(s: ^e2e.Session, loc := #caller_location) {
	e2e.key(s, "F5", loc = loc)
	e2e.wait_load(s, loc = loc)
}

@(test)
nav_trust_end_to_end :: proc(t: ^testing.T) {
	secret := fmt.tprintf("%s/secret.html", e2e.temp_folder(t))
	e2e.write_text(secret, SECRET_PAGE)
	secret_url := e2e.file_url(secret)
	page := e2e.url(e2e.test_server(t), TRUST_PAGE)
	s := e2e.start(t, {url = page})
	store(s, "kept")
	testing.expect_value(t, stored(s), "kept")   // the data is there to begin with

	// a page asks for about:sites?clear=*&type=all
	page_asks_for(s, CLEAR_ALL)
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return strings.has_prefix(e2e.location(s), SITES) }, "the page's navigation to about:sites")
	testing.expect_value(t, e2e.location(s), SITES)   // a page can open about:sites, without its query
	press_f5(s)
	e2e.navigate(s, page)
	testing.expect_value(t, stored(s), "kept")   // F5 on it cleared nothing
	e2e.go_back(s)
	e2e.go_forward(s)
	e2e.navigate(s, page)
	testing.expect_value(t, stored(s), "kept")   // Back and Forward over it cleared nothing

	// a page asks for a file of this computer, and for a share (the loopback admin share names this very file)
	forward_slashes, _ := strings.replace_all(secret, `\`, "/", context.temp_allocator)
	share, _ := strings.replace(forward_slashes, ":", "$", 1, context.temp_allocator)
	for address in ([]string{secret_url, fmt.tprintf("file://127.0.0.1/%s", share)}) {
		e2e.console(s, clear = true)
		page_asks_for(s, address)
		e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return console_says(s, "Blocked") }, "the page's console to say it was refused")
		testing.expectf(t, console_says(s, REFUSED), "a page asking for %s is refused in its console", address)
		testing.expect_value(t, e2e.location(s), page)   // the tab stays on the page
		press_f5(s)
		testing.expect_value(t, e2e.location(s), page)   // F5 does not open it
		testing.expect(t, e2e.eval(s, "document.title") != SECRET_TITLE, "F5 does not show the file")
	}

	// what the person gives still works
	e2e.navigate(s, secret_url)
	testing.expect_value(t, e2e.eval(s, "document.title"), SECRET_TITLE)   // typed, a file opens
	press_f5(s)
	testing.expect_value(t, e2e.eval(s, "document.title"), SECRET_TITLE)   // and F5 shows it again
	e2e.navigate(s, page)
	store(s, "again")
	e2e.navigate(s, CLEAR_ALL)
	e2e.navigate(s, page)
	testing.expect_value(t, stored(s), "null")   // typed, about:sites?clear=... clears the data

	// the page of the browser acts through its own links
	store(s, "link")
	e2e.navigate(s, SITES)
	e2e.click(s, "a.clear")
	e2e.wait_load(s)
	e2e.navigate(s, page)
	testing.expect_value(t, stored(s), "null")   // about:sites' own Clear all link clears the data

	// going back to an entry that was typed with a clear does not clear again
	store(s, "history")
	e2e.navigate(s, CLEAR_ALL)
	e2e.navigate(s, page)
	store(s, "after")
	e2e.go_back(s)
	e2e.go_forward(s)
	testing.expect_value(t, stored(s), "after")   // Back to the typed clear and Forward again do not clear a second time
}
