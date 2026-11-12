package style

import "core:reflect"
import "core:sync"

// The keywords of the enums that name CSS values (`Space_Between` is written `space-between`), in one hash table made
// once: parse_enum finds a keyword by one hash and one comparison, not by comparing it with every name of the enum. An
// enum missing from KEYWORD_ENUMS is still parsed, by comparing names (keyword_scan): only slower.

@(private = "file")
KEYWORD_ENUMS := [?]typeid{
	Anim_Direction, Appearance, Backface_Visibility, Bg_Attachment, Blend_Mode, Border_Style, Box_Area, Box_Sizing,
	Break_Inside, Break_Value, Clear, Color_Space, Column_Fill, Column_Span, Composition, Container_Type, Content_Align,
	Content_Visibility, Counter_Style, Cursor, Direction, Display, Fill_Mode, Flex_Direction, Flex_Wrap, Float,
	Font_Display, Font_Kerning, Font_Optical_Sizing, Font_Style, Font_Variant_Caps, Font_Variant_Position, Geometry_Box,
	Hyphens, Isolation, List_Style_Position, List_Style_Type, Mask_Box, Mask_Composite, Mask_Mode, Object_Fit, Overflow,
	Overflow_Anchor, Overflow_Wrap, Overscroll, Play_State, Position, Repeat, Resize, Scroll_Behavior, Scrollbar_Gutter,
	Scrollbar_Width, Stroke_Linecap, Stroke_Linejoin, Table_Layout, Text_Align, Text_Combine_Upright,
	Text_Decoration_Skip_Ink, Text_Decoration_Style, Text_Orientation, Text_Rendering, Text_Transform, Text_Wrap_Mode,
	Text_Wrap_Style, Timeline_Axis, Transform_Box, Transform_Style, Try_Order, Unicode_Bidi, User_Select, Visibility,
	White_Space, White_Space_Collapse, Word_Break, Writing_Mode,
}

// Slots of the table: a power of two, at most half full (keyword_table_build checks it).
@(private = "file")
KEYWORD_SLOTS :: 4096

// The slot that marks an enum as in the table (its name cannot be an identifier): a keyword it misses is no keyword of it.
@(private = "file")
KEYWORD_LISTED :: "\x00"
@(private = "file")
KEYWORD_LISTED_VALUE :: max(u16)

@(private = "file")
Keyword_Slot :: struct {
	enum_type: typeid,   // nil: empty
	hash:      u32,
	value:     u16,      // the index of the name in the enum (what parse_enum returns as E(index))
}

@(private = "file") keyword_table: [KEYWORD_SLOTS]Keyword_Slot
@(private = "file") keyword_once: sync.Once

// `name` lower-cased, with `_` read as `-` for an enum's own names (names_equal's rule), hashed with its enum.
@(private = "file")
keyword_hash :: proc "contextless" (enum_type: typeid, name: string, enum_name: bool) -> u32 {
	h := u64(14695981039346656037) ~ transmute(u64)enum_type
	for i in 0 ..< len(name) {
		c := name[i]
		if c >= 'A' && c <= 'Z' { c += 32 }
		if enum_name && c == '_' { c = '-' }
		h = (h ~ u64(c)) * 1099511628211
	}
	return u32(h ~ (h >> 32))
}

@(private = "file")
keyword_insert :: proc(enum_type: typeid, name: string, value: u16) {
	h := keyword_hash(enum_type, name, true)
	i := int(h) & (KEYWORD_SLOTS - 1)
	for keyword_table[i].enum_type != nil { i = (i + 1) & (KEYWORD_SLOTS - 1) }
	keyword_table[i] = Keyword_Slot{enum_type, h, value}
}

@(private = "file")
keyword_table_build :: proc() {
	used := 0
	for t in KEYWORD_ENUMS {
		names := reflect.enum_field_names(t)
		for n, i in names { keyword_insert(t, n, u16(i)) }
		keyword_insert(t, KEYWORD_LISTED, KEYWORD_LISTED_VALUE)
		used += len(names) + 1
	}
	assert(used * 2 <= KEYWORD_SLOTS, "the keyword table is more than half full: make KEYWORD_SLOTS larger")
}

// The index in `E` of the keyword `id` (ASCII case-insensitive); false: none.
@(private)
keyword_index :: proc(id: string, $E: typeid) -> (int, bool) {
	sync.once_do(&keyword_once, keyword_table_build)
	names := reflect.enum_field_names(E)
	h := keyword_hash(E, id, false)
	listed := keyword_hash(E, KEYWORD_LISTED, true)
	is_listed := false
	for i := int(h) & (KEYWORD_SLOTS - 1); keyword_table[i].enum_type != nil; i = (i + 1) & (KEYWORD_SLOTS - 1) {
		s := &keyword_table[i]
		if s.enum_type != E { continue }
		if s.hash == h && s.value != KEYWORD_LISTED_VALUE && names_equal(id, names[s.value]) { return int(s.value), true }
	}
	// a miss: no keyword of a listed enum; an enum that is not listed is read name by name
	for i := int(listed) & (KEYWORD_SLOTS - 1); keyword_table[i].enum_type != nil; i = (i + 1) & (KEYWORD_SLOTS - 1) {
		s := &keyword_table[i]
		if s.enum_type == E && s.value == KEYWORD_LISTED_VALUE { is_listed = true; break }
	}
	if is_listed { return 0, false }
	return keyword_scan(id, names)
}

// keyword_index by comparing every name: the reference of the table, and the reading of an enum that is not listed.
@(private)
keyword_scan :: proc(id: string, names: []string) -> (int, bool) {
	for n, i in names { if names_equal(id, n) { return i, true } }
	return 0, false
}
