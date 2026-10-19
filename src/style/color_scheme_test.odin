package style

import "core:math"
import "core:testing"
import "wb:config"
import "wb:css"
import "wb:dom"
import "wb:html"

// color-scheme, the page's scheme (<meta name="color-scheme">), used schemes, system colors and light-dark() per element.

@(private = "file")
Sx :: struct {
	doc: ^dom.Document,
	eng: ^Engine,
	st:  ^Styled,
}

@(private = "file")
sx_load :: proc(src: string, prefer_dark: bool, settings: ^Settings = nil) -> ^Sx {
	f := new(Sx)
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, 100_000)
	if settings != nil {
		f.eng = engine_make(settings^)
	} else {
		ss := settings_default()
		f.eng = engine_make(ss)
		settings_destroy(&ss)
	}
	engine_set_journal(f.eng, 1 << 16)
	f.eng.settings.inc_max_ratio = 1
	env := f.eng.env
	env.prefers_dark = prefer_dark
	engine_set_environment(f.eng, env)
	sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = compute_styles(f.eng, f.doc, {})
	dom.journal_enable(f.doc, 1 << 16)
	return f
}

@(private = "file")
sx_unload :: proc(f: ^Sx) {
	styled_destroy(f.st)
	engine_destroy(f.eng)
	dom.document_destroy(f.doc)
	free(f)
}

@(private = "file")
sx :: proc(f: ^Sx, id: string) -> ^Computed { return style_of(f.st, dom.find_by_id(f.doc, id)) }

@(private = "file")
hexc :: proc(rgb: u32) -> css.Color { return css.color_from_u32(rgb) }

@(private = "file")
same :: proc(a, b: css.Color) -> bool {
	for i in 0 ..< 4 { if math.abs(a[i] - b[i]) > 0.01 { return false } }
	return true
}

// Restyles after mutations: partial when possible, else full; the result must be what a full pass gives.
@(private = "file")
sx_step :: proc(t: ^testing.T, f: ^Sx, what: string, loc := #caller_location) -> (partial: bool) {
	_, ok := restyle_dom(f.eng, f.doc, f.st)
	if !ok {
		old := f.st
		f.st = compute_styles(f.eng, f.doc, {})
		styled_destroy(old)
	}
	diff := verify_styles(f.eng, f.doc, f.st, context.temp_allocator)
	testing.expectf(t, diff == "", "%s: %s", what, diff, loc = loc)
	return ok
}

// `color: currentcolor` is `inherit`: declared in a sheet it is validated without an element (probe context), on the
// root it takes the initial color (https://sacha.house crashed on it).
@(test)
color_currentcolor_everywhere :: proc(t: ^testing.T) {
	f := sx_load(`<style>:root{color:currentColor} p{color:currentcolor} @supports (color: currentColor) { b{color:red} }</style><body style="color:#123456"><p id=p>x <b id=b>y</b></p></body>`, false)
	defer sx_unload(f)
	testing.expect(t, same(sx(f, "p").color, hexc(0x123456)), "currentcolor inherits")
	testing.expect(t, same(sx(f, "b").color, hexc(0xff0000)), "@supports (color: currentColor) holds")
	root := style_of(f.st, f.doc.root)
	testing.expect(t, root == nil || root.color.a > 0, "the root has a color")
}

@(test)
color_scheme_values :: proc(t: ^testing.T) {
	ok_cases := [?]struct { src: string, v: Color_Scheme_Value }{
		{"normal", {}}, {"light", {.Listed, .Light}}, {"dark", {.Listed, .Dark}}, {"light dark", {.Listed, .Light, .Dark}},
		{"dark light", {.Listed, .Light, .Dark}}, {"only light", {.Listed, .Light, .Only}}, {"dark only", {.Listed, .Dark, .Only}},
		{"my-theme", {.Listed}}, {"my-theme dark", {.Listed, .Dark}}, {"only foo", {.Listed, .Only}}, {"LIGHT Dark", {.Listed, .Light, .Dark}},
	}
	for c in ok_cases {
		vs := css.parse_component_values(c.src, {max_nesting_depth = 32, max_rules = 1}, context.temp_allocator)
		v, ok := parse_color_scheme(vs)
		testing.expectf(t, ok && v == c.v, "%q: %v %v", c.src, v, ok)
	}
	for bad in ([?]string{"", "only", "only only dark", "normal light", "light normal", "default", "inherit dark", "light 3px", "light, dark"}) {
		vs := css.parse_component_values(bad, {max_nesting_depth = 32, max_rules = 1}, context.temp_allocator)
		_, ok := parse_color_scheme(vs)
		testing.expectf(t, !ok, "%q must be invalid", bad)
	}
	testing.expect_value(t, used_scheme({}, true), Scheme.Light)
	testing.expect_value(t, used_scheme({.Listed}, true), Scheme.Light)
	testing.expect_value(t, used_scheme({.Listed, .Dark}, false), Scheme.Dark)
	testing.expect_value(t, used_scheme({.Listed, .Light}, true), Scheme.Light)
	testing.expect_value(t, used_scheme({.Listed, .Light, .Dark}, true), Scheme.Dark)
	testing.expect_value(t, used_scheme({.Listed, .Light, .Dark}, false), Scheme.Light)
}

@(test)
used_schemes_and_inheritance :: proc(t: ^testing.T) {
	SRC :: `<style>
		#d { color-scheme: dark } #l { color-scheme: light } #b { color-scheme: light dark } #o { color-scheme: only dark }
		#n { color-scheme: normal } #c { color-scheme: my-own } #bad { color-scheme: normal dark }
	</style>
	<div id=d><p id=d_in>x</p><div id=l><p id=l_in>y</p></div><div id=n>n</div><div id=bad>b</div></div>
	<div id=b>b</div><div id=o>o</div><div id=c>c</div><p id=plain>p</p>`
	for dark in ([2]bool{false, true}) {
		f := sx_load(SRC, dark)
		defer sx_unload(f)
		testing.expect_value(t, sx(f, "d").used_scheme, Scheme.Dark)
		testing.expect_value(t, sx(f, "d_in").used_scheme, Scheme.Dark)                  // inherited
		testing.expect_value(t, sx(f, "l_in").used_scheme, Scheme.Light)                 // overridden below a dark one
		testing.expect_value(t, sx(f, "n").used_scheme, Scheme.Light)                    // normal: the browser default
		testing.expect_value(t, sx(f, "bad").used_scheme, Scheme.Dark)                   // invalid declaration: inherits
		testing.expect_value(t, sx(f, "b").used_scheme, dark ? Scheme.Dark : Scheme.Light)   // both: the preference
		testing.expect_value(t, sx(f, "o").used_scheme, Scheme.Dark)
		testing.expect_value(t, sx(f, "c").used_scheme, Scheme.Light)                    // only unknown schemes
		testing.expect_value(t, sx(f, "plain").used_scheme, Scheme.Light)
		testing.expect(t, sx(f, "d").color_scheme == {.Listed, .Dark})
	}
}

@(test)
system_colors_follow_the_element :: proc(t: ^testing.T) {
	f := sx_load(`<style>
		#d { color-scheme: dark } #l { color-scheme: light }
		.bg { background-color: Canvas; border: 1px solid ButtonBorder }
		.ld { background-color: light-dark(red, blue) }
		#ct { color: CanvasText } #mix { background-color: color-mix(in srgb, Canvas 50%, CanvasText) }
	</style>
	<div id=d><a id=da href=x>link</a><div id=dbg class=bg></div><div id=dld class=ld></div><input id=dinput><button id=dbutton>b</button>
		<mark id=dmark>m</mark><div id=mix></div>
		<div id=l><a id=la href=x>link</a><div id=lbg class=bg></div><div id=lld class=ld></div><input id=linput></div></div>
	<div id=ct><span id=ct_in>t</span><div id=ct_light style="color-scheme: light">t</div></div>`, true)
	defer sx_unload(f)
	testing.expect(t, same(sx(f, "da").color, hexc(0x9e9eff)), "LinkText of the dark scheme")
	testing.expect(t, same(sx(f, "la").color, hexc(0x0000ee)), "LinkText of the light scheme")
	testing.expect(t, same(sx(f, "dbg").background_color, hexc(0x121212)), "Canvas of the dark scheme")
	testing.expect(t, same(sx(f, "lbg").background_color, hexc(0xffffff)))
	testing.expect(t, same(sx(f, "dbg").border_color[.Top], hexc(0x6b6b6b)), "ButtonBorder")
	testing.expect(t, same(sx(f, "dld").background_color, hexc(0x0000ff)), "light-dark() in a dark element")
	testing.expect(t, same(sx(f, "lld").background_color, hexc(0xff0000)), "light-dark() in a light element")
	testing.expect(t, same(sx(f, "dinput").background_color, hexc(0x3b3b3b)) && same(sx(f, "dinput").color, hexc(0xffffff)), "Field / FieldText")
	testing.expect(t, same(sx(f, "linput").background_color, hexc(0xffffff)) && same(sx(f, "linput").color, hexc(0x000000)))
	testing.expect(t, same(sx(f, "dbutton").background_color, hexc(0x6b6b6b)), "ButtonFace")
	testing.expect(t, same(sx(f, "dmark").background_color, hexc(0xffff00)) && same(sx(f, "dmark").color, hexc(0x000000)), "Mark / MarkText")
	testing.expect(t, same(sx(f, "mix").background_color, hexc(0x898989)), "color-mix() of system colors")
	testing.expect(t, same(sx(f, "d").color, hexc(0xffffff)), "the initial color is CanvasText of the element's scheme")
	// `color: CanvasText` is inherited as CanvasText: a light child shows the light one
	testing.expect(t, same(sx(f, "ct").color, hexc(0x000000)))
	testing.expect(t, same(sx(f, "ct_in").color, hexc(0x000000)))
	testing.expect(t, same(sx(f, "ct_light").color, hexc(0x000000)))
	testing.expect_value(t, f.st.root_scheme, Scheme.Light)
	testing.expect(t, same(f.st.canvas, hexc(0xffffff)), "a light root: the light canvas")
}

@(test)
dark_text_inherited_into_light :: proc(t: ^testing.T) {
	f := sx_load(`<div id=d style="color-scheme: dark; color: CanvasText"><p id=p>x</p><p id=l style="color-scheme: light">y<b id=b>z</b></p>
		<p id=fixed style="color-scheme: light; color: inherit">w</p><p id=red style="color: red; color-scheme: light">r</p></div>`, false)
	defer sx_unload(f)
	testing.expect(t, same(sx(f, "d").color, hexc(0xffffff)))
	testing.expect(t, same(sx(f, "p").color, hexc(0xffffff)))
	testing.expect(t, same(sx(f, "l").color, hexc(0x000000)), "the child re-resolves an inherited system color in its own scheme")
	testing.expect(t, same(sx(f, "b").color, hexc(0x000000)))
	testing.expect(t, same(sx(f, "fixed").color, hexc(0x000000)), "inherit takes the specified system color too")
	testing.expect(t, same(sx(f, "red").color, hexc(0xff0000)), "an absolute color stays")
}

@(test)
page_color_scheme_meta :: proc(t: ^testing.T) {
	{
		f := sx_load(`<head><meta name=color-scheme content="bogus 12px"><meta name="Color-Scheme" content="dark"><meta name=color-scheme content=light></head><p id=p>x</p><a id=a href=y>l</a>`, false)
		defer sx_unload(f)
		testing.expect_value(t, sx(f, "p").used_scheme, Scheme.Dark)   // the first valid meta wins
		testing.expect(t, same(sx(f, "a").color, hexc(0x9e9eff)))
		testing.expect_value(t, f.st.root_scheme, Scheme.Dark)
		testing.expect(t, same(f.st.canvas, hexc(0x121212)), "the canvas of a dark page")
		testing.expect_value(t, len(f.st.scheme_metas), 3)
	}
	{
		f := sx_load(`<head><meta name=color-scheme content="light dark"></head><p id=p>x</p>`, true)
		defer sx_unload(f)
		testing.expect_value(t, sx(f, "p").used_scheme, Scheme.Dark)
	}
	{
		f := sx_load(`<head><meta name=color-scheme content="light dark"></head><p id=p>x</p>`, false)
		defer sx_unload(f)
		testing.expect_value(t, sx(f, "p").used_scheme, Scheme.Light)
	}
	{
		// the root's own value wins over the meta; a descendant declaring normal goes back to light
		f := sx_load(`<head><meta name=color-scheme content="dark"><style>:root { color-scheme: light } #n { color-scheme: normal }</style></head><p id=p>x</p>`, true)
		defer sx_unload(f)
		testing.expect_value(t, sx(f, "p").used_scheme, Scheme.Light)
	}
	{
		f := sx_load(`<head><meta name=color-scheme content="dark"><style>#n { color-scheme: normal }</style></head><div id=n><p id=p>x</p></div>`, true)
		defer sx_unload(f)
		testing.expect_value(t, sx(f, "p").used_scheme, Scheme.Light)
	}
	{
		// in <noscript>: this browser runs no script, the meta counts (webassembly.org)
		f := sx_load(`<head><noscript><meta name="color-scheme" content="light dark"></noscript></head><p id=p>x</p>`, true)
		defer sx_unload(f)
		testing.expect_value(t, sx(f, "p").used_scheme, Scheme.Dark)
	}
}

// webassembly.org: light and dark sheets chosen by media in <noscript>; the media of a sheet's owner must survive the
// rebuilds of the engine (its list lived in the engine's arena, reset by every rebuild: both sheets applied).
@(test)
sheets_chosen_by_prefers_color_scheme :: proc(t: ^testing.T) {
	SRC :: `<head><noscript>
		<style media="(prefers-color-scheme: light)">:root { color-scheme: light; background-color: #fefefe }</style>
		<style media="(prefers-color-scheme: dark)">:root { color-scheme: dark; background-color: #1e1e1e }</style>
		<meta name="color-scheme" content="light dark"></noscript></head><p id=p>x</p><a id=a href=y>l</a>`
	for dark in ([2]bool{false, true}) {
		f := sx_load(SRC, dark)
		defer sx_unload(f)
		for _ in 0 ..< 2 {
			testing.expect_value(t, sx(f, "p").used_scheme, dark ? Scheme.Dark : Scheme.Light)
			testing.expect(t, same(f.st.canvas, hexc(dark ? 0x1e1e1e : 0xfefefe)))
			testing.expect(t, same(sx(f, "a").color, hexc(dark ? 0x9e9eff : 0x0000ee)))
			f.eng.dirty = true   // a rebuild (a sheet added, preferences...) must change nothing
			styled_destroy(f.st)
			f.st = compute_styles(f.eng, f.doc, {})
		}
		// the preference changes: the other sheet applies
		env := f.eng.env
		env.prefers_dark = !dark
		engine_set_environment(f.eng, env)
		styled_destroy(f.st)
		f.st = compute_styles(f.eng, f.doc, {})
		testing.expect_value(t, sx(f, "p").used_scheme, dark ? Scheme.Light : Scheme.Dark)
	}
}

@(test)
meta_changes_restyle :: proc(t: ^testing.T) {
	f := sx_load(`<head><title>t</title></head><body><p id=p>x</p><a id=a href=y>l</a></body>`, false)
	defer sx_unload(f)
	testing.expect_value(t, sx(f, "p").used_scheme, Scheme.Light)
	head := dom.find_first_by_tag(f.doc, "head")
	m := dom.create_element(f.doc, "meta")
	dom.set_attribute(f.doc, m, "name", "color-scheme")
	dom.set_attribute(f.doc, m, "content", "dark")
	dom.append_child(f.doc, head, m)
	partial := sx_step(t, f, "meta inserted")
	testing.expect(t, !partial, "a new page scheme restyles everything")
	testing.expect_value(t, sx(f, "p").used_scheme, Scheme.Dark)
	testing.expect(t, same(sx(f, "a").color, hexc(0x9e9eff)))

	dom.set_attribute(f.doc, m, "content", "light")
	sx_step(t, f, "meta content changed")
	testing.expect_value(t, sx(f, "p").used_scheme, Scheme.Light)

	dom.set_attribute(f.doc, m, "content", "dark")
	sx_step(t, f, "back to dark")
	dom.remove_child(f.doc, head, m)
	sx_step(t, f, "meta removed")
	testing.expect_value(t, sx(f, "p").used_scheme, Scheme.Light)

	// an unrelated mutation stays partial
	dom.set_attribute(f.doc, dom.find_by_id(f.doc, "p"), "class", "q")
	testing.expect(t, sx_step(t, f, "class"), "an unrelated change is partial")
	// color-scheme set inline: the subtree restyles partially, exactly
	dom.set_attribute(f.doc, dom.find_first_by_tag(f.doc, "body"), "style", "color-scheme: dark")
	testing.expect(t, sx_step(t, f, "inline color-scheme"))
	testing.expect_value(t, sx(f, "p").used_scheme, Scheme.Dark)
	testing.expect(t, same(sx(f, "a").color, hexc(0x9e9eff)))
	testing.expect(t, same(sx(f, "p").color, hexc(0xffffff)))
}

@(test)
system_color_preferences :: proc(t: ^testing.T) {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	config.set_from_string(&p, "page.color.dark.link", "#00ff00", .User)
	config.set_from_string(&p, "page.color.background", "rgb(250 240 230)", .User)
	config.set_from_string(&p, "page.color.dark.field", "not a color", .User)
	saved := os_appearance()
	defer set_os_appearance(saved)
	set_os_appearance(Os_Appearance{known = true, has_accent = true, accent = {.Light = hexc(0xffd000), .Dark = hexc(0x3b5b76)}, has_highlight = true, highlight = hexc(0x0078d7), highlight_text = hexc(0xffffff)})
	s := settings_from_prefs(&p)
	defer settings_destroy(&s)
	testing.expect(t, same(s.colors[.Dark][.Link_Text], hexc(0x00ff00)))
	testing.expect(t, same(s.colors[.Light][.Canvas], css.Color{250.0 / 255, 240.0 / 255, 230.0 / 255, 1}))
	testing.expect(t, same(s.colors[.Dark][.Field], hexc(0x3b3b3b)), "an invalid value falls back to the default")
	testing.expect(t, same(s.colors[.Light][.Accent_Color], hexc(0xffd000)), "system: the platform's accent")
	testing.expect(t, same(s.colors[.Light][.Accent_Color_Text], hexc(0x000000)), "auto: black on a light accent")
	testing.expect(t, same(s.colors[.Dark][.Accent_Color], hexc(0x3b5b76)), "the accent of dark surfaces")
	testing.expect(t, same(s.colors[.Dark][.Accent_Color_Text], hexc(0xffffff)))
	testing.expect(t, same(s.colors[.Light][.Highlight], hexc(0x0078d7)))
	testing.expect(t, same(s.colors[.Dark][.Selected_Item], hexc(0x99c8ff)))

	set_os_appearance({})
	s2 := settings_from_prefs(&p)
	defer settings_destroy(&s2)
	testing.expect(t, same(s2.colors[.Light][.Accent_Color], hexc(0x0075ff)), "no platform accent: Chromium's")
	testing.expect(t, same(s2.colors[.Light][.Accent_Color_Text], hexc(0xffffff)))
	testing.expect(t, same(s2.colors[.Light][.Highlight], hexc(0x1967d2)))

	f := sx_load(`<style>p { color-scheme: dark }</style><p><a id=a href=x>l</a></p>`, false, &s)
	defer sx_unload(f)
	testing.expect(t, same(sx(f, "a").color, hexc(0x00ff00)), "the stylesheet follows the preference")
}
