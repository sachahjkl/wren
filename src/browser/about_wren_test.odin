package browser

import "core:os"
import "core:strings"
import "core:testing"
import "toolkit:ui"
import "wb:config"
import "wb:license"
import "wb:url"
import "wb:wasm"

////////////////////////////////
// The third-party list

@(test)
third_party_table_is_parsed :: proc(t: ^testing.T) {
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
	list := third_party_list()
	testing.expect(t, len(list) >= 15, "THIRD_PARTY.md's table is parsed")
	seen := make(map[string]Third_Party, context.temp_allocator)
	for tp in list {
		testing.expectf(t, tp.name != "" && tp.license != "", "a row without a name or a license: %v", tp)
		seen[tp.name] = tp
	}
	for name in ([]string{"gui_toolkit", "Slug", "Wasmtime", "QuickJS-ng", "Lexbor", "wasi-libc"}) {
		testing.expectf(t, name in seen, "%s is in THIRD_PARTY.md", name)
	}
	testing.expect_value(t, seen["gui_toolkit"].version, ui.VERSION)
	testing.expect_value(t, seen["Wasmtime"].version, wasm.WASMTIME_VERSION)
	testing.expect(t, strings.has_prefix(seen["Slug"].license, "MIT"), "Slug is MIT: its credit is required")
	testing.expect(t, seen["Slug"].url != "", "Slug links to its repository")
}

@(test)
pinned_versions_match_the_scripts :: proc(t: ^testing.T) {
	data, err := os.read_entire_file("tools/build_js.ps1", context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expectf(t, strings.contains(string(data), "$QjsVersion = '" + QUICKJS_VERSION + "'"), "QUICKJS_VERSION (%s) is the version tools\\build_js.ps1 builds", QUICKJS_VERSION)
	data, err = os.read_entire_file("tools/fetch_wasmtime.ps1", context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expectf(t, strings.contains(string(data), "$Version = '" + wasm.WASMTIME_VERSION + "'"), "WASMTIME_VERSION (%s) is the version tools\\fetch_wasmtime.ps1 fetches", wasm.WASMTIME_VERSION)
}

// A license text added to native\js\licenses is shown by about:licenses (and shipped in licenses\ by tools\package.ps1).
@(test)
every_shipped_license_text_is_shown :: proc(t: ^testing.T) {
	shipped := make(map[string]bool, context.temp_allocator)
	list, _ := os.read_all_directory_by_path("native/js/licenses", context.temp_allocator)
	testing.expect(t, len(list) >= 8, "native/js/licenses is found")
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
test_page :: proc(theme: string, state: License_State = {}, notice: Wren_Notice = {}) -> Wren_Page {
	pal, _ := ui.palette_named(theme)
	return {palette = pal, state = state, notice = notice, support_url = SUPPORT_URL, profile_dir = `C:\Users\x\AppData\Roaming\Wren`}
}

@(test)
about_page_without_a_license :: proc(t: ^testing.T) {
	for theme in ([]string{"graphite", "daylight"}) {
		html := wren_page_html(test_page(theme))
		for want in ([]string{
			"Unregistered", "free during the beta", "Support Wren", SUPPORT_URL,
			"Wren is a beta under development.", "Every version is free; a licence only supports development.",
			"Froment Software", FROMENT_URL, "data:image/png;base64,", "Version " + APP_VERSION, "Enter a licence key", "WREN1",
			"gui_toolkit", "Slug", "Wasmtime", "QuickJS-ng", "Odin", "about:licenses",
		}) {
			testing.expectf(t, strings.contains(html, want), "about:wren (%s) lacks %q", theme, want)
		}
		testing.expect(t, !strings.contains(html, "Registered to"), "an unregistered Wren does not claim a registration")
		testing.expect(t, !strings.contains(html, "UNREGISTERED"), "no shouting")
		testing.expect(t, !strings.contains(html, "Remove the licence"), "nothing to remove")
		pal, _ := ui.palette_named(theme)
		testing.expectf(t, strings.contains(html, pal.dark ? "color-scheme: dark" : "color-scheme: light"), "%s's color scheme", theme)
		testing.expect(t, !strings.contains(html, "$"), "every theme token was replaced")
		testing.expect(t, !strings.contains(html, "<script") && !strings.contains(html, `id="lic"`), "no card, no script without a licence")
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
	d := test_page("graphite")
	d.card_sample = true
	html := wren_page_html(d)
	for want in ([]string{`id="lic"`, "Sample Supporter", "-wren-shader: card-foil", "<script>", "Unregistered"}) {
		testing.expectf(t, strings.contains(html, want), "the preview lacks %q", want)
	}
	testing.expect(t, !strings.contains(html, "Registered to"), "nothing is registered")
	d.card_sample = false
	testing.expect(t, !strings.contains(wren_page_html(d), `id="lic"`), "no card without the preview or a licence")
	testing.expect(t, is_builtin_href("about:wren?card=sample") && !is_builtin_href("about:blank") && !is_builtin_href("https://example.org/about:wren"), "the preview is a built-in page; about:blank is not")
}

@(test)
about_page_with_a_license :: proc(t: ^testing.T) {
	lic := license.License{product = "wren", edition = "patron", name = "Zoé <b>Martin</b> & Co", email = "z@example.org", date = "2026-10-22", order = "WREN-0042"}
	state := License_State{lic = lic, registered = true, stored = true}
	html := wren_page_html(test_page("graphite", state))
	for want in ([]string{"Registered to Zoé &lt;b&gt;Martin&lt;/b&gt; &amp; Co", "Patron licence", "2026-10-22", "WREN-0042", "z@example.org", "Thank you", "Remove the licence", "Replace the licence"}) {
		testing.expectf(t, strings.contains(html, want), "about:wren with a license lacks %q", want)
	}
	testing.expect(t, !strings.contains(html, "Unregistered"), "a registered Wren is not unregistered")
	testing.expect(t, !strings.contains(html, "<b>Martin</b>"), "the name is escaped")
	for want in ([]string{`id="lic"`, "CERTIFIED", `class="seal"`, "<script>", "requestAnimationFrame", "prefers-reduced-motion", "-wren-shader: card-foil", "@property --sweep", `class="tickwrap"`, "text-shadow", "@media (max-width: 520px)"}) {
		testing.expectf(t, strings.contains(html, want), "the licence card lacks %q", want)
	}
	testing.expect(t, strings.contains(html, "Zoé &lt;b&gt;Martin&lt;/b&gt; &amp; Co</div>"), "the card shows the escaped name")
	testing.expect(t, !strings.contains(html, "setInterval") && !strings.contains(html, "requestAnimationFrame(loop"), "the card's script never loops: no frame at rest")
	// every page has the beta notice
	testing.expect(t, strings.contains(html, "Wren is a beta under development."))
}

@(test)
about_page_notices_and_rejected_store :: proc(t: ^testing.T) {
	state := License_State{stored = true, err = .Bad_Signature}
	html := wren_page_html(test_page("daylight", state, {"Nope <i>", true}))
	testing.expect(t, strings.contains(html, "Unregistered"))
	testing.expect(t, strings.contains(html, "The stored licence was not accepted"))
	testing.expect(t, strings.contains(html, `class="notice bad">Nope &lt;i&gt;`))
	html = wren_page_html(test_page("daylight", {}, {"Fine", false}))
	testing.expect(t, strings.contains(html, `class="notice ok">Fine`))
}

@(test)
thanks_section_links_every_entry :: proc(t: ^testing.T) {
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
	testing.expect(t, found && r.list[i].url == WREN_URL && r.list[i].title == "About Wren", "the command opens about:wren")
	_, found = r.index["browser.about_licenses"]
	testing.expect(t, found)
}

////////////////////////////////
// Keeping the license

@(private = "file")
license_app :: proc(path: string, persist: bool) -> ^App {
	app := new(App)
	app.prefs = config.prefs_make()
	register_all_prefs(&app.prefs)
	seed := license.DEV_SEED
	pub, _ := license.public_key_of(seed[:], context.temp_allocator)
	assert(config.set_from_string(&app.prefs, "browser.license.public_key", pub, .User) == .None)
	if path != "" { assert(config.set_from_string(&app.prefs, "browser.license.path", path, .User) == .None) }
	app.cfg.persist_profile = persist
	app.profile_dir = ""
	return app
}

@(private = "file")
license_app_free :: proc(app: ^App) {
	config.prefs_destroy(&app.prefs)
	free(app)
}

@(private = "file")
dev_license :: proc(name: string, seed: [32]byte = license.DEV_SEED) -> string {
	seed := seed
	text, ok := license.sign(seed[:], {edition = "supporter", name = name, email = "a@b.c", date = "2026-10-22", order = "T-1"}, context.temp_allocator)
	assert(ok)
	return text
}

@(test)
the_licence_a_build_is_handed_out_with_is_put_in_once :: proc(t: ^testing.T) {
	_ = os.make_directory_all("build/tmp")
	path := "build/tmp/about_seed_test.wrenlicense"
	marker := "build/tmp/about_seed_test.wrenlicense.seeded"
	_ = os.remove(path); _ = os.remove(marker)
	defer { _ = os.remove(path); _ = os.remove(marker) }
	app := license_app(path, true)
	defer license_app_free(app)
	given := dev_license("Pre-registered")

	// the profile holds none: it is given the build's, and the marker says so
	license_seed(app, given)
	st := license_state(app)
	testing.expect(t, st.registered && st.lic.name == "Pre-registered", "a pre-registered build shows its licence")
	testing.expect(t, os.exists(marker), "the licence was put in once")

	// the user removes it: it stays removed (the next start is a new call of license_seed)
	license_remove(app)
	license_seed(app, given)
	testing.expect(t, !license_state(app).stored, "a removed licence is not put back")

	// the user registers another one: it is the profile's, and the build's does not replace it
	mine := dev_license("Mine")
	testing.expect_value(t, license_install(app, mine), license.Error.None)
	license_seed(app, given)
	testing.expect(t, license_state(app).lic.name == "Mine", "the licence of the user is kept")

	// a profile that holds a licence of its own (shared with another Wren) is not touched, and gets no marker
	_ = os.remove(marker)
	license_seed(app, given)
	testing.expect(t, license_state(app).lic.name == "Mine" && !os.exists(marker), "a licence already there is kept as it is")

	// a text this build does not accept is put nowhere
	_ = os.remove(path)
	license_seed(app, dev_license("Elsewhere", license.OTHER_DEV_SEED))
	testing.expect(t, !os.exists(path) && !os.exists(marker), "a licence this build cannot check is not put in")
	license_seed(app, "")
	testing.expect(t, !os.exists(path), "no licence in the build, nothing put in")
}
@(test)
license_is_kept_checked_and_removed :: proc(t: ^testing.T) {
	_ = os.make_directory_all("build/tmp")
	path := "build/tmp/about_license_test.wrenlicense"
	_ = os.remove(path)
	defer os.remove(path)
	app := license_app(path, true)
	defer license_app_free(app)

	st := license_state(app)
	testing.expect(t, !st.registered && !st.stored, "nothing is stored at first")

	// a key of another pair is refused and writes nothing
	other := dev_license("Other", license.OTHER_DEV_SEED)
	testing.expect_value(t, license_install(app, other), license.Error.Bad_Signature)
	testing.expect_value(t, license_install(app, "garbage"), license.Error.Bad_Format)
	testing.expect(t, !os.exists(path), "a refused key is not kept")

	// a good one, pasted wrapped, is kept in its canonical form
	good := dev_license("Jeanne")
	wrapped := strings.concatenate({good[:40], "\r\n  ", good[40:]}, context.temp_allocator)
	testing.expect_value(t, license_install(app, wrapped), license.Error.None)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, strings.trim_space(string(data)), good)
	st = license_state(app)
	testing.expect(t, st.registered && st.stored && st.lic.name == "Jeanne" && st.lic.order == "T-1", "the stored key is read back and checked")

	// the file is the profile's: another pair's key in it is "stored, not accepted"
	_ = os.write_entire_file(path, transmute([]byte)other)
	st = license_state(app)
	testing.expect(t, !st.registered && st.stored && st.err == .Bad_Signature, "a stored key that does not check out is not a registration")
	_ = os.write_entire_file(path, transmute([]byte)string("not a licence at all"))
	st = license_state(app)
	testing.expect(t, !st.registered && st.stored && st.err == .Bad_Format)

	testing.expect_value(t, license_install(app, good), license.Error.None)
	license_remove(app)
	testing.expect(t, !os.exists(path), "removing deletes the file")
	st = license_state(app)
	testing.expect(t, !st.registered && !st.stored)

	// a file too large to be a license is not read
	big, _ := strings.repeat("A", license.MAX_TEXT + 10, context.temp_allocator)
	_ = os.write_entire_file(path, transmute([]byte)big)
	testing.expect(t, !license_state(app).stored, "an oversized file is ignored")
}

@(test)
license_without_a_profile_stays_in_memory :: proc(t: ^testing.T) {
	app := license_app("", false)
	defer license_app_free(app)
	testing.expect_value(t, license_path(app), "")
	testing.expect(t, !license_state(app).registered)
	testing.expect_value(t, license_install(app, dev_license("Memoire")), license.Error.None)
	testing.expect(t, license_state(app).registered && license_state(app).lic.name == "Memoire")
	license_remove(app)
	testing.expect(t, !license_state(app).stored)
}

@(test)
license_file_open_and_form :: proc(t: ^testing.T) {
	_ = os.make_directory_all("build/tmp")
	store := "build/tmp/about_license_store.wrenlicense"
	src := "build/tmp/about_license_src.wrenlicense"
	_ = os.remove(store)
	defer os.remove(store)
	defer os.remove(src)
	app := license_app(store, true)
	defer license_app_free(app)

	// a file dropped on the window: a header of comments, the key wrapped
	good := dev_license("Dropped")
	text := strings.concatenate({"# Wren licence\n# order T-1\n", good[:60], "\n", good[60:], "\n"}, context.temp_allocator)
	_ = os.write_entire_file(src, transmute([]byte)text)
	n := license_install_file(app, src)
	testing.expect(t, !n.bad, n.text)
	testing.expect(t, license_state(app).registered && license_state(app).lic.name == "Dropped")

	_ = os.write_entire_file(src, transmute([]byte)string("nothing"))
	n = license_install_file(app, src)
	testing.expect(t, n.bad && n.text != "", "a file that is not a licence says so")
	testing.expect(t, license_state(app).lic.name == "Dropped", "and the licence in use stays")
	n = license_install_file(app, "build/tmp/does_not_exist.wrenlicense")
	testing.expect(t, n.bad)

	// the form: the query of about:wren?action=...
	form :: proc(app: ^App, q: string) -> Wren_Notice {
		sp := url.params_make(context.temp_allocator)
		url.params_parse(&sp, q)
		return wren_query(app, sp)
	}
	n = form(app, "action=register&key=")
	testing.expect(t, n.bad, "an empty key is asked for")
	n = form(app, "action=register&key=WREN1.aaaa.bbbb")
	testing.expect(t, n.bad)
	testing.expect(t, license_state(app).lic.name == "Dropped")
	n = form(app, strings.concatenate({"action=register&key=", dev_license("Pasted")}, context.temp_allocator))   // (base64url and dots need no escaping)
	testing.expect(t, !n.bad && n.text != "", "a good key is accepted")
	testing.expect(t, license_state(app).lic.name == "Pasted")
	n = form(app, "action=remove")
	testing.expect(t, !n.bad)
	testing.expect(t, !license_state(app).stored)
	n = form(app, "choose=1")
	testing.expect(t, n.text == "" && !n.bad, "choose=1 alone says nothing")
}

@(test)
support_link_is_a_web_page :: proc(t: ^testing.T) {
	app := license_app("", false)
	defer license_app_free(app)
	testing.expect_value(t, license_support_url(app), SUPPORT_URL)
	testing.expect_value(t, config.set_from_string(&app.prefs, "browser.license.support_url", "https://example.org/help", .User), config.Set_Error.None)
	testing.expect_value(t, license_support_url(app), "https://example.org/help")
	testing.expect_value(t, config.set_from_string(&app.prefs, "browser.license.support_url", "javascript:alert(1)", .User), config.Set_Error.None)
	testing.expect_value(t, license_support_url(app), SUPPORT_URL)
	testing.expect_value(t, config.set_from_string(&app.prefs, "browser.license.support_url", "file:///C:/x", .User), config.Set_Error.None)
	testing.expect_value(t, license_support_url(app), SUPPORT_URL)
	// the production key is empty until it is made: a release reads no licence; a development build still accepts the
	// development pair's (tools\license.ps1 issue -dev), never another pair's
	testing.expect_value(t, config.set_from_string(&app.prefs, "browser.license.public_key", "", .User), config.Set_Error.None)
	testing.expect_value(t, license_public_key(app), license.PRODUCTION_PUBLIC_KEY)
	if license.PRODUCTION_PUBLIC_KEY == "" {
		when IS_DEV_BUILD {
			testing.expect_value(t, license_install(app, dev_license("x")), license.Error.None)
			testing.expect_value(t, license_install(app, dev_license("y", license.OTHER_DEV_SEED)), license.Error.No_Public_Key)
		} else {
			testing.expect_value(t, license_install(app, dev_license("x")), license.Error.No_Public_Key)
		}
	}
}
