package browser

import "toolkit:draw"
import "wb:css"
import "wb:style"

// Colors the shell paints into pages itself (form controls, their drop-down list and validation bubble, scroll bars),
// taken from the system colors of the element's used color scheme (style.Settings.colors, preferences page.color.* and
// page.color.dark.*), so that a control in a `color-scheme: dark` page is a dark control.

Control_Palette :: struct {
	scheme:        style.Scheme,
	accent:        draw.Color,   // accent-color, else AccentColor
	accent_text:   draw.Color,
	field:         draw.Color,
	field_text:    draw.Color,
	face:          draw.Color,   // ButtonFace
	face_text:     draw.Color,
	border:        draw.Color,   // ButtonBorder
	track:         draw.Color,   // unfilled part of a slider
	selected:      draw.Color,   // SelectedItem
	selected_text: draw.Color,
	inactive:      draw.Color,   // selected item of an unfocused list
	hover:         draw.Color,
	highlight:     draw.Color,   // text selection of a focused field
	highlight_dim: draw.Color,   // ... of an unfocused one
	focus_ring:    draw.Color,
	popup_border:  draw.Color,
	shadow:        draw.Color,
	mark_off:      draw.Color,   // the dash of an indeterminate checkbox that is not checked
}

@(private = "file")
dc_of :: proc(c: css.Color, alpha: f32 = 1) -> draw.Color {
	d := to_draw(c)
	d.a *= alpha
	return d
}

// The palette of a control styled `cs` (nil: the user's preferred scheme).
control_palette :: proc(cs: ^style.Computed) -> Control_Palette {
	s := &the_app.page_settings.style
	scheme := cs != nil ? cs.used_scheme : style.preferred_scheme(s)
	col := &s.colors[scheme]
	dark := scheme == .Dark
	p := Control_Palette{scheme = scheme}
	p.accent = dc_of(col[.Accent_Color])
	p.accent_text = dc_of(col[.Accent_Color_Text])
	if cs != nil && !cs.accent_color.auto {
		p.accent = dc_of(cs.accent_color.color)
		l := 0.2126 * cs.accent_color.color.r + 0.7152 * cs.accent_color.color.g + 0.0722 * cs.accent_color.color.b
		p.accent_text = l < 0.5 ? draw.hex(0xffffffff) : draw.hex(0x000000ff)
	}
	p.field, p.field_text = dc_of(col[.Field]), dc_of(col[.Field_Text])
	p.face, p.face_text, p.border = dc_of(col[.Button_Face]), dc_of(col[.Button_Text]), dc_of(col[.Button_Border])
	p.selected, p.selected_text = dc_of(col[.Selected_Item]), dc_of(col[.Selected_Item_Text])
	p.highlight = dc_of(col[.Highlight], 0.45)
	p.highlight_dim = dc_of(col[.Gray_Text], 0.35)
	p.track = dark ? draw.hex(0x545454ff) : draw.hex(0xc8c8c8ff)
	p.inactive = dark ? draw.hex(0x545454ff) : draw.hex(0xc8c8c8ff)
	p.hover = p.selected
	p.hover.a *= 0.2
	p.focus_ring = dark ? draw.hex(0x99c8ffff) : draw.hex(0x4d90feff)
	p.popup_border = dark ? draw.hex(0x6b6b6bff) : draw.hex(0x9a9a9aff)
	p.shadow = dark ? draw.hex(0x00000080) : draw.hex(0x00000030)
	p.mark_off = dc_of(col[.Field_Text], 0.8)
	return p
}

// The colors of a scroll bar (arrow: of the arrow buttons of classic bars).
Bar_Colors :: struct {
	thumb, track, arrow: css.Color,
	thumb_hover, thumb_pressed, button_hover, button_pressed: css.Color,   // what the pointer does to them (bar_states)
}

// How far a part of a bar goes from its color when the pointer is on it or holds it, toward white or black.
@(private = "file") BAR_THUMB_HOVER_MIX :: 0.13
@(private = "file") BAR_THUMB_PRESSED_MIX :: 0.38
@(private = "file") BAR_BUTTON_HOVER_MIX :: 0.1
@(private = "file") BAR_BUTTON_PRESSED_MIX :: 0.28
// Under this a color of the page's scrollbar-color is dark: its states go toward white.
@(private = "file") BAR_DARK_BELOW :: 0.5

// Scroll bar colors for a scroller (or the document) whose used color scheme is `scheme` and whose style is `cs` (nil:
// none): those of overlay or classic bars in that scheme (the layout preferences in the light one,
// browser.scrollbar.dark.* in the dark one), then the element's scrollbar-color (its arrows take the thumb's).
scrollbar_colors :: proc(scheme: style.Scheme, cs: ^style.Computed) -> (c: Bar_Colors) {
	set := &the_app.page_render.settings
	dark := scheme == .Dark
	switch {
	case set.scrollbar_overlay && dark: c = {thumb = the_app.scheme_ui.dark_thumb, track = the_app.scheme_ui.dark_track}
	case set.scrollbar_overlay: c = {thumb = set.scrollbar_thumb, track = set.scrollbar_track}
	case dark: c = the_app.scheme_ui.dark_classic
	case: c = {thumb = set.classic_thumb, track = set.classic_track, arrow = set.classic_arrow}
	}
	if cs != nil && !cs.scrollbar_color.auto { c = {thumb = cs.scrollbar_color.thumb, track = cs.scrollbar_color.track, arrow = cs.scrollbar_color.thumb} }
	bar_states(&c, cs != nil && !cs.scrollbar_color.auto ? bar_luma(c.thumb) < BAR_DARK_BELOW : dark)
	return
}

@(private = "file")
bar_luma :: proc(c: css.Color) -> f32 { return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2] }

// The colors of a bar under the pointer, from its own: a light bar darkens, a dark one lights up, and what is see-through fills in.
@(private = "file")
bar_states :: proc(c: ^Bar_Colors, lighten: bool) {
	toward := css.Color{0, 0, 0, 1}
	if lighten { toward = {1, 1, 1, 1} }
	mixed :: proc(from, to: css.Color, f: f32) -> css.Color { return from + (to - from) * f }
	c.thumb_hover, c.thumb_pressed = mixed(c.thumb, toward, BAR_THUMB_HOVER_MIX), mixed(c.thumb, toward, BAR_THUMB_PRESSED_MIX)
	c.button_hover, c.button_pressed = mixed(c.track, toward, BAR_BUTTON_HOVER_MIX), mixed(c.track, toward, BAR_BUTTON_PRESSED_MIX)
}
