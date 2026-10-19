package browser

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import "toolkit:font"
import "wb:dom"
import "wb:html"
import lay "wb:layout"
import "wb:style"

// Layout of a large page with the real text stack, timed: full passes (word cache warm after the first) and the first
// pass (cold cache). Runs only with -define:BENCH_TEXT=true, on build/perf/p50k.html (tools/perf.ps1 makes it).
//   odin test src/browser -collection:wb=src -collection:toolkit=ext/gui_toolkit -o:speed -define:BENCH_TEXT=true -define:ODIN_TEST_NAMES=browser.bench_text_layout

@(private = "file") BENCH_TEXT :: #config(BENCH_TEXT, false)
@(private = "file") BENCH_FAKE_WIDTH :: #config(BENCH_FAKE_WIDTH, false)
@(private = "file") BENCH_FAKE_ALL :: #config(BENCH_FAKE_ALL, false)

@(test)
bench_text_layout :: proc(t: ^testing.T) {
	when !BENCH_TEXT { return }
	data, err := os.read_entire_file("build/perf/p50k.html", context.allocator)
	if err != nil { return }
	defer delete(data)
	fs := new(font.State)
	defer free(fs)
	font.init(fs)
	defer font.destroy(fs)
	ui, _ := font.load_system(fs, "Segoe UI")
	pf: Page_Fonts   // not page_render's: tests run in parallel
	page_fonts_init(&pf, fs, ui)
	defer page_fonts_destroy(&pf)
	lset := lay.settings_default()
	doc := dom.document_create(nil)
	defer dom.document_destroy(doc)
	html.parse_into(doc, doc.root, data, 50_000_000)
	ss := style.settings_default()
	defer style.settings_destroy(&ss)
	eng := style.engine_make(ss)
	defer style.engine_destroy(eng)
	style.sync_document_sheets(eng, doc, "about:test")
	st := style.compute_styles(eng, doc, {})
	defer style.styled_destroy(st)
	m: Measure
	ROUNDS :: 10
	times: [ROUNDS]f64
	for r in 0 ..< ROUNDS {
		l: Layout
		api := page_text_api(&pf, &m, &ss)
		when BENCH_FAKE_ALL { api = lay.Text_Api{font = proc(user: rawptr, families: []string, weight: u16, italic: bool) -> lay.Font { return 1 }, metrics = proc(user: rawptr, f: lay.Font, size: f32) -> lay.Font_Metrics { return {0.8 * size, 0.2 * size, 0.5 * size} }, width = proc(user: rawptr, f: lay.Font, size: f32, text: string) -> f32 { return 0.5 * size * f32(len(text)) }} }
		when BENCH_FAKE_WIDTH { api.width = proc(user: rawptr, f: lay.Font, size: f32, text: string) -> f32 { return 0.5 * size * f32(len(text)) } }
		t0 := time.tick_now()
		lay.run(&l, lay.Input{doc = doc, styled = st, settings = &lset,
			text = api, viewport = {1500, 900}, scale = 1.5, band_h = 256})
		times[r] = time.duration_milliseconds(time.tick_since(t0))
		lay.destroy(&l)
		free_all(context.temp_allocator)
	}
	best := times[1]
	for x in times[1:] { best = min(best, x) }
	fmt.printfln("text layout p50k: first %.2f ms, best warm %.2f ms", times[0], best)
	testing.expect(t, best > 0)
}
