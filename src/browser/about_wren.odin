package browser

import "core:encoding/base64"
import "core:fmt"
import "core:strings"
import "core:time"
import "toolkit:ui"
import "wb:base"
import "wb:license"
import "wb:page"
import "wb:url"
import "wb:wasm"

////////////////////////////////
// about:wren (About Wren) and about:licenses (the third-party licenses in full).
//
// Two ordinary documents, made like the start page, in the colors of the interface's theme (browser.ui.theme) so they
// read as part of the browser: the logo of the channel, the version and build, "by Froment Software", the beta notice,
// the licence line and the form to enter a key, the third-party list. They are documents rather than a chrome panel
// because they need text that can be selected and copied (the commit, the key), links, a form with a text area and
// the page scroller; the chrome only reaches them through a command (browser.about, in the menu and the palette).
//
// The form submits to about:wren itself (GET: the forms package posts to http(s) only): navigate hands the query to
// show_wren_page, which acts on it only when it comes from this page (or the browser's own UI), never from a web page.

WREN_URL     :: "about:wren"
LICENSES_URL :: "about:licenses"
FROMENT_URL  :: "https://froment.software"

FROMENT_LOGO_PNG :: #load("../../assets/brand/froment-software-128.png")

is_wren_address :: proc(a: string) -> bool {
	return a == WREN_URL || a == LICENSES_URL || strings.has_prefix(a, WREN_URL + "?") || strings.has_prefix(a, WREN_URL + "#") ||
		strings.has_prefix(a, LICENSES_URL + "#")
}

// Everything the page shows that comes from the running program (so tests can build it without an App).
Wren_Page :: struct {
	palette:     ui.Palette,
	state:       License_State,
	notice:      Wren_Notice,
	support_url: string,
	profile_dir: string,
}

Wren_Notice :: struct {
	text: string,
	bad:  bool,
}

@(private = "file")
hex_of :: proc(c: u32) -> string { return fmt.tprintf("#%06x", c >> 8) }

@(private = "file")
build_date_text :: proc() -> string {
	t := time.unix(i64(ODIN_COMPILE_TIMESTAMP / 1_000_000_000), 0)
	y, mo, d := time.date(t)
	h, mi, _ := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d UTC", y, int(mo), d, h, mi)
}

@(private = "file")
odin_version_text :: proc() -> string { return strings.trim_space(ODIN_VERSION_FILE) }

// The channel in words: "release", or "development" (blueprint logo).
channel_name :: proc() -> string { return IS_DEV_BUILD ? "development" : "release" }

@(private = "file")
png_url :: proc(png: []byte) -> string {
	return strings.concatenate({"data:image/png;base64,", base64.encode(png, allocator = context.temp_allocator)}, context.temp_allocator)
}

@(private = "file")
WREN_STYLE :: `
  html { background-color: $BG$; color-scheme: $SCHEME$; }
  body { margin: 0; color: $TEXT$; font-family: system-ui; font-size: 15px; line-height: 1.5; }
  .main { max-width: 720px; box-sizing: border-box; margin: 0 auto; padding: 40px 24px 56px; }
  a { color: $ACCENT$; text-decoration: none; }
  a:hover { text-decoration: underline; }
  h1 { font-size: 32px; line-height: 1.2; margin: 0; }
  h2 { font-size: 17px; margin: 34px 0 10px; padding-bottom: 6px; border-bottom: 1px solid $BORDER$; }
  p { margin: 0 0 10px; }
  .weak { color: $WEAK$; }
  .id { display: flex; align-items: center; }
  .id img.mark { width: 96px; height: 96px; flex: none; object-fit: contain; margin-right: 22px; }
  .id .text { min-width: 0; }
  @media (max-width: 520px) {
    .id { flex-direction: column; align-items: flex-start; }
    .id img.mark { margin: 0 0 16px 0; }
  }
  .id p { margin: 2px 0 0; }
  .id p.sig { margin-top: 8px; font-size: 13px; color: $WEAK$; white-space: nowrap; }
  .sig img { width: 16px; height: 16px; vertical-align: -3px; margin: 0 5px; }
  .sig a { color: $TEXT$; font-weight: 600; }
  .beta { margin: 24px 0 0; padding: 10px 14px; background-color: $PANEL$; border: 1px solid $BORDER$; border-radius: 4px; }
  .status { margin: 0 0 4px; }
  .notice { margin: 12px 0 0; padding: 8px 12px; background-color: $PANEL$; border: 1px solid $BORDER$; border-radius: 4px; }
  .notice.bad { color: $BAD$; border-color: $BAD$; }
  .notice.ok { border-color: $GOOD$; }
  table { width: 100%; border-collapse: collapse; }
  td, th { text-align: left; padding: 4px 8px 4px 0; vertical-align: top; border-bottom: 1px solid $BORDER$; }
  th { color: $WEAK$; font-weight: normal; }
  td.k { color: $WEAK$; width: 150px; white-space: nowrap; }
  td.v { word-break: break-all; }
  form { margin: 12px 0 0; }
  textarea { display: block; width: 100%; box-sizing: border-box; height: 74px; padding: 8px; background-color: $BG$; color: $TEXT$; border: 1px solid $BORDER$; border-radius: 4px; font-family: monospace; font-size: 13px; }
  button, .btn { display: inline-block; margin: 8px 8px 0 0; padding: 6px 14px; background-color: $PANEL2$; color: $TEXT$; border: 1px solid $BORDER$; border-radius: 4px; font-size: 14px; }
  button.primary { background-color: $ACCENT$; color: $ACCENT_TEXT$; border-color: $ACCENT$; }
  .btn:hover { text-decoration: none; }
  pre { margin: 8px 0 0; padding: 10px 12px; background-color: $PANEL$; border: 1px solid $BORDER$; border-radius: 4px; font-size: 12px; line-height: 1.4; white-space: pre-wrap; word-break: break-word; }
  .text h3 { font-size: 15px; margin: 24px 0 2px; }
  .foot { margin-top: 36px; color: $WEAK$; font-size: 13px; }
`

@(private = "file")
theme_css :: proc(p: ui.Palette) -> string {
	s := WREN_STYLE
	r :: proc(s: string, token: string, with: string) -> string {
		out, _ := strings.replace_all(s, token, with, context.temp_allocator)
		return out
	}
	out := r(s, "$ACCENT_TEXT$", hex_of(p.accent_text))   // (before $ACCENT$: the longer token first)
	out = r(out, "$ACCENT$", hex_of(p.accent))
	out = r(out, "$BG$", hex_of(p.bg | 0xff))
	out = r(out, "$PANEL2$", hex_of(p.panel2))
	out = r(out, "$PANEL$", hex_of(p.panel))
	out = r(out, "$TEXT$", hex_of(p.text))
	out = r(out, "$WEAK$", hex_of(p.weak))
	out = r(out, "$BORDER$", hex_of(p.border))
	out = r(out, "$BAD$", hex_of(p.bad))
	out = r(out, "$GOOD$", hex_of(p.good))
	out = r(out, "$SCHEME$", p.dark ? "dark" : "light")
	return out
}

@(private = "file")
esc :: proc(sb: ^strings.Builder, s: string) { strings.write_string(sb, escape_html(s)) }

@(private = "file")
row :: proc(sb: ^strings.Builder, key, value: string) {
	strings.write_string(sb, "<tr><td class=\"k\">")
	esc(sb, key)
	strings.write_string(sb, "</td><td class=\"v\">")
	esc(sb, value)
	strings.write_string(sb, "</td></tr>\n")
}

@(private = "file")
page_head :: proc(sb: ^strings.Builder, title: string, p: ui.Palette, extra_css := "") {
	strings.write_string(sb, "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>")
	esc(sb, title)
	strings.write_string(sb, "</title>\n<style>")
	strings.write_string(sb, theme_css(p))
	strings.write_string(sb, extra_css)
	strings.write_string(sb, "</style>\n</head>\n<body>\n<div class=\"main\">\n")
}

// The licence line, and under it the entry form.
@(private = "file")
licence_section :: proc(sb: ^strings.Builder, d: Wren_Page) {
	strings.write_string(sb, "<h2>Licence</h2>\n")
	s := d.state
	if s.registered {
		strings.write_string(sb, "<p class=\"status\"><b>Registered to ")
		esc(sb, s.lic.name)
		fmt.sbprintf(sb, "</b> &middot; %s licence</p>\n", escape_html(license.edition_title(s.lic.edition)))
		license_card_html(sb, s.lic)
		strings.write_string(sb, "<p>Thank you for supporting the development of Wren.</p>\n")
	} else {
		strings.write_string(sb, "<p class=\"status weak\">Unregistered &mdash; free during the beta &middot; <a href=\"")
		esc(sb, d.support_url)
		strings.write_string(sb, "\">Support Wren</a></p>\n")
		if s.err != .None && s.stored {
			// a licence is stored but does not check out (another key, a damaged file): said once, quietly
			strings.write_string(sb, "<p class=\"weak\">The stored licence was not accepted: ")
			esc(sb, license.error_text(s.err))
			strings.write_string(sb, "</p>\n")
		}
	}
	if d.notice.text != "" {
		fmt.sbprintf(sb, "<p class=\"notice %s\">", d.notice.bad ? "bad" : "ok")
		esc(sb, d.notice.text)
		strings.write_string(sb, "</p>\n")
	}
	strings.write_string(sb, "<form method=\"get\" action=\"about:wren\"><input type=\"hidden\" name=\"action\" value=\"register\">\n")
	strings.write_string(sb, "<p class=\"weak\" style=\"margin-bottom: 6px\">")
	strings.write_string(sb, s.registered ? "Replace the licence: paste another key, or drop a <code>.wrenlicense</code> file on this window." : "Enter a licence key: paste it here, or drop a <code>.wrenlicense</code> file on this window.")
	strings.write_string(sb, "</p>\n<textarea name=\"key\" spellcheck=\"false\" placeholder=\"WREN1.…\"></textarea>\n")
	strings.write_string(sb, "<button type=\"submit\" class=\"primary\">Register</button><a class=\"btn\" href=\"about:wren?choose=1\">Choose a file…</a>\n</form>\n")
	if s.registered {
		strings.write_string(sb, "<form method=\"get\" action=\"about:wren\"><input type=\"hidden\" name=\"action\" value=\"remove\"><button type=\"submit\">Remove the licence from this computer</button></form>\n")
	}
	strings.write_string(sb, "<p class=\"weak\" style=\"margin-top: 12px\">A licence is checked on this computer with a signature; Wren never contacts a server for it, and nothing in Wren depends on it.</p>\n")
}

@(private = "file")
build_section :: proc(sb: ^strings.Builder, d: Wren_Page) {
	strings.write_string(sb, "<h2>Build</h2>\n<table>\n")
	row(sb, "Version", APP_VERSION)
	row(sb, "Channel", channel_name())
	row(sb, "Commit", APP_COMMIT_DATE != "" ? fmt.tprintf("%s (%s)", app_commit(), APP_COMMIT_DATE) : app_commit())
	row(sb, "Build", build_description())
	row(sb, "Built", build_date_text())
	row(sb, "gui_toolkit", ui.VERSION)
	row(sb, "Odin", odin_version_text())
	row(sb, "Wasmtime", wasm.WASMTIME_VERSION)
	row(sb, "QuickJS-ng", QUICKJS_VERSION)
	if d.profile_dir != "" { row(sb, "Profile", d.profile_dir) }
	strings.write_string(sb, "</table>\n")
}

// The components, one row each: name (a link), version, license, and a link to the license text when it is embedded.
@(private = "file")
third_party_table :: proc(sb: ^strings.Builder, with_text_links: bool) {
	strings.write_string(sb, "<table>\n<tr><th>Component</th><th>Version</th><th>Licence</th>")
	if with_text_links { strings.write_string(sb, "<th>Text</th>") }
	strings.write_string(sb, "</tr>\n")
	for tp in third_party_list() {
		strings.write_string(sb, "<tr><td>")
		if tp.url != "" {
			strings.write_string(sb, "<a href=\"")
			esc(sb, tp.url)
			strings.write_string(sb, "\">")
			esc(sb, tp.name)
			strings.write_string(sb, "</a>")
		} else {
			esc(sb, tp.name)
		}
		strings.write_string(sb, "</td><td>")
		esc(sb, tp.version)
		strings.write_string(sb, "</td><td>")
		esc(sb, tp.license)
		strings.write_string(sb, "</td>")
		if with_text_links {
			strings.write_string(sb, "<td>")
			for lt in LICENSE_TEXTS {
				if !strings.contains(lt.of, tp.name) && !strings.contains(tp.name, lt.of) { continue }
				fmt.sbprintf(sb, "<a href=\"%s#%s\">%s</a> ", LICENSES_URL, lt.id, escape_html(lt.title))
				break
			}
			strings.write_string(sb, "</td>")
		}
		strings.write_string(sb, "</tr>\n")
	}
	strings.write_string(sb, "</table>\n")
}

wren_page_html :: proc(d: Wren_Page) -> string {
	sb := strings.builder_make(context.temp_allocator)
	page_head(&sb, "About Wren", d.palette, d.state.registered ? card_css() : "")
	// the name, the version, the tagline, and the maker's signature as the last, small line of the header
	fmt.sbprintf(&sb, "<div class=\"id\"><img class=\"mark\" src=\"%s\" width=\"96\" height=\"96\" alt=\"\"><div class=\"text\"><h1>%s</h1><p>Version %s%s</p><p class=\"weak\">%s</p>",
		app_logo_url(), APP_NAME, APP_VERSION, IS_DEV_BUILD ? " (development build)" : "", escape_html(APP_TAGLINE))
	fmt.sbprintf(&sb, "<p class=\"sig\">by<img src=\"%s\" width=\"16\" height=\"16\" alt=\"\"><a href=\"%s\">Froment Software</a></p></div></div>\n",
		png_url(FROMENT_LOGO_PNG), FROMENT_URL)
	strings.write_string(&sb, "<p class=\"beta\"><b>Wren is a beta under development.</b> Every version is free; a licence only supports development.</p>\n")
	licence_section(&sb, d)
	build_section(&sb, d)
	strings.write_string(&sb, "<h2>Third-party software</h2>\n<p>Wren's own code is open source under the MIT licence. It is built from the components below, whose licences require this notice; the full texts are in <a href=\"about:licenses\">about:licenses</a>.</p>\n<p>Text rendering can use the Slug algorithm and shaders by Eric Lengyel (MIT licence), credited as its licence requires.</p>\n")
	third_party_table(&sb, false)
	strings.write_string(&sb, "<p class=\"weak\" style=\"margin-top: 10px\">The other Rust libraries linked into the image decoders are listed with their licences in <code>licenses\\rust-crates.txt</code> next to <code>wren.exe</code> in the release package.</p>\n")
	fmt.sbprintf(&sb, "<p class=\"foot\">&copy; 2026 sachahjkl &middot; <a href=\"%s\">Froment Software</a> &middot; <a href=\"about:licenses\">Licences</a> &middot; <a href=\"about:about\">Built-in pages</a></p>\n", FROMENT_URL)
	strings.write_string(&sb, "</div>\n</body>\n</html>\n")
	return strings.to_string(sb)
}

licenses_page_html :: proc(d: Wren_Page) -> string {
	sb := strings.builder_make(context.temp_allocator)
	page_head(&sb, "Licences", d.palette)
	strings.write_string(&sb, "<h1>Licences</h1>\n<p class=\"weak\">The software Wren is built from, and the full text of each licence. <a href=\"about:wren\">Back to About Wren</a>.</p>\n")
	strings.write_string(&sb, "<h2>Components</h2>\n")
	third_party_table(&sb, true)
	strings.write_string(&sb, "<p class=\"weak\" style=\"margin-top: 10px\">Rust libraries of the image decoders (resvg, image-webp, rav1d…): each one's licence is listed in <code>licenses\\rust-crates.txt</code> in the release package. The public suffix list is published under the MPL-2.0 by <a href=\"https://publicsuffix.org\">publicsuffix.org</a>.</p>\n")
	strings.write_string(&sb, "<h2>Texts</h2>\n<div class=\"text\">\n")
	for lt in LICENSE_TEXTS {
		fmt.sbprintf(&sb, "<h3 id=\"%s\">%s</h3>\n", lt.id, escape_html(lt.title))
		if lt.note != "" { fmt.sbprintf(&sb, "<p class=\"weak\" style=\"margin: 0\">%s</p>\n", escape_html(lt.note)) }
		strings.write_string(&sb, "<pre>")
		esc(&sb, strings.trim_space(lt.text))
		strings.write_string(&sb, "</pre>\n")
	}
	strings.write_string(&sb, "</div>\n</div>\n</body>\n</html>\n")
	return strings.to_string(sb)
}

////////////////////////////////
// Showing it

wren_page_data :: proc(app: ^App, notice: Wren_Notice) -> Wren_Page {
	pal, ok := ui.palette_named(app.cfg.ui_theme)
	if !ok { pal = ui.PALETTE_GRAPHITE }
	return Wren_Page{
		palette = pal, state = license_state(app), notice = notice,
		support_url = license_support_url(app), profile_dir = app.profile_dir,
	}
}

// about:wren / about:licenses in `t`. `from`: the page that navigated here (the form of about:wren, whose action is
// about:wren?action=register&key=...: a form that does not post to http(s) always submits with GET). The query is acted
// on only when it comes from this page or from the browser's own UI, never from a web page.
show_wren_page :: proc(app: ^App, t: ^Tab, address: string, from: ^page.Page = nil, notice := Wren_Notice{}) {
	notice := notice
	query := ""
	if i := strings.index_byte(address, '?'); i >= 0 { query = address[i + 1:] }
	trusted := from == nil || builtin_document(from)
	shown := address
	choose := false
	if trusted && query != "" {
		params := url.params_make(context.temp_allocator)
		url.params_parse(&params, query)
		notice = wren_query(app, params)
		if v, ok := url.params_get(params, "choose"); ok && v == "1" { choose = true }
	}
	// the entry is about:wren again: the key is not left in the history, and going back here does not ask twice
	if query != "" { shown = WREN_URL }
	if hash := strings.index_byte(shown, '#'); hash >= 0 && strings.has_prefix(shown, WREN_URL) { shown = WREN_URL }

	base.scope_close(t.nav)
	t.nav = base.scope_make("navigation", t.scope)
	t.load, t.kind = nil, .Web
	t.page = page.page_create(&app.loop, &app.loader, &app.page_settings, t.nav, shown, console_sink, t)
	attach_page(app, t, t.page)
	layout_reset(&t.layout)
	t.scroll_target = base.NIL_HANDLE
	t.scroll = 0
	for l in t.console { delete(l) }
	clear(&t.console)
	d := wren_page_data(app, notice)
	html := strings.has_prefix(shown, LICENSES_URL) ? licenses_page_html(d) : wren_page_html(d)
	page.load_html(t.page, transmute([]byte)html)
	// the licence card's pointer script (about_card.odin); the other built-in pages have none, so they start no realm
	if d.state.registered && !strings.has_prefix(shown, LICENSES_URL) { page.scripts_start(t.page) }
	if shown != address {
		page.session_replace(&t.session, shown)
		sync_history(t)
	}
	delete(t.url); t.url = strings.clone(shown)
	delete(t.title); t.title = strings.clone(strings.has_prefix(shown, LICENSES_URL) ? "Licences" : "About Wren")
	set_status(t, shown)
	ui.field_set(&app.address, shown)
	if choose { license_choose_file(app, t) }
}

// The form of the page: register a key, or remove the stored licence.
wren_query :: proc(app: ^App, sp: url.Search_Params) -> Wren_Notice {
	action, _ := url.params_get(sp, "action")
	switch action {
	case "register":
		key, _ := url.params_get(sp, "key")
		if strings.trim_space(key) == "" { return {"Paste a licence key first.", true} }
		if err := license_install(app, key); err != .None { return {license.error_text(err), true} }
		return {"Licence accepted. Thank you for supporting Wren!", false}
	case "remove":
		license_remove(app)
		return {"The licence was removed from this computer.", false}
	}
	return {}
}
