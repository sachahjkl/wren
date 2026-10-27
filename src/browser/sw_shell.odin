package browser

// Service workers' requests to the shell (page/service_worker.odin): clients.openWindow(url) opens a tab (this
// browser has one window: a new window is a new tab, shown), WindowClient.focus() shows the client's tab.

import "wb:page"

sw_shell_init :: proc(app: ^App) {
	page.sw_embedder = {open = sw_shell_open, focus = sw_shell_focus, user = app}
}

sw_shell_destroy :: proc(app: ^App) { page.sw_embedder = {} }

@(private = "file")
sw_shell_open :: proc(user: rawptr, url: string) -> bool {
	app := (^App)(user)
	tab_open(app, url, origin = .Page)
	request_frames(app, 2)
	return true
}

@(private = "file")
sw_shell_focus :: proc(user: rawptr, p: ^page.Page) -> bool {
	app := (^App)(user)
	for t, i in active_window(app).tabs {
		if t.page != page.page_top(p) { continue }
		tab_select(app, i)
		return true
	}
	return false
}
