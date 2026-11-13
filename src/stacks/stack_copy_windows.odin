#+build windows
package stacks

// A thread of this process, read from a distance: the browser's sampling profiler (prof_windows.odin) and a tool's hang dump
// (jspage, WREN_HANG_DUMP_MS) stop a thread, copy its stack and walk the copy after it runs again. The toolkit's gt:crash walks
// stacks the same way in its handler but keeps that walker to itself, so Wren keeps this one for its own threads.

import "core:fmt"
import win "core:sys/windows"

// How much of a stack is copied; what a frame reads past the end of the copy stays in the buffer.
STACK_COPY_MOST :: 1 << 20
@(private = "file") STACK_COPY_SLACK :: 1 << 20
@(private = "file") FRAME_REGISTER_BYTE :: 3   // of UNWIND_INFO: the frame register in its low bits
@(private = "file") FRAME_REGISTER_MASK :: 0xF
@(private = "file") DUMP_FRAMES :: 64

@(private = "file")
RUNTIME_FUNCTION :: struct {
	begin, end, unwind: u32,
}

foreign import kernel32_copy "system:Kernel32.lib"

@(private = "file", default_calling_convention = "system")
foreign kernel32_copy {
	RtlLookupFunctionEntry :: proc(ControlPc: u64, ImageBase: ^u64, HistoryTable: rawptr) -> ^RUNTIME_FUNCTION ---
	RtlVirtualUnwind :: proc(HandlerType: u32, ImageBase: u64, ControlPc: u64, FunctionEntry: ^RUNTIME_FUNCTION, ContextRecord: ^win.CONTEXT, HandlerData: ^rawptr, EstablisherFrame: ^u64, ContextPointers: rawptr) -> rawptr ---
}

// A thread's stack, copied from its stack pointer up. A stack is walked in a copy, never in place: the walk of a stack that is not what it should be (code without
// unwind tables took one word for a return address and every frame after it is wrong) reads through whatever it found, and RtlVirtualUnwind has no way to say it
// could not. In place that ended the process (WREN_SAMPLE_STACK on cnn.com), in the copy it ends the walk. And a sampler walks after the thread it stopped has
// gone on: the lookup of an unwind table takes a lock of the loader, which the stopped thread may hold.
Stack_Copy :: struct {
	bytes:     [^]u8,
	low, high: u64,   // what was copied, in the thread's addresses
}

stack_copy_init :: proc "contextless" (c: ^Stack_Copy) -> bool {
	c.bytes = ([^]u8)(win.VirtualAlloc(nil, STACK_COPY_MOST + STACK_COPY_SLACK, win.MEM_COMMIT | win.MEM_RESERVE, win.PAGE_READWRITE))
	return c.bytes != nil
}

stack_copy_destroy :: proc "contextless" (c: ^Stack_Copy) {
	if c.bytes != nil { win.VirtualFree(c.bytes, 0, win.MEM_RELEASE) }
	c^ = {}
}

// Copies the stack `rsp` is on, up to the end of its committed part. The thread is stopped. Nothing of it is touched but through
// ReadProcessMemory, which fails where a read would fault. False: the stack pointer points at nothing that can be read.
stack_copy_take :: proc "contextless" (c: ^Stack_Copy, rsp: u64) -> bool {
	c.low, c.high = 0, 0
	if c.bytes == nil { return false }
	info: win.MEMORY_BASIC_INFORMATION
	if win.VirtualQuery(rawptr(uintptr(rsp)), &info, size_of(info)) == 0 || info.State != win.MEM_COMMIT { return false }
	end := u64(uintptr(info.BaseAddress)) + u64(info.RegionSize)
	size := min(end - rsp, STACK_COPY_MOST)
	got: uint
	if !win.ReadProcessMemory(win.GetCurrentProcess(), rawptr(uintptr(rsp)), c.bytes, uint(size), &got) || got == 0 { return false }
	c.low, c.high = rsp, rsp + u64(got)
	return true
}

// The return addresses of the stack in `c`, innermost first, starting from the registers `ctx` (which the walk changes). The count written in `pcs`.
stack_walk :: proc "contextless" (c: ^Stack_Copy, ctx: ^win.CONTEXT, pcs: []u64) -> int {
	stack_rebase(c, ctx)
	n := 0
	for n < len(pcs) && ctx.Rip != 0 {
		pcs[n] = ctx.Rip
		n += 1
		if !stack_step(c, ctx) { break }
	}
	return n
}

// What points into the stack points into the copy, whatever register it came back in.
@(private = "file")
stack_rebase :: proc "contextless" (c: ^Stack_Copy, ctx: ^win.CONTEXT) {
	for r in ([?]^u64{&ctx.Rsp, &ctx.Rbp, &ctx.Rbx, &ctx.Rsi, &ctx.Rdi, &ctx.R12, &ctx.R13, &ctx.R14, &ctx.R15}) {
		if r^ >= c.low && r^ < c.high { r^ = r^ - c.low + u64(uintptr(c.bytes)) }
	}
}

@(private = "file")
stack_holds :: proc "contextless" (c: ^Stack_Copy, at: u64) -> bool {
	buffer := u64(uintptr(c.bytes))
	return at >= buffer && at + size_of(u64) <= buffer + (c.high - c.low)
}

// From a frame to its caller. False: the walk went out of the stack, or would read through a register that is not on it.
@(private = "file")
stack_step :: proc "contextless" (c: ^Stack_Copy, ctx: ^win.CONTEXT) -> bool {
	if !stack_holds(c, ctx.Rsp) { return false }
	image: u64
	fn := RtlLookupFunctionEntry(ctx.Rip, &image, nil)
	if fn == nil {
		// a leaf, or code without tables: the return address is on top of the stack
		ctx.Rip = (^u64)(uintptr(ctx.Rsp))^
		ctx.Rsp += size_of(u64)
	} else {
		// (registers in the order of the context, Rax first: the numbers of the unwind codes)
		frame := int(([^]u8)(uintptr(image + u64(fn.unwind)))[FRAME_REGISTER_BYTE] & FRAME_REGISTER_MASK)
		if frame != 0 && !stack_holds(c, ([^]u64)(&ctx.Rax)[frame]) { return false }
		handler_data: rawptr
		establisher: u64
		RtlVirtualUnwind(0, image, ctx.Rip, fn, ctx, &handler_data, &establisher, nil)
	}
	stack_rebase(c, ctx)
	return true
}

// A tool that seems stuck: the call stack of another thread of this process (suspended while its stack is copied), named with the
// PDB, on standard output and standard error. `thread` needs THREAD_SUSPEND_RESUME and THREAD_GET_CONTEXT.
dump_thread :: proc(thread: win.HANDLE, what: string) {
	stack: Stack_Copy
	if !stack_copy_init(&stack) { emit("*** dump: no memory for the stack"); return }
	defer stack_copy_destroy(&stack)
	if win.SuspendThread(thread) == ~win.DWORD(0) { emit("*** dump: cannot suspend the thread"); return }
	ctx: win.CONTEXT
	ctx.ContextFlags = 0x0010000B   // CONTEXT_FULL (AMD64)
	got := win.GetThreadContext(thread, &ctx)
	if got { stack_copy_take(&stack, ctx.Rsp) }
	win.ResumeThread(thread)
	if !got { emit("*** dump: cannot read the thread's context"); return }
	pcs: [DUMP_FRAMES]u64
	n := stack_walk(&stack, &ctx, pcs[:])
	process := win.GetCurrentProcess()
	win.SymSetOptions(win.SYMOPT_LOAD_LINES | win.SYMOPT_DEFERRED_LOADS)
	win.SymInitialize(process, nil, true)
	buf: [8192]u8
	emit(fmt.bprintf(buf[:], "\n*** stack of %s", what))
	for pc, i in pcs[:n] {
		raw: [size_of(win.SYMBOL_INFOW) + SYMBOL_NAME_CHARS * size_of(u16)]u8
		sym := (^win.SYMBOL_INFOW)(&raw[0])
		sym.SizeOfStruct = size_of(win.SYMBOL_INFOW)
		sym.MaxNameLen = SYMBOL_NAME_CHARS
		disp: u64
		if win.SymFromAddrW(process, pc, &disp, sym) {
			name, _ := win.utf16_to_utf8(([^]u16)(&sym.Name[0])[:sym.NameLen], context.temp_allocator)
			emit(fmt.bprintf(buf[:], "  #%02d %s+0x%X", i, name, disp))
		} else {
			emit(fmt.bprintf(buf[:], "  #%02d 0x%X", i, pc))
		}
	}
	emit("*** end of the stack\n")
}

// (both: test_all keeps a tool's standard output, a person sees its standard error)
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
