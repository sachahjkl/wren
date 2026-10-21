package crashtrace

// A crash of a test tool (an access violation, an illegal instruction, a stack overflow...) prints the faulting
// thread's call stack with function names, files and lines (DbgHelp and the PDB next to the exe: build the tool with
// -debug, -o:speed keeps working) on standard output and standard error, then lets the process die as before. Without
// it a crash under load left only a "Fault offset" in the Windows event log. Importing the package installs it.
//
// The stack is unwound from the exception's context with the unwind tables of the modules (RtlVirtualUnwind; Wasmtime
// registers those of the code it compiles). Only the faulting thread is shown.

import "base:runtime"
import "core:fmt"
import win "core:sys/windows"

@(private = "file")
MAX_FRAMES :: 64

@(private = "file")
RUNTIME_FUNCTION :: struct {
	begin, end, unwind: u32,
}

foreign import kernel32 "system:Kernel32.lib"

@(private = "file", default_calling_convention = "system")
foreign kernel32 {
	RtlLookupFunctionEntry :: proc(ControlPc: u64, ImageBase: ^u64, HistoryTable: rawptr) -> ^RUNTIME_FUNCTION ---
	RtlVirtualUnwind :: proc(HandlerType: u32, ImageBase: u64, ControlPc: u64, FunctionEntry: ^RUNTIME_FUNCTION, ContextRecord: ^win.CONTEXT, HandlerData: ^rawptr, EstablisherFrame: ^u64, ContextPointers: rawptr) -> rawptr ---
}

@(private = "file")
installed: bool

@(init, private = "file")
install :: proc "contextless" () {
	if installed { return }
	installed = true
	win.SetUnhandledExceptionFilter(on_crash)
}

@(private = "file")
code_name :: proc(code: u32) -> string {
	switch code {
	case 0xC0000005: return "access violation"
	case 0xC000001D: return "illegal instruction (an Odin assertion or bounds check)"
	case 0xC00000FD: return "stack overflow"
	case 0xC0000094: return "integer division by zero"
	case 0xC0000409: return "stack buffer overrun / fast fail"
	case 0x80000003: return "breakpoint"
	}
	return "exception"
}

@(private = "file")
on_crash :: proc "system" (info: ^win.EXCEPTION_POINTERS) -> win.LONG {
	context = runtime.default_context()
	rec := info.ExceptionRecord
	ctx := info.ContextRecord^   // unwound in a copy
	process := win.GetCurrentProcess()
	win.SymSetOptions(win.SYMOPT_LOAD_LINES | win.SYMOPT_DEFERRED_LOADS)
	win.SymInitialize(process, nil, true)

	buf: [8192]u8
	b := fmt.bprintf(buf[:], "\n*** crash: %s (0x%08X) at 0x%X, thread %d", code_name(u32(rec.ExceptionCode)), u32(rec.ExceptionCode), uintptr(rec.ExceptionAddress), win.GetCurrentThreadId())
	if rec.ExceptionCode == 0xC0000005 && rec.NumberParameters >= 2 {
		kind := uintptr(rec.ExceptionInformation[0])
		b = fmt.bprintf(buf[:], "%s, %s address 0x%X", b, kind == 0 ? "reading" : (kind == 1 ? "writing" : "executing"), uintptr(rec.ExceptionInformation[1]))
	}
	emit(b)

	for i in 0 ..< MAX_FRAMES {
		pc := ctx.Rip
		if pc == 0 { break }
		emit(frame_line(buf[:], process, i, pc))
		image_base: u64
		fn := RtlLookupFunctionEntry(pc, &image_base, nil)
		if fn == nil {
			// a leaf function: the return address is on top of the stack
			if ctx.Rsp == 0 { break }
			ctx.Rip = (^u64)(uintptr(ctx.Rsp))^
			ctx.Rsp += 8
		} else {
			handler_data: rawptr
			establisher: u64
			RtlVirtualUnwind(0, image_base, pc, fn, &ctx, &handler_data, &establisher, nil)
		}
	}
	emit("*** end of the stack\n")
	return 0   // EXCEPTION_CONTINUE_SEARCH: the process dies as it would have (exit code, event log)
}

@(private = "file")
frame_line :: proc(buf: []u8, process: win.HANDLE, i: int, pc: u64) -> string {
	SYM_NAME :: 256
	raw: [size_of(win.SYMBOL_INFOW) + SYM_NAME * 2]u8
	sym := (^win.SYMBOL_INFOW)(&raw[0])
	sym.SizeOfStruct = size_of(win.SYMBOL_INFOW)
	sym.MaxNameLen = SYM_NAME
	disp: u64
	name := "?"
	name_buf: [SYM_NAME * 3]u8
	if win.SymFromAddrW(process, pc, &disp, sym) {
		w := ([^]u16)(&sym.Name[0])[:sym.NameLen]
		n := 0
		for c in w { if n < len(name_buf) - 1 { name_buf[n] = c < 128 ? u8(c) : '?'; n += 1 } }
		name = string(name_buf[:n])
	}
	line: win.IMAGEHLP_LINE64
	line.SizeOfStruct = size_of(win.IMAGEHLP_LINE64)
	ldisp: win.DWORD
	file_buf: [512]u8
	file := ""
	if win.SymGetLineFromAddrW64(process, pc, &ldisp, &line) && line.FileName != nil {
		w := ([^]u16)(rawptr(line.FileName))
		n := 0
		for n < len(file_buf) - 1 && w[n] != 0 { file_buf[n] = w[n] < 128 ? u8(w[n]) : '?'; n += 1 }
		file = string(file_buf[:n])
	}
	if file != "" { return fmt.bprintf(buf, "  #%02d 0x%X %s+0x%X  %s:%d", i, pc, name, disp, file, line.LineNumber) }
	return fmt.bprintf(buf, "  #%02d 0x%X %s+0x%X", i, pc, name, disp)
}

// On standard output (where test_all keeps the tools' reports) and standard error, with nothing buffered.
@(private = "file")
emit :: proc(s: string) {
	for h in ([2]win.DWORD{win.STD_OUTPUT_HANDLE, win.STD_ERROR_HANDLE}) {
		out := win.GetStdHandle(h)
		if out == nil || out == win.INVALID_HANDLE_VALUE { continue }
		written: win.DWORD
		win.WriteFile(out, raw_data(s), win.DWORD(len(s)), &written, nil)
		win.WriteFile(out, raw_data(string("\n")), 1, &written, nil)
	}
}
