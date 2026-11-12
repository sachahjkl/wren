package style

import "base:runtime"
import "core:reflect"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:css"

@(private = "file")
OPT :: css.Parse_Options{max_nesting_depth = 64, max_rules = 1000, max_errors_kept = 10}

// An element whose bases are not the probe's: em, rem, the viewport, a container and the color scheme differ, its parent
// is right to left.
@(private = "file")
element_cx :: proc(e: ^Engine, a: runtime.Allocator) -> Cx {
	// (every group copied before it is written: the probe's groups are the engine's)
	pcx := probe_context(e, a)
	for g in Group { cx_own(&pcx, g) }
	pcx.c.direction = .Rtl
	cx := probe_context(e, a)
	for g in Group { cx_own(&cx, g) }
	cx.parent = pcx.c
	cx.lc = css.Length_Context{font_size = 21, root_font_size = 13, x_height = 9, ch = 11, line_height = 30, root_line_height = 17,
		vw = 1111, vh = 777, cq_w = 333, cq_h = 222, has_cq_w = true, has_cq_h = true, vertical = true}
	cx.c.used_scheme = .Dark
	cx.c.color = {0.25, 0.5, 0.75, 1}
	return cx
}

// Every value compiled to a typed specified value computes, applied as compiled, what its tokens compute; the values
// that depend on more than the element's bases stay on their tokens.
@(test)
specified_values_apply_as_their_tokens :: proc(t: ^testing.T) {
	s := settings_default()
	e := engine_make(s)
	settings_destroy(&s)
	defer engine_destroy(e)
	arena: base.Arena
	_ = base.arena_init_growing(&arena)
	defer base.arena_destroy(&arena)
	a := base.arena_allocator(&arena)

	typed := strings.join({
		"display: flex", "display: -webkit-box", "display: RUN-IN", "display: none", "display: table-cell",
		"position: sticky", "float: right", "float: none", "clear: both", "box-sizing: border-box",
		"visibility: collapse", "overflow-x: overlay", "overflow-y: hidden", "overflow: clip",
		"border-top-style: dashed", "border-left-style: none", "outline-style: auto", "outline-style: double",
		"font-style: italic", "text-align: -webkit-center", "text-align: match-parent", "text-align: justify-all",
		"text-align: end", "text-transform: uppercase", "text-overflow: ellipsis", "text-overflow: clip",
		"word-break: break-all", "overflow-wrap: anywhere", "direction: rtl", "object-fit: scale-down",
		"flex-direction: column-reverse", "flex-wrap: wrap", "justify-content: space-between", "justify-content: left",
		"align-items: self-end", "align-self: anchor-center", "align-content: stretch", "list-style-position: inside",
		"pointer-events: visiblePainted", "pointer-events: none", "user-select: all", "border-collapse: collapse",
		"stroke-linecap: round", "stroke-linejoin: bevel",
		"width: 10px", "height: 2.5in", "min-width: 0", "max-width: none", "max-height: 50%", "min-height: auto",
		"width: min-content", "width: fit-content", "top: -3px", "left: auto", "bottom: 12%", "right: 1.5em",
		"margin-top: -2rem", "margin-left: auto", "margin: 1vw 2vh 3vmin 4vmax", "padding: 1ex 2ch 3lh 4rlh",
		"padding-top: 7cqw", "padding-left: 2cqh", "text-indent: -1.25em", "text-indent: 5%", "row-gap: normal",
		"column-gap: 3pt", "flex-basis: content", "flex-basis: 20%", "flex-basis: 1.1em", "width: 3vi", "height: 3vb",
		"inset-inline-start: 4px", "margin-inline: 1em",
		"color: #abc", "color: #a1b2c3d4", "color: Navy", "color: transparent", "background-color: #fff8",
		"background-color: RED", "border-top-color: rebeccapurple", "border-left-color: #000",
		"outline-color: tomato", "text-decoration-color: #123456",
	}, "; ", a)
	decls := css.parse_declarations(typed, OPT, a)
	pre, _ := compile_declarations(e, decls, a)
	testing.expect(t, len(pre) > 0, "declarations compiled")
	for d in pre {
		text := css.serialize_values(d.value, a)
		if d.spec.kind == .None { testing.expectf(t, false, "%v: %s stays on its tokens", d.prop, text); continue }
		x := element_cx(e, a)
		y := element_cx(e, a)
		ok := apply_prop(&x, d.prop, d.value)
		apply_specified(&y, d.prop, d.spec)
		testing.expectf(t, ok, "%v: %s is valid", d.prop, text)
		same := computed_equal(x.c, y.c) && x.explicit == y.explicit && x.cenv.has_current == y.cenv.has_current && x.cenv.current == y.cenv.current
		testing.expectf(t, same, "%v: %s applies as its tokens", d.prop, text)
	}

	untyped := strings.join({
		"float: inline-start", "text-align: -internal-th-center", "width: calc(1px + 1em)", "color: currentcolor",
		"color: canvastext", "background-color: rgb(1 2 3)", "border-top-color: light-dark(red, blue)", "width: var(--w)",
		"display: inline flow", "font-size: 12px", "line-height: 1.5", "opacity: 0.5",
	}, "; ", a)
	for d in compile_declarations_of(e, untyped, a) {
		testing.expectf(t, d.spec.kind == .None, "%v: %s stays on its tokens", d.prop, css.serialize_values(d.value, a))
	}

	// CSS-wide keywords are found when compiled, in any case, shorthands' longhands included
	for d in compile_declarations_of(e, "color: INHERIT; margin: revert-layer; display: Unset; width: initial; top: revert", a) {
		testing.expect(t, d.wide != .None && d.spec.kind == .None, "a CSS-wide keyword")
	}
	pre2 := compile_declarations_of(e, "margin: revert-layer; display: Unset", a)
	testing.expect(t, len(pre2) == 5 && pre2[0].wide == .Revert_Layer && pre2[4].wide == .Unset, "the keyword of each")
}

@(private = "file")
compile_declarations_of :: proc(e: ^Engine, text: string, a: runtime.Allocator) -> []Pre_Decl {
	pre, _ := compile_declarations(e, css.parse_declarations(text, OPT, a), a)
	return pre
}

// The keyword table finds every name of an enum, in any case, as comparing every name does; `_` is not `-`; an enum
// that is not in the table is read by its names.
// Every name of `E` and its upper case found by the table and by a scan, at its index; with `_`, none.
@(private = "file")
keyword_check :: proc(t: ^testing.T, $E: typeid) {
	names := reflect.enum_field_names(E)
	for n, i in names {
		css_name := base.ascii_lower(n, context.temp_allocator)
		css_name, _ = strings.replace_all(css_name, "_", "-", context.temp_allocator)
		for id in ([?]string{css_name, base.ascii_upper(css_name, context.temp_allocator)}) {
			got, ok := keyword_index(id, E)
			want, want_ok := keyword_scan(id, names)
			testing.expectf(t, ok && got == i && want_ok && want == i, "%v: %s", typeid_of(E), id)
		}
		if strings.contains(n, "_") {
			_, ok := keyword_index(base.ascii_lower(n, context.temp_allocator), E)
			testing.expectf(t, !ok, "%v: %s with `_`", typeid_of(E), n)
		}
	}
	_, ok := keyword_index("no-such-keyword", E)
	testing.expect(t, !ok, "a miss")
}

@(private = "file")
Unlisted_Keywords :: enum u8 { Alpha_Beta, Gamma }

// The keyword table finds every name of an enum, in any case, as comparing every name does; `_` is not `-`; an enum
// that is not in the table is read by its names.
@(test)
keyword_table_finds_what_a_scan_finds :: proc(t: ^testing.T) {
	keyword_check(t, Display)
	keyword_check(t, Cursor)
	keyword_check(t, Content_Align)
	keyword_check(t, Text_Align)
	keyword_check(t, Blend_Mode)
	keyword_check(t, Writing_Mode)
	keyword_check(t, Overflow)
	keyword_check(t, Unlisted_Keywords)
	v, ok := parse_enum(css.parse_component_values("SPACE-EVENLY", OPT, context.temp_allocator), Content_Align)
	testing.expect(t, ok && v == .Space_Evenly, "parse_enum through the table")
}
