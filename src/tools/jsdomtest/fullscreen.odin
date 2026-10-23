package jsdomtest

// examples/jsdom/fullscreen.html: the Fullscreen API. The page checks what needs no gesture; the tool plays the shell
// (a window that records what it is asked, and the user's clicks), runs the page's phases, and checks the browser's
// side: the window is asked to fill the screen and to go back, nested documents, a refusing window, a document that
// closes in full screen.

import "core:fmt"
import "core:strings"
import "core:time"
import "wb:dom"
import "wb:host"
import "wb:page"

@(private = "file")
Window_Record :: struct {
	is_on:   bool,
	asked:   int,       // requests to fill the screen
	left:    int,       // requests to go back
	refuse:  bool,
	nav:     page.Api_FullscreenNavigation,   // of the first request
	top:     ^page.Page,
}

@(private = "file")
rec: Window_Record

fullscreen_test_setup :: proc() {
	page.fullscreen_embedder = {set = proc(top: ^page.Page, on: bool, nav: page.Api_FullscreenNavigation) -> bool {
		if on {
			if rec.refuse { return false }
			if rec.asked == 0 { rec.nav = nav }
			rec.asked += 1
			rec.top = top
		} else {
			rec.left += 1
		}
		rec.is_on = on
		return true
	}}
}

@(private = "file")
wait_for_log :: proc(from: int, what: string, ms: f64 = 20000) -> bool {
	start := time.tick_now()
	for time.duration_milliseconds(time.tick_since(start)) < ms {
		for l in logs[from:] { if l == what { return true } }
		host.loop_wait(&loop, 2)
	}
	return false
}

// Runs `phase` of the page (an async function) and counts the verdicts it logs.
@(private = "file")
run_phase :: proc(p: ^page.Page, phase: string) {
	from := len(logs)
	code := strings.concatenate({`(async () => { await window.`, phase, `(); console.log("PHASE_DONE"); })().catch((e) => console.log("FAIL `, phase,
		` threw " + (e && e.name) + ": " + (e && e.message) + " " + (e && e.stack)))`}, context.temp_allocator)
	page.js_run(p, transmute([]byte)code, "probe.js")
	finished := wait_for_log(from, "PHASE_DONE")
	pass, fail := 0, 0
	for l in logs[from:] {
		if strings.has_prefix(l, "PASS ") { pass += 1 }
		if strings.has_prefix(l, "FAIL ") || strings.has_prefix(l, "Uncaught") { fail += 1; fmt.printf("FAIL %s: %s\n", phase, l) }
	}
	passes += pass
	failures += fail
	if !finished { fmt.printf("FAIL %s did not finish\n", phase); failures += 1 }
	fmt.printf("  %s: %d checks passed, %d failed\n", phase, pass, fail)
}

// A click of the user in a document: it gets transient activation.
@(private = "file")
click :: proc(p: ^page.Page) {
	page.dispatch_event(p, p.body, dom.Event{type = "mousedown", bubbles = true, cancelable = true})
	page.dispatch_event(p, p.body, dom.Event{type = "mouseup", bubbles = true, cancelable = true})
	page.dispatch_event(p, p.body, dom.Event{type = "click", bubbles = true, cancelable = true})
}

fullscreen_checks :: proc(p: ^page.Page) {
	check(rec.asked == 0 && !page.fullscreen_active(p), "nothing asked the window while the page had no gesture")

	click(p)
	run_phase(p, "phase2")
	check(rec.asked >= 5 && rec.left >= 4 && !rec.is_on, "the window was asked to fill the screen and to go back, and ends as it was")
	check(rec.nav == .Hide, "navigationUI: \"hide\" reaches the window")
	check(!page.fullscreen_active(p), "no fullscreen element is left in the document")

	// two frames
	check(wait_for_log(0, "READY2"), "both frames loaded")
	kids := page.frames_children(p)
	check(len(kids) == 2 && kids[0].page != nil && kids[1].page != nil, "two nested documents")
	if len(kids) == 2 && kids[0].page != nil && kids[1].page != nil {
		fa, fb := kids[0].page, kids[1].page
		click(fa)
		click(fb)
		run_phase(p, "phase3")
		check(page.fullscreen_active(p) && page.fullscreen_active(fa) && !page.fullscreen_active(fb), "the frame's document and its container are fullscreen, the refused frame is not")
		check(rec.is_on && rec.top == p, "the window was asked for the tab's document")
		check(page.fullscreen_exit(p), "the shell leaves full screen (Escape)")
		check(!page.fullscreen_active(p) && !page.fullscreen_active(fa) && !rec.is_on, "... for the whole tree, the window comes back")
		check(!page.fullscreen_exit(p), "... and again: nothing to leave")

		// the frame goes while it is fullscreen
		click(fa)
		check(page.fullscreen_active(fa), "the frame is fullscreen again")
		page.js_run(p, transmute([]byte)string(`document.getElementById("fa").remove()`), "probe.js")
		check(!page.fullscreen_active(p) && !rec.is_on, "removing the frame's container ends full screen and gives the window back")
	}

	// a window that refuses
	rec.refuse = true
	click(p)
	run_phase(p, "phase4")
	rec.refuse = false
	check(!page.fullscreen_active(p) && !rec.is_on, "a refusal leaves nothing behind")

	// the document closes in full screen (main closes it): the window is given back
	click(p)
	from := len(logs)
	page.js_run(p, transmute([]byte)string(`document.getElementById("b").requestFullscreen().then(() => console.log("FS_ON"))`), "probe.js")
	check(wait_for_log(from, "FS_ON") && rec.is_on, "full screen again before the page closes")
}

// After main closed the page.
fullscreen_closed_checks :: proc() {
	check(!rec.is_on, "closing a document in full screen gives the window back")
}
