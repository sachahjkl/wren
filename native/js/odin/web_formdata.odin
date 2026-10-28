// web_formdata.odin: FormData (XMLHttpRequest Standard) on the browser's entry lists (module forms). Ported from
// native/js/runtime/web_formdata.c: same wjr_* / web_formdata_* symbols and behaviour.
//
// File entries come back as File objects (their bytes copied from the browser; a file chosen in an <input type=file>
// is read then). Bodies: multipart/form-data is encoded by the browser with a boundary made here
// (web_formdata_encode); Response.formData() parses multipart and urlencoded bodies here (web_formdata_parse).
package odin_glue

import "../odin_abi/abi"
import "../odin_abi/api_decl"
import "../odin/jsb"
import "../odin/wj"

FormData :: api_decl.FormData

@(private = "file")
fd_obj :: proc "contextless" (v: wj.JSValue) -> ^wj.Obj {
	o := wj.wj_unwrap(v, jsb.iface_of(FormData))
	return o != nil && o.handle != 0 ? o : nil
}

@(export, link_name = "web_formdata_is")
web_formdata_is :: proc "c" (v: wj.JSValue) -> bool { return fd_obj(v) != nil }

// The browser's FormData behind a FormData object (0 if `v` is not one).
@(export, link_name = "web_formdata_handle")
web_formdata_handle :: proc "c" (v: wj.JSValue) -> u64 { return wj.handle_of(fd_obj(v)) }

// A new FormData object with no entries.
@(export, link_name = "web_formdata_new")
web_formdata_new :: proc "c" (ctx: ^wj.Context) -> wj.JSValue {
	context = wj.heap_context()
	h: FormData
	if st := jsb.host(&h, api_decl.FormData_create, wj.wr_FormData_create, u64(0), u64(0)); st != .None {
		return wj.wj_throw_status(ctx, i32(st), "FormData")
	}
	return wj.wj_wrap_owned(ctx, u64(h), jsb.iface_of(FormData), wj.UNDEFINED)
}

@(export, link_name = "wjr_FormData_constructor")
wjr_FormData_constructor :: proc "c" (ctx: ^wj.Context, new_target: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	if wj.is_undefined(new_target) { return wj.wj_throw_type(ctx, "Constructor FormData requires 'new'") }
	form, submitter := wj.arg(argc, argv, 0), wj.arg(argc, argv, 1)
	fh, sh: u64
	if !wj.is_undefined(form) && !wj.wj_to_handle(ctx, form, net_iface(.HTMLFormElement), false, &fh, "Failed to construct 'FormData': parameter 1 is not of type 'HTMLFormElement'.") { return wj.EXCEPTION }
	if !wj.is_nullish(submitter) && !wj.wj_to_handle(ctx, submitter, net_iface(.HTMLElement), false, &sh, "Failed to construct 'FormData': parameter 2 is not of type 'HTMLElement'.") { return wj.EXCEPTION }
	h: FormData
	#partial switch st := jsb.host(&h, api_decl.FormData_create, wj.wr_FormData_create, fh, sh); st {
	case .None:
	case .Invalid_Handle: return wj.wj_throw_type(ctx, "Failed to construct 'FormData': The specified element is not a submit button of this form.")
	case:                 return wj.wj_throw_status(ctx, i32(st), "FormData")
	}
	return wj.wj_wrap_owned(ctx, u64(h), jsb.iface_of(FormData), new_target)
}

// A Blob value's entry: the bytes in a browser buffer, the file name (the given one, the File's, or "blob") and type.
@(private = "file")
Blob_Entry :: struct {
	buf:        api_decl.Buffer,
	name, mime: wj.Str,
}

@(private = "file")
blob_entry_free :: proc "contextless" (ctx: ^wj.Context, e: ^Blob_Entry) {
	if e.buf != 0 { wj.wr_Object_release(u64(e.buf)) }
	wj.wj_str_free(ctx, &e.name)
	wj.wj_str_free(ctx, &e.mime)
}

@(private = "file")
blob_entry :: proc(ctx: ^wj.Context, blob: wj.JSValue, filename: wj.JSValue, bytes: []u8) -> (e: Blob_Entry, ok: bool) {
	if !wj.is_undefined(filename) {
		if !wj.web_to_usv(ctx, filename, &e.name) { return }
	} else if wj.wj_unwrap(blob, net_iface(.File)) != nil {
		fn := wj.JS_GetPropertyStr(ctx, blob, "name")
		good := !wj.is_exception(fn) && wj.web_to_usv(ctx, fn, &e.name)
		wj.JS_FreeValue(ctx, fn)
		if !good { return }
	} else {
		e.name = {wj.raw_bytes("blob"), 4, false}
	}
	t := web_blob_type(ctx, blob)
	good := wj.wj_to_str(ctx, t, &e.mime, 0, nil)
	wj.JS_FreeValue(ctx, t)
	if !good { wj.wj_str_free(ctx, &e.name); return }
	e.buf = api_decl.Buffer(wj.wj_host_buffer(ctx, raw_data(bytes), uint(len(bytes))))
	if e.buf == 0 { blob_entry_free(ctx, &e); return }
	return e, true
}

@(private = "file")
fd_add :: proc(ctx: ^wj.Context, h: FormData, name_v: wj.JSValue, value: wj.JSValue, filename: wj.JSValue, set: bool) -> bool {
	name: wj.Str
	if !wj.web_to_usv(ctx, name_v, &name) { return false }
	defer wj.wj_str_free(ctx, &name)
	n := wj.str_view(name)
	st: abi.Api_Error
	if bytes, is_blob := blob_slice(value); is_blob {
		e, ok := blob_entry(ctx, value, filename, bytes)
		if !ok { return false }
		defer blob_entry_free(ctx, &e)
		if set {
			st = jsb.host5(&none_m2, api_decl.FormData_setBlob, wj.wr_FormData_setBlob, h, n, e.buf, wj.str_view(e.name), wj.str_view(e.mime))
		} else {
			st = jsb.host5(&none_m2, api_decl.FormData_appendBlob, wj.wr_FormData_appendBlob, h, n, e.buf, wj.str_view(e.name), wj.str_view(e.mime))
		}
	} else {
		if !wj.is_undefined(filename) { wj.JS_ThrowTypeError(ctx, "Failed to execute 'append' on 'FormData': parameter 2 is not of type 'Blob'."); return false }
		v: wj.Str
		if !wj.web_to_usv(ctx, value, &v) { return false }
		defer wj.wj_str_free(ctx, &v)
		if set {
			st = jsb.host(&none_m2, api_decl.FormData_set, wj.wr_FormData_set, h, n, wj.str_view(v))
		} else {
			st = jsb.host(&none_m2, api_decl.FormData_append, wj.wr_FormData_append, h, n, wj.str_view(v))
		}
	}
	if st != .None { wj.wj_throw_status(ctx, i32(st), "FormData"); return false }
	return true
}

// append(name, value) / append(name, blob, filename): `value` a Blob or File, else a string.
@(export, link_name = "web_formdata_append")
web_formdata_append :: proc "c" (ctx: ^wj.Context, fd: wj.JSValue, name: wj.JSValue, value: wj.JSValue, filename: wj.JSValue) -> bool {
	context = wj.heap_context()
	o := fd_obj(fd)
	if o == nil { wj.JS_ThrowTypeError(ctx, "not a FormData"); return false }
	return fd_add(ctx, FormData(o.handle), name, value, filename, false)
}

@(private = "file")
fd_member :: proc(ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, set: bool) -> wj.JSValue {
	h, ok := jsb.this(ctx, this_val, FormData)
	if !ok { return wj.EXCEPTION }
	if argc < 2 { return wj.wj_throw_arity(ctx, set ? "FormData.set" : "FormData.append", 2, argc) }
	return fd_add(ctx, h, argv[0], argv[1], wj.arg(argc, argv, 2), set) ? wj.UNDEFINED : wj.EXCEPTION
}

@(export, link_name = "wjr_FormData_append")
wjr_FormData_append :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return fd_member(ctx, this_val, argc, argv, false)
}

@(export, link_name = "wjr_FormData_set")
wjr_FormData_set :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return fd_member(ctx, this_val, argc, argv, true)
}

// the value of entry `i`: a string, or a File (undefined past the end)
@(private = "file")
entry_value :: proc(ctx: ^wj.Context, h: FormData, i: i32) -> wj.JSValue {
	value: string
	if jsb.host(&value, api_decl.FormData_valueAt, wj.wr_FormData_valueAt, h, i) != .None { return wj.UNDEFINED }
	is_file: bool
	jsb.host(&is_file, api_decl.FormData_isFileAt, wj.wr_FormData_isFileAt, h, i)
	if !is_file { return wj.new_string_len(ctx, value) }
	// (each string result lives in the scratch buffer until the next call: copied)
	name := wj.heap_strndup(value)
	defer wj.libc_free(name)
	name_len := uint(len(value))
	type_s: string
	jsb.host(&type_s, api_decl.FormData_fileTypeAt, wj.wr_FormData_fileTypeAt, h, i)
	type := wj.heap_strndup(type_s)
	defer wj.libc_free(type)
	type_len := uint(len(type_s))
	buf: api_decl.Buffer
	st := jsb.host(&buf, api_decl.FormData_fileAt, wj.wr_FormData_fileAt, h, i)
	defer if buf != 0 { wj.wr_Object_release(u64(buf)) }
	if st != .None { return wj.wj_throw_status(ctx, i32(st), "FormData") }
	if name == nil || type == nil { return wj.JS_ThrowOutOfMemory(ctx) }
	length: i64
	jsb.host(&length, api_decl.Buffer_length, wj.wr_Buffer_length, buf)
	bytes, err := make([]u8, int(max(length, 0)))
	if err != nil { return wj.JS_ThrowOutOfMemory(ctx) }
	defer delete(bytes)
	got: i32
	if len(bytes) > 0 { jsb.host(&got, api_decl.Buffer_read, wj.wr_Buffer_read, buf, i64(0), bytes) }
	return web_file_new(ctx, raw_data(bytes), uint(max(got, 0)), wj.cstr(type), type_len, wj.cstr(name), name_len,
		wj.wr_Performance_timeOrigin() + wj.wr_Performance_now())
}

@(private = "file")
fd_find :: proc(ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue, all: bool) -> wj.JSValue {
	h, ok := jsb.this(ctx, this_val, FormData)
	if !ok { return wj.EXCEPTION }
	if argc < 1 { return wj.wj_throw_arity(ctx, all ? "FormData.getAll" : "FormData.get", 1, argc) }
	name: wj.Str
	if !wj.web_to_usv(ctx, argv[0], &name) { return wj.EXCEPTION }
	defer wj.wj_str_free(ctx, &name)
	arr := all ? wj.JS_NewArray(ctx) : wj.NULL
	k: u32
	size: i32
	jsb.host(&size, api_decl.FormData_size, wj.wr_FormData_size, h)
	for i in 0 ..< size {
		n: string
		if jsb.host(&n, api_decl.FormData_nameAt, wj.wr_FormData_nameAt, h, i) != .None || n != wj.str_view(name) { continue }
		v := entry_value(ctx, h, i)
		if wj.is_exception(v) { wj.JS_FreeValue(ctx, arr); return v }
		if !all { return v }
		wj.array_set(ctx, arr, k, v)
		k += 1
	}
	return arr
}

@(export, link_name = "wjr_FormData_get")
wjr_FormData_get :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return fd_find(ctx, this_val, argc, argv, false)
}

@(export, link_name = "wjr_FormData_getAll")
wjr_FormData_getAll :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	context = wj.heap_context()
	return fd_find(ctx, this_val, argc, argv, true)
}

// The pair iterator's "at" callback (web_iterator_new / web_for_each): 0 past the end, -1 with an exception.
@(private = "file")
fd_at :: proc "c" (ctx: ^wj.Context, owner: wj.JSValue, index: u32, key: ^wj.JSValue, value: ^wj.JSValue) -> i32 {
	context = wj.heap_context()
	o := fd_obj(owner)
	if o == nil { return 0 }
	h := FormData(o.handle)
	size: i32
	jsb.host(&size, api_decl.FormData_size, wj.wr_FormData_size, h)
	if i32(index) >= size { return 0 }
	n: string
	if jsb.host(&n, api_decl.FormData_nameAt, wj.wr_FormData_nameAt, h, i32(index)) != .None { return 0 }
	key^ = wj.new_string_len(ctx, n)
	value^ = entry_value(ctx, h, i32(index))
	if wj.is_exception(value^) { wj.JS_FreeValue(ctx, key^); return -1 }
	return 1
}

@(private = "file")
fd_iter :: proc "contextless" (ctx: ^wj.Context, this_val: wj.JSValue, kind: i32) -> wj.JSValue {
	if _, ok := jsb.this(ctx, this_val, FormData); !ok { return wj.EXCEPTION }
	return wj.web_iterator_new(ctx, wj.ITERABLE_FORMDATA, this_val, kind, fd_at)
}

@(export, link_name = "wjr_FormData_entries")
wjr_FormData_entries :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return fd_iter(ctx, this_val, wj.ITER_ENTRIES) }
@(export, link_name = "wjr_FormData_keys")
wjr_FormData_keys :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return fd_iter(ctx, this_val, wj.ITER_KEYS) }
@(export, link_name = "wjr_FormData_values")
wjr_FormData_values :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue { return fd_iter(ctx, this_val, wj.ITER_VALUES) }

@(export, link_name = "wjr_FormData_forEach")
wjr_FormData_forEach :: proc "c" (ctx: ^wj.Context, this_val: wj.JSValue, argc: i32, argv: [^]wj.JSValue) -> wj.JSValue {
	if _, ok := jsb.this(ctx, this_val, FormData); !ok { return wj.EXCEPTION }
	return wj.web_for_each(ctx, this_val, argc, argv, fd_at)
}

// ---- bodies ----

// The entries of `fd` as multipart/form-data in a browser buffer (owned), with the boundary made here written to
// `boundary` (NUL-terminated, at most cap - 1 bytes). 0 with an exception pending.
@(export, link_name = "web_formdata_encode")
web_formdata_encode :: proc "c" (ctx: ^wj.Context, fd: wj.JSValue, boundary: [^]u8, cap: uint) -> u64 {
	context = wj.heap_context()
	o := fd_obj(fd)
	if o == nil { wj.JS_ThrowTypeError(ctx, "not a FormData"); return 0 }
	alnum := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
	prefix := "----WrenFormBoundary"
	r: [16]u8
	wj.arc4random_buf(&r[0], len(r))
	w := min(uint(len(prefix)), cap - 1)
	copy(boundary[:w], prefix)
	for i := 0; i < len(r) && w + 1 < cap; i += 1 {
		boundary[w] = alnum[int(r[i]) % len(alnum)]
		w += 1
	}
	boundary[w] = 0
	buf: api_decl.Buffer
	if st := jsb.host(&buf, api_decl.FormData_encode, wj.wr_FormData_encode, FormData(o.handle), string(boundary[:w])); st != .None {
		wj.wj_throw_status(ctx, i32(st), "FormData")
		return 0
	}
	return u64(buf)
}

// A parameter of a header value (`name=value` or `name="value"`).
header_param :: proc "contextless" (v: string, name: string) -> (string, bool) {
	n := len(v)
	for i in 0 ..< n {
		if v[i] != ';' { continue }
		j := i + 1
		for j < n && (v[j] == ' ' || v[j] == '\t') { j += 1 }
		if j + len(name) < n && wj.ascii_ieq(v[j:][:len(name)], name) && v[j + len(name)] == '=' {
			j += len(name) + 1
			if j < n && v[j] == '"' {
				k := j + 1
				for k < n && v[k] != '"' { k += 1 }
				return v[j + 1:k], true
			}
			k := j
			for k < n && v[k] != ';' && v[k] != ' ' && v[k] != '\t' { k += 1 }
			return v[j:k], true
		}
	}
	return "", false
}

// The first position of `needle` in `hay`, -1 when absent.
find_bytes :: proc "contextless" (hay: []u8, needle: string) -> int {
	m := len(needle)
	if m == 0 || len(hay) < m { return -1 }
	for i in 0 ..= len(hay) - m {
		if hay[i] == needle[0] && string(hay[i:][:m]) == needle { return i }
	}
	return -1
}

@(private = "file")
parse_multipart :: proc(ctx: ^wj.Context, fd: wj.JSValue, body: []u8, boundary: string) -> bool {
	delim: [128]u8
	if len(boundary) + 4 >= len(delim) { return false }
	delim[0], delim[1] = '-', '-'
	copy(delim[2:], boundary)
	d := string(delim[:len(boundary) + 2])
	at := find_bytes(body, d)
	if at < 0 { return false }
	cur := body[at:]
	for {
		cur = cur[len(d):]
		if len(cur) >= 2 && cur[0] == '-' && cur[1] == '-' { return true }   // the closing delimiter
		if len(cur) >= 2 && cur[0] == '\r' && cur[1] == '\n' { cur = cur[2:] } else { return false }
		// headers, up to an empty line
		hend := find_bytes(cur, "\r\n\r\n")
		if hend < 0 { return false }
		name, fname, ctype: string
		has_name, has_fname: bool
		for line := 0; line < hend; {
			le := find_bytes(cur[line:hend + 2], "\r\n")
			le = le < 0 ? hend : line + le
			l := string(cur[line:le])
			for c, k in transmute([]u8)l {
				if c != ':' { continue }
				v := l[k + 1:]
				for len(v) > 0 && (v[0] == ' ' || v[0] == '\t') { v = v[1:] }
				if wj.ascii_ieq(l[:k], "content-disposition") {
					if p, ok := header_param(v, "name"); ok { name, has_name = p, true }
					fname, has_fname = header_param(v, "filename")
				} else if wj.ascii_ieq(l[:k], "content-type") {
					ctype = v
				}
				break
			}
			line = le + 2
		}
		content := cur[hend + 4:]
		next := find_bytes(content, d)
		if next < 0 || !has_name { return false }
		part := content[:next]
		if len(part) >= 2 && part[len(part) - 2] == '\r' && part[len(part) - 1] == '\n' { part = part[:len(part) - 2] }
		nv := wj.new_string_len(ctx, name)
		ok: bool
		if has_fname {
			ct := wj.heap_strndup(ctype)
			fn := wj.heap_strndup(fname)
			file := web_file_new(ctx, raw_data(part), uint(len(part)), wj.cstr(ct), uint(len(ctype)), wj.cstr(fn), uint(len(fname)), 0)
			wj.libc_free(ct)
			wj.libc_free(fn)
			ok = !wj.is_exception(file) && web_formdata_append(ctx, fd, nv, file, wj.UNDEFINED)
			wj.JS_FreeValue(ctx, file)
		} else {
			val := wj.web_utf8_string(ctx, raw_data(part), uint(len(part)), false)
			ok = !wj.is_exception(val) && web_formdata_append(ctx, fd, nv, val, wj.UNDEFINED)
			wj.JS_FreeValue(ctx, val)
		}
		wj.JS_FreeValue(ctx, nv)
		if !ok { return false }
		cur = content[next:]
	}
}

// The entries of a body as application/x-www-form-urlencoded or multipart/form-data (Fetch "package data"): a new
// FormData, or a TypeError pending.
@(export, link_name = "web_formdata_parse")
web_formdata_parse :: proc "c" (ctx: ^wj.Context, p: [^]u8, n: uint, content_type: cstring, ct_len: uint) -> wj.JSValue {
	context = wj.heap_context()
	ct := content_type != nil ? string(([^]u8)(rawptr(content_type))[:ct_len]) : ""
	body := p != nil ? p[:n] : nil
	essence := 0
	for essence < len(ct) && ct[essence] != ';' { essence += 1 }
	for essence > 0 && (ct[essence - 1] == ' ' || ct[essence - 1] == '\t') { essence -= 1 }
	fd := web_formdata_new(ctx)
	if wj.is_exception(fd) { return fd }
	if wj.ascii_ieq(ct[:essence], "multipart/form-data") {
		b, ok := header_param(ct, "boundary")
		if !ok || !parse_multipart(ctx, fd, body, b) {
			wj.JS_FreeValue(ctx, fd)
			if !wj.JS_HasException(ctx) { wj.JS_ThrowTypeError(ctx, "Failed to fetch: the body is not valid multipart/form-data") }
			return wj.EXCEPTION
		}
		return fd
	}
	if wj.ascii_ieq(ct[:essence], "application/x-www-form-urlencoded") {
		params: api_decl.URLSearchParams
		if st := jsb.host(&params, api_decl.URLSearchParams_create, wj.wr_URLSearchParams_create, string(body)); st != .None {
			wj.JS_FreeValue(ctx, fd)
			return wj.wj_throw_status(ctx, i32(st), "formData")
		}
		defer wj.wr_Object_release(u64(params))
		size: i32
		jsb.host(&size, api_decl.URLSearchParams_size, wj.wr_URLSearchParams_size, params)
		for i in 0 ..< size {
			s: string
			jsb.host(&s, api_decl.URLSearchParams_nameAt, wj.wr_URLSearchParams_nameAt, params, i)
			name := wj.new_string_len(ctx, s)
			s = ""
			jsb.host(&s, api_decl.URLSearchParams_valueAt, wj.wr_URLSearchParams_valueAt, params, i)
			value := wj.new_string_len(ctx, s)
			ok := web_formdata_append(ctx, fd, name, value, wj.UNDEFINED)
			wj.JS_FreeValue(ctx, name)
			wj.JS_FreeValue(ctx, value)
			if !ok { wj.JS_FreeValue(ctx, fd); return wj.EXCEPTION }
		}
		return fd
	}
	wj.JS_FreeValue(ctx, fd)
	return wj.wj_throw_type(ctx, "Failed to execute 'formData': the Content-Type is not multipart/form-data or application/x-www-form-urlencoded")
}
