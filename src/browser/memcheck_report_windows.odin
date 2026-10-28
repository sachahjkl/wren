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

@(private = "file") MEM_COMMIT :: 0x1000
@(private = "file") MEM_PRIVATE :: 0x20000

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
