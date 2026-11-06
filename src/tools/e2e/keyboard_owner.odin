package e2e_scenarios

// Who has the keyboard, with real pages (src/browser/keyboard.odin):
//   * a frame's document has it for as long as the keyboard is in that frame: not behind a tab switch, not after it went through the address bar;
//   * a press on the page under a long script takes it there at once: the letters that follow wait for the page, they do not land in the address bar;
//   * Tab past the last element of a page goes to the address bar, and F6 back.
// (With no page: chrome_keyboard.odin. A new tab and a home page that arrives: urlbar.odin.)

import "core:fmt"
import "core:testing"
import "wb:e2e"

@(private = "file") SIZE :: [2]int{800, 600}
@(private = "file") SHORTER :: [2]int{800, 590}   // what lets the task of busy_probe.html go
@(private = "file") BUSY_PAGE :: "/site/busy_probe.html"
@(private = "file") SITE_PAGE :: "/site/index.html"
@(private = "file") FRAME_AT :: e2e.Point{100, 35}   // the field in the frame of FRAME_PAGE
@(private = "file") FIXED_FIELD_AT :: e2e.Point{100, 25}   // the field added to the busy page
@(private = "file") FRAME_PAGE :: `<!doctype html><style>body{margin:0}</style><iframe id=fr style="position:absolute;left:0;top:0;width:400px;height:200px;border:0" srcdoc="<!doctype html><style>body{margin:0}</style><input id=inner style='position:absolute;left:0;top:20px;width:300px;height:30px'>"></iframe><input id=top style="position:absolute;left:0;top:225px">`
@(private = "file") FIELD_PAGE :: `<!doctype html><input id=f>`
@(private = "file") FIXED_FIELD :: `window.f = document.createElement('input'); f.style.cssText = 'position:fixed;left:10px;top:10px;width:300px;height:30px;z-index:9'; document.body.append(f); 1`
@(private = "file") INNER_VALUE :: "document.getElementById('fr').contentDocument.getElementById('inner').value"
@(private = "file") TOP_FOCUS :: "document.getElementById('top').focus(); 1"
@(private = "file") TOP_VALUE :: "document.getElementById('top').value"
@(private = "file") LETTER :: "x"
@(private = "file") SECOND_LETTER :: "y"
@(private = "file") TYPED :: "abc"

@(private = "file")
write_page :: proc(s: ^e2e.Session, html: string) {
	e2e.eval(s, fmt.tprintf("document.open(); document.write(%q); document.close(); 1", html))
	e2e.wait_frames(s)
}

// A press in the frame gives it the keyboard.
@(private = "file")
frame_takes_the_keyboard :: proc(t: ^testing.T, s: ^e2e.Session) {
	write_page(s, FRAME_PAGE)
	e2e.click_at(s, FRAME_AT)
	e2e.type_text(s, LETTER)
	e2e.wait_chrome_still(s)
	testing.expect_value(t, e2e.eval(s, INNER_VALUE), LETTER)
}

@(test)
a_frame_has_no_keyboard_behind_a_tab_switch :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, software = true, url = "about:blank"})
	frame_takes_the_keyboard(t, s)
	first := e2e.targets(s).tabs[0].id
	e2e.new_tab(s, "about:blank")
	e2e.wait_load(s)
	write_page(s, FIELD_PAGE)
	e2e.eval(s, "f.focus(); 1")
	e2e.type_text(s, SECOND_LETTER)
	e2e.wait_chrome_still(s)
	testing.expect_value(t, e2e.eval(s, "f.value"), SECOND_LETTER)
	e2e.activate_tab(s, first)
	e2e.wait_chrome_still(s)
	testing.expect_value(t, e2e.eval(s, INNER_VALUE), LETTER)
	// its tab back, the frame has the keyboard again
	e2e.type_text(s, SECOND_LETTER)
	e2e.wait_chrome_still(s)
	testing.expect_value(t, e2e.eval(s, INNER_VALUE), LETTER + SECOND_LETTER)
}

// Ctrl+F lends the keyboard: Escape gives it back to the document that had it, a frame's too.
@(test)
the_find_bar_gives_the_keyboard_back_to_the_frame_that_had_it :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, software = true, url = "about:blank"})
	frame_takes_the_keyboard(t, s)
	e2e.key(s, "Ctrl+F")
	e2e.wait_chrome_still(s)
	e2e.type_text(s, TYPED)
	e2e.wait_chrome_still(s)
	testing.expect_value(t, e2e.eval(s, INNER_VALUE), LETTER)
	e2e.key(s, "Escape")
	e2e.wait_chrome_still(s)
	e2e.type_text(s, SECOND_LETTER)
	e2e.wait_chrome_still(s)
	testing.expect_value(t, e2e.eval(s, INNER_VALUE), LETTER + SECOND_LETTER)
}

@(test)
a_frame_has_no_keyboard_after_it_went_through_the_address_bar :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, software = true, url = "about:blank"})
	frame_takes_the_keyboard(t, s)
	e2e.key(s, "Ctrl+L")
	e2e.wait_chrome_still(s)
	e2e.key(s, "F6")   // to the page
	e2e.wait_chrome_still(s)
	e2e.eval(s, TOP_FOCUS)
	e2e.type_text(s, SECOND_LETTER)
	e2e.wait_chrome_still(s)
	testing.expect_value(t, e2e.eval(s, TOP_VALUE), SECOND_LETTER)
	testing.expect_value(t, e2e.eval(s, INNER_VALUE), LETTER)
}

// The address bar has the keyboard, a press on the page's field comes under a long script, and a letter in a chrome frame after it.
@(test)
letters_after_a_press_on_a_busy_page_wait_for_the_page :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = SIZE, software = true, url = fmt.tprintf("%s%s", server.origin, BUSY_PAGE)})
	e2e.eval(s, FIXED_FIELD)
	e2e.wait_frames(s)
	e2e.key(s, "Ctrl+L")
	e2e.wait_chrome_still(s)
	before := e2e.urlbar(s).text
	e2e.eval(s, "hold()")
	e2e.while_busy(s, {
		e2e.busy_press(s, FIXED_FIELD_AT), e2e.busy_release(s, FIXED_FIELD_AT),
		e2e.busy_capture(),   // (a chrome frame between: what the press decided holds in the next ones)
		{kind = .Event, ev = {kind = .Text, text = 'x'}},
		e2e.busy_resize(SHORTER),
	})
	e2e.wait_js(s, "window.released === true")
	e2e.wait_chrome_still(s)
	testing.expect_value(t, e2e.urlbar(s).text, before)
	testing.expect_value(t, e2e.eval(s, "f.value"), LETTER)
}

// A load under what is being typed: the document arrives, the text and the keyboard stay. Enter on the address shown, typed with a space after it: the tab says what it is.
@(test)
typing_while_a_tab_loads_and_enter_on_the_same_address :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = SIZE, software = true, url = "about:blank"})
	e2e.key(s, "Ctrl+L")
	e2e.wait_chrome_still(s)
	e2e.type_text(s, TYPED)
	e2e.wait_chrome_still(s)
	address := fmt.tprintf("%s%s", server.origin, SITE_PAGE)
	e2e.navigate_begin(s, address)
	e2e.wait_load(s)
	e2e.wait_chrome_still(s)
	testing.expect_value(t, e2e.urlbar(s).text, TYPED)
	e2e.type_text(s, LETTER)
	e2e.wait_chrome_still(s)
	testing.expect_value(t, e2e.urlbar(s).text, TYPED + LETTER)

	e2e.key(s, "Ctrl+A")
	e2e.type_text(s, fmt.tprintf("%s ", address))
	e2e.wait_chrome_still(s)
	e2e.key(s, "Enter")
	e2e.wait_load(s)
	e2e.wait_chrome_still(s)
	testing.expect_value(t, e2e.urlbar(s).text, address)
}

@(test)
tab_past_the_last_element_goes_to_the_address_bar_and_f6_comes_back :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, software = true, url = "about:blank"})
	write_page(s, FIELD_PAGE)
	e2e.eval(s, "f.focus(); 1")
	e2e.key(s, "Tab")
	e2e.wait_chrome_still(s)
	e2e.type_text(s, TYPED)
	e2e.wait_chrome_still(s)
	testing.expect_value(t, e2e.urlbar(s).text, TYPED)
	testing.expect_value(t, e2e.eval(s, "f.value"), "")
	e2e.key(s, "F6")
	e2e.wait_chrome_still(s)
	e2e.type_text(s, LETTER)
	e2e.wait_chrome_still(s)
	testing.expect_value(t, e2e.eval(s, "f.value"), LETTER)
}
