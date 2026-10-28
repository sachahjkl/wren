package browser

import "toolkit:ui"
import "wb:config"
import "wb:fetch"

////////////////////////////////
// Paths of this computer as addresses: what is typed or pasted in the address bar, what is given on the command line,
// and files or folders dropped on the window, all become the file: URL of the path. A folder then opens its index.html
// or its listing (fetch/directory.odin). A relative path is ambiguous: it stays a search. The syntax of a path is the
// system's (local_paths_windows.odin: drive letters, UNC shares, backslashes, %USERPROFILE%; local_paths_other.odin:
// POSIX absolute paths and ~), so this file holds only what every system shares.

LOCAL_PATH_PREFS := [?]config.Def{
	{name = "browser.drop.open_files", kind = .Bool, default = {b = true},
		description = "Files and folders dropped on the window open: the first in the current tab, the others in new tabs."},
}

register_local_path_prefs :: proc(p: ^config.Prefs) { config.register(p, LOCAL_PATH_PREFS[:]) }

////////////////////////////////
// Dropping files and folders on the window. The toolkit's drag-and-drop (dnd_shell.odin, neutral on every backend) opens
// dropped files through default_drop -> open_dropped_paths. Windows adds a WM_DROPFILES hook for the elevated browser,
// where OLE drops are refused by UIPI (local_paths_windows.odin); other systems need none (drop_files_platform_* are the
// no-ops of local_paths_other.odin).

drop_files_init :: proc(app: ^App) {
	dnd_init(app)   // dnd_shell.odin: the toolkit drop target (drags with their events to the page)
	drop_files_platform_init(app)
	drop_files_platform_apply(app)
	config.watch(&app.prefs, "browser.drop.", proc(user: rawptr, name: string, p: ^config.Prefs) { drop_files_platform_apply((^App)(user)) }, app)
}

drop_files_destroy :: proc(app: ^App) {
	dnd_destroy(app)
	page_input_destroy(app)
	drop_files_platform_destroy(app)
}

// Files and folders dropped on the window: the first in the current tab, the others in new tabs (in the background).
open_dropped_paths :: proc(app: ^App, paths: []string) {
	wnd := active_window(app)
	first := -1
	for p, i in paths {
		address := fetch.file_url_from_path(p, false, context.temp_allocator)   // a folder is redirected to its URL with '/'
		if i == 0 && current_tab(app) != nil {
			first = wnd.current
			navigate(app, current_tab(app), address, origin = .User)
		} else {
			tab_open(app, address, origin = .User)
			if first < 0 { first = wnd.current }
		}
	}
	// the first one is shown (the others wait in their tabs, as when links open in the background)
	if first >= 0 && first < len(wnd.tabs) {
		wnd.current = first
		if t := current_tab(app); t != nil { ui.field_set(&wnd.address, t.url) }
	}
	request_frames(app, 3)
}
