package browser

import "core:strings"
import "toolkit:ui"
import "wb:base"

// about:blocker: the content blocker's dashboard, a native view like about:config and about:history (not a web page: it
// edits the blocker of the browser itself and has no document, origin or scripts).

BLOCKER_URL :: "about:blocker"

is_blocker_address :: proc(a: string) -> bool { return a == BLOCKER_URL || strings.has_prefix(a, BLOCKER_URL + "#") }

show_blocker :: proc(app: ^App, t: ^Tab, address: string) {
	base.scope_close(t.nav)
	t.nav = base.scope_make("navigation", t.scope)
	t.page, t.load, t.kind = nil, nil, .Blocker
	layout_reset(&t.layout)
	t.scroll_target = base.NIL_HANDLE
	for l in t.console { delete(l) }
	clear(&t.console)
	delete(t.url); t.url = strings.clone(address)
	delete(t.title); t.title = strings.clone("Content blocker")
	set_status(t, "about:blocker")
	ui.field_set(&app.address, address)
}

blocker_page :: proc(app: ^App, t: ^Tab) {
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.column() { ui.label("Content blocker###bd_title") }
}
