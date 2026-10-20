package page

// FormData file entries for JavaScript (api/js_web.widl, partial module forms): a File object needs the bytes of a file
// entry, and fetch() / XMLHttpRequest need the multipart body with a boundary the engine chose (it also writes the
// Content-Type header). Files chosen in an <input type=file> are on disk until then: they are read here, on the UI
// thread, within forms.upload.max_file_bytes.

import "base:runtime"
import "core:strings"
import "wb:forms"

FormData_fileAt :: proc(c: ^Call, data: Api_FormData, index: i32) -> (u64, Api_Error) {
	e := entry_at(data, index)
	if e == nil || !e.is_file { return 0, fail(c, .Not_Found, "NotFoundError: no such file entry") }
	p := c.page
	if e.file.data != nil || e.file.path == "" {
		h := buffer_create(p, e.file.data, c.owner)
		if h == 0 && len(e.file.data) > 0 { return 0, fail(c, .Quota, "QuotaExceededError: page memory limit") }
		if h == 0 { h = buffer_create(p, nil, c.owner) }
		return h, .None
	}
	bytes, ok, msg := forms.read_file_default(e.file.path, p.settings.forms.upload_max_file, nil)
	if !ok { defer delete(msg); return 0, fail(c, .Not_Found, strings.clone(msg, context.temp_allocator)) }
	h := buffer_adopt_slice(p, bytes, c.owner)
	if h == 0 { return 0, fail(c, .Quota, "QuotaExceededError: page memory limit") }
	return h, .None
}

FormData_setBlob :: proc(c: ^Call, data: Api_FormData, name: string, blob: Api_Buffer, filename: string, mime: string) -> Api_Error {
	fd := data.data
	at := fd_remove_all(c.page, fd, name)
	e, ok := fd_blob_entry(c.page, fd, name, blob.data.bytes[:], filename, mime)
	if !ok { return fail(c, .Quota, "QuotaExceededError: page memory limit") }
	if at < 0 {
		if too_many(c.page, fd) { fd_entry_destroy(c.page, fd, &e); return fail(c, .Invalid_Argument, "too many entries (forms.max_entries)") }
		append(&fd.entries, e)
	} else {
		inject_at(&fd.entries, at, e)
	}
	return .None
}

FormData_encode :: proc(c: ^Call, data: Api_FormData, boundary: string) -> (u64, Api_Error) {
	p := c.page
	body, ok, msg := forms.multipart(data.data.entries[:], boundary, p.settings.forms)
	if !ok { defer delete(msg); return 0, fail(c, .Not_Found, strings.clone(msg, context.temp_allocator)) }
	h := buffer_adopt_slice(p, body, c.owner)
	if h == 0 { return 0, fail(c, .Quota, "QuotaExceededError: page memory limit") }
	return h, .None
}

// A buffer taking a slice allocated with context.allocator (no copy).
@(private)
buffer_adopt_slice :: proc(p: ^Page, bytes: []byte, owner: u32) -> u64 {
	raw := transmute(runtime.Raw_Slice)bytes
	dyn := transmute([dynamic]byte)runtime.Raw_Dynamic_Array{data = raw.data, len = raw.len, cap = raw.len, allocator = context.allocator}
	return buffer_adopt(p, dyn, owner)
}