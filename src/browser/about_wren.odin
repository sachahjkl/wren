package browser

import "core:encoding/base64"
import "core:fmt"
import "core:strings"
import "core:time"
import "toolkit:ui"
import "wb:base"
import i18n "toolkit:i18n"
import "wb:license"
import licence "toolkit:licence"
import "wb:page"
import "wb:wasm"

////////////////////////////////
// about:wren (About Wren) and about:licenses (the third-party licenses in full).
//
// Two ordinary documents, made like the start page, in the colors of the interface's theme (appearance.theme) so they
// read as part of the browser: the logo of the channel, the version and build, "by Froment Software", the beta notice,
// the licence line (whether Wren is registered; the licence itself is the settings' Licence page, license_shell.odin),
// the third-party list. They are documents rather than a chrome panel because they need text that can be selected and
// copied (the commit), links and the page scroller; the chrome only reaches them through a command (browser.about, in
// the menu and the palette). The updates and the installation are the settings' (about:settings: the System page's
// Updates line, the Installation page): this page links to them and says nothing of their state.

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
	state:       licence.Status,
	checking:    bool,             // the store has not answered yet (its first read is under way)
	support_url: string,
	profile_dir: string,
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
  table { width: 100%; border-collapse: collapse; }
  td, th { text-align: left; padding: 4px 8px 4px 0; vertical-align: top; border-bottom: 1px solid $BORDER$; }
  th { color: $WEAK$; font-weight: normal; }
  td.k { color: $WEAK$; width: 150px; white-space: nowrap; }
  td.v { word-break: break-all; }
  form { margin: 12px 0 0; }
  button { display: inline-block; margin: 8px 8px 0 0; padding: 6px 14px; background-color: $PANEL2$; color: $TEXT$; border: 1px solid $BORDER$; border-radius: 4px; font-size: 14px; }
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
page_head :: proc(sb: ^strings.Builder, title: string, p: ui.Palette) {
	strings.write_string(sb, "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>")
	esc(sb, title)
	strings.write_string(sb, "</title>\n<style>")
	strings.write_string(sb, theme_css(p))
	strings.write_string(sb, "</style>\n</head>\n<body>\n<div class=\"main\">\n")
}

// The licence line: whether Wren is registered, and the way to the settings' Licence page, where its card, its key and
// its file are (license_shell.odin). Nothing more of the licence is said here: the page says it once.
@(private = "file")
licence_section :: proc(sb: ^strings.Builder, d: Wren_Page) {
	strings.write_string(sb, "<h2>License</h2>\n")
	s := d.state
	if s.registered {
		strings.write_string(sb, "<p class=\"status\"><b>Registered to ")
		esc(sb, s.licence.name)
		fmt.sbprintf(sb, "</b> &middot; %s license</p>\n", escape_html(licence.edition_title(license.WREN, s.licence.edition)))
	} else if d.checking {
		strings.write_string(sb, "<p class=\"status weak\">Reading the license\u2026</p>\n")
	} else {
		strings.write_string(sb, "<p class=\"status weak\">Unregistered &mdash; free during the beta &middot; <a href=\"")
		esc(sb, d.support_url)
		strings.write_string(sb, "\">Support Wren</a></p>\n")
	}
	fmt.sbprintf(sb, "<p><a href=\"%s\">Manage the license</a></p>\n", SETTINGS_LICENCE_URL)
}

@(private = "file")
build_section :: proc(sb: ^strings.Builder, d: Wren_Page) {
	strings.write_string(sb, "<h2>Build</h2>\n<table>\n")
	row(sb, "Version", APP_VERSION_SHOWN)
	row(sb, "Channel", channel_name())
	row(sb, "Commit", APP_COMMIT_DATE != "" ? fmt.tprintf("%s (%s)", app_commit(), APP_COMMIT_DATE) : app_commit())
	row(sb, "Build", build_description())
	row(sb, "Built", build_date_text())
	row(sb, "gui_toolkit", ui.VERSION)
	row(sb, "Odin", odin_version_text())
	row(sb, "Wasmtime", wasm.WASMTIME_VERSION)
	row(sb, "JavaScript engine", "Wren's own, in Odin (after QuickJS-ng " + QUICKJS_VERSION + ")")
	if d.profile_dir != "" { row(sb, "Profile", d.profile_dir) }
	strings.write_string(sb, "</table>\n")
}

// The settings' pages that say what changed, the updates and the installation: links, their state is theirs.
@(private = "file")
settings_links :: proc(sb: ^strings.Builder) {
	fmt.sbprintf(sb, "<p><a href=\"%s\">What's new</a>", SETTINGS_WHATS_NEW_URL)
	// (no Updates line where Wren does not update itself: updates_other.odin)
	if UPDATES_SELF { fmt.sbprintf(sb, " &middot; <a href=\"%s\">Updates</a>", SETTINGS_UPDATES_URL) }
	fmt.sbprintf(sb, " &middot; <a href=\"%s\">Installation</a></p>\n", SETTINGS_INSTALL_URL)
}

// The people and projects Wren owes its design or its code to: one link each, to the official site (the official X account
// when there is none). The libraries are named by four of their links; about:licenses has every component.
@(private = "file")
thanks_section :: proc(sb: ^strings.Builder) {
	strings.write_string(sb, "<h2>")
	esc(sb, i18n.tr("Thanks"))
	strings.write_string(sb, "</h2>\n<table>\n")
	thanks_row(sb, "Casey Muratori", "https://caseymuratori.com", i18n.tr("Handmade Hero, Molly Rocket, and the immediate-mode GUI he popularised."))
	thanks_row(sb, "Jonathan Blow", "https://x.com/Jonathan_Blow", i18n.tr("Braid and The Witness."))
	thanks_row(sb, "United States Graphics Company", "https://usgraphics.com", i18n.tr("Engineering graphics, and the Berkeley Mono typeface."))
	thanks_row(sb, "ThePrimeagen", "https://x.com/ThePrimeagen", i18n.tr("Programming videos and streams on YouTube and Twitch."))
	thanks_row(sb, "Ginger Bill (Bill Hall)", "https://gingerbill.org", i18n.tr("Creator of Odin, the language Wren is written in."))
	thanks_row(sb, "Dax Raad (OpenCode)", "https://opencode.ai", i18n.tr("OpenCode, the open source AI coding agent, and its team."))
	thanks_row(sb, "Andreas Kling (Ladybird)", "https://ladybird.org", i18n.tr("An independent browser engine, written from scratch and developed in the open."))
	thanks_row(sb, "Ryan Fleury", "https://rfleury.com", i18n.tr("RAD Debugger, whose immediate-mode interface inspired Wren's."))
	thanks_row(sb, "Fabrice Bellard", "https://bellard.org", i18n.tr("QuickJS, the JavaScript engine that QuickJS-ng is a fork of."))
	thanks_row(sb, "Alexander Borisov", "https://lexbor.com", i18n.tr("Lexbor, the HTML parser."))
	strings.write_string(sb, "<tr><td class=\"k\">")
	esc(sb, i18n.tr("Libraries"))
	strings.write_string(sb, "</td><td>")
	thanks_link(sb, "https://github.com/EricLengyel/Slug", "Slug")
	strings.write_string(sb, " (Eric Lengyel), ")
	thanks_link(sb, "https://github.com/bytecodealliance/wasmtime", "Wasmtime")
	strings.write_string(sb, ", ")
	thanks_link(sb, "https://github.com/quickjs-ng/quickjs", "QuickJS-ng")
	strings.write_string(sb, ", ")
	thanks_link(sb, "https://github.com/linebender/resvg", "resvg")
	strings.write_string(sb, ", ")
	fmt.sbprintf(sb, "<a href=\"%s\">%s</a>.", LICENSES_URL, escape_html(i18n.tr("the other components and their licenses")))
	strings.write_string(sb, "</td></tr>\n</table>\n")
}

@(private = "file")
thanks_row :: proc(sb: ^strings.Builder, name, url, why: string) {
	strings.write_string(sb, "<tr><td class=\"k\">")
	thanks_link(sb, url, name)
	strings.write_string(sb, "</td><td>")
	esc(sb, why)
	strings.write_string(sb, "</td></tr>\n")
}

@(private = "file")
thanks_link :: proc(sb: ^strings.Builder, url, text: string) {
	strings.write_string(sb, "<a href=\"")
	esc(sb, url)
	strings.write_string(sb, "\">")
	esc(sb, text)
	strings.write_string(sb, "</a>")
}

// The components, one row each: name (a link), version, license, and a link to the license text when it is embedded.
@(private = "file")
third_party_table :: proc(sb: ^strings.Builder, with_text_links: bool) {
	strings.write_string(sb, "<table>\n<tr><th>Component</th><th>Version</th><th>License</th>")
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
	page_head(&sb, "About Wren", d.palette)
	// the name, the version, the tagline, and the maker's signature as the last, small line of the header
	fmt.sbprintf(&sb, "<div class=\"id\"><img class=\"mark\" src=\"%s\" width=\"96\" height=\"96\" alt=\"\"><div class=\"text\"><h1>%s</h1><p>Version %s%s</p><p class=\"weak\">%s</p>",
		app_logo_url(), APP_NAME, APP_VERSION_SHOWN, IS_DEV_BUILD ? " (development build)" : "", escape_html(APP_TAGLINE))
	fmt.sbprintf(&sb, "<p class=\"sig\">by<img src=\"%s\" width=\"16\" height=\"16\" alt=\"\"><a href=\"%s\">Froment Software</a></p></div></div>\n",
		png_url(FROMENT_LOGO_PNG), FROMENT_URL)
	strings.write_string(&sb, "<p class=\"beta\"><b>Wren is a beta under development.</b> Every version is free; a license only supports development.</p>\n")
	licence_section(&sb, d)
	build_section(&sb, d)
	settings_links(&sb)
	thanks_section(&sb)
	strings.write_string(&sb, "<h2>Third-party software</h2>\n<p>Wren's own code is under the PolyForm Strict License 1.0.0 (its source is public). It is built from the components below, whose licenses require this notice; the full texts are in <a href=\"about:licenses\">about:licenses</a>.</p>\n<p>Text rendering can use the Slug algorithm and shaders by Eric Lengyel (MIT license), credited as its license requires.</p>\n")
	third_party_table(&sb, false)
	strings.write_string(&sb, "<p class=\"weak\" style=\"margin-top: 10px\">The Rust libraries linked into the image decoders are listed with their licenses in <a href=\"about:licenses#rust-crates\">about:licenses</a>.</p>\n")
	fmt.sbprintf(&sb, "<p class=\"foot\">&copy; 2026 Sacha Froment (<a href=\"%s\">Froment Software</a>) &middot; <a href=\"about:licenses\">Licenses</a> &middot; <a href=\"about:about\">Built-in pages</a></p>\n", FROMENT_URL)
	strings.write_string(&sb, "</div>\n</body>\n</html>\n")
	return strings.to_string(sb)
}

licenses_page_html :: proc(d: Wren_Page) -> string {
	sb := strings.builder_make(context.temp_allocator)
	page_head(&sb, "Licenses", d.palette)
	strings.write_string(&sb, "<h1>Licenses</h1>\n<p class=\"weak\">The software Wren is built from, and the full text of each license. <a href=\"about:wren\">Back to About Wren</a>.</p>\n")
	strings.write_string(&sb, "<h2>Components</h2>\n")
	third_party_table(&sb, true)
	strings.write_string(&sb, "<p class=\"weak\" style=\"margin-top: 10px\">Rust libraries of the image decoders (resvg, image-webp, rav1d…): each one's license is listed in <a href=\"#rust-crates\">the text below</a>. The public suffix list is published under the MPL-2.0 by <a href=\"https://publicsuffix.org\">publicsuffix.org</a>.</p>\n")
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

wren_page_data :: proc(app: ^App) -> Wren_Page {
	return Wren_Page{
		palette = chrome_palette(app), state = app.licence.status, checking = !app.licence.read,
		support_url = license_support_url(app), profile_dir = app.profile_dir,
	}
}

// about:wren / about:licenses in `t`. A query does nothing (the page has no form): the entry is about:wren.
show_wren_page :: proc(app: ^App, t: ^Tab, address: string) {
	shown := address
	if strings.index_byte(address, '?') >= 0 { shown = WREN_URL }
	if hash := strings.index_byte(shown, '#'); hash >= 0 && strings.has_prefix(shown, WREN_URL) { shown = WREN_URL }

	nav_show_page(app, t, shown)
	layout_reset(&t.layout)
	t.scroll_target = base.NIL_HANDLE
	t.scroll = 0
	console_reset(t)
	d := wren_page_data(app)
	html := strings.has_prefix(shown, LICENSES_URL) ? licenses_page_html(d) : wren_page_html(d)
	page.load_html(t.page, transmute([]byte)html)
	if shown != address {
		page.session_replace(&t.session, shown)
		sync_history(app, t)
	}
	delete(t.url); t.url = strings.clone(shown)
	delete(t.title); t.title = strings.clone(strings.has_prefix(shown, LICENSES_URL) ? "Licenses" : "About Wren")
	set_status(t, shown)
}
