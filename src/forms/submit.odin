package forms

import "core:crypto"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:url"

// Form submission (§4.10.21): the submission algorithm, the form data set (entry list) and its three encodings.

////////////////////////////////
// Attributes

@(private)
parse_method :: proc(s: string) -> Submit_Method {
	switch strings.to_lower(trim_ascii_ws(s), context.temp_allocator) {
	case "post": return .Post
	case "dialog": return .Dialog
	}
	return .Get
}

@(private)
parse_enctype :: proc(s: string) -> Enctype {
	switch strings.to_lower(trim_ascii_ws(s), context.temp_allocator) {
	case "multipart/form-data": return .Multipart
	case "text/plain": return .Text_Plain
	}
	return .Urlencoded
}

// The attribute of the submitter (formX) when it is a submit button carrying it, else the form's own.
@(private)
form_attr :: proc(f: ^Forms, form, submitter: base.Handle, sub_name, form_name: string) -> (string, bool) {
	if submitter != base.NIL_HANDLE && is_submit_button(f, submitter) {
		if v, ok := attr(element(f, submitter), sub_name); ok { return v, true }
	}
	return attr(element(f, form), form_name)
}

method_of :: proc(f: ^Forms, form, submitter: base.Handle) -> Submit_Method {
	v, _ := form_attr(f, form, submitter, "formmethod", "method")
	return parse_method(v)
}

enctype_of :: proc(f: ^Forms, form, submitter: base.Handle) -> Enctype {
	v, _ := form_attr(f, form, submitter, "formenctype", "enctype")
	return parse_enctype(v)
}

@(private)
no_validate :: proc(f: ^Forms, form, submitter: base.Handle) -> bool {
	if submitter != base.NIL_HANDLE && is_submit_button(f, submitter) && has_attr(element(f, submitter), "formnovalidate") { return true }
	return has_attr(element(f, form), "novalidate")
}

// The document's base URL: the first <base href>, resolved against the document URL.
document_base_url :: proc(f: ^Forms) -> string {
	doc_url := f.host.document_url != nil ? f.host.document_url(f.host.user) : "about:blank"
	all := make([dynamic]base.Handle, context.temp_allocator)
	walk_elements(f, f.doc.root, &all)
	for h in all {
		n := element(f, h)
		if n.name != "base" { continue }
		href, ok := attr(n, "href")
		if !ok { continue }
		b, bok := url.parse_absolute(doc_url, context.temp_allocator)
		if !bok { break }
		if u, uok := url.parse(trim_ascii_ws(href), &b, context.temp_allocator); uok { return u.href }
		break
	}
	return doc_url
}

// The action URL (absolute), from formaction / action, the document URL when empty.
action_of :: proc(f: ^Forms, form, submitter: base.Handle) -> (string, bool) {
	a, _ := form_attr(f, form, submitter, "formaction", "action")
	base_url := document_base_url(f)
	if trim_ascii_ws(a) == "" { return base_url, true }
	b, ok := url.parse_absolute(base_url, context.temp_allocator)
	if !ok { return "", false }
	u, uok := url.parse(trim_ascii_ws(a), &b, context.temp_allocator)
	if !uok { return "", false }
	return u.href, true
}

// The encoding the form is submitted in. Only UTF-8 is implemented: an accept-charset that names other encodings falls
// back to UTF-8 (which is also what the specification mandates for new content).
@(private)
pick_charset :: proc(f: ^Forms, form: base.Handle) -> string {
	return "UTF-8"
}

////////////////////////////////
// Entry list (§4.10.21.4)

// The direction of a field's value for `dirname`: `dir` attribute, "auto" from the first strong character.
@(private)
direction_of :: proc(f: ^Forms, h: base.Handle) -> string {
	for cur := h; cur != base.NIL_HANDLE; cur = parent_element(f, cur) {
		if d, ok := attr(element(f, cur), "dir"); ok {
			l := strings.to_lower(trim_ascii_ws(d), context.temp_allocator)
			if l == "ltr" || l == "rtl" { return l }
			if l == "auto" {
				for r in value(f, h) {
					if (r >= 0x0590 && r <= 0x08FF) || (r >= 0xFB1D && r <= 0xFDFF) || (r >= 0xFE70 && r <= 0xFEFF) { return "rtl" }
					if (r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z') || (r >= 0xC0 && r <= 0x24F) { return "ltr" }
				}
				return "ltr"
			}
		}
	}
	return "ltr"
}

@(private)
append_string_entry :: proc(list: ^[dynamic]Entry, name, value: string) {
	append(list, Entry{name = strings.clone(name), value = strings.clone(value)})
}

// Constructs the entry list of `form`. ok = false when the form is already constructing one (re-entrancy from a
// formdata listener) or there are too many entries.
construct_entry_list :: proc(f: ^Forms, form: base.Handle, submitter: base.Handle, charset := "UTF-8") -> (list: [dynamic]Entry, ok: bool) {
	fc := control_of(f, form)
	if fc == nil || fc.constructing_entries { return nil, false }
	fc.constructing_entries = true
	defer if c := control_peek(f, form); c != nil { c.constructing_entries = false }
	for field in form_submittables(f, form) {
		n := element(f, field)
		if n == nil { continue }
		k := kind_of(n)
		if in_datalist(f, field) || is_disabled(f, field) { continue }
		if k == .Button && field != submitter { continue }
		t := input_type_of(n)
		if k == .Input {
			if (t == .Checkbox || t == .Radio) && !checked(f, field) { continue }
			if (t == .Submit || t == .Reset || t == .Button || t == .Image) && field != submitter { continue }
		}
		name, has_name := attr(n, "name")
		if k == .Input && t == .Image {
			c := control_of(f, field)
			prefix := has_name && name != "" ? strings.concatenate({name, "."}, context.temp_allocator) : ""
			buf: [16]u8
			append_string_entry(&list, strings.concatenate({prefix, "x"}, context.temp_allocator), strconv.write_int(buf[:], i64(c.image_coords.x), 10))
			append_string_entry(&list, strings.concatenate({prefix, "y"}, context.temp_allocator), strconv.write_int(buf[:], i64(c.image_coords.y), 10))
			continue
		}
		if !has_name || name == "" { continue }
		switch {
		case k == .Select:
			for o in select_options_synced(f, field) {
				if option_selected_raw(f, o) && !is_disabled(f, o) { append_string_entry(&list, name, option_value(f, o)) }
			}
		case k == .Input && (t == .Checkbox || t == .Radio):
			v, ok2 := attr(n, "value")
			append_string_entry(&list, name, ok2 ? v : "on")
		case k == .Input && t == .File:
			fl := files(f, field)
			if len(fl) == 0 {
				append(&list, Entry{name = strings.clone(name), is_file = true, file = File{name = strings.clone(""), mime = strings.clone("application/octet-stream")}})
			} else {
				for x in fl { append(&list, Entry{name = strings.clone(name), is_file = true, file = file_clone(x)}) }
			}
		case k == .Input && t == .Hidden && strings.equal_fold(name, "_charset_"):
			append_string_entry(&list, name, charset)
		case:
			append_string_entry(&list, name, value(f, field))
		}
		if dn, ok2 := attr(n, "dirname"); ok2 && dn != "" && (k == .Textarea || (k == .Input && (t == .Text || t == .Search || t == .Tel || t == .Url || t == .Email || t == .Password))) {
			append_string_entry(&list, dn, direction_of(f, field))
		}
		if len(list) > f.settings.max_entries { entries_destroy(&list); return nil, false }
	}
	if f.host.formdata != nil {
		f.host.formdata(f.host.user, form, &list)
	}
	if len(list) > f.settings.max_entries { entries_destroy(&list); return nil, false }
	return list, true
}

////////////////////////////////
// Encodings

// CR, LF and CR LF become CR LF (names and string values of every encoding).
crlf :: proc(s: string, allocator := context.temp_allocator) -> string {
	if strings.index_any(s, "\r\n") < 0 { return s }
	sb := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c == '\r' {
			strings.write_string(&sb, "\r\n")
			if i + 1 < len(s) && s[i + 1] == '\n' { i += 1 }
		} else if c == '\n' {
			strings.write_string(&sb, "\r\n")
		} else {
			strings.write_byte(&sb, c)
		}
	}
	return strings.to_string(sb)
}

// application/x-www-form-urlencoded percent-encoding of one string (UTF-8): alphanumerics and *-._ stay, space is '+'.
urlencode_into :: proc(sb: ^strings.Builder, s: string, space_as_plus := true) {
	HEX := "0123456789ABCDEF"
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '*' || c == '-' || c == '.' || c == '_':
			strings.write_byte(sb, c)
		case c == ' ' && space_as_plus:
			strings.write_byte(sb, '+')
		case:
			strings.write_byte(sb, '%')
			strings.write_byte(sb, HEX[c >> 4])
			strings.write_byte(sb, HEX[c & 15])
		}
	}
}

// The name/value pairs of the urlencoded and text/plain encodings: newlines normalized, files replaced by their name.
@(private)
pair_value :: proc(e: Entry) -> string { return e.is_file ? e.file.name : crlf(e.value) }

urlencode :: proc(list: []Entry, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	for e, i in list {
		if i > 0 { strings.write_byte(&sb, '&') }
		urlencode_into(&sb, crlf(e.name))
		strings.write_byte(&sb, '=')
		urlencode_into(&sb, pair_value(e))
	}
	return strings.to_string(sb)
}

text_plain :: proc(list: []Entry, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	for e in list {
		strings.write_string(&sb, crlf(e.name))
		strings.write_byte(&sb, '=')
		strings.write_string(&sb, pair_value(e))
		strings.write_string(&sb, "\r\n")
	}
	return strings.to_string(sb)
}

// A boundary nobody can predict (the platform's random generator), like browsers': "----WrenFormBoundary" + 16 chars.
make_boundary :: proc(allocator := context.allocator) -> string {
	ALPHABET := "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
	raw: [16]u8
	crypto.rand_bytes(raw[:])
	out: [16]u8
	for b, i in raw { out[i] = ALPHABET[int(b) % len(ALPHABET)] }
	return strings.concatenate({"----WrenFormBoundary", string(out[:])}, allocator)
}

// Escaping of names and filenames in Content-Disposition (§4.10.21.8): LF, CR and '"' are percent-encoded.
@(private)
multipart_escape :: proc(sb: ^strings.Builder, s: string) {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '\n': strings.write_string(sb, "%0A")
		case '\r': strings.write_string(sb, "%0D")
		case '"': strings.write_string(sb, "%22")
		case: strings.write_byte(sb, s[i])
		}
	}
}

// A part's Content-Type: the file's type when it is printable ASCII (File API: Blob.type), else the default (a type with
// CR / LF would have added header lines inside the body).
@(private)
mime_header_value :: proc(mime: string) -> string {
	if mime == "" { return "application/octet-stream" }
	for c in transmute([]u8)mime { if c < 0x20 || c > 0x7E { return "application/octet-stream" } }
	return mime
}

Read_File_Proc :: #type proc(path: string, max_bytes: int, user: rawptr) -> (data: []byte, ok: bool, message: string)

// Reads a file with the OS (default reader of multipart bodies).
read_file_default :: proc(path: string, max_bytes: int, user: rawptr) -> (data: []byte, ok: bool, message: string) {
	info, serr := os.stat(path, context.temp_allocator)
	if serr != nil { return nil, false, fmt.aprintf("cannot read %s", path) }
	if int(info.size) > max_bytes { return nil, false, fmt.aprintf("%s is larger than forms.upload.max_file_bytes", path) }
	b, err := os.read_entire_file(path, context.allocator)
	if err != nil { return nil, false, fmt.aprintf("cannot read %s", path) }
	// the file may have grown since it was measured
	if len(b) > max_bytes { delete(b); return nil, false, fmt.aprintf("%s is larger than forms.upload.max_file_bytes", path) }
	return b, true, ""
}

// multipart/form-data (RFC 7578 with the HTML escaping rules). Files on disk are read with `read` (this may run on a
// worker thread: it touches nothing but the entries). Limits from `s`.
multipart :: proc(list: []Entry, boundary: string, s: Settings, read: Read_File_Proc = read_file_default, user: rawptr = nil, allocator := context.allocator) -> (body: []byte, ok: bool, message: string) {
	out := make([dynamic]byte, allocator)
	sb := strings.builder_make(context.temp_allocator)
	total := 0
	for e in list {
		strings.builder_reset(&sb)
		strings.write_string(&sb, "--")
		strings.write_string(&sb, boundary)
		strings.write_string(&sb, "\r\nContent-Disposition: form-data; name=\"")
		multipart_escape(&sb, crlf(e.name))
		strings.write_byte(&sb, '"')
		if e.is_file {
			strings.write_string(&sb, "; filename=\"")
			multipart_escape(&sb, e.file.name)
			strings.write_string(&sb, "\"\r\nContent-Type: ")
			strings.write_string(&sb, mime_header_value(e.file.mime))
		}
		strings.write_string(&sb, "\r\n\r\n")
		append(&out, ..transmute([]byte)strings.to_string(sb))
		if e.is_file {
			if e.file.data != nil {
				// in-memory files (FormData blobs) obey the per-file limit as files on disk do
				if len(e.file.data) > s.upload_max_file { delete(out); return nil, false, fmt.aprintf("%s is larger than forms.upload.max_file_bytes", e.file.name) }
				append(&out, ..e.file.data)
				total += len(e.file.data)
			} else if e.file.path != "" {
				data, rok, msg := read(e.file.path, s.upload_max_file, user)
				if !rok { delete(out); return nil, false, msg }
				total += len(data)
				append(&out, ..data)
				delete(data)
			}
			if total > s.upload_max_total {
				delete(out)
				return nil, false, fmt.aprintf("the files of this form exceed forms.upload.max_total_bytes")
			}
		} else {
			append(&out, ..transmute([]byte)crlf(e.value))
		}
		append(&out, '\r', '\n')
	}
	strings.builder_reset(&sb)
	strings.write_string(&sb, "--")
	strings.write_string(&sb, boundary)
	strings.write_string(&sb, "--\r\n")
	append(&out, ..transmute([]byte)strings.to_string(sb))
	return out[:], true, ""
}

// Does the list carry files whose bytes still have to be read from disk?
needs_file_reads :: proc(list: []Entry) -> bool {
	for e in list { if e.is_file && e.file.data == nil && e.file.path != "" { return true } }
	return false
}

// Encodes a submission's body (POST). Multipart bodies with files on disk read them: call it off the UI thread for those.
encode_submission :: proc(sub: ^Submission, s: Settings, read: Read_File_Proc = read_file_default, user: rawptr = nil) -> (ok: bool, message: string) {
	switch sub.enctype {
	case .Urlencoded:
		sub.body = transmute([]byte)urlencode(sub.entries[:])
		sub.content_type = strings.clone("application/x-www-form-urlencoded")
	case .Text_Plain:
		sub.body = transmute([]byte)text_plain(sub.entries[:])
		sub.content_type = strings.clone("text/plain")
	case .Multipart:
		if sub.boundary == "" { sub.boundary = make_boundary() }
		body, bok, msg := multipart(sub.entries[:], sub.boundary, s, read, user)
		if !bok { return false, msg }
		sub.body = body
		sub.content_type = strings.concatenate({"multipart/form-data; boundary=", sub.boundary})
	}
	return true, ""
}

////////////////////////////////
// The submission algorithm

@(private)
replace_query :: proc(action: string, query: string) -> string {
	u, ok := url.parse_absolute(action, context.temp_allocator)
	if !ok { return action }
	base_end := len(u.href)
	if u.has_fragment { base_end -= len(u.fragment) + 1 }
	head := u.href[:base_end]
	if u.has_query { head = head[:len(head) - len(u.query) - 1] }
	frag := u.has_fragment ? strings.concatenate({"#", u.fragment}, context.temp_allocator) : ""
	return strings.concatenate({head, "?", query, frag}, context.temp_allocator)
}

// Statically validates the form's controls; on failure reports the first unhandled problem. True when the form may go.
interactively_validate :: proc(f: ^Forms, form: base.Handle) -> bool {
	for e in form_submittables(f, form) { if c := control_of(f, e); c != nil { c.user_validity = true } }
	invalid := make([dynamic]base.Handle, context.temp_allocator)
	for e in form_submittables(f, form) { if is_invalid_candidate(f, e) { append(&invalid, e) } }
	changed_widely(f)
	if len(invalid) == 0 { return true }
	first := base.NIL_HANDLE
	for e in invalid {
		if fire(f, e, "invalid", cancelable = true) && first == base.NIL_HANDLE { first = e }
	}
	if first != base.NIL_HANDLE { show_report(f, first) }
	return false
}

// requestSubmit(submitter): the submitter, when given, must be a submit button owned by the form.
request_submit :: proc(f: ^Forms, form, submitter: base.Handle) -> Error {
	if kind(f, form) != .Form { return .Invalid_Handle }
	if submitter != base.NIL_HANDLE {
		if !is_submit_button(f, submitter) { return .Not_Supported }       // TypeError
		if form_owner(f, submitter) != form { return .Not_Allowed }        // NotFoundError
	}
	submit(f, form, submitter)
	return .None
}

// Submits `form` (§4.10.21.3). `from_method` is form.submit(): no validation, no submit event.
submit :: proc(f: ^Forms, form: base.Handle, submitter: base.Handle, from_method := false) {
	if kind(f, form) != .Form || !is_connected(f, form) { return }
	fc := control_of(f, form)
	if fc.constructing_entries { return }
	if !from_method {
		if fc.firing_submission { return }
		fc.firing_submission = true
		if !no_validate(f, form, submitter) && !interactively_validate(f, form) {
			if c := control_peek(f, form); c != nil { c.firing_submission = false }
			return
		}
		go_on := fire(f, form, "submit", bubbles = true, cancelable = true, object = u64(submitter))
		if c := control_peek(f, form); c != nil { c.firing_submission = false }
		if !go_on || !is_connected(f, form) { return }
	}
	charset := pick_charset(f, form)
	list, ok := construct_entry_list(f, form, submitter, charset)
	if !ok { return }
	if !is_connected(f, form) { entries_destroy(&list); return }
	method := method_of(f, form, submitter)

	if method == .Dialog {
		entries_destroy(&list)
		dialog := base.NIL_HANDLE
		for p := parent_element(f, form); p != base.NIL_HANDLE; p = parent_element(f, p) { if kind(f, p) == .Dialog { dialog = p; break } }
		if dialog == base.NIL_HANDLE { return }
		result := ""
		has_result := false
		if submitter != base.NIL_HANDLE {
			if input_type(f, submitter) == .Image && kind(f, submitter) == .Input {
				c := control_of(f, submitter)
				result = fmt.tprintf("%d,%d", c.image_coords.x, c.image_coords.y)
			} else {
				result = value(f, submitter)
			}
			has_result = true
		}
		close_dialog(f, dialog, result, has_result)
		return
	}

	action, aok := action_of(f, form, submitter)
	if !aok { entries_destroy(&list); return }
	u, uok := url.parse_absolute(action, context.temp_allocator)
	if !uok { entries_destroy(&list); return }
	target, _ := form_attr(f, form, submitter, "formtarget", "target")
	enctype := enctype_of(f, form, submitter)

	sub := new(Submission)
	sub.form, sub.submitter, sub.method, sub.enctype = form, submitter, method, enctype
	sub.target = strings.clone(target)
	sub.charset = strings.clone(charset)
	sub.scheme = strings.clone(u.scheme)
	sub.no_opener = has_attr(element(f, form), "rel") && strings.contains(strings.to_lower(attr_or(element(f, form), "rel"), context.temp_allocator), "noopener")

	switch u.scheme {
	case "javascript":
		// no JavaScript in this browser: nothing to run
		entries_destroy(&list)
		submission_destroy(sub)
		return
	case "mailto":
		sub.mailto = true
		if method == .Get {
			// mail with headers: the query is the entry list, spaces as %20
			q := urlencode(list[:], context.temp_allocator)
			q, _ = strings.replace_all(q, "+", "%20", context.temp_allocator)
			sub.url = strings.clone(replace_query(action, q))
		} else {
			// mail as body
			body: string
			if enctype == .Text_Plain {
				sb := strings.builder_make(context.temp_allocator)
				urlencode_into(&sb, text_plain(list[:], context.temp_allocator), false)
				body = strings.to_string(sb)
			} else {
				body = urlencode(list[:], context.temp_allocator)
			}
			sep := u.has_query ? "&" : "?"
			head := u.href
			if u.has_fragment { head = head[:len(head) - len(u.fragment) - 1] }
			sub.url = strings.concatenate({head, sep, "body=", body})
		}
		sub.method = .Get
		entries_destroy(&list)
	case:
		if method == .Get || u.scheme == "data" || (u.scheme != "http" && u.scheme != "https") {
			// mutate action URL: the query becomes the entry list (data: and other schemes always navigate with GET)
			sub.url = strings.clone(replace_query(action, urlencode(list[:], context.temp_allocator)))
			sub.method = .Get
			entries_destroy(&list)
		} else {
			// submit as entity body: encoded by the receiver (encode_submission) so file reads can leave the UI thread
			sub.url = strings.clone(action)
			sub.entries = list
			if enctype == .Multipart { sub.boundary = make_boundary() }
		}
	}
	if f.host.navigate != nil { f.host.navigate(f.host.user, sub) } else { submission_destroy(sub) }
}

@(private)
attr_or :: proc(n: ^dom.Node, name: string) -> string {
	v, _ := attr(n, name)
	return v
}

// Closes a <dialog> with a return value (method=dialog submissions): `open` removed, `close` fired.
close_dialog :: proc(f: ^Forms, dialog: base.Handle, result: string, has_result: bool) {
	n := element(f, dialog)
	if n == nil || !has_attr(n, "open") { return }
	dom.remove_attribute(f.doc, dialog, "open")
	if c := control_of(f, dialog); c != nil && has_result { replace_owned(&c.return_value, result) }
	changed_widely(f)
	fire(f, dialog, "close")
}

dialog_return_value :: proc(f: ^Forms, dialog: base.Handle) -> string {
	c := control_peek(f, dialog)
	return c != nil ? c.return_value : ""
}
