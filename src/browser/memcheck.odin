package browser

// The check build (build.bat check -> build\browser_check.exe: -debug, -define:WREN_TRACK_MEMORY=true): every
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
//     stats <label>       a line of WREN_MEMCHECK_STATS (CSV): the tracker's counters, private bytes, working set,
//                         the process's kernel, GDI and USER handles, the tabs open
//     repeat <n> ... end  the commands between, n times (nested repeats too)
//     quit                closes the window: the normal exit, then the report
//     # ...               a comment
// A normal build has none of this.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"
import "core:time"
import "wb:base"

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

@(default_calling_convention = "system")
foreign kernel32_mem {
	@(link_name = "GetProcessHandleCount") mem_GetProcessHandleCount :: proc(process: win.HANDLE, count: ^u32) -> win.BOOL ---
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
Step_Kind :: enum u8 { Open, Go, Command, Load, Wait, Frames, Stats, Quit }

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
			_, _ = os.write_string(h, "step,label,ms,live_bytes,live_blocks,peak_bytes,permanent_bytes,private_bytes,working_set,handles,gdi,user,tabs\n")
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
	app.frames_requested = max(app.frames_requested, 1)   // the loop keeps turning while the script runs
	for driver.next < len(driver.steps) {
		s := &driver.steps[driver.next]
		t := current_tab(app)
		if driver.waiting {
			switch s.kind {
			case .Wait: if time.tick_diff(driver.deadline, time.tick_now()) < 0 { return }
			case .Frames: driver.frames -= 1; if driver.frames > 0 { return }
			case .Load: if tab_busy(t) && time.tick_diff(driver.deadline, time.tick_now()) < 0 { return }
			case .Open, .Go, .Command, .Stats, .Quit:
			}
			driver.waiting = false
			driver.next += 1
			continue
		}
		switch s.kind {
		case .Open:
			tab_open(app, s.arg)
		case .Go:
			if t != nil { navigate(app, t, s.arg) }
		case .Command:
			if c := command(s.arg); c != nil { command_run(app, t, c) }
		case .Load:
			driver.waiting, driver.deadline = true, time.tick_add(time.tick_now(), time.Duration(driver.load_ms * f64(time.Millisecond)))
			return
		case .Wait:
			driver.waiting, driver.deadline = true, time.tick_add(time.tick_now(), time.Duration(s.n) * time.Millisecond)
			return
		case .Frames:
			driver.waiting, driver.frames = true, max(s.n, 1)
			return
		case .Stats:
			driver_stats(app, s.arg)
		case .Quit:
			driver.active = false
			win.PostMessageW(app.win.hwnd, win.WM_CLOSE, 0, 0)
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
	line := fmt.tprintf("%d,%s,%.0f,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d\n", driver.next, label, time.duration_milliseconds(time.tick_since(driver.t0)),
		m.live_bytes, m.live_blocks, m.peak_bytes, m.permanent_bytes, c.private_bytes, c.working_set, c.handles, c.gdi, c.user, len(app.tabs))
	_, _ = os.write_string(driver.stats, line)
}

@(private = "file")
driver_destroy :: proc() {
	if driver.has_stats { os.close(driver.stats) }
	delete(driver.steps)
	delete(driver.text)
	driver = {}
}
