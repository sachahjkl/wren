package browser

// Browser extensions in the shell (docs/extensions.md, section 3.10): start-up and shutdown, the loads of packages, the
// profile's files, what the router asks of the shell (Ext_Embedder: tabs, windows, which page is a popup), and the
// install prompt's answer. src/extensions holds the data, src/page runs the contexts; the toolbar button is
// ext_toolbar.odin, about:extensions ext_page.odin.
//
// Nothing here touches the disk on the loop thread: a package is read by image_load on the blocking pool, the list is
// read there too, and every file is written through a Profile_File (profile_writes.odin).

import "core:os"
import "core:strings"
import "wb:base"
import "wb:config"
import "wb:extensions"
import "wb:host"
import "wb:page"

// Why a package is loaded: the answer is used accordingly when it comes back (ext_load_done).
Ext_Load_Kind :: enum u8 { Startup, Install, Reload }

Ext_Shell :: struct {
	started:  bool,
	watch:    int,                          // the preferences' observer (extensions.*)
	files:    map[string]^Profile_File,     // the profile's files of the extensions, by path (owned keys)
	pending:  [dynamic]^extensions.Load_Result,   // loaded packages waiting for the install prompt's answer
	notice:   string,                       // owned: what about:extensions says on top (the last result)
	picking:  bool,                         // the folder dialog is open
	loading:  int,                          // loads in flight
	popups:   map[u64]string,               // tabs that show an extension's popup: tab id -> extension id (owned)
	toolbar:  Ext_Toolbar,                  // ext_toolbar.odin: the buttons' icons
}

ext_reg :: proc(app: ^App) -> ^extensions.Registry { return &app.pages.extensions }

ext_shell_start :: proc(app: ^App) {
	if app.ext.started { return }
	app.ext.started = true
	dir := app.cfg.persist_profile ? app.profile_dir : ""
	reg := ext_reg(app)
	extensions.registry_init(reg, extensions.settings_from_prefs(&app.prefs), dir, "en-US")
	reg.write, reg.write_user = ext_write, app
	app.loader.extensions = reg
	page.ext_router_init(&app.loop, page.Ext_Embedder{
		user = app, page_kind = ext_page_kind, tabs = ext_tabs, windows = ext_windows, focused_window = ext_focused_window, changed = ext_changed,
	}, &app.loader, &app.page_settings, &app.storage)
	app.ext.watch = config.watch(&app.prefs, "extensions.", ext_prefs_changed, app)
	if !reg.settings.enabled || dir == "" { return }
	// the list, read off the loop thread; each listed package is then loaded (ext_load)
	Job :: struct { app: ^App, path, text: string }
	job := new(Job)
	job.app, job.path = app, strings.concatenate({dir, "/", extensions.LIST_FILE})
	host.run_blocking(&app.blocking, proc(data: rawptr) {
		j := (^Job)(data)
		context.allocator = base.process_allocator()
		if bytes, err := os.read_entire_file(j.path, context.allocator); err == nil { j.text = string(bytes) }
	}, proc(data: rawptr) {
		j := (^Job)(data)
		defer { delete(j.path); delete(j.text); free(j) }
		app := j.app
		if !app.ext.started { return }
		for le in extensions.registry_list_parse(j.text) {
			e := extensions.registry_add_listed(ext_reg(app), le)
			ext_load(app, e.path, .Startup)
		}
	}, job, proc(data: rawptr) {
		j := (^Job)(data)
		delete(j.path); delete(j.text); free(j)
	})
}

ext_shell_stop :: proc(app: ^App) {
	if !app.ext.started { return }
	app.ext.started = false
	config.unwatch(&app.prefs, app.ext.watch)
	page.ext_router_destroy()
	app.loader.extensions = nil
	extensions.registry_destroy(ext_reg(app))
	for p in app.ext.pending { extensions.load_result_destroy(p); free(p) }
	delete(app.ext.pending)
	for k, f in app.ext.files {
		profile_file_flush(f)
		profile_file_destroy(f)
		free(f)
		delete(k)
	}
	delete(app.ext.files)
	for _, id in app.ext.popups { delete(id) }
	delete(app.ext.popups)
	delete(app.ext.notice)
	ext_toolbar_destroy(app)
	app.ext = {}
}

@(private = "file")
ext_prefs_changed :: proc(user: rawptr, name: string, p: ^config.Prefs) {
	app := (^App)(user)
	if !app.ext.started { return }
	ext_reg(app).settings = extensions.settings_from_prefs(p)
	request_frames(app, 2)
}

// The registry's writer: one Profile_File per path, written by the blocking pool.
@(private = "file")
ext_write :: proc(user: rawptr, path, text: string, remove: bool) {
	app := (^App)(user)
	f := app.ext.files[path]
	if f == nil {
		f = new(Profile_File)
		profile_file_init(f, app, path)
		app.ext.files[strings.clone(path)] = f
	}
	if remove { profile_file_remove(f) } else { profile_file_write(f, text) }
}

// A message for the top of about:extensions, shown with the page's next showing (ext_page_refresh after a load).
ext_notice :: proc(app: ^App, text: string) {
	delete(app.ext.notice)
	app.ext.notice = strings.clone(text)
}

////////////////////////////////
// Loading a package (off the loop thread)

@(private = "file")
Ext_Load_Job :: struct {
	app:      ^App,
	kind:     Ext_Load_Kind,
	path:     string,
	settings: extensions.Settings,
	dir:      string,
	result:   extensions.Load_Result,
}

ext_load :: proc(app: ^App, path: string, kind: Ext_Load_Kind) {
	reg := ext_reg(app)
	j := new(Ext_Load_Job)
	j^ = {app = app, kind = kind, path = strings.clone(path), settings = reg.settings, dir = strings.clone(reg.dir)}
	j.settings.restricted_hosts = ""   // (a string of the preferences: not read on the pool's thread)
	app.ext.loading += 1
	host.run_blocking(&app.blocking, proc(data: rawptr) {
		j := (^Ext_Load_Job)(data)
		context.allocator = base.process_allocator()
		j.result = extensions.image_load(j.path, j.settings, "en-US", j.dir)
		if j.dir != "" && j.result.image != nil {
			_ = os.make_directory_all(strings.concatenate({extensions.extension_profile_dir(j.dir, j.result.image.id), "/storage"}, context.temp_allocator))
		}
	}, ext_load_done, j, proc(data: rawptr) {
		j := (^Ext_Load_Job)(data)
		extensions.load_result_destroy(&j.result)
		delete(j.path); delete(j.dir); free(j)
	})
}

@(private = "file")
ext_load_done :: proc(data: rawptr) {
	j := (^Ext_Load_Job)(data)
	app := j.app
	defer { extensions.load_result_destroy(&j.result); delete(j.path); delete(j.dir); free(j) }
	app.ext.loading = max(app.ext.loading - 1, 0)
	if !app.ext.started { return }
	defer { ext_page_refresh(app); request_frames(app, 2) }   // (every outcome shows: about:extensions again)
	reg := ext_reg(app)
	r := &j.result
	switch j.kind {
	case .Startup:
		if r.image == nil {
			// (the folder is gone: the extension stays listed, with its error, until the user removes it)
			for e in reg.list { if e.path == j.path { e.loading = false; delete(e.error); e.error = strings.clone(r.error); extensions.registry_changed(reg) } }
			return
		}
		e := extensions.registry_adopt(reg, r, false)
		if e != nil && e.enabled { page.ext_extension_start(e, true) }
	case .Install:
		if r.image == nil || !r.image.ok {
			ext_notice(app, strings.concatenate({"The extension could not be loaded: ", r.error != "" ? r.error : "unknown error"}, context.temp_allocator))
			return
		}
		if extensions.registry_find(reg, r.image.id) != nil {
			// the same folder again: a reload, which keeps its grants
			ext_reload_with(app, r)
			return
		}
		if len(reg.list) + len(app.ext.pending) >= reg.settings.max_installed {
			ext_notice(app, "Too many extensions are installed (extensions.max_installed).")
			return
		}
		p := new(extensions.Load_Result)
		p^ = r^
		r^ = {}
		append(&app.ext.pending, p)
		ext_notice(app, "")
	case .Reload:
		if r.image == nil { ext_notice(app, strings.concatenate({"The extension could not be reloaded: ", r.error}, context.temp_allocator)); return }
		ext_reload_with(app, r)
	}
}

// The new image of an installed extension takes the place of the old one: its background starts over, its pages load again.
@(private = "file")
ext_reload_with :: proc(app: ^App, r: ^extensions.Load_Result) {
	reg := ext_reg(app)
	id := strings.clone(r.image.id, context.temp_allocator)
	page.ext_extension_stop(id)
	e := extensions.registry_adopt(reg, r, false)
	if e == nil { return }
	extensions.registry_save_list(reg)
	if e.enabled { page.ext_extension_start(e, false) }
	ext_reload_pages(app, id)
	ext_notice(app, e.error != "" ? strings.concatenate({"Reloaded with an error: ", e.error}, context.temp_allocator) : "Reloaded.")
}

@(private = "file")
ext_origin_of :: proc(id: string) -> string { return strings.concatenate({extensions.SCHEME_CHROME, "://", id, "/"}, context.temp_allocator) }

// The tabs that show a page of the extension load again (after a reload).
@(private = "file")
ext_reload_pages :: proc(app: ^App, id: string) {
	prefix := ext_origin_of(id)
	for t in tabs_all(app) { if strings.has_prefix(t.url, prefix) { reload(app, t) } }
}

// The tabs that show a page of the extension close (it is disabled or removed).
@(private = "file")
ext_close_pages :: proc(app: ^App, id: string) {
	prefix := ext_origin_of(id)
	ids := make([dynamic]u64, 0, 4, context.temp_allocator)
	for t in tabs_all(app) { if strings.has_prefix(t.url, prefix) { append(&ids, t.id) } }
	for tid in ids {
		t := tab_find(app, tid)
		if t == nil { continue }
		w, i := window_of_tab(app, t)
		if w == nil { continue }
		if len(app.windows) == 1 && len(w.tabs) == 1 { navigate(app, t, "", origin = .User); continue }   // (the last tab: the homepage instead)
		tab_close_in(app, w, i)
	}
}

////////////////////////////////
// What about:extensions asks (ext_page.odin)

// The install prompt was accepted: the extension is installed, its host permissions granted (Chrome's rule), it starts.
ext_accept :: proc(app: ^App, id: string) {
	reg := ext_reg(app)
	for p, i in app.ext.pending {
		if p.image == nil || p.image.id != id { continue }
		ordered_remove(&app.ext.pending, i)
		e := extensions.registry_adopt(reg, p, true)
		extensions.load_result_destroy(p)
		free(p)
		if e == nil { return }
		extensions.registry_save_list(reg)
		page.ext_extension_start(e, false)
		ext_notice(app, strings.concatenate({e.image != nil ? e.image.manifest.name : e.id, " is installed."}, context.temp_allocator))
		request_frames(app, 2)
		return
	}
}

ext_cancel :: proc(app: ^App, id: string) {
	for p, i in app.ext.pending {
		if p.image == nil || p.image.id != id { continue }
		ordered_remove(&app.ext.pending, i)
		extensions.load_result_destroy(p)
		free(p)
		ext_notice(app, "The installation was cancelled.")
		return
	}
}

ext_set_enabled :: proc(app: ^App, id: string, on: bool) {
	reg := ext_reg(app)
	e := extensions.registry_find(reg, id)
	if e == nil || e.enabled == on { return }
	e.enabled = on
	if on {
		page.ext_extension_start(e, false)
	} else {
		page.ext_extension_stop(id)
		ext_close_pages(app, id)
	}
	extensions.registry_changed(reg)
	extensions.registry_save_list(reg)
	page.ext_alarms_schedule()
	request_frames(app, 2)
}

ext_reload :: proc(app: ^App, id: string) {
	e := extensions.registry_find(ext_reg(app), id)
	if e == nil || e.loading { return }
	e.loading = true
	ext_load(app, e.path, .Reload)
}

ext_remove :: proc(app: ^App, id: string) {
	reg := ext_reg(app)
	e := extensions.registry_find(reg, id)
	if e == nil { return }
	name := strings.clone(e.image != nil ? e.image.manifest.name : id, context.temp_allocator)
	id_copy := strings.clone(id, context.temp_allocator)
	page.ext_extension_stop(id_copy)
	ext_close_pages(app, id_copy)
	// its storage goes with it (the folders stay empty: no disk call here)
	if reg.dir != "" && reg.write != nil {
		for kind in ([2]extensions.Area_Kind{.Local, .Sync}) { reg.write(reg.write_user, extensions.area_file(reg.dir, id_copy, kind), "", true) }
	}
	extensions.registry_remove(reg, id_copy)
	extensions.registry_save_list(reg)
	page.ext_alarms_schedule()
	ext_notice(app, strings.concatenate({name, " was removed."}, context.temp_allocator))
	request_frames(app, 2)
}

// Grants or withdraws one host pattern.
ext_grant :: proc(app: ^App, id, pattern: string, on: bool) {
	reg := ext_reg(app)
	e := extensions.registry_find(reg, id)
	if e == nil { return }
	extensions.grant_set(reg, e, pattern, on)
	extensions.registry_save_list(reg)
}

////////////////////////////////
// The popup (phase 1: a tab of its own)

// Opens the extension's popup: its page in a tab (the panel under the button needs the toolkit to host a page surface
// in a popup: docs/extensions.md, question 7). A popup already open is shown again.
ext_open_popup :: proc(app: ^App, e: ^extensions.Extension, popup: string) {
	if e.image == nil { return }
	for tid, id in app.ext.popups {
		if id != e.id { continue }
		if t := tab_find(app, tid); t != nil { tab_reveal(app, t); return }
	}
	t := tab_open(app, extensions.image_url(e.image, popup), origin = .User)
	if t == nil { return }
	app.ext.popups[t.id] = strings.clone(e.id)
}

////////////////////////////////
// The router's view of the shell (page.Ext_Embedder)

@(private = "file")
ext_page_kind :: proc(user: rawptr, p: ^page.Page) -> page.Ext_Kind {
	app := (^App)(user)
	if t := tab_of_page(app, p); t != nil && t.id in app.ext.popups { return .Popup }
	return .Tab
}

@(private = "file")
ext_tabs :: proc(user: rawptr, out: ^[dynamic]page.Ext_Tab_Info) {
	app := (^App)(user)
	for w in app.windows {
		for t, i in w.tabs {
			append(out, page.Ext_Tab_Info{
				id = i64(t.id), window = i64(w.id), index = i64(i), url = t.url, title = t.title,
				active = i == w.current, pinned = t.pinned, loading = t.load != nil, page = t.page != nil ? page.page_id(t.page) : 0,
			})
		}
	}
}

@(private = "file")
ext_windows :: proc(user: rawptr, out: ^[dynamic]page.Ext_Window_Info) {
	app := (^App)(user)
	front := window_front(app)
	for w in app.windows {
		state := w.minimized ? "minimized" : "normal"
		append(out, page.Ext_Window_Info{id = i64(w.id), focused = w == front, width = w.win.size.x, height = w.win.size.y, state = state})
	}
}

@(private = "file")
ext_focused_window :: proc(user: rawptr) -> i64 {
	app := (^App)(user)
	if w := window_front(app); w != nil { return i64(w.id) }
	return -1
}

@(private = "file")
ext_changed :: proc(user: rawptr, ext: string) {
	request_frames((^App)(user), 2)
}

// A tab closed: what the extensions kept for it goes.
ext_tab_closed :: proc(app: ^App, t: ^Tab) {
	if !app.ext.started { return }
	if id, ok := app.ext.popups[t.id]; ok { delete(id); delete_key(&app.ext.popups, t.id) }
	page.ext_action_tab_closed(t.id)
}
