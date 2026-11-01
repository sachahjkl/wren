package jsdomtest

// One @(test) per page of examples/jsdom. `checks` is what the page declares it makes at least: fewer, or a page that never says
// it is done, fails (testhost.finish). Every file of the folder has its test here (every_page_has_a_test).

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:js"
import lay "wb:layout"
import "wb:page"
import "wb:tools/testenv"
import "wb:tools/testhost"

// A page's test: `after` is what the program checks of it then (the browser's side).
page_test :: proc(t: ^testing.T, name: string, checks: int, after: proc(p: ^page.Page, lh: ^Layout_Host) = nil, closed: proc() = nil, timeout_ms := PAGE_LIMIT_MS) {
	context.allocator = base.process_allocator()
	world_begin(t, name)
	defer world_end()
	src, rerr := os.read_entire_file(filepath.join({PAGES_DIR, name}, context.temp_allocator) or_else "", context.allocator)
	testing.expectf(t, rerr == nil, "cannot read %s", name)
	defer delete(src)
	lh := new(Layout_Host)
	lh.set = lay.settings_default()
	t0 := time.tick_now()
	p := open_page(string(src), lh, name, timeout_ms)
	uncaught_since(0, name)
	if after != nil { after(p, lh) }
	if js.memprof_wanted() { js.print_profile(p.js.inst, name) }
	page.page_close(p)
	if closed != nil { closed() }
	lay.destroy(&lh.l)
	free(lh)
	fmt.printf("%s: %d checks passed (%.0f ms)\n", name, sect.checks, time.duration_milliseconds(time.tick_since(t0)))
	testhost.finish(&sect, t, min_checks = checks)
}

DND_CHECKS :: 98
TOUCH_CHECKS :: 6

PAGES := [?]string{
	"animations.html", "bench.html", "compat.html", "css-animations.html", "cssom.html", "custom.html", "dnd.html", "domparser-xml.html",
	"elements.html", "events.html", "fullscreen.html", "html.html", "intersection.html", "layout.html", "leaks.html", "navigation.html",
	"observer.html", "popover.html", "resize.html", "scripts.html", "shadow.html", "style.html", "template_stamp.html", "traversal.html",
	"tree.html", "videoquality.html", "xhtml.xhtml", "xml.html", "xmlserializer.html",
}

// A page added to the folder gets a test: nothing is left out by accident.
@(test)
every_page_has_a_test :: proc(t: ^testing.T) {
	infos, err := os.read_all_directory_by_path(PAGES_DIR, context.allocator)
	testing.expect(t, err == nil, "cannot read " + PAGES_DIR)
	defer os.file_info_slice_delete(infos, context.allocator)
	for fi in infos {
		if !strings.has_suffix(fi.name, ".html") && !strings.has_suffix(fi.name, ".xhtml") { continue }
		found := false
		for p in PAGES { if p == fi.name { found = true } }
		testing.expectf(t, found, "%s has no test (pages.odin)", fi.name)
	}
}

@(test) animations :: proc(t: ^testing.T) { page_test(t, "animations.html", checks = 81) }
@(test) compat :: proc(t: ^testing.T) { page_test(t, "compat.html", checks = 39) }
@(test) css_animations :: proc(t: ^testing.T) { page_test(t, "css-animations.html", checks = 28) }
@(test) cssom :: proc(t: ^testing.T) { page_test(t, "cssom.html", checks = 63) }
@(test) custom :: proc(t: ^testing.T) { page_test(t, "custom.html", checks = 34) }
@(test) domparser_xml :: proc(t: ^testing.T) { page_test(t, "domparser-xml.html", checks = 30) }
@(test) elements :: proc(t: ^testing.T) { page_test(t, "elements.html", checks = 179) }
@(test) html :: proc(t: ^testing.T) { page_test(t, "html.html", checks = 145) }
@(test) intersection :: proc(t: ^testing.T) { page_test(t, "intersection.html", checks = 35) }
@(test) navigation :: proc(t: ^testing.T) { page_test(t, "navigation.html", checks = 85) }
@(test) observer :: proc(t: ^testing.T) { page_test(t, "observer.html", checks = 25) }
@(test) resize :: proc(t: ^testing.T) { page_test(t, "resize.html", checks = 32) }
@(test) scripts :: proc(t: ^testing.T) { page_test(t, "scripts.html", checks = 15) }
@(test) shadow :: proc(t: ^testing.T) { page_test(t, "shadow.html", checks = 130) }
@(test) styles :: proc(t: ^testing.T) { page_test(t, "style.html", checks = 62) }
@(test) template_stamp :: proc(t: ^testing.T) { page_test(t, "template_stamp.html", checks = 30) }
@(test) traversal :: proc(t: ^testing.T) { page_test(t, "traversal.html", checks = 50) }
@(test) tree :: proc(t: ^testing.T) { page_test(t, "tree.html", checks = 161) }
@(test) videoquality :: proc(t: ^testing.T) { page_test(t, "videoquality.html", checks = 9) }
@(test) xhtml :: proc(t: ^testing.T) { page_test(t, "xhtml.xhtml", checks = 10) }
@(test) xml :: proc(t: ^testing.T) { page_test(t, "xml.html", checks = 38) }
@(test) xmlserializer :: proc(t: ^testing.T) { page_test(t, "xmlserializer.html", checks = 11) }

@(test)
leaks :: proc(t: ^testing.T) { page_test(t, "leaks.html", checks = 4, after = proc(p: ^page.Page, _: ^Layout_Host) { leak_checks(p) }) }

@(test)
layout_page :: proc(t: ^testing.T) { page_test(t, "layout.html", checks = 43, after = proc(p: ^page.Page, lh: ^Layout_Host) { layout_cost_checks(p); resize_checks(p, lh) }) }

@(test)
events :: proc(t: ^testing.T) { page_test(t, "events.html", checks = 33, after = proc(p: ^page.Page, _: ^Layout_Host) { browser_event_checks(p) }) }

@(test)
fullscreen :: proc(t: ^testing.T) {
	fullscreen_test_setup()   // fullscreen.odin: a window that records what it is asked
	page_test(t, "fullscreen.html", checks = 83, after = proc(p: ^page.Page, _: ^Layout_Host) { fullscreen_checks(p) }, closed = fullscreen_closed_checks)
}

@(test)
popover :: proc(t: ^testing.T) { page_test(t, "popover.html", checks = 42, after = proc(p: ^page.Page, _: ^Layout_Host) { popover_checks(p) }) }

// dnd.html builds Touch and TouchEvent: a page told about a touch screen (browser.touch.expose = on).
@(test)
dnd :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	world_begin(t, "dnd.html")
	defer world_end()
	settings.js.touch_handlers, settings.js.touch_points = true, TOUCH_POINTS
	src, rerr := os.read_entire_file(filepath.join({PAGES_DIR, "dnd.html"}, context.temp_allocator) or_else "", context.allocator)
	testing.expect(t, rerr == nil, "cannot read dnd.html")
	defer delete(src)
	lh := new(Layout_Host)
	lh.set = lay.settings_default()
	p := open_page(string(src), lh, "dnd.html")
	uncaught_since(0, "dnd.html")
	dnd_checks(p)   // dnd.odin
	page.page_close(p)
	lay.destroy(&lh.l)
	free(lh)
	fmt.printf("dnd.html: %d checks passed\n", sect.checks)
	testhost.finish(&sect, t, min_checks = DND_CHECKS)
}

// (the micro-benchmarks only measure: a performance run, tools\test_all.ps1 -Perf)
@(test)
bench :: proc(t: ^testing.T) {
	if base.perf_skip("jsdomtest: the micro-benchmarks of the DOM bindings (examples/jsdom/bench.html)") { return }
	page_test(t, "bench.html", checks = 0, timeout_ms = BENCH_LIMIT_MS)
}

@(test)
touch_expose :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	world_begin(t, "browser.touch.expose")
	defer world_end()
	touch_checks()
	sect.finished = true
	testhost.finish(&sect, t, min_checks = TOUCH_CHECKS)
}

// A last test, by the order of names: what the process keeps goes, and with -define:WREN_TRACK_MEMORY=true whatever the pages left
// behind shows. It is left out when -tests: does not name it.
@(test)
zz_the_process_ends_with_nothing_left :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	process_end()
	testing.expect_value(t, testenv.mem_check("jsdomtest"), 0)
	all := testhost.totals
	fmt.printf("\n%d pages\n%d passed, %d failure(s), %d skipped\n", all.sections, all.passes, all.failures, all.skips)
}
