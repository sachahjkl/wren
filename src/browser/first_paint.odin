package browser

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "toolkit:draw"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:css"
import "wb:host"
import lay "wb:layout"
import "wb:page"
import "wb:style"
import "wb:url"

// The first paint of a new document, without a white flash in between (what browsers call paint holding):
//   * when a tab navigates, the frame of the page it showed stays on screen (no input reaches the page, it is not laid
//     out again; it was left: frozen for the back/forward cache, or unloaded and running until the hold ends) while the
//     new one loads, then until the new document's first useful paint: its render-blocking stylesheets are there
//     (page/render_blocking.odin) and its layout shows something (text with its font, an image, a control...). After
//     browser.paint_holding.timeout_ms past the arrival of the new document, its canvas color is shown instead (no
//     longer the old page) until it can paint. Chromium holds for up to about a second; 1000 ms here.
//   * the old page is closed as soon as it is no longer shown;
//   * nothing to hold (the tab's first page, a page that never painted, another origin when
//     browser.paint_holding.cross_origin is off): the expected canvas is shown, Canvas of the user's preferred scheme
//     until the new document says better (its root's scheme, its background), never a white flash in a dark theme;
//   * built-in pages (about:home, about:config, error pages) are shown at once.
// A frozen frame is painted only while it is still exact: if the old document changed meanwhile (its scripts run until
// it is closed), its canvas color is shown instead.

Hold_State :: enum u8 {
	None,
	Waiting,    // the old frame stands, with no limit: the new document has not arrived
	Counting,   // it has (Tab_Nav.arrived): the old frame stands until browser.paint_holding.timeout_ms past that
}

// What happens to a hold (hold_step).
Hold_Event :: enum u8 {
	Navigation,   // a navigation leaves the tab's page: its frame is held if it can be, else it goes; what was held waits for the new document
	Arrival,      // the page phase saw the new document
	Over,         // the old page goes: closed, or into the back/forward cache
	Back,         // the navigation did not happen: the old page is the tab's again
	Tab_Gone,     // the tab's scope closed it
}

Paint_Hold :: struct {
	state:     Hold_State,
	nav:       ^base.Scope,   // the old navigation: its page and everything it started
	page:      ^page.Page,
	load:      ^Doc_Load,     // (the old navigation's: the tab's again if the page comes back)
	no_store:  bool,          // (the same)
	layout:    Layout,        // its last layout (painted as is); reused as the tab's next layout memory
	scroll:    f32,
	canvas:    css.Color,     // the old page's canvas
	// the held page goes into the back/forward cache when the hold ends (bfcache.odin), with what the tab had of it
	bf_entry:  u64,
	zoom:      f32,
	image_sizes: u64,
	web_fonts: int,
}

// Fallback colors of classic scroll bars in the dark scheme (the preferences' defaults: Chrome's).
DARK_CLASSIC_THUMB :: css.Color{0.408, 0.408, 0.408, 1}
DARK_CLASSIC_TRACK :: css.Color{0.259, 0.259, 0.259, 1}
DARK_CLASSIC_ARROW :: css.Color{0.639, 0.639, 0.639, 1}

First_Paint_Settings :: struct {
	enabled:      bool,
	timeout_ms:   f64,
	cross_origin: bool,
	dark_thumb, dark_track: css.Color,
	dark_classic: Bar_Colors,
}

FIRST_PAINT_PREFS := [?]config.Def{
	{name = "browser.paint_holding.enabled", kind = .Bool, default = {b = true},
		description = "Keep showing the current page while the next one loads, until the next one can paint (its stylesheets and fonts are there), instead of a blank page. Off: the page is cleared as soon as a navigation starts."},
	{name = "browser.paint_holding.timeout_ms", kind = .Float, default = {f = 1000}, bounded = true, min = 0, max = 60_000, unit = "ms",
		description = "Once the next document has arrived, how long the previous page may stay on screen while it is not ready to paint; then its background color shows until it is. (Chromium: up to about a second.)"},
	{name = "browser.paint_holding.cross_origin", kind = .Bool, default = {b = true},
		description = "Hold the previous page also when the next one is on another origin. Off: only same-origin navigations keep it (the page of another site is never shown under the next one's address)."},
	{name = "browser.scrollbar.dark.thumb_color", kind = .String, default = {s = "rgba(170, 170, 180, 0.6)"},
		description = "Scroll bar thumbs of pages and elements whose color scheme is dark (CSS color). The light ones: layout.scrollbar.thumb_color."},
	{name = "browser.scrollbar.dark.track_color", kind = .String, default = {s = "rgba(255, 255, 255, 0.06)"},
		description = "Scroll bar tracks in the dark color scheme (CSS color, transparent = none). The light ones: layout.scrollbar.track_color."},
	{name = "browser.scrollbar.dark.classic_thumb_color", kind = .String, default = {s = "#686868"},
		description = "Classic scroll bar thumbs in the dark color scheme (CSS color). The light ones: layout.scrollbar.classic.thumb_color."},
	{name = "browser.scrollbar.dark.classic_track_color", kind = .String, default = {s = "#424242"},
		description = "Classic scroll bar tracks, arrow buttons and corners in the dark color scheme (CSS color)."},
	{name = "browser.scrollbar.dark.classic_arrow_color", kind = .String, default = {s = "#a3a3a3"},
		description = "Arrows of classic scroll bars in the dark color scheme (CSS color)."},
}

register_first_paint_prefs :: proc(p: ^config.Prefs) { config.register(p, FIRST_PAINT_PREFS[:]) }


@(private = "file")
pref_color :: proc(p: ^config.Prefs, name: string, fallback: css.Color) -> css.Color {
	vs := css.parse_component_values(config.string_of(p, name), {max_nesting_depth = 32, max_rules = 1}, context.temp_allocator)
	if cv, ok := css.parse_color(vs, nil); ok && cv.kind == .Rgba { return cv.rgba }
	return fallback
}

@(private = "file")
first_paint_settings_from :: proc(p: ^config.Prefs) -> First_Paint_Settings {
	return {
		enabled = config.bool_of(p, "browser.paint_holding.enabled"),
		timeout_ms = config.float_of(p, "browser.paint_holding.timeout_ms"),
		cross_origin = config.bool_of(p, "browser.paint_holding.cross_origin"),
		dark_thumb = pref_color(p, "browser.scrollbar.dark.thumb_color", {0.67, 0.67, 0.7, 0.6}),
		dark_track = pref_color(p, "browser.scrollbar.dark.track_color", {1, 1, 1, 0.06}),
		dark_classic = {
			thumb = pref_color(p, "browser.scrollbar.dark.classic_thumb_color", DARK_CLASSIC_THUMB),
			track = pref_color(p, "browser.scrollbar.dark.classic_track_color", DARK_CLASSIC_TRACK),
			arrow = pref_color(p, "browser.scrollbar.dark.classic_arrow_color", DARK_CLASSIC_ARROW),
		},
	}
}

first_paint_init :: proc(app: ^App) {
	app.scheme_ui = first_paint_settings_from(&app.prefs)
	app.watches[.First_Paint] = config.watch(&app.prefs, "browser.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		the_app.scheme_ui = first_paint_settings_from(p)
		request_frames((^App)(user), 2)
	}, app)
}

// The color behind a page that has nothing to show yet: Canvas of the scheme the user prefers.
expected_canvas :: proc(app: ^App) -> css.Color {
	s := &app.page_settings.style
	return s.colors[style.preferred_scheme(s)][.Canvas]
}

// Whether the frame of `t`'s page may be held through a navigation to `target`.
@(private = "file")
holdable :: proc(t: ^Tab, target: string) -> bool {
	if !the_app.scheme_ui.enabled || t.kind != .Web || t.page == nil || !t.page.render.painted { return false }
	if !t.layout.valid || t.layout.mutations != t.page.doc.mutations { return false }
	if !the_app.scheme_ui.cross_origin {
		u, ok := url.parse_absolute(target, context.temp_allocator)
		if !ok || !url.same_origin(url.origin_of(u, context.temp_allocator), t.page.env.origin) { return false }
	}
	return true
}

// Milliseconds on the loop's clock since `at` (host.now_ns of it): what falls due through the loop reads that clock.
shell_elapsed_ms :: proc(at: i64) -> f64 { return f64(shell_now_ns() - at) / NS_PER_MS_F }

NS_PER_MS_F :: 1e6

// The loop's clock. (A unit test's App is not the_app: there none, and time stands still.)
shell_now_ns :: proc() -> i64 { return the_app != nil ? host.now_ns(&the_app.loop) : 0 }

// The one place a hold changes.
hold_step :: proc(app: ^App, t: ^Tab, ev: Hold_Event, target := "") {
	h := &t.hold
	switch ev {
	case .Navigation:
		if holdable(t, target) {
			hold_step(app, t, .Over)   // a page already held goes: the current one painted after it
			h.state = .Waiting
			h.nav, h.page, h.load, h.no_store = t.nav, t.page, t.load, t.nav_state.no_store
			h.layout, t.layout = t.layout, h.layout   // the held frame; the tab gets the old memory back
			h.scroll = t.scroll
			h.bf_entry, h.zoom, h.image_sizes, h.web_fonts = t.nav_state.bf_entry, t.zoom, t.image_sizes, t.web_fonts
			t.nav_state.bf_entry = 0
			h.canvas = t.page.styled != nil ? t.page.styled.canvas : expected_canvas(app)
			page.set_page_visible(t.page, false)   // its timers slow down to background pace; nothing paints it again
			page.page_set_left(t.page, true)
			t.nav = nil
		} else {
			bfcache_take(app, t)   // (not kept: it goes with the scope, what is held, if anything, stays)
			if h.state == .Counting { h.state = .Waiting }
		}
		layout_reset(&t.layout)
	case .Arrival:
		if h.state == .Waiting { h.state = .Counting }
	case .Over:
		if h.state == .None { return }
		if !bfcache_take_held(app, t) {
			base.scope_close(h.nav)   // the old page, its modules and every request it still had
			layout_reset(&h.layout)
		}
		page_fonts_drop(&app.page_render.fonts, h)   // its web faces, if the new page took over the tab's (fonts.odin)
		h.state, h.nav, h.page, h.load = .None, nil, nil, nil
	case .Back:
		left := t.nav
		t.nav, t.page, t.load, t.nav_state.no_store = h.nav, h.page, h.load, h.no_store
		t.layout, h.layout = h.layout, t.layout
		t.scroll = h.scroll
		t.fragment_done = true   // (it is where it was)
		h.state, h.nav, h.page, h.load, h.bf_entry = .None, nil, nil, nil, 0
		t.nav_state.left = nil
		page.page_set_left(t.page, false)
		page.page_thaw(t.page, visible = current_tab(app) == t)   // frozen for the back/forward cache when it was left (bfcache.odin)
		base.scope_close(left)   // the navigation's scope: its Doc_Load (a download's request is the download's now)
		delete(t.url)
		t.url = strings.clone(t.page.env.location.href)
		delete(t.title)
		t.title = default_tab_title(t.url, context.allocator)
		tab_icon_destroy(&t.icon)   // the title and icon are read again from the page
		nav_to(app, t, .Painted)
	case .Tab_Gone:
		h.state, h.nav, h.page, h.load = .None, nil, nil, nil
		layout_destroy(&h.layout)
		page_fonts_drop(&app.page_render.fonts, h)
	}
}

// The limit of the hold has passed.
hold_expired :: proc(app: ^App, t: ^Tab) -> bool {
	return t.hold.state == .Counting && shell_elapsed_ms(t.nav_state.arrived) >= app.scheme_ui.timeout_ms
}

// The old page has no reason to stay: the new one painted, its limit passed, or the new document's origin may not show under it.
hold_ended :: proc(app: ^App, t: ^Tab) -> bool {
	h := &t.hold
	if h.state != .Counting { return false }
	if t.nav_state.phase == .Painted || hold_expired(app, t) { return true }
	return !app.scheme_ui.cross_origin && t.page != nil && h.page != nil && !url.same_origin(t.page.env.origin, h.page.env.origin)
}

// Whether the held frame still says what its page is: its items read the document's text. The page runs: a script that reads a computed style makes a pass of its own with
// no layout to go with it (js_dom_styled); the held layout reads the records of its own pass, which stands as long as it does (style.styled_read_begin).
hold_exact :: proc(h: ^Paint_Hold) -> bool {
	return h.page != nil && h.layout.valid && h.layout.mutations == h.page.doc.mutations
}

// Paints what the tab shows while its page cannot paint: the held frame if it is still exact, else `fallback` as the
// canvas. Returns true when the held frame was painted.
hold_paint :: proc(app: ^App, t: ^Tab, dc: ^draw.Context, r: draw.Rect, fallback: css.Color) -> bool {
	h := &t.hold
	if !hold_exact(h) {
		draw.rect(dc, r, to_draw(h.state != .None ? h.canvas : fallback))
		return false
	}
	size := draw.rect_size(r)
	draw.rect(dc, r, to_draw(h.canvas))
	held_tab := Tab{page = h.page}   // the image painter looks images up in the page being painted
	images_before_layout(&held_tab)
	draw.push_clip(dc, r)
	images_paint_begin_frame(app)
	lo_y, hi_y := lay.doc_scroll_y_range(&h.layout, size.y)
	paint(&h.layout, dc, h.page.doc, r.min, size, clamp(h.scroll, lo_y, hi_y), r)
	images_after_paint(app)
	draw.pop_clip(dc)
	return true
}

// Something of the layout is content (CSS Paint Timing's "contentful": text, images, form controls, list markers). Text waiting for its
// font is drawn invisible: it is not, and a held page stays on screen for it (the page's families were read before the layout: adopt_web_fonts).
layout_contentful :: proc(l: ^Layout) -> bool {
	if !l.valid { return false }
	for &it in l.items {
		#partial switch it.kind {
		case .Text: if strings.trim_space(it.text) != "" && !web_text_invisible(l, it.cs) { return true }
		case .Replaced, .Control, .Marker: return true
		}
	}
	return false
}

// Milliseconds before the hold of `t` times out (the shell wakes up then); -1 when there is none.
hold_wait_ms :: proc(t: ^Tab) -> f64 {
	h := &t.hold
	if h.state != .Counting { return -1 }
	return max(the_app.scheme_ui.timeout_ms - shell_elapsed_ms(t.nav_state.arrived), 0)
}

// The first paint of the tab's new page happened now: the profile build records how long it took (WREN_PROF set:
// appended to <WREN_PROF>.firstpaint.txt as "milliseconds since the navigation started, since the document arrived, URL,
// where the document and the subresources came from": http_cache_ui.odin cache_prof_fields).
prof_first_paint :: proc(t: ^Tab) {
	when PROFILE {
		if !prof.on { return }
		since_nav := shell_elapsed_ms(t.nav_state.started)
		since_doc := t.nav_state.arrived != 0 ? shell_elapsed_ms(t.nav_state.arrived) : -1
		path := strings.concatenate({prof.out, ".firstpaint.txt"}, context.temp_allocator)
		f, err := os.open(path, {.Write, .Create, .Append}, os.Permissions_Default_File)
		if err != nil { return }
		defer os.close(f)
		os.write_string(f, fmt.tprintf("%.1f\t%.1f\t%s\t%s\n", since_nav, since_doc, t.url, cache_prof_fields(t)))   // (http_cache_ui.odin)
	}
}

_ :: fmt   // used by the profile build only
_ :: os

// The current tab's document has not painted, has changed since its last layout or was held by render-blocking resources
// in the last page phase, and waits for nothing that blocks its rendering: the frame that paints it may start now
// (pacing.odin pacer_slot_wait). `laid`: the mutation count of that last layout (0: no document).
first_paint_due :: proc(app: ^App) -> (due: bool, laid: u64) {
	t := current_tab(app)
	if t == nil || t.kind != .Web || t.page == nil || t.page.doc == nil { return }
	laid = t.layout.mutations
	pp := &window_own(app).page_prep
	blocked := pp.tab == t && pp.page == t.page && pp.blocked
	if t.page.render.painted || (laid == t.page.doc.mutations && !blocked) { return }
	state, _ := page.first_paint_state(t.page)
	return state == .Ready, laid
}

// A blocked first paint or a hold ends at a known time even if nothing else happens: a frame is requested then.
first_paint_wake :: proc(app: ^App, t: ^Tab) {
	wait := hold_wait_ms(t)
	if t.page != nil {
		if d := page.first_paint_next_deadline_ms(t.page); d >= 0 && (wait < 0 || d < wait) { wait = d }
	}
	if wait < 0 { return }
	own := window_own(app)
	if own.first_paint_timer != base.NIL_HANDLE { host.clear_timer(&app.loop, own.first_paint_timer) }
	own.first_paint_timer = host.set_timer(&app.loop, max(wait, 1), 0, proc(data: rawptr) {
		w := window_by_id(the_app, int(uintptr(data)))
		if w == nil { return }
		w.own.first_paint_timer = base.NIL_HANDLE
		window_request(the_app, w, 2)
	}, rawptr(uintptr(active_window(app).id)))
}

// A thin bar along the top of the page while the tab loads a document that has not painted yet. (The pointer shows
// the "working in background" cursor over the page meanwhile: page_cursor.odin.)
loading_bar :: proc(app: ^App, t: ^Tab, dc: ^draw.Context, r: draw.Rect) {
	if !tab_loading(t) { return }
	scale := ui.scale()
	h := max(2 * scale, 1)
	w := r.max.x - r.min.x
	// indeterminate: a segment sweeping across, eased in time since the navigation started
	ms := shell_elapsed_ms(t.nav_state.started)
	k := f32(math.mod(ms, 1400) / 1400)
	seg := w * 0.3
	x := r.min.x - seg + (w + seg) * k
	accent := to_draw(app.page_settings.style.colors[style.preferred_scheme(&app.page_settings.style)][.Highlight])
	draw.push_clip(dc, r)
	draw.rect(dc, {{x, r.min.y}, {x + seg, r.min.y + h}}, accent)
	draw.pop_clip(dc)
	request_frames(app, 2)
}

// The tab is loading a document that has not painted yet.
tab_loading :: proc(t: ^Tab) -> bool {
	if t == nil || t.kind != .Web { return false }
	if t.page == nil { return nav_pending(t) }
	return !t.page.render.painted && (t.load != nil || t.hold.state != .None)
}
