package style

import "base:runtime"
import "core:math"
import "core:strings"
import "core:sync"
import "wb:base"
import "wb:config"
import "wb:css"
import "wb:dom"

// Color schemes (CSS Color Adjustment 1, HTML <meta name="color-scheme">) and system colors (CSS Color 4 §6.2).
//
// `color-scheme` (inherited) lists the schemes an element is designed for; the root element whose value is `normal`
// takes the page's color scheme from the first valid <meta name="color-scheme"> of the document. The *used* scheme of
// an element is the user's preference (style.color_scheme, which follows Windows when set to auto) when the element
// supports it, else the scheme it supports, else light. It decides, per element, which set of system colors (Canvas,
// CanvasText, LinkText...) and which branch of light-dark() a value means. The two sets are preferences
// (page.color.* and page.color.dark.*), with Chromium's values on Windows as defaults; highlight and accent colors may
// follow the system (`system`).
//
// `color` is inherited as specified when it depends on the scheme (CSS Color 4: system colors and light-dark() are
// resolved with the color scheme of the element that uses them): the computed style keeps the value resolved in both
// schemes (`color_pair`), and a child whose used scheme differs from its parent's shows the other one. Other color
// properties are resolved with the scheme of the element they are declared on.

Scheme :: enum u8 { Light, Dark }

// The computed value of color-scheme: {} is `normal`; `.Listed` marks a list (which may name only custom schemes).
Scheme_Flag :: enum u8 { Listed, Light, Dark, Only }
Color_Scheme_Value :: bit_set[Scheme_Flag; u8]

System_Color :: enum u8 {
	Canvas, Canvas_Text, Link_Text, Visited_Text, Active_Text, Button_Face, Button_Text, Button_Border, Field, Field_Text,
	Highlight, Highlight_Text, Selected_Item, Selected_Item_Text, Mark, Mark_Text, Gray_Text, Accent_Color, Accent_Color_Text,
}

// A color resolved in each scheme (equal halves: it does not depend on the scheme).
Scheme_Color :: struct { light, dark: css.Color }

scheme_pick :: #force_inline proc(sc: Scheme_Color, s: Scheme) -> css.Color { return s == .Dark ? sc.dark : sc.light }

// The used color scheme of an element whose color-scheme is `v`, for a user who prefers dark (or not).
used_scheme :: proc(v: Color_Scheme_Value, prefer_dark: bool) -> Scheme {
	if .Light in v && .Dark in v { return prefer_dark ? .Dark : .Light }
	if .Dark in v { return .Dark }
	return .Light
}

////////////////////////////////
// The operating system's appearance

// What the shell reads from the platform (Windows: the apps theme, the accent color, the selection colors). The style
// package only stores it: preferences set to `system` and style.color_scheme = auto resolve against it.
Os_Appearance :: struct {
	known:          bool,
	dark:           bool,         // the user's apps theme is dark
	has_accent:     bool,
	accent:         css.Color,
	has_highlight:  bool,
	highlight:      css.Color,    // selection background (GetSysColor(COLOR_HIGHLIGHT))
	highlight_text: css.Color,
}

@(private) os_look: Os_Appearance

// Records the platform's appearance; true when it differs from what was known (settings must then be derived again:
// settings_from_prefs reads it, and pages restyle).
set_os_appearance :: proc(a: Os_Appearance) -> bool {
	if a == os_look { return false }
	os_look = a
	return true
}

os_appearance :: proc() -> Os_Appearance { return os_look }

////////////////////////////////
// System colors

@(private)
SYSTEM_COLOR_NAMES := [?]struct { name: string, c: System_Color }{
	{"canvas", .Canvas}, {"canvastext", .Canvas_Text}, {"linktext", .Link_Text}, {"visitedtext", .Visited_Text},
	{"activetext", .Active_Text}, {"buttonface", .Button_Face}, {"buttontext", .Button_Text}, {"buttonborder", .Button_Border},
	{"field", .Field}, {"fieldtext", .Field_Text}, {"highlight", .Highlight}, {"highlighttext", .Highlight_Text},
	{"selecteditem", .Selected_Item}, {"selecteditemtext", .Selected_Item_Text}, {"mark", .Mark}, {"marktext", .Mark_Text},
	{"graytext", .Gray_Text}, {"accentcolor", .Accent_Color}, {"accentcolortext", .Accent_Color_Text},
	// deprecated system colors (CSS Color 4 §6.3), mapped as Chromium does
	{"activecaption", .Canvas}, {"appworkspace", .Canvas}, {"background", .Canvas}, {"inactivecaption", .Canvas},
	{"infobackground", .Canvas}, {"menu", .Canvas}, {"scrollbar", .Canvas}, {"window", .Canvas},
	{"captiontext", .Canvas_Text}, {"infotext", .Canvas_Text}, {"menutext", .Canvas_Text}, {"windowtext", .Canvas_Text},
	{"buttonhighlight", .Button_Face}, {"buttonshadow", .Button_Face}, {"threedface", .Button_Face},
	{"activeborder", .Button_Border}, {"inactiveborder", .Button_Border}, {"threeddarkshadow", .Button_Border},
	{"threedhighlight", .Button_Border}, {"threedlightshadow", .Button_Border}, {"threedshadow", .Button_Border},
	{"windowframe", .Button_Border}, {"inactivecaptiontext", .Gray_Text},
}

system_color_by_name :: proc(lower_name: string) -> (System_Color, bool) {
	for e in SYSTEM_COLOR_NAMES { if e.name == lower_name { return e.c, true } }
	return {}, false
}

// css.Color_Env.system: `user` is the engine's ^Settings.
@(private)
system_color :: proc(user: rawptr, name: string, dark: bool) -> (css.Color, bool) {
	sc, ok := system_color_by_name(name)
	if !ok { return {}, false }
	s := (^Settings)(user)
	return s.colors[dark ? .Dark : .Light][sc], true
}

// The value of a system color for these settings.
settings_color :: proc(s: ^Settings, c: System_Color, scheme: Scheme) -> css.Color { return s.colors[scheme][c] }

// Preference names (after "page.color." or "page.color.dark."), with Chromium's values on Windows. `system`: the
// platform's color (highlight, accent), else the second value; `auto` (text on accent): black or white, whichever
// contrasts more with the accent.
@(private)
COLOR_KEYS := [System_Color]struct { key: string, light, dark: string, what: string }{
	.Canvas             = {"background", "#ffffff", "#121212", "Background of pages that set none (Canvas)"},
	.Canvas_Text        = {"text", "#000000", "#ffffff", "Text of pages (CanvasText)"},
	.Link_Text          = {"link", "#0000ee", "#9e9eff", "Links (LinkText)"},
	.Visited_Text       = {"visited", "#551a8b", "#d0adf0", "Visited links (VisitedText)"},
	.Active_Text        = {"active_link", "#ff0000", "#ff0000", "Links being pressed (ActiveText)"},
	.Button_Face        = {"button_face", "#efefef", "#6b6b6b", "Background of buttons (ButtonFace)"},
	.Button_Text        = {"button_text", "#000000", "#ffffff", "Text of buttons (ButtonText)"},
	.Button_Border      = {"button_border", "#767676", "#6b6b6b", "Borders of buttons (ButtonBorder)"},
	.Field              = {"field", "#ffffff", "#3b3b3b", "Background of input fields (Field)"},
	.Field_Text         = {"field_text", "#000000", "#ffffff", "Text of input fields (FieldText)"},
	.Highlight          = {"highlight", "system", "system", "Background of selected text (Highlight)"},
	.Highlight_Text     = {"highlight_text", "system", "system", "Selected text (HighlightText)"},
	.Selected_Item      = {"selected_item", "system", "#99c8ff", "Background of selected items, in lists and menus (SelectedItem)"},
	.Selected_Item_Text = {"selected_item_text", "system", "#3b3b3b", "Text of selected items (SelectedItemText)"},
	.Mark               = {"mark", "#ffff00", "#ffff00", "Background of <mark> (Mark)"},
	.Mark_Text          = {"mark_text", "#000000", "#000000", "Text of <mark> (MarkText)"},
	.Gray_Text          = {"gray_text", "#808080", "#808080", "Disabled text (GrayText)"},
	.Accent_Color       = {"accent", "system", "system", "Accent of checkboxes, radio buttons, sliders, progress bars (AccentColor)"},
	.Accent_Color_Text  = {"accent_text", "auto", "auto", "Text on the accent color (AccentColorText)"},
}

// Chromium's values where a preference says `system` and the platform tells nothing.
@(private)
FALLBACK_SYSTEM := [System_Color]u32{
	.Highlight = 0x1967d2, .Highlight_Text = 0xffffff, .Selected_Item = 0x1967d2, .Selected_Item_Text = 0xffffff,
	.Accent_Color = 0x0075ff,
	.Canvas = 0, .Canvas_Text = 0, .Link_Text = 0, .Visited_Text = 0, .Active_Text = 0, .Button_Face = 0, .Button_Text = 0,
	.Button_Border = 0, .Field = 0, .Field_Text = 0, .Mark = 0, .Mark_Text = 0, .Gray_Text = 0, .Accent_Color_Text = 0,
}

@(private) color_prefs_once: sync.Once
@(private) color_prefs: [2 * len(System_Color)]config.Def

// The page.color.* and page.color.dark.* preferences (built once, process-wide, kept for good).
color_pref_defs :: proc() -> []config.Def {
	sync.once_do(&color_prefs_once, proc() {
		context.allocator = runtime.heap_allocator()
		for k, c in COLOR_KEYS {
			i := int(c)
			hint := ""
			if k.light == "system" { hint = " `system` = the color Windows uses." }
			if k.light == "auto" { hint = " `auto` = black or white, whichever contrasts more with the accent." }
			color_prefs[i] = config.Def{
				name = strings.concatenate({"page.color.", k.key}, context.allocator), kind = .String, default = {s = k.light},
				description = strings.concatenate({k.what, " in the light color scheme (CSS color).", hint}, context.allocator),
			}
			color_prefs[len(System_Color) + i] = config.Def{
				name = strings.concatenate({"page.color.dark.", k.key}, context.allocator), kind = .String, default = {s = k.dark},
				description = strings.concatenate({k.what, " in the dark color scheme: pages that declare color-scheme: dark, or light dark when dark is preferred (CSS color).", hint}, context.allocator),
			}
		}
	})
	return color_prefs[:]
}

@(private)
contrast_text :: proc(bg: css.Color) -> css.Color {
	lin :: proc(x: f32) -> f32 { return x <= 0.04045 ? x / 12.92 : f32(math.pow(f64((x + 0.055) / 1.055), 2.4)) }
	l := 0.2126 * lin(bg.r) + 0.7152 * lin(bg.g) + 0.0722 * lin(bg.b)
	// Chromium's color_utils::IsDark (as Firefox's AccentColorText): the luminance whose contrast with black and with
	// white is the same, 0.211692
	return l < 0.211692 ? css.Color{1, 1, 1, 1} : css.Color{0, 0, 0, 1}
}

// Fills s.colors from the preferences and the platform's appearance.
@(private)
colors_from_prefs :: proc(p: ^config.Prefs, s: ^Settings) {
	look := os_look
	for scheme in Scheme {
		prefix := scheme == .Dark ? "page.color.dark." : "page.color."
		autos: [System_Color]bool
		for k, c in COLOR_KEYS {
			text := strings.trim_space(config.string_of(p, strings.concatenate({prefix, k.key}, context.temp_allocator)))
			fallback := scheme == .Dark ? k.dark : k.light
			switch {
			case strings.equal_fold(text, "auto"):
				autos[c] = true
			case strings.equal_fold(text, "system"):
				s.colors[scheme][c] = system_value(look, c, s.colors[scheme])
			case:
				col, ok := parse_pref_color(text)
				if !ok { col, ok = parse_pref_color(fallback) }
				if !ok { col = system_value(look, c, s.colors[scheme]) }
				s.colors[scheme][c] = col
			}
		}
		for c in System_Color {
			if !autos[c] { continue }
			#partial switch c {
			case .Accent_Color_Text: s.colors[scheme][c] = contrast_text(s.colors[scheme][.Accent_Color])
			case .Highlight_Text: s.colors[scheme][c] = contrast_text(s.colors[scheme][.Highlight])
			case .Selected_Item_Text: s.colors[scheme][c] = contrast_text(s.colors[scheme][.Selected_Item])
			case: s.colors[scheme][c] = contrast_text(s.colors[scheme][.Canvas])
			}
		}
	}
}

// What `system` means for one color.
@(private)
system_value :: proc(look: Os_Appearance, c: System_Color, so_far: [System_Color]css.Color) -> css.Color {
	#partial switch c {
	case .Highlight, .Selected_Item: if look.has_highlight { return look.highlight }
	case .Highlight_Text, .Selected_Item_Text: if look.has_highlight { return look.highlight_text }
	case .Accent_Color: if look.has_accent { return look.accent }
	case .Accent_Color_Text: return contrast_text(so_far[.Accent_Color])
	}
	return css.color_from_u32(FALLBACK_SYSTEM[c])
}

@(private)
parse_pref_color :: proc(text: string) -> (css.Color, bool) {
	arena := context.temp_allocator
	toks := css.tokenize(text, arena)
	vals := make([dynamic]css.Value, arena)
	for t in toks { append(&vals, css.Value{kind = .Token, tok = t}) }
	if cv, ok := css.parse_color(vals[:], nil); ok && cv.kind == .Rgba { return cv.rgba, true }
	if len(text) > 0 && (strings.contains(text, "(")) {
		vs := css.parse_component_values(text, {max_nesting_depth = 32, max_rules = 1}, arena)
		if cv, ok := css.parse_color(vs, nil); ok && cv.kind == .Rgba { return cv.rgba, true }
	}
	return {}, false
}

////////////////////////////////
// The property

// color-scheme: normal | [ light | dark | <custom-ident> ]+ && only?
parse_color_scheme :: proc(vs: []css.Value) -> (Color_Scheme_Value, bool) {
	items := split_items(css.trim_values(vs))
	if len(items) == 0 { return {}, false }
	v: Color_Scheme_Value
	names := 0
	for it in items {
		if it.kind != .Token || it.tok.kind != .Ident { return {}, false }
		id := strings.to_lower(it.tok.text, context.temp_allocator)
		switch id {
		case "normal":
			if len(items) != 1 { return {}, false }
			return {}, true
		case "only":
			if .Only in v { return {}, false }
			v += {.Only}
		case "light": v += {.Light}; names += 1
		case "dark": v += {.Dark}; names += 1
		case "initial", "inherit", "unset", "revert", "revert-layer", "default":
			return {}, false
		case: names += 1   // a scheme this browser does not know: allowed, and ignored
		}
	}
	if names == 0 { return {}, false }
	return v + {.Listed}, true
}

// After color-scheme is known (inherited, initial or declared): the root takes the page's scheme when its value is
// normal; the used scheme follows; colors resolve with it from here on, and an inherited `color` that depends on the
// scheme is re-resolved.
@(private)
scheme_settle :: proc(cx: ^Cx, page_scheme: Color_Scheme_Value, prefer_dark: bool) {
	c := cx.c
	if cx.parent == nil && c.color_scheme == {} { c.color_scheme = page_scheme }
	c.used_scheme = used_scheme(c.color_scheme, prefer_dark)
	cx.cenv.dark = c.used_scheme == .Dark
	c.color = scheme_pick(c.color_pair, c.used_scheme)
}

// `color`: resolved for both schemes when the value can depend on it (system colors, light-dark()).
@(private)
apply_color :: proc(cx: ^Cx, vs: []css.Value) -> bool {
	c := cx.c
	if id, ok := ident_raw(vs); ok && strings.equal_fold(id, "currentcolor") {
		// `color: currentcolor` is `inherit`
		if cx.parent != nil { c.color_pair = cx.parent.color_pair } else { c.color_pair = cx.initial.color_pair }
		c.color = scheme_pick(c.color_pair, c.used_scheme)
		return true
	}
	env := cx.cenv
	env.dark = false
	light, ok := css.parse_color(vs, &env)
	if !ok || light.kind != .Rgba { return false }
	pair := Scheme_Color{light.rgba, light.rgba}
	if scheme_sensitive(vs) {
		env.dark = true
		if dark, ok2 := css.parse_color(vs, &env); ok2 && dark.kind == .Rgba { pair.dark = dark.rgba }
	}
	c.color_pair = pair
	c.color = scheme_pick(pair, c.used_scheme)
	return true
}

// The value names something whose meaning may follow the color scheme: an identifier (a system color) or a function
// that may hold one (light-dark(), color-mix()).
@(private)
scheme_sensitive :: proc(vs: []css.Value) -> bool {
	for v in vs {
		switch v.kind {
		case .Token: if v.tok.kind == .Ident { return true }
		case .Function, .Block: if strings.equal_fold(v.tok.text, "light-dark") || scheme_sensitive(v.children) { return true }
		}
	}
	return false
}

////////////////////////////////
// The page's color scheme (<meta name="color-scheme">)

// HTML: the first <meta name="color-scheme" content> of the document, in tree order, whose content is a valid
// color-scheme value. `metas` gets every candidate element (whatever its content), so that a later change of the DOM
// can tell whether it concerns them.
page_color_scheme :: proc(doc: ^dom.Document, metas: ^[dynamic]base.Handle = nil) -> (v: Color_Scheme_Value, found: bool) {
	if metas != nil { clear(metas) }
	root := dom.get(doc, doc.root)
	if root == nil { return }
	stack := make([dynamic]base.Handle, 0, 64, context.temp_allocator)
	for ch := root.last_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).prev { append(&stack, ch) }
	for len(stack) > 0 {
		h := pop(&stack)
		n := dom.get(doc, h)
		if n == nil || n.kind != .Element { continue }
		if n.name == "meta" {
			name, has_name := attr(n, "name")
			if has_name && strings.equal_fold(strings.trim(name, " \t\n\r\f"), "color-scheme") {
				if content, has := attr(n, "content"); has {
					if metas != nil { append(metas, h) }
					if !found {
						vals := css.parse_component_values(content, {max_nesting_depth = 32, max_rules = 1}, context.temp_allocator)
						if pv, ok := parse_color_scheme(vals); ok { v, found = pv, true }
					}
				}
			}
			continue
		}
		if metas == nil && found { break }
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).prev { append(&stack, ch) }
	}
	return
}

// Whether the mutations `entries` may have changed the page's color scheme of `s` (a <meta> inserted, removed or
// edited); the caller then restyles everything. Rescans the document only when a mutation concerns a <meta>.
@(private)
meta_scheme_changed :: proc(doc: ^dom.Document, s: ^Styled, entries: []dom.Journal_Entry) -> bool {
	suspect := false
	removal := false
	check: for &en in entries {
		switch en.kind {
		case .Insert:
			n := dom.get(doc, en.node)
			if n == nil || n.kind != .Element { continue }
			stack := make([dynamic]base.Handle, 0, 16, context.temp_allocator)
			append(&stack, en.node)
			for len(stack) > 0 {
				x := pop(&stack)
				xn := dom.get(doc, x)
				if xn == nil || xn.kind != .Element { continue }
				if xn.name == "meta" { suspect = true; break check }
				for ch := xn.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
			}
		case .Remove:
			removal = true
		case .Attribute:
			if en.name != "name" && en.name != "content" { continue }
			if n := dom.get(doc, en.node); n != nil && n.kind == .Element && n.name == "meta" { suspect = true; break check }
		case .Text:
		}
	}
	if !suspect && removal {
		for h in s.scheme_metas { if !connected(doc, h) { suspect = true; break } }
	}
	if !suspect { return false }
	v, _ := page_color_scheme(doc, &s.scheme_metas)
	return v != s.page_scheme
}
