package page

// HTML drag and drop (HTML §6.11): the drag data store behind a DataTransfer (api/js_dnd.widl, runtime/web_dnd.c), the
// files a page is given as browser objects read on demand, HTMLInputElement.files, and the drag-and-drop processing
// model the shell drives (src/browser/dnd_shell.odin): a drag that starts in the page (a draggable element, a link, an
// image, a text selection) or that comes from another application, its dragenter / dragover / dragleave / drop events
// at the elements under the pointer, the operation the page chose, and dragend at the source.
//
// The store's mode follows the event being dispatched: read/write in dragstart, read-only in drop, protected
// otherwise (the types and the kinds are visible, the data and the files are not), as the standard says, so a page
// cannot read what is dragged over it before the user drops it there.
//
// What the shell does with the result (open dropped files, follow a dropped link) depends on one rule: a page that
// cancelled dragover (a drop zone) or drop decides; otherwise the browser's default applies (Drop_Result).

import "core:os"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:forms"

////////////////////////////////
// Files given to the page

// A file the page may read: one the user dropped or chose (`path`), or one a page made (`data`). Read on demand, by
// slices (File.slice().arrayBuffer() reads only that part).
Local_File :: struct {
	file: forms.File,
}

@(private)
local_file_vt := Object_VTable{
	name = "File",
	destroy = proc(p: ^Page, data: rawptr) {
		lf := (^Local_File)(data)
		forms.file_destroy(&lf.file)
		free(lf)
	},
}

lookup_LocalFile :: proc(c: ^Call, h: u64) -> ^Local_File { return (^Local_File)(object_data(c.page, h, &local_file_vt)) }

@(private)
file_clone :: proc(f: forms.File) -> forms.File {
	out := forms.File{path = strings.clone(f.path), name = strings.clone(f.name), mime = strings.clone(f.mime), size = f.size, modified_ms = f.modified_ms}
	if f.data != nil { out.data = make([]byte, len(f.data)); copy(out.data, f.data) }
	return out
}

// A new browser object for a copy of `f`, owned by `owner` (the realm releases it with its File).
@(private)
local_file_object :: proc(p: ^Page, f: forms.File, owner: u32) -> u64 {
	lf := new(Local_File)
	lf.file = file_clone(f)
	return object_create(p, &local_file_vt, lf, owner)
}

// A file of this computer as the page sees it: its name, its MIME type (the browser's table), its size and time.
// ok = false when it cannot be read (gone, a folder).
local_file_from_path :: proc(path: string, allocator := context.allocator) -> (f: forms.File, ok: bool) {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil || info.type == .Directory { return }
	slash := strings.last_index_any(path, "\\/")
	f = forms.File{
		path = strings.clone(path, allocator), name = strings.clone(path[slash + 1:], allocator),
		mime = strings.clone(mime_type_for_name(path), allocator), size = info.size,
		modified_ms = f64(time.to_unix_nanoseconds(info.modification_time)) / 1e6,
	}
	return f, true
}

// The MIME type a page sees for a file name (File.type), "" when unknown.
@(private)
mime_type_for_name :: proc(name: string) -> string {
	dot := strings.last_index_byte(name, '.')
	if dot < 0 || dot < strings.last_index_any(name, "\\/") { return "" }
	switch strings.to_lower(name[dot + 1:], context.temp_allocator) {
	case "txt": return "text/plain"
	case "html", "htm": return "text/html"
	case "css": return "text/css"
	case "js", "mjs": return "text/javascript"
	case "json": return "application/json"
	case "xml": return "application/xml"
	case "csv": return "text/csv"
	case "md": return "text/markdown"
	case "pdf": return "application/pdf"
	case "zip": return "application/zip"
	case "png": return "image/png"
	case "jpg", "jpeg": return "image/jpeg"
	case "gif": return "image/gif"
	case "webp": return "image/webp"
	case "avif": return "image/avif"
	case "svg": return "image/svg+xml"
	case "ico": return "image/x-icon"
	case "bmp": return "image/bmp"
	case "mp3": return "audio/mpeg"
	case "wav": return "audio/wav"
	case "ogg", "oga": return "audio/ogg"
	case "flac": return "audio/flac"
	case "m4a": return "audio/mp4"
	case "mp4", "m4v": return "video/mp4"
	case "webm": return "video/webm"
	case "mov": return "video/quicktime"
	case "wasm": return "application/wasm"
	case "woff2": return "font/woff2"
	case "woff": return "font/woff"
	case "ttf": return "font/ttf"
	}
	return ""
}

LocalFile_name :: proc(c: ^Call, file: Api_LocalFile) -> string { return file.data.file.name }
LocalFile_type :: proc(c: ^Call, file: Api_LocalFile) -> string { return file.data.file.mime }
LocalFile_info :: proc(c: ^Call, file: Api_LocalFile) -> Api_LocalFileInfo {
	return {size = file.data.file.size, last_modified = file.data.file.modified_ms}
}

// Reads from the file as it was given: NotReadableError (Not_Found) when it went away or changed size (File API).
LocalFile_read :: proc(c: ^Call, file: Api_LocalFile, offset: i64, into: []u8) -> (i64, Api_Error) {
	f := &file.data.file
	if offset < 0 || offset > f.size { return 0, fail(c, .Invalid_Argument, "offset past the end of the file") }
	want := min(i64(len(into)), f.size - offset)
	if want <= 0 { return 0, .None }
	if f.data != nil {
		copy(into[:want], f.data[offset:offset + want])
		return want, .None
	}
	info, serr := os.stat(f.path, context.temp_allocator)
	if serr != nil || info.size != f.size { return 0, fail(c, .Not_Found, "NotReadableError: the file changed or was removed since it was given to the page") }
	h, oerr := os.open(f.path)
	if oerr != nil { return 0, fail(c, .Not_Found, "NotReadableError: the file cannot be opened") }
	defer os.close(h)
	got: i64
	for got < want {
		n, rerr := os.read_at(h, into[got:want], offset + got)
		if n <= 0 || rerr != nil { break }
		got += i64(n)
	}
	if got < want { return got, fail(c, .Not_Found, "NotReadableError: the file could not be read") }
	return got, .None
}

////////////////////////////////
// The drag data store

Drag_Mode :: enum u8 { Protected, Read_Write, Read_Only }
Drag_Op :: enum u8 { None, Copy, Link, Move }
Drag_Ops :: bit_set[Drag_Op; u8]

Drag_Item :: struct {
	is_file: bool,
	is_dir:  bool,         // a folder the user dropped: a File of size 0 (as other browsers), webkitGetAsEntry lists it
	type:    string,       // owned; a string item's type is lower case
	data:    string,       // owned (string items)
	file:    forms.File,   // owned (file items)
}

Drag_Store :: struct {
	items:          [dynamic]Drag_Item,
	mode:           Drag_Mode,
	drop_effect:    Drag_Op,
	effect_allowed: string,         // one of EFFECT_ALLOWED (not owned)
	image:          base.Handle,    // setDragImage
	image_offset:   [2]i32,
}

EFFECT_ALLOWED := [?]string{"none", "copy", "copyLink", "copyMove", "link", "linkMove", "move", "all", "uninitialized"}
@(private) DROP_EFFECT_NAMES := [Drag_Op]string{.None = "none", .Copy = "copy", .Link = "link", .Move = "move"}

@(private)
drag_store_vt := Object_VTable{
	name = "DataTransfer",
	destroy = proc(p: ^Page, data: rawptr) {
		st := (^Drag_Store)(data)
		store_clear(st)
		delete(st.items)
		free(st)
	},
}

lookup_DataTransfer :: proc(c: ^Call, h: u64) -> ^Drag_Store { return store_get(c.page, h) }

@(private)
store_get :: proc(p: ^Page, h: u64) -> ^Drag_Store { return (^Drag_Store)(object_data(p, h, &drag_store_vt)) }

@(private)
store_new :: proc(p: ^Page, owner: u32, mode: Drag_Mode) -> u64 {
	st := new(Drag_Store)
	st.mode = mode
	st.effect_allowed = "uninitialized"
	return object_create(p, &drag_store_vt, st, owner)
}

@(private)
item_destroy :: proc(it: ^Drag_Item) {
	delete(it.type)
	delete(it.data)
	forms.file_destroy(&it.file)
}

@(private)
store_clear :: proc(st: ^Drag_Store) {
	for &it in st.items { item_destroy(&it) }
	clear(&st.items)
}

// HTML: "text" means text/plain and "url" text/uri-list; other formats are lower cased.
@(private)
normal_format :: proc(format: string) -> string {
	f := strings.to_lower(format, context.temp_allocator)
	switch f {
	case "text": return "text/plain"
	case "url": return "text/uri-list"
	}
	return f
}

@(private)
store_set_string :: proc(st: ^Drag_Store, format, data: string) {
	f := normal_format(format)
	for &it in st.items {
		if !it.is_file && it.type == f {
			delete(it.data)
			it.data = strings.clone(data)
			return
		}
	}
	append(&st.items, Drag_Item{type = strings.clone(f), data = strings.clone(data)})
}

@(private)
store_get_string :: proc(st: ^Drag_Store, format: string) -> (string, bool) {
	f := normal_format(format)
	want_url := strings.equal_fold(format, "url")
	for it in st.items {
		if it.is_file || it.type != f { continue }
		if want_url { return uri_list_first(it.data), true }
		return it.data, true
	}
	return "", false
}

@(private)
store_add_file :: proc(st: ^Drag_Store, f: forms.File) {
	append(&st.items, Drag_Item{is_file = true, type = strings.clone(f.mime), file = file_clone(f)})
}

// A dropped folder: a file item with no type and no bytes, its path kept for the Entries API.
@(private)
store_add_dir :: proc(st: ^Drag_Store, path: string) {
	slash := strings.last_index_any(strings.trim_right(path, "\\/"), "\\/")
	name := strings.trim_right(path, "\\/")[slash + 1:]
	f := forms.File{path = strings.clone(path), name = strings.clone(name), mime = strings.clone("")}
	append(&st.items, Drag_Item{is_file = true, is_dir = true, type = strings.clone(""), file = f})
}

// The first URL of a text/uri-list ("" when none).
uri_list_first :: proc(list: string) -> string {
	rest := list
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' { continue }
		return l
	}
	return ""
}

@(private)
file_count :: proc(st: ^Drag_Store) -> int {
	n := 0
	for it in st.items { if it.is_file { n += 1 } }
	return n
}

@(private)
nth_file :: proc(st: ^Drag_Store, index: i32) -> ^forms.File {
	k: i32 = 0
	for &it in st.items {
		if !it.is_file { continue }
		if k == index { return &it.file }
		k += 1
	}
	return nil
}

DataTransfer_create :: proc(c: ^Call) -> u64 { return store_new(c.page, c.owner, .Read_Write) }

DataTransfer_get_dropEffect :: proc(c: ^Call, dt: Api_DataTransfer) -> string { return DROP_EFFECT_NAMES[dt.data.drop_effect] }

DataTransfer_set_dropEffect :: proc(c: ^Call, dt: Api_DataTransfer, value: string) {
	for name, op in DROP_EFFECT_NAMES { if name == value { dt.data.drop_effect = op; return } }
}

DataTransfer_get_effectAllowed :: proc(c: ^Call, dt: Api_DataTransfer) -> string { return dt.data.effect_allowed }

DataTransfer_set_effectAllowed :: proc(c: ^Call, dt: Api_DataTransfer, value: string) {
	if dt.data.mode != .Read_Write { return }
	for name in EFFECT_ALLOWED { if name == value { dt.data.effect_allowed = name; return } }
}

DataTransfer_getData :: proc(c: ^Call, dt: Api_DataTransfer, format: string) -> string {
	if dt.data.mode == .Protected { return "" }
	s, _ := store_get_string(dt.data, format)
	return s
}

DataTransfer_setData :: proc(c: ^Call, dt: Api_DataTransfer, format, data: string) {
	if dt.data.mode != .Read_Write { return }
	store_set_string(dt.data, format, data)
}

DataTransfer_clearData :: proc(c: ^Call, dt: Api_DataTransfer, format: Maybe(string)) {
	st := dt.data
	if st.mode != .Read_Write { return }
	f, has := format.?
	nf := has ? normal_format(f) : ""
	k := 0
	for &it in st.items {
		if !it.is_file && (!has || it.type == nf) { item_destroy(&it); continue }
		st.items[k] = it
		k += 1
	}
	resize(&st.items, k)
}

DataTransfer_setDragImage :: proc(c: ^Call, dt: Api_DataTransfer, image: Api_Element, x, y: i32) {
	if dt.data.mode != .Read_Write { return }
	dt.data.image = H(image.handle)
	dt.data.image_offset = {x, y}
}

DataTransfer_typeList :: proc(c: ^Call, dt: Api_DataTransfer) -> string {
	sb := strings.builder_make(context.temp_allocator)
	files := false
	for it in dt.data.items {
		if it.is_file { files = true; continue }
		if strings.builder_len(sb) > 0 { strings.write_byte(&sb, '\n') }
		strings.write_string(&sb, it.type)
	}
	if files {
		if strings.builder_len(sb) > 0 { strings.write_byte(&sb, '\n') }
		strings.write_string(&sb, "Files")
	}
	return strings.to_string(sb)
}

DataTransfer_itemCount :: proc(c: ^Call, dt: Api_DataTransfer) -> i32 { return i32(len(dt.data.items)) }

@(private)
item_at :: proc(c: ^Call, dt: Api_DataTransfer, index: i32) -> (^Drag_Item, Api_Error) {
	if index < 0 || int(index) >= len(dt.data.items) { return nil, fail(c, .Invalid_Argument, "no item at this index") }
	return &dt.data.items[index], .None
}

DataTransfer_itemKind :: proc(c: ^Call, dt: Api_DataTransfer, index: i32) -> (Api_DragItemKind, Api_Error) {
	it, err := item_at(c, dt, index)
	if err != .None { return .String, err }
	return it.is_file ? .File : .String, .None
}

DataTransfer_itemType :: proc(c: ^Call, dt: Api_DataTransfer, index: i32) -> (string, Api_Error) {
	it, err := item_at(c, dt, index)
	if err != .None { return "", err }
	return it.type, .None
}

DataTransfer_itemString :: proc(c: ^Call, dt: Api_DataTransfer, index: i32) -> (string, Api_Error) {
	it, err := item_at(c, dt, index)
	if err != .None { return "", err }
	if dt.data.mode == .Protected || it.is_file { return "", fail(c, .Invalid_State, "the data is not available now") }
	return it.data, .None
}

DataTransfer_itemFile :: proc(c: ^Call, dt: Api_DataTransfer, index: i32) -> (u64, Api_Error) {
	it, err := item_at(c, dt, index)
	if err != .None { return 0, err }
	if dt.data.mode == .Protected || !it.is_file { return 0, .None }
	return local_file_object(c.page, it.file, c.owner), .None
}

// getAsFileSystemHandle(): a handle of what was dropped, read access granted (fs_api.odin); a folder is its root.
DataTransfer_itemFsHandle :: proc(c: ^Call, dt: Api_DataTransfer, index: i32) -> (string, Api_Error) {
	it, err := item_at(c, dt, index)
	if err != .None { return "", err }
	if dt.data.mode == .Protected || !it.is_file || it.file.path == "" { return "", .None }
	info, e := os.stat(it.file.path, context.temp_allocator)
	if e != nil { return "", .None }
	b := strings.builder_make(context.temp_allocator)
	fs_given_handle(c.page, it.file.path, info.type == .Directory, false, &b)
	return strings.trim_right(strings.to_string(b), "\n"), .None
}

DataTransfer_addString :: proc(c: ^Call, dt: Api_DataTransfer, data, type: string) -> Api_Error {
	st := dt.data
	if st.mode != .Read_Write { return fail(c, .Invalid_State, "the DataTransfer is not in read/write mode") }
	t := strings.to_lower(type, context.temp_allocator)
	for it in st.items { if !it.is_file && it.type == t { return fail(c, .Not_Supported, "an item of this type exists already") } }
	append(&st.items, Drag_Item{type = strings.clone(t), data = strings.clone(data)})
	return .None
}

DataTransfer_addFile :: proc(c: ^Call, dt: Api_DataTransfer, file: Api_LocalFile) -> Api_Error {
	if dt.data.mode != .Read_Write { return fail(c, .Invalid_State, "the DataTransfer is not in read/write mode") }
	store_add_file(dt.data, file.data.file)
	return .None
}

DataTransfer_addBytes :: proc(c: ^Call, dt: Api_DataTransfer, name, type: string, data: []u8, last_modified: f64) -> Api_Error {
	if dt.data.mode != .Read_Write { return fail(c, .Invalid_State, "the DataTransfer is not in read/write mode") }
	p := c.page
	if p.held + len(data) > p.settings.max_fetch_bytes { return fail(c, .Quota, "QuotaExceededError: the page's memory limit") }
	f := forms.File{name = name, mime = type, size = i64(len(data)), data = data, modified_ms = last_modified}
	store_add_file(dt.data, f)   // (copies)
	return .None
}

DataTransfer_removeItem :: proc(c: ^Call, dt: Api_DataTransfer, index: i32) -> Api_Error {
	st := dt.data
	if st.mode != .Read_Write { return fail(c, .Invalid_State, "the DataTransfer is not in read/write mode") }
	if index < 0 || int(index) >= len(st.items) { return .None }
	item_destroy(&st.items[index])
	ordered_remove(&st.items, int(index))
	return .None
}

DataTransfer_clearItems :: proc(c: ^Call, dt: Api_DataTransfer) -> Api_Error {
	if dt.data.mode != .Read_Write { return fail(c, .Invalid_State, "the DataTransfer is not in read/write mode") }
	store_clear(dt.data)
	return .None
}

DataTransfer_fileCount :: proc(c: ^Call, dt: Api_DataTransfer) -> i32 {
	if dt.data.mode == .Protected { return 0 }
	return i32(file_count(dt.data))
}

DataTransfer_file :: proc(c: ^Call, dt: Api_DataTransfer, index: i32) -> (u64, Api_Error) {
	if dt.data.mode == .Protected { return 0, fail(c, .Invalid_Argument, "no file at this index") }
	f := nth_file(dt.data, index)
	if f == nil { return 0, fail(c, .Invalid_Argument, "no file at this index") }
	return local_file_object(c.page, f^, c.owner), .None
}

DataTransfer_mode :: proc(c: ^Call, dt: Api_DataTransfer) -> i32 { return i32(dt.data.mode) }

DragEvent_dataTransfer :: proc(c: ^Call, event: Api_Event) -> u64 {
	e := event.data
	if store_get(c.page, e.object) == nil { return 0 }
	switch e.type {
	case "dragstart", "drag", "dragenter", "dragleave", "dragover", "drop", "dragend": return e.object
	}
	return 0
}

////////////////////////////////
// HTMLInputElement.files

@(private)
file_input :: proc(c: ^Call, h: u64) -> (^forms.Forms, bool) {
	p := c.page
	if p.worker != nil || p.formctl == nil { return nil, false }
	f := page_forms(p)
	if forms.input_type(f, H(h)) != .File || forms.kind(f, H(h)) != .Input { return nil, false }
	return f, true
}

InputFiles_count :: proc(c: ^Call, input: Api_Element) -> i32 {
	f, ok := file_input(c, input.handle)
	if !ok { return 0 }
	return i32(len(forms.files(f, H(input.handle))))
}

InputFiles_item :: proc(c: ^Call, input: Api_Element, index: i32) -> (u64, Api_Error) {
	f, ok := file_input(c, input.handle)
	if !ok { return 0, fail(c, .Invalid_Argument, "not a file input") }
	list := forms.files(f, H(input.handle))
	if index < 0 || int(index) >= len(list) { return 0, fail(c, .Invalid_Argument, "no file at this index") }
	return local_file_object(c.page, list[index], c.owner), .None
}

// input.files = dt.files (a page sets a file input's selection, as test libraries and uploaders do): no input or change
// event, as when a script sets the attribute.
InputFiles_assign :: proc(c: ^Call, input: Api_Element, from: Api_DataTransfer) -> Api_Error {
	f, ok := file_input(c, input.handle)
	if !ok { return fail(c, .Invalid_State, "not a file input") }
	list := make([dynamic]forms.File, 0, file_count(from.data))
	for it in from.data.items { if it.is_file { append(&list, file_clone(it.file)) } }
	forms.set_files_quiet(f, H(input.handle), list[:])
	delete(list)
	return .None
}
