package layout

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import "wb:dom"
import "wb:html"
import "wb:style"

// Timing of each pass on the page tools\perf.ps1 generates (build\perf\p10k.html). Opt-in:
//   set WREN_LAYOUT_BENCH=1 & odin test src/layout -collection:wb=src -o:speed -define:ODIN_TEST_NAMES=layout.bench_passes
@(test)
bench_passes :: proc(t: ^testing.T) {
	if os.get_env("WREN_LAYOUT_BENCH", context.temp_allocator) == "" { return }
	data, err := os.read_entire_file("build/perf/p10k.html", context.allocator)
	if err != nil { return }
	defer delete(data)
	doc := dom.document_create(nil)
	defer dom.document_destroy(doc)
	html.parse_into(doc, doc.root, data, 2_000_000)
	ss := style.settings_default()
	eng := style.engine_make(ss)
	style.settings_destroy(&ss)
	defer style.engine_destroy(eng)
	style.sync_document_sheets(eng, doc, "about:test")
	st := style.compute_styles(eng, doc, {})
	defer style.styled_destroy(st)
	set := settings_default()
	l: Layout
	defer destroy(&l)
	api := Text_Api{
		font = proc(user: rawptr, families: []string, weight: u16, italic: bool) -> Font { return 1 },
		width = proc(user: rawptr, f: Font, size: f32, text: string) -> f32 { return 0.5 * size * f32(len(text)) },
		metrics = proc(user: rawptr, f: Font, size: f32) -> Font_Metrics { return {0.8 * size, 0.2 * size, 0.5 * size} },
	}
	for round in 0 ..< 4 {
		in_ := Input{doc = doc, styled = st, settings = &set, text = api, viewport = {1500, 900}, scale = 1.5, band_h = 256}
		t0 := time.tick_now()
		run(&l, in_)
		fmt.printfln("round %d: total %.2f ms, %d boxes, %d items, passes %v", round, time.duration_milliseconds(time.tick_since(t0)), len(l.boxes), len(l.items), l.stats)
	}
	fmt.printfln("size_of(Box) = %d, Inline_Item = %d, Frag = %d, Display_Item = %d", size_of(Box), size_of(Inline_Item), size_of(Frag), size_of(Display_Item))
	free_all(context.temp_allocator)
}
