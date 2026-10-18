package forms

import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import "wb:base"

// Text editing of input and textarea fields: the selection, user edits with beforeinput / input events, undo / redo,
// clipboard, and the selection API (select, setSelectionRange, setRangeText). Internally positions are bytes of the
// edit text, always on character boundaries.

Edit_Kind :: enum u8 {
	Insert_Text, Insert_Line_Break, Insert_From_Paste, Insert_Replacement,
	Delete_Backward, Delete_Forward, Delete_Word_Backward, Delete_Word_Forward,
	Delete_Line_Backward, Delete_Line_Forward, Delete_By_Cut,
	History_Undo, History_Redo,
}

EDIT_INPUT_TYPES := [Edit_Kind]string{
	.Insert_Text = "insertText", .Insert_Line_Break = "insertLineBreak", .Insert_From_Paste = "insertFromPaste",
	.Insert_Replacement = "insertReplacementText",
	.Delete_Backward = "deleteContentBackward", .Delete_Forward = "deleteContentForward",
	.Delete_Word_Backward = "deleteWordBackward", .Delete_Word_Forward = "deleteWordForward",
	.Delete_Line_Backward = "deleteSoftLineBackward", .Delete_Line_Forward = "deleteSoftLineForward",
	.Delete_By_Cut = "deleteByCut", .History_Undo = "historyUndo", .History_Redo = "historyRedo",
}

Move_Unit :: enum u8 { Char, Word, Line_Edge, Line, Doc_Edge }

// The selection APIs apply to text, search, url, tel, password and textarea (not email or number, §4.10.5.2.10).
selection_applies :: proc(f: ^Forms, h: base.Handle) -> bool {
	n := element(f, h)
	#partial switch kind_of(n) {
	case .Textarea: return true
	case .Input:
		#partial switch input_type_of(n) { case .Text, .Search, .Url, .Tel, .Password: return true }
	}
	return false
}

@(private)
is_multiline :: proc(f: ^Forms, h: base.Handle) -> bool { return kind(f, h) == .Textarea }

// Clamps a byte position to the text and to a character boundary.
@(private)
snap :: proc(s: string, pos: int) -> int {
	p := clamp(pos, 0, len(s))
	for p > 0 && p < len(s) && (s[p] & 0xC0) == 0x80 { p -= 1 }
	return p
}

// Selection in bytes of the edit text (start <= end).
selection :: proc(f: ^Forms, h: base.Handle) -> (start, end: int, dir: Direction) {
	c := control_of(f, h)
	if c == nil { return }
	s := edit_text(f, h)
	return snap(s, c.sel_start), snap(s, c.sel_end), c.sel_dir
}

// The caret is the end of the selection the user is moving: `end` for forward, `start` for backward selections.
caret :: proc(f: ^Forms, h: base.Handle) -> int {
	a, b, d := selection(f, h)
	return d == .Backward ? a : b
}

set_selection :: proc(f: ^Forms, h: base.Handle, start, end: int, dir := Direction.None) {
	c := control_of(f, h)
	if c == nil { return }
	s := edit_text(f, h)
	a, b := snap(s, start), snap(s, end)
	if b < a { a = b }
	if c.sel_start != a || c.sel_end != b || c.sel_dir != dir {
		c.sel_start, c.sel_end, c.sel_dir = a, b, dir
		f.serial += 1
	}
}

// Moves the selection's moving end to `pos` (extend) or collapses there.
@(private)
place_caret :: proc(f: ^Forms, h: base.Handle, pos: int, extend: bool) {
	if !extend { set_selection(f, h, pos, pos); return }
	a, b, d := selection(f, h)
	anchor := d == .Backward ? b : a
	if pos < anchor { set_selection(f, h, pos, anchor, .Backward) } else { set_selection(f, h, anchor, pos, pos == anchor ? .None : .Forward) }
}

selected_text :: proc(f: ^Forms, h: base.Handle) -> string {
	a, b, _ := selection(f, h)
	s := edit_text(f, h)
	return s[a:b]
}

select_all :: proc(f: ^Forms, h: base.Handle) {
	set_selection(f, h, 0, len(edit_text(f, h)), .Forward)
}

////////////////////////////////
// Character and word boundaries

@(private)
prev_char :: proc(s: string, pos: int) -> int {
	if pos <= 0 { return 0 }
	p := pos - 1
	for p > 0 && (s[p] & 0xC0) == 0x80 { p -= 1 }
	return p
}

@(private)
next_char :: proc(s: string, pos: int) -> int {
	if pos >= len(s) { return len(s) }
	_, w := utf8.decode_rune_in_string(s[pos:])
	return pos + max(w, 1)
}

@(private)
rune_at :: proc(s: string, pos: int) -> rune {
	if pos >= len(s) { return -1 }
	r, _ := utf8.decode_rune_in_string(s[pos:])
	return r
}

@(private)
is_extend :: proc(r: rune) -> bool {
	return r == 0x200D || (r >= 0xFE00 && r <= 0xFE0F) || unicode.is_grapheme_extend(r) || unicode.is_emoji_modifier(r) || (r >= 0xE0020 && r <= 0xE007F)
}

// One user-perceived character back / forward (a base character with its combining marks, joiners and modifiers).
cluster_prev :: proc(s: string, pos: int) -> int {
	p := prev_char(s, pos)
	for p > 0 {
		r := rune_at(s, p)
		pr := rune_at(s, prev_char(s, p))
		if !is_extend(r) && pr != 0x200D { break }
		p = prev_char(s, p)
	}
	if p > 0 && rune_at(s, p) == '\n' && rune_at(s, prev_char(s, p)) == '\r' { p = prev_char(s, p) }
	return p
}

cluster_next :: proc(s: string, pos: int) -> int {
	p := next_char(s, pos)
	for p < len(s) {
		r := rune_at(s, p)
		if !is_extend(r) && rune_at(s, prev_char(s, p)) != 0x200D { break }
		p = next_char(s, p)
	}
	return p
}

@(private)
Char_Class :: enum u8 { Space, Word, Punct }

@(private)
char_class :: proc(r: rune) -> Char_Class {
	if r == ' ' || r == '\t' || r == '\n' || r == '\r' || unicode.is_space(r) { return .Space }
	if unicode.is_letter(r) || unicode.is_digit(r) || r == '_' || unicode.is_number(r) || is_extend(r) { return .Word }
	return .Punct
}

// Start of the previous word (Windows behaviour: skip spaces, then a run of the same class).
word_prev :: proc(s: string, pos: int) -> int {
	p := pos
	for p > 0 && char_class(rune_at(s, prev_char(s, p))) == .Space { p = prev_char(s, p) }
	if p == 0 { return 0 }
	cls := char_class(rune_at(s, prev_char(s, p)))
	for p > 0 && char_class(rune_at(s, prev_char(s, p))) == cls { p = prev_char(s, p) }
	return p
}

// Start of the next word: the run under the caret, then the spaces after it.
word_next :: proc(s: string, pos: int) -> int {
	p := pos
	if p >= len(s) { return len(s) }
	cls := char_class(rune_at(s, p))
	if cls != .Space { for p < len(s) && char_class(rune_at(s, p)) == cls { p = next_char(s, p) } }
	for p < len(s) && char_class(rune_at(s, p)) == .Space && rune_at(s, p) != '\n' { p = next_char(s, p) }
	return p
}

// The word around `pos` (double click).
word_at :: proc(s: string, pos: int) -> (start, end: int) {
	p := snap(s, pos)
	if p >= len(s) && p > 0 { p = prev_char(s, p) }
	if len(s) == 0 { return 0, 0 }
	cls := char_class(rune_at(s, p))
	start, end = p, p
	for start > 0 && char_class(rune_at(s, prev_char(s, start))) == cls { start = prev_char(s, start) }
	for end < len(s) && char_class(rune_at(s, end)) == cls { end = next_char(s, end) }
	return
}

@(private)
line_start :: proc(s: string, pos: int) -> int {
	p := pos
	for p > 0 && s[p - 1] != '\n' { p -= 1 }
	return p
}

@(private)
line_end :: proc(s: string, pos: int) -> int {
	p := pos
	for p < len(s) && s[p] != '\n' { p += 1 }
	return p
}

// Moves the caret (keyboard navigation). Collapsing a selection with Left/Right goes to its edge, as on Windows.
move_caret :: proc(f: ^Forms, h: base.Handle, unit: Move_Unit, dir: int, extend: bool) {
	s := edit_text(f, h)
	a, b, _ := selection(f, h)
	pos := caret(f, h)
	if !extend && a != b && unit == .Char {
		place_caret(f, h, dir < 0 ? a : b, false)
		return
	}
	target := pos
	switch unit {
	case .Char: target = dir < 0 ? cluster_prev(s, pos) : cluster_next(s, pos)
	case .Word: target = dir < 0 ? word_prev(s, pos) : word_next(s, pos)
	case .Line_Edge:
		if is_multiline(f, h) { target = dir < 0 ? line_start(s, pos) : line_end(s, pos) } else { target = dir < 0 ? 0 : len(s) }
	case .Doc_Edge: target = dir < 0 ? 0 : len(s)
	case .Line:
		if !is_multiline(f, h) { target = dir < 0 ? 0 : len(s); break }
		ls := line_start(s, pos)
		col := utf8.rune_count_in_string(s[ls:pos])
		if dir < 0 {
			if ls == 0 { target = 0; break }
			prev_ls := line_start(s, ls - 1)
			target = advance_runes(s, prev_ls, col, ls - 1)
		} else {
			le := line_end(s, pos)
			if le >= len(s) { target = len(s); break }
			target = advance_runes(s, le + 1, col, line_end(s, le + 1))
		}
	}
	place_caret(f, h, target, extend)
}

@(private)
advance_runes :: proc(s: string, from, count, limit: int) -> int {
	p := from
	for _ in 0 ..< count {
		if p >= limit { break }
		p = next_char(s, p)
	}
	return min(p, limit)
}

////////////////////////////////
// Edits

@(private)
UNDO_TYPING :: u8(1)
@(private)
UNDO_OTHER :: u8(2)

@(private)
push_undo :: proc(f: ^Forms, c: ^Control, text: string, a, b: int, kind: u8) {
	if f.settings.undo_depth <= 0 { return }
	t := now(f)
	if kind == UNDO_TYPING && len(c.undo) > 0 {
		last := &c.undo[len(c.undo) - 1]
		if last.kind == UNDO_TYPING && t - last.ms <= f.settings.undo_merge_ms { last.ms = t; undo_clear(&c.redo); return }
	}
	append(&c.undo, Undo_Step{text = strings.clone(text), sel_start = a, sel_end = b, kind = kind, ms = t})
	for len(c.undo) > f.settings.undo_depth {
		delete(c.undo[0].text)
		ordered_remove(&c.undo, 0)
	}
	undo_clear(&c.redo)
}

// What a user edit would do: the new text and caret, or ok = false when it changes nothing.
@(private)
plan_edit :: proc(f: ^Forms, h: base.Handle, kind: Edit_Kind, text: string) -> (out: string, caret_pos: int, data: string, ok: bool) {
	s := edit_text(f, h)
	a, b, _ := selection(f, h)
	multiline := is_multiline(f, h)
	switch kind {
	case .Insert_Text, .Insert_From_Paste, .Insert_Replacement, .Insert_Line_Break:
		ins := kind == .Insert_Line_Break ? "\n" : text
		ins = multiline ? normalize_newlines(ins) : strip_newlines(normalize_newlines(ins))
		if kind == .Insert_Line_Break && !multiline { return }
		if mx := max_length(f, h); mx >= 0 {
			room := mx - (utf16_len(s) - utf16_len(s[a:b]))
			if room < 0 { room = 0 }
			if utf16_len(ins) > room { ins = cap_utf16(ins, room) }
			if ins == "" && a == b { return }
		}
		room_bytes := f.settings.max_value_bytes - (len(s) - (b - a))
		if len(ins) > room_bytes { ins = cap_bytes(ins, max(room_bytes, 0)) }
		if ins == "" && a == b { return }
		out = strings.concatenate({s[:a], ins, s[b:]}, context.temp_allocator)
		return out, a + len(ins), ins, true
	case .Delete_Backward, .Delete_Forward, .Delete_Word_Backward, .Delete_Word_Forward, .Delete_Line_Backward, .Delete_Line_Forward, .Delete_By_Cut:
		da, db := a, b
		if a == b {
			#partial switch kind {
			case .Delete_Backward: da = cluster_prev(s, a)
			case .Delete_Forward: db = cluster_next(s, b)
			case .Delete_Word_Backward: da = word_prev(s, a)
			case .Delete_Word_Forward: db = word_next(s, b)
			case .Delete_Line_Backward: da = multiline ? line_start(s, a) : 0
			case .Delete_Line_Forward: db = multiline ? line_end(s, b) : len(s)
			case .Delete_By_Cut: return
			}
		}
		if da == db { return }
		out = strings.concatenate({s[:da], s[db:]}, context.temp_allocator)
		return out, da, "", true
	case .History_Undo, .History_Redo:
		return
	}
	return
}

// A user edit: beforeinput (cancelable), the change, input. Returns true when the text changed.
edit :: proc(f: ^Forms, h: base.Handle, kind: Edit_Kind, text := "") -> bool {
	if !is_text_field(f, h) || !is_mutable(f, h) { return false }
	if kind == .History_Undo || kind == .History_Redo { return history(f, h, kind == .History_Undo) }
	_, _, data, ok := plan_edit(f, h, kind, text)
	if !ok { return false }
	if !fire(f, h, "beforeinput", bubbles = true, cancelable = true, data = data, text = EDIT_INPUT_TYPES[kind]) { return false }
	// listeners may have changed the field: plan again on what is there now
	if control_peek(f, h) == nil || element(f, h) == nil || !is_mutable(f, h) { return false }
	out, pos, data2, ok2 := plan_edit(f, h, kind, text)
	if !ok2 { return false }
	c := control_of(f, h)
	a, b, _ := selection(f, h)
	push_undo(f, c, edit_text(f, h), a, b, kind == .Insert_Text ? UNDO_TYPING : UNDO_OTHER)
	before := strings.clone(value(f, h), context.temp_allocator)
	set_edit_text(f, h, out)
	set_selection(f, h, pos, pos)
	c.changed_since_focus = true
	changed(f, h)
	_ = before
	fire(f, h, "input", bubbles = true, data = data2, text = EDIT_INPUT_TYPES[kind])
	return true
}

@(private)
history :: proc(f: ^Forms, h: base.Handle, undo: bool) -> bool {
	c := control_of(f, h)
	from := undo ? &c.undo : &c.redo
	to := undo ? &c.redo : &c.undo
	if len(from) == 0 { return false }
	kind := undo ? Edit_Kind.History_Undo : Edit_Kind.History_Redo
	if !fire(f, h, "beforeinput", bubbles = true, cancelable = true, text = EDIT_INPUT_TYPES[kind]) { return false }
	c = control_peek(f, h)
	if c == nil || len(from) == 0 { return false }
	step := pop(from)
	a, b, _ := selection(f, h)
	append(to, Undo_Step{text = strings.clone(edit_text(f, h)), sel_start = a, sel_end = b, kind = UNDO_OTHER, ms = now(f)})
	set_edit_text(f, h, step.text)
	set_selection(f, h, step.sel_start, step.sel_end)
	delete(step.text)
	c.changed_since_focus = true
	changed(f, h)
	fire(f, h, "input", bubbles = true, text = EDIT_INPUT_TYPES[kind])
	return true
}

can_undo :: proc(f: ^Forms, h: base.Handle) -> bool { c := control_peek(f, h); return c != nil && len(c.undo) > 0 }
can_redo :: proc(f: ^Forms, h: base.Handle) -> bool { c := control_peek(f, h); return c != nil && len(c.redo) > 0 }

// The text a copy puts on the clipboard ("" for password fields: never copied).
copy_text :: proc(f: ^Forms, h: base.Handle) -> string {
	if input_type(f, h) == .Password && kind(f, h) == .Input { return "" }
	return selected_text(f, h)
}

// Cut: the selected text (to put on the clipboard) and the deletion as a user edit.
cut :: proc(f: ^Forms, h: base.Handle) -> string {
	t := strings.clone(copy_text(f, h), context.temp_allocator)
	if t == "" { return "" }
	if !edit(f, h, .Delete_By_Cut) { return "" }
	return t
}

paste :: proc(f: ^Forms, h: base.Handle, text: string) -> bool { return edit(f, h, .Insert_From_Paste, text) }

////////////////////////////////
// Selection API (positions in UTF-16 code units)

// selectionStart / selectionEnd; ok = false when the API does not apply (the IDL attribute is null).
selection_utf16 :: proc(f: ^Forms, h: base.Handle) -> (start, end: int, dir: Direction, ok: bool) {
	if !selection_applies(f, h) { return }
	a, b, d := selection(f, h)
	s := edit_text(f, h)
	return byte_to_utf16(s, a), byte_to_utf16(s, b), d, true
}

// setSelectionRange. Fires `select`.
set_selection_range :: proc(f: ^Forms, h: base.Handle, start, end: int, dir: Direction) -> Error {
	if !selection_applies(f, h) { return .Invalid_State }
	s := edit_text(f, h)
	e := max(end, 0)
	st := min(max(start, 0), e)
	set_selection(f, h, utf16_to_byte(s, st), utf16_to_byte(s, e), dir)
	fire(f, h, "select", bubbles = true)
	return .None
}

// select(): everything. Fires `select`.
select_text :: proc(f: ^Forms, h: base.Handle) -> Error {
	if !is_text_field(f, h) { return .None }
	select_all(f, h)
	fire(f, h, "select", bubbles = true)
	return .None
}

Select_Mode :: enum u8 { Preserve, Select, Start, End }

// setRangeText(replacement, start, end, mode) (§4.10.18.6). start/end < 0 mean "the selection".
set_range_text :: proc(f: ^Forms, h: base.Handle, replacement: string, start, end: int, mode: Select_Mode) -> Error {
	if !selection_applies(f, h) { return .Invalid_State }
	s := strings.clone(edit_text(f, h), context.temp_allocator)
	sa, sb, _ := selection(f, h)
	len16 := utf16_len(s)
	st16, en16: int
	if start < 0 || end < 0 {
		st16, en16 = byte_to_utf16(s, sa), byte_to_utf16(s, sb)
	} else {
		if start > end { return .Index_Size }
		st16, en16 = min(start, len16), min(end, len16)
	}
	sel_start16, sel_end16 := byte_to_utf16(s, sa), byte_to_utf16(s, sb)
	a, b := utf16_to_byte(s, st16), utf16_to_byte(s, en16)
	repl := is_multiline(f, h) ? normalize_newlines(replacement) : replacement
	out := strings.concatenate({s[:a], repl, s[b:]}, context.temp_allocator)
	c := control_of(f, h)
	if kind(f, h) == .Textarea || input_type(f, h) in TEXT_LIKE { set_value(f, h, out) } else { set_edit_text(f, h, out) }
	out_s := edit_text(f, h)
	new_len := utf16_len(repl)
	new_end := st16 + new_len
	switch mode {
	case .Select: sel_start16, sel_end16 = st16, new_end
	case .Start: sel_start16, sel_end16 = st16, st16
	case .End: sel_start16, sel_end16 = new_end, new_end
	case .Preserve:
		old_len := en16 - st16
		delta := new_len - old_len
		if sel_start16 > en16 { sel_start16 += delta } else if sel_start16 > st16 { sel_start16 = st16 }
		if sel_end16 > en16 { sel_end16 += delta } else if sel_end16 > st16 { sel_end16 = new_end }
	}
	_ = c
	set_selection(f, h, utf16_to_byte(out_s, sel_start16), utf16_to_byte(out_s, sel_end16))
	fire(f, h, "select", bubbles = true)
	return .None
}
