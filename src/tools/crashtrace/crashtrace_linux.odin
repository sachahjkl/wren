package crashtrace

// Linux: a crash (SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP) prints the faulting thread's call stack on standard
// output and standard error and, once set_report_dir was called, into "<dir>/crash <date> <time> UTC.txt"; then the
// process dies as it would have (the default action: the system's core dump, if enabled, keeps the memory). What the
// minidump is on Windows is the core dump here (coredumpctl).
//
// The handler runs on an alternate signal stack (a stack overflow leaves none of its own), allocates nothing and writes with
// system calls. The stack comes from libc's backtrace(), which unwinds through the signal frame into the faulting code with
// the unwind tables (.eh_frame) of every module; each frame is printed with its module and the offset in it (dladdr), what
// an offline symbolizer reads (addr2line -e <exe> <offset>, or tools/crash_symbolize with the build's map), and with
// the name libc finds (exported symbols only: an executable's own functions show as module+offset). The build is named
// by its GNU build id (build_fingerprint).

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"

foreign import libc "system:c"
foreign import libdl "system:dl"

@(private = "file")
Dl_Info :: struct {
	fname: cstring,
	fbase: rawptr,
	sname: cstring,
	saddr: rawptr,
}

@(private = "file", default_calling_convention = "c")
foreign libc {
	backtrace :: proc(buffer: [^]rawptr, size: i32) -> i32 ---
	getauxval :: proc(type: u64) -> u64 ---
}

@(private = "file", default_calling_convention = "c")
foreign libdl {
	dladdr :: proc(addr: rawptr, info: ^Dl_Info) -> i32 ---
}

@(private = "file") MAX_FRAMES :: 64
@(private = "file") ALT_STACK_SIZE :: 256 * 1024

@(private = "file") installed: bool
@(private = "file") reported: i32
@(private = "file") alt_stack: [ALT_STACK_SIZE]u8
@(private = "file") report_dir: [512]u8
@(private = "file") report_dir_len: int
@(private = "file") report_header: [512]u8
@(private = "file") report_header_len: int
@(private = "file") report_fd: linux.Fd = -1
@(private = "file") fingerprint: [64]u8
@(private = "file") fingerprint_len: int

@(private = "file")
SIGNALS := [?]posix.Signal{.SIGSEGV, .SIGBUS, .SIGILL, .SIGFPE, .SIGABRT, .SIGTRAP}

// The GNU build id of the executable (the note the linker writes with --build-id: build.sh asks for it), as hex: it names
// one build, as the PE time stamp and size do on Windows. `base` is ignored here (the running executable's). "" without
// a build id.
build_fingerprint :: proc(buf: []u8, base: uintptr = 0) -> string {
	n := copy(buf, fingerprint[:fingerprint_len])
	return string(buf[:n])
}

// The build id of the executable mapped in this process, read from its program headers (AT_PHDR).
@(private = "file")
read_build_id :: proc "contextless" () -> int {
	phdr := uintptr(getauxval(3))    // AT_PHDR
	phnum := int(getauxval(5))       // AT_PHNUM
	if phdr == 0 || phnum == 0 { return 0 }
	PT_PHDR :: 6
	PT_NOTE :: 4
	bias: uintptr
	for i in 0 ..< phnum {
		p := phdr + uintptr(i * 56)
		if (^u32)(p)^ == PT_PHDR { bias = phdr - uintptr((^u64)(p + 16)^) }
	}
	for i in 0 ..< phnum {
		p := phdr + uintptr(i * 56)
		if (^u32)(p)^ != PT_NOTE { continue }
		at := bias + uintptr((^u64)(p + 16)^)
		end := at + uintptr((^u64)(p + 32)^)
		for at + 12 <= end {
			namesz, descsz, kind := (^u32)(at)^, (^u32)(at + 4)^, (^u32)(at + 8)^
			name := at + 12
			desc := name + uintptr((namesz + 3) &~ 3)
			if kind == 3 && namesz == 4 && (^u32)(name)^ == 0x00554e47 {   // NT_GNU_BUILD_ID, "GNU\0"
				HEX := "0123456789abcdef"
				n := 0
				for k in 0 ..< int(descsz) {
					if n + 2 > len(fingerprint) { break }
					b := ([^]u8)(desc)[k]
					fingerprint[n], fingerprint[n + 1] = HEX[b >> 4], HEX[b & 15]
					n += 2
				}
				return n
			}
			at = desc + uintptr((descsz + 3) &~ 3)
		}
	}
	return 0
}

// The folder where crashes leave their report (created on the first crash), and a line written at the top of each
// report (the program and its version). Call it once at startup; until then a crash only prints.
set_report_dir :: proc(dir: string, header := "") {
	report_dir_len = copy(report_dir[:len(report_dir) - 1], dir)
	report_header_len = copy(report_header[:], header)
}

@(init, private = "file")
install :: proc "contextless" () {
	if installed { return }
	installed = true
	fingerprint_len = read_build_id()
	// backtrace() loads libgcc's unwinder on its first call, which allocates: done here, not in the handler
	warm: [4]rawptr
	backtrace(&warm[0], len(warm))
	ss := posix.stack_t{ss_sp = &alt_stack[0], ss_size = ALT_STACK_SIZE}
	posix.sigaltstack(&ss, nil)
	for s in SIGNALS {
		act: posix.sigaction_t
		act.sa_sigaction = on_signal
		act.sa_flags = {.SIGINFO, .ONSTACK, .RESETHAND}
		posix.sigaction(s, &act, nil)
	}
}

// Threads other than the main one need an alternate stack of their own for a stack overflow on them to be reported: a
// thread may call this once at its start (the stack is the caller's to keep for the thread's life).
thread_alt_stack :: proc(stack: []u8) {
	ss := posix.stack_t{ss_sp = raw_data(stack), ss_size = uint(len(stack))}
	posix.sigaltstack(&ss, nil)
}

@(private = "file")
signal_name :: proc(s: posix.Signal) -> string {
	#partial switch s {
	case .SIGSEGV: return "segmentation fault (an invalid memory access)"
	case .SIGBUS:  return "bus error"
	case .SIGILL:  return "illegal instruction (an Odin assertion or bounds check)"
	case .SIGFPE:  return "arithmetic error (an integer division by zero)"
	case .SIGABRT: return "abort (a runtime gave up: a Rust panic that could not unwind, a failed C assertion, a corrupted heap)"
	case .SIGTRAP: return "breakpoint"
	}
	return "signal"
}

@(private = "file")
on_signal :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, uctx: rawptr) {
	if intrinsics.atomic_exchange(&reported, 1) == 0 {
		context = runtime.default_context()   // memcheck: a signal handler runs on the faulting thread, outside the tracker
		write_report(sig, info, uctx)
	}
	// SA_RESETHAND put the default action back: a fault returns to the instruction, which faults again and ends the
	// process as it would have; a signal sent on purpose (abort) is sent again
	#partial switch sig {
	case .SIGABRT, .SIGTRAP: posix.raise(sig)
	}
}

@(private = "file")
write_report :: proc(sig: posix.Signal, info: ^posix.siginfo_t, uctx: rawptr) {
	open_report()
	buf: [4096]u8
	tid := linux.gettid()
	// the faulting instruction: RIP of the interrupted context (ucontext_t: uc_mcontext.gregs[REG_RIP], x86-64)
	pc: uintptr
	when ODIN_ARCH == .amd64 { if uctx != nil { pc = uintptr((^u64)(uintptr(uctx) + 40 + 16 * 8)^) } }
	emit(fmt.bprintf(buf[:], "\n*** crash: %s (signal %d) at 0x%X, thread %d, address 0x%X", signal_name(sig), int(sig), pc, int(tid), uintptr(info.si_addr)))
	emit(build_line(buf[:]))
	frames: [MAX_FRAMES]rawptr
	n := int(backtrace(&frames[0], MAX_FRAMES))
	// the first frames are this handler and the signal trampoline: the stack proper starts at the faulting instruction
	first := 0
	for i in 0 ..< n { if pc != 0 && uintptr(frames[i]) == pc { first = i; break } }
	k := 0
	for i in first ..< n {
		emit(frame_line(buf[:], k, uintptr(frames[i])))
		k += 1
	}
	emit("*** end of the stack\n")
	if report_fd >= 0 { linux.close(report_fd); report_fd = -1 }
}

// "build <exe> <build id>, base 0x...": which build crashed and where it was loaded.
@(private = "file")
build_line :: proc(buf: []u8) -> string {
	d: Dl_Info
	exe := "?"
	base: uintptr
	if dladdr(rawptr(build_line), &d) != 0 {
		if d.fname != nil { exe = file_name(string(d.fname)) }
		base = uintptr(d.fbase)
	}
	if fingerprint_len == 0 { return fmt.bprintf(buf, "  build %s (no build id), base 0x%X", exe, base) }
	return fmt.bprintf(buf, "  build %s %s, base 0x%X", exe, string(fingerprint[:fingerprint_len]), base)
}

@(private = "file")
file_name :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i >= 0 { return path[i + 1:] }
	return path
}

// "#NN 0x<address> <symbol>+0x<offset>  [<module>+0x<offset in the module>]".
@(private = "file")
frame_line :: proc(buf: []u8, i: int, pc: uintptr) -> string {
	d: Dl_Info
	if dladdr(rawptr(pc), &d) == 0 { return fmt.bprintf(buf, "  #%02d 0x%X ?", i, pc) }
	mod := d.fname != nil ? file_name(string(d.fname)) : "?"
	off := pc - uintptr(d.fbase)
	if d.sname != nil { return fmt.bprintf(buf, "  #%02d 0x%X %s+0x%X  [%s+0x%X]", i, pc, string(d.sname), pc - uintptr(d.saddr), mod, off) }
	return fmt.bprintf(buf, "  #%02d 0x%X ?  [%s+0x%X]", i, pc, mod, off)
}

// The report file: "<dir>/crash <date> <time> UTC.txt" (UTC: the local time zone is not read in a signal handler).
@(private = "file")
open_report :: proc() {
	if report_dir_len == 0 { return }
	path: [len(report_dir) + 64]u8
	n := copy(path[:], report_dir[:report_dir_len])
	path[n] = 0
	linux.mkdir(cstring(&path[0]), {.IRUSR, .IWUSR, .IXUSR})
	ts, _ := linux.clock_gettime(.REALTIME)
	y, mo, d, h, mi, s := civil_utc(i64(ts.time_sec))
	stem := fmt.bprintf(path[n:len(path) - 1], "/crash %04d-%02d-%02d %02d-%02d-%02d UTC.txt", y, mo, d, h, mi, s)
	path[n + len(stem)] = 0
	fd, err := linux.open(cstring(&path[0]), {.WRONLY, .CREAT, .TRUNC, .CLOEXEC}, {.IRUSR, .IWUSR})
	if err != .NONE { return }
	report_fd = fd
	if report_header_len > 0 {
		linux.write(fd, report_header[:report_header_len])
		linux.write(fd, transmute([]u8)string("\n"))
	}
}

// Seconds since 1970 as a UTC date and time (days to civil date: H. Hinnant's algorithm).
@(private)
civil_utc :: proc "contextless" (t: i64) -> (y, mo, d, h, mi, s: int) {
	days := t / 86400
	rem := t - days * 86400
	if rem < 0 { rem += 86400; days -= 1 }
	h, mi, s = int(rem / 3600), int(rem % 3600 / 60), int(rem % 60)
	z := days + 719468
	era := (z >= 0 ? z : z - 146096) / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d = int(doy - (153 * mp + 2) / 5 + 1)
	mo = int(mp < 10 ? mp + 3 : mp - 9)
	y = int(yoe + era * 400 + (mo <= 2 ? 1 : 0))
	return
}

// On standard output (where test_all keeps the tools' reports), standard error and the report file, with nothing buffered.
@(private = "file")
emit :: proc(s: string) {
	nl := transmute([]u8)string("\n")
	for fd in ([2]linux.Fd{1, 2}) {
		linux.write(fd, transmute([]u8)s)
		linux.write(fd, nl)
	}
	if report_fd >= 0 {
		linux.write(report_fd, transmute([]u8)s)
		linux.write(report_fd, nl)
	}
}

////////////////////////////////
// Sessions that ended without a report

// What kills a process without the handler being run (SIGKILL: the out-of-memory killer, a watchdog, kill -9): a file
// "session.txt" in the report folder says a session is running (its process id, its start after boot, the header);
// end_session() removes it at a clean exit. Found at the next start with its process gone, it becomes
// "unclean exit <date>.txt" in the same folder.
begin_session :: proc() {
	if report_dir_len == 0 { return }
	dir := string(report_dir[:report_dir_len])
	_ = os.make_directory_all(dir)
	path := strings.concatenate({dir, "/session.txt"}, context.temp_allocator)
	if prev, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		pid, started := parse_session(string(prev))
		if pid != 0 && !process_is(pid, started) { write_unclean(dir, string(prev), pid) }
	}
	text := fmt.tprintf("%d\n%d\n%s\n", os.get_pid(), start_ticks(os.get_pid()), string(report_header[:report_header_len]))
	_ = os.write_entire_file(path, transmute([]u8)text)
}

end_session :: proc() {
	if report_dir_len == 0 { return }
	_ = os.remove(strings.concatenate({string(report_dir[:report_dir_len]), "/session.txt"}, context.temp_allocator))
}

@(private = "file")
parse_session :: proc(text: string) -> (pid: int, started: u64) {
	lines := strings.split(text, "\n", context.temp_allocator)
	if len(lines) < 2 { return }
	p, ok1 := strconv.parse_int(strings.trim_space(lines[0]), 10)
	s, ok2 := strconv.parse_u64(strings.trim_space(lines[1]), 10)
	if ok1 && ok2 { return p, s }
	return
}

// The start of process `pid` after boot, in clock ticks (/proc/<pid>/stat, field 22); 0 when it is gone.
@(private)
start_ticks :: proc(pid: int) -> u64 {
	stat, err := os.read_entire_file(fmt.tprintf("/proc/%d/stat", pid), context.temp_allocator)
	if err != nil { return 0 }
	s := string(stat)
	close := strings.last_index_byte(s, ')')
	if close < 0 { return 0 }
	fields := strings.fields(s[close + 1:], context.temp_allocator)
	if len(fields) < 20 { return 0 }
	v, _ := strconv.parse_u64(fields[19])
	return v
}

// Whether process `pid` that started at `started` still runs (a recycled id is another process).
@(private = "file")
process_is :: proc(pid: int, started: u64) -> bool {
	now := start_ticks(pid)
	return now != 0 && now == started
}

@(private = "file")
write_unclean :: proc(dir, prev: string, pid: int) {
	ts, _ := linux.clock_gettime(.REALTIME)
	y, mo, d, h, mi, s := civil_utc(i64(ts.time_sec))
	text := fmt.tprintf("%s\n\n*** a session ended without a crash report: no stack, the handler was not run (SIGKILL: the out-of-memory killer, a watchdog, kill -9; or the machine stopped).\nThe session file said (process id, start, program):\n%s\nThe system's record: journalctl -k (the out-of-memory killer), coredumpctl (a core dump of process %d).\n",
		string(report_header[:report_header_len]), prev, pid)
	path := fmt.tprintf("%s/unclean exit %04d-%02d-%02d %02d-%02d-%02d UTC.txt", dir, y, mo, d, h, mi, s)
	_ = os.write_entire_file(path, transmute([]u8)text)
}
