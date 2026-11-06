package e2e_scenarios

// Every frame the renderer draws around what changes the window's tabs or a page's scale, one by one (the timeline: remote_timeline.odin), holds the page and the
// interface: a tab closed in the back, a Ctrl+wheel over a long page. A settled capture sees none of this: what the eye sees is one frame of 16 ms.

import "core:fmt"
import "core:testing"
import "toolkit:draw"
import "toolkit:render"
import "toolkit:ui"
import "wb:browser"
import "wb:e2e"

@(private = "file") WINDOW_SIZE :: [2]int{1000, 700}
@(private = "file") TIMELINE_FRAMES :: 200
// Frames made after each action: what it asks for and what follows from it.
@(private = "file") FRAMES_AFTER :: 8
@(private = "file") PAGE_COLOR := e2e.Color{46, 139, 87, 255}
// A pixel of the toolbar above the page, of the status bar from the window's corner.
@(private = "file") TOOLBAR_ABOVE_PAGE :: 10
@(private = "file") STATUS_MARGIN :: [2]int{5, 3}
// The long page: a Ctrl+wheel lays it out on the page thread (browser.shell.page_thread), with chrome frames meanwhile. Its background is PAGE_COLOR, the article's column
// fills the middle of the window at every zoom.
@(private = "file") ARTICLE :: "examples/site/zoom_article.html"
@(private = "file") SCROLLED_NOTCHES :: 12
@(private = "file") SCROLL_SETTLE_FRAMES :: 30
@(private = "file") ZOOM_NOTCHES := [?]f64{-1, -1, 1, 1}
@(private = "file") ZOOM_ROUNDS_MOST :: 8
@(private = "file") PAPER_COLOR := e2e.Color{250, 248, 240, 255}
// How far in from the page area's top and bottom its column is looked at, and how much of it: half its width, its height.
@(private = "file") EDGE_PX :: 20
@(private = "file") BAND :: [2]int{100, 8}

@(private = "file")
pixel_of :: proc(f: browser.Tl_Frame, x, y: int) -> e2e.Color {
	i := (y * f.w + x) * 4
	return {f.pixels[i], f.pixels[i + 1], f.pixels[i + 2], f.pixels[i + 3]}
}

@(private = "file")
record :: proc(s: ^e2e.Session) {
	context = s.ctx
	browser.control_timeline_start(s.app, 1, TIMELINE_FRAMES, every = true)
	e2e.wait_frames(s, 2)
}

// What was recorded, valid until `forget`. None was missed.
@(private = "file")
recorded :: proc(t: ^testing.T, s: ^e2e.Session) -> []browser.Tl_Frame {
	context = s.ctx
	browser.timeline_end(s.app)
	frames := s.app.remote.tl.frames[:]
	for f in frames { testing.expect_value(t, f.skipped, 0) }
	return frames
}

@(private = "file")
forget :: proc(s: ^e2e.Session) {
	context = s.ctx
	browser.timeline_free(&s.app.remote.tl)
}

@(private = "file")
tab_with_id :: proc(s: ^e2e.Session, id: int) -> (found: e2e.Tab) {
	for x in e2e.targets(s).tabs { if x.id == id { found = x } }
	return
}

@(private = "file") Close_By :: enum u8 { Cross, Middle_Click }

// Three tabs, the middle one current: the tab `side` of it (-1, 1) closes. The page, the toolbar and the status bar are in every frame, and the current tab stays.
@(private = "file")
close_in_the_back :: proc(t: ^testing.T, by: Close_By, side: int, prefs: []string = nil) {
	dir := e2e.temp_folder(t)
	kept_url := e2e.file_page(dir, "kept.html", `<!doctype html><html style="background:rgb(46,139,87)"><title>Kept</title>`)
	other_url := e2e.file_page(dir, "other.html", `<!doctype html><html style="background:rgb(200,30,30)"><title>Other</title>`)
	s := e2e.start(t, {size = WINDOW_SIZE, url = other_url, prefs = prefs})
	before := e2e.targets(s).tabs[0].id
	kept := e2e.new_tab(s, kept_url)
	s.tab = kept
	e2e.wait_load(s)
	after := e2e.new_tab(s, other_url, background = true)
	e2e.wait_frames(s, FRAMES_AFTER)

	closing := side < 0 ? before : after
	r := tab_with_id(s, closing).rect
	cross := cross_of(s, closing)
	page := s.app.active.page_rect
	record(s)
	if by == .Cross {
		e2e.click_at(s, {f64(cross.min.x + cross.max.x) / 2, f64(cross.min.y + cross.max.y) / 2}, .Window)
	} else {
		e2e.click_at(s, {r.x + r.w / 2, r.y + r.h / 2}, .Window, .Middle)
	}
	e2e.wait_frames(s, FRAMES_AFTER)
	frames := recorded(t, s)
	defer forget(s)

	tabs := e2e.targets(s).tabs
	testing.expect_value(t, len(tabs), 2)
	for x in tabs { testing.expect_value(t, x.active, x.id == kept) }
	testing.expect(t, len(frames) > FRAMES_AFTER, "the frames around the close are there")
	first := frames[0]
	toolbar, status := pixel_of(first, first.w / 2, int(page.min.y) - TOOLBAR_ABOVE_PAGE), pixel_of(first, STATUS_MARGIN.x, first.h - STATUS_MARGIN.y)
	for f in frames {
		testing.expectf(t, near(pixel_of(f, f.w / 2, f.h / 2), PAGE_COLOR), "the page in frame %d: %v", f.n, pixel_of(f, f.w / 2, f.h / 2))
		testing.expectf(t, pixel_of(f, f.w / 2, int(page.min.y) - TOOLBAR_ABOVE_PAGE) == toolbar, "the toolbar in frame %d", f.n)
		testing.expectf(t, pixel_of(f, STATUS_MARGIN.x, f.h - STATUS_MARGIN.y) == status, "the status bar in frame %d", f.n)
	}
}

@(test)
a_tab_closed_by_its_cross_after_the_current_one_leaves_every_frame_whole :: proc(t: ^testing.T) { close_in_the_back(t, .Cross, 1) }

@(test)
a_tab_closed_by_its_cross_before_the_current_one_leaves_every_frame_whole :: proc(t: ^testing.T) { close_in_the_back(t, .Cross, -1) }

@(test)
a_tab_closed_by_a_middle_click_leaves_every_frame_whole :: proc(t: ^testing.T) { close_in_the_back(t, .Middle_Click, 1) }

@(test)
a_tab_closed_in_the_sidebar_leaves_every_frame_whole :: proc(t: ^testing.T) { close_in_the_back(t, .Middle_Click, -1, {"browser.tabs.position=left"}) }

// The article's column at both ends of the page area, in each frame of four Ctrl+wheels: never only the page's background, which a chrome frame used to show where the last
// pixels, moved by the zoom's new offsets, had left.
@(private = "file")
zoom_frames :: proc(t: ^testing.T, s: ^e2e.Session) {
	e2e.scroll(s, SCROLLED_NOTCHES)
	e2e.wait_frames(s, SCROLL_SETTLE_FRAMES)
	chrome_frames := 0
	// (a chrome frame comes when a layout outlasts a frame, which a fast layout may not: the zooms again until one has, they end where they began)
	for _ in 0 ..< ZOOM_ROUNDS_MOST {
		record(s)
		for notches in ZOOM_NOTCHES {
			e2e.scroll(s, notches, ctrl = true)
			e2e.wait_frames(s, FRAMES_AFTER)
		}
		frames := recorded(t, s)
		page := s.app.active.page_rect
		for f in frames {
			if f.nested { chrome_frames += 1 }
			for y in ([2]int{int(page.min.y) + EDGE_PX, int(page.max.y) - EDGE_PX}) {
				testing.expectf(t, paper_at(f, y), "the article at y %d in frame %d (a chrome frame: %v)", y, f.n, f.nested)
			}
		}
		forget(s)
		if chrome_frames > 0 { break }
	}
	testing.expect(t, chrome_frames > 0, "the layouts of the zoom ran on the page thread, with chrome frames")
}

// The article's paper in a band around the middle of the window at `y` (its text and its tables leave some of it in any band).
@(private = "file")
paper_at :: proc(f: browser.Tl_Frame, y: int) -> bool {
	for row in y ..< y + BAND.y {
		for x in f.w / 2 - BAND.x ..< f.w / 2 + BAND.x {
			if near(pixel_of(f, x, row), PAPER_COLOR) { return true }
		}
	}
	return false
}

@(test)
ctrl_wheel_over_a_long_page_keeps_it_in_every_frame :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = WINDOW_SIZE, url = e2e.file_url(fmt.tprintf("%s/%s", e2e.repo_root(), ARTICLE))})
	zoom_frames(t, s)
}

// An idle browser gives its layer targets back (memory_trim.odin), but the picture of the page on screen: it went with them, and the first chrome frame after an
// idle moment showed the page's background alone (seen with two tests in a process, whose wait reached the idle time).
@(test)
a_trim_leaves_the_chrome_frames_the_page_on_screen :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = WINDOW_SIZE, url = e2e.file_url(fmt.tprintf("%s/%s", e2e.repo_root(), ARTICLE))})
	e2e.wait_frames(s, SCROLL_SETTLE_FRAMES)
	context = s.ctx
	tab := browser.current_tab(s.app)
	testing.expect(t, browser.shell_snapshot_of(tab.id) != nil, "a picture of the page is kept")
	browser.memory_trim(s.app)
	kept := browser.shell_snapshot_of(tab.id)
	testing.expect_value(t, kept.gen, render.targets_generation(&s.app.r))
	zoom_frames(t, s)
}

// (shown after it loaded in the back: no frame of it has been kept yet)
@(test)
ctrl_wheel_over_a_page_just_shown_keeps_it_in_every_frame :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = WINDOW_SIZE, url = "about:blank"})
	id := e2e.new_tab(s, e2e.file_url(fmt.tprintf("%s/%s", e2e.repo_root(), ARTICLE)), background = true)
	s.tab = id
	e2e.wait_load(s)
	e2e.wait_frames(s, FRAMES_AFTER)
	e2e.activate_tab(s, id)
	e2e.wait_frames(s, FRAMES_AFTER)
	zoom_frames(t, s)
}

// The tab's close button, under the pointer's hover if it needs it.
@(private = "file")
cross_of :: proc(s: ^e2e.Session, id: int) -> draw.Rect {
	r := tab_with_id(s, id).rect
	e2e.hover(s, {r.x + r.w / 2, r.y + r.h / 2}, .Window)
	e2e.wait_frames(s, FRAMES_AFTER)
	w := s.app.active
	cross, _ := browser.chrome_box_rect(w, ui.key_from_string(w.own.strip.area_key, fmt.tprintf("###tab_%d", id)), "###close")
	return cross
}
