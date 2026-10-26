package browser

// File System Access in the shell (page/fs_api.odin keeps the page's side): the pickers are the system's dialogs of
// the toolkit (platform.open_file_dialog & co.), shown on a worker of the blocking pool, owned by the window; a
// permission a page asks for (requestPermission) is a small dialog of the browser over the page: "Allow" or "Block".
//
// For tests (wren ctl, no person to answer): browser.dialogs.test_answer stands for every dialog: "|"-separated paths
// chosen, or "cancel".

import "core:fmt"
import "core:strings"
import "base:runtime"
import "toolkit:platform"
import "toolkit:ui"
import "wb:config"
import "wb:host"
import "wb:i18n"
import "wb:page"

@(private = "file")
Pick_Job :: struct {
	app:    ^App,
	req:    ^page.Fs_Pick,
	dialog: platform.File_Dialog,
	result: platform.Dialog_Result,
	test:   string,     // browser.dialogs.test_answer when set
}

@(private = "file")
Ask_State :: struct {
	queue: [dynamic]^page.Fs_Ask,
}

@(private = "file")
ask_state: Ask_State

fs_shell_init :: proc(app: ^App) {
	page.fs_embedder = {pick = fs_shell_pick, ask = fs_shell_ask, user = app}
}

fs_shell_destroy :: proc(app: ^App) {
	page.fs_embedder = {}
	for r in ask_state.queue { page.fs_ask_done(r, false) }
	delete(ask_state.queue)
	ask_state = {}
}

@(private = "file")
fs_shell_pick :: proc(user: rawptr, p: ^page.Page, req: ^page.Fs_Pick) {
	app := (^App)(user)
	j := new(Pick_Job)
	j.app, j.req = app, req
	j.test = strings.clone(config.string_of(&app.prefs, "browser.dialogs.test_answer"))
	d := &j.dialog
	d.owner = app.win
	d.multiple = req.multiple
	d.all_files = req.all_files
	d.suggested_name = req.suggested
	d.start_dir = req.start_dir
	d.overwrite_prompt = true
	switch req.start_known {
	case "desktop": d.start_known = .Desktop
	case "documents": d.start_known = .Documents
	case "downloads": d.start_known = .Downloads
	case "music": d.start_known = .Music
	case "pictures": d.start_known = .Pictures
	case "videos": d.start_known = .Videos
	}
	// the system remembers the folder per site and id (File System Access "id")
	d.remember_id = strings.concatenate({page.page_origin(p), "#", req.id})
	filters := make([]platform.File_Filter, len(req.filters))
	for f, i in req.filters { filters[i] = {name = f.name, patterns = f.patterns} }
	d.filters = filters
	switch req.kind {
	case .Open: d.title = i18n.tr("Open")
	case .Save: d.title = i18n.tr("Save as")
	case .Directory: d.title = i18n.tr("Choose a folder")
	}
	host.run_blocking(&app.blocking, pick_work, pick_done, j)
}

@(private = "file")
pick_work :: proc(data: rawptr) {
	j := (^Pick_Job)(data)
	if j.test != "" {
		if j.test == "cancel" { j.result.status = .Cancelled; return }
		parts := strings.split(j.test, "|", context.temp_allocator)
		paths := make([]string, len(parts))
		for x, i in parts { paths[i] = strings.clone(x) }
		j.result = {status = .Chosen, paths = paths}
		return
	}
	switch j.req.kind {
	case .Open: j.result = platform.open_file_dialog(j.dialog)
	case .Save: j.result = platform.save_file_dialog(j.dialog)
	case .Directory: j.result = platform.pick_folder_dialog(j.dialog)
	}
}

@(private = "file")
pick_done :: proc(data: rawptr) {
	j := (^Pick_Job)(data)
	defer {
		platform.dialog_result_destroy(&j.result)
		delete(j.dialog.filters)
		delete(j.dialog.remember_id)
		delete(j.test)
		free(j)
	}
	page.fs_pick_done(j.req, j.result.status == .Chosen ? j.result.paths : nil)
	j.app.frames_requested = max(j.app.frames_requested, 2)
}

@(private = "file")
fs_shell_ask :: proc(user: rawptr, p: ^page.Page, req: ^page.Fs_Ask) {
	app := (^App)(user)
	switch config.string_of(&app.prefs, "browser.dialogs.test_answer") {
	case "": append(&ask_state.queue, req)
	case "cancel": page.fs_ask_done(req, false)
	case: page.fs_ask_done(req, true)
	}
	app.frames_requested = max(app.frames_requested, 2)
}

// The permission prompt over the page (the first request waiting), each frame while one waits.
fs_shell_build :: proc(app: ^App) {
	if len(ask_state.queue) == 0 { return }
	req := ask_state.queue[0]
	em := ui.font_size()
	open := true
	answered, granted := false, false
	if ui.modal("fs_permission", em * 30, &open) {
		ui.spacer(ui.px(em * 0.8))
		what := req.write ? i18n.tr("edit") : i18n.tr("view")
		ui.label(fmt.tprintf(i18n.tr("%s wants to %s files in"), req.origin, what))
		ui.label(req.what)
		ui.spacer(ui.px(em * 0.8))
		if ui.row() {
			if action_button(i18n.tr("Allow"), "fs_allow", em * 8) { answered, granted = true, true }
			ui.spacer(ui.px(em * 0.6))
			if action_button(i18n.tr("Block"), "fs_block", em * 8) { answered, granted = true, false }
		}
		ui.spacer(ui.px(em * 0.8))
	}
	if !open { answered, granted = true, false }   // Escape, a click outside: blocked
	if answered {
		ordered_remove(&ask_state.queue, 0)
		page.fs_ask_done(req, granted)
		app.frames_requested = max(app.frames_requested, 2)
	}
}

_ :: runtime.Allocator
