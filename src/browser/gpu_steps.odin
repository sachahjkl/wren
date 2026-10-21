#+vet !unused-imports
package browser

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "toolkit:draw"
import "toolkit:render"
import "toolkit:ui"

// GPU time by step of the frame (render.set_gpu_profile: a timestamp after every run of draw calls, clear, copy and
// filter pass): the "GPU steps" section of the frame statistics panel, and the profiler's per-step report and CSV
// columns. Measured only while one of them is read (the panel open with GPU timing on, or the profiler recording).

Gpu_Steps_Frame :: struct {
	valid:   bool,
	n:       [render.Gpu_Step]u16,
	ms:      [render.Gpu_Step]f32,
	px:      [render.Gpu_Step]f32,   // Mpx written
	mb:      [render.Gpu_Step]f32,   // MB moved (estimate)
	targets: u16,                    // render targets bound
}

@(private)
gpu_steps_state: struct {
	last:    render.Gpu_Profile,
	have:    bool,
	cache:   draw.Layer_Cache_Stats,
}

@(private)
gpu_steps_of :: proc(p: render.Gpu_Profile) -> Gpu_Steps_Frame {
	g := Gpu_Steps_Frame{valid = true, targets = u16(min(p.target_changes, 65535))}
	for k in render.Gpu_Step {
		s := p.steps[k]
		g.n[k], g.ms[k] = u16(min(s.count, 65535)), s.ms
		g.px[k], g.mb[k] = f32(s.pixels) / 1e6, f32(s.bytes) / (1 << 20)
	}
	return g
}

// Each frame's end (prof_frame_end): measured while read (a timestamp per step serializes the GPU a little: the
// profiler takes them only with WREN_GPU_STEPS=1, so that its frame times stay those of an unmeasured frame); the
// latest profile and the cache's numbers for the panel.
gpu_steps_frame :: proc(app: ^App) {
	@(static) env := -1
	if env < 0 {
		v := os.get_env("WREN_GPU_STEPS", context.temp_allocator)
		env = v == "2" ? 2 : v == "1" ? 1 : 0
	}
	// WREN_GPU_STEPS=2: every draw call timed (the report lists the slowest)
	render.set_gpu_profile(&app.r, (prof_on() && env >= 1) || (hud.panel_open && hud.cfg.gpu_timing), prof_on() && env == 2)
	if p, ok := render.gpu_profile(&app.r); ok { gpu_steps_state.last, gpu_steps_state.have = p, true }
	gpu_steps_state.cache = draw.layer_cache_stats(&app.dc)
}

// The per-step profile of a recorded frame, when it arrives (a few frames late): matched by its timed submit.
gpu_steps_attach :: proc(app: ^App, frames: []Frame_Rec) {
	cs := draw.layer_cache_stats(&app.dc)   // the frame just recorded
	append(&gpu_kept, [3]i32{i32(cs.hits), i32(cs.misses), i32(cs.stored)})
	p, ok := render.gpu_profile(&app.r)
	if !ok { return }
	for k := len(frames) - 1; k >= max(0, len(frames) - 16); k -= 1 {
		if frames[k].gpu_index == p.frame {
			if !frames[k].gpu_steps.valid { gpu_steps_slowest(p) }
			frames[k].gpu_steps = gpu_steps_of(p)
			break
		}
	}
}

GPU_STEP_NAMES := [render.Gpu_Step]string{
	.Draw_Frame = "draw frame", .Draw_Layer = "draw layers", .Clear = "clears", .Copy = "copies",
	.Color = "color passes", .Blur = "blur passes", .Downsample = "reductions", .Shadow = "shadow passes",
	.Mask = "mask passes", .Upload = "uploads", .Acquire = "back buffer", .Present = "present", .Idle = "idle before",
}

// CSV columns (prof.odin): per step, the count and the milliseconds; then the targets bound.
gpu_steps_csv_header :: proc(sb: ^strings.Builder) {
	for k in render.Gpu_Step { fmt.sbprintf(sb, ",gpu_%v_n,gpu_%v_ms", k, k) }
	strings.write_string(sb, ",gpu_targets")
}

gpu_steps_csv_row :: proc(sb: ^strings.Builder, g: Gpu_Steps_Frame) {
	for k in render.Gpu_Step {
		if g.valid { fmt.sbprintf(sb, ",%d,%.4f", g.n[k], g.ms[k]) } else { strings.write_string(sb, ",,") }
	}
	if g.valid { fmt.sbprintf(sb, ",%d", g.targets) } else { strings.write_string(sb, ",") }
}

// The slowest steps of the detailed profile, by batch, summed over the frames.
@(private)
Slow_Step :: struct { ms: f64, n: int, rec: render.Gpu_Step_Rec }
@(private) gpu_slow: map[i32]Slow_Step
@(private) gpu_slow_frames: int
@(private) gpu_kept: [dynamic][3]i32   // per recorded frame: kept effect results reused, redrawn, kept anew

@(private)
gpu_steps_slowest :: proc(p: render.Gpu_Profile) {
	if !render.gpu_profile_enabled(&the_app.r) { return }
	gpu_slow_frames += 1
	for i in 0 ..< p.n_slowest {
		s := p.slowest[i]
		if s.batch < 0 { continue }
		e := gpu_slow[s.batch]
		e.ms += f64(s.ms)
		e.n += 1
		e.rec = s
		gpu_slow[s.batch] = e
	}
}

when PROFILE {

// The profiler's report: per step, frames profiled, mean count, mean / p95 / max milliseconds, written pixels and
// estimated traffic.
gpu_steps_report :: proc(sb: ^strings.Builder, frames: []Frame_Rec) {
	if len(gpu_kept) > 0 {
		k: [3]f64
		for v in gpu_kept { k += {f64(v[0]), f64(v[1]), f64(v[2])} }
		fmt.sbprintf(sb, "\n-- kept effect results per frame: reused %.2f, redrawn %.2f, kept anew %.3f\n", k[0] / f64(len(gpu_kept)), k[1] / f64(len(gpu_kept)), k[2] / f64(len(gpu_kept)))
	}
	n := 0
	for f in frames { if f.gpu_steps.valid { n += 1 } }
	if n == 0 { return }
	fmt.sbprintf(sb, "\n-- GPU steps (%d frames profiled; per frame)\n", n)
	fmt.sbprintf(sb, "  %-14s %7s %8s %8s %8s %8s %9s\n", "step", "count", "mean ms", "p95 ms", "max ms", "Mpx", "MB")
	targets: f64
	for f in frames { if f.gpu_steps.valid { targets += f64(f.gpu_steps.targets) } }
	for k in render.Gpu_Step {
		v := make([dynamic]f64, 0, n, context.temp_allocator)
		cnt, px, mb: f64
		for f in frames {
			g := f.gpu_steps
			if !g.valid { continue }
			append(&v, f64(g.ms[k]))
			cnt += f64(g.n[k]); px += f64(g.px[k]); mb += f64(g.mb[k])
		}
		if cnt == 0 { continue }
		s := stat_of(v[:])
		fmt.sbprintf(sb, "  %-14s %7.1f %8.3f %8.3f %8.3f %8.3f %9.2f\n", GPU_STEP_NAMES[k], cnt / f64(n), s.mean, s.p95, s.max, px / f64(n), mb / f64(n))
	}
	fmt.sbprintf(sb, "  render targets bound per frame: %.1f\n", targets / f64(n))
	if len(gpu_slow) == 0 { return }
	// detailed profile: the draw calls that were among the slowest of their frame, by batch index
	Row :: struct { batch: i32, s: Slow_Step }
	rows := make([dynamic]Row, 0, len(gpu_slow), context.temp_allocator)
	for b, s in gpu_slow { append(&rows, Row{b, s}) }
	slice.sort_by(rows[:], proc(a, b: Row) -> bool { return a.s.ms > b.s.ms })
	fmt.sbprintf(sb, "  slowest draw calls (ms per profiled frame, %d frames): batch, insts, kinds (bit k = KIND k, 31 = picture), flags, scissor\n", gpu_slow_frames)
	for r, i in rows {
		if i >= 25 { break }
		x := r.s.rec
		fmt.sbprintf(sb, "    %8.4f  %-11v batch %4d  insts %5d  kinds %08x  flags %08x  scissor %v\n", r.s.ms / f64(max(gpu_slow_frames, 1)), x.kind, r.batch, x.insts, x.kinds, x.flags, x.scissor)
	}
}

} else {

gpu_steps_report :: proc(sb: ^strings.Builder, frames: []Frame_Rec) {}

}

// The panel's section: the last profile read back, and the kept effect results.
panel_gpu_steps :: proc(app: ^App, w: f32) {
	c := hud.cfg.comma
	ui.stat_heading("gpusteps", "GPU STEPS, LAST FRAME MS", w)
	st := &gpu_steps_state
	if !render.gpu_timing_enabled(&app.r) || !st.have {
		ui.stat_row("gs_none", "Steps", render.gpu_timing_enabled(&app.r) ? "--" : "not measured", w, mono = false)
	} else {
		p := st.last
		for k in render.Gpu_Step {
			s := p.steps[k]
			if s.count == 0 { continue }
			ui.stat_row(fmt.tprintf("gs_%d", int(k)), fmt.tprintf("%s (%d)", GPU_STEP_NAMES[k], s.count), fmt_ms(s.ms, c), w)
		}
		ui.stat_row("gs_targets", "Targets bound", fmt.tprintf("%d", p.target_changes), w)
	}
	cs := st.cache
	ui.stat_row("gs_kept", "Kept effects", fmt.tprintf("%d, %s", cs.entries, fmt_bytes(cs.bytes, c)), w)
	ui.stat_row("gs_hits", "Reused / redrawn", fmt.tprintf("%d / %d", cs.hits, cs.misses), w)
}
