package forms

import "core:strings"
import "core:unicode/utf8"
import "wb:base"
import "wb:dom"

// Values (§4.10.5 value modes and sanitization, §4.10.11 textarea), checkedness (with radio groups), option selectedness
// (§4.10.7 selectedness setting algorithm) and files.

Error :: enum i32 {
	None              = 0,
	Invalid_Handle    = -1,
	Not_Supported     = -4,   // the attribute does not apply to this control (the web API throws or ignores)
	Invalid_State     = -11,  // InvalidStateError
	Index_Size        = -12,  // IndexSizeError
	Not_Allowed       = -13,
}

value_mode :: proc(t: Input_Type) -> Value_Mode {
	#partial switch t {
	case .Hidden, .Submit, .Image, .Reset, .Button: return .Default
	case .Checkbox, .Radio: return .Default_On
	case .File: return .Filename
	}
	return .Value
}

////////////////////////////////
// Text utilities

@(private)
strip_newlines :: proc(s: string) -> string {
	if strings.index_any(s, "\r\n") < 0 { return s }
	sb := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) { if s[i] != '\r' && s[i] != '\n' { strings.write_byte(&sb, s[i]) } }
	return strings.to_string(sb)
}

@(private)
is_ascii_ws :: #force_inline proc(c: u8) -> bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' }

trim_ascii_ws :: proc(s: string) -> string {
	a, b := 0, len(s)
	for a < b && is_ascii_ws(s[a]) { a += 1 }
	for b > a && is_ascii_ws(s[b - 1]) { b -= 1 }
	return s[a:b]
}

// "Strip and collapse ASCII whitespace".
collapse_ws :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	pending := false
	for i in 0 ..< len(s) {
		if is_ascii_ws(s[i]) { pending = strings.builder_len(sb) > 0; continue }
		if pending { strings.write_byte(&sb, ' '); pending = false }
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
}

// CR LF and lone CR become LF (textarea API value, typed text).
normalize_newlines :: proc(s: string, allocator := context.temp_allocator) -> string {
	if strings.index_byte(s, '\r') < 0 { return s }
	sb := strings.builder_make(allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\r' {
			strings.write_byte(&sb, '\n')
			if i + 1 < len(s) && s[i + 1] == '\n' { i += 1 }
			continue
		}
		strings.write_byte(&sb, s[i])
	}
	return strings.to_string(sb)
}

// Number of UTF-16 code units (JavaScript's length).
utf16_len :: proc(s: string) -> int {
	n := 0
	for r in s { n += r >= 0x10000 ? 2 : 1 }
	return n
}

// Byte offset of UTF-16 position `u` (clamped; a position inside a surrogate pair goes before the character).
utf16_to_byte :: proc(s: string, u: int) -> int {
	if u <= 0 { return 0 }
	n := 0
	for r, i in s {
		w := r >= 0x10000 ? 2 : 1
		if n + w > u { return i }
		n += w
		if n == u { return i + utf8.rune_size(r) }
	}
	return len(s)
}

byte_to_utf16 :: proc(s: string, b: int) -> int {
	n := 0
	for r, i in s {
		if i >= b { break }
		n += r >= 0x10000 ? 2 : 1
	}
	return n
}

// Cuts `s` to at most `max_bytes` on a character boundary.
@(private)
cap_bytes :: proc(s: string, max_bytes: int) -> string {
	if len(s) <= max_bytes { return s }
	end := max_bytes
	for end > 0 && (s[end] & 0xC0) == 0x80 { end -= 1 }
	return s[:end]
}

// The first `units` UTF-16 code units of s.
@(private)
cap_utf16 :: proc(s: string, units: int) -> string { return s[:utf16_to_byte(s, units)] }

@(private)
replace_owned :: proc(dst: ^string, s: string) {
	if dst^ == s { return }
	old := dst^
	dst^ = strings.clone(s)
	delete(old)
}

////////////////////////////////
// Sanitization (§4.10.5.1.x)

@(private)
is_valid_email :: proc(s: string) -> bool {
	at := strings.index_byte(s, '@')
	if at <= 0 || at == len(s) - 1 { return false }
	local, domain := s[:at], s[at + 1:]
	for c in transmute([]u8)local {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || is_digit(c) || strings.index_byte(".!#$%&'*+/=?^_`{|}~-", c) >= 0
		if !ok { return false }
	}
	labels := domain
	for label in strings.split_iterator(&labels, ".") {
		if len(label) == 0 || len(label) > 63 { return false }
		if label[0] == '-' || label[len(label) - 1] == '-' { return false }
		for c in transmute([]u8)label {
			if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || is_digit(c) || c == '-') { return false }
		}
	}
	return true
}

@(private)
is_valid_simple_color :: proc(s: string) -> bool {
	if len(s) != 7 || s[0] != '#' { return false }
	for c in transmute([]u8)s[1:] {
		if !(is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) { return false }
	}
	return true
}

// The value sanitization algorithm of input type `t`. `n` gives the attributes (multiple, min, max, step).
sanitize :: proc(f: ^Forms, n: ^dom.Node, t: Input_Type, s: string) -> string {
	#partial switch t {
	case .Text, .Search, .Tel, .Password: return strip_newlines(s)
	case .Url: return trim_ascii_ws(strip_newlines(s))
	case .Email:
		v := strip_newlines(s)
		if !has_attr(n, "multiple") { return trim_ascii_ws(v) }
		sb := strings.builder_make(context.temp_allocator)
		parts := v
		first := true
		for part in strings.split_iterator(&parts, ",") {
			if !first { strings.write_byte(&sb, ',') }
			first = false
			strings.write_string(&sb, trim_ascii_ws(part))
		}
		return strings.to_string(sb)
	case .Number: return is_valid_float(s) ? s : ""
	case .Range:
		v, ok := parse_float(s)
		lim := limits(f, n, t)
		if !ok { v = range_default(lim) }
		if lim.has_min && v < lim.min { v = lim.min }
		if lim.has_max && lim.max >= lim.min && v > lim.max { v = lim.max }
		if st, has := allowed_step(f, n, t); has {
			base := step_base(f, n, t)
			k := (v - base) / st
			if !is_integral(k) {
				r := round_half_up(k)
				nv := base + r * st
				if lim.has_max && nv > lim.max { nv = base + (r - 1) * st }
				v = nv
			}
		}
		return format_float(v)
	case .Date, .Month, .Week, .Time:
		if _, ok := number_from_string(t, s); ok { return s }
		return ""
	case .Datetime_Local:
		ms, ok := parse_datetime_local(s)
		if !ok { return "" }
		return format_datetime_local(ms)   // normalized: 'T', shortest time
	case .Color:
		if is_valid_simple_color(s) { return strings.to_lower(s, context.temp_allocator) }
		return "#000000"
	}
	return s
}

////////////////////////////////
// Default values

// The textarea's child text content (Text children only).
@(private)
child_text :: proc(f: ^Forms, h: base.Handle) -> string {
	n := dom.get(f.doc, h)
	if n == nil { return "" }
	sb := strings.builder_make(context.temp_allocator)
	for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(f.doc, ch).next {
		cn := dom.get(f.doc, ch)
		if cn.kind == .Text { strings.write_string(&sb, cn.text) }
	}
	return strings.to_string(sb)
}

default_value :: proc(f: ^Forms, h: base.Handle) -> string {
	n := element(f, h)
	#partial switch kind_of(n) {
	case .Input:
		v, _ := attr(n, "value")
		return v
	case .Textarea: return child_text(f, h)
	case .Output: return dom.text_content(f.doc, h)
	}
	return ""
}

set_default_value :: proc(f: ^Forms, h: base.Handle, v: string) -> Error {
	n := element(f, h)
	#partial switch kind_of(n) {
	case .Input: dom.set_attribute(f.doc, h, "value", v)
	case .Textarea: dom.set_text_content(f.doc, h, v)
	case .Output: dom.set_text_content(f.doc, h, v)
	case: return .Not_Supported
	}
	changed(f, h)
	return .None
}

// Applies "the type attribute changed" steps when the type differs from the one seen last (value mode transitions).
@(private)
sync_type :: proc(f: ^Forms, c: ^Control, n: ^dom.Node) {
	t := input_type_of(n)
	if c.type_known && c.type_seen == t { return }
	if c.type_known {
		old_mode := value_mode(c.type_seen)
		new_mode := value_mode(t)
		if old_mode == .Value && new_mode != .Value {
			// the value is kept in the `value` attribute when it was dirty
			if c.dirty_value && c.value != "" && (new_mode == .Default || new_mode == .Default_On) { dom.set_attribute(f.doc, c.node, "value", c.value) }   // (HTML: only a non-empty value)
		} else if old_mode != .Value && new_mode == .Value {
			v, _ := attr(n, "value")
			replace_owned(&c.value, v)
			c.dirty_value = false
		} else if old_mode != .Filename && new_mode == .Filename {
			replace_owned(&c.value, "")
		}
		if c.dirty_value { replace_owned(&c.value, cap_bytes(sanitize(f, n, t, c.value), f.settings.max_value_bytes)) }
		if new_mode != .Filename { for &fl in c.files { file_destroy(&fl) }; clear(&c.files) }
		c.has_edit = false
		c.sel_start, c.sel_end = 0, 0
	}
	c.type_seen = t
	c.type_known = true
}

////////////////////////////////
// value

// The value IDL attribute of any control.
value :: proc(f: ^Forms, h: base.Handle) -> string {
	n := element(f, h)
	switch kind_of(n) {
	case .Input:
		c := control_of(f, h)
		sync_type(f, c, n)
		t := c.type_seen
		switch value_mode(t) {
		case .Value:
			if c.dirty_value { return c.value }
			v, _ := attr(n, "value")
			return cap_bytes(sanitize(f, n, t, v), f.settings.max_value_bytes)
		case .Default:
			v, _ := attr(n, "value")
			return v
		case .Default_On:
			v, ok := attr(n, "value")
			return ok ? v : "on"
		case .Filename:
			if len(c.files) == 0 { return "" }
			return strings.concatenate({"C:\\fakepath\\", c.files[0].name}, context.temp_allocator)
		}
	case .Textarea:
		c := control_of(f, h)
		if c.dirty_value { return c.value }
		return cap_bytes(normalize_newlines(child_text(f, h)), f.settings.max_value_bytes)
	case .Select:
		for o in select_options_synced(f, h) { if option_selected_raw(f, o) { return option_value(f, o) } }
		return ""
	case .Option: return option_value(f, h)
	case .Button:
		v, _ := attr(n, "value")
		return v
	case .Output: return dom.text_content(f.doc, h)
	case .None, .Optgroup, .Fieldset, .Legend, .Form, .Label, .Object, .Datalist, .Dialog:
	}
	return ""
}

// Sets the value as a script does (value IDL setter). `by_user` marks a user edit (constraint rules differ).
set_value :: proc(f: ^Forms, h: base.Handle, v: string, by_user := false) -> Error {
	n := element(f, h)
	switch kind_of(n) {
	case .Input:
		c := control_of(f, h)
		sync_type(f, c, n)
		t := c.type_seen
		switch value_mode(t) {
		case .Value:
			old := strings.clone(value(f, h), context.temp_allocator)
			nv := cap_bytes(sanitize(f, n, t, v), f.settings.max_value_bytes)
			replace_owned(&c.value, nv)
			c.dirty_value = true
			c.user_edited = by_user
			c.has_edit = false
			if !by_user { undo_clear(&c.undo); undo_clear(&c.redo) }
			if old != nv {
				end := len(nv)
				c.sel_start, c.sel_end, c.sel_dir = end, end, .None
			}
		case .Default, .Default_On:
			dom.set_attribute(f.doc, h, "value", v)
		case .Filename:
			if v != "" { return .Invalid_State }
			for &fl in c.files { file_destroy(&fl) }
			clear(&c.files)
		}
		changed(f, h)
	case .Textarea:
		c := control_of(f, h)
		old := strings.clone(value(f, h), context.temp_allocator)
		nv := cap_bytes(normalize_newlines(v), f.settings.max_value_bytes)
		replace_owned(&c.value, nv)
		c.dirty_value = true
		c.user_edited = by_user
		if !by_user { undo_clear(&c.undo); undo_clear(&c.redo) }
		if old != nv { c.sel_start, c.sel_end, c.sel_dir = len(nv), len(nv), .None }
		changed(f, h)
	case .Select:
		found := false
		for o in select_options_synced(f, h) {
			oc := control_of(f, o)
			oc.selected = !found && option_value(f, o) == v
			oc.dirty_selected = true
			if oc.selected { found = true }
		}
		select_run_selectedness(f, h, false)
		changed_widely(f)
	case .Option, .Button:
		dom.set_attribute(f.doc, h, "value", v)
		changed(f, h)
	case .Output:
		dom.set_text_content(f.doc, h, v)
	case .None, .Optgroup, .Fieldset, .Legend, .Form, .Label, .Object, .Datalist, .Dialog:
		return .Not_Supported
	}
	return .None
}

// What a text field shows and edits: the value, or what the user is typing when it does not parse yet.
edit_text :: proc(f: ^Forms, h: base.Handle) -> string {
	c := control_of(f, h)
	if c == nil { return "" }
	if c.has_edit { return c.edit }
	return value(f, h)
}

// True when the field is a text field the user types into (text-like, date-like typed as text, number, color hex).
is_text_field :: proc(f: ^Forms, h: base.Handle) -> bool {
	n := element(f, h)
	#partial switch kind_of(n) {
	case .Textarea: return true
	case .Input: return input_type_of(n) in TYPED
	}
	return false
}

// Replaces what the user is typing. For parsed types the value follows when the text parses (bad input otherwise).
@(private)
set_edit_text :: proc(f: ^Forms, h: base.Handle, text: string) {
	n := element(f, h)
	c := control_of(f, h)
	t := Input_Type.Text
	if kind_of(n) == .Input { sync_type(f, c, n); t = c.type_seen }
	capped := cap_bytes(text, f.settings.max_value_bytes)
	if kind_of(n) == .Textarea || t in TEXT_LIKE {
		replace_owned(&c.value, kind_of(n) == .Textarea ? capped : sanitize(f, n, t, capped))
		c.dirty_value = true
		c.has_edit = false
	} else {
		replace_owned(&c.edit, capped)
		c.has_edit = true
		parsed := sanitize(f, n, t, capped)
		accepted := parsed
		if t == .Color && !is_valid_simple_color(capped) { accepted = "" }   // a half-typed color keeps the old value
		if t == .Color && accepted == "" { accepted = value(f, h) }
		replace_owned(&c.value, accepted)
		c.dirty_value = true
	}
	c.user_edited = true
}

// The field suffers from bad input: the user typed something its type cannot represent.
bad_input :: proc(f: ^Forms, h: base.Handle) -> bool {
	c := control_peek(f, h)
	if c == nil || !c.has_edit || c.edit == "" { return false }
	t := input_type(f, h)
	if t == .Color { return !is_valid_simple_color(c.edit) }
	return sanitize(f, element(f, h), t, c.edit) == "" || (t == .Number && !is_valid_float(c.edit))
}

////////////////////////////////
// Checkedness

// Initializes and reconciles a checkbox/radio's checkedness with its `checked` attribute (as the attribute change steps
// would have), then for radios makes sure at most one of the group is checked.
@(private)
sync_checked :: proc(f: ^Forms, h: base.Handle, n: ^dom.Node, c: ^Control) {
	present := has_attr(n, "checked")
	if !c.checked_init {
		c.checked_init = true
		c.checked = present
		c.checked_attr = present
		if present { f.serial += 1; c.checked_seq = next_seq(f) }
	} else if present != c.checked_attr {
		c.checked_attr = present
		if !c.dirty_checked {
			c.checked = present
			if present { c.checked_seq = next_seq(f) }
		}
	}
}

@(private)
next_seq :: proc(f: ^Forms) -> u64 {
	f.seq += 1
	return f.seq
}

// Resolves a radio group: initializes every member (tree order, so with several `checked` attributes the last one wins,
// as the parser would leave it) and keeps only the most recently checked one.
@(private)
sync_radio_group :: proc(f: ^Forms, h: base.Handle) {
	group := radio_group(f, h)
	if len(group) == 0 {
		if c := control_of(f, h); c != nil { sync_checked(f, h, element(f, h), c) }
		return
	}
	best: ^Control
	count := 0
	for g in group {
		gc := control_of(f, g)
		sync_checked(f, g, element(f, g), gc)
		if gc.checked {
			count += 1
			if best == nil || gc.checked_seq > best.checked_seq { best = gc }
		}
	}
	if count > 1 {
		for g in group {
			gc := control_of(f, g)
			if gc != best && gc.checked { gc.checked = false }
		}
	}
}

checked :: proc(f: ^Forms, h: base.Handle) -> bool {
	n := element(f, h)
	if kind_of(n) != .Input { return false }
	t := input_type_of(n)
	if t != .Checkbox && t != .Radio { return false }
	c := control_of(f, h)
	if t == .Radio { sync_radio_group(f, h) } else { sync_checked(f, h, n, c) }
	return c.checked
}

// checked IDL setter (and user toggling): sets the dirty checkedness flag; a radio unchecks the rest of its group.
set_checked :: proc(f: ^Forms, h: base.Handle, v: bool, dirty := true) -> Error {
	n := element(f, h)
	if kind_of(n) != .Input { return .Not_Supported }
	t := input_type_of(n)
	c := control_of(f, h)
	if t == .Radio { sync_radio_group(f, h) } else { sync_checked(f, h, n, c) }
	c.checked = v
	if dirty { c.dirty_checked = true }
	if v {
		c.checked_seq = next_seq(f)
		if t == .Radio {
			for g in radio_group(f, h) {
				if g == h { continue }
				gc := control_of(f, g)
				gc.checked = false
			}
		}
	}
	changed(f, h)
	changed_widely(f)
	return .None
}

default_checked :: proc(f: ^Forms, h: base.Handle) -> bool { return has_attr(element(f, h), "checked") }

set_default_checked :: proc(f: ^Forms, h: base.Handle, v: bool) {
	if v { dom.set_attribute(f.doc, h, "checked", "") } else { dom.remove_attribute(f.doc, h, "checked") }
	checked(f, h)   // apply the attribute change steps now
	changed_widely(f)
}

indeterminate :: proc(f: ^Forms, h: base.Handle) -> bool {
	c := control_peek(f, h)
	return c != nil && c.indeterminate
}

set_indeterminate :: proc(f: ^Forms, h: base.Handle, v: bool) {
	if c := control_of(f, h); c != nil { c.indeterminate = v; changed(f, h) }
}

////////////////////////////////
// Options

// option.value: the value attribute, else the text.
option_value :: proc(f: ^Forms, o: base.Handle) -> string {
	if v, ok := attr(element(f, o), "value"); ok { return v }
	return option_text(f, o)
}

// option.text: descendant text (script excluded), whitespace stripped and collapsed.
option_text :: proc(f: ^Forms, o: base.Handle) -> string {
	sb := strings.builder_make(context.temp_allocator)
	stack := make([dynamic]base.Handle, context.temp_allocator)
	append(&stack, o)
	for len(stack) > 0 {
		cur := pop(&stack)
		n := dom.get(f.doc, cur)
		if n == nil { continue }
		if n.kind == .Text { strings.write_string(&sb, n.text); continue }
		if n.kind == .Element && (n.name == "script") && cur != o { continue }
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(f.doc, ch).prev { append(&stack, ch) }
	}
	return collapse_ws(strings.to_string(sb))
}

option_label :: proc(f: ^Forms, o: base.Handle) -> string {
	if v, ok := attr(element(f, o), "label"); ok && v != "" { return v }
	return option_text(f, o)
}

@(private)
sync_option :: proc(f: ^Forms, o: base.Handle) -> ^Control {
	c := control_of(f, o)
	present := has_attr(element(f, o), "selected")
	if !c.selected_init {
		c.selected_init = true
		c.selected = present
		c.selected_attr = present
	} else if present != c.selected_attr {
		c.selected_attr = present
		if !c.dirty_selected { c.selected = present }
	}
	return c
}

@(private)
option_selected_raw :: proc(f: ^Forms, o: base.Handle) -> bool {
	c := control_peek(f, o)
	return c != nil && c.selected
}

// Size of the select's box in rows: `size`, else 4 for multiple and 1 otherwise.
display_size :: proc(f: ^Forms, sel: base.Handle) -> int {
	n := element(f, sel)
	if v, ok := attr(n, "size"); ok {
		x := 0
		s := trim_ascii_ws(v)
		valid := len(s) > 0
		for c in transmute([]u8)s { if !is_digit(c) { valid = false; break }; x = min(x * 10 + int(c - '0'), 1 << 20) }
		if valid && x > 0 { return x }
	}
	return has_attr(n, "multiple") ? 4 : 1
}

is_dropdown :: proc(f: ^Forms, sel: base.Handle) -> bool { return !has_attr(element(f, sel), "multiple") && display_size(f, sel) == 1 }

// The selectedness setting algorithm (§4.10.7): a single-selection drop-down always has exactly one option selected
// (the first enabled one by default); two or more selected options in a single select keep only the last.
@(private)
select_run_selectedness :: proc(f: ^Forms, sel: base.Handle, keep_first := false) {
	opts := select_options(f, sel)
	if has_attr(element(f, sel), "multiple") {
		for o in opts { sync_option(f, o) }
		return
	}
	selected := 0
	for o in opts { if sync_option(f, o).selected { selected += 1 } }
	if selected == 0 && display_size(f, sel) == 1 {
		for o in opts {
			if !is_disabled(f, o) { control_of(f, o).selected = true; return }
		}
	} else if selected > 1 {
		// keep the last selected (tree order)
		last := -1
		for o, i in opts { if control_of(f, o).selected { last = i } }
		if keep_first { for o, i in opts { if control_of(f, o).selected { last = i; break } } }
		for o, i in opts { if i != last { control_of(f, o).selected = false } }
	}
}

// The select's options with their selectedness up to date.
select_options_synced :: proc(f: ^Forms, sel: base.Handle) -> []base.Handle {
	select_run_selectedness(f, sel)
	return select_options(f, sel)
}

option_selected :: proc(f: ^Forms, o: base.Handle) -> bool {
	if sel := option_select(f, o); sel != base.NIL_HANDLE { select_run_selectedness(f, sel) }
	return sync_option(f, o).selected
}

// option.selected setter (and user choice): dirtiness set; in a single select the others are deselected.
set_option_selected :: proc(f: ^Forms, o: base.Handle, v: bool) {
	sel := option_select(f, o)
	if sel != base.NIL_HANDLE { select_run_selectedness(f, sel) }
	c := sync_option(f, o)
	c.selected = v
	c.dirty_selected = true
	if sel != base.NIL_HANDLE && v && !has_attr(element(f, sel), "multiple") {
		for other in select_options(f, sel) { if other != o { sync_option(f, other).selected = false } }
	}
	if sel != base.NIL_HANDLE { select_run_selectedness(f, sel) }
	changed_widely(f)
}

default_selected :: proc(f: ^Forms, o: base.Handle) -> bool { return has_attr(element(f, o), "selected") }

set_default_selected :: proc(f: ^Forms, o: base.Handle, v: bool) {
	if v { dom.set_attribute(f.doc, o, "selected", "") } else { dom.remove_attribute(f.doc, o, "selected") }
	option_selected(f, o)
	changed_widely(f)
}

selected_index :: proc(f: ^Forms, sel: base.Handle) -> int {
	for o, i in select_options_synced(f, sel) { if control_of(f, o).selected { return i } }
	return -1
}

set_selected_index :: proc(f: ^Forms, sel: base.Handle, index: int) {
	opts := select_options_synced(f, sel)
	for o, i in opts {
		c := control_of(f, o)
		c.selected = i == index
		c.dirty_selected = true
	}
	select_run_selectedness(f, sel)
	changed_widely(f)
}

option_index :: proc(f: ^Forms, o: base.Handle) -> int {
	sel := option_select(f, o)
	if sel == base.NIL_HANDLE { return 0 }
	for x, i in select_options(f, sel) { if x == o { return i } }
	return 0
}

////////////////////////////////
// Files

files :: proc(f: ^Forms, h: base.Handle) -> []File {
	c := control_peek(f, h)
	if c == nil || input_type(f, h) != .File { return nil }
	return c.files[:]
}

// Replaces the selection of a file input from a script (input.files = dataTransfer.files): no event. Takes ownership
// of `list`'s contents.
set_files_quiet :: proc(f: ^Forms, h: base.Handle, list: []File) {
	c := control_of(f, h)
	if c == nil { for &fl in list { file_destroy(&fl) }; return }
	for &fl in c.files { file_destroy(&fl) }
	clear(&c.files)
	keep := min(len(list), f.settings.upload_max_files)
	for i in 0 ..< len(list) {
		if i < keep { append(&c.files, list[i]) } else { file_destroy(&list[i]) }
	}
	changed(f, h)
}

// Replaces the selection of a file input (the shell's file dialog). Takes ownership of `list`'s contents. Fires input
// and change when the selection differs.
set_files :: proc(f: ^Forms, h: base.Handle, list: []File) {
	c := control_of(f, h)
	if c == nil { for &fl in list { file_destroy(&fl) }; return }
	n := element(f, h)
	keep := len(list)
	if !has_attr(n, "multiple") { keep = min(keep, 1) }
	keep = min(keep, f.settings.upload_max_files)
	same := keep == len(c.files)
	if same { for i in 0 ..< keep { if c.files[i].path != list[i].path || c.files[i].name != list[i].name { same = false; break } } }
	for &fl in c.files { file_destroy(&fl) }
	clear(&c.files)
	for i in 0 ..< len(list) {
		if i < keep { append(&c.files, list[i]) } else { file_destroy(&list[i]) }
	}
	c.user_validity = true
	changed(f, h)
	if !same {
		fire(f, h, "input", bubbles = true)
		fire(f, h, "change", bubbles = true)
	} else {
		fire(f, h, "cancel", bubbles = true)
	}
}
