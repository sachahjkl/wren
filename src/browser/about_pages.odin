package browser

import "core:fmt"
import "core:strings"
import "toolkit:ui"
import "wb:base"
import "wb:page"

////////////////////////////////
// about:about (and about: alone): the browser's own pages, as other browsers list theirs.

ABOUT_URL :: "about:about"

About_Page :: struct {
	url:   string,
	title: string,
	about: string,   // HTML
}

ABOUT_PAGES := [?]About_Page{
	{HOME_URL, "Start page", "What a new tab shows (<code>browser.homepage</code>): links to the settings and the demos."},
	{DEMOS_URL, "Demos and tests", "Every demo and test page that comes with Wren, by theme, with what each one shows."},
	{HISTORY_URL, "History", "Every page visited (Ctrl+H), by day, searchable, and the history tree of each tab: going back then elsewhere keeps the old way as a branch."},
	{"about:config", "Configuration", "Every setting of the browser, searchable and editable; nothing is hard-wired."},
	{CACHE_URL, "HTTP cache", "What the browser keeps of the responses it fetched (RFC 9111): statistics, the entries by site and URL, a filter, and a button that clears it."},
	{WREN_URL, "About Wren", "Version and build, who made it, the beta notice, the licence and the form to enter a key, the third-party software."},
	{LICENSES_URL, "Licences", "The licences of the software Wren is built from, in full."},
	{ABOUT_URL, "Built-in pages", "This list, under the version of the browser. <code>about:</code> alone opens it too."},
	{"about:blank", "Blank page", "An empty document."},
}

@(private = "file")
ABOUT_PAGES_STYLE :: `
  html { background-color: #0d1017; }
  body { margin: 0; color: #c9d1e3; font-family: system-ui; font-size: 15px; }
  .main { max-width: 680px; box-sizing: border-box; margin: 0 auto; padding: 48px 20px; }
  h1 { font-size: 32px; margin: 0 0 6px; color: #f1f4fb; }
  .intro { color: #8993ad; margin: 0 0 22px; }
  .page { margin: 10px 0; padding: 12px 18px; background-color: #131825; border: 1px solid #232b40; border-radius: 12px; }
  .page h3 { margin: 0 0 4px; font-size: 16px; }
  .page h3 a { color: #ffb84d; text-decoration: none; }
  .page h3 a:hover { text-decoration: underline; }
  .page h3 a:active { color: #ffd699; }
  .page h3 .t { color: #8993ad; font-weight: normal; margin-left: 10px; font-size: 14px; }
  .page p { margin: 0; color: #8993ad; }
  code { color: #c9d1e3; background-color: #1b2132; padding: 0 3px; border-radius: 3px; }
  .build { display: flex; align-items: center; margin: 0 0 28px; }
  .build img { width: 64px; height: 64px; margin-right: 16px; }
  .build .name { margin: 0; font-size: 20px; font-weight: bold; color: #f1f4fb; }
  .build .what { margin: 2px 0 0; color: #8993ad; }
  .dev { display: inline-block; margin: 8px 0 0; padding: 3px 12px 3px 4px; border: 1px solid #2f5ea8; border-radius: 14px; background-color: #10213f; color: #9cc0f2; font-size: 13px; }
  .dev b { display: inline-block; margin-right: 8px; padding: 0 8px; border-radius: 10px; background-color: #2363b8; color: #ffffff; font-size: 11px; letter-spacing: 1px; }
`

about_pages_html :: proc() -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>Built-in pages</title>\n<style>")
	strings.write_string(&sb, ABOUT_PAGES_STYLE)
	strings.write_string(&sb, "</style>\n</head>\n<body>\n<div class=\"main\">\n")
	// which build this is: the logo of its channel, the version, the commit (a development build says so)
	fmt.sbprintf(&sb, "<div class=\"build\"><img src=\"%s\" width=\"64\" height=\"64\" alt=\"\"><div><p class=\"name\">%s %s</p><p class=\"what\">Commit %s%s &middot; build: %s</p>%s</div></div>\n",
		app_logo_url(), APP_NAME, APP_VERSION, app_commit(), APP_COMMIT_DATE != "" ? fmt.tprintf(", %s", APP_COMMIT_DATE) : "",
		build_description(), dev_badge_html(with_commit = false))
	strings.write_string(&sb, "<h1>Built-in pages</h1>\n<p class=\"intro\">The pages of the browser itself. <code>view-source:</code> before an address shows a page's source; a path of this computer (<code>C:\\...</code>, <code>\\\\server\\share</code>) opens the file, or the folder's <code>index.html</code>, or its listing.</p>\n")
	for p in ABOUT_PAGES {
		strings.write_string(&sb, "<div class=\"page\"><h3><a href=\"")
		strings.write_string(&sb, p.url)
		strings.write_string(&sb, "\">")
		strings.write_string(&sb, p.url)
		strings.write_string(&sb, "</a><span class=\"t\">")
		strings.write_string(&sb, p.title)
		strings.write_string(&sb, "</span></h3><p>")
		strings.write_string(&sb, p.about)   // (our own HTML)
		strings.write_string(&sb, "</p></div>\n")
	}
	strings.write_string(&sb, "</div>\n</body>\n</html>\n")
	return strings.to_string(sb)
}

// An ordinary document, like the start page: its links open as if typed in the address bar.
show_about_pages :: proc(app: ^App, t: ^Tab) {
	base.scope_close(t.nav)
	t.nav = base.scope_make("navigation", t.scope)
	t.load, t.kind = nil, .Web
	t.page = page.page_create(&app.loop, &app.loader, &app.page_settings, t.nav, ABOUT_URL, console_sink, t)
	attach_page(app, t, t.page)
	layout_reset(&t.layout)
	t.scroll_target = base.NIL_HANDLE
	t.scroll = 0
	console_reset(t)
	page.load_html(t.page, transmute([]byte)about_pages_html())
	delete(t.url); t.url = strings.clone(ABOUT_URL)
	delete(t.title); t.title = strings.clone("Built-in pages")
	set_status(t, ABOUT_URL)
	ui.field_set(&app.address, ABOUT_URL)
}
