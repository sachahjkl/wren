package layout

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:dom"
import "wb:html"
import "wb:style"

// Timing of each pass on the page tools\perf.ps1 generates (build\perf\p10k.html). Opt-in:
//   set WREN_LAYOUT_BENCH=1 & odin test src/layout -collection:wb=src -o:speed -define:ODIN_TEST_NAMES=layout.bench_passes
// (WREN_LAYOUT_BENCH_PAGE=p50k for the larger page.) Full passes, then incremental ones: width steps of a resize,
// height only, a text changed in one paragraph, a style restyle comparison.
@(test)
bench_passes :: proc(t: ^testing.T) {
	if os.get_env("WREN_LAYOUT_BENCH", context.temp_allocator) == "" { return }
	name := os.get_env("WREN_LAYOUT_BENCH_PAGE", context.temp_allocator)
	if name == "" { name = "p10k" }
	data, err := os.read_entire_file(fmt.tprintf("build/perf/%s.html", name), context.allocator)
	if err != nil { return }
	defer delete(data)
	doc := dom.document_create(nil)
	defer dom.document_destroy(doc)
	html.parse_into(doc, doc.root, data, 2_000_000)
	ss := style.settings_default()
	eng := style.engine_make(ss)
	style.settings_destroy(&ss)
	defer style.engine_destroy(eng)
	style.engine_set_journal(eng, 1 << 16)
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
	vp := Vec2{1500, 900}
	input :: proc(doc: ^dom.Document, st: ^style.Styled, set: ^Settings, api: Text_Api, vp: Vec2) -> Input {
		return Input{doc = doc, styled = st, settings = set, text = api, viewport = vp, scale = 1.5, band_h = 256}
	}
	report :: proc(what: string, l: ^Layout, t0: time.Tick) {
		fmt.printfln("%-22s %v total %6.2f ms  [tree %.2f layout %.2f finish %.2f display %.2f bands %.2f]  laid %d rebuilt %d spliced %v %s",
			what, l.last_pass, time.duration_milliseconds(time.tick_since(t0)), l.stats[0], l.stats[1], l.stats[2], l.stats[3], l.stats[4],
			l.inc.last_laid, l.inc.last_rebuilt, l.inc.last_spliced, l.inc.fallback)
	}
	for round in 0 ..< 3 {
		l.valid = false
		t0 := time.tick_now()
		run(&l, input(doc, st, &set, api, vp))
		report(fmt.tprintf("full %d", round), &l, t0)
	}
	fmt.printfln("%d boxes, %d items", len(l.boxes), len(l.items))
	for k in 0 ..< 6 {
		vp.x = 1500 - f32(k + 1) * 37
		t0 := time.tick_now()
		run(&l, input(doc, st, &set, api, vp))
		report("resize width", &l, t0)
	}
	for k in 0 ..< 3 {
		vp.y = 900 - f32(k + 1) * 23
		t0 := time.tick_now()
		run(&l, input(doc, st, &set, api, vp))
		report("resize height", &l, t0)
	}
	// a text in the middle of the page, every frame
	spans := make([dynamic]base.Handle, context.temp_allocator)
	{
		stack := make([dynamic]base.Handle, context.temp_allocator)
		append(&stack, doc.root)
		for len(stack) > 0 {
			h := pop(&stack)
			n := dom.get(doc, h)
			if n.kind == .Element && n.name == "span" { append(&spans, h) }
			for ch := n.first_child; ch != base.NIL_HANDLE; ch = dom.get(doc, ch).next { append(&stack, ch) }
		}
	}
	target := spans[len(spans) / 2]
	for k in 0 ..< 6 {
		dom.set_text_content(doc, target, fmt.tprintf("frame %d lorem ipsum", k))
		t0 := time.tick_now()
		old := st
		st = style.compute_styles(eng, doc, {})
		t1 := time.tick_now()
		style.journal_diff(old, st)
		t2 := time.tick_now()
		style.styled_destroy(old)
		t3 := time.tick_now()
		run(&l, input(doc, st, &set, api, vp))
		fmt.printfln("  restyle %.2f ms, journal diff %.2f ms", time.duration_milliseconds(time.tick_diff(t0, t1)), time.duration_milliseconds(time.tick_diff(t1, t2)))
		report("text mutation", &l, t3)
	}
	fmt.printfln("size_of(Box) = %d, Inline_Item = %d, Frag = %d, Display_Item = %d", size_of(Box), size_of(Inline_Item), size_of(Frag), size_of(Display_Item))
	free_all(context.temp_allocator)
}
