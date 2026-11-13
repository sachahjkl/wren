package e2e_scenarios

// Who owns the address field's text and what a command asks of the next build, with no browser around them (chrome_world.odin):
//   * the field shows what the tab says, the empty field of a home tab too, whatever brought the tab back (a switch, Escape);
//   * what the user typed stays while the keyboard is there, whatever happens to the tabs (a switch made from outside, another
//     tab closed, the address of the page changing), even selected as a whole; without the keyboard a tab shown afresh takes it back;
//   * in full screen, where the bars are not built, what a command asks of them comes at once, not at the next visit of the pointer.
// (With a page and a load: keyboard_owner.odin, urlbar.odin.)

import "core:strings"
import "core:testing"
import "toolkit:platform"
import session "toolkit:testkit/session"
import "toolkit:ui"
import "wb:browser"

@(private = "file") FIRST :: "one"
@(private = "file") SECOND :: "two"
@(private = "file") THIRD :: "three"
@(private = "file") FIRST_URL :: "https://one.test/"
@(private = "file") SECOND_URL :: "https://two.test/"
@(private = "file") ADDRESS_BOX :: "address"
@(private = "file") TYPED :: "typed"
@(private = "file") PUSHED_URL :: "https://one.test/pushed"
@(private = "file") FULL_SCREEN_FRAMES :: 4   // the build after the change of the window, and what it asked for
@(private = "file") MID_WINDOW :: [2]f32{300, 300}

@(private = "file")
field_text :: proc(w: ^Chrome_World) -> string { return ui.line_edit_string(&w.wnd.address) }

@(private = "file")
make_home :: proc(w: ^Chrome_World, i: int) {
	delete(w.wnd.tabs[i].url)
	w.wnd.tabs[i].url = strings.clone(browser.HOME_URL)
}

@(private = "file")
type_in_field :: proc(w: ^Chrome_World) {
	session.click(w.s, ADDRESS_BOX)
	session.type_slowly(w.s, TYPED)
	session.frames(w.s, 2)
	testing.expect_value(w.s.t, field_text(w), TYPED)
}

@(test)
a_home_tab_shown_again_has_an_empty_address_field :: proc(t: ^testing.T) {
	w := chrome_start(t, {tabs = {FIRST, SECOND}})
	make_home(w, 1)
	chrome_select(w, SECOND)
	testing.expect_value(t, field_text(w), "")
	chrome_select(w, FIRST)
	testing.expect_value(t, field_text(w), FIRST_URL)
	chrome_select(w, SECOND)
	testing.expect_value(t, field_text(w), "")
}

@(test)
escape_on_a_home_tab_empties_the_address_field :: proc(t: ^testing.T) {
	w := chrome_start(t, {tabs = {FIRST, SECOND}})
	make_home(w, 1)
	chrome_select(w, SECOND)
	type_in_field(w)
	session.key(w.s, .Escape)   // (the list of suggestions)
	session.key(w.s, .Escape)
	session.frames(w.s, 2)
	testing.expect_value(t, field_text(w), "")
}

@(test)
what_is_typed_stays_through_a_tab_switch_from_outside :: proc(t: ^testing.T) {
	w := chrome_start(t, {tabs = {FIRST, SECOND}})
	type_in_field(w)
	chrome_select(w, SECOND)
	testing.expect_value(t, field_text(w), TYPED)
	session.key(w.s, .Escape)
	session.key(w.s, .Escape)
	session.frames(w.s, 2)
	testing.expect_value(t, field_text(w), SECOND_URL)   // Escape: the address of the tab shown now
}

@(test)
what_is_typed_stays_when_another_tab_closes :: proc(t: ^testing.T) {
	w := chrome_start(t, {tabs = {FIRST, SECOND, THIRD}})
	type_in_field(w)
	browser.tab_close(w.app, 2)
	session.frames(w.s, 2)
	testing.expect_value(t, field_text(w), TYPED)
}

@(test)
what_is_typed_stays_selected_as_a_whole_when_the_page_changes_its_address :: proc(t: ^testing.T) {
	w := chrome_start(t, {tabs = {FIRST}})
	type_in_field(w)
	ui.line_edit_select_all(&w.wnd.address)
	browser.same_document_url(w.app, w.wnd.tabs[0], PUSHED_URL)
	session.frames(w.s, 2)
	testing.expect_value(t, field_text(w), TYPED)
}

@(test)
what_is_typed_goes_when_the_keyboard_left_and_the_tab_changes :: proc(t: ^testing.T) {
	w := chrome_start(t, {tabs = {FIRST, SECOND}})
	type_in_field(w)
	ui.set_focus(0)
	session.frames(w.s, 2)
	testing.expect_value(t, field_text(w), TYPED)   // (the keyboard left: nothing asks for the text yet)
	chrome_select(w, SECOND)
	testing.expect_value(t, field_text(w), SECOND_URL)
}

@(test)
an_address_that_changes_replaces_a_field_nobody_typed_in :: proc(t: ^testing.T) {
	w := chrome_start(t, {tabs = {FIRST}})
	browser.same_document_url(w.app, w.wnd.tabs[0], PUSHED_URL)
	session.frames(w.s, 2)
	testing.expect_value(t, field_text(w), PUSHED_URL)
	// with the keyboard there and all of it selected too: the next letter replaces what came
	chrome_command(w, "nav.focus_address")
	browser.same_document_url(w.app, w.wnd.tabs[0], FIRST_URL)
	session.frames(w.s, 2)
	testing.expect_value(t, field_text(w), FIRST_URL)
	testing.expect(t, ui.line_edit_has_selection(&w.wnd.address), "what came is selected")
}

@(test)
full_screen_shows_the_bars_a_command_asks_for :: proc(t: ^testing.T) {
	w := chrome_start(t, {tabs = {FIRST}})
	session.move(w.s, MID_WINDOW)   // (the top edge of the screen shows the bars)
	platform.set_fullscreen(w.wnd.win, true)
	session.frames(w.s, FULL_SCREEN_FRAMES)
	testing.expect(t, session.find(w.s, ADDRESS_BOX) == nil, "full screen: no address bar")
	chrome_command(w, "nav.focus_address")
	session.frames(w.s, FULL_SCREEN_FRAMES)
	testing.expect(t, ui.focus_key() != 0 && ui.focus_key() == w.wnd.own.address_key, "Ctrl+L: the address bar has the keyboard")
	session.type_slowly(w.s, TYPED)
	session.frames(w.s, 2)
	testing.expect_value(t, field_text(w), TYPED)
	session.key(w.s, .Escape)
	session.key(w.s, .Escape)
	session.frames(w.s, FULL_SCREEN_FRAMES)
	chrome_command(w, "browser.main_menu")
	session.frames(w.s, FULL_SCREEN_FRAMES)
	testing.expect(t, ui.menu_any_open(), "Alt+F: the main menu is open")
	platform.set_fullscreen(w.wnd.win, false)
}
