package browser

// A timeline of the frames the renderer draws, for finding what the eye sees and a settled capture does not: a header drawn
// twice for one frame, a blank page for another, the scroll bar jumping. `wren ctl timeline start` records every frame the window
// ends (full frames and the chrome frames made while a page keeps the thread), `timeline stop <dir>` writes them as pictures with
// a contact sheet and a JSON of what each frame was (when, its scroll, whether it was a chrome frame, how much it differs from
// the frame before, and whether it is an A-B-A: a frame that differs from both its neighbours while those two are alike).
// The frames are what the renderer drew (the same copy as a capture), so the window may be hidden; the copy costs one GPU read a
// frame, and a frame whose copy is not ready when the next one ends is missed (counted in `skipped`).

import "core:fmt"
import "core:os"
import "core:strings"
import "toolkit:render"
import "wb:host"
import "wb:images"
import "wb:remote"

Tl_Frame :: struct {
	n:       int,       // the frame's number since the start (frames the recorder saw, missed ones included)
	ms:      f64,
	nested:  bool,      // a chrome frame, made while a page kept the thread
	scroll:  f32,
	hold:    bool,      // the page of the navigation before is being held
	loading: bool,
	skipped: int,       // frames missed since the one before
	pixels:  []u8,
	w, h:    int,
}

Timeline :: struct {
	on:     bool,
	scale:  f32,
	rect:   [4]int,
	max:    int,
	t0:     i64,
	frames: [dynamic]Tl_Frame,
	asked:  bool,       // a copy of the frame before is waiting to be read
	meta:   Tl_Frame,
	missed: int,
	seen:   int,
}

TIMELINE_MAX_FRAMES :: 1500

// Before a frame ends (remote_capture_arm): the copy of the frame before is taken, and this frame's is asked for.
timeline_frame :: proc(app: ^App) {
	tl := &the_remote.tl
	if !tl.on || the_remote.capture_window != 0 { return }
	if tl.asked {
		pixels, size, st := render.capture_poll(&app.r)
		#partial switch st {
		case .Ready:
			f := tl.meta
			f.pixels, f.w, f.h = pixels, size.x, size.y
			if tl.scale != 1 {
				small, w, h := scale_rgba(pixels, size.x, size.y, tl.scale)
				delete(pixels)
				f.pixels, f.w, f.h = small, w, h
			}
			f.skipped, tl.missed = tl.missed, 0
			append(&tl.frames, f)
			tl.asked = false
		case .Pending:
			tl.missed += 1   // the GPU has not finished the copy: this frame is not recorded
			tl.seen += 1
			return
		case: tl.asked = false
		}
	}
	if len(tl.frames) >= tl.max { tl.on = false; return }
	if render.capture_pending(&app.r) { tl.missed += 1; tl.seen += 1; return }
	if render.capture_request(&app.r, tl.rect) {
		tl.asked = true
		m := Tl_Frame{n = tl.seen, ms = f64(host.now_ns(&app.loop) - tl.t0) / 1e6, nested = shell_nested()}
		if t := current_tab(app); t != nil { m.scroll, m.hold, m.loading = t.scroll, t.hold.active, tab_loading(t) }
		tl.meta = m
	}
	tl.seen += 1
}

timeline_free :: proc(tl: ^Timeline) {
	for f in tl.frames { delete(f.pixels) }
	clear(&tl.frames)
	tl.asked, tl.missed, tl.seen = false, 0, 0
}

// Wren.timeline {action: start | stop | status, scale (0.3), max (240), target: window | page (start); dir, cols (6), all (stop)}
m_timeline :: proc(app: ^App, c: ^Call) -> Reply {
	tl := &the_remote.tl
	action, _ := remote.param_string(c.params, "action", "status")
	switch action {
	case "start":
		timeline_free(tl)
		s, _ := remote.param_float(c.params, "scale", 0.3)
		mx, _ := remote.param_int(c.params, "max", 240)
		tgt, _ := remote.param_string(c.params, "target", "window")
		tl.scale, tl.max = f32(clamp(s, 0.05, 1)), clamp(mx, 2, TIMELINE_MAX_FRAMES)
		tl.rect = {}
		if tgt == "page" {
			pr := active_window(app).page_rect
			tl.rect = {int(pr.min.x), int(pr.min.y), int(pr.max.x - pr.min.x), int(pr.max.y - pr.min.y)}
		}
		tl.t0, tl.on = host.now_ns(&app.loop), true
		request_frames(app, 2)
		return done(fmt.tprintf(`{{"recording":true,"scale":%.2f,"max":%d}}`, tl.scale, tl.max))
	case "status":
		return done(fmt.tprintf(`{{"recording":%v,"frames":%d}}`, tl.on, len(tl.frames)))
	case "stop":
		dir, ok := remote.param_string(c.params, "dir")
		if !ok { return fail(remote.ERR_PARAMS, "\"dir\": the folder for the pictures") }
		cols, _ := remote.param_int(c.params, "cols", 6)
		all, _ := remote.param_bool(c.params, "all")
		tl.on = false
		if tl.asked { render.capture_cancel(&app.r); tl.asked = false }
		rep := timeline_write(tl, dir, clamp(cols, 1, 24), all)
		timeline_free(tl)
		return rep
	}
	return fail(remote.ERR_PARAMS, "action: start, stop or status")
}

@(private = "file")
pixels_differing :: proc(a, b: []u8) -> int {
	n := 0
	for i := 0; i + 3 < min(len(a), len(b)); i += 4 {
		if abs(int(a[i]) - int(b[i])) > 8 || abs(int(a[i + 1]) - int(b[i + 1])) > 8 || abs(int(a[i + 2]) - int(b[i + 2])) > 8 { n += 1 }
	}
	return n
}

@(private = "file")
timeline_write :: proc(tl: ^Timeline, dir: string, cols: int, all: bool) -> Reply {
	frames := tl.frames[:]
	if len(frames) == 0 { return fail(remote.ERR_FAILED, "no frame was recorded (was `timeline start` called, and did the window draw?)") }
	if err := os.make_directory_all(dir); err != nil && !os.exists(dir) { return fail(remote.ERR_FAILED, fmt.tprintf("cannot make %s", dir)) }
	n := len(frames)
	w, h := frames[0].w, frames[0].h
	thr := max(30, w * h / 3000)   // pixels that must differ for a frame to count as changed
	diff := make([]int, n, context.temp_allocator)
	aba := make([]bool, n, context.temp_allocator)
	for i in 1 ..< n {
		if frames[i].w == w && frames[i].h == h && frames[i - 1].w == w && frames[i - 1].h == h { diff[i] = pixels_differing(frames[i - 1].pixels, frames[i].pixels) } else { diff[i] = w * h }
	}
	for i in 1 ..< n - 1 {
		if diff[i] > thr && diff[i + 1] > thr && frames[i - 1].w == w && frames[i + 1].w == w {
			if pixels_differing(frames[i - 1].pixels, frames[i + 1].pixels) * 5 < min(diff[i], diff[i + 1]) { aba[i] = true }
		}
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"dir":%s,"frames":[`, remote.quote(dir))
	flagged, chrome := 0, 0
	for f, i in frames {
		file := fmt.tprintf("%s/%03d.png", dir, i)
		if png, ok := images.encode_rgba(f.pixels, f.w, f.h, .Png, 0, false); ok { _ = os.write_entire_file(file, png); delete(png) }
		if aba[i] { flagged += 1 }
		if f.nested { chrome += 1 }
		if i > 0 { strings.write_byte(&b, ',') }
		fmt.sbprintf(&b, `{{"i":%d,"n":%d,"ms":%.1f,"kind":"%s","scroll":%.0f,"hold":%v,"loading":%v,"skipped":%d,"diff":%d,"aba":%v}}`,
			i, f.n, f.ms, f.nested ? "chrome" : "full", f.scroll, f.hold, f.loading, f.skipped, diff[i], aba[i])
	}
	// the contact sheet: the frames that changed (all of them with `all`), in order, a red frame on an A-B-A and an orange one on a chrome frame
	shown := make([dynamic]int, context.temp_allocator)
	for i in 0 ..< n { if all || i == 0 || diff[i] > thr || aba[i] { append(&shown, i) } }
	if len(shown) > 120 && !all { resize(&shown, 120) }
	rows := (len(shown) + cols - 1) / cols
	gap := 4
	sw, sh := cols * (w + gap) + gap, rows * (h + gap) + gap
	sheet := make([]u8, sw * sh * 4, context.temp_allocator)
	for i in 0 ..< len(sheet) / 4 { sheet[i * 4], sheet[i * 4 + 1], sheet[i * 4 + 2], sheet[i * 4 + 3] = 40, 40, 40, 255 }
	for k, slot in shown {
		f := frames[k]
		if f.w != w || f.h != h { continue }
		ox, oy := gap + (slot % cols) * (w + gap), gap + (slot / cols) * (h + gap)
		for y in 0 ..< h { copy(sheet[((oy + y) * sw + ox) * 4:][:w * 4], f.pixels[y * w * 4:][:w * 4]) }
		mark: [3]u8
		has := true
		switch {
		case aba[k]: mark = {230, 40, 40}
		case f.nested: mark = {240, 150, 30}
		case: has = false
		}
		if has {
			for t in 0 ..< 3 {
				for x in 0 ..< w { for yy in ([2]int{t, h - 1 - t}) { o := ((oy + yy) * sw + ox + x) * 4; sheet[o], sheet[o + 1], sheet[o + 2] = mark[0], mark[1], mark[2] } }
				for y in 0 ..< h { for xx in ([2]int{t, w - 1 - t}) { o := ((oy + y) * sw + ox + xx) * 4; sheet[o], sheet[o + 1], sheet[o + 2] = mark[0], mark[1], mark[2] } }
			}
		}
	}
	sheet_path := fmt.tprintf("%s/sheet.png", dir)
	if png, ok := images.encode_rgba(sheet, sw, sh, .Png, 0, false); ok { _ = os.write_entire_file(sheet_path, png); delete(png) }
	shown_list := strings.builder_make(context.temp_allocator)
	for k, slot in shown { if slot > 0 { strings.write_byte(&shown_list, ',') }; fmt.sbprintf(&shown_list, "%d", k) }
	fmt.sbprintf(&b, `],"count":%d,"chrome":%d,"aba":%d,"sheet":%s,"sheetFrames":[%s],"cols":%d,"width":%d,"height":%d}}`,
		n, chrome, flagged, remote.quote(sheet_path), strings.to_string(shown_list), cols, w, h)
	if err := os.write_entire_file(fmt.tprintf("%s/timeline.json", dir), transmute([]byte)strings.to_string(b)); err != nil { return fail(remote.ERR_FAILED, "cannot write timeline.json") }
	return done(strings.to_string(b))
}
