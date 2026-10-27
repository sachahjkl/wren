package browser

import "core:testing"
import "toolkit:font"
import "toolkit:render"
import "toolkit:ui"

// The frame statistics panel keeps its size and its place whatever it shows: the same lines for every section, and the
// same box for an idle browser and a busy one (it used to grow and shrink as steps ran or stopped, and jump above the
// status bar it hangs from).

@(private = "file")
idle_source :: proc() -> Panel_Source { return {} }

@(private = "file")
busy_source :: proc() -> (s: Panel_Source) {
	s.n = {frames = 62, fps = 61.7, cpu_mean = 2.5, cpu_p95 = 7.25, cpu_p99 = 31.5, cpu_max = 120.75, gpu_mean = 0.5, gpu_p95 = 1.25,
		gpu_p99 = 3.5, gpu_max = 9.5, gpu_n = 62, over = 3, gpu_over = 1, budget = 16.67, shown = 60, missed = 2, lat_mean = 12.5,
		lat_p95 = 30, lat_n = 9, wasm_mean = 0.25, full_restyles = 4, partial_restyles = 1234, working_set = 512 << 20,
		private_bytes = 300 << 20, mem_valid = true}
	for k in Hud_Series { s.n.series[k] = 1.5 }
	s.n.passes = {.None = 0, .Full = 3, .Incremental = 120, .Refresh = 7}
	s.budget = 16.67
	s.pacer.hz, s.pacer.live_hz, s.pacer.interval, s.pacer.variable = 144, 144, 1, true
	s.gpu_timing, s.gpu_have = true, true
	for k in render.Gpu_Step { s.gpu_last.steps[k].count, s.gpu_last.steps[k].ms = 12345, 0.75 }
	s.gpu_last.target_changes = 9
	s.measured_hz, s.shown_total, s.missed_total = 143.9, 100_000, 25
	s.restyle, s.has_restyle = {restyle = .Full, restyled = 900}, true
	s.layout, s.has_layout = {lay_pass = .Full, lay_steps = {1, 2, 3, 4, 5}, lay_boxes = 120_000, lay_items = 450_000, lay_pre = {12, 10}}, true
	s.comp, s.has_comp = {comp_valid = true}, true
	s.comp.comp.chunks, s.comp.comp.visible = 40, 12
	s.wasm_modules, s.wasm_timing, s.wasm_compiler = 3, true, "cranelift"
	s.images = {entries = 77, bytes = 64 << 20, limit = 256 << 20}
	return
}

@(test)
frame_stats_sections_keep_their_lines :: proc(t: ^testing.T) {
	idle, busy := idle_source(), busy_source()
	half := busy_source()
	half.has_layout, half.layout.lay_pass, half.gpu_have, half.n.mem_valid, half.pacer.live_hz = true, .Incremental, false, false, 0
	half.layout.lay_steps = {0, 2, 0, 0, 0}
	for s in Panel_Section {
		a := panel_lines(&idle, s)
		for other in ([]^Panel_Source{&busy, &half}) {
			b := panel_lines(other, s)
			if !testing.expectf(t, len(a) == len(b), "%v: %d lines idle, %d busy", s, len(a), len(b)) { continue }
			for l, i in a {
				testing.expectf(t, l.id == b[i].id && l.heading == b[i].heading, "%v line %d: %s / %s", s, i, l.id, b[i].id)
			}
		}
	}
	// nothing measured reads the same mark
	for l in panel_lines(&idle, .Gpu_Steps) { if !l.heading && l.id != "gs_none" && l.id != "gs_kept" && l.id != "gs_hits" { testing.expect_value(t, l.value, STAT_NONE) } }
}

// Built headless: the panel's body has one size for every data set, in one, two and three columns.
@(test)
frame_stats_body_keeps_its_size :: proc(t: ^testing.T) {
	page_render_test_lock()
	defer page_render_test_unlock()
	fonts: font.State
	font.init(&fonts)
	defer font.destroy(&fonts)
	ui_font, ok := font.load_embedded(&fonts, font.FALLBACK_UI_DATA)
	if !testing.expect(t, ok) { return }
	theme: ui.Theme
	ui.apply_palette(&theme, ui.PALETTE_GRAPHITE)
	defer ui.theme_destroy(&theme)
	s := new(ui.State)
	defer free(s)
	ui.init(s, &fonts, &theme)
	defer ui.destroy(s)

	size_of_body :: proc(s: ^ui.State, ui_font: font.Font_Id, src: ^Panel_Source, ncols: int) -> [2]f32 {
		size: [2]f32
		for _ in 0 ..< 2 {
			ui.begin_build(s, {
				window_size = {1600, 1200}, dt = 1.0 / 60, animations = false, dpi_scale = 1,
				base = ui.Style{pref = {.X = ui.text_size(), .Y = ui.px(30)}, font = ui_font, font_size = 13, text_pad = 6},
			})
			box := frame_stats_columns(src, frame_stats_layout(ncols), 13 * 17, 13 * 0.6)
			ui.end_build()
			size = box.size
			free_all(context.temp_allocator)
		}
		return size
	}
	for ncols in 1 ..= 3 {
		idle, busy := idle_source(), busy_source()
		a := size_of_body(s, ui_font, &idle, ncols)
		b := size_of_body(s, ui_font, &busy, ncols)
		testing.expectf(t, a == b && a.y > 0, "%d columns: idle %v, busy %v", ncols, a, b)
	}
}
