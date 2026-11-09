package browser

// Bookmarks: pages the user keeps, in folders (bookmarks_ui.odin: about:bookmarks, the star of the address bar, Ctrl+D).
//   * One format for everything: the "Netscape bookmark file" that every browser imports and exports (Chrome, Firefox,
//     Edge, Safari). The profile keeps them in bookmarks.html in that format (with browser.profile.persist), Export
//     writes the same text, and Import reads any such file (read with the HTML parser, as loose as the files are:
//     <DT> and <p> never closed). An import merges: a folder of the same name at the same place is the same folder, an
//     address already in that folder is not added again.
//   * Order: the list holds every bookmark and folder; the children of a folder are those whose `parent` is its id, in
//     the order of the list (0: the top level).
//   * Written on a background thread to a temporary file moved over the old one, a second after a change, and when the
//     browser closes. A file that cannot be read as bookmarks is moved aside to bookmarks.html.bad (and never
//     overwritten if that name is taken).
//
// The procedures on a list are pure: bookmarks_test.odin.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:host"
import "wb:html"

BOOKMARKS_FILE :: "bookmarks.html"
BOOKMARKS_SAVE_DELAY_MS :: 1000
@(private = "file") BOOKMARKS_MAX_NODES :: 4_000_000   // (a file of 100 000 bookmarks is about 400 000 nodes)

Bookmark :: struct {
	id:       u64,
	parent:   u64,      // the folder's id (0: the top level)
	folder:   bool,
	title:    string,   // owned
	url:      string,   // owned; "" for a folder
	added_ms: i64,      // Unix time
}

Bookmarks :: struct {
	items:      [dynamic]Bookmark,
	next_id:    u64,
	serial:     u64,          // bumped at every change (views rebuild)
	path:       string,       // owned; "" = memory only
	dirty:      bool,
	saving:     bool,         // a write is running on the blocking pool
	again:      bool,         // ... and another change came meanwhile
	unreadable: bool,         // the file is not a bookmarks file: never overwritten
	timer:      base.Handle,
}

bookmark_free :: proc(b: ^Bookmark) {
	delete(b.title)
	delete(b.url)
}

bookmarks_list_destroy :: proc(items: ^[dynamic]Bookmark) {
	for &b in items { bookmark_free(&b) }
	delete(items^)
	items^ = nil
}

// The index of the bookmark `id` (-1: none).
bookmark_index :: proc(items: []Bookmark, id: u64) -> int {
	if id == 0 { return -1 }
	for b, i in items { if b.id == id { return i } }
	return -1
}

// The index of the first bookmark of `url` (-1: none).
bookmark_of_url :: proc(items: []Bookmark, url: string) -> int {
	if url == "" { return -1 }
	for b, i in items { if !b.folder && b.url == url { return i } }
	return -1
}

// Whether `id` is `ancestor` or inside it.
bookmark_within :: proc(items: []Bookmark, id, ancestor: u64) -> bool {
	for cur := id; cur != 0; {
		if cur == ancestor { return true }
		i := bookmark_index(items, cur)
		if i < 0 { return false }
		cur = items[i].parent
	}
	return false
}

// Adds a bookmark or a folder at the end of `parent`. Returns its id.
bookmark_add :: proc(items: ^[dynamic]Bookmark, next_id: ^u64, parent: u64, title, url: string, folder: bool, added_ms: i64) -> u64 {
	next_id^ += 1
	append(items, Bookmark{id = next_id^, parent = parent, folder = folder, title = strings.clone(title), url = strings.clone(url), added_ms = added_ms})
	return next_id^
}

// Removes the bookmark `id`, and everything in it when it is a folder. Returns how many went.
bookmark_remove :: proc(items: ^[dynamic]Bookmark, id: u64) -> int {
	gone := 0
	for i := len(items) - 1; i >= 0; i -= 1 {
		if !bookmark_within(items[:], items[i].id, id) { continue }
		bookmark_free(&items[i])
		ordered_remove(items, i)
		gone += 1
	}
	// (a folder's children before it in the list: removed in a second pass, their parent being gone)
	for removed := true; removed; {
		removed = false
		for i := len(items) - 1; i >= 0; i -= 1 {
			p := items[i].parent
			if p != 0 && bookmark_index(items[:], p) < 0 {
				bookmark_free(&items[i])
				ordered_remove(items, i)
				gone += 1
				removed = true
			}
		}
	}
	return gone
}

// Moves the bookmark `id` into `parent`, after its last child (never into itself). False: not moved.
bookmark_move_into :: proc(items: ^[dynamic]Bookmark, id, parent: u64) -> bool {
	i := bookmark_index(items[:], id)
	if i < 0 || (parent != 0 && bookmark_within(items[:], parent, id)) { return false }
	if parent != 0 { if pi := bookmark_index(items[:], parent); pi < 0 || !items[pi].folder { return false } }
	b := items[i]
	ordered_remove(items, i)
	b.parent = parent
	append(items, b)
	return true
}

// Moves the bookmark `id` before (`delta` -1) or after (+1) its neighbour in its folder. False: it is at that end.
bookmark_shift :: proc(items: ^[dynamic]Bookmark, id: u64, delta: int) -> bool {
	i := bookmark_index(items[:], id)
	if i < 0 { return false }
	j := i + delta
	for j >= 0 && j < len(items) && items[j].parent != items[i].parent { j += delta }
	if j < 0 || j >= len(items) { return false }
	items[i], items[j] = items[j], items[i]
	return true
}

////////////////////////////////
// The Netscape bookmark file

// The file of `items` (every browser reads it).
bookmarks_serialize :: proc(items: []Bookmark, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<!-- This is an automatically generated file.\n     It will be read and overwritten.\n     DO NOT EDIT! -->\n")
	strings.write_string(&sb, "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n<TITLE>Bookmarks</TITLE>\n<H1>Bookmarks</H1>\n")
	write_folder :: proc(sb: ^strings.Builder, items: []Bookmark, parent: u64, depth: int) {
		indent :: proc(sb: ^strings.Builder, n: int) { for _ in 0 ..< n { strings.write_string(sb, "    ") } }
		indent(sb, depth)
		strings.write_string(sb, "<DL><p>\n")
		for b in items {
			if b.parent != parent { continue }
			indent(sb, depth + 1)
			if b.folder {
				fmt.sbprintf(sb, "<DT><H3 ADD_DATE=\"%d\">", b.added_ms / 1000)
				base.write_escaped(sb, b.title)
				strings.write_string(sb, "</H3>\n")
				write_folder(sb, items, b.id, depth + 1)
			} else {
				strings.write_string(sb, "<DT><A HREF=\"")
				base.write_escaped(sb, b.url, {.Quote})
				fmt.sbprintf(sb, "\" ADD_DATE=\"%d\">", b.added_ms / 1000)
				base.write_escaped(sb, b.title)
				strings.write_string(sb, "</A>\n")
			}
		}
		indent(sb, depth)
		strings.write_string(sb, "</DL><p>\n")
	}
	write_folder(&sb, items, 0, 0)
	return strings.to_string(sb)
}

// Reads a bookmark file into `items`, under `under` (0: the top level), merged with what is there: a folder of the
// same name at the same place is the same folder, an address already in its folder is not added again. Addresses
// that are not absolute, or are javascript:, are left out. `now_ms`: the date of those that have none.
// Returns how many bookmarks were added; ok is false when the text holds no list of bookmarks (<DL>).
bookmarks_import :: proc(items: ^[dynamic]Bookmark, next_id: ^u64, text: string, under: u64, now_ms: i64) -> (added: int, ok: bool) {
	d := dom.document_create()
	defer dom.document_destroy(d)
	html.parse_into(d, d.root, transmute([]byte)text, BOOKMARKS_MAX_NODES)
	top := find_dl(d, d.root)
	if top == base.NIL_HANDLE { return 0, false }
	Walk :: struct { d: ^dom.Document, items: ^[dynamic]Bookmark, next_id: ^u64, now_ms: i64, added: int }
	w := Walk{d, items, next_id, now_ms, 0}
	// `pending`: the folder an <H3> just named, which the next <DL> fills (they are siblings in a <DT>)
	walk :: proc(w: ^Walk, n: base.Handle, folder: u64) {
		pending: u64 = 0
		for c := dom.get(w.d, n).first_child; c != base.NIL_HANDLE; c = dom.get(w.d, c).next {
			node := dom.get(w.d, c)
			switch node.name {
			case "a":
				href, _ := dom.get_attribute(w.d, c, "href")
				href = strings.trim_space(href)
				if !bookmark_address_ok(href) { continue }
				dup := false
				for b in w.items { if b.parent == folder && !b.folder && b.url == href { dup = true; break } }
				if dup { continue }
				title := strings.trim_space(dom.text_content(w.d, c))
				bookmark_add(w.items, w.next_id, folder, title != "" ? title : href, href, false, date_of(w.d, c, w.now_ms))
				w.added += 1
			case "h3":
				title := strings.trim_space(dom.text_content(w.d, c))
				pending = 0
				for b in w.items { if b.parent == folder && b.folder && b.title == title { pending = b.id; break } }
				if pending == 0 { pending = bookmark_add(w.items, w.next_id, folder, title, "", true, date_of(w.d, c, w.now_ms)) }
			case "dl":
				walk(w, c, pending != 0 ? pending : folder)
				pending = 0
			case:
				if node.kind == .Element { walk(w, c, folder) }
			}
		}
	}
	walk(&w, top, under)
	return w.added, true

	find_dl :: proc(d: ^dom.Document, n: base.Handle) -> base.Handle {
		for c := dom.get(d, n).first_child; c != base.NIL_HANDLE; c = dom.get(d, c).next {
			if dom.get(d, c).name == "dl" { return c }
			if found := find_dl(d, c); found != base.NIL_HANDLE { return found }
		}
		return base.NIL_HANDLE
	}
	date_of :: proc(d: ^dom.Document, h: base.Handle, now_ms: i64) -> i64 {
		v, _ := dom.get_attribute(d, h, "add_date")
		secs, ok := strconv.parse_i64(strings.trim_space(v))
		return ok && secs > 0 ? secs * 1000 : now_ms
	}
}

// An address a bookmark can hold: absolute, and not a script.
bookmark_address_ok :: proc(a: string) -> bool {
	colon := strings.index_byte(a, ':')
	if colon <= 0 { return false }
	scheme := strings.to_lower(a[:colon], context.temp_allocator)
	return scheme != "javascript" && scheme != "data"
}

////////////////////////////////
// In the profile

bookmarks_init :: proc(app: ^App) {
	if !app.cfg.persist_profile { return }
	app.bms.path = strings.concatenate({app.profile_dir, "/", BOOKMARKS_FILE})
	data, err := os.read_entire_file(app.bms.path, context.temp_allocator)
	if err != nil { return }
	if _, ok := bookmarks_import(&app.bms.items, &app.bms.next_id, string(data), 0, now_ms()); !ok {
		bookmarks_list_destroy(&app.bms.items)
		bad := strings.concatenate({app.bms.path, ".bad"}, context.temp_allocator)
		if os.exists(bad) || os.rename(app.bms.path, bad) != nil { app.bms.unreadable = true }
		return
	}
	app.bms.serial += 1
}

bookmarks_changed :: proc(app: ^App) {
	app.bms.serial += 1
	app.bms.dirty = true
	request_frames(app, 2)
	if app.bms.path == "" || app.bms.timer != base.NIL_HANDLE { return }
	if app.bms.saving { app.bms.again = true; return }
	app.bms.timer = host.set_timer(&app.loop, BOOKMARKS_SAVE_DELAY_MS, 0, proc(data: rawptr) {
		app := (^App)(data)
		app.bms.timer = base.NIL_HANDLE
		host.quiet_note(&app.loop)   // (the disk, not the screen)
		bookmarks_save(app)
	}, app)
}

@(private = "file")
Save_Job :: struct { app: ^App, path, text: string, ok: bool }

// Writes the bookmarks on the blocking pool (one write at a time).
@(private = "file")
bookmarks_save :: proc(app: ^App) {
	if app.bms.path == "" || !app.bms.dirty || app.bms.unreadable { return }
	if app.bms.saving { app.bms.again = true; return }
	app.bms.dirty = false
	app.bms.saving = true
	job := new(Save_Job)
	job.app = app
	job.path = strings.clone(app.bms.path)
	job.text = strings.clone(bookmarks_serialize(app.bms.items[:]))
	host.run_blocking(&app.blocking, proc(data: rawptr) {
		j := (^Save_Job)(data)
		j.ok = base.file_write_atomic(j.path, transmute([]byte)j.text, flush = true)
		free_all(context.temp_allocator)
	}, proc(data: rawptr) {
		j := (^Save_Job)(data)
		app := j.app
		host.quiet_note(&app.loop)
		app.bms.saving = false
		if !j.ok { app.bms.dirty = true }
		delete(j.path); delete(j.text); free(j)
		if app.bms.again || app.bms.dirty { app.bms.again = false; bookmarks_changed(app) }
	}, job)
}

// At exit: what is not written yet is written now, on this thread.
bookmarks_shutdown :: proc(app: ^App) {
	if app.bms.saving { host.blocking_settle(&app.blocking) }
	if app.bms.timer != base.NIL_HANDLE { host.clear_timer(&app.loop, app.bms.timer) }
	if app.bms.path != "" && app.bms.dirty && !app.bms.unreadable {
		_ = base.file_write_atomic(app.bms.path, transmute([]byte)bookmarks_serialize(app.bms.items[:]), flush = true)
	}
	bookmarks_list_destroy(&app.bms.items)
	delete(app.bms.path)
	app.bms = {}
}

// The bookmark of the page `t` shows, added at the top level, or the one it has (its id).
bookmark_page :: proc(app: ^App, t: ^Tab) -> (id: u64, added: bool) {
	if t == nil || !bookmark_address_ok(t.url) { return 0, false }
	if i := bookmark_of_url(app.bms.items[:], t.url); i >= 0 { return app.bms.items[i].id, false }
	title := t.title != "" ? t.title : t.url
	id = bookmark_add(&app.bms.items, &app.bms.next_id, 0, title, t.url, false, now_ms())
	bookmarks_changed(app)
	return id, true
}
