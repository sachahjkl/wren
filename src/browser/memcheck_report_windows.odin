package browser

// The two heap / virtual-memory diagnostics of the memory-check driver (memcheck.odin's `vmmap` step): they walk the
// process's Windows heaps and committed regions, which has no portable equivalent, so they are a Windows-only file with
// an honest stub beside it (memcheck_report_other.odin). Each writes a report file for the endurance run to read.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import win "core:sys/windows"

foreign import kernel32_mem "system:Kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32_mem {
	@(link_name = "GetProcessHeaps") mem_GetProcessHeaps :: proc(n: u32, heaps: [^]win.HANDLE) -> u32 ---
	@(link_name = "HeapLock") mem_HeapLock :: proc(heap: win.HANDLE) -> win.BOOL ---
	@(link_name = "HeapUnlock") mem_HeapUnlock :: proc(heap: win.HANDLE) -> win.BOOL ---
	@(link_name = "HeapWalk") mem_HeapWalk :: proc(heap: win.HANDLE, e: ^Mem_Heap_Entry) -> win.BOOL ---
	@(link_name = "VirtualQuery") mem_VirtualQuery :: proc(address: uintptr, info: ^Mem_Basic_Info, length: uint) -> uint ---
}

foreign import ntdll_mem "system:ntdll.lib"

@(default_calling_convention = "system", private = "file")
foreign ntdll_mem {
	@(link_name = "NtQueryInformationThread") mem_NtQueryInformationThread :: proc(thread: win.HANDLE, class: u32, info: rawptr, length: u32, returned: ^u32) -> i32 ---
}

@(private = "file") MEM_COMMIT :: 0x1000
@(private = "file") MEM_PRIVATE :: 0x20000
@(private = "file") MEM_MAPPED :: 0x40000
@(private = "file") MEM_IMAGE :: 0x1000000
@(private = "file") MEM_WRITABLE :: 0xCC   // PAGE_READWRITE, PAGE_WRITECOPY and their executable forms
@(private = "file") MEM_IMAGE_SHOWN_FROM :: 1 << 20
@(private = "file") MEM_THREAD_QUERY :: 0x0040   // THREAD_QUERY_INFORMATION
// Only a Wasm linear memory reserves this much at once (wasm.wasmtime.static_memory_bytes).
@(private = "file") WASM_RESERVE_FROM :: 1 << 30

// The start of a thread's environment block: NT_TIB, whose third word is the end of the stack.
@(private = "file")
Mem_Teb :: struct { exception_list, stack_base, stack_limit: uintptr }

// THREAD_BASIC_INFORMATION
@(private = "file")
Mem_Thread_Info :: struct {
	exit_status: i32,
	teb:         ^Mem_Teb,
	client_id:   [2]uintptr,
	affinity:    uintptr,
	priority, base_priority: i32,
}

@(private = "file")
Mem_Basic_Info :: struct {
	base, alloc_base:     uintptr,
	alloc_protect:        u32,
	region_size:          uint,
	state, protect, kind: u32,
}

@(private = "file")
Mem_Heap_Entry :: struct {
	data:             rawptr,
	size:             u32,
	overhead, region: u8,
	flags:            u16,
	_:                [3]uintptr,   // the block / region union
}

// The live blocks of the process heaps grouped by exact size (the biggest groups first): what the native libraries
// hold that the tracker does not see. Slow; a diagnostic for the endurance run.
memory_heap_report :: proc(file: string, top := MEMORY_REPORT_TOP) {
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

// The biggest private committed allocations (one line each: base, committed MB, kind) and what the kinds add up to, to
// find what a number is made of. A kind: a process heap's segment, a thread's stack, a Wasm linear memory (what reserves
// WASM_RESERVE_FROM of address space), compiled code, or nothing known.
memory_map_report :: proc(file: string, top := MEMORY_REPORT_TOP) {
	Kind :: enum u8 { Other, Heap, Stack, Linear, Exec }
	Region :: struct { base: uintptr, committed: i64, reserved: i64, kind: Kind, heap: int }
	regions := make(map[uintptr]Region, 256, context.temp_allocator)
	images := make(map[uintptr]i64, 64, context.temp_allocator)   // what each module may write: the system charges it to the process as private bytes
	mapped: i64
	mbi: Mem_Basic_Info
	addr: uintptr
	for mem_VirtualQuery(addr, &mbi, size_of(mbi)) != 0 {
		writable := mbi.state == MEM_COMMIT && mbi.protect & MEM_WRITABLE != 0
		if mbi.kind == MEM_IMAGE && writable { images[mbi.alloc_base] += i64(mbi.region_size) }
		if mbi.kind == MEM_MAPPED && writable { mapped += i64(mbi.region_size) }
		if mbi.kind == MEM_PRIVATE && mbi.alloc_base != 0 {
			r := regions[mbi.alloc_base]
			r.base = mbi.alloc_base
			r.reserved += i64(mbi.region_size)
			if mbi.state == MEM_COMMIT {
				r.committed += i64(mbi.region_size)
				if mbi.protect & 0xF0 != 0 { r.kind = .Exec }
			}
			regions[mbi.alloc_base] = r
		}
		next := mbi.base + uintptr(mbi.region_size)
		if next <= addr { break }
		addr = next
	}
	mark :: proc(regions: ^map[uintptr]Region, at: uintptr, kind: Kind, heap := 0) {
		m: Mem_Basic_Info
		if mem_VirtualQuery(at, &m, size_of(m)) == 0 { return }
		if r, ok := &regions[m.alloc_base]; ok { r.kind, r.heap = kind, heap }
	}
	heaps: [64]win.HANDLE
	n := min(int(mem_GetProcessHeaps(len(heaps), &heaps[0])), len(heaps))
	for i in 0 ..< n {
		e: Mem_Heap_Entry
		mem_HeapLock(heaps[i])
		for mem_HeapWalk(heaps[i], &e) { if e.data != nil { mark(&regions, uintptr(e.data), .Heap, i + 1) } }
		mem_HeapUnlock(heaps[i])
	}
	if snap := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPTHREAD, 0); snap != win.INVALID_HANDLE_VALUE {
		defer win.CloseHandle(snap)
		te := win.THREADENTRY32{dwSize = size_of(win.THREADENTRY32)}
		for ok := win.Thread32First(snap, &te); ok; ok = win.Thread32Next(snap, &te) {
			if te.th32OwnerProcessID != win.GetCurrentProcessId() { continue }
			h := win.OpenThread(MEM_THREAD_QUERY, false, te.th32ThreadID)
			if h == nil { continue }
			info: Mem_Thread_Info
			if mem_NtQueryInformationThread(h, 0, &info, size_of(info), nil) == 0 && info.teb != nil {
				mark(&regions, info.teb.stack_limit, .Stack)
			}
			win.CloseHandle(h)
		}
	}
	list := make([dynamic]Region, 0, len(regions), context.temp_allocator)
	totals: [Kind]i64
	counts: [Kind]int
	for _, r in regions {
		if r.committed == 0 { continue }
		x := r
		if x.kind == .Other && x.reserved >= WASM_RESERVE_FROM { x.kind = .Linear }
		totals[x.kind] += x.committed
		counts[x.kind] += 1
		append(&list, x)
	}
	slice.sort_by(list[:], proc(a, b: Region) -> bool { return a.committed > b.committed })
	b := strings.builder_make(context.temp_allocator)
	for total, k in totals { fmt.sbprintf(&b, "%v\t%.2f MB\t%d\n", k, f64(total) / 1048576, counts[k]) }
	fmt.sbprintf(&b, "Mapped\t%.2f MB\n", f64(mapped) / 1048576)
	for base, bytes in images {
		if bytes < MEM_IMAGE_SHOWN_FROM { continue }
		name: [win.MAX_PATH]u16
		n := win.GetModuleFileNameW(win.HMODULE(base), &name[0], len(name))
		text, _ := win.utf16_to_utf8(name[:n], context.temp_allocator)
		fmt.sbprintf(&b, "Image\t%.2f MB\t%s\n", f64(bytes) / 1048576, text)
	}
	for r, i in list {
		if i >= top { break }
		fmt.sbprintf(&b, "%x\t%.2f MB committed\t%.2f MB reserved\t%v %d\n", r.base, f64(r.committed) / 1048576, f64(r.reserved) / 1048576, r.kind, r.heap)
	}
	_ = os.write_entire_file(file, transmute([]byte)strings.to_string(b))
}
