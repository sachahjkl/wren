package style

import "core:mem"
import "core:sync"
import "wb:base"

// What a change of computed style means for layout, per element. Layout keeps its boxes between passes and needs to
// know, for each element whose style changed, how much of its work is invalid:
//   * Paint:  only paint-only values (layout's refresh path updates them);
//   * Layout: sizes, spacing, alignment... the box keeps its kind, flags, fonts and items: it is laid out again;
//   * Box:    the box itself may change (display, position, float, overflow, fonts, generated content, stacking...):
//             its parent's content is built again.
// `Layout_Journal` (journal.odin) records these per element as styles change.

Change_Level :: enum u8 { None, Paint, Layout, Box }

// Properties layout reads straight from the computed style while laying out, and nowhere else (not when building
// boxes, not in the flags of a box, not in the items of its text). A change of only these keeps the boxes. Every other
// property of the layout tier is structural.
LAYOUT_ONLY_PROPS :: [?]Prop{
	.Clear, .Top, .Right, .Bottom, .Left, .Box_Sizing,
	.Width, .Height, .Min_Width, .Min_Height, .Max_Width, .Max_Height,
	.Margin_Top, .Margin_Right, .Margin_Bottom, .Margin_Left,
	.Padding_Top, .Padding_Right, .Padding_Bottom, .Padding_Left,
	.Border_Top_Style, .Border_Right_Style, .Border_Bottom_Style, .Border_Left_Style,
	.Border_Top_Width, .Border_Right_Width, .Border_Bottom_Width, .Border_Left_Width,
	.Vertical_Align, .Aspect_Ratio, .Object_Fit,
	.Flex_Direction, .Flex_Wrap, .Flex_Grow, .Flex_Shrink, .Flex_Basis, .Justify_Content, .Align_Items, .Align_Self,
	.Align_Content, .Order, .Row_Gap, .Column_Gap,
	.Letter_Spacing, .Word_Spacing, .Text_Align, .Text_Indent, .Text_Overflow, .Word_Break, .Overflow_Wrap, .Tab_Size,
	.Text_Wrap_Mode, .Text_Wrap_Style, .Hyphens, .Outline_Width, .Border_Collapse, .Border_Spacing, .Table_Layout,
	.Text_Decoration_Style, .Text_Decoration_Thickness, .Text_Underline_Offset,
}

@(private) change_once: sync.Once
@(private) layout_only_set: Prop_Set
// Runs of layout fields (see paint_change.odin) that are contiguous in Computed: compared with one memcmp first.
@(private) Field_Run :: struct { offset: uintptr, size: int, first, count: int }
@(private) layout_runs: [dynamic]Field_Run
@(private) extra_fields: [dynamic]Field_Info   // layout fields no property owns (resolved values)

@(private)
change_init :: proc() {
	tiers_init()
	sync.once_do(&change_once, proc() {
		for p in LAYOUT_ONLY_PROPS { ps_add(&layout_only_set, p) }
		layout_runs = make([dynamic]Field_Run, 0, 32, base.permanent_allocator())
		for f, i in layout_fields {
			if n := len(layout_runs); n > 0 {
				r := &layout_runs[n - 1]
				if r.offset + uintptr(r.size) == f.offset && !is_pseudo_field(f.offset) && !is_pseudo_field(r.offset) {
					r.size += f.size
					r.count += 1
					continue
				}
			}
			append(&layout_runs, Field_Run{offset = f.offset, size = f.size, first = i, count = 1})
		}
		covered := make(map[uintptr]bool, 256, context.temp_allocator)
		for p in Prop {
			sl := &prop_slots[p]
			for k in 0 ..< 2 { if sl.size[k] > 0 { covered[sl.off[k]] = true } }
		}
		extra_fields = make([dynamic]Field_Info, 0, 8, base.permanent_allocator())
		for f in layout_fields {
			if !covered[f.offset] && !is_pseudo_field(f.offset) { append(&extra_fields, f) }
		}
	})
}

@(private)
is_pseudo_field :: #force_inline proc(off: uintptr) -> bool {
	return off == offset_of(Computed, before) || off == offset_of(Computed, after)
}

// Properties a change of which keeps the box (see Change_Level).
layout_only_props :: proc() -> Prop_Set {
	change_init()
	return layout_only_set
}

// Same answer as layout_equal, faster when most values are bit-identical (two passes over the same document): each
// run of fields is compared as bytes first, values only where the bytes differ.
layout_equal_fast :: proc(a, b: ^Computed) -> bool {
	if a == b { return true }
	if a == nil || b == nil { return false }
	change_init()
	if structure_sig(a) != structure_sig(b) { return false }
	for &r in layout_runs {
		pa, pb := rawptr(uintptr(a) + r.offset), rawptr(uintptr(b) + r.offset)
		if mem.compare_ptrs(pa, pb, r.size) == 0 { continue }
		for i in r.first ..< r.first + r.count {
			f := layout_fields[i]
			fa, fb := rawptr(uintptr(a) + f.offset), rawptr(uintptr(b) + f.offset)
			if is_pseudo_field(f.offset) {
				if !layout_equal_fast((^^Computed)(fa)^, (^^Computed)(fb)^) { return false }
				continue
			}
			if mem.compare_ptrs(fa, fb, f.size) == 0 { continue }
			if f.plain { return false }
			if f.ti.id == []string {
				if !strings_equal((^[]string)(fa)^, (^[]string)(fb)^) { return false }
				continue
			}
			if !deep_equal(fa, fb, f.ti) { return false }
		}
	}
	return true
}

// How much layout work the change from `old` to `new` invalidates. nil on either side (an element that gains or loses
// its style) is a box change.
change_level :: proc(old, new: ^Computed) -> Change_Level {
	level := layout_level(old, new)
	if level == .None && old != new && !computed_equal(old, new) { return .Paint }
	return level
}

// change_level without telling paint-only changes from no change (both .None): what the journal needs, cheaper.
layout_level :: proc(old, new: ^Computed) -> Change_Level {
	if old == new { return .None }
	if old == nil || new == nil { return .Box }
	change_init()
	if layout_equal_fast(old, new) { return .None }
	if structure_sig(old) != structure_sig(new) { return .Box }
	if !pseudo_equal(old.before, new.before) || !pseudo_equal(old.after, new.after) { return .Box }
	// fields that are not properties (resolved values such as the marker text) are read when building boxes
	for &f in extra_fields {
		fa, fb := rawptr(uintptr(old) + f.offset), rawptr(uintptr(new) + f.offset)
		if mem.compare_ptrs(fa, fb, f.size) != 0 && (f.plain || !deep_equal(fa, fb, f.ti)) { return .Box }
	}
	level := Change_Level.Paint
	for p in Prop {
		if tier_table[p] == .Paint || prop_equal(old, new, p) { continue }
		if !ps_has(layout_only_set, p) { return .Box }
		level = .Layout
	}
	return level == .Paint ? .Box : level
}

@(private)
pseudo_equal :: proc(a, b: ^Computed) -> bool {
	if a == b { return true }
	if a == nil || b == nil { return false }
	return layout_equal_fast(a, b)
}

// The level of a change of the animated properties `props` (a tick of the timeline).
props_level :: proc(props: Prop_Set) -> Change_Level {
	change_init()
	if ps_empty(props) { return .None }
	level := Change_Level.Paint
	for w, i in props.bits {
		if w & ~paint_set.bits[i] == 0 { continue }
		if w & ~(paint_set.bits[i] | layout_only_set.bits[i]) != 0 { return .Box }
		level = .Layout
	}
	return level
}
