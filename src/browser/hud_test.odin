package browser

import "core:testing"
import "toolkit:ui"
import "wb:config"

@(private = "file")
values_full :: proc() -> (v: [Title_Field]string) {
	v[.App], v[.Version], v[.Build], v[.Engine] = "Wren", "0.1.0", "release", "Wasmtime 49.0.3"
	v[.Fps], v[.Cpu], v[.Gpu], v[.Mem] = "60", "1.2", "0.8", "312"
	v[.Page], v[.Url] = "Example", "https://example.com/"
	return
}

DEFAULT_FORMAT :: "{app} {version} · {build} · {engine} · {fps} fps · CPU {cpu} ms · GPU {gpu} ms — {page}"

@(test)
title_compose_fields_and_parts :: proc(t: ^testing.T) {
	v := values_full()
	testing.expect_value(t, title_compose(DEFAULT_FORMAT, " · ", v), "Wren 0.1.0 · release · Wasmtime 49.0.3 · 60 fps · CPU 1.2 ms · GPU 0.8 ms — Example")
	// no GPU time: its part goes, with the separator before it (the page keeps its own)
	v[.Gpu] = ""
	testing.expect_value(t, title_compose(DEFAULT_FORMAT, " · ", v), "Wren 0.1.0 · release · Wasmtime 49.0.3 · 60 fps · CPU 1.2 ms — Example")
	// statistics off: only the identity and the page
	v[.Fps], v[.Cpu] = "", ""
	testing.expect_value(t, title_compose(DEFAULT_FORMAT, " · ", v), "Wren 0.1.0 · release · Wasmtime 49.0.3 — Example")
	// the first part missing: no leading separator
	testing.expect_value(t, title_compose("{fps} fps · {page}", " · ", v), "Example")
	// unknown fields stay as they are; literal text without fields stays
	testing.expect_value(t, title_compose("{page} | {nope} | v{version}", " · ", v), "Example | {nope} | v0.1.0")
	// another separator
	testing.expect_value(t, title_compose("{app} / {gpu} / {page}", " / ", v), "Wren / Example")
	// nothing at all
	empty: [Title_Field]string
	testing.expect_value(t, title_compose("{fps} · {cpu}", " · ", empty), "")
}

@(test)
title_statistics_and_throttle :: proc(t: ^testing.T) {
	testing.expect(t, title_has_stats(DEFAULT_FORMAT))
	testing.expect(t, title_has_stats("{mem} MB"))
	testing.expect(t, !title_has_stats("{app} — {page}"))
	// a new page: at once, whatever the interval
	testing.expect(t, title_due(false, true, 0, 500, false))
	testing.expect(t, title_due(false, false, 0, 500, false))
	// same page, statistics shown: at most every interval, and when they come to rest
	testing.expect(t, !title_due(true, true, 120, 500, false))
	testing.expect(t, title_due(true, true, 500, 500, false))
	testing.expect(t, title_due(true, true, 10, 500, true))
	// same page, no statistics: never again
	testing.expect(t, !title_due(true, false, 100_000, 500, true))
}

@(test)
build_descriptions :: proc(t: ^testing.T) {
	testing.expect_value(t, describe_build(.Release, false), "release")
	testing.expect_value(t, describe_build(.Debug, false), "debug")
	testing.expect_value(t, describe_build(.Profile, true), "profile +gpu-timing")
	testing.expect_value(t, build_kind_name(BUILD_KIND), PROFILE ? "profile" : (ODIN_DEBUG ? "debug" : "release"))
	testing.expect(t, app_commit() != "" && app_commit()[0] != 'g' || app_commit() == "dev")
}

@(test)
number_formats :: proc(t: ^testing.T) {
	testing.expect_value(t, fmt_ms(0.345), "0.34")
	testing.expect_value(t, fmt_ms(4.24), "4.2")
	testing.expect_value(t, fmt_ms(16.7), "16.7")
	testing.expect_value(t, fmt_ms(123.4), "123")
	testing.expect_value(t, fmt_ms(1.24, comma = true), "1,2")
	testing.expect_value(t, fmt_bytes(512), "512 B")
	testing.expect_value(t, fmt_bytes(12_400), "12.4 kB")
	testing.expect_value(t, fmt_bytes(312_000_000), "312 MB")
	testing.expect_value(t, fmt_bytes(2_500_000_000, comma = true), "2,50 GB")
	testing.expect_value(t, fmt_count(999), "999")
	testing.expect_value(t, fmt_count(7440), "7440")
	testing.expect_value(t, fmt_count(12345), "12 345")
	testing.expect_value(t, fmt_count(1234567), "1 234 567")
}

@(test)
hud_settings_parse :: proc(t: ^testing.T) {
	p := config.prefs_make()
	defer config.prefs_destroy(&p)
	register_all_prefs(&p)
	s := hud_settings_from_prefs(&p)
	testing.expect(t, s.bar_visible)
	testing.expect_value(t, len(s.items), len(Status_Item))
	testing.expect_value(t, s.metrics[0], Status_Metric.Graph)
	testing.expect(t, s.title_stats)
	hud_settings_destroy(&s)

	testing.expect_value(t, config.set_from_string(&p, "browser.status_bar.items", "zoom, nodes,bogus", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&p, "browser.status_bar.graph.colors", ",#ff0000,nope", .User), config.Set_Error.None)
	testing.expect_value(t, config.set_from_string(&p, "browser.status_bar.decimal_separator", ",", .User), config.Set_Error.None)
	testing.expect(t, config.set_from_string(&p, "browser.status_bar.decimal_separator", ";", .User) != config.Set_Error.None)
	s = hud_settings_from_prefs(&p)
	defer hud_settings_destroy(&s)
	testing.expect_value(t, len(s.items), 2)
	testing.expect_value(t, s.items[0], Status_Item.Zoom)
	testing.expect_value(t, s.items[1], Status_Item.Nodes)
	_, tasks_set := s.colors[.Tasks].?
	_, styles_set := s.colors[.Styles].?
	_, layout_set := s.colors[.Layout].?
	testing.expect(t, !tasks_set && styles_set && !layout_set)
	testing.expect(t, s.comma)
}

// The numbers of the status bar and the title, from the history of frames: frames per second over the window, means,
// over-budget frames, restyles and layout passes counted from the details.
@(test)
hud_numbers_from_history :: proc(t: ^testing.T) {
	saved := hud
	defer hud = saved
	hud = {}
	hud.cfg.window_ms, hud.cfg.budget = 1000, 16.7
	ui.history_init(&hud.history, 512, CPU_SERIES)
	defer ui.history_destroy(&hud.history)
	hud.details = make([]Frame_Detail, 512)
	defer delete(hud.details)
	// 3 s of frames 10 ms apart: 2 ms of styles, 1 ms of interface, 1 ms of GPU; every 10th frame a 20 ms layout
	for i in 1 ..= 300 {
		hud.serial += 1
		s := ui.history_push(&hud.history, f64(i) * 10, hud.serial)
		s.v[Hud_Series.Styles], s.v[Hud_Series.UI], s.v[Hud_Series.GPU] = 2, 1, 1
		d := Frame_Detail{serial = hud.serial, restyle = .Partial}
		if i % 10 == 0 { s.v[Hud_Series.Layout] = 20; d.lay_pass = .Full }
		hud.details[hud.serial % 512] = d
	}
	hud_refresh(nil, 3000)
	n := hud.nums
	testing.expect_value(t, n.frames, 101)                 // 2000 .. 3000 ms inclusive
	testing.expect(t, abs(n.fps - 101) < 0.01)
	testing.expect_value(t, n.cpu_max, 23)
	testing.expect_value(t, n.over, 11)                    // the 20 ms layouts (frames 200, 210 ... 300)
	testing.expect(t, abs(n.gpu_mean - 1) < 1e-4)
	testing.expect_value(t, n.gpu_n, 101)
	testing.expect_value(t, n.partial_restyles, 101)
	testing.expect_value(t, n.passes[.Full], 11)
	testing.expect(t, abs(n.series[.Styles] - 2) < 1e-4)
	// frames faster than the history keeps: the rate comes from the time the kept ones span
	ui.history_clear(&hud.history)
	for i in 0 ..< 600 { hud.serial += 1; ui.history_push(&hud.history, 5000 + f64(i) * 0.5, hud.serial) }
	hud_refresh(nil, 5300)
	testing.expect_value(t, hud.nums.frames, 512)
	testing.expect(t, hud.nums.fps > 1900 && hud.nums.fps < 2100)
	// nothing in the window: at rest
	hud_refresh(nil, 9000)
	testing.expect_value(t, hud.nums.frames, 0)
	testing.expect_value(t, hud.nums.fps, 0)
}
