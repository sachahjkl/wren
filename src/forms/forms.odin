// Package forms: HTML form controls (HTML Standard §4.10) as a model without a window: values and their sanitization,
// checkedness, option selectedness, constraint validation, text editing, activation behaviour, focus, reset and
// submission (form data set and its three encodings). The page wires it to the DOM events and the shell to the screen.
//
// State lives beside the DOM, keyed by node handle. A control gets a record the first time anything asks about it; the
// record starts from the content attributes (value, checked, selected, the textarea's text) and only diverges once a
// "dirty" flag is set, exactly as the specification describes. Attribute changes made while a control is not dirty are
// picked up on the next read (the record remembers what it last saw), so no mutation observer is needed. Records of nodes
// that were destroyed are dropped by `collect` (the page calls it when the DOM changed).
//
// Everything that leaves the package goes through `Host`: events (the page runs the guest's listeners), the document URL,
// planned navigations (the shell performs them later, outside any guest call) and style invalidation.
//
// Strings are UTF-8 internally. Positions exposed to the web API (selectionStart, maxlength...) are UTF-16 code units,
// as in JavaScript; `utf16_to_byte` / `byte_to_utf16` convert.
package forms

import "core:strings"
import "wb:base"
import "wb:dom"

Kind :: enum u8 { None, Input, Textarea, Select, Button, Option, Optgroup, Fieldset, Legend, Output, Form, Label, Object, Datalist, Dialog }

Input_Type :: enum u8 {
	Text, Search, Tel, Url, Email, Password, Date, Month, Week, Time, Datetime_Local, Number, Range, Color,
	Checkbox, Radio, File, Submit, Image, Reset, Button, Hidden,
}

Value_Mode :: enum u8 { Value, Default, Default_On, Filename }

Direction :: enum u8 { None, Forward, Backward }

File :: struct {
	path: string,   // owned: where the bytes are read from at submission ("" for an in-memory file)
	name: string,   // owned: the file name shown to the page
	mime: string,   // owned
	size: i64,
	data: []byte,   // owned: in-memory contents (FormData blobs); nil for files on disk
	modified_ms: f64,
}

Undo_Step :: struct {
	text:       string,   // owned: the edit text before the change
	sel_start:  int,
	sel_end:    int,
	kind:       u8,       // what kind of edit made it (consecutive typing merges)
	ms:         f64,
}

Control :: struct {
	node:            base.Handle,
	kind:            Kind,
	// value (input, textarea): `value` is meaningful when dirty_value; otherwise the default value is read from the DOM
	value:           string,
	dirty_value:     bool,
	user_edited:     bool,        // the value was last changed by the user (tooLong / tooShort only apply then)
	type_seen:       Input_Type,  // to apply the "type attribute changed" steps
	type_known:      bool,
	// what the user is typing in a field whose value is a parsed form (number, date...). Differs from `value` when it
	// does not parse (then value is "" and the field suffers from bad input).
	edit:            string,
	has_edit:        bool,
	// checkedness
	checked:         bool,
	dirty_checked:   bool,
	checked_attr:    bool,        // presence of the `checked` attribute when last looked at
	checked_init:    bool,
	checked_seq:     u64,         // when it last became checked (a radio group keeps the latest)
	indeterminate:   bool,
	// option selectedness
	selected:        bool,
	dirty_selected:  bool,
	selected_attr:   bool,
	selected_init:   bool,
	// files
	files:           [dynamic]File,
	// validation
	custom_error:    string,
	user_validity:   bool,        // :user-valid / :user-invalid apply
	// selection, in bytes of the edit text
	sel_start:       int,
	sel_end:         int,
	sel_dir:         Direction,
	undo:            [dynamic]Undo_Step,
	redo:            [dynamic]Undo_Step,
	value_at_focus:  string,      // change event: the value when the field got the focus
	changed_since_focus: bool,
	// form element flags
	firing_submission: bool,
	constructing_entries: bool,
	// dialog
	return_value:    string,
	style_bits:      Style_Bits,  // pseudo-class state last reported (style invalidation)
	style_known:     bool,
	image_coords:    [2]i32,      // last activation point of an image button
}

Submit_Method :: enum u8 { Get, Post, Dialog }

Enctype :: enum u8 { Urlencoded, Multipart, Text_Plain }

Entry :: struct {
	name:    string,   // owned
	value:   string,   // owned (string entries)
	is_file: bool,
	file:    File,     // owned (file entries)
}

// A planned navigation, produced by the submission algorithm. Owned by whoever receives it: `submission_destroy`.
Submission :: struct {
	form:         base.Handle,
	submitter:    base.Handle,
	method:       Submit_Method,
	url:          string,         // the action, with the query already replaced for GET
	enctype:      Enctype,
	content_type: string,         // for POST: the request's Content-Type ("" until encoded for multipart)
	body:         []byte,         // for POST, once encoded
	target:       string,
	charset:      string,
	entries:      [dynamic]Entry, // POST: what the body is made of (multipart bodies are encoded off the UI thread)
	boundary:     string,
	scheme:       string,         // of the action URL
	mailto:       bool,           // a mailto: action: hand the URL to the system
	dialog:       base.Handle,    // method dialog: the dialog that was closed
	no_opener:    bool,
}

Host :: struct {
	user:          rawptr,
	// Fires an event at a node and runs the listeners. Returns false when a listener cancelled it.
	dispatch:      proc(user: rawptr, target: base.Handle, ev: dom.Event) -> bool,
	document_url:  proc(user: rawptr) -> string,
	// A form submission wants to navigate. Ownership of `s` passes to the callee. Called synchronously; the embedder must
	// run the navigation later (it may be inside a guest call).
	navigate:      proc(user: rawptr, s: ^Submission),
	// Something a pseudo-class depends on changed: computed styles are stale.
	style_changed: proc(user: rawptr),
	// Optional: fire `formdata` at `form` with a FormData over `entries` (listeners may change them).
	formdata:      proc(user: rawptr, form: base.Handle, entries: ^[dynamic]Entry),
	now_ms:        proc(user: rawptr) -> f64,
	// The focused element changed (`by_keyboard`: :focus-visible).
	focus_changed: proc(user: rawptr, focus: base.Handle, by_keyboard: bool),
	// A trusted click on a file / color input: show the platform's picker, then call set_files / set_value.
	pick_files:    proc(user: rawptr, input: base.Handle),
	pick_color:    proc(user: rawptr, input: base.Handle),
	// Popovers (optional; the page's popover state): the activation of a button with `popovertarget`, a trusted click
	// that may light-dismiss showing popovers, and Escape as a close request (true when it hid one).
	popover_invoke:  proc(user: rawptr, invoker: base.Handle),
	popover_dismiss: proc(user: rawptr, target: base.Handle),
	close_request:   proc(user: rawptr) -> bool,
	// A dialog closes; whether a modal dialog makes an element inert (no focus by Tab). Optional.
	dialog_closed:   proc(user: rawptr, dialog: base.Handle),
	queue_close:     proc(user: rawptr, dialog: base.Handle),   // "close" is fired from a task (at once without this)
	inert:           proc(user: rawptr, h: base.Handle) -> bool,
	// The activation of a link (<a> / <area> with href) clicked by a script (element.click(), a dispatched click): the
	// page follows it. A user's click is the embedder's (it follows links itself). Optional.
	follow_link:     proc(user: rawptr, link: base.Handle),
}

Report :: struct {
	node:    base.Handle,
	message: string,   // owned
	until:   f64,      // ms (host clock)
}

Forms :: struct {
	doc:          ^dom.Document,
	settings:     ^Settings,
	host:         Host,
	controls:     map[base.Handle]^Control,
	focus:        base.Handle,
	seen_mutations: u64,
	serial:       u64,           // bumped whenever something a control shows changed: the painter compares it
	report:       Report,        // the validation bubble to show (reportValidity / interactive validation)
	radio_cache:  map[Radio_Key][dynamic]base.Handle,
	radio_cache_at: u64,
	radio_cache_valid: bool,
	id:           u64,           // unique per Forms (callers that outlive a page compare it)
	in_activation: int,          // nested activation depth (a label's synthetic click must not loop)
	focus_by_key: bool,          // the focus came from the keyboard (:focus-visible)
	seq:          u64,
	patterns:     map[string]^Regex,   // compiled `pattern` attributes (nil: invalid), keyed by source
}

Radio_Key :: struct { owner: base.Handle, name: string }

@(private)
next_id: u64

forms_create :: proc(doc: ^dom.Document, settings: ^Settings, host: Host) -> ^Forms {
	f := new(Forms)
	f.doc = doc
	f.settings = settings
	f.host = host
	f.controls = make(map[base.Handle]^Control)
	f.radio_cache = make(map[Radio_Key][dynamic]base.Handle)
	next_id += 1
	f.id = next_id
	return f
}

forms_destroy :: proc(f: ^Forms) {
	if f == nil { return }
	for _, c in f.controls { control_free(c) }
	delete(f.controls)
	clear_radio_cache(f)
	delete(f.radio_cache)
	clear_patterns(f)
	delete(f.patterns)
	delete(f.report.message)
	free(f)
}

@(private)
clear_radio_cache :: proc(f: ^Forms) {
	for k, v in f.radio_cache { delete(k.name); delete(v) }
	clear(&f.radio_cache)
	f.radio_cache_valid = false
}

file_destroy :: proc(fl: ^File) {
	delete(fl.path); delete(fl.name); delete(fl.mime); delete(fl.data)
	fl^ = {}
}

file_clone :: proc(fl: File) -> File {
	out := fl
	out.path = strings.clone(fl.path)
	out.name = strings.clone(fl.name)
	out.mime = strings.clone(fl.mime)
	if fl.data != nil { out.data = make([]byte, len(fl.data)); copy(out.data, fl.data) }
	return out
}

entry_destroy :: proc(e: ^Entry) {
	delete(e.name); delete(e.value)
	if e.is_file { file_destroy(&e.file) }
	e^ = {}
}

entry_clone :: proc(e: Entry) -> Entry {
	out := Entry{name = strings.clone(e.name), value = strings.clone(e.value), is_file = e.is_file}
	if e.is_file { out.file = file_clone(e.file) }
	return out
}

entries_destroy :: proc(list: ^[dynamic]Entry) {
	for &e in list { entry_destroy(&e) }
	delete(list^)
	list^ = nil
}

submission_destroy :: proc(s: ^Submission) {
	if s == nil { return }
	delete(s.url); delete(s.content_type); delete(s.body); delete(s.target); delete(s.charset); delete(s.boundary); delete(s.scheme)
	entries_destroy(&s.entries)
	free(s)
}

@(private)
undo_clear :: proc(list: ^[dynamic]Undo_Step) {
	for u in list { delete(u.text) }
	clear(list)
}

@(private)
control_free :: proc(c: ^Control) {
	delete(c.value); delete(c.edit); delete(c.custom_error); delete(c.value_at_focus); delete(c.return_value)
	for &fl in c.files { file_destroy(&fl) }
	delete(c.files)
	undo_clear(&c.undo); delete(c.undo)
	undo_clear(&c.redo); delete(c.redo)
	free(c)
}

// Drops the records of nodes that no longer exist and forgets cached groupings. Cheap when nothing changed; the page
// calls it after DOM mutations.
collect :: proc(f: ^Forms) {
	if f.seen_mutations == f.doc.mutations { return }
	f.seen_mutations = f.doc.mutations
	clear_radio_cache(f)
	dead := make([dynamic]base.Handle, context.temp_allocator)
	for h, _ in f.controls { if dom.get(f.doc, h) == nil { append(&dead, h) } }
	for h in dead {
		control_free(f.controls[h])
		delete_key(&f.controls, h)
	}
	if f.focus != base.NIL_HANDLE && !is_connected(f, f.focus) { f.focus = base.NIL_HANDLE }
	if f.report.node != base.NIL_HANDLE && dom.get(f.doc, f.report.node) == nil { f.report.node = base.NIL_HANDLE }
}

// The record of an element that has form state (creates it). nil for nodes that are not elements.
control_of :: proc(f: ^Forms, h: base.Handle) -> ^Control {
	if c, ok := f.controls[h]; ok {
		if dom.get(f.doc, h) == nil { return nil }
		return c
	}
	n := dom.get(f.doc, h)
	if n == nil || n.kind != .Element { return nil }
	c := new(Control)
	c.node = h
	c.kind = kind_of(n)
	f.controls[h] = c
	return c
}

// The record if one exists, without creating it.
control_peek :: proc(f: ^Forms, h: base.Handle) -> ^Control {
	c, _ := f.controls[h]
	return c
}

@(private)
now :: proc(f: ^Forms) -> f64 {
	if f.host.now_ms != nil { return f.host.now_ms(f.host.user) }
	return 0
}

@(private)
fire :: proc(f: ^Forms, target: base.Handle, type: string, bubbles := false, cancelable := false, data := "", text := "", object: u64 = 0, x: f64 = 0, y: f64 = 0, code: i64 = 0, related: u64 = 0) -> bool {
	if f.host.dispatch == nil { return true }
	// `related`: the relatedTarget (focus events), retargeted along the path by the dispatch
	return f.host.dispatch(f.host.user, target, dom.Event{type = type, bubbles = bubbles, cancelable = cancelable, data = data, text = text, object = object, x = x, y = y, code = code, related = related})
}

// Something visible changed (value, caret, checkedness...): the painter redraws, and styles are recomputed when a
// pseudo-class of the control (or of its form) may have changed.
changed :: proc(f: ^Forms, h: base.Handle) {
	f.serial += 1
	c := control_peek(f, h)
	if c == nil { return }
	bits := style_bits(f, h)
	if !c.style_known || bits != c.style_bits {
		c.style_known = true
		c.style_bits = bits
		if f.host.style_changed != nil { f.host.style_changed(f.host.user) }
	}
}

// Changes that can reach other elements' pseudo-classes (radio groups, :default buttons, form validity).
@(private)
changed_widely :: proc(f: ^Forms) {
	f.serial += 1
	if f.host.style_changed != nil { f.host.style_changed(f.host.user) }
}
