package browser

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "toolkit:platform"
import "toolkit:ui"
import "wb:blocker"
import "wb:host"
import "wb:i18n"

// A configuration or filter file chosen in the dashboard that is bigger than this is refused.
BLOCKER_IMPORT_MAX_BYTES :: 64 << 20

// The system's Open and Save dialogs for the dashboard (export and import of the configuration and of the user's
// filters). The dialog runs on a thread of its own (host.run_dialog); what it chose is read or written back on the
// interface thread.

@(private = "file")
Job :: struct {
	app:       ^App,
	save:      bool,
	suggested: string,
	path:      string,
	kind:      int,    // 0: the whole configuration, 1: the user's filters
	owner:     ^platform.Window,   // the window the dialog belongs to (read on the loop's thread, not on the dialog's)
	// the file's text, written or read on the dialog's thread after the choice (never on the loop's: a slow disk or share)
	text:      string,   // a save: made on the loop's thread when the dialog opens (owned)
	data:      []u8,     // an open: what was read (owned)
	failed:    bool,     // the write or the read failed
	too_large: bool,
}

file_dialog :: proc(app: ^App, save: bool, suggested: string, kind: int) {
	j := new(Job)
	j.app, j.save, j.kind, j.owner = app, save, kind, active_window(app).win
	j.suggested = strings.clone(suggested)
	if save {
		b := &app.bl.b
		j.text = kind == 0 ? blocker.conf_text(b, false) : strings.clone(b.conf.my_filters)
	}
	if !host.run_dialog(&app.dialogs, dialog_work, dialog_done, j, job_free) {
		ui.toast(.Bad, i18n.tr("The dialog could not open"))
		job_free(j)
	}
}

@(private = "file")
job_free :: proc(data: rawptr) {
	j := (^Job)(data)
	delete(j.suggested); delete(j.path); delete(j.text); delete(j.data); free(j)
}

@(private = "file")
dialog_work :: proc(data: rawptr) {
	j := (^Job)(data)
	patterns := [1]string{"*.txt"}
	filters := [1]platform.File_Filter{{name = i18n.tr("Text files"), patterns = patterns[:]}}
	d := platform.File_Dialog{
		owner            = j.owner,
		filters          = filters[:],
		all_files        = true,
		suggested_name   = j.suggested,
		default_ext      = "txt",
		overwrite_prompt = j.save,
		remember_id      = "blocker-files",
	}
	res := j.save ? platform.save_file_dialog(d, context.allocator) : platform.open_file_dialog(d, context.allocator)
	defer platform.dialog_result_destroy(&res, context.allocator)
	if res.status == .Chosen && len(res.paths) > 0 { j.path = strings.clone(res.paths[0]) }
	if j.path != "" {
		if j.save {
			j.failed = os.write_entire_file(j.path, j.text) != nil
		} else {
			data, err := os.read_entire_file(j.path, context.allocator)
			switch {
			case err != nil: j.failed = true
			case len(data) > BLOCKER_IMPORT_MAX_BYTES: j.too_large = true; delete(data)
			case: j.data = data
			}
		}
	}
	free_all(context.temp_allocator)
}

@(private = "file")
dialog_done :: proc(data: rawptr) {
	j := (^Job)(data)
	defer job_free(j)
	app := j.app
	if j.path == "" { return }
	b := &app.bl.b
	name := filepath.base(j.path)
	switch {
	case j.save && j.failed:
		ui.toast(.Bad, i18n.tr("Could not write %s"), j.path)
	case j.save:
		announce(app, .Good, j.kind == 0 ? fmt.tprintf(i18n.tr("Configuration saved to %s"), name) : fmt.tprintf(i18n.tr("Filters saved to %s"), name))
	case j.failed:
		ui.toast(.Bad, i18n.tr("Could not read %s"), j.path)
	case j.too_large:
		ui.toast(.Bad, i18n.tr("%s is too large"), name)
	case:
		data := j.data
		if j.kind == 0 {
			ok, bad := blocker.conf_parse(b, string(data), true)
			blocker.conf_save(b)
			blocker.rebuild(b)
			blocker.updater_round(b, false)
			app.dash.my_loaded = false
			delete(app.dash.status)
			app.dash.status = strings.clone(fmt.tprintf(i18n.tr("imported %s"), name))
			words := fmt.tprintf(i18n.tr("settings count, file, ignored lines", "%d settings imported from %s (%d lines ignored)"), ok, name, bad)
			if ok > 0 { announce(app, .Good, words) } else { ui.toast(.Bad, "%s", words) }
		} else {
			dash_add_filter(app, strings.trim_space(string(data)))
		}
	}
	request_frames(app, 3)
}
