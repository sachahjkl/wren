package browser

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import "toolkit:draw"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:css"
import "wb:host"
import "wb:page"
import "wb:style"
import "wb:url"

// The first paint of a new document, without a white flash in between (what browsers call paint holding):
//   * when a tab navigates, the page it showed stays on screen, frozen (no input reaches it, it is not laid out
//     again; it keeps running until the new document arrives, as in other browsers before the commit) while the new
//     one loads, then until the new document's first useful paint: its render-blocking stylesheets and fonts are
//     there (page/render_blocking.odin) and its layout shows something (text, an image, a control...). After
//     browser.paint_holding.timeout_ms past the arrival of the new document, its canvas color is shown instead (no
//     longer the old page) until it can paint. Chromium holds for up to about a second; 1000 ms here.
//   * the old page is closed as soon as it is no longer shown;
//   * nothing to hold (the tab's first page, a page that never painted, another origin when
//     browser.paint_holding.cross_origin is off): the expected canvas is shown, Canvas of the user's preferred scheme
//     until the new document says better (its root's scheme, its background), never a white flash in a dark theme;
//   * built-in pages (about:home, about:config, error pages) are shown at once.
// A frozen frame is painted only while it is still exact: if the old document changed meanwhile (its scripts run until
// it is closed), its canvas color is shown instead.

Paint_Hold :: struct {
	active:    bool,
	nav:       ^base.Scope,   // the old navigation: its page and everything it started
	page:      ^page.Page,
	layout:    Layout,        // its last layout (painted as is); reused as the tab's next layout memory
	scroll:    f32,
	canvas:    css.Color,     // the old page's canvas
	commit:    time.Tick,     // when the new document arrived
	committed: bool,          // ... it has (for this navigation)
	started:   time.Tick,     // when the navigation started (held or not: time to first paint)
}

First_Paint_Settings :: struct {
	enabled:      bool,
	timeout_ms:   f64,
	cross_origin: bool,
	dark_thumb, dark_track: css.Color,
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
}

scheme_ui: First_Paint_Settings
@(private = "file") first_paint_watch: int

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
	}
}

first_paint_init :: proc(app: ^App) {
	scheme_ui = first_paint_settings_from(&app.prefs)
	first_paint_watch = config.watch(&app.prefs, "browser.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		scheme_ui = first_paint_settings_from(p)
		(^App)(user).frames_requested = max((^App)(user).frames_requested, 2)
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
	if !scheme_ui.enabled || t.kind != .Web || t.page == nil || !t.page.render.painted { return false }
	if !t.layout.valid || t.layout.mutations != t.page.doc.mutations { return false }
	if !scheme_ui.cross_origin {
		u, ok := url.parse_absolute(target, context.temp_allocator)
		if !ok || !url.same_origin(url.origin_of(u, context.temp_allocator), t.page.env.origin) { return false }
	}
	return true
}

// Navigation of `t` to `target` starts: its page is held (or closed), and the tab is ready for a new navigation scope.
// Closes the previous navigation scope in every case but the held one.
hold_begin :: proc(app: ^App, t: ^Tab, target: string) {
	t.hold.started = time.tick_now()
	t.hold.committed = false
	if holdable(t, target) {
		hold_release(t)   // a page already held goes: the current one painted after it
		h := &t.hold
		h.active = true
		h.nav, h.page = t.nav, t.page
		h.layout, t.layout = t.layout, h.layout   // the held frame; the tab gets the old memory back
		h.scroll = t.scroll
		h.canvas = t.page.styled != nil ? t.page.styled.canvas : expected_canvas(app)
		page.set_page_visible(t.page, false)   // its timers slow down to background pace; nothing paints it again
	} else {
		base.scope_close(t.nav)   // the page that was never painted (or nothing): what is held, if anything, stays
	}
	t.nav = nil
	layout_reset(&t.layout)
}

// Stops holding: the old page closes.
hold_release :: proc(t: ^Tab) {
	h := &t.hold
	if !h.active { return }
	base.scope_close(h.nav)   // the old page, its modules and every request it still had
	layout_reset(&h.layout)
	h.active, h.nav, h.page = false, nil, nil
}

// Tab closing: the held page went with the tab's scope.
hold_destroy :: proc(t: ^Tab) {
	t.hold.active, t.hold.nav, t.hold.page = false, nil, nil
	layout_destroy(&t.hold.layout)
}

// Paints what the tab shows while its page cannot paint: the held frame if it is still exact and not timed out, else
// `fallback` as the canvas. Returns true when the held frame was painted.
hold_paint :: proc(app: ^App, t: ^Tab, dc: ^draw.Context, r: draw.Rect, fallback: css.Color) -> bool {
	h := &t.hold
	if h.active && h.committed && f64(time.duration_milliseconds(time.tick_since(h.commit))) >= scheme_ui.timeout_ms {
		hold_release(t)
	}
	if !h.active || h.page == nil || !h.layout.valid || h.layout.mutations != h.page.doc.mutations {
		draw.rect(dc, r, to_draw(h.active ? h.canvas : fallback))
		return false
	}
	size := draw.rect_size(r)
	draw.rect(dc, r, to_draw(h.canvas))
	held_tab := Tab{page = h.page}   // the image painter looks images up in the page being painted
	images_before_layout(&held_tab)
	draw.push_clip(dc, r)
	images_paint_begin_frame(app)
	paint(&h.layout, dc, h.page.doc, r.min, size, clamp(h.scroll, 0, max(0, h.layout.height - size.y)), r)
	images_after_paint(app)
	draw.pop_clip(dc)
	return true
}

// The new document of `t` arrived: the hold now counts down (and ends at once across origins when that is not allowed).
hold_commit :: proc(t: ^Tab) {
	h := &t.hold
	if h.committed { return }
	h.committed = true
	h.commit = time.tick_now()
	if h.active && !scheme_ui.cross_origin && t.page != nil && h.page != nil && !url.same_origin(t.page.env.origin, h.page.env.origin) { hold_release(t) }
}

// Something of the layout is content (CSS Paint Timing's "contentful": text, images, form controls, list markers).
layout_contentful :: proc(l: ^Layout) -> bool {
	if !l.valid { return false }
	for &it in l.items {
		#partial switch it.kind {
		case .Text: if strings.trim_space(it.text) != "" { return true }
		case .Replaced, .Control, .Marker: return true
		}
	}
	return false
}

// Milliseconds before the hold of `t` times out (the shell wakes up then); -1 when there is none.
hold_wait_ms :: proc(t: ^Tab) -> f64 {
	h := &t.hold
	if !h.active || !h.committed { return -1 }
	return max(scheme_ui.timeout_ms - f64(time.duration_milliseconds(time.tick_since(h.commit))), 0)
}

// The first paint of the tab's new page happened now: the profile build records how long it took (WREN_PROF set:
// appended to <WREN_PROF>.firstpaint.txt as "milliseconds since the navigation started, since the document arrived, URL").
prof_first_paint :: proc(t: ^Tab) {
	when PROFILE {
		if !prof.on { return }
		since_nav := time.duration_milliseconds(time.tick_since(t.hold.started))
		since_doc := t.hold.committed ? time.duration_milliseconds(time.tick_since(t.hold.commit)) : -1
		path := strings.concatenate({prof.out, ".firstpaint.txt"}, context.temp_allocator)
		f, err := os.open(path, {.Write, .Create, .Append}, os.Permissions_Default_File)
		if err != nil { return }
		defer os.close(f)
		os.write_string(f, fmt.tprintf("%.1f\t%.1f\t%s\n", since_nav, since_doc, t.url))
	}
}

_ :: fmt   // used by the profile build only
_ :: os

@(private = "file") first_paint_timer: base.Handle

// A blocked first paint or a hold ends at a known time even if nothing else happens: a frame is requested then.
first_paint_wake :: proc(app: ^App, t: ^Tab) {
	wait := hold_wait_ms(t)
	if t.page != nil {
		if d := page.first_paint_next_deadline_ms(t.page); d >= 0 && (wait < 0 || d < wait) { wait = d }
	}
	if wait < 0 { return }
	if first_paint_timer != base.NIL_HANDLE { host.clear_timer(&app.loop, first_paint_timer) }
	first_paint_timer = host.set_timer(&app.loop, max(wait, 1), 0, proc(data: rawptr) {
		first_paint_timer = base.NIL_HANDLE
		a := (^App)(data)
		a.frames_requested = max(a.frames_requested, 2)
	}, app)
}

// A thin bar along the top of the page while the tab loads a document that has not painted yet. (The toolkit has no
// "working in background" cursor yet: platform.Cursor.)
loading_bar :: proc(app: ^App, t: ^Tab, dc: ^draw.Context, r: draw.Rect) {
	if !tab_loading(t) { return }
	scale := ui.scale()
	h := max(2 * scale, 1)
	w := r.max.x - r.min.x
	// indeterminate: a segment sweeping across, eased in time since the navigation started
	ms := time.duration_milliseconds(time.tick_since(t.hold.started))
	k := f32(math.mod(ms, 1400) / 1400)
	seg := w * 0.3
	x := r.min.x - seg + (w + seg) * k
	accent := to_draw(app.page_settings.style.colors[style.preferred_scheme(&app.page_settings.style)][.Highlight])
	draw.push_clip(dc, r)
	draw.rect(dc, {{x, r.min.y}, {x + seg, r.min.y + h}}, accent)
	draw.pop_clip(dc)
	app.frames_requested = max(app.frames_requested, 1)
}

// The tab is loading a document that has not painted yet.
tab_loading :: proc(t: ^Tab) -> bool {
	if t == nil || t.kind != .Web { return false }
	if t.page == nil { return t.load != nil }
	return !t.page.render.painted && (t.load != nil || t.hold.active)
}