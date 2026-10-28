package browser

import "core:fmt"
import "core:os"
import "core:time"
import "wb:base"
import "wb:host"

// Measuring what loading costs (WREN_LOAD_REPORT=<file>): for each page loaded in a tab, a line of tab-separated values is
// appended once the page had WREN_LOAD_REPORT_MS (default 10000) to settle: URL, blocker on or off, time to the first paint,
// time until readyState complete, requests made, requests blocked, bytes received, DOM nodes, process CPU time and memory.
// tools\blocker_perf.ps1 runs it over a list of sites with and without the blocker.

Load_Measure :: struct {
	active:    bool,
	url:       string,
	start:     time.Tick,
	paint_ms:  f64,
	done_ms:   f64,
	cpu0:      f64,
	tab:       u64,
	timer:     base.Handle,
}

@(private = "file") lm: Load_Measure
@(private = "file") report_path: string
@(private = "file") settle_ms := 10000.0
@(private = "file") checked: bool

@(private = "file")
enabled :: proc() -> bool {
	if !checked {
		checked = true
		report_path = os.get_env("WREN_LOAD_REPORT", context.allocator)
		if s := os.get_env("WREN_LOAD_REPORT_MS", context.temp_allocator); s != "" {
			n := 0
			for c in s { if c >= '0' && c <= '9' { n = n * 10 + int(c - '0') } }
			if n > 0 { settle_ms = f64(n) }
		}
	}
	return report_path != ""
}

@(private = "file")
cpu_ms :: proc() -> f64 {
	t := base.process_times()
	return t.user_ms + t.kernel_ms
}

load_measure_begin :: proc(app: ^App, t: ^Tab, address: string) {
	if !enabled() || !(len(address) > 4 && address[:4] == "http") { return }
	if lm.timer != base.NIL_HANDLE { host.clear_timer(&app.loop, lm.timer) }
	delete(lm.url)
	lm = Load_Measure{active = true, url = fmt.aprintf("%s", address), start = time.tick_now(), cpu0 = cpu_ms(), tab = t.id}
	lm.timer = host.set_timer(&app.loop, settle_ms, 0, load_measure_write, app)
}

load_measure_painted :: proc(t: ^Tab) {
	if !lm.active || t.id != lm.tab || t.page == nil { return }
	ms := time.duration_milliseconds(time.tick_since(lm.start))
	if lm.paint_ms == 0 && t.page.render.painted { lm.paint_ms = ms }
	if lm.done_ms == 0 && t.page.scripts != nil && t.page.scripts.ready_state == .Complete { lm.done_ms = ms }
}

@(private = "file")
load_measure_write :: proc(data: rawptr) {
	app := (^App)(data)
	m := &lm
	m.timer = base.NIL_HANDLE
	if !m.active { return }
	m.active = false
	var_t: ^Tab
	for t in tabs_all(app) { if t.id == m.tab { var_t = t } }
	if var_t == nil || var_t.page == nil { return }
	blocked := 0
	if ts := blocker_tab(var_t); ts != nil { blocked = ts.blocked }
	mem := base.process_memory()
	on := bl.started && bl.b.cfg.enabled
	line := fmt.tprintf("%s\t%s\t%.0f\t%.0f\t%d\t%d\t%d\t%d\t%.0f\t%.1f\n", m.url, on ? "on" : "off", m.paint_ms, m.done_ms, len(var_t.net.entries), blocked, var_t.net.bytes, var_t.page.doc.nodes.count, cpu_ms() - m.cpu0, f64(mem.resident) / 1e6)
	if f, err := os.open(report_path, {.Write, .Create, .Append}, os.Permissions_Default_File); err == nil {
		os.write_string(f, line)
		os.close(f)
	}
}
