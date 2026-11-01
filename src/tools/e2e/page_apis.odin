package e2e_scenarios

// What needs the shell's frames, timers and paint: a layout read by a script in a page just navigated to, timers that change nothing, Web Animations,
// popovers, the Navigation API, an XHTML page.

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:e2e"

// How far a colour of these pages may be from what is asked of it (they have text and borders near).
@(private = "file") TOLERANCE :: 24
@(private = "file") BLUE := e2e.Color{0, 0, 255, 255}
@(private = "file") WHITE := e2e.Color{255, 255, 255, 255}
@(private = "file") POPOVER_OPEN := e2e.Color{255, 236, 153, 255}
@(private = "file") GREEN := e2e.Color{0, 128, 0, 255}
// Windows of these pages.
@(private = "file") LAYOUT_WINDOW := [2]int{800, 500}
@(private = "file") DEMO_WINDOW := [2]int{900, 700}
// In a capture of a box of one colour: a place inside it; of the probe's track (200 px wide, half of it painted): one on each side of the half; of the menu: one in its background.
@(private = "file") INSIDE_A_BOX := [2]int{10, 10}
@(private = "file") TRACK_PAINTED := [2]int{50, 10}
@(private = "file") TRACK_EMPTY := [2]int{150, 10}
@(private = "file") MENU_BACKGROUND := [2]int{6, 30}
// A flat colour of a page with nothing near it.
@(private = "file") FLAT_TOLERANCE :: 8

// The shell's "page whose natural sizes layout reads" was set by the frame's own layout only: a layout forced by a script (the first thing a page does) before
// any frame of the new page read the previous frame's page: another document (an image of the page before at the same place of the tree gave its size: 77 x 33) or
// one already freed (an access violation in shell_intrinsic, on youtube.com's watch page). The page after a page with an image of 77 x 33 reads its own image's width at once.
@(test)
a_layout_read_by_a_script_uses_this_pages_images :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = LAYOUT_WINDOW, dpi = e2e.DPI_ONE, url = e2e.url(server, "/site/remote/layout-sized.htm")})
	e2e.navigate(s, e2e.url(server, "/site/remote/layout-first.htm"))
	first := e2e.eval(s, "window.first")
	testing.expectf(t, first != "" && first[0] >= '0' && first[0] <= '9' && !strings.has_prefix(first, "77:"), "the image's width is this page's, not the page before's 77: %q", first)
}

// A script ticks every 20 ms and touches nothing, which draws no frame (frames_at_rest.odin); a timer that turns the box blue then reaches the screen.
@(test)
a_timer_that_changes_the_page_reaches_the_screen :: proc(t: ^testing.T) {
	s := e2e.start(t, {dpi = e2e.DPI_ONE, url = e2e.url(e2e.test_server(t), "/site/remote/idle-timer.htm")})
	e2e.wait_idle(s)
	e2e.wait_stable(s)
	e2e.eval(s, "window.paint(); 1")
	e2e.wait_js(s, `getComputedStyle(document.getElementById("box")).backgroundColor === "rgb(0, 0, 255)"`)
	e2e.wait_stable(s)
	px := e2e.pixel(e2e.capture(s, {target = .Selector, selector = "#box"}), INSIDE_A_BOX.x, INSIDE_A_BOX.y)
	testing.expectf(t, near(px, BLUE, FLAT_TOLERANCE), "a timer that changes the page is drawn: %v", px)
}

// examples/site/web-animations.html: element.animate() drawn by the shell (a paused effect seen in a capture: the probe bar is half its 200 px), a short animation whose `finished`
// resolves on the real event loop, and the demo's own animations listed.
@(test)
web_animations_are_painted_and_finish_on_the_loop :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = DEMO_WINDOW, dpi = e2e.DPI_ONE, url = e2e.url(e2e.test_server(t), "/site/web-animations.html")})
	e2e.wait_idle(s)
	testing.expect_value(t, e2e.eval(s, "window.demo.count()"), "4")
	e2e.eval(s, `window.probe = document.getElementById("probe").animate({ width: ["0px", "200px"] }, 1000); window.probe.pause(); window.probe.currentTime = 500; 1`)
	e2e.wait_stable(s)
	track := e2e.capture(s, {target = .Selector, selector = "#probe-track"})
	left, right := e2e.pixel(track, TRACK_PAINTED.x, TRACK_PAINTED.y), e2e.pixel(track, TRACK_EMPTY.x, TRACK_EMPTY.y)
	testing.expectf(t, near(left, BLUE, TOLERANCE) && near(right, WHITE, TOLERANCE), "a paused effect is painted, blue up to half the bar: %v then %v", left, right)
	e2e.eval(s, `window.short = "running"; document.getElementById("probe").animate({ opacity: [1, 0] }, 120).finished.then((a) => { window.short = a.playState; }); 1`)
	e2e.wait_js(s, `window.short === "finished"`)
}

// examples/site/popover.html: a real click on the invoker shows the menu (painted, its :popover-open background, above the card), a click outside light-dismisses it, Esc closes the
// nested one first. examples/site/remote/popover-clip.htm: a popover inside a 10 px box that clips and makes a stacking context, under a fixed red cover of z-index 1000: in the top
// layer it is painted whole, at the centre of the viewport, above the cover.
@(test)
popovers_are_in_the_top_layer :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	s := e2e.start(t, {size = DEMO_WINDOW, dpi = e2e.DPI_ONE, url = e2e.url(server, "/site/popover.html")})
	e2e.wait_idle(s)
	e2e.click(s, "#open-menu")
	e2e.wait_js(s, `document.getElementById("menu").matches(":popover-open")`)
	e2e.wait_stable(s)
	px := e2e.pixel(e2e.capture(s, {target = .Selector, selector = "#menu"}), MENU_BACKGROUND.x, MENU_BACKGROUND.y)
	testing.expectf(t, near(px, POPOVER_OPEN, TOLERANCE), "it is painted with its :popover-open style: %v", px)
	e2e.click(s, "#more")
	e2e.wait_js(s, `document.getElementById("submenu").matches(":popover-open")`)
	e2e.key(s, "Escape")
	e2e.wait_js(s, `!document.getElementById("submenu").matches(":popover-open")`)
	testing.expect_value(t, e2e.eval(s, `document.getElementById("menu").matches(":popover-open")`), "true")
	e2e.click(s, "h1")   // (the menu is centred in the viewport: the heading is outside it)
	e2e.wait_js(s, `!document.getElementById("menu").matches(":popover-open")`)

	e2e.navigate(s, e2e.url(server, "/site/remote/popover-clip.htm"))
	e2e.wait_idle(s)
	e2e.wait_stable(s)
	page := e2e.capture(s, {target = .Page})
	centre := e2e.pixel(page, page.width / 2, page.height / 2)
	testing.expectf(t, near(centre, GREEN, TOLERANCE), "above a z-index 1000 cover, not clipped by its 10 px ancestor: %v", centre)
}

// examples/site/navigation.html: a real click on a link is intercepted by the page's navigate listener (the document stays: its marker too), a navigation to another page carries its
// state there, the browser's Back brings the demo back from the back/forward cache with the right current entry, and a second Back is a same-document traversal the page intercepts
// (userInitiated). Then another document reached by a push: navigation.activation; the browser's reload button fires navigate, which the page intercepts (the document stays).
@(test)
the_navigation_api_with_the_browsers_own_buttons :: proc(t: ^testing.T) {
	s := e2e.start(t, {url = e2e.url(e2e.test_server(t), "/site/navigation.html")})
	e2e.wait_idle(s)
	marker := e2e.eval(s, "String(window.marker)")
	same_marker := fmt.tprintf(`String(window.marker) === "%s"`, marker)
	base := int(e2e.eval_f64(s, "navigation.currentEntry.index"))

	e2e.click(s, "#link-about")
	e2e.wait_js(s, `location.search === "?view=about" && window.navCount === 1`)
	testing.expect_value(t, e2e.eval(s, "[location.search, navigation.currentEntry.index, navigation.canGoForward, window.lastNav].join()"), fmt.tprintf("?view=about,%d,false,push:true", base + 1))
	testing.expect_value(t, e2e.eval(s, same_marker), "true")

	e2e.eval(s, `navigation.navigate("remote/fixture.htm", { state: { from: "demo" } }); 1`)
	e2e.wait_js(s, `location.pathname.endsWith("/fixture.htm") && document.readyState === "complete"`)
	testing.expect_value(t, e2e.eval(s, "[navigation.currentEntry.getState() && navigation.currentEntry.getState().from, navigation.currentEntry.index, navigation.entries()[navigation.currentEntry.index - 1].sameDocument].join()"), fmt.tprintf("demo,%d,false", base + 2))

	e2e.run_command(s, "nav.back")
	e2e.wait_js(s, `location.search === "?view=about" && document.readyState === "complete"`)
	testing.expect_value(t, e2e.eval(s, fmt.tprintf(`[%s, navigation.currentEntry.index, navigation.canGoForward, navigation.entries()[navigation.currentEntry.index + 1].getState().from].join()`, same_marker)), fmt.tprintf("true,%d,true,demo", base + 1))

	e2e.run_command(s, "nav.back")
	e2e.wait_js(s, `location.search === "" && window.lastNav === "traverse:true"`)
	testing.expect_value(t, e2e.eval(s, fmt.tprintf(`[window.lastNav, navigation.currentEntry.index, %s].join()`, same_marker)), fmt.tprintf("traverse:true,%d,true", base))

	e2e.eval(s, `navigation.navigate("remote/fixture.htm?act"); 1`)
	e2e.wait_js(s, `location.search === "?act" && document.readyState === "complete"`)
	testing.expect_value(t, e2e.eval(s, `[navigation.activation.navigationType, navigation.activation.entry === navigation.currentEntry, navigation.activation.from && navigation.activation.from.url.includes("navigation.html")].join()`), "push,true,true")
	e2e.eval(s, `window.keep = "kept"; navigation.addEventListener("navigate", (e) => { if (e.navigationType === "reload") { window.sawReload = e.userInitiated; e.intercept(); } }); 1`)
	e2e.run_command(s, "nav.reload")
	e2e.wait_js(s, "window.sawReload === true")
	testing.expect_value(t, e2e.eval(s, "[window.sawReload, window.keep].join()"), "true,kept")
}

// examples/site/remote/xhtml.xhtml, served as application/xhtml+xml: parsed as XML (a self-closed <div/> is empty, names keep their case), its CDATA script runs, its style applies (the box painted blue).
@(test)
an_xhtml_page_is_parsed_as_xml :: proc(t: ^testing.T) {
	s := e2e.start(t, {dpi = e2e.DPI_ONE, url = e2e.url(e2e.test_server(t), "/site/remote/xhtml.xhtml")})
	testing.expect_value(t, e2e.eval(s, "String(window.xhtml)"), "application/xhtml+xml,p,id dataName,0,myElement")
	e2e.wait_stable(s)
	px := e2e.pixel(e2e.capture(s, {target = .Selector, selector = "#box"}), INSIDE_A_BOX.x, INSIDE_A_BOX.y)
	testing.expectf(t, near(px, BLUE, TOLERANCE), "its style applies: %v", px)
}
