package page

// FormData (XHR §5): an entry list owned by the browser, referenced by an object handle. Built from a form (which fires
// `formdata`), edited by the guest, sent with Fetch_startFormData. File entries keep their path and are read when the
// body is encoded, on a worker thread.

import "core:strings"
import "wb:base"
import "wb:fetch"
import "wb:dom"
import "wb:forms"
import "wb:host"
import "wb:url"

Form_Data :: struct {
	entries: [dynamic]forms.Entry,
	held:    int,   // bytes of its blob entries, counted in p.held like the buffers they were copied from
}

formdata_vt := Object_VTable{
	name = "FormData",
	destroy = proc(p: ^Page, data: rawptr) {
		fd := (^Form_Data)(data)
		p.held -= fd.held
		forms.entries_destroy(&fd.entries)
		free(fd)
	},
}

formdata_get :: proc(p: ^Page, h: u64) -> ^Form_Data { return (^Form_Data)(object_data(p, h, &formdata_vt)) }

formdata_create :: proc(p: ^Page, owner: u32) -> (u64, ^Form_Data) {
	fd := new(Form_Data)
	return object_create(p, &formdata_vt, fd, owner), fd
}

// The `formdata` event of the entry list construction: listeners see (and may change) the list through a FormData.
@(private)
formdata_event :: proc(user: rawptr, form: base.Handle, entries: ^[dynamic]forms.Entry) {
	p := (^Page)(user)
	if p.closed { return }
	h, fd := formdata_create(p, 0)
	fd.entries, entries^ = entries^, nil
	dispatch_event(p, form, dom.Event{type = "formdata", bubbles = true, object = h})
	if back := formdata_get(p, h); back != nil {
		entries^, back.entries = back.entries, nil
		p.held -= back.held   // the bytes leave the page's objects with the submission
		back.held = 0
	}
	object_release(p, h)
}

@(private)
too_many :: proc(p: ^Page, fd: ^Form_Data) -> bool { return len(fd.entries) >= p.settings.forms.max_entries }

// A blob entry of `bytes` (copied), its bytes counted against page.max_fetch_bytes; false past it.
@(private)
fd_blob_entry :: proc(p: ^Page, fd: ^Form_Data, name: string, bytes: []byte, filename, mime: string) -> (e: forms.Entry, ok: bool) {
	if len(bytes) > p.settings.max_fetch_bytes - p.held { return {}, false }
	data := make([]byte, len(bytes))
	copy(data, bytes)
	p.held += len(data)
	fd.held += len(data)
	return forms.Entry{name = strings.clone(name), is_file = true, file = forms.File{
		name = strings.clone(filename == "" ? "blob" : filename), mime = strings.clone(mime), size = i64(len(data)), data = data,
	}}, true
}

// Destroys an entry of `fd` (no longer in its list), giving back the bytes it counted.
@(private)
fd_entry_destroy :: proc(p: ^Page, fd: ^Form_Data, e: ^forms.Entry) {
	if e.is_file && e.file.data != nil { p.held -= len(e.file.data); fd.held -= len(e.file.data) }
	forms.entry_destroy(e)
}

FormData_create :: proc(c: ^Call, form: Api_Element, submitter: Api_Element) -> (u64, Api_Error) {
	p := c.page
	pf := page_forms(p)
	list: [dynamic]forms.Entry
	if form.handle != 0 {
		if forms.kind(pf, H(form.handle)) != .Form { return 0, fail(c, .Invalid_Handle, "not a form") }
		if submitter.handle != 0 && (!forms.is_submit_button(pf, H(submitter.handle)) || forms.form_owner(pf, H(submitter.handle)) != H(form.handle)) {
			return 0, fail(c, .Invalid_Handle, "not a submit button of this form")
		}
		ok: bool
		list, ok = forms.construct_entry_list(pf, H(form.handle), H(submitter.handle))
		if !ok { return 0, fail(c, .Invalid_State, "InvalidStateError: the form is already constructing its entry list") }
	}
	h, fd := formdata_create(p, c.owner)
	fd.entries = list
	return h, .None
}

FormData_append :: proc(c: ^Call, data: Api_FormData, name, value: string) -> Api_Error {
	fd := data.data
	if too_many(c.page, fd) { return fail(c, .Invalid_Argument, "too many entries (forms.max_entries)") }
	append(&fd.entries, forms.Entry{name = strings.clone(name), value = strings.clone(value)})
	return .None
}

// append(name, blob, filename): the bytes of a buffer as a file entry ("blob" when no file name is given).
FormData_appendBlob :: proc(c: ^Call, data: Api_FormData, name: string, blob: Api_Buffer, filename: string, mime: string) -> Api_Error {
	fd := data.data
	if too_many(c.page, fd) { return fail(c, .Invalid_Argument, "too many entries (forms.max_entries)") }
	e, ok := fd_blob_entry(c.page, fd, name, blob.data.bytes[:], filename, mime)
	if !ok { return fail(c, .Quota, "QuotaExceededError: page memory limit") }
	append(&fd.entries, e)
	return .None
}

@(private)
fd_remove_all :: proc(p: ^Page, fd: ^Form_Data, name: string) -> (first: int) {
	first = -1
	i := 0
	for i < len(fd.entries) {
		if fd.entries[i].name == name {
			if first < 0 { first = i }
			fd_entry_destroy(p, fd, &fd.entries[i])
			ordered_remove(&fd.entries, i)
			continue
		}
		i += 1
	}
	return
}

// set(name, value): replaces the first entry of that name and removes the others (appends when there is none).
FormData_set :: proc(c: ^Call, data: Api_FormData, name, value: string) -> Api_Error {
	fd := data.data
	at := fd_remove_all(c.page, fd, name)
	e := forms.Entry{name = strings.clone(name), value = strings.clone(value)}
	if at < 0 {
		if too_many(c.page, fd) { forms.entry_destroy(&e); return fail(c, .Invalid_Argument, "too many entries (forms.max_entries)") }
		append(&fd.entries, e)
	} else {
		inject_at(&fd.entries, at, e)
	}
	return .None
}

FormData_delete :: proc(c: ^Call, data: Api_FormData, name: string) { fd_remove_all(c.page, data.data, name) }

FormData_has :: proc(c: ^Call, data: Api_FormData, name: string) -> bool {
	for e in data.data.entries { if e.name == name { return true } }
	return false
}

// The number of entries named `name` (getAll().length).
FormData_count :: proc(c: ^Call, data: Api_FormData, name: string) -> i32 {
	n: i32
	for e in data.data.entries { if e.name == name { n += 1 } }
	return n
}

@(private)
entry_text :: proc(e: forms.Entry) -> string { return e.is_file ? e.file.name : e.value }

// getAll(name)[i]: the value (a file entry gives its file name). Not_Found when there is no such entry.
FormData_getAt :: proc(c: ^Call, data: Api_FormData, name: string, index: i32) -> (string, Api_Error) {
	k: i32
	for e in data.data.entries {
		if e.name != name { continue }
		if k == index { return entry_text(e), .None }
		k += 1
	}
	return "", .Not_Found
}

FormData_get :: proc(c: ^Call, data: Api_FormData, name: string) -> (string, Api_Error) { return FormData_getAt(c, data, name, 0) }

FormData_size :: proc(c: ^Call, data: Api_FormData) -> i32 { return i32(len(data.data.entries)) }

@(private)
entry_at :: proc(data: Api_FormData, i: i32) -> ^forms.Entry {
	fd := data.data
	if i < 0 || int(i) >= len(fd.entries) { return nil }
	return &fd.entries[i]
}

FormData_nameAt :: proc(c: ^Call, data: Api_FormData, index: i32) -> (string, Api_Error) {
	e := entry_at(data, index)
	if e == nil { return "", .Not_Found }
	return e.name, .None
}

FormData_valueAt :: proc(c: ^Call, data: Api_FormData, index: i32) -> (string, Api_Error) {
	e := entry_at(data, index)
	if e == nil { return "", .Not_Found }
	return entry_text(e^), .None
}

FormData_isFileAt :: proc(c: ^Call, data: Api_FormData, index: i32) -> (bool, Api_Error) {
	e := entry_at(data, index)
	if e == nil { return false, .Not_Found }
	return e.is_file, .None
}

FormData_fileSizeAt :: proc(c: ^Call, data: Api_FormData, index: i32) -> i64 {
	e := entry_at(data, index)
	if e == nil || !e.is_file { return -1 }
	return e.file.size
}

FormData_fileTypeAt :: proc(c: ^Call, data: Api_FormData, index: i32) -> (string, Api_Error) {
	e := entry_at(data, index)
	if e == nil || !e.is_file { return "", .Not_Found }
	return e.file.mime, .None
}
////////////////////////////////
// Sending a FormData with fetch

// A body being encoded on a worker: owns a copy of the entries. `cancelled` is set when the page closes first.
@(private)
Body_Job :: struct {
	page:      ^Page,
	fetch:     base.Handle,
	cleanup:   base.Cleanup_Id,
	cancelled: bool,
	sub:       forms.Submission,   // entries + enctype in, body + content type out
	settings:  forms.Settings,
	ok:        bool,
	message:   string,
	target:    string,
	method:    string,
	headers:   string,
	options:   u32,
}

@(private)
start_fetch_with_body :: proc(p: ^Page, f: ^Fetch, target, method, headers: string, content_type: string, body: []byte, options: u32) {
	pairs := make([dynamic]fetch.Header_Pair, context.temp_allocator)
	parse_header_lines(headers, &pairs)
	has_ct := false
	for hp in pairs { if strings.equal_fold(hp.name, "content-type") { has_ct = true } }
	if !has_ct && content_type != "" { append(&pairs, fetch.Header_Pair{"Content-Type", content_type}) }
	o := options
	mode := fetch.Mode.Cors
	switch o & 3 { case 1: mode = .Same_Origin; case 2: mode = .No_Cors }
	creds := fetch.Credentials.Same_Origin
	switch (o >> 2) & 3 { case 1: creds = .Omit; case 2: creds = .Include }
	redirect := fetch.Redirect_Mode.Follow
	switch (o >> 4) & 3 { case 1: redirect = .Error; case 2: redirect = .Manual }
	policy := fetch.Referrer_Policy((o >> 6) & 0xF)
	if policy > .Unsafe_Url { policy = .Default }
	f.task = fetch.start(p.loader, {
		request = {
			url = target, method = method, headers = pairs[:], body = body,
			mode = mode, credentials = creds, redirect = redirect, destination = .Empty,
			referrer_policy = policy, no_referrer = o & (1 << 10) != 0,
			initiator = &p.env, guard = .Request,
		},
		on_event = fetch_event, user = f, scope = p.scope, collect = false,
	})
}

@(private)
fail_fetch :: proc(p: ^Page, f: ^Fetch, message: string) {
	f.state, f.error, f.error_kind = 3, strings.clone(message), .Body_Too_Large
	log(p, .Error, message)
	if inst := instance_by_index(p, f.instance); inst != nil {
		h := f.self
		argv := [4]u32{f.user, u32(u64(h)), u32(u64(h) >> 32), u32(f.state)}
		call_guest(p, inst, f.callback, argv[:])
	}
}

// Fetch with a FormData body: the Content-Type (with its boundary) is set unless the headers name one. Same options and
// callback as Fetch_start.
Fetch_startFormData :: proc(c: ^Call, target: string, data: Api_FormData, callback: u32, user: i32, method: string, headers: string, enctype: Api_FormEnctype, options: Api_FetchOptions) -> u64 {
	p := c.page
	fd := data.data
	h, f := base.pool_insert(&p.fetches, Fetch{page = p, instance = c.owner, callback = callback, user = u32(user)})
	f.self = h
	abs := target
	if u, ok := url.parse(abs, &p.env.location, context.temp_allocator); ok { abs = u.href }

	job := new(Body_Job)
	job.page, job.fetch = p, h
	job.settings = p.settings.forms
	switch enctype {
	case .Multipart:  job.sub.enctype = .Multipart
	case .Urlencoded: job.sub.enctype = .Urlencoded
	case .Text_Plain: job.sub.enctype = .Text_Plain
	}
	for e in fd.entries { append(&job.sub.entries, forms.entry_clone(e)) }
	job.target, job.method, job.headers, job.options = strings.clone(abs), strings.clone(method), strings.clone(headers), fetch_options_pack(options)

	if !forms.needs_file_reads(job.sub.entries[:]) {
		body_job_work(job)
		body_job_finish(job)
		return u64(h)
	}
	job.cleanup = base.on_close(p.scope, proc(data: rawptr) { (^Body_Job)(data).cancelled = true }, job)
	host.run_blocking(p.loader.blocking, body_job_work, proc(data: rawptr) {
		job := (^Body_Job)(data)
		if !job.cancelled { base.forget_cleanup(job.page.scope, job.cleanup) }
		body_job_finish(job)
	}, job)
	return u64(h)
}
@(private)
body_job_work :: proc(data: rawptr) {
	job := (^Body_Job)(data)
	job.ok, job.message = forms.encode_submission(&job.sub, job.settings)
}

@(private)
body_job_finish :: proc(job: ^Body_Job) {
	defer {
		forms.entries_destroy(&job.sub.entries)
		delete(job.sub.body); delete(job.sub.content_type); delete(job.sub.boundary)
		delete(job.message); delete(job.target); delete(job.method); delete(job.headers)
		free(job)
	}
	if job.cancelled { return }
	p := job.page
	f := base.pool_get(&p.fetches, job.fetch)
	if f == nil || p.closed { return }   // the guest released the request meanwhile
	if !job.ok { fail_fetch(p, f, job.message); return }
	start_fetch_with_body(p, f, job.target, job.method, job.headers, job.sub.content_type, job.sub.body, job.options)
}
