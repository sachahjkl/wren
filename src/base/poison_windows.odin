package base

// The heap's free and realloc of the whole executable (poison.odin): the import table of wren.exe holds the only address
// of HeapFree and HeapReAlloc that the Odin runtime, the Rust library and the static C runtime call through.

@(require) import "base:intrinsics"
@(require) import "core:sys/windows"

when POISON_MEMORY {

@(private) HEAP_REALLOC_IN_PLACE_ONLY :: 0x00000010
@(private) HEAP_SIZE_INVALID :: ~uint(0)
@(private) IMPORT_BY_ORDINAL :: u64(1) << 63
@(private) IMPORT_HINT_BYTES :: size_of(u16)

@(private) Import_Descriptor :: struct { names, time_stamp, forwarder, dll, slots: u32 }

@(private) Heap_Free :: #type proc "system" (heap: rawptr, flags: u32, p: rawptr) -> b32
@(private) Heap_Realloc :: #type proc "system" (heap: rawptr, flags: u32, p: rawptr, size: uint) -> rawptr
@(private) Heap_Alloc :: #type proc "system" (heap: rawptr, flags: u32, size: uint) -> rawptr
@(private) Heap_Size :: #type proc "system" (heap: rawptr, flags: u32, p: rawptr) -> uint

foreign import kernel32 "system:Kernel32.lib"
@(private, default_calling_convention = "system")
foreign kernel32 {
	HeapSize :: proc(heap: rawptr, flags: u32, p: rawptr) -> uint ---
	HeapAlloc :: proc(heap: rawptr, flags: u32, size: uint) -> rawptr ---
}

@(private) real_free: Heap_Free
@(private) real_realloc: Heap_Realloc

@(private) real_alloc: Heap_Alloc
@(private) real_size: Heap_Size

@(private)
heap_release :: proc "contextless" (heap, p: rawptr) { real_free(heap, 0, p) }

////////////////////////////////
// WREN_POISON_PAGES=1: every block on pages of its own, taken away when it is freed and never given out again, as the system's
// PageHeap does (which is a key of the machine's registry). Any read of a freed block faults on the spot, a plain number too.
// A page or two per block and a system call per allocation: for a run that looks for one thing.

@(private) GUARD_RESERVE :: uint(1) << 42
@(private) GUARD_PAGE :: uint(4096)
@(private) GUARD_HEADER :: uint(16)   // the block's size, before what the caller gets (the heap's alignment)
@(private) GUARD_ENV :: "WREN_POISON_PAGES"
@(private) GUARD_ENV_BYTES :: 8

@(private) guard_next, guard_end, guard_start: uint

@(private)
guard_owns :: #force_inline proc "contextless" (p: rawptr) -> bool { return uint(uintptr(p)) >= guard_start && uint(uintptr(p)) < guard_end }

@(private)
guard_pages :: #force_inline proc "contextless" (size: uint) -> uint { return (size + GUARD_HEADER + GUARD_PAGE - 1) / GUARD_PAGE }

@(private)
guard_alloc :: proc "contextless" (size: uint) -> rawptr {
	pages := guard_pages(size)
	block := intrinsics.atomic_add(&guard_next, (pages + 1) * GUARD_PAGE)   // (and a page of nothing after it)
	if block + pages * GUARD_PAGE >= guard_end { return nil }
	if windows.VirtualAlloc(rawptr(uintptr(block)), pages * GUARD_PAGE, windows.MEM_COMMIT, windows.PAGE_READWRITE) == nil { return nil }
	(^uint)(uintptr(block))^ = size
	return rawptr(uintptr(block + GUARD_HEADER))
}

@(private)
guard_free :: proc "contextless" (p: rawptr) {
	block := rawptr(uintptr(p) - uintptr(GUARD_HEADER))
	info: windows.MEMORY_BASIC_INFORMATION
	windows.VirtualQuery(block, &info, size_of(info))
	if info.State != windows.MEM_COMMIT { poison_fail("double free", p, 0) }
	windows.VirtualFree(block, guard_pages((^uint)(block)^) * GUARD_PAGE, windows.MEM_DECOMMIT)
}

@(private)
hooked_alloc :: proc "system" (heap: rawptr, flags: u32, size: uint) -> rawptr {
	if p := guard_alloc(size); p != nil { return p }
	return real_alloc(heap, flags, size)
}

@(private)
hooked_size :: proc "system" (heap: rawptr, flags: u32, p: rawptr) -> uint {
	if guard_owns(p) { return (^uint)(uintptr(p) - uintptr(GUARD_HEADER))^ }
	return real_size(heap, flags, p)
}

@(private)
hooked_free :: proc "system" (heap: rawptr, flags: u32, p: rawptr) -> b32 {
	if p == nil { return true }
	if poison_pointer(p) { poison_fail("double free", p, 0) }   // (the runtime read the block's start in the header of a freed block)
	if guard_owns(p) { guard_free(p); return true }
	size := HeapSize(heap, 0, p)
	if size == HEAP_SIZE_INVALID { poison_fail("a free of what the heap does not know", p, 0) }
	quarantine_put(heap, p, int(size))
	return true
}

@(private)
hooked_realloc :: proc "system" (heap: rawptr, flags: u32, p: rawptr, size: uint) -> rawptr {
	if flags & HEAP_REALLOC_IN_PLACE_ONLY != 0 { return guard_owns(p) ? nil : real_realloc(heap, flags, p, size) }
	old := HeapSize(heap, 0, p)
	if old == HEAP_SIZE_INVALID { poison_fail("a resize of what the heap does not know", p, 0) }
	if poison_in_quarantine(p) { poison_fail("a resize of a freed block", p, int(old)) }
	moved := HeapAlloc(heap, flags, size)
	if moved == nil { return nil }
	intrinsics.mem_copy_non_overlapping(moved, p, min(old, size))
	hooked_free(heap, 0, p)
	return moved
}

// Every import of the heap in the executable, whatever the DLL named (kernel32, an api set).
@(private, init)
poison_install :: proc "contextless" () {
	image := uintptr(windows.GetModuleHandleW(nil))
	nt := (^windows.IMAGE_NT_HEADERS64)(image + uintptr((^windows.IMAGE_DOS_HEADER)(image).e_lfanew))
	imports := ([^]Import_Descriptor)(image + uintptr(nt.OptionalHeader.ImportTable.VirtualAddress))
	pages := guard_begin()
	for d := 0; imports[d].dll != 0; d += 1 {
		names := ([^]u64)(image + uintptr(imports[d].names))
		slots := ([^]uintptr)(image + uintptr(imports[d].slots))
		for i := 0; names[i] != 0; i += 1 {
			if names[i] & IMPORT_BY_ORDINAL != 0 { continue }
			switch cstring(rawptr(image + uintptr(names[i]) + IMPORT_HINT_BYTES)) {
			case "HeapFree":
				real_free = Heap_Free(rawptr(slots[i]))
				import_write(&slots[i], uintptr(rawptr(hooked_free)))
			case "HeapReAlloc":
				real_realloc = Heap_Realloc(rawptr(slots[i]))
				import_write(&slots[i], uintptr(rawptr(hooked_realloc)))
			case "HeapAlloc":
				if !pages { continue }
				real_alloc = Heap_Alloc(rawptr(slots[i]))
				import_write(&slots[i], uintptr(rawptr(hooked_alloc)))
			case "HeapSize":
				if !pages { continue }
				real_size = Heap_Size(rawptr(slots[i]))
				import_write(&slots[i], uintptr(rawptr(hooked_size)))
			}
		}
	}
}

// Whether the run asks for pages of their own (WREN_POISON_PAGES); their address space is reserved then.
@(private)
guard_begin :: proc "contextless" () -> bool {
	value: [GUARD_ENV_BYTES]u16
	if windows.GetEnvironmentVariableW(windows.L(GUARD_ENV), &value[0], GUARD_ENV_BYTES) == 0 { return false }
	region := windows.VirtualAlloc(nil, GUARD_RESERVE, windows.MEM_RESERVE, windows.PAGE_NOACCESS)
	if region == nil { return false }
	guard_start = uint(uintptr(region))
	guard_next = guard_start
	guard_end = guard_start + GUARD_RESERVE
	return true
}

@(private)
import_write :: proc "contextless" (slot: ^uintptr, value: uintptr) {
	old: u32
	windows.VirtualProtect(slot, size_of(uintptr), windows.PAGE_READWRITE, &old)
	slot^ = value
	windows.VirtualProtect(slot, size_of(uintptr), old, &old)
}

} // when POISON_MEMORY
