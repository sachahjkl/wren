package browser

// The artistic new tab page itself: the painting fills the window, the start page's shortcuts and the address bar stay
// legible over it (a light gradient), a discreet caption sits at the bottom (title, artist, date, museum, a link to the
// record), and two small buttons offer another painting and opening the record. It honours the light / dark theme and
// prefers-reduced-motion (no cross-fade then). It is an ordinary document, rendered by the same engine as every other
// page, like about:home; its links open as if typed in the address bar.
//
// The image is embedded as a data: URL from the cached file, so the page needs no network of its own and no special
// scheme. When no painting is ready yet it falls back to an elegant gradient with the caption (or, with the fallback
// preference off, to the plain start page). The background task is started by art_seen_new_tab the first time an art new
// tab is shown.

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "wb:base"
import "wb:i18n"
import "wb:page"

// about:home with this query shows the next painting without leaving the tab (the "another painting" button links here).
ART_NEXT_URL :: "about:home?art=next"
ART_ON_URL :: "about:home?art=on"     // the start page's card: turn the art start page on
ART_OFF_URL :: "about:home?art=off"   // the art page's link: back to the plain start page

// Chooses what a new tab shows: the art page when the option is on, else the plain start page. Called by show_home.
// Returns true when it handled the tab (loaded the art page).
art_newtab_maybe :: proc(app: ^App, t: ^Tab, want_next: bool) -> bool {
	if !art.cfg.enabled { return false }
	art_seen_new_tab(app)   // first art new tab of the session: starts the background task; marks activity
	_ = want_next   // the recent-pick ring already avoids repeating the last ones, so "another painting" differs on its own
	// pick a painting suited to the window's orientation
	landscape := art_window_landscape(app)
	it := art_pick(landscape)
	if it == nil && !art.cfg.offline_fallback { return false }   // nothing ready and no fallback: the plain start page
	html := art_page_html(app, it, landscape)
	art_show_page(app, t, html)
	t.art_empty = it == nil   // no painting yet: art_fill_waiting replaces this page when the first one is ready
	if it != nil { art_consume() }   // this painting is shown: let the window refill with a fresh one
	return true
}

// A painting is ready: the art new tabs that showed none yet show it (still the start page, nothing typed or opened over them).
art_fill_waiting :: proc(app: ^App) {
	for t in tabs_all(app) {
		if !t.art_empty || t.kind != .Web || t.url != HOME_URL || t.page == nil { continue }
		t.art_empty = false
		cur := app.active
		if w, _ := window_of_tab(app, t); w != nil { window_activate(app, w) }
		_ = art_newtab_maybe(app, t, false)
		if cur != nil && cur != app.active { window_activate(app, cur) }
	}
}

// about:home with a query: `art=next` shows the next painting; `art=on` / `art=off` turn the art start page on or off (a person's
// choice or a link of the start page itself: `acts`, see nav_trust.odin) and show the start page as it is then.
home_query :: proc(app: ^App, t: ^Tab, target: string, acts: bool) {
	if acts {
		switch {
		case strings.contains(target, "art=on"):  set_pref_bool(app, "browser.newtab.art.enabled", true)
		case strings.contains(target, "art=off"): set_pref_bool(app, "browser.newtab.art.enabled", false)
		}
	}
	show_home(app, t, strings.contains(target, "art=next"))
}

// Loads the art page HTML into the tab, like show_home.
@(private = "file")
art_show_page :: proc(app: ^App, t: ^Tab, html: string) {
	base.scope_close(t.nav)
	t.nav = base.scope_make("navigation", t.scope)
	t.load, t.kind = nil, .Web
	t.page = page.page_create(&app.loop, &app.loader, &app.page_settings, t.nav, HOME_URL, console_sink, t)
	attach_page(app, t, t.page)
	layout_reset(&t.layout)
	t.scroll_target = base.NIL_HANDLE
	t.scroll = 0
	console_reset(t)
	page.load_html(t.page, transmute([]byte)html)
	delete(t.url); t.url = strings.clone(HOME_URL)
	delete(t.title); t.title = strings.clone(i18n.tr("New tab"))
	set_status(t, HOME_URL)
	address_set(app, t, "")   // like the start page: an empty address bar
}

// Whether the window is wider than tall (the "smart" orientation match). Uses the active window's last painted page
// area; falls back to landscape when it is unknown (a fresh window before its first frame).
@(private = "file")
art_window_landscape :: proc(app: ^App) -> bool {
	w := active_window(app)
	r := w.page_rect
	ww := r.max.x - r.min.x
	hh := r.max.y - r.min.y
	if ww <= 0 || hh <= 0 { return true }
	return ww >= hh
}

////////////////////////////////
// HTML

@(private = "file")
ART_STYLE :: `
  * { box-sizing: border-box; }
  html, body { height: 100%; margin: 0; }
  body { font-family: system-ui; color: #f1f4fb; background-color: #0d1017; overflow: hidden; }
  .art-bg { position: fixed; inset: 0; background-position: center; background-repeat: no-repeat;
            background-size: $FIT$; background-color: #0d1017; }
  .art-blur { position: fixed; inset: 0; background-position: center; background-repeat: no-repeat;
              background-size: cover; filter: blur(42px) brightness(0.6); transform: scale(1.1); }
  .art-top { position: fixed; top: 0; left: 0; right: 0; height: 180px;
             background-image: linear-gradient(to bottom, rgba(5,8,14,0.72), rgba(5,8,14,0)); pointer-events: none; }
  .art-bottom { position: fixed; bottom: 0; left: 0; right: 0; height: 220px;
                background-image: linear-gradient(to top, rgba(5,8,14,0.82), rgba(5,8,14,0)); pointer-events: none; }
  .art-shortcuts { position: fixed; top: 34px; left: 0; right: 0; display: flex; justify-content: center; gap: 12px; }
  .art-chip { padding: 9px 18px; border-radius: 20px; background-color: rgba(20,25,38,0.72);
              border: 1px solid rgba(255,255,255,0.14); color: #e7ecf6; text-decoration: none; font-size: 14px; }
  .art-chip:hover { background-color: rgba(40,48,70,0.85); border-color: #ffb84d; }
  .art-caption { position: fixed; left: 28px; bottom: 24px; right: 28px; display: flex; align-items: flex-end;
                 justify-content: space-between; gap: 20px; }
  .art-text { max-width: 70%; text-shadow: 0 1px 6px rgba(0,0,0,0.85); }
  .art-title { margin: 0; font-size: 22px; font-weight: 600; }
  .art-meta { margin: 3px 0 0; font-size: 15px; color: #d4dbec; }
  .art-meta a { color: #ffd699; text-decoration: none; }
  .art-meta a:hover { text-decoration: underline; }
  .art-license { margin: 4px 0 0; font-size: 12px; color: #9aa6c0; letter-spacing: 0.2px; }
  .art-actions { display: flex; gap: 2px; align-items: center; }
  .art-btn { padding: 5px 9px; border-radius: 7px; color: rgba(241,244,251,0.58); text-decoration: none; font-size: 13px;
             white-space: nowrap; text-shadow: 0 1px 4px rgba(0,0,0,0.8); }
  .art-btn:hover { color: #ffffff; background-color: rgba(255,255,255,0.14); }
  .art-sep { width: 1px; height: 12px; background-color: rgba(255,255,255,0.22); margin: 0 4px; }
  .art-empty { position: fixed; inset: 0; background-image: linear-gradient(135deg, #10213f, #1a1030 60%, #0d1017); }
  @media (prefers-reduced-motion: no-preference) { .art-bg { transition: opacity 240ms ease; } }
  @media (prefers-color-scheme: light) {
    .art-top { background-image: linear-gradient(to bottom, rgba(245,246,250,0.6), rgba(245,246,250,0)); }
    .art-bottom { background-image: linear-gradient(to top, rgba(10,13,20,0.7), rgba(10,13,20,0)); }
  }
`

// The whole art page. `it` nil = the fallback gradient with no painting.
art_page_html :: proc(app: ^App, it: ^Art_Item, landscape: bool) -> string {
	sb := strings.builder_make(context.temp_allocator)
	fit := art_fit_mode(it, landscape)
	style, _ := strings.replace_all(ART_STYLE, "$FIT$", fit, context.temp_allocator)
	strings.write_string(&sb, "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>")
	strings.write_string(&sb, i18n.tr("New tab"))
	strings.write_string(&sb, "</title>\n<style>")
	strings.write_string(&sb, style)
	strings.write_string(&sb, "</style>\n</head>\n<body>\n")

	if it == nil {
		strings.write_string(&sb, "<div class=\"art-empty\"></div>\n")
	} else {
		data := art_data_url(it)
		// a blurred fill behind a "contain" image so a portrait on a wide window (or the reverse) has no black bars
		if fit == "contain" {
			fmt.sbprintf(&sb, "<div class=\"art-blur\" style=\"background-image:url('%s')\"></div>\n", data)
		}
		fmt.sbprintf(&sb, "<div class=\"art-bg\" style=\"background-image:url('%s')\"></div>\n", data)
	}

	strings.write_string(&sb, "<div class=\"art-top\"></div>\n")
	// the start page's shortcuts stay, as chips over the painting
	strings.write_string(&sb, "<div class=\"art-shortcuts\">")
	fmt.sbprintf(&sb, "<a class=\"art-chip\" href=\"about:config\">%s</a>", i18n.tr("Configuration"))
	fmt.sbprintf(&sb, "<a class=\"art-chip\" href=\"about:demos\">%s</a>", i18n.tr("Demos & tests"))
	strings.write_string(&sb, "</div>\n")
	strings.write_string(&sb, "<div class=\"art-bottom\"></div>\n")

	// the caption and the buttons
	strings.write_string(&sb, "<div class=\"art-caption\">\n")
	if art.cfg.show_caption {
		strings.write_string(&sb, "<div class=\"art-text\">\n")
		title := it != nil && it.title != "" ? it.title : i18n.tr("A painting")
		fmt.sbprintf(&sb, "<p class=\"art-title\">%s</p>\n", art_escape(title))
		art_write_meta(&sb, it)
		if it != nil && it.license != "" { fmt.sbprintf(&sb, "<p class=\"art-license\">%s</p>\n", art_escape(it.license)) }
		strings.write_string(&sb, "</div>\n")
	} else {
		strings.write_string(&sb, "<div class=\"art-text\"></div>\n")
	}
	strings.write_string(&sb, "<div class=\"art-actions\">\n")
	fmt.sbprintf(&sb, "<a class=\"art-btn\" href=\"%s\">%s</a>\n", ART_NEXT_URL, i18n.tr("Another painting"))
	if it != nil && it.record != "" { fmt.sbprintf(&sb, "<a class=\"art-btn\" href=\"%s\">%s</a>\n", art_escape(it.record), i18n.tr("Open the record")) }
	// back to the plain start page (the same switch as browser.newtab.art.enabled)
	strings.write_string(&sb, "<span class=\"art-sep\"></span>\n")
	fmt.sbprintf(&sb, "<a class=\"art-btn\" href=\"%s\">%s</a>\n", ART_OFF_URL, i18n.tr("Plain start page"))
	strings.write_string(&sb, "</div>\n</div>\n")

	strings.write_string(&sb, "</body>\n</html>\n")
	return strings.to_string(sb)
}

// "cover" for a painting whose orientation matches the window (it fills every pixel), "contain" otherwise (it is shown
// whole over a blurred fill of itself, so a tall portrait on a wide screen is not cropped to a sliver).
@(private = "file")
art_fit_mode :: proc(it: ^Art_Item, landscape: bool) -> string {
	if it == nil { return "cover" }
	it_landscape := it.width >= it.height
	return it_landscape == landscape ? "cover" : "contain"
}

@(private = "file")
art_write_meta :: proc(sb: ^strings.Builder, it: ^Art_Item) {
	if it == nil {
		fmt.sbprintf(sb, "<p class=\"art-meta\">%s</p>\n", i18n.tr("No painting could be loaded yet."))
		return
	}
	strings.write_string(sb, "<p class=\"art-meta\">")
	parts := make([dynamic]string, context.temp_allocator)
	if it.artist != "" { append(&parts, art_escape(it.artist)) }
	if it.date != "" { append(&parts, art_escape(it.date)) }
	if it.museum != "" { append(&parts, art_escape(it.museum)) }
	strings.write_string(sb, strings.join(parts[:], " &middot; ", context.temp_allocator))
	strings.write_string(sb, "</p>\n")
}

// The cached image as a data: URL (base64), read from disk each time the page is built. Returns an empty transparent
// pixel when the file is gone (purged between the pick and the paint): the gradient stays.
@(private = "file")
art_data_url :: proc(it: ^Art_Item) -> string {
	data, err := os.read_entire_file(it.file, context.temp_allocator)
	if err != nil || len(data) == 0 {
		return "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="
	}
	mime := art_mime_of(it.file)
	return strings.concatenate({"data:", mime, ";base64,", base64.encode(data, allocator = context.temp_allocator)}, context.temp_allocator)
}

@(private = "file")
art_mime_of :: proc(path: string) -> string {
	s := strings.to_lower(path, context.temp_allocator)
	switch {
	case strings.has_suffix(s, ".png"):  return "image/png"
	case strings.has_suffix(s, ".webp"): return "image/webp"
	case strings.has_suffix(s, ".gif"):  return "image/gif"
	case strings.has_suffix(s, ".bmp"):  return "image/bmp"
	}
	return "image/jpeg"
}

// Escapes text for an HTML attribute or text node (the caption shows values from the sources).
@(private = "file")
art_escape :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for c in s {
		switch c {
		case '&': strings.write_string(&sb, "&amp;")
		case '<': strings.write_string(&sb, "&lt;")
		case '>': strings.write_string(&sb, "&gt;")
		case '"': strings.write_string(&sb, "&quot;")
		case '\'': strings.write_string(&sb, "&#39;")
		case: strings.write_rune(&sb, c)
		}
	}
	return strings.to_string(sb)
}
