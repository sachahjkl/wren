package browser

import "core:fmt"
import "core:testing"
import "core:time"
import "toolkit:ui"
import "wb:config"

// The palette's search, timed: the registry, every preference (the largest source of rows) and a source of 5000 pages.
// Runs only with -define:BENCH_PALETTE=true:
//   odin test src/browser -collection:wb=src -collection:toolkit=ext/gui_toolkit -o:speed -define:BENCH_PALETTE=true -define:ODIN_TEST_NAMES=browser.bench_palette

@(private = "file") BENCH_PALETTE :: #config(BENCH_PALETTE, false)

// (made once: what is timed is the palette, not the source)
@(private = "file")
bench_pages :: proc(user: rawptr, app: ^App, out: ^[dynamic]Palette_Item) {
	append(out, ..(^[dynamic]Palette_Item)(user)[:])
}

@(test)
bench_palette :: proc(t: ^testing.T) {
	page_render_test_lock()
	defer page_render_test_unlock()
	when !BENCH_PALETTE { return }
	app := new(App)
	defer free(app)
	app.prefs = config.prefs_make()
	defer config.prefs_destroy(&app.prefs)
	register_all_prefs(&app.prefs)
	defer palette_destroy()
	palette_collect(app, "")
	pages := make([dynamic]Palette_Item)
	defer { for p in pages { delete(p.title); delete(p.detail) }; delete(pages) }
	for i in 0 ..< 5000 {
		u := fmt.aprintf("https://site%d.example.org/articles/%d/the-title-of-page-%d", i % 97, i, i)
		append(&pages, Palette_Item{title = fmt.aprintf("The title of page %d on site %d", i, i % 97), detail = u, key = u})
	}
	palette_add_source({name = "Bench", prefix = '/', items = bench_pages, user = &pages})
	// the matcher alone, over the source's titles
	for q in ([]string{"page 42", "site title"}) {
		fq := fuzzy_query_make(q)
		s: Fuzzy_Scratch
		defer fuzzy_scratch_destroy(&s)
		out := make([dynamic]ui.Fuzzy_Range, context.temp_allocator)
		start := time.tick_now()
		hits := 0
		for _ in 0 ..< 20 { for p in pages { clear(&out); if _, ok := fuzzy_match(&fq, p.title, &s, &out); ok { hits += 1 } } }
		fmt.printf("fuzzy_match    %-14q %7.3f ms  %5d hits\n", q, time.duration_milliseconds(time.tick_since(start)) / 20, hits / 20)
	}
	for q in ([]string{"", ">", "rel", "zoom in", ">theme dayl", ":", ":palette", ":ui.theme", ":ft", "/", "/page 42", "/site title"}) {
		runs := 20
		start := time.tick_now()
		for _ in 0 ..< runs { palette_collect(app, q); free_all(context.temp_allocator) }
		ms := time.duration_milliseconds(time.tick_since(start)) / f64(runs)
		fmt.printf("palette_collect %-14q %7.3f ms  %5d rows\n", q, ms, len(cpal.rows))
	}
}
