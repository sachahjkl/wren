package page

// FormData (XHR §5): an entry list owned by the browser, referenced by an object handle. Built from a form (which fires
// `formdata`), edited by the guest, sent with Fetch_startFormData. File entries keep their path and are read when the
// body is encoded, on a worker thread.

import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:forms"
import "wb:host"
import "wb:url"
import "wb:wasm"

Form_Data :: struct { entries: [dynamic]forms.Entry }

formdata_vt := Object_VTable{
	name = "FormData",
	destroy = proc(p: ^Page, data: rawptr) {
		fd := (^Form_Data)(data)
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
	}
	object_release(p, h)
}

@(private)
fd_of :: proc(env: wasm.Exec_Env, h: u64) -> ^Form_Data { return formdata_get(page_of(env), h) }

@(private)
too_many :: proc(p: ^Page, fd: ^Form_Data) -> bool { return len(fd.entries) >= p.settings.forms.max_entries }

n_FormData_create :: proc "c" (env: wasm.Exec_Env, form, submitter: u64) -> u64 {
	context = ctx()
	p := page_of(env)
	pf := page_forms(p)
	list: [dynamic]forms.Entry
	if form != 0 {
		if forms.kind(pf, H(form)) != .Form { return 0 }
		if submitter != 0 && (!forms.is_submit_button(pf, H(submitter)) || forms.form_owner(pf, H(submitter)) != H(form)) { return 0 }
		ok: bool
		list, ok = forms.construct_entry_list(pf, H(form), H(submitter))
		if !ok { return 0 }   // InvalidStateError: the form is already constructing its entry list
	}
	h, fd := formdata_create(p, inst_of(env).index)
	fd.entries = list
	return h
}

n_FormData_append :: proc "c" (env: wasm.Exec_Env, h: u64, name: [^]u8, nl: i32, value: [^]u8, vl: i32) -> i32 {
	context = ctx()
	fd := fd_of(env, h)
	if fd == nil { return i32(dom.Error.Invalid_Handle) }
	if too_many(page_of(env), fd) { return i32(dom.Error.Invalid_Argument) }
	append(&fd.entries, forms.Entry{name = strings.clone(str(name, nl)), value = strings.clone(str(value, vl))})
	return 0
}

// append(name, blob, filename): the bytes of a buffer as a file entry ("blob" when no file name is given).
n_FormData_appendBlob :: proc "c" (env: wasm.Exec_Env, h: u64, name: [^]u8, nl: i32, buffer: u64, filename: [^]u8, fl: i32, mime: [^]u8, ml: i32) -> i32 {
	context = ctx()
	p := page_of(env)
	fd := fd_of(env, h)
	if fd == nil { return i32(dom.Error.Invalid_Handle) }
	b := buffer_get(p, buffer)
	if b == nil { return i32(dom.Error.Invalid_Handle) }
	if too_many(p, fd) { return i32(dom.Error.Invalid_Argument) }
	data := make([]byte, len(b.bytes))
	copy(data, b.bytes[:])
	fname := str(filename, fl)
	append(&fd.entries, forms.Entry{name = strings.clone(str(name, nl)), is_file = true, file = forms.File{
		name = strings.clone(fname == "" ? "blob" : fname), mime = strings.clone(str(mime, ml)), size = i64(len(data)), data = data,
	}})
	return 0
}

@(private)
fd_remove_all :: proc(fd: ^Form_Data, name: string) -> (first: int) {
	first = -1
	i := 0
	for i < len(fd.entries) {
		if fd.entries[i].name == name {
			if first < 0 { first = i }
			forms.entry_destroy(&fd.entries[i])
			ordered_remove(&fd.entries, i)
			continue
		}
		i += 1
	}
	return
}

// set(name, value): replaces the first entry of that name and removes the others (appends when there is none).
n_FormData_set :: proc "c" (env: wasm.Exec_Env, h: u64, name: [^]u8, nl: i32, value: [^]u8, vl: i32) -> i32 {
	context = ctx()
	fd := fd_of(env, h)
	if fd == nil { return i32(dom.Error.Invalid_Handle) }
	n := str(name, nl)
	at := fd_remove_all(fd, n)
	e := forms.Entry{name = strings.clone(n), value = strings.clone(str(value, vl))}
	if at < 0 {
		if too_many(page_of(env), fd) { forms.entry_destroy(&e); return i32(dom.Error.Invalid_Argument) }
		append(&fd.entries, e)
	} else {
		inject_at(&fd.entries, at, e)
	}
	return 0
}

n_FormData_delete :: proc "c" (env: wasm.Exec_Env, h: u64, name: [^]u8, nl: i32) -> i32 {
	context = ctx()
	fd := fd_of(env, h)
	if fd == nil { return i32(dom.Error.Invalid_Handle) }
	fd_remove_all(fd, str(name, nl))
	return 0
}

n_FormData_has :: proc "c" (env: wasm.Exec_Env, h: u64, name: [^]u8, nl: i32) -> i32 {
	context = ctx()
	fd := fd_of(env, h)
	if fd == nil { return i32(dom.Error.Invalid_Handle) }
	n := str(name, nl)
	for e in fd.entries { if e.name == n { return 1 } }
	return 0
}

// The number of entries named `name` (getAll().length).
n_FormData_count :: proc "c" (env: wasm.Exec_Env, h: u64, name: [^]u8, nl: i32) -> i32 {
	context = ctx()
	fd := fd_of(env, h)
	if fd == nil { return i32(dom.Error.Invalid_Handle) }
	n := str(name, nl)
	c: i32
	for e in fd.entries { if e.name == n { c += 1 } }
	return c
}

@(private)
entry_text :: proc(e: forms.Entry) -> string { return e.is_file ? e.file.name : e.value }

// getAll(name)[i]: the value (a file entry gives its file name). Not_Found when there is no such entry.
n_FormData_getAt :: proc "c" (env: wasm.Exec_Env, h: u64, name: [^]u8, nl: i32, index: i32, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	fd := fd_of(env, h)
	if fd == nil { return i32(dom.Error.Invalid_Handle) }
	n := str(name, nl)
	k: i32
	for e in fd.entries {
		if e.name != n { continue }
		if k == index { return out_string(entry_text(e), buf, cap) }
		k += 1
	}
	return i32(dom.Error.Not_Found)
}

n_FormData_get :: proc "c" (env: wasm.Exec_Env, h: u64, name: [^]u8, nl: i32, buf: [^]u8, cap: i32) -> i32 {
	return n_FormData_getAt(env, h, name, nl, 0, buf, cap)
}

n_FormData_size :: proc "c" (env: wasm.Exec_Env, h: u64) -> i32 {
	context = ctx()
	fd := fd_of(env, h)
	if fd == nil { return i32(dom.Error.Invalid_Handle) }
	return i32(len(fd.entries))
}

@(private)
entry_at :: proc(env: wasm.Exec_Env, h: u64, i: i32) -> ^forms.Entry {
	fd := fd_of(env, h)
	if fd == nil || i < 0 || int(i) >= len(fd.entries) { return nil }
	return &fd.entries[i]
}

n_FormData_nameAt :: proc "c" (env: wasm.Exec_Env, h: u64, i: i32, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	e := entry_at(env, h, i)
	if e == nil { return i32(dom.Error.Not_Found) }
	return out_string(e.name, buf, cap)
}

n_FormData_valueAt :: proc "c" (env: wasm.Exec_Env, h: u64, i: i32, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	e := entry_at(env, h, i)
	if e == nil { return i32(dom.Error.Not_Found) }
	return out_string(entry_text(e^), buf, cap)
}

n_FormData_isFileAt :: proc "c" (env: wasm.Exec_Env, h: u64, i: i32) -> i32 {
	context = ctx()
	e := entry_at(env, h, i)
	if e == nil { return i32(dom.Error.Not_Found) }
	return e.is_file ? 1 : 0
}

n_FormData_fileSizeAt :: proc "c" (env: wasm.Exec_Env, h: u64, i: i32) -> i64 {
	context = ctx()
	e := entry_at(env, h, i)
	if e == nil || !e.is_file { return -1 }
	return e.file.size
}

n_FormData_fileTypeAt :: proc "c" (env: wasm.Exec_Env, h: u64, i: i32, buf: [^]u8, cap: i32) -> i32 {
	context = ctx()
	e := entry_at(env, h, i)
	if e == nil || !e.is_file { return i32(dom.Error.Not_Found) }
	return out_string(e.file.mime, buf, cap)
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

// Fetch with a FormData body: `enctype` 0 multipart/form-data (the Fetch default), 1 urlencoded, 2 text/plain. The
// Content-Type (with its boundary) is set unless the headers name one. Same options and callback as Fetch_start.
n_Fetch_startFormData :: proc "c" (env: wasm.Exec_Env, target: [^]u8, tl: i32, method: [^]u8, ml: i32, headers: [^]u8, hl: i32, formdata: u64, enctype, options, callback, user: i32) -> u64 {
	context = ctx()
	p := page_of(env)
	fd := formdata_get(p, formdata)
	if fd == nil { return 0 }
	inst := inst_of(env)
	h, f := base.pool_insert(&p.fetches, Fetch{page = p, instance = inst.index, callback = u32(callback), user = u32(user)})
	f.self = h
	abs := str(target, tl)
	if u, ok := url.parse(abs, &p.env.location, context.temp_allocator); ok { abs = u.href }

	job := new(Body_Job)
	job.page, job.fetch = p, h
	job.settings = p.settings.forms
	job.sub.enctype = enctype == 1 ? .Urlencoded : enctype == 2 ? .Text_Plain : .Multipart
	for e in fd.entries { append(&job.sub.entries, forms.entry_clone(e)) }
	job.target, job.method, job.headers, job.options = strings.clone(abs), strings.clone(str(method, ml)), strings.clone(str(headers, hl)), u32(options)

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
