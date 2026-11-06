package style

import "core:math"
import "core:testing"
import "wb:dom"

// The values of CSS Text Decoration 4 as the cascade gives them: what parses, what inherits, what animates.
@(private = "file")
at :: proc(f: ^Fixture, id: string) -> ^Computed { return style_of(f.st, dom.find_by_id(f.doc, id)) }

@(test)
skip_and_position_values :: proc(t: ^testing.T) {
	f := fixture_load(`<style>
		#a { text-decoration-skip-ink: all; text-decoration-skip-spaces: start; text-underline-position: under right; }
		#b { text-decoration-skip-ink: none; text-decoration-skip-spaces: none; text-underline-position: from-font; }
		#c { text-decoration-skip-ink: bad; text-decoration-skip-spaces: all start; text-underline-position: under from-font; text-underline-offset: from-font; }
		</style><div id=a><i id=in>x</i></div><div id=b>x</div><div id=c>x</div>`)
	defer fixture_unload(f)
	a, b, c := at(f, "a"), at(f, "b"), at(f, "c")
	testing.expect(t, a.text_decoration_skip_ink == .All && a.text_decoration_skip_spaces == {.Start} && a.text_underline_position == {.Under, .Right})
	testing.expect(t, b.text_decoration_skip_ink == .None && b.text_decoration_skip_spaces == {} && b.text_underline_position.place == .From_Font)
	testing.expect(t, c.text_decoration_skip_ink == .Auto && c.text_decoration_skip_spaces == {.Start, .End} && c.text_underline_position == {}, "invalid values leave the initial ones")
	testing.expect(t, c.text_underline_offset.kind == .Auto)
	testing.expect(t, at(f, "in").text_decoration_skip_ink == .All && at(f, "in").text_underline_position == {.Under, .Right}, "they inherit")
}

@(test)
thickness_and_offset_keep_their_percentages :: proc(t: ^testing.T) {
	f := fixture_load(`<style>
		#a { font-size: 20px; text-decoration-thickness: 10%; text-underline-offset: 50%; }
		#b { font-size: 40px; }
		#c { text-decoration-thickness: thick; }
		#d { text-decoration: underline wavy 3px red; }
		#e { text-decoration: underline thin red; }
		#f { text-decoration-thickness: from-font; }
		</style><div id=a><div id=b>x</div></div><p id=c>x</p><p id=d>x</p><p id=e>x</p><p id=f>x</p>`)
	defer fixture_unload(f)
	a, b := at(f, "a"), at(f, "b")
	testing.expect(t, a.text_decoration_thickness.kind == .Percent && a.text_decoration_thickness.v == 10)
	testing.expect(t, b.text_underline_offset.kind == .Percent && b.text_underline_offset.v == 50, "inherited as a percentage, not as what it was on the parent")
	testing.expect(t, b.text_decoration_thickness.kind == .Auto, "thickness does not inherit")
	testing.expect(t, at(f, "c").text_decoration_thickness.v == LINE_WIDTH_THICK)
	d := at(f, "d")
	testing.expect(t, d.text_decoration_thickness.v == 3 && d.text_decoration_style == .Wavy, "the shorthand in full")
	testing.expect(t, at(f, "e").text_decoration_thickness.v == LINE_WIDTH_THIN, "a keyword of the shorthand")
	testing.expect(t, at(f, "f").text_decoration_thickness.kind == .Normal)
}

@(test)
error_lines_stand_alone :: proc(t: ^testing.T) {
	f := fixture_load(`<style>#a { text-decoration: spelling-error; } #b { text-decoration-line: grammar-error; } #c { text-decoration-line: underline grammar-error; }</style>
		<p id=a>x</p><p id=b>x</p><p id=c>x</p>`)
	defer fixture_unload(f)
	testing.expect(t, at(f, "a").text_decoration == {.Spelling_Error})
	testing.expect(t, at(f, "b").text_decoration == {.Grammar_Error})
	testing.expect(t, at(f, "c").text_decoration == {})
}

@(test)
emphasis_values :: proc(t: ^testing.T) {
	f := fixture_load(`<style>
		#a { text-emphasis: open sesame red; text-emphasis-position: under left; }
		#b { -webkit-text-emphasis-style: "@"; text-emphasis-skip: symbols narrow; }
		#c { text-emphasis-style: filled; }
		#d { text-emphasis-style: open filled; text-emphasis-position: left; }
		#a2 { text-emphasis: open sesame red; text-emphasis: blue; }
		</style><div id=a><i id=in>x</i></div><p id=b>x</p><p id=c>x</p><p id=d>x</p><p id=a2>x</p>`)
	defer fixture_unload(f)
	a := at(f, "a")
	testing.expect(t, a.text_emphasis_style.shape == .Sesame && a.text_emphasis_style.open && !a.text_emphasis_color.auto && a.text_emphasis_position == {under = true, left = true})
	testing.expect(t, at(f, "in").text_emphasis_style.shape == .Sesame, "it inherits")
	b := at(f, "b")
	testing.expect(t, b.text_emphasis_style.shape == .String && b.text_emphasis_style.text == "@" && b.text_emphasis_skip == {.Symbols, .Narrow})
	testing.expect(t, emphasis_mark(at(f, "c").text_emphasis_style, false) == "●" && emphasis_mark(at(f, "c").text_emphasis_style, true) == "﹅", "a circle in rows, sesame in columns")
	testing.expect(t, at(f, "d").text_emphasis_style.shape == .None && at(f, "d").text_emphasis_position.auto, "invalid")
	testing.expect(t, at(f, "a2").text_emphasis_style.shape == .None, "the shorthand resets the style")
}

@(test)
stroke_values :: proc(t: ^testing.T) {
	f := fixture_load(`<style>#a { -webkit-text-stroke: 2px red; } #b { -webkit-text-stroke: red thin; } #c { -webkit-text-stroke-width: -1px; }</style>
		<div id=a><i id=in>x</i></div><p id=b>x</p><p id=c>x</p>`)
	defer fixture_unload(f)
	a := at(f, "a")
	testing.expect(t, a.text_stroke_width == 2 && !a.text_stroke_color.auto && stroke_color(a).r == 1)
	testing.expect(t, at(f, "in").text_stroke_width == 2, "it inherits")
	testing.expect(t, at(f, "b").text_stroke_width == LINE_WIDTH_THIN)
	testing.expect(t, at(f, "c").text_stroke_width == 0, "no negative width")
}

@(test)
what_animates_and_what_flips :: proc(t: ^testing.T) {
	f := fixture_load(`<style>
		#a { -webkit-text-stroke-width: 0; text-underline-offset: 0; text-decoration-skip-ink: none; text-decoration-thickness: 0; text-emphasis-color: rgb(0, 0, 0); text-decoration-inset: 0 }
		#b { -webkit-text-stroke-width: 4px; text-underline-offset: 10px; text-decoration-skip-ink: all; text-decoration-thickness: 50%; text-emphasis-color: rgb(255, 255, 255); text-decoration-inset: 10px 20px }
		</style><p id=a>x</p><p id=b>x</p>`)
	defer fixture_unload(f)
	a, b := at(f, "a"), at(f, "b")
	ctx := Interp_Ctx{alloc = context.temp_allocator}
	out := new_clone(a^, context.temp_allocator)
	for g in Group { group_take(out, g, context.temp_allocator) }
	testing.expect(t, interpolate_prop(out, a, b, .Text_Stroke_Width, 0.5, &ctx) && math.abs(out.text_stroke_width - 2) < 1e-4, "a width")
	testing.expect(t, interpolate_prop(out, a, b, .Text_Underline_Offset, 0.5, &ctx) && math.abs(out.text_underline_offset.v - 5) < 1e-4, "an offset")
	testing.expect(t, interpolate_prop(out, a, b, .Text_Decoration_Thickness, 0.5, &ctx), "a length and a percentage")
	testing.expect(t, interpolate_prop(out, a, b, .Text_Emphasis_Color, 0.5, &ctx) && out.text_emphasis_color.color.r > 0.3, "a color")
	testing.expect(t, interpolate_prop(out, a, b, .Text_Decoration_Inset, 0.5, &ctx) && out.text_decoration_inset[1].v == 10, "an inset")
	testing.expect(t, !interpolate_prop(out, a, b, .Text_Decoration_Skip_Ink, 0.5, &ctx), "text-decoration-skip-ink is discrete")
}
