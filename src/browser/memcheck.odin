package browser

// The check build (build.bat check -> build\wren_check.exe: -debug, -define:WREN_TRACK_MEMORY=true): every
// allocation of the process is tracked (base/memory.odin), and once the browser has shut everything down the blocks
// still allocated are written to <profile>/memtrack.txt (or to the file WREN_MEMTRACK_REPORT names). With
// WREN_MEMTRACK_FAIL=1 the process then exits with code 3 when there are any.
//
// The check build can also drive itself, without the desktop's keyboard or mouse: WREN_MEMCHECK_SCRIPT names a file of
// commands run one after the other on the UI thread, between frames (tools\memcheck_e2e.ps1, tools\endurance.ps1):
//
//     open <url>          a new tab showing <url>            go <url>       the current tab navigates
//     command <name>      a command of the registry (commands.odin: tab.close, nav.back, browser.command_palette...)
//     load                waits until the current tab has loaded (at most WREN_MEMCHECK_LOAD_MS, 30 s by default)
//     wait <ms>           frames go on meanwhile             frames <n>     waits for n frames
//     idle <ms>           nothing keeps the loop turning meanwhile: it sleeps as when left alone (memory_trim.odin trims)
//     trim                memory_trim now                    vmmap <file>   the biggest private allocations, and
//                         <file>.heap: the live heap blocks by size
//     stats <label>       a line of WREN_MEMCHECK_STATS (CSV): the tracker's counters, private bytes, working set,
//                         the process's kernel, GDI and USER handles, the tabs open
//     snapshot <file>     the live blocks grouped by place of allocation (base.mem_snapshot), to compare two of them
//     repeat <n> ... end  the commands between, n times (nested repeats too)
//     quit                closes the window: the normal exit, then the report
//     # ...               a comment
// A normal build has none of this.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:js"
import "wb:page"
import "wb:wasm"
import "wb:webfont"
import "toolkit:platform"
import "toolkit:render"

// `profile_dir` is a copy the caller keeps until this returns (the app's is freed before).
memcheck_exit :: proc(profile_dir: string) {
	when base.TRACK_MEMORY {
		driver_destroy()
		file := ""
		if os.get_env("WREN_MEMTRACK_REPORT", context.temp_allocator) == "" {
			file = strings.concatenate({profile_dir, "/memtrack.txt"}, context.temp_allocator)
		}
		n := base.mem_report("browser", file)
		if n > 0 && os.get_env("WREN_MEMTRACK_FAIL", context.temp_allocator) == "1" { os.exit(3) }
	}
}

// The loop's longest sleep: the script's `idle` step needs a turn when it ends.
memcheck_wake :: proc(timeout: int) -> int {
	when base.TRACK_MEMORY {
		if driver.active && driver.idling {
			left := max(int(time.duration_milliseconds(time.tick_diff(time.tick_now(), driver.deadline))), 1)
			return timeout <= 0 ? left : min(timeout, left)
		}
	}
	return timeout
}

// After each frame of the main loop: the next command of WREN_MEMCHECK_SCRIPT when the previous one is done.
memcheck_drive :: proc(app: ^App) {
	when base.TRACK_MEMORY { driver_step(app) }
}

Process_Counters :: struct {
	private_bytes, working_set: i64,
	handles, gdi, user:         i64,
}

// Where the private bytes are, as the system sees them (any build): what the process heaps hold (Odin, Rust, C
// libraries all allocate from them) against what they have committed, and the private committed pages outside the
// heaps by kind: read-write (arenas, linear memories, stacks) and executable (compiled code). The reader lives in the
// toolkit's testkit (process_<os>.odin); Windows fills every field, Linux leaves the heap / VM split zero for now.
Memory_Split :: struct {
	heap_allocated, heap_committed: i64,
	vm_rw, vm_exec:                 i64,
}

memory_split :: proc() -> (m: Memory_Split) {
	s := base.memory_split()
	return {heap_allocated = s.heap_allocated, heap_committed = s.heap_committed, vm_rw = s.vm_rw, vm_exec = s.vm_exec}
}

// What the system counts for this process (any build): the memory above, the open kernel handles, and (Windows) the GDI
// and USER objects. From base.process_counters (toolkit:testkit), the same numbers Windows reported directly before.
process_counters :: proc() -> (c: Process_Counters) {
	pc := base.process_counters()
	return {private_bytes = pc.private, working_set = pc.resident, handles = pc.handles, gdi = pc.gdi, user = pc.user}
}

////////////////////////////////
// The script driver (check builds)

@(private = "file")
Step_Kind :: enum u8 { Open, Go, Command, Load, Wait, Idle, Frames, Stats, Snapshot, Vmmap, Trim, Quit }

@(private = "file")
Step :: struct {
	kind: Step_Kind,
	arg:  string,   // in the driver's text
	n:    int,
}

@(private = "file")
Driver :: struct {
	started:  bool,
	active:   bool,
	text:     []byte,
	steps:    [dynamic]Step,
	next:     int,
	waiting:  bool,         // the current step is waiting (deadline or frames)
	idling:   bool,         // ... and lets the loop sleep (idle)
	deadline: time.Tick,
	frames:   int,
	load_ms:  f64,
	t0:       time.Tick,
	stats:    ^os.File,
	has_stats: bool,
}

@(private = "file")
driver: Driver

@(private = "file")
driver_start :: proc() {
	driver.started = true
	path := os.get_env("WREN_MEMCHECK_SCRIPT", context.temp_allocator)
	if path == "" { return }
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { return }
	driver.text = data
	driver.load_ms = 30_000
	if v := os.get_env("WREN_MEMCHECK_LOAD_MS", context.temp_allocator); v != "" {
		if n, ok := strconv.parse_f64(v); ok && n > 0 { driver.load_ms = n }
	}
	lines := strings.split_lines(string(data), context.temp_allocator)
	i := 0
	driver_parse(lines, &i, 1)
	if p := os.get_env("WREN_MEMCHECK_STATS", context.temp_allocator); p != "" {
		if h, herr := os.open(p, os.O_WRONLY | os.O_CREATE | os.O_TRUNC); herr == nil {
			driver.stats, driver.has_stats = h, true
			_, _ = os.write_string(h, "step,label,ms,live_bytes,live_blocks,peak_bytes,permanent_bytes,private_bytes,working_set,handles,gdi,user,tabs,heap_allocated,heap_committed,vm_rw,vm_exec,wasm_modules,wasm_code_bytes,wasm_instances,js_entries,js_bytes,img_entries,img_bytes,font_entries,font_bytes,gpu_target_bytes,trims\n")
		}
	}
	driver.t0 = time.tick_now()
	driver.active = len(driver.steps) > 0
}

// Appends the commands of lines[i:] (until a matching `end`) `times` times.
@(private = "file")
driver_parse :: proc(lines: []string, i: ^int, times: int) {
	start := i^
	for rep in 0 ..< max(times, 1) {
		i^ = start
		for i^ < len(lines) {
			line := strings.trim_space(lines[i^])
			i^ += 1
			if line == "" || line[0] == '#' { continue }
			word, _, rest := strings.partition(line, " ")
			rest = strings.trim_space(rest)
			switch word {
			case "end":
			case "repeat":
				n, _ := strconv.parse_int(rest)
				driver_parse(lines, i, n)
				continue
			case "open":    append(&driver.steps, Step{kind = .Open, arg = rest})
			case "go":      append(&driver.steps, Step{kind = .Go, arg = rest})
			case "command": append(&driver.steps, Step{kind = .Command, arg = rest})
			case "load":    append(&driver.steps, Step{kind = .Load})
			case "wait":    n, _ := strconv.parse_int(rest); append(&driver.steps, Step{kind = .Wait, n = n})
			case "frames":  n, _ := strconv.parse_int(rest); append(&driver.steps, Step{kind = .Frames, n = n})
			case "stats":   append(&driver.steps, Step{kind = .Stats, arg = rest})
			case "snapshot": append(&driver.steps, Step{kind = .Snapshot, arg = rest})
			case "vmmap":   append(&driver.steps, Step{kind = .Vmmap, arg = rest})
			case "trim":    append(&driver.steps, Step{kind = .Trim})
			case "idle":    n, _ := strconv.parse_int(rest); append(&driver.steps, Step{kind = .Idle, n = n})
			case "quit":    append(&driver.steps, Step{kind = .Quit})
			}
			if word == "end" {
				if rep == max(times, 1) - 1 { return }
				break
			}
		}
	}
}

@(private = "file")
driver_step :: proc(app: ^App) {
	if !driver.started { driver_start() }
	if !driver.active { return }
	if !driver.idling { request_frames(app, 1) }   // the loop keeps turning while the script runs
	for driver.next < len(driver.steps) {
		s := &driver.steps[driver.next]
		t := current_tab(app)
		if driver.waiting {
			switch s.kind {
			case .Wait: if time.tick_diff(driver.deadline, time.tick_now()) < 0 { return }
			case .Idle:
				if time.tick_diff(driver.deadline, time.tick_now()) < 0 { return }
				driver.idling = false
			case .Frames: driver.frames -= 1; if driver.frames > 0 { return }
			case .Load: if tab_busy(t) && time.tick_diff(driver.deadline, time.tick_now()) < 0 { return }
			case .Open, .Go, .Command, .Stats, .Snapshot, .Vmmap, .Trim, .Quit:
			}
			driver.waiting = false
			driver.next += 1
			continue
		}
		switch s.kind {
		case .Open:
			tab_open(app, s.arg, origin = .User)
		case .Go:
			if t != nil { navigate(app, t, s.arg, origin = .User) }
		case .Command:
			if c := command(s.arg); c != nil { command_run(app, t, c) }
		case .Load:
			driver.waiting, driver.deadline = true, time.tick_add(time.tick_now(), time.Duration(driver.load_ms * f64(time.Millisecond)))
			return
		case .Wait:
			driver.waiting, driver.deadline = true, time.tick_add(time.tick_now(), time.Duration(s.n) * time.Millisecond)
			return
		case .Idle:   // like a wait, but the loop may fall asleep (nothing keeps it turning): what the browser does when left alone
			driver.waiting, driver.idling, driver.deadline = true, true, time.tick_add(time.tick_now(), time.Duration(s.n) * time.Millisecond)
			return
		case .Frames:
			driver.waiting, driver.frames = true, max(s.n, 1)
			return
		case .Stats:
			driver_stats(app, s.arg)
		case .Snapshot:
			base.mem_snapshot(s.arg)
		case .Vmmap:
			memory_map_report(s.arg)
			memory_heap_report(strings.concatenate({s.arg, ".heap"}, context.temp_allocator))
		case .Trim:
			memory_trim(app)
		case .Quit:
			driver.active = false
			platform.request_close(active_window(app).win)
			return
		}
		driver.next += 1
		return   // one command per frame: the shell reacts to each as to a user's
	}
	driver.active = false
}

@(private = "file")
driver_stats :: proc(app: ^App, label: string) {
	if !driver.has_stats { return }
	m := base.mem_stats()
	c := process_counters()
	sp := memory_split()
	wc := wasm.cache_stats()
	jc := js.cache_stats()
	is := page.images_stats(nil)
	_, _, fe, fb := webfont.decoded_cache_stats()
	line := fmt.tprintf("%d,%s,%.0f,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n", driver.next, label, time.duration_milliseconds(time.tick_since(driver.t0)),
		m.live_bytes, m.live_blocks, m.peak_bytes, m.permanent_bytes, c.private_bytes, c.working_set, c.handles, c.gdi, c.user, len(tabs_all(app)),
		sp.heap_allocated, sp.heap_committed, sp.vm_rw, sp.vm_exec, wc.entries, wc.code_bytes, wasm.instances_alive(), jc.entries, jc.bytes,
		is.entries, is.bytes, fe, fb, render.targets_bytes(&app.r), memory_trim_count())
	_, _ = os.write_string(driver.stats, line)
}

@(private = "file")
driver_destroy :: proc() {
	if driver.has_stats { os.close(driver.stats) }
	delete(driver.steps)
	delete(driver.text)
	driver = {}
}
