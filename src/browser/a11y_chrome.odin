package browser

import "core:strings"
import "toolkit:ui"
import "wb:i18n"

// Accessibility of the chrome (the toolkit's ui.a11y, docs/accessibility.md): what the boxes of the tab strip, the
// sidebar, the address bar and the buttons are to a screen reader. The widgets of the toolkit say most of it; this file
// names what only the browser knows (a tab is a tab of a page, a glyph button goes back) and gives the custom boxes of
// the chrome their roles.

// A chrome button named by its tooltip: "Back (Alt+Left); right click: history" is the button "Back", its shortcut
// "Alt+Left", the rest its description. A name the app gave stands; the id the toolkit falls back to does not.
chrome_tip_a11y :: proc(b: ^ui.Box, tip_text: string) {
	if b == nil || tip_text == "" { return }
	text := strings.clone(tip_text, ui.frame_allocator())   // (tips are often temporary strings: the tree is made at the end of the build)
	name, shortcut := tip_name(text)
	cur := b.a11y
	// (a box that shows text keeps it as its name: the tip only describes it)
	if ui.a11y_box_text(b) == "" && (cur == nil || cur.name == "" || cur.name == b.name) {
		info := ui.A11y_Info{name = name}
		if (cur == nil || cur.role == .Unknown) && .Clickable in b.flags { info.role = .Button }
		ui.a11y_set(b, info)
	}
	if b.a11y == nil { ui.a11y_set(b, {}) }
	if b.a11y.shortcut == "" && shortcut != "" { b.a11y.shortcut = shortcut }
	if b.a11y.description == "" && text != b.a11y.name && text != ui.a11y_box_text(b) { b.a11y.description = text }
}

// The name of a tooltip (what comes before " (", ":", ";" or a new line) and the shortcut in its first parentheses
// ("Ctrl+T", "F5", "Escape").
tip_name :: proc(text: string) -> (name, shortcut: string) {
	end := len(text)
	for sep in ([?]string{" (", ":", ";", "\n"}) {
		if i := strings.index(text, sep); i > 0 && i < end { end = i }
	}
	name = strings.trim_space(text[:end])
	if lo := strings.index(text, "("); lo >= 0 {
		if hi := strings.index(text[lo:], ")"); hi > 1 {
			inner := text[lo + 1:][:hi - 1]
			key := inner
			if c := strings.index(key, ","); c > 0 { key = key[:c] }
			key = strings.trim_space(key)
			looks_like_key := strings.contains(key, "+") || key == "Escape" || key == "Enter" || key == "Shift+Enter" ||
				(len(key) >= 2 && len(key) <= 3 && key[0] == 'F' && key[1] >= '0' && key[1] <= '9')
			if looks_like_key { shortcut = key }
		}
	}
	return
}

// A tab of the strip or of the sidebar: its page's title, selected when it is the current tab, "3 of 12", busy while
// the page loads. Its close button stays reachable (no_children = false); its title is its name, not a child.
tab_a11y :: proc(b: ^ui.Box, t: ^Tab, i, n: int, on: bool) {
	title := t.title != "" ? t.title : (t.url != "" ? t.url : i18n.tr("tab", "New tab"))
	ui.a11y_set(b, {role = .Tab, name = title, selected = on, position = i + 1, set_size = n, busy = tab_busy(t),
		no_children = false, actions = {.Show_Context_Menu}})
}

// The container of the tabs: a tab list (vertical in the sidebar).
tab_list_a11y :: proc(b: ^ui.Box, vertical: bool) {
	ui.a11y_set(b, {role = .Tab_List, name = i18n.tr("Tabs"), orientation = vertical ? ui.Axis.Y : ui.Axis.X})
}

// What the chrome's caption buttons are called (the toolkit's window_buttons).
chrome_a11y_init :: proc() {
	ui.set_window_button_names(i18n.tr("window", "Minimize"), i18n.tr("window", "Maximize"), i18n.tr("window", "Restore"), i18n.tr("window", "Close"))
}
