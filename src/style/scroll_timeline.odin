package style

import "base:runtime"
import "core:math"
import "core:strings"
import "wb:base"
import "wb:css"
import "wb:dom"

// Scroll-driven animations (CSS Scroll-driven Animations 1): an animation attached to a scroll container's position instead of
// the document's clock.
//
// animation-timeline names, for each animation, a scroll progress timeline (scroll(), scroll-timeline-*) or a view progress
// timeline (view(), view-timeline-*). The page measures what a timeline reads at the frame's start, from the last layout
// (`timeline_scroll_sample`: a Timeline_Probe gives the scroller's offsets and the subject's box); `Progress_Timeline` keeps those
// numbers, so that a chrome frame can tell where the animation stands at another offset without reading anything else of the page
// (`progress_local`). An animation on such a timeline has no time of its own: Anim_Run.local is its progress in its attachment
// range (animation-range), on a scale of PROGRESS_SPAN, and its spec is normalised to that scale (`spec_normalised`), so that
// run_state, apply_run and the keyframes work as they do for time.

// The length of an attachment range on the scale of a progress-based animation's local time.
PROGRESS_SPAN :: 100.0
// animation-duration: auto (the attachment range for a progress-based animation, 0s for another).
ANIM_DURATION_AUTO :: f32(-1)

Anim_Timeline_Kind :: enum u8 { Auto, None, Named, Scroll, View }
Timeline_Axis :: enum u8 { Block, Inline, X, Y }
Scroller_Kind :: enum u8 { Nearest, Root, Self }

// The two ends of a view timeline's scrollport inset; an Auto end takes the scroll-padding (none here: 0).
View_Inset :: struct { start, end: Length }

AUTO_INSET :: View_Inset{Length{kind = .Auto}, Length{kind = .Auto}}

Anim_Timeline :: struct {
	kind:     Anim_Timeline_Kind,
	name:     string,          // .Named: a dashed ident
	axis:     Timeline_Axis,
	scroller: Scroller_Kind,   // .Scroll
	inset:    View_Inset,      // .View
}

Range_Name :: enum u8 { Normal, Cover, Contain, Entry, Exit, Entry_Crossing, Exit_Crossing }

// One end of animation-range.
Anim_Range :: struct {
	name:   Range_Name,
	has:    bool,     // an offset was written (Normal without one: the end of the timeline)
	offset: Length,
}

// timeline-scope.
Timeline_Scope :: struct {
	all:   bool,
	names: []string,
}

@(private = "file")
RANGE_NAMES := [Range_Name]string{.Normal = "normal", .Cover = "cover", .Contain = "contain", .Entry = "entry", .Exit = "exit", .Entry_Crossing = "entry-crossing", .Exit_Crossing = "exit-crossing"}

@(private = "file")
AXIS_NAMES := [Timeline_Axis]string{.Block = "block", .Inline = "inline", .X = "x", .Y = "y"}

@(private = "file")
SCROLLER_NAMES := [Scroller_Kind]string{.Nearest = "nearest", .Root = "root", .Self = "self"}

// A named range by its keyword (animation-range, the selectors of @keyframes).
range_name_of :: proc(id: string) -> (Range_Name, bool) {
	for name, r in RANGE_NAMES { if r != .Normal && base.ascii_equal_fold(id, name) { return r, true } }
	return .Normal, false
}

@(private = "file")
axis_of :: proc(id: string) -> (Timeline_Axis, bool) {
	for name, a in AXIS_NAMES { if base.ascii_equal_fold(id, name) { return a, true } }
	return .Block, false
}

@(private = "file")
dashed_ident :: proc(v: css.Value) -> (string, bool) {
	if !tok_is(v, .Ident) || !strings.has_prefix(v.tok.text, "--") || len(v.tok.text) <= 2 { return "", false }
	return v.tok.text, true
}

////////////////////////////////
// Parsing

@(private)
parse_inset_end :: proc(cx: ^Cx, v: css.Value) -> (Length, bool) {
	return parse_length(cx, {v}, {.Percent, .Negative, .Auto})
}

@(private = "file")
parse_scroll_function :: proc(args: []css.Value) -> (t: Anim_Timeline, ok: bool) {
	t.kind = .Scroll
	seen_axis, seen_scroller := false, false
	for it in split_items(args) {
		id := ident_lower(it)
		if a, is_axis := axis_of(id); is_axis && !seen_axis {
			t.axis, seen_axis = a, true
			continue
		}
		found := false
		for name, k in SCROLLER_NAMES {
			if id == name && !seen_scroller { t.scroller, seen_scroller, found = k, true, true }
		}
		if !found { return t, false }
	}
	return t, true
}

@(private = "file")
parse_view_function :: proc(cx: ^Cx, args: []css.Value) -> (t: Anim_Timeline, ok: bool) {
	t.kind = .View
	t.inset = AUTO_INSET
	seen_axis := false
	insets := 0
	for it in split_items(args) {
		if a, is_axis := axis_of(ident_lower(it)); is_axis {
			if seen_axis || insets == 1 && seen_axis { return t, false }
			t.axis, seen_axis = a, true
			continue
		}
		l, good := parse_inset_end(cx, it)
		if !good || insets == 2 { return t, false }
		if insets == 0 { t.inset = {l, l} } else { t.inset.end = l }
		insets += 1
	}
	return t, true
}

@(private = "file")
parse_one_timeline :: proc(cx: ^Cx, part: []css.Value) -> (t: Anim_Timeline, ok: bool) {
	items := css.trim_values(part)
	if len(items) != 1 { return t, false }
	v := items[0]
	if v.kind == .Function {
		args := css.trim_values(v.children)
		switch base.ascii_lower(v.tok.text) {
		case "scroll": return parse_scroll_function(args)
		case "view": return parse_view_function(cx, args)
		}
		return t, false
	}
	if name, dashed := dashed_ident(v); dashed { return Anim_Timeline{kind = .Named, name = strings.clone(name, cx.alloc)}, true }
	switch ident_lower(v) {
	case "auto": return Anim_Timeline{kind = .Auto}, true
	case "none": return Anim_Timeline{kind = .None}, true
	}
	return t, false
}

@(private)
parse_range_end :: proc(cx: ^Cx, part: []css.Value) -> (r: Anim_Range, ok: bool) {
	items := split_items(part)
	switch len(items) {
	case 1:
		if ident_lower(items[0]) == "normal" { return Anim_Range{}, true }
		if name, named := range_name_of(ident_lower(items[0])); named { return Anim_Range{name = name}, true }
		l, good := parse_length(cx, items[:], {.Percent, .Negative})
		return Anim_Range{has = true, offset = l}, good
	case 2:
		name, named := range_name_of(ident_lower(items[0]))
		if !named { return r, false }
		l, good := parse_length(cx, items[1:], {.Percent, .Negative})
		return Anim_Range{name = name, has = true, offset = l}, good
	}
	return r, false
}

// The longhands of Scroll-driven Animations, animation-timeline and animation-range-*.
apply_timeline_prop :: proc(cx: ^Cx, p: Prop, vs: []css.Value) -> bool {
	c := cx.c
	parts := list_parts(vs)
	n := len(parts)
	if n == 0 { return false }
	for part in parts { if len(css.trim_values(part)) == 0 { return false } }
	#partial switch p {
	case .Animation_Timeline:
		out := make([]Anim_Timeline, n, cx.alloc)
		for part, i in parts {
			t, ok := parse_one_timeline(cx, part)
			if !ok { return false }
			out[i] = t
		}
		c.animation_timeline = out
	case .Animation_Range_Start, .Animation_Range_End:
		out := make([]Anim_Range, n, cx.alloc)
		for part, i in parts {
			r, ok := parse_range_end(cx, part)
			if !ok { return false }
			out[i] = r
		}
		if p == .Animation_Range_Start { c.animation_range_start = out } else { c.animation_range_end = out }
	case .Scroll_Timeline_Name, .View_Timeline_Name:
		out := make([]string, n, cx.alloc)
		for part, i in parts {
			items := css.trim_values(part)
			if len(items) != 1 { return false }
			if ident_lower(items[0]) == "none" { continue }
			name, dashed := dashed_ident(items[0])
			if !dashed { return false }
			out[i] = strings.clone(name, cx.alloc)
		}
		if p == .Scroll_Timeline_Name { c.scroll_timeline_name = out } else { c.view_timeline_name = out }
	case .Scroll_Timeline_Axis, .View_Timeline_Axis:
		out := make([]Timeline_Axis, n, cx.alloc)
		for part, i in parts {
			a, ok := axis_of(css.ident_of(part))
			if !ok { return false }
			out[i] = a
		}
		if p == .Scroll_Timeline_Axis { c.scroll_timeline_axis = out } else { c.view_timeline_axis = out }
	case .View_Timeline_Inset:
		out := make([]View_Inset, n, cx.alloc)
		for part, i in parts {
			items := split_items(part)
			if len(items) < 1 || len(items) > 2 { return false }
			a, ok := parse_inset_end(cx, items[0])
			if !ok { return false }
			b := a
			if len(items) == 2 {
				if b, ok = parse_inset_end(cx, items[1]); !ok { return false }
			}
			out[i] = {a, b}
		}
		c.view_timeline_inset = out
	case .Timeline_Scope:
		if n == 1 {
			switch css.ident_of(parts[0]) {
			case "none": c.timeline_scope = {}; return true
			case "all": c.timeline_scope = {all = true}; return true
			}
		}
		out := make([]string, n, cx.alloc)
		for part, i in parts {
			items := css.trim_values(part)
			if len(items) != 1 { return false }
			name, dashed := dashed_ident(items[0])
			if !dashed { return false }
			out[i] = strings.clone(name, cx.alloc)
		}
		c.timeline_scope = {names = out}
	case: return false
	}
	return true
}

////////////////////////////////
// Shorthands

@(private = "file")
is_range_keyword :: proc(v: css.Value) -> bool {
	id := ident_lower(v)
	if id == "normal" { return true }
	_, named := range_name_of(id)
	return named
}

// animation-range: [<animation-range-start> <animation-range-end>?]#. A name alone covers that range to its end; a start without
// a name leaves the end at normal.
expand_animation_range :: proc(vs: []css.Value, a: runtime.Allocator) -> ([]Longhand, bool) {
	layers := css.split_commas(css.trim_values(vs), a)
	n := len(layers)
	if n == 0 { return nil, false }
	starts, ends := make([][]css.Value, n, a), make([][]css.Value, n, a)
	for layer, k in layers {
		items := split_items(layer, a)
		if len(items) == 0 || len(items) > 4 { return nil, false }
		first := 1   // ("entry 10% exit", "entry exit 90%", "10% 90%")
		if len(items) > 1 && is_range_keyword(items[0]) && !is_range_keyword(items[1]) { first = 2 }
		starts[k] = items[:first]
		switch {
		case first < len(items): ends[k] = items[first:]
		case ident_lower(items[0]) != "normal" && is_range_keyword(items[0]): ends[k] = items[:1]
		case: ends[k] = idents(a, "normal")
		}
	}
	res := make([dynamic]Longhand, a)
	append(&res, Longhand{.Animation_Range_Start, comma_join(starts, a)}, Longhand{.Animation_Range_End, comma_join(ends, a)})
	return res[:], true
}

// scroll-timeline: [<scroll-timeline-name> <scroll-timeline-axis>?]#
expand_scroll_timeline :: proc(vs: []css.Value, a: runtime.Allocator) -> ([]Longhand, bool) {
	layers := css.split_commas(css.trim_values(vs), a)
	n := len(layers)
	if n == 0 { return nil, false }
	names, axes := make([][]css.Value, n, a), make([][]css.Value, n, a)
	for layer, k in layers {
		items := split_items(layer, a)
		if len(items) == 0 || len(items) > 2 { return nil, false }
		names[k] = items[:1]
		axes[k] = len(items) == 2 ? items[1:] : idents(a, "block")
	}
	res := make([dynamic]Longhand, a)
	append(&res, Longhand{.Scroll_Timeline_Name, comma_join(names, a)}, Longhand{.Scroll_Timeline_Axis, comma_join(axes, a)})
	return res[:], true
}

// view-timeline: [<view-timeline-name> [<view-timeline-inset> || <view-timeline-axis>]?]#
expand_view_timeline :: proc(vs: []css.Value, a: runtime.Allocator) -> ([]Longhand, bool) {
	layers := css.split_commas(css.trim_values(vs), a)
	n := len(layers)
	if n == 0 { return nil, false }
	names, axes, insets := make([][]css.Value, n, a), make([][]css.Value, n, a), make([][]css.Value, n, a)
	for layer, k in layers {
		items := split_items(layer, a)
		if len(items) == 0 || len(items) > 4 { return nil, false }
		names[k] = items[:1]
		rest := make([dynamic]css.Value, a)
		for it, i in items[1:] {
			if _, is_axis := axis_of(ident_lower(it)); is_axis {
				if axes[k] != nil { return nil, false }
				axes[k] = items[1 + i:2 + i]
				continue
			}
			if len(rest) > 0 { append(&rest, css.Value{kind = .Token, tok = css.Token{kind = .Whitespace}}) }
			append(&rest, it)
		}
		if axes[k] == nil { axes[k] = idents(a, "block") }
		insets[k] = len(rest) > 0 ? rest[:] : idents(a, "auto")
	}
	res := make([dynamic]Longhand, a)
	append(&res, Longhand{.View_Timeline_Name, comma_join(names, a)}, Longhand{.View_Timeline_Axis, comma_join(axes, a)}, Longhand{.View_Timeline_Inset, comma_join(insets, a)})
	return res[:], true
}

////////////////////////////////
// Serializing

// (`length_text` is the page's css_length: lengths are written by whoever serialises a computed value.)
@(private = "file")
inset_text :: proc(l: Length, length_text: proc(l: Length) -> string) -> string {
	return l.kind == .Auto ? "auto" : length_text(l)
}

@(private = "file")
inset_pair_text :: proc(i: View_Inset, length_text: proc(l: Length) -> string) -> string {
	a, b := inset_text(i.start, length_text), inset_text(i.end, length_text)
	return a == b ? a : strings.concatenate({a, " ", b}, context.temp_allocator)
}

range_text_of :: proc(r: Anim_Range, default_percent: f32, length_text: proc(l: Length) -> string) -> string {
	if !r.has { return RANGE_NAMES[r.name] }
	offset := length_text(r.offset)
	if r.name == .Normal { return offset }
	if r.offset.kind == .Percent && r.offset.v == default_percent { return RANGE_NAMES[r.name] }
	return strings.concatenate({RANGE_NAMES[r.name], " ", offset}, context.temp_allocator)
}

@(private = "file")
timeline_text :: proc(t: Anim_Timeline, length_text: proc(l: Length) -> string) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	switch t.kind {
	case .Auto: return "auto"
	case .None: return "none"
	case .Named: return t.name
	case .Scroll:
		if t.scroller != .Nearest { append(&parts, SCROLLER_NAMES[t.scroller]) }
		if t.axis != .Block { append(&parts, AXIS_NAMES[t.axis]) }
		return strings.concatenate({"scroll(", strings.join(parts[:], " ", context.temp_allocator), ")"}, context.temp_allocator)
	case .View:
		if t.axis != .Block { append(&parts, AXIS_NAMES[t.axis]) }
		if t.inset != AUTO_INSET { append(&parts, inset_pair_text(t.inset, length_text)) }
		return strings.concatenate({"view(", strings.join(parts[:], " ", context.temp_allocator), ")"}, context.temp_allocator)
	}
	return ""
}

// The computed value of a Scroll-driven Animations property and of animation-timeline, animation-range-*, "" for any other name.
timeline_prop_text :: proc(c: ^Computed, name: string, length_text: proc(l: Length) -> string) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	switch name {
	case "animation-timeline": for t in c.animation_timeline { append(&parts, timeline_text(t, length_text)) }
	case "animation-range-start": for r in c.animation_range_start { append(&parts, range_text_of(r, 0, length_text)) }
	case "animation-range-end": for r in c.animation_range_end { append(&parts, range_text_of(r, 100, length_text)) }
	case "scroll-timeline-name": for s in c.scroll_timeline_name { append(&parts, s == "" ? "none" : s) }
	case "view-timeline-name": for s in c.view_timeline_name { append(&parts, s == "" ? "none" : s) }
	case "scroll-timeline-axis": for a in c.scroll_timeline_axis { append(&parts, AXIS_NAMES[a]) }
	case "view-timeline-axis": for a in c.view_timeline_axis { append(&parts, AXIS_NAMES[a]) }
	case "view-timeline-inset": for i in c.view_timeline_inset { append(&parts, inset_pair_text(i, length_text)) }
	case "timeline-scope":
		if c.timeline_scope.all { return "all" }
		if len(c.timeline_scope.names) == 0 { return "none" }
		append(&parts, ..c.timeline_scope.names)
	case "scroll-timeline":
		for s, i in c.scroll_timeline_name {
			axis := list_at(c.scroll_timeline_axis, i, Timeline_Axis.Block)
			label := s == "" ? "none" : s
			append(&parts, axis == .Block ? label : strings.concatenate({label, " ", AXIS_NAMES[axis]}, context.temp_allocator))
		}
	case "view-timeline":
		for s, i in c.view_timeline_name {
			axis := list_at(c.view_timeline_axis, i, Timeline_Axis.Block)
			inset := list_at(c.view_timeline_inset, i, AUTO_INSET)
			one := make([dynamic]string, context.temp_allocator)
			append(&one, s == "" ? "none" : s)
			if axis != .Block { append(&one, AXIS_NAMES[axis]) }
			if inset != AUTO_INSET { append(&one, inset_pair_text(inset, length_text)) }
			append(&parts, strings.join(one[:], " ", context.temp_allocator))
		}
	case "animation-range":
		for r, i in c.animation_range_start {
			end := list_at(c.animation_range_end, i, Anim_Range{})
			a, b := range_text_of(r, 0, length_text), range_text_of(end, 100, length_text)
			same := end == Anim_Range{} || (r.name != .Normal && a == b)   // (the end the start alone stands for)
			append(&parts, same ? a : strings.concatenate({a, " ", b}, context.temp_allocator))
		}
	case "animation-name": for s in c.animation_name { append(&parts, s == "" ? "none" : s) }
	}
	return strings.join(parts[:], ", ", context.temp_allocator)
}

////////////////////////////////
// What a timeline reads

// What the page measures of a scroller (CSS px).
Scroll_Measure :: struct {
	ok:     bool,     // it has a box, and scrolls
	pos:    [2]f64,   // its scroll offsets
	lo, hi: [2]f64,   // their range
	port:   [2]f64,   // the scrollport's size
}

// The layout as the page's last frame left it, for the timelines.
Timeline_Probe :: struct {
	user:     rawptr,
	root:     base.Handle,   // the document element
	// `node` NIL: the viewport
	scroller: proc(user: rawptr, node: base.Handle) -> Scroll_Measure,
	// The box of `subject` (min x, y and max x, y) in the scrollable area of `source` at offset zero; ok false without a box.
	subject:  proc(user: rawptr, subject, source: base.Handle) -> (lo, hi: [2]f64, ok: bool),
}

// What a timeline reads.
Timeline_Source :: struct {
	view:    bool,
	source:  base.Handle,   // NIL: the viewport
	subject: base.Handle,   // a view timeline's
	axis:    Timeline_Axis,
	inset:   View_Inset,
}

// A timeline as last measured: all that is needed to tell its progress at another offset.
Progress_Timeline :: struct {
	active:     bool,
	source:     base.Handle,          // NIL: the viewport
	axis:       int,                  // 0 x, 1 y
	reverse:    bool,                 // its offsets run down from zero (a right-to-left scroller)
	origin:     f64,                  // the offset at which the scroller rests
	offset:     f64,                  // where it is, from its origin
	lo, hi:     f64,                  // the offsets of 0% and 100%
	ranges:     [Range_Name][2]f64,   // the offsets of each named range
	start, end: f64,                  // the attachment range of the animation (offsets)
}

// The offset of `pos` along the timeline's axis, from its origin.
progress_offset :: proc(t: ^Progress_Timeline, pos: [2]f64) -> f64 {
	d := pos[t.axis] - t.origin
	return t.reverse ? -d : d
}

// Its progress at offset `at`, on a scale of 0..PROGRESS_SPAN of the timeline.
timeline_percent :: proc(t: ^Progress_Timeline, at: f64) -> f64 {
	if t.hi <= t.lo { return at >= t.hi ? PROGRESS_SPAN : 0 }
	return (at - t.lo) / (t.hi - t.lo) * PROGRESS_SPAN
}

// The local time of an animation attached to `t` at offset `at`: how far it is in its attachment range.
@(private)
progress_local :: proc(t: ^Progress_Timeline, at: f64) -> f64 {
	if t.end <= t.start { return at >= t.end ? PROGRESS_SPAN : -1 }
	return (at - t.start) / (t.end - t.start) * PROGRESS_SPAN
}

// The offset one end of animation-range stands for. `default`: where it lies in its range without an offset (0 or 1).
@(private)
range_offset :: proc(t: ^Progress_Timeline, r: Anim_Range, default: f64) -> f64 {
	span := t.ranges[r.name]
	if !r.has { return span[0] + (span[1] - span[0]) * default }
	return span[0] + f64(resolve(r.offset, f32(span[1] - span[0])))
}

// The nearest ancestor of `h` that is a scroll container; NIL: the viewport.
@(private = "file")
nearest_scroller :: proc(s: ^Styled, doc: ^dom.Document, h, root: base.Handle) -> base.Handle {
	scrolls :: proc(o: Overflow) -> bool { return o == .Scroll || o == .Auto || o == .Hidden }
	for cur := dom.parent_or_host(doc, h); cur != base.NIL_HANDLE && cur != root; cur = dom.parent_or_host(doc, cur) {
		c := base_style_of(s, cur)
		if c != nil && (scrolls(c.overflow_x) || scrolls(c.overflow_y)) { return cur }
	}
	return base.NIL_HANDLE
}

// What `h` declares under `name`.
@(private = "file")
declared_on :: proc(s: ^Styled, doc: ^dom.Document, h, root: base.Handle, name: string) -> (src: Timeline_Source, ok: bool) {
	c := base_style_of(s, h)
	if c == nil { return }
	for n, i in c.scroll_timeline_name {
		if n == name { return {source = h == root ? base.NIL_HANDLE : h, axis = list_at(c.scroll_timeline_axis, i, Timeline_Axis.Block)}, true }
	}
	for n, i in c.view_timeline_name {
		if n == name {
			return {view = true, subject = h, source = nearest_scroller(s, doc, h, root), axis = list_at(c.view_timeline_axis, i, Timeline_Axis.Block), inset = list_at(c.view_timeline_inset, i, AUTO_INSET)}, true
		}
	}
	return
}

@(private = "file")
scope_lists :: proc(s: ^Styled, h: base.Handle, name: string) -> bool {
	c := base_style_of(s, h)
	if c == nil { return false }
	if c.timeline_scope.all { return true }
	for x in c.timeline_scope.names { if x == name { return true } }
	return false
}

// The one element under `scope` that declares `name` (more than one: none), the subtrees of other timeline-scopes of that name aside.
@(private = "file")
declared_under :: proc(s: ^Styled, doc: ^dom.Document, scope, root: base.Handle, name: string) -> (src: Timeline_Source, ok: bool) {
	stack := make([dynamic]base.Handle, context.temp_allocator)
	append(&stack, scope)
	for len(stack) > 0 {
		h := pop(&stack)
		n := dom.get(doc, h)
		if n == nil { continue }
		if n.kind == .Element && h != scope {
			if d, found := declared_on(s, doc, h, root, name); found {
				if ok { return {}, false }
				src, ok = d, true
			}
			if scope_lists(s, h, name) { continue }
		}
		for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
	}
	return
}

// What `name` means for an animation of `h`: its own declaration or an ancestor's, one under the nearest timeline-scope that lists it, else
// one of the document's outside any such scope. (`global`: what that last search found in this sample, by name.)
@(private = "file")
named_timeline :: proc(s: ^Styled, doc: ^dom.Document, h, root: base.Handle, name: string, global: ^map[string]Global_Timeline) -> (src: Timeline_Source, ok: bool) {
	for cur := h; cur != base.NIL_HANDLE; cur = dom.parent_or_host(doc, cur) {
		n := dom.get(doc, cur)
		if n == nil || n.kind != .Element { continue }
		if d, found := declared_on(s, doc, cur, root, name); found { return d, true }
		if scope_lists(s, cur, name) { return declared_under(s, doc, cur, root, name) }
	}
	if g, known := global[name]; known { return g.src, g.ok }
	src, ok = declared_under(s, doc, doc.root, root, name)
	global[name] = {src, ok}
	return
}

// A name looked for in the whole document, for one sample.
@(private = "file")
Global_Timeline :: struct { src: Timeline_Source, ok: bool }

// What an animation of `h` is attached to, by its animation-timeline. ok false: nothing (the timeline is inactive).
@(private = "file")
resolve_timeline :: proc(s: ^Styled, doc: ^dom.Document, root, h: base.Handle, t: Anim_Timeline, global: ^map[string]Global_Timeline) -> (src: Timeline_Source, ok: bool) {
	#partial switch t.kind {
	case .Scroll:
		switch t.scroller {
		case .Nearest: src.source = nearest_scroller(s, doc, h, root)
		case .Root:
		case .Self: src.source = h == root ? base.NIL_HANDLE : h
		}
		src.axis = t.axis
		return src, true
	case .View:
		return {view = true, subject = h, source = nearest_scroller(s, doc, h, root), axis = t.axis, inset = t.inset}, true
	case .Named:
		return named_timeline(s, doc, h, root, t.name, global)
	}
	return
}

// The physical axis of a logical one, on the scroller's writing mode: 0 x, 1 y.
@(private = "file")
axis_index :: proc(a: Timeline_Axis, c: ^Computed) -> int {
	vertical := c != nil && c.writing_mode != .Horizontal_Tb
	switch a {
	case .X: return 0
	case .Y: return 1
	case .Block: return vertical ? 0 : 1
	case .Inline: return vertical ? 1 : 0
	}
	return 1
}

// `t` measured for a timeline reading `src`.
progress_measure :: proc(s: ^Styled, probe: Timeline_Probe, src: Timeline_Source, t: ^Progress_Timeline) {
	t^ = {source = src.source}
	m := probe.scroller(probe.user, src.source)
	if !m.ok { return }
	ax := axis_index(src.axis, base_style_of(s, src.source != base.NIL_HANDLE ? src.source : probe.root))
	t.axis = ax
	t.reverse = m.hi[ax] <= 0 && m.lo[ax] < 0
	t.origin = t.reverse ? m.hi[ax] : m.lo[ax]
	span := m.hi[ax] - m.lo[ax]
	t.offset = progress_offset(t, m.pos)
	if !src.view {
		if span <= 0 { return }
		t.lo, t.hi = 0, span
		for &r in t.ranges { r = {0, span} }
		t.active = true
		return
	}
	lo, hi, ok := probe.subject(probe.user, src.subject, src.source)
	if !ok { return }
	port := m.port[ax]
	a, b := lo[ax], hi[ax]
	if t.reverse { a, b = m.hi[ax] - hi[ax], m.hi[ax] - lo[ax] }   // (from the scroller's start edge, on its right)
	// the edges of the scrollport less its insets
	start_edge := f64(resolve(src.inset.start, f32(port)))
	end_edge := port - f64(resolve(src.inset.end, f32(port)))
	cover := [2]f64{a - end_edge, b - start_edge}
	contain := b - a <= end_edge - start_edge ? [2]f64{b - end_edge, a - start_edge} : [2]f64{a - start_edge, b - end_edge}
	t.lo, t.hi = cover[0], cover[1]
	t.ranges[.Normal] = cover
	t.ranges[.Cover] = cover
	t.ranges[.Contain] = contain
	t.ranges[.Entry] = {cover[0], contain[0]}
	t.ranges[.Exit] = {contain[1], cover[1]}
	t.ranges[.Entry_Crossing] = {a - end_edge, b - end_edge}
	t.ranges[.Exit_Crossing] = {a - start_edge, b - start_edge}
	t.active = true
}

// Measures the timelines of the page's CSS animations; true when an animation has something new to show from them.
timeline_scroll_sample :: proc(tl: ^Timeline, doc: ^dom.Document, s: ^Styled, probe: Timeline_Probe) -> (changed: bool) {
	if tl == nil || s == nil { return false }
	global := make(map[string]Global_Timeline, 4, context.temp_allocator)
	for _, ea in tl.elements {
		if ea.base == nil { continue }
		for r in ea.runs {
			if r.timeline.kind == .Auto { continue }
			was := r.progress
			r.progress = {}
			if src, ok := resolve_timeline(s, doc, probe.root, ea.node, r.timeline, &global); ok {
				r.src = src
				progress_measure(s, probe, src, &r.progress)
				if r.progress.active {
					spec := animation_at(ea.base, r.index)
					r.progress.start = range_offset(&r.progress, spec.range_start, 0)
					r.progress.end = range_offset(&r.progress, spec.range_end, 1)
				}
			}
			if r.progress != was {
				changed = true
				// (keyframes at a named range move with it; the frames stay readable until the next tick: a chrome frame goes on with them)
				if r.progress.ranges != was.ranges && r.frames_ranged { r.frames_moved = true }
			}
		}
	}
	for _, st in tl.progress_timelines {
		was := st.progress
		st.progress = {}
		if !st.none { progress_measure(s, probe, st.src, &st.progress) }
		if st.progress != was { changed = true }
	}
	if changed { tl.dirty = true }
	return
}

// `spec` as the local time of a progress-based animation counts it: its delay and iterations share PROGRESS_SPAN, time-based ones
// in proportion, and an auto duration fills the range.
@(private)
spec_normalised :: proc(spec: Animation_Spec) -> Animation_Spec {
	n := spec
	iters := f64(spec.iterations)
	if spec.duration == ANIM_DURATION_AUTO {
		n.delay = 0
		n.duration = iters > 0 && !math.is_inf(iters) ? f32(PROGRESS_SPAN / iters) : 0
		return n
	}
	total := max(f64(spec.delay), 0) + max(f64(spec.duration), 0) * iters
	if !(total > 0) || math.is_inf(total) {
		n.duration, n.delay = 0, 0
		return n
	}
	n.duration = f32(f64(spec.duration) * PROGRESS_SPAN / total)
	n.delay = f32(max(f64(spec.delay), 0) * PROGRESS_SPAN / total)
	return n
}
