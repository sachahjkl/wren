package browser

import "core:os"
import "core:strings"
import "core:testing"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import licence "toolkit:licence"
import "wb:wasm"

////////////////////////////////
// The third-party list

// A file of this run: the unit tests and their run under AddressSanitizer may be going on side by side.
@(private = "file")
about_scratch :: proc(name: string) -> string {
	return strings.concatenate({"build/tmp/", name, "_", base.unique_name(context.temp_allocator), ".wrenlicense"}, context.temp_allocator)
}

@(test)
third_party_table_is_parsed :: proc(t: ^testing.T) {
	test_app(t)
	md := "# x\n\n| Component | Version | License | Where |\n|---|---|---|---|\n" +
		"| [Foo](https://foo.example) | 1.2.3 (`vendor/foo`) | MIT; parts: a (MIT) | the foo `thing` |\n" +
		"| Bar and [Baz](https://baz.example) text | commit `0123456789abcdef` | Apache-2.0 | b |\n" +
		"| Qux | submodule `ext/qux` | MPL-2.0 | c |\n\nafter the table\n| not | a | table row |\n"
	list := third_party_list(md)
	testing.expect_value(t, len(list), 3)
	if len(list) != 3 { return }
	testing.expect_value(t, list[0].name, "Foo")
	testing.expect_value(t, list[0].url, "https://foo.example")
	testing.expect_value(t, list[0].version, "1.2.3")
	testing.expect_value(t, list[0].license, "MIT")
	testing.expect_value(t, list[0].where_, "the foo thing")
	testing.expect_value(t, list[1].version, "01234567")
	testing.expect_value(t, list[1].url, "")
	testing.expect_value(t, list[2].version, "")
}

@(test)
third_party_list_of_the_repository :: proc(t: ^testing.T) {
	test_app(t)
	list := third_party_list()
	testing.expect(t, len(list) >= 15, "THIRD_PARTY.md's table is parsed")
	seen := make(map[string]Third_Party, context.temp_allocator)
	for tp in list {
		testing.expectf(t, tp.name != "" && tp.license != "", "a row without a name or a license: %v", tp)
		seen[tp.name] = tp
	}
	for name in ([]string{"gui_toolkit", "Slug", "Wasmtime", "QuickJS-ng", "Lexbor", "emmalloc"}) {
		testing.expectf(t, name in seen, "%s is in THIRD_PARTY.md", name)
	}
	testing.expect_value(t, seen["gui_toolkit"].version, ui.VERSION)
	testing.expect_value(t, seen["Wasmtime"].version, wasm.WASMTIME_VERSION)
	testing.expect(t, strings.has_prefix(seen["Slug"].license, "MIT"), "Slug is MIT: its credit is required")
	testing.expect(t, seen["Slug"].url != "", "Slug links to its repository")
}

@(test)
pinned_versions_match_the_scripts :: proc(t: ^testing.T) {
	test_app(t)
	data, err := os.read_entire_file("src/tools/tooling/js_engine.odin", context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expectf(t, strings.contains(string(data), "QJS_VERSION :: \"" + QUICKJS_VERSION + "\""), "QUICKJS_VERSION (%s) is the version src\\tools\\tooling\\js_engine.odin pins", QUICKJS_VERSION)
	data, err = os.read_entire_file("src/tools/wrentool/deps/fetch.odin", context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expectf(t, strings.contains(string(data), "WASMTIME_VERSION :: \"" + wasm.WASMTIME_VERSION + "\""), "WASMTIME_VERSION (%s) is the version src\\tools\\wrentool\\deps\\fetch.odin pins", wasm.WASMTIME_VERSION)
}

// A license text added to native\js\licenses is shown by about:licenses (and shipped in licenses\ by wrentool package).
@(test)
every_shipped_license_text_is_shown :: proc(t: ^testing.T) {
	test_app(t)
	shipped := make(map[string]bool, context.temp_allocator)
	list, _ := os.read_all_directory_by_path("native/js/licenses", context.temp_allocator)
	testing.expect(t, len(list) >= 3, "native/js/licenses is found")
	for fi in list {
		data, _ := os.read_entire_file(strings.concatenate({"native/js/licenses/", fi.name}, context.temp_allocator), context.temp_allocator)
		found := false
		for lt in LICENSE_TEXTS { if lt.text == string(data) { found = true } }
		testing.expectf(t, found, "native/js/licenses/%s is not in LICENSE_TEXTS (third_party.odin)", fi.name)
		shipped[fi.name] = true
	}
	ids := make(map[string]bool, context.temp_allocator)
	for lt in LICENSE_TEXTS {
		testing.expectf(t, lt.id not_in ids && strings.trim_space(lt.text) != "", "license text %q: empty, or its id is used twice", lt.id)
		ids[lt.id] = true
	}
	testing.expect(t, "slug" in ids && "wren" in ids && "wasmtime" in ids, "Slug (credit required), Wren and Wasmtime texts are shown")
}

////////////////////////////////
// The page

@(private = "file")
test_page :: proc(theme: string, state: licence.Status = {}, notice: Wren_Notice = {}) -> Wren_Page {
	pal := ui.palette_of(strings.trim_suffix(theme, " light"), strings.has_suffix(theme, " light"))
	return {palette = pal, state = state, notice = notice, support_url = SUPPORT_URL, profile_dir = `C:\Users\x\AppData\Roaming\Wren`}
}

@(test)
about_page_without_a_license :: proc(t: ^testing.T) {
	test_app(t)
	for theme in ([]string{"graphite", "midnight light"}) {
		html := wren_page_html(test_page(theme))
		for want in ([]string{
			"Unregistered", "free during the beta", "Support Wren", SUPPORT_URL,
			"Wren is a beta under development.", "Every version is free; a license only supports development.",
			"Froment Software", FROMENT_URL, "data:image/png;base64,", "Version " + APP_VERSION, "Enter a license key", "WREN1",
			"gui_toolkit", "Slug", "Wasmtime", "QuickJS-ng", "Odin", "about:licenses",
		}) {
			testing.expectf(t, strings.contains(html, want), "about:wren (%s) lacks %q", theme, want)
		}
		testing.expect(t, !strings.contains(html, "Registered to"), "an unregistered Wren does not claim a registration")
		testing.expect(t, !strings.contains(html, "UNREGISTERED"), "no shouting")
		testing.expect(t, !strings.contains(html, "Remove the license"), "nothing to remove")
		pal := ui.palette_of(strings.trim_suffix(theme, " light"), strings.has_suffix(theme, " light"))
		testing.expectf(t, strings.contains(html, pal.dark ? "color-scheme: dark" : "color-scheme: light"), "%s's color scheme", theme)
		testing.expect(t, !strings.contains(html, "$"), "every theme token was replaced")
		testing.expect(t, !strings.contains(html, "<script") && !strings.contains(html, `id="lic"`), "no card, no script without a license")
		// the maker's signature is part of the header, under the tagline; the logo keeps its proportions in a narrow row
		sig := strings.index(html, `class="sig"`)
		testing.expect(t, sig > strings.index(html, "<h1>") && sig < strings.index(html, "beta under development"), "by Froment Software ends the header")
		testing.expect(t, strings.contains(html, "flex: none; object-fit: contain"), "the logo is neither squashed nor stretched")
	}
	// the two themes differ
	testing.expect(t, wren_page_html(test_page("graphite")) != wren_page_html(test_page("daylight")))
}

@(test)
the_card_can_be_previewed_without_a_licence :: proc(t: ^testing.T) {
	test_app(t)
	d := test_page("graphite")
	d.card_sample = true
	html := wren_page_html(d)
	for want in ([]string{`id="lic"`, "Sample Supporter", "-wren-shader: card-foil", "<script>", "Unregistered"}) {
		testing.expectf(t, strings.contains(html, want), "the preview lacks %q", want)
	}
	testing.expect(t, !strings.contains(html, "Registered to"), "nothing is registered")
	d.card_sample = false
	testing.expect(t, !strings.contains(wren_page_html(d), `id="lic"`), "no card without the preview or a license")
	testing.expect(t, is_builtin_href("about:wren?card=sample") && !is_builtin_href("about:blank") && !is_builtin_href("https://example.org/about:wren"), "the preview is a built-in page; about:blank is not")
}

@(test)
about_page_with_a_license :: proc(t: ^testing.T) {
	test_app(t)
	lic := licence.Licence{product = "wren", edition = "patron", name = "Zoé <b>Martin</b> & Co", email = "z@example.org", date = "2026-10-22", order = "WREN-0042"}
	state := licence.Status{licence = lic, registered = true, stored = true, covered = true}
	html := wren_page_html(test_page("graphite", state))
	for want in ([]string{"Registered to Zoé &lt;b&gt;Martin&lt;/b&gt; &amp; Co", "Patron license", "2026-10-22", "WREN-0042", "z@example.org", "Thank you", "Remove the license", "Replace the license"}) {
		testing.expectf(t, strings.contains(html, want), "about:wren with a license lacks %q", want)
	}
	testing.expect(t, !strings.contains(html, "Unregistered"), "a registered Wren is not unregistered")
	testing.expect(t, !strings.contains(html, "<b>Martin</b>"), "the name is escaped")
	for want in ([]string{`id="lic"`, "CERTIFIED", `class="seal"`, "<script>", "requestAnimationFrame", "prefers-reduced-motion", "-wren-shader: card-foil", "@property --sweep", `class="tickwrap"`, "text-shadow", "@media (max-width: 520px)"}) {
		testing.expectf(t, strings.contains(html, want), "the license card lacks %q", want)
	}
	testing.expect(t, strings.contains(html, "Zoé &lt;b&gt;Martin&lt;/b&gt; &amp; Co</div>"), "the card shows the escaped name")
	// the copy button: an icon inside, the three labels in one grid cell (so its width is the longest one's), and a script that only
	// changes the state, never the text
	for want in ([]string{`id="copylic"`, `class="i-copy"`, `class="i-ok"`, `class="l-idle">Copy the license details<`, `class="l-done" aria-live="polite">Copied<`, `class="l-fail">Copy failed<`, `currentColor`, `width="1em"`,
		"button.copy .lbs > span { grid-area: 1 / 1;", "button.copy .ics svg { grid-area: 1 / 1;", `setAttribute("data-state"`}) {
		testing.expectf(t, strings.contains(html, want), "the copy button lacks %q", want)
	}
	testing.expect(t, strings.index(html, `class="ics"`) < strings.index(html, `class="l-idle"`), "the icon is left of the text")
	testing.expect(t, !strings.contains(html, "b.textContent"), "the label's text is never swapped: the button keeps its width")
	// the seal: drawn by its own shader, the tick a whole stroked path (the rotated bordered box it was cut at its foot in a filter)
	for want in ([]string{`class="relief" data-engrave="CERTIFIED"`, "-wren-shader: card-seal", `<path d="M31.75 27.5L40.25 36L56.25 17"`, `stroke-linecap="round"`, `.lic .seal[data-shader=off] .edge`}) {
		testing.expectf(t, strings.contains(html, want), "the seal lacks %q", want)
	}
	testing.expect(t, !strings.contains(html, `class="tick"`), "no bordered box for the tick")
	testing.expect(t, !strings.contains(html, "setInterval") && !strings.contains(html, "requestAnimationFrame(loop"), "the card's script never loops: no frame at rest")
	// the logo is printed on the card: one picture, outside the layer whose parallax the pointer moves (it floated and snapped back on release),
	// and what does slide eases with the card
	card := html[strings.index(html, `class="cardbox"`):]
	testing.expect_value(t, strings.count(card[:strings.index(card, "<script>")], "<img"), 1)
	logo, face := strings.index(card, `<img class="logo"`), strings.index(card, `<div class="face">`)
	testing.expect(t, logo >= 0 && logo < face && !strings.contains(card[face:strings.index(card, `class="seal"`)], "<img"), "the logo is not in the face")
	testing.expect(t, strings.contains(html, ".lic .logo { position: absolute;") && !strings.contains(html[strings.index(html, ".lic .logo {"):][:240], ", 18px"), "the logo is in the base's plane, not lifted")
	for want in ([]string{"function follow(ms)", "face.style.transition = s; shadow.style.transition = s;", ".lic .face {", "transition: transform 0.55s", ".lic.live .face, .lic.live .seal .shadow { transition: none; }"}) {
		testing.expectf(t, strings.contains(html, want), "the parallax layers do not ease with the card: lacks %q", want)
	}
	// every page has the beta notice
	testing.expect(t, strings.contains(html, "Wren is a beta under development."))
}

@(test)
about_page_notices_and_rejected_store :: proc(t: ^testing.T) {
	test_app(t)
	state := licence.Status{stored = true, err = .Bad_Signature}
	html := wren_page_html(test_page("daylight", state, {"Nope <i>", true}))
	testing.expect(t, strings.contains(html, "Unregistered"))
	testing.expect(t, strings.contains(html, "The stored license was not accepted"))
	testing.expect(t, strings.contains(html, `class="notice bad">Nope &lt;i&gt;`))
	html = wren_page_html(test_page("daylight", {}, {"Fine", false}))
	testing.expect(t, strings.contains(html, `class="notice ok">Fine`))
}

@(test)
thanks_section_links_every_entry :: proc(t: ^testing.T) {
	test_app(t)
	html := wren_page_html(test_page("daylight"))
	heading :: "<h2>Thanks</h2>"
	start := strings.index(html, heading)
	testing.expect(t, start >= 0, "the thanks section is there")
	if start < 0 { return }
	section := html[start + len(heading):]
	if end := strings.index(section, "<h2>"); end >= 0 { section = section[:end] }
	testing.expect(t, strings.count(section, `<tr><td class="k">`) >= 11, "ten people or projects and the libraries")
	for want in ([]string{
		"https://caseymuratori.com", "https://x.com/Jonathan_Blow", "https://usgraphics.com", "https://x.com/ThePrimeagen",
		"https://gingerbill.org", "https://opencode.ai", "https://ladybird.org", "https://rfleury.com", "https://bellard.org",
		"https://lexbor.com", "https://github.com/EricLengyel/Slug", "https://github.com/bytecodealliance/wasmtime",
		"https://github.com/quickjs-ng/quickjs", "https://github.com/linebender/resvg",
	}) {
		testing.expectf(t, strings.contains(section, strings.concatenate({`href="`, want, `"`}, context.temp_allocator)), "the thanks section lacks a link to %s", want)
	}
	rest := section
	links := 0
	for {
		i := strings.index(rest, `href="`)
		if i < 0 { break }
		rest = rest[i + len(`href="`):]
		j := strings.index_byte(rest, '"')
		if j < 0 { break }
		href := rest[:j]
		links += 1
		testing.expectf(t, strings.has_prefix(href, "https://") || href == LICENSES_URL, "a link of the thanks section is not https: %q", href)
		rest = rest[j:]
	}
	testing.expect(t, links >= 15, "every entry links")
}

@(test)
licenses_page_has_every_text :: proc(t: ^testing.T) {
	test_app(t)
	html := licenses_page_html(test_page("graphite"))
	for lt in LICENSE_TEXTS {
		testing.expectf(t, strings.contains(html, strings.concatenate({`id="`, lt.id, `"`}, context.temp_allocator)), "licenses page lacks the anchor of %s", lt.id)
	}
	testing.expect(t, strings.contains(html, "Eric Lengyel") || strings.contains(html, "Slug"), "Slug is credited")
	testing.expect(t, strings.contains(html, "Permission is hereby granted"), "the MIT text is there")
	testing.expect(t, strings.contains(html, "about:wren"), "a way back")
}

@(test)
addresses_of_the_about_pages :: proc(t: ^testing.T) {
	test_app(t)
	for a in ([]string{"about:wren", "about:wren?choose=1", "about:wren?action=register&key=x", "about:wren#x", "about:licenses", "about:licenses#slug"}) {
		testing.expectf(t, is_wren_address(a) && is_builtin_address(a), "%s is a page of the browser", a)
	}
	for a in ([]string{"about:wrenx", "about:blank", "https://about:wren", "about:licensesx", "about:config"}) {
		testing.expectf(t, !is_wren_address(a), "%s is not", a)
	}
	testing.expect(t, is_license_file_address("file:///C:/Users/x/jeanne.wrenlicense"))
	testing.expect(t, is_license_file_address("file:///C:/Users/x/JEANNE.WRENLICENSE"))
	testing.expect(t, is_license_file_address("file:///C:/x/a%20b.wrenlicense"))
	testing.expect(t, !is_license_file_address("file:///C:/x/a.html"))
	testing.expect(t, !is_license_file_address("https://example.org/a.wrenlicense"), "only files of this computer")
	testing.expect(t, !is_license_file_address("file:///C:/x/a.wrenlicense.txt"))
	r: Command_Registry
	commands_build(&r)
	defer commands_destroy(&r)
	i, found := r.index["browser.about"]
	testing.expect(t, found && r.list[i].url == WREN_URL && r.list[i].label == "About Wren", "the command opens about:wren")
	_, found = r.index["browser.about_licenses"]
	testing.expect(t, found)
}

@(test)
support_link_is_a_web_page :: proc(t: ^testing.T) {
	test_app(t)
	app := app_make()
	defer app_free(app)
	assert(app_prefs_init(app) == "")
	testing.expect_value(t, license_support_url(app), SUPPORT_URL)
	testing.expect_value(t, config.set_from_string(&app.prefs, "browser.license.support_url", "https://example.org/help", .User), config.Set_Error.None)
	testing.expect_value(t, license_support_url(app), "https://example.org/help")
	testing.expect_value(t, config.set_from_string(&app.prefs, "browser.license.support_url", "javascript:alert(1)", .User), config.Set_Error.None)
	testing.expect_value(t, license_support_url(app), SUPPORT_URL)
	testing.expect_value(t, config.set_from_string(&app.prefs, "browser.license.support_url", "file:///C:/x", .User), config.Set_Error.None)
	testing.expect_value(t, license_support_url(app), SUPPORT_URL)
}
