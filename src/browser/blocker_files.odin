package browser

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"
import "toolkit:ui"
import "wb:blocker"
import "wb:host"
import "wb:i18n"

// The system's Open and Save dialogs for the dashboard (export and import of the configuration and of the user's
// filters). The dialog runs on a worker thread; what it chose is read or written back on the interface thread.

@(private = "file")
Job :: struct {
	app:       ^App,
	save:      bool,
	suggested: string,
	path:      string,
	kind:      int,    // 0: the whole configuration, 1: the user's filters
}

file_dialog :: proc(app: ^App, save: bool, suggested: string, kind: int) {
	j := new(Job)
	j.app, j.save, j.kind = app, save, kind
	j.suggested = strings.clone(suggested)
	host.run_blocking(&app.blocking, dialog_work, dialog_done, j)
}

@(private = "file")
dialog_work :: proc(data: rawptr) {
	j := (^Job)(data)
	if win.CoInitializeEx(nil, .APARTMENTTHREADED) < 0 { return }
	defer win.CoUninitialize()
	dlg: ^win.IFileDialog
	if j.save {
		sd: ^win.IFileSaveDialog
		if win.CoCreateInstance(win.CLSID_FileSaveDialog, nil, win.CLSCTX_INPROC_SERVER, win.IID_IFileSaveDialog, cast(^rawptr)&sd) < 0 || sd == nil { return }
		dlg = cast(^win.IFileDialog)sd
		sd->SetFileName(win.utf8_to_wstring(j.suggested, context.temp_allocator))
	} else {
		od: ^win.IFileOpenDialog
		if win.CoCreateInstance(win.CLSID_FileOpenDialog, nil, win.CLSCTX_INPROC_SERVER, win.IID_IFileOpenDialog, cast(^rawptr)&od) < 0 || od == nil { return }
		dlg = cast(^win.IFileDialog)od
	}
	defer dlg->Release()
	types := [2]win.COMDLG_FILTERSPEC{{win.utf8_to_wstring(i18n.tr("Text files"), context.temp_allocator), win.L("*.txt")}, {win.utf8_to_wstring(i18n.tr("All files"), context.temp_allocator), win.L("*.*")}}
	dlg->SetFileTypes(2, &types[0])
	dlg->SetDefaultExtension(win.L("txt"))
	if dlg->Show(j.app.win.hwnd) < 0 { free_all(context.temp_allocator); return }
	item: ^win.IShellItem
	if dlg->GetResult(&item) < 0 || item == nil { free_all(context.temp_allocator); return }
	defer item->Release()
	wpath: win.LPWSTR
	if item->GetDisplayName(.FILESYSPATH, &wpath) >= 0 && wpath != nil {
		n := 0
		for (cast([^]u16)wpath)[n] != 0 { n += 1 }
		if s, err := win.utf16_to_utf8((cast([^]u16)wpath)[:n], context.allocator); err == nil { j.path = s }
		win.CoTaskMemFree(wpath)
	}
	free_all(context.temp_allocator)
}

@(private = "file")
dialog_done :: proc(data: rawptr) {
	j := (^Job)(data)
	defer { delete(j.suggested); delete(j.path); free(j) }
	app := j.app
	if j.path == "" { return }
	b := &bl.b
	name := filepath.base(j.path)
	switch {
	case j.save && j.kind == 0:
		text := blocker.conf_text(b, false)
		defer delete(text)
		if os.write_entire_file(j.path, text) == nil { ui.toast(.Good, i18n.tr("Configuration saved to %s"), name) } else { ui.toast(.Bad, i18n.tr("Could not write %s"), j.path) }
	case j.save:
		if os.write_entire_file(j.path, b.conf.my_filters) == nil { ui.toast(.Good, i18n.tr("Filters saved to %s"), name) } else { ui.toast(.Bad, i18n.tr("Could not write %s"), j.path) }
	case:
		data, err := os.read_entire_file(j.path, context.allocator)
		if err != nil { ui.toast(.Bad, i18n.tr("Could not read %s"), j.path); return }
		defer delete(data)
		if len(data) > 64 << 20 { ui.toast(.Bad, i18n.tr("%s is too large"), name); return }
		if j.kind == 0 {
			ok, bad := blocker.conf_parse(b, string(data), true)
			blocker.conf_save(b)
			blocker.rebuild(b)
			blocker.updater_round(b, false)
			dash.my_loaded = false
			delete(dash.status)
			dash.status = strings.clone(fmt.tprintf(i18n.tr("imported %s"), name))
			ui.toast(ok > 0 ? .Good : .Bad, i18n.tr("settings count, file, ignored lines", "%d settings imported from %s (%d lines ignored)"), ok, name, bad)
		} else {
			dash_add_filter(app, strings.trim_space(string(data)))
		}
	}
	app.frames_requested = max(app.frames_requested, 3)
}
