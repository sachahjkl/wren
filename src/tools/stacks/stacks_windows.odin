#+build windows
// Package stacks: the call stack of every thread of another process that runs, named with its PDB, for what hangs and leaves
// nothing behind. `wren ctl stacks <pid>` prints them for any process of this user (a test tool too); `wren ctl quit` writes them
// when the Wren it closes does not end; the shutdown watchdog has the same command write them before it ends a stuck browser.
//
// From another process on purpose. A process that walks its own threads must suspend them to read them, and a suspended thread may
// hold the very heap lock or loader lock that DbgHelp then waits for; here the only thing that can hang is this reader, and whoever
// runs it has it under a limit. The target is suspended one thread at a time, for as long as it takes to read that thread's frames:
// the names are looked up after it runs again.
package stacks

import "core:fmt"
import "core:strings"
import win "core:sys/windows"

// How many frames of a thread are read; how long a symbol's name may be.
MAX_FRAMES :: 96
SYMBOL_NAME_CHARS :: 256
// The longest file name a frame prints, in characters.
FILE_NAME_CHARS :: 512

@(private = "file") IMAGE_FILE_MACHINE_AMD64 :: 0x8664
@(private = "file") ADDR_MODE_FLAT :: 3
@(private = "file") CONTEXT_FULL_AMD64 :: 0x0010000B
@(private = "file") STILL_ACTIVE :: 259
// What a minidump holds: MiniDumpWithIndirectlyReferencedMemory | MiniDumpWithThreadInfo (as a crash's report).
@(private = "file") MINIDUMP_FLAGS :: 0x1040
// (the room dbghelp's own KDHELP64 takes at the end of a STACKFRAME64: its size has grown with the versions of the library)
@(private = "file") KDHELP_ROOM :: 256

@(private = "file")
ADDRESS64 :: struct {
	Offset:  u64,
	Segment: u16,
	Mode:    u32,
}

@(private = "file")
STACKFRAME64 :: struct {
	AddrPC, AddrReturn, AddrFrame, AddrStack, AddrBStore: ADDRESS64,
	FuncTableEntry: rawptr,
	Params:   [4]u64,
	Far:      win.BOOL,
	Virtual:  win.BOOL,
	Reserved: [3]u64,
	KdHelp:   [KDHELP_ROOM]u8,
}

foreign import dbghelp_stacks "system:DbgHelp.lib"

@(private = "file", default_calling_convention = "system")
foreign dbghelp_stacks {
	StackWalk64 :: proc(machine: u32, process, thread: win.HANDLE, frame: ^STACKFRAME64, ctx: rawptr, read_memory, table_access, module_base, translate: rawptr) -> win.BOOL ---
	SymFunctionTableAccess64 :: proc(process: win.HANDLE, addr: u64) -> rawptr ---
	SymGetModuleBase64 :: proc(process: win.HANDLE, addr: u64) -> u64 ---
}

@(private = "file")
Module :: struct {
	base, size: u64,
	name:       string,
}

@(private = "file")
Walk_State :: enum u8 { Read, Cannot_Open, Cannot_Suspend, No_Context }

@(private = "file")
Thread_Walk :: struct {
	id:     u32,
	name:   string,
	state:  Walk_State,
	frames: [MAX_FRAMES]u64,
	count:  int,
}

// The threads of process `pid` as text (temp allocator). `minidump`: also a dump of the process in that file. ok false: it could not
// be opened (gone, or another user's); `text` says so.
process_text :: proc(pid: int, minidump := "") -> (text: string, ok: bool) {
	if pid == int(win.GetCurrentProcessId()) { return "a process does not read its own stacks here (it would suspend itself)", false }
	access := win.DWORD(win.PROCESS_QUERY_INFORMATION | win.PROCESS_VM_READ)
	process := win.OpenProcess(access, false, win.DWORD(pid))
	if process == nil { return fmt.tprintf("cannot open process %d (error %d)", pid, win.GetLastError()), false }
	defer win.CloseHandle(process)

	b := strings.builder_make(context.temp_allocator)
	code: win.DWORD
	win.GetExitCodeProcess(process, &code)
	// (a process with an exit code and threads left: it was told to end, and something it runs does not let it)
	if code == STILL_ACTIVE { fmt.sbprintf(&b, "process %d, running\n", pid) } else { fmt.sbprintf(&b, "process %d, ending with code %d: these threads have not ended\n", pid, code) }
	if minidump != "" { write_minidump(&b, process, pid, minidump) }

	win.SymSetOptions(win.SYMOPT_LOAD_LINES | win.SYMOPT_DEFERRED_LOADS)
	symbols := bool(win.SymInitialize(process, nil, true))
	defer if symbols { win.SymCleanup(process) }
	if !symbols { fmt.sbprintf(&b, "(no symbols: SymInitialize, error %d)\n", win.GetLastError()) }

	mods := modules_of(pid)
	walks := threads_of(pid)
	for &t in walks { walk_thread(process, &t) }
	for &t in walks {
		fmt.sbprintf(&b, "\nthread %d %q\n", t.id, t.name)
		switch t.state {
		case .Read:
		case .Cannot_Open: strings.write_string(&b, "  (cannot open it)\n")
		case .Cannot_Suspend: strings.write_string(&b, "  (cannot suspend it)\n")
		case .No_Context: strings.write_string(&b, "  (cannot read its registers)\n")
		}
		for pc, i in t.frames[:t.count] { write_frame(&b, process, symbols, mods, i, pc) }
	}
	return strings.to_string(b), true
}

@(private = "file")
write_minidump :: proc(b: ^strings.Builder, process: win.HANDLE, pid: int, path: string) {
	file := win.CreateFileW(win.utf8_to_wstring(path, context.temp_allocator), win.GENERIC_WRITE, 0, nil, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, nil)
	if file == win.INVALID_HANDLE_VALUE { fmt.sbprintf(b, "(cannot write %s, error %d)\n", path, win.GetLastError()); return }
	defer win.CloseHandle(file)
	if win.MiniDumpWriteDump(process, win.DWORD(pid), file, win.MINIDUMP_TYPE(MINIDUMP_FLAGS), nil, nil, nil) {
		fmt.sbprintf(b, "minidump: %s\n", path)
	} else {
		fmt.sbprintf(b, "(no minidump, error %d)\n", win.GetLastError())
	}
}

@(private = "file")
narrow :: proc(w: []u16) -> string {
	s, err := win.utf16_to_utf8(w, context.temp_allocator)
	return err == nil ? s : ""
}

@(private = "file")
modules_of :: proc(pid: int) -> []Module {
	out := make([dynamic]Module, context.temp_allocator)
	snap := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPMODULE, win.DWORD(pid))
	if snap == win.INVALID_HANDLE_VALUE { return out[:] }
	defer win.CloseHandle(snap)
	e := win.MODULEENTRY32W{dwSize = size_of(win.MODULEENTRY32W)}
	for more := win.Module32FirstW(snap, &e); more; more = win.Module32NextW(snap, &e) {
		n := 0
		for n < len(e.szModule) && e.szModule[n] != 0 { n += 1 }
		append(&out, Module{base = u64(uintptr(e.modBaseAddr)), size = u64(e.modBaseSize), name = narrow(e.szModule[:n])})
	}
	return out[:]
}

@(private = "file")
threads_of :: proc(pid: int) -> []Thread_Walk {
	out := make([dynamic]Thread_Walk, context.temp_allocator)
	snap := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPTHREAD, 0)
	if snap == win.INVALID_HANDLE_VALUE { return out[:] }
	defer win.CloseHandle(snap)
	e := win.THREADENTRY32{dwSize = size_of(win.THREADENTRY32)}
	for more := win.Thread32First(snap, &e); more; more = win.Thread32Next(snap, &e) {
		if int(e.th32OwnerProcessID) == pid { append(&out, Thread_Walk{id = e.th32ThreadID}) }
	}
	return out[:]
}

// Reads the return addresses of a thread, suspended meanwhile.
@(private = "file")
walk_thread :: proc(process: win.HANDLE, t: ^Thread_Walk) {
	thread := win.OpenThread(win.THREAD_SUSPEND_RESUME | win.THREAD_GET_CONTEXT | win.THREAD_QUERY_INFORMATION, false, win.DWORD(t.id))
	if thread == nil { t.state = .Cannot_Open; return }
	defer win.CloseHandle(thread)
	desc: win.PWSTR
	if win.GetThreadDescription(thread, &desc) >= 0 && desc != nil {
		w := ([^]u16)(rawptr(desc))
		n := 0
		for w[n] != 0 { n += 1 }
		t.name = narrow(w[:n])
		win.LocalFree(rawptr(desc))
	}
	if win.SuspendThread(thread) == ~win.DWORD(0) { t.state = .Cannot_Suspend; return }
	defer win.ResumeThread(thread)
	ctx: win.CONTEXT
	ctx.ContextFlags = CONTEXT_FULL_AMD64
	if !win.GetThreadContext(thread, &ctx) { t.state = .No_Context; return }
	frame := STACKFRAME64{}
	frame.AddrPC = {Offset = ctx.Rip, Mode = ADDR_MODE_FLAT}
	frame.AddrFrame = {Offset = ctx.Rbp, Mode = ADDR_MODE_FLAT}
	frame.AddrStack = {Offset = ctx.Rsp, Mode = ADDR_MODE_FLAT}
	for t.count < MAX_FRAMES {
		if !StackWalk64(IMAGE_FILE_MACHINE_AMD64, process, thread, &frame, &ctx, nil, rawptr(SymFunctionTableAccess64), rawptr(SymGetModuleBase64), nil) { break }
		if frame.AddrPC.Offset == 0 { break }
		t.frames[t.count] = frame.AddrPC.Offset
		t.count += 1
	}
}

// "#NN <symbol>+0x<offset>  [<module>+0x<offset in the module>]  <file>:<line>"; a frame of a program with no PDB has the module's
// offset, which wrentool symbolize and wrentool crash-symbolize read.
@(private = "file")
write_frame :: proc(b: ^strings.Builder, process: win.HANDLE, symbols: bool, mods: []Module, i: int, pc: u64) {
	fmt.sbprintf(b, "  #%02d ", i)
	named := false
	if symbols {
		raw: [size_of(win.SYMBOL_INFOW) + SYMBOL_NAME_CHARS * size_of(u16)]u8
		sym := (^win.SYMBOL_INFOW)(&raw[0])
		sym.SizeOfStruct = size_of(win.SYMBOL_INFOW)
		sym.MaxNameLen = SYMBOL_NAME_CHARS
		disp: u64
		if win.SymFromAddrW(process, pc, &disp, sym) {
			fmt.sbprintf(b, "%s+0x%X", narrow(([^]u16)(&sym.Name[0])[:sym.NameLen]), disp)
			named = true
		}
	}
	if !named { fmt.sbprintf(b, "0x%X", pc) }
	for m in mods {
		if pc >= m.base && pc < m.base + m.size { fmt.sbprintf(b, "  [%s+0x%X]", m.name, pc - m.base); break }
	}
	if symbols {
		line: win.IMAGEHLP_LINE64
		line.SizeOfStruct = size_of(win.IMAGEHLP_LINE64)
		ldisp: win.DWORD
		if win.SymGetLineFromAddrW64(process, pc, &ldisp, &line) && line.FileName != nil {
			w := ([^]u16)(rawptr(line.FileName))
			n := 0
			for n < FILE_NAME_CHARS && w[n] != 0 { n += 1 }
			fmt.sbprintf(b, "  %s:%d", narrow(w[:n]), line.LineNumber)
		}
	}
	strings.write_byte(b, '\n')
}
