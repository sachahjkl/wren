#+vet !unused-imports
package browser

// Latency of the shell under load (profile build, WREN_PROF set): every frame's input poll and present on the QPC
// time line, so that tools\shell_latency.ps1, which posts input to the window and notes the QPC of each post, can
// tell for every input how long it took until a frame that had read it was presented. The UI thread being busy with a
// page (a long script, a layout) shows up as frames polled late: the input waited in the window's queue meanwhile.
// Written as <prefix>.latency.txt: freq on the first line, then one row per frame.

import "core:fmt"
import "core:os"
import "core:strings"

Latency_Frame :: struct {
	polled, presented: i64,   // QPC
	events:            i32,
	w, h:              i32,   // window size the frame was drawn at
	kind:              u8,    // 0: a full frame; 1: a chrome frame made while the page was busy (shell_frames.odin)
}

when PROFILE {

@(private = "file") lat_frames: [dynamic]Latency_Frame
@(private = "file") lat_cur: Latency_Frame

// Right after the frame read its input.
latency_probe_polled :: proc(events: int) {
	if !prof.on { return }
	lat_cur = Latency_Frame{polled = qpc(), events = i32(events)}
}

// Right after the frame was presented.
latency_probe_presented :: proc(app: ^App, kind: u8 = 0) {
	if !prof.on || lat_cur.polled == 0 { return }
	lat_cur.presented = qpc()
	lat_cur.w, lat_cur.h = i32(app.win.size.x), i32(app.win.size.y)
	lat_cur.kind = kind
	append(&lat_frames, lat_cur)
	lat_cur = {}
}

// A chrome frame made inside a full frame (shell_frames.odin) records itself without losing the full frame's poll.
latency_probe_save :: proc() -> Latency_Frame { v := lat_cur; lat_cur = {}; return v }
latency_probe_restore :: proc(v: Latency_Frame) { lat_cur = v }

latency_probe_report :: proc() {
	if !prof.on { return }
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "freq,%d\npolled,presented,events,w,h,kind\n", i64(prof.freq))
	for f in lat_frames { fmt.sbprintf(&sb, "%d,%d,%d,%d,%d,%d\n", f.polled, f.presented, f.events, f.w, f.h, f.kind) }
	_ = os.write_entire_file(strings.concatenate({prof.out, ".latency.txt"}, context.temp_allocator), transmute([]byte)strings.to_string(sb))
	delete(lat_frames)
}

} else {

latency_probe_polled :: proc(events: int) {}
latency_probe_presented :: proc(app: ^App, kind: u8 = 0) {}
latency_probe_report :: proc() {}
latency_probe_save :: proc() -> Latency_Frame { return {} }
latency_probe_restore :: proc(v: Latency_Frame) {}

}
