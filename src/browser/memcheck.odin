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
import "core:slice"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"
import "core:time"
import "wb:base"
import "wb:js"
import "wb:page"
import "wb:wasm"
import "wb:webfont"
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

foreign import kernel32_mem "system:Kernel32.lib"
foreign import user32_mem "system:User32.lib"

Mem_Heap_Summary :: struct {
	cb:                                            u32,
	allocated, committed, reserved, max_reserved: uint,
}

Mem_Basic_Info :: struct {
	base, alloc_base:  uintptr,
	alloc_protect:     u32,
	region_size:       uint,
	state, protect, kind: u32,
}

@(default_calling_convention = "system")
foreign kernel32_mem {
	@(link_name = "GetProcessHandleCount") mem_GetProcessHandleCount :: proc(process: win.HANDLE, count: ^u32) -> win.BOOL ---
	@(link_name = "GetProcessHeaps") mem_GetProcessHeaps :: proc(n: u32, heaps: [^]win.HANDLE) -> u32 ---
	@(link_name = "HeapSummary") mem_HeapSummary :: proc(heap: win.HANDLE, flags: u32, s: ^Mem_Heap_Summary) -> win.BOOL ---
	@(link_name = "HeapLock") mem_HeapLock :: proc(heap: win.HANDLE) -> win.BOOL ---
	@(link_name = "HeapUnlock") mem_HeapUnlock :: proc(heap: win.HANDLE) -> win.BOOL ---
	@(link_name = "HeapWalk") mem_HeapWalk :: proc(heap: win.HANDLE, e: ^Mem_Heap_Entry) -> win.BOOL ---
	@(link_name = "VirtualQuery") mem_VirtualQuery :: proc(address: uintptr, info: ^Mem_Basic_Info, length: uint) -> uint ---
}

// Where the private bytes are, as the system sees them (any build): what the process heaps hold (Odin, Rust, C
// libraries all allocate from them) against what they have committed, and the private committed pages outside the
// heaps by kind: read-write (arenas, linear memories, stacks) and executable (compiled code).
Memory_Split :: struct {
	heap_allocated, heap_committed: i64,
	vm_rw, vm_exec:                 i64,   // MEM_PRIVATE | MEM_COMMIT pages, all of them (the heaps' segments included)
}

MEM_COMMIT :: 0x1000
MEM_PRIVATE :: 0x20000

memory_split :: proc() -> (m: Memory_Split) {
	heaps: [64]win.HANDLE
	n := min(int(mem_GetProcessHeaps(len(heaps), &heaps[0])), len(heaps))
	for i in 0 ..< n {
		s := Mem_Heap_Summary{cb = size_of(Mem_Heap_Summary)}
		if mem_HeapSummary(heaps[i], 0, &s) { m.heap_allocated += i64(s.allocated); m.heap_committed += i64(s.committed) }
	}
	mbi: Mem_Basic_Info
	addr: uintptr
	for mem_VirtualQuery(addr, &mbi, size_of(mbi)) != 0 {
		if mbi.state == MEM_COMMIT && mbi.kind == MEM_PRIVATE {
			if mbi.protect & 0xF0 != 0 { m.vm_exec += i64(mbi.region_size) } else { m.vm_rw += i64(mbi.region_size) }
		}
		next := mbi.base + uintptr(mbi.region_size)
		if next <= addr { break }
		addr = next
	}
	return
}

Mem_Heap_Entry :: struct {
	data:                  rawptr,
	size:                  u32,
	overhead, region:      u8,
	flags:                 u16,
	_:                     [3]uintptr,   // the block / region union
}

// The live blocks of the process heaps grouped by exact size (the biggest groups first): what the native libraries
// hold that the tracker does not see. Slow; a diagnostic for the endurance run.
memory_heap_report :: proc(file: string, top := 40) {
	heaps: [64]win.HANDLE
	n := min(int(mem_GetProcessHeaps(len(heaps), &heaps[0])), len(heaps))
	sizes := make(map[u32][2]i64, 4096, context.temp_allocator)   // size -> {count, bytes}
	for i in 0 ..< n {
		e: Mem_Heap_Entry
		mem_HeapLock(heaps[i])
		for mem_HeapWalk(heaps[i], &e) {
			if e.flags & 0x4 == 0 { continue }   // PROCESS_HEAP_ENTRY_BUSY
			v := sizes[e.size]
			v[0] += 1
			v[1] += i64(e.size)
			sizes[e.size] = v
		}
		mem_HeapUnlock(heaps[i])
	}
	Group :: struct { size: u32, count, bytes: i64 }
	list := make([dynamic]Group, 0, len(sizes), context.temp_allocator)
	for s, v in sizes { append(&list, Group{s, v[0], v[1]}) }
	slice.sort_by(list[:], proc(a, b: Group) -> bool { return a.bytes > b.bytes })
	b := strings.builder_make(context.temp_allocator)
	total: i64
	for g in list { total += g.bytes }
	fmt.sbprintf(&b, "total %.2f MB in %d sizes\n", f64(total) / 1048576, len(list))
	for g, i in list {
		if i >= top { break }
		fmt.sbprintf(&b, "%d bytes\tx %d\t%.2f MB\n", g.size, g.count, f64(g.bytes) / 1048576)
	}
	_ = os.write_entire_file(file, transmute([]byte)strings.to_string(b))
}

// The biggest private committed allocations (one line each: base, committed MB, kind), to find what a number is made of.
memory_map_report :: proc(file: string, top := 40) {
	Region :: struct { base: uintptr, committed: i64, reserved: i64, exec: bool }
	regions := make(map[uintptr]Region, 256, context.temp_allocator)
	mbi: Mem_Basic_Info
	addr: uintptr
	for mem_VirtualQuery(addr, &mbi, size_of(mbi)) != 0 {
		if mbi.kind == MEM_PRIVATE && mbi.alloc_base != 0 {
			r := regions[mbi.alloc_base]
			r.base = mbi.alloc_base
			r.reserved += i64(mbi.region_size)
			if mbi.state == MEM_COMMIT {
				r.committed += i64(mbi.region_size)
				if mbi.protect & 0xF0 != 0 { r.exec = true }
			}
			regions[mbi.alloc_base] = r
		}
		next := mbi.base + uintptr(mbi.region_size)
		if next <= addr { break }
		addr = next
	}
	list := make([dynamic]Region, 0, len(regions), context.temp_allocator)
	for _, r in regions { if r.committed > 0 { append(&list, r) } }
	slice.sort_by(list[:], proc(a, b: Region) -> bool { return a.committed > b.committed })
	b := strings.builder_make(context.temp_allocator)
	for r, i in list {
		if i >= top { break }
		fmt.sbprintf(&b, "%x\t%.2f MB committed\t%.2f MB reserved\t%s\n", r.base, f64(r.committed) / 1048576, f64(r.reserved) / 1048576, r.exec ? "exec" : "rw")
	}
	_ = os.write_entire_file(file, transmute([]byte)strings.to_string(b))
}

@(default_calling_convention = "system")
foreign user32_mem {
	@(link_name = "GetGuiResources") mem_GetGuiResources :: proc(process: win.HANDLE, flags: u32) -> u32 ---
}

// What the system counts for this process (any build).
process_counters :: proc() -> (c: Process_Counters) {
	proc_h := win.GetCurrentProcess()
	pmc: win.PROCESS_MEMORY_COUNTERS_EX
	pmc.cb = size_of(pmc)
	if win.GetProcessMemoryInfo(proc_h, (^win.PROCESS_MEMORY_COUNTERS)(&pmc), size_of(pmc)) {
		c.private_bytes, c.working_set = i64(pmc.PrivateUsage), i64(pmc.WorkingSetSize)
	}
	n: u32
	if mem_GetProcessHandleCount(proc_h, &n) { c.handles = i64(n) }
	c.gdi = i64(mem_GetGuiResources(proc_h, 0))    // GR_GDIOBJECTS
	c.user = i64(mem_GetGuiResources(proc_h, 1))   // GR_USEROBJECTS
	return
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
			win.PostMessageW(active_window(app).win.hwnd, win.WM_CLOSE, 0, 0)
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
