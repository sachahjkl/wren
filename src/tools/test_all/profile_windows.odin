#+build windows
package test_all

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import win "core:sys/windows"
import "wb:tools/tooling"

// -Profile: where the time and the processors of a run go: every process it started, seen by name, with its exact wall time and CPU time, and the use of the processors second by second (the run's, and the rest of
// the machine's: other runs on the machine skew a measure, this says by how much). No sampling of the CPU times and no scanning of the process list: each step's job object tells a completion port of each process
// it gets, the handle opened then gives the exact times after it has ended. Writes build/prof/<time>.processes.tsv (pid, step, name, start, wall, cpu, command line of each process) and .timeline.tsv (one line per second).
//   test_all -ProfileReport build/prof/x     the table again
//   test_all -ProfileCompare a b             two runs

@(private = "file") MSG_NEW_PROCESS :: 6
@(private = "file") TICKS_PER_SECOND :: 10_000_000.0
@(private = "file") SAMPLE_MS :: 1000
@(private = "file") PROCESS_COMMAND_LINE_INFORMATION :: 60
@(private = "file") COMMAND_LINE_BYTES :: 65536
@(private = "file") TOP_PROGRAMS :: 25
@(private = "file") TIMELINE_SLICES :: 12
PROFILE_DIR :: "build/prof"

foreign import kernel32_times "system:Kernel32.lib"
@(default_calling_convention = "system", private = "file")
foreign kernel32_times {
	GetSystemTimes :: proc(idle, kernel, user: ^i64) -> win.BOOL ---
}

@(private = "file")
Seen_Process :: struct {
	pid:     u32,
	handle:  win.HANDLE,
	name:    string,
	command: string,
}

Profile :: struct {
	port:    win.HANDLE,
	stop:    bool,   // (atomic)
	thread:  ^thread.Thread,
	began:   i64,
	base:    string,
	seen:    [dynamic]Seen_Process,
	timeline: strings.Builder,
}

@(private = "file")
file_time_now :: proc() -> i64 {
	ft: win.FILETIME
	win.GetSystemTimeAsFileTime(&ft)
	return i64(ft.dwHighDateTime) << 32 | i64(ft.dwLowDateTime)
}

@(private = "file")
times_of :: proc(h: win.HANDLE) -> (create, exit, cpu: i64) {
	k, u: i64
	win.GetProcessTimes(h, (^win.FILETIME)(&create), (^win.FILETIME)(&exit), (^win.FILETIME)(&k), (^win.FILETIME)(&u))
	return create, exit, k + u
}

@(private = "file")
command_line_of :: proc(h: win.HANDLE) -> string {
	buf := make([]u8, COMMAND_LINE_BYTES, context.temp_allocator)
	got: u32
	if win.NtQueryInformationProcess(h, auto_cast PROCESS_COMMAND_LINE_INFORMATION, raw_data(buf), COMMAND_LINE_BYTES, &got) != 0 { return "" }
	length := int((^u16)(raw_data(buf))^)
	offset := size_of(rawptr) * 2
	if offset + length > len(buf) { return "" }
	wide := slice.reinterpret([]u16, buf[offset:offset + length])
	text, _ := win.utf16_to_utf8(wide, context.allocator)
	return text
}

@(private = "file")
name_of :: proc(h: win.HANDLE) -> string {
	text := tooling.process_image_path(h)
	if text == "" { return "?" }
	slash := strings.last_index_any(text, "\\/")
	base := text[slash + 1:]
	return strings.clone(strings.trim_suffix(base, ".exe"))
}

@(private = "file")
profile_thread :: proc(p: ^Profile) {
	last_idle, last_kernel, last_user: i64
	GetSystemTimes(&last_idle, &last_kernel, &last_user)
	last_time := file_time_now()
	last_cpu := i64(0)
	for !sync.atomic_load(&p.stop) {
		bytes: u32
		key: uint
		overlapped: ^win.OVERLAPPED
		if win.GetQueuedCompletionStatus(p.port, &bytes, &key, &overlapped, SAMPLE_MS) && bytes == MSG_NEW_PROCESS {
			pid := u32(uintptr(overlapped))
			h := win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
			if h != nil { append(&p.seen, Seen_Process{pid, h, name_of(h), command_line_of(h)}) }
		}
		free_all(context.temp_allocator)
		now := file_time_now()
		if f64(now - last_time) < TICKS_PER_SECOND { continue }
		cpu := i64(0)
		running := 0
		for s in p.seen {
			_, exit, c := times_of(s.handle)
			cpu += c
			if exit == 0 { running += 1 }
		}
		idle, kernel, user: i64
		GetSystemTimes(&idle, &kernel, &user)
		dt := f64(now - last_time) / TICKS_PER_SECOND
		tree := f64(cpu - last_cpu) / TICKS_PER_SECOND / dt
		machine := f64((kernel - last_kernel) + (user - last_user) - (idle - last_idle)) / TICKS_PER_SECOND / dt
		fmt.sbprintfln(&p.timeline, "%.3f\t%.3f\t%.3f\t%d", f64(now - p.began) / TICKS_PER_SECOND, tree, machine, running)
		last_cpu, last_time, last_idle, last_kernel, last_user = cpu, now, idle, kernel, user
	}
}

profile_begin :: proc() -> ^Profile {
	p := new(Profile)
	p.port = win.CreateIoCompletionPort(win.INVALID_HANDLE_VALUE, nil, 0, 1)
	p.began = file_time_now()
	buf: [time.MIN_YYYY_DATE_LEN]u8
	clock: [time.MIN_HMS_LEN]u8
	t := time.now()
	date, _ := strings.replace_all(time.to_string_yyyy_mm_dd(t, buf[:]), "-", "")
	hour, _ := strings.replace_all(time.to_string_hms(t, clock[:]), ":", "")
	p.base = fmt.aprintf("%s/%s-%s", PROFILE_DIR, date, hour)
	_ = os.make_directory_all(PROFILE_DIR)
	strings.write_string(&p.timeline, "t\ttree_cores\tmachine_cores\tprocesses\n")
	p.thread = thread.create_and_start_with_poly_data(p, profile_thread, context)
	return p
}

profile_port :: proc(p: ^Profile) -> rawptr { return rawptr(p.port) }

// What a step's command becomes when the run is profiled: its job tells the port.
profile_spawn :: proc(p: ^Profile, r: ^Step_Run, argv: []string, c: Command) -> tooling.Spawn {
	return {command = argv, env = c.env, dir = c.dir, log = r.log, port = rawptr(p.port)}
}

profile_end :: proc(p: ^Profile) {
	sync.atomic_store(&p.stop, true)
	thread.join(p.thread)
	b := strings.builder_make()
	strings.write_string(&b, "pid\tname\tstart\twall\tcpu\tcmd\n")
	now := file_time_now()
	for s in p.seen {
		create, exit, cpu := times_of(s.handle)
		end := exit == 0 ? now : exit
		command, _ := strings.replace_all(s.command, "\t", " ")
		fmt.sbprintfln(&b, "%d\t%s\t%.3f\t%.3f\t%.3f\t%s", s.pid, s.name, f64(create - p.began) / TICKS_PER_SECOND, f64(end - create) / TICKS_PER_SECOND, f64(cpu) / TICKS_PER_SECOND, command)
		win.CloseHandle(s.handle)
	}
	_ = os.write_entire_file(fmt.tprintf("%s.processes.tsv", p.base), strings.to_string(b))
	_ = os.write_entire_file(fmt.tprintf("%s.timeline.tsv", p.base), strings.to_string(p.timeline))
	profile_report(p.base)
}

@(private = "file")
Row :: struct { name: string, start, wall, cpu: f64 }
@(private = "file")
Second :: struct { t, tree, machine: f64 }

@(private = "file")
number :: proc(s: string) -> f64 { v, _ := strconv.parse_f64(s); return v }

@(private = "file")
read_rows :: proc(base: string) -> (rows: [dynamic]Row, seconds: [dynamic]Second) {
	data, _ := os.read_entire_file(fmt.tprintf("%s.processes.tsv", base), context.allocator)
	text := string(data)
	first := true
	for line in strings.split_lines_iterator(&text) {
		if first { first = false; continue }
		f := strings.split(line, "\t")
		if len(f) >= 5 { append(&rows, Row{f[1], number(f[2]), number(f[3]), number(f[4])}) }
	}
	data2, _ := os.read_entire_file(fmt.tprintf("%s.timeline.tsv", base), context.allocator)
	text2 := string(data2)
	first = true
	for line in strings.split_lines_iterator(&text2) {
		if first { first = false; continue }
		f := strings.split(line, "\t")
		if len(f) >= 3 { append(&seconds, Second{number(f[0]), number(f[1]), number(f[2])}) }
	}
	return
}

// The seconds at least one of these runs (several at once count once: what a run would gain if they took no time at all, at most).
@(private = "file")
union_seconds :: proc(rows: []Row) -> f64 {
	sorted := slice.clone(rows, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: Row) -> bool { return a.start < b.start })
	sum, end := 0.0, -1.0
	for r in sorted {
		e := r.start + r.wall
		if r.start > end { sum += r.wall; end = e } else if e > end { sum += e - end; end = e }
	}
	return sum
}

@(private = "file")
Program :: struct { name: string, count: int, wall, union_s, cpu: f64 }

@(private = "file")
programs_of :: proc(rows: []Row) -> []Program {
	by := make(map[string][dynamic]Row, 64, context.temp_allocator)
	for r in rows {
		list := by[r.name]
		append(&list, r)
		by[r.name] = list
	}
	out := make([dynamic]Program, context.temp_allocator)
	for name, list in by {
		p := Program{name = name, count = len(list), union_s = union_seconds(list[:])}
		for r in list { p.wall += r.wall; p.cpu += r.cpu }
		append(&out, p)
	}
	slice.sort_by(out[:], proc(a, b: Program) -> bool { return a.cpu > b.cpu })
	return out[:]
}

profile_report :: proc(base: string) {
	rows, seconds := read_rows(base)
	wall, cpu, tree, machine := 0.0, 0.0, 0.0, 0.0
	if len(seconds) > 0 { wall = seconds[len(seconds) - 1].t }
	for r in rows { cpu += r.cpu }
	for s in seconds { tree += s.tree; machine += s.machine }
	count := f64(max(len(seconds), 1))
	cores := os.get_processor_core_count()
	fmt.printfln("%s: %.0f s wall, %.0f s CPU in %d processes; %.1f processors of %d used on average by the run, %.1f by the rest of the machine", base, wall, cpu, len(rows), tree / count, cores, max(0, (machine - tree) / count))
	// how the run used the machine: the seconds in each band of its use
	BANDS := []f64{1, 2, 4, 8, 12, 16, 1000}
	fmt.print("seconds by processors used:")
	prev := 0.0
	for b in BANDS {
		n := 0
		for s in seconds { if s.tree >= prev && s.tree < b { n += 1 } }
		fmt.printf(" %.0f..%.0f: %d s,", prev, b, n)
		prev = b
	}
	fmt.println()
	piece := max(1, int(wall) / TIMELINE_SLICES)
	fmt.printf("processors used, every %d s:", piece)
	for t := 0; t < int(wall); t += piece {
		sum, n := 0.0, 0
		for s in seconds { if s.t >= f64(t) && s.t < f64(t + piece) { sum += s.tree; n += 1 } }
		if n > 0 { fmt.printf(" %.1f", sum / f64(n)) }
	}
	fmt.println()
	fmt.printfln("%7s %9s %9s %9s  %s", "count", "wall s", "union s", "CPU s", "program")
	for p, i in programs_of(rows[:]) {
		if i >= TOP_PROGRAMS { break }
		fmt.printfln("%7s %9s %9s %9s  %s", fmt.tprint(p.count), fmt.tprintf("%.1f", p.wall), fmt.tprintf("%.1f", p.union_s), fmt.tprintf("%.1f", p.cpu), p.name)
	}
}

profile_compare :: proc(a, b: string) {
	profile_report(a)
	fmt.println()
	profile_report(b)
	fmt.println()
	rows_a, _ := read_rows(a)
	rows_b, _ := read_rows(b)
	Diff :: struct { name: string, x, y: f64 }
	by := make(map[string]Diff, 64, context.temp_allocator)
	for p in programs_of(rows_a[:]) { d := by[p.name]; d.name = p.name; d.x = p.cpu; by[p.name] = d }
	for p in programs_of(rows_b[:]) { d := by[p.name]; d.name = p.name; d.y = p.cpu; by[p.name] = d }
	list := make([dynamic]Diff, context.temp_allocator)
	for _, d in by { append(&list, d) }
	slice.sort_by(list[:], proc(p, q: Diff) -> bool { return abs(p.y - p.x) > abs(q.y - q.x) })
	fmt.printfln("%9s %9s %9s   %s", "CPU s", "CPU s", "diff", "program")
	for d, i in list {
		if i >= TOP_PROGRAMS { break }
		fmt.printfln("%9s %9s %9s   %s", fmt.tprintf("%.1f", d.x), fmt.tprintf("%.1f", d.y), fmt.tprintf("%.1f", d.y - d.x), d.name)
	}
}
