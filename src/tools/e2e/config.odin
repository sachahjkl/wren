package e2e_scenarios

// about:config, from the keys a user would press; the registry says what they did. Ctrl+F, a search of several words, Down into the list, Enter
// on a switch: the preference flips. A number: Enter edits it, a typed value and Enter apply it; a value out of range is refused; Delete puts the
// default back. A choice: Enter, Down (opens the list), Down, Enter: the next value. The categories: Shift+Tab from the list, type-ahead to a
// category, Right into its list, Enter on its first preference. Right and Left open and close a preference's details.

import "core:testing"
import "wb:e2e"

@(private = "file") CONFIG_SIZE :: [2]int{1280, 900}
@(private = "file") CONFIG_DPI :: 100
@(private = "file") SWITCH_PREF :: "blocker.badge.enabled"
@(private = "file") NUMBER_PREF :: "blocker.cosmetic.max_selectors"
@(private = "file") NUMBER_DEFAULT :: "20000"
@(private = "file") NUMBER_VALUE :: "12345"
@(private = "file") NUMBER_OUT_OF_RANGE :: "5"
@(private = "file") CHOICE_PREF :: "blocker.badge.style"
@(private = "file") CHOICE_NEXT :: "inside"
@(private = "file") CATEGORY_PREF :: "cookies.enabled"
@(private = "file") SAME_PICTURE_TOLERANCE :: 0
// The window without its status bar, window pixels.
@(private = "file") PICTURE :: e2e.Shot_Options{target = .Rect, rect = {0, 0, f64(CONFIG_SIZE.x), f64(CONFIG_SIZE.y) - STATUS_BAR_HEIGHT}}
@(private = "file") STATUS_BAR_HEIGHT :: 40

// A search from the field: what is there is selected, typed over; down to the first preference under the header.
@(private = "file")
search :: proc(s: ^e2e.Session, words: string, loc := #caller_location) {
	e2e.key(s, "Ctrl+F", loc = loc)
	e2e.type_text(s, words, loc)
	keys(s, {"Down", "Down"}, loc)
}

// Each in a frame of its own, as a hand's keys are.
@(private = "file")
keys :: proc(s: ^e2e.Session, list: []string, loc := #caller_location) {
	for k in list { e2e.key(s, k, loc = loc) }
}

// How many pixels of two captures of the window differ.
@(private = "file")
pixels_differ :: proc(a, b: e2e.Image) -> int {
	if a.width != b.width || a.height != b.height { return a.width * a.height }
	count, _, _ := e2e.diff_pictures(a.rgba, b.rgba, a.width, a.height, SAME_PICTURE_TOLERANCE)
	return count
}

@(test)
config_end_to_end :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = CONFIG_SIZE, dpi = CONFIG_DPI, url = "about:config"})

	testing.expect_value(t, e2e.pref_get(s, SWITCH_PREF), "true")
	search(s, "blocker badge enabled")
	e2e.key(s, "Enter")
	testing.expect_value(t, e2e.pref_get(s, SWITCH_PREF), "false")   // search, Down into the list, Enter flips a switch
	e2e.key(s, "Delete")
	testing.expect_value(t, e2e.pref_get(s, SWITCH_PREF), "true")    // Delete resets it to its default

	search(s, "cosmetic max selectors")
	e2e.key(s, "Enter")
	e2e.type_text(s, NUMBER_VALUE)
	e2e.key(s, "Enter")
	testing.expect_value(t, e2e.pref_get(s, NUMBER_PREF), NUMBER_VALUE)   // Enter edits a number, Enter applies it
	e2e.shot(s, "01 number edited.png")
	e2e.key(s, "Enter")
	e2e.type_text(s, NUMBER_OUT_OF_RANGE)
	e2e.key(s, "Enter")
	testing.expect_value(t, e2e.pref_get(s, NUMBER_PREF), NUMBER_VALUE)   // a value out of range is refused
	e2e.shot(s, "02 out of range.png")
	e2e.key(s, "Delete")
	testing.expect_value(t, e2e.pref_get(s, NUMBER_PREF), NUMBER_DEFAULT)   // Delete puts the default back

	search(s, "badge style")
	keys(s, {"Enter", "Down", "Down", "Enter"})
	testing.expect_value(t, e2e.pref_get(s, CHOICE_PREF), CHOICE_NEXT)   // a choice: Enter, Down opens it, Down, Enter picks the next value
	e2e.pref_reset(s, CHOICE_PREF)

	// the details fold of the active row: they open, and closing them gives the same picture back (the status bar is left out: its frame graph changes by itself, and any two pictures of the whole window differ)
	e2e.wait_chrome_still(s)
	closed := e2e.capture(s, PICTURE)
	e2e.shot(s, "03 details closed.png", PICTURE)
	e2e.key(s, "Right")
	e2e.wait_chrome_still(s)
	opened := e2e.capture(s, PICTURE)
	testing.expect(t, pixels_differ(closed, opened) > 0, "Right opens the details of a preference (the page changes)")
	e2e.key(s, "Left")
	e2e.wait_chrome_still(s)
	e2e.shot(s, "04 details closed again.png", PICTURE)
	testing.expect_value(t, pixels_differ(closed, e2e.capture(s, PICTURE)), 0)   // Left closes them

	// a category by the keyboard: the search emptied, back to the list, Shift+Tab to the categories, type-ahead, Right into its list
	keys(s, {"Ctrl+F", "Backspace", "Down"})
	e2e.key(s, "Shift+Tab")
	e2e.type_text(s, "cookies")
	e2e.key(s, "Right")
	testing.expect_value(t, e2e.pref_get(s, CATEGORY_PREF), "true")
	e2e.key(s, "Enter")
	testing.expect_value(t, e2e.pref_get(s, CATEGORY_PREF), "false")   // a category picked by type-ahead, Right into it, Enter on its first preference
	e2e.shot(s, "05 cookies category.png")
}
