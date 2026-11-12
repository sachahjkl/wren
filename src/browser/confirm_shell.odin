package browser

// The question before an act that is not taken back (gui_toolkit ui.confirm): a bookmark folder removed with what it
// holds, a downloaded file deleted from the disk, the browsing history deleted. One question at a time: the act is named
// here (Confirm_Kind and its target), asked from a menu or a key, and done when the user confirms it in a later frame.

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "toolkit:ui"
import "wb:i18n"

Confirm_Kind :: enum u8 { None, Bookmark_Folder, Download_File, History_Range }

Pending_Confirm :: struct {
	open:          bool,
	kind:          Confirm_Kind,
	id:            u64,           // Bookmark_Folder: the folder; Download_File: the download
	from_ms, to_ms: i64,          // History_Range
	title, note, act: string,     // owned
	lines:         [dynamic]string,   // owned: what it acts on
}

@(private = "file")
confirm_clear :: proc(c: ^Pending_Confirm) {
	delete(c.title); delete(c.note); delete(c.act)
	for l in c.lines { delete(l) }
	delete(c.lines)
	c^ = {}
}

confirm_destroy :: proc(app: ^App) { confirm_clear(&app.confirm) }

@(private = "file")
confirm_ask :: proc(app: ^App, kind: Confirm_Kind, title, note, act: string) -> ^Pending_Confirm {
	confirm_clear(&app.confirm)
	c := &app.confirm
	c.open, c.kind = true, kind
	c.title, c.note, c.act = strings.clone(title), strings.clone(note), strings.clone(act)
	if ui.building() { ui.ctx_menu_close() }   // (the menu that asked)
	request_frames(app, 2)
	return c
}

// A bookmark removed: a folder that holds anything is asked about first, the rest goes at once.
bookmark_remove_asked :: proc(app: ^App, id: u64) {
	i := bookmark_index(app.bms.items[:], id)
	if i < 0 { return }
	b := app.bms.items[i]
	n := 0
	for x in app.bms.items { if x.id != id && bookmark_within(app.bms.items[:], x.id, id) { n += 1 } }
	if !b.folder || n == 0 {
		_ = bookmark_remove(&app.bms.items, id)
		bookmarks_changed(app)
		return
	}
	c := confirm_ask(app, .Bookmark_Folder, fmt.tprintf(i18n.tr("Remove the folder %q?"), b.title),
		fmt.tprintf(n == 1 ? i18n.tr("It holds %d item, which goes with it.") : i18n.tr("It holds %d items, which go with it."), n), i18n.tr("Remove"))
	c.id = id
	for x in app.bms.items {
		if x.parent == id { append(&c.lines, strings.clone(x.title != "" ? x.title : x.url)) }
	}
}

// A downloaded file deleted from the disk (not to the trash).
download_delete_asked :: proc(app: ^App, d: ^Download) {
	if d == nil || d.state != .Done || d.path == "" { return }
	c := confirm_ask(app, .Download_File, fmt.tprintf(i18n.tr("Delete %s?"), filepath.base(d.path)),
		i18n.tr("The file is deleted from the disk, not put in the trash."), i18n.tr("Delete"))
	c.id = d.id
	append(&c.lines, strings.clone(d.path))
}

// The visits between two times deleted (`what`: the range's words, "the last hour").
history_delete_asked :: proc(app: ^App, from_ms, to_ms: i64, what: string) {
	n := 0
	for v in app.ghist.visits { if v.at_ms >= from_ms && v.at_ms <= to_ms { n += 1 } }
	if n == 0 { ui.toast(.Info, "No visit to delete"); return }
	c := confirm_ask(app, .History_Range, fmt.tprintf(i18n.tr("Delete the history of %s?"), what),
		fmt.tprintf(n == 1 ? i18n.tr("%d visit is deleted, and the closed tabs of that time.") : i18n.tr("%d visits are deleted, and the closed tabs of that time."), n), i18n.tr("Delete"))
	c.from_ms, c.to_ms = from_ms, to_ms
}

// Each frame: the question while it is open, the act when it is confirmed.
confirm_build :: proc(app: ^App) {
	c := &app.confirm
	if !c.open && c.kind == .None { return }
	answer := ui.confirm("wren_confirm", &c.open, {title = c.title, note = c.note, lines = c.lines[:], act = c.act})
	switch answer {
	case .None:
		if c.open { return }
	case .Cancelled:
	case .Confirmed:
		switch c.kind {
		case .None:
		case .Bookmark_Folder:
			_ = bookmark_remove(&app.bms.items, c.id)
			bookmarks_changed(app)
		case .Download_File:
			for d in app.dls.list { if d.id == c.id { download_delete_file(app, d); break } }
		case .History_Range:
			global_history_remove_range(app, c.from_ms, c.to_ms)
		}
	}
	confirm_clear(c)
	request_frames(app, 2)
}
