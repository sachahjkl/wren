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

foreign import kernel32 "system:Kernel32.lib"
@(private, default_calling_convention = "system")
foreign kernel32 {
	HeapSize :: proc(heap: rawptr, flags: u32, p: rawptr) -> uint ---
	HeapAlloc :: proc(heap: rawptr, flags: u32, size: uint) -> rawptr ---
}

@(private) real_free: Heap_Free
@(private) real_realloc: Heap_Realloc

@(private)
heap_release :: proc "contextless" (heap, p: rawptr) { real_free(heap, 0, p) }

@(private)
hooked_free :: proc "system" (heap: rawptr, flags: u32, p: rawptr) -> b32 {
	if p == nil { return true }
	if poison_pointer(p) { poison_fail("double free", p, 0) }   // (the runtime read the block's start in the header of a freed block)
	size := HeapSize(heap, 0, p)
	if size == HEAP_SIZE_INVALID { poison_fail("a free of what the heap does not know", p, 0) }
	quarantine_put(heap, p, int(size))
	return true
}

@(private)
hooked_realloc :: proc "system" (heap: rawptr, flags: u32, p: rawptr, size: uint) -> rawptr {
	if flags & HEAP_REALLOC_IN_PLACE_ONLY != 0 { return real_realloc(heap, flags, p, size) }
	old := HeapSize(heap, 0, p)
	if old == HEAP_SIZE_INVALID { poison_fail("a resize of what the heap does not know", p, 0) }
	if poison_in_quarantine(p) { poison_fail("a resize of a freed block", p, int(old)) }
	moved := HeapAlloc(heap, flags, size)
	if moved == nil { return nil }
	intrinsics.mem_copy_non_overlapping(moved, p, min(old, size))
	hooked_free(heap, 0, p)
	return moved
}

// Every import of HeapFree and HeapReAlloc in the executable, whatever the DLL named (kernel32, an api set).
@(private, init)
poison_install :: proc "contextless" () {
	image := uintptr(windows.GetModuleHandleW(nil))
	nt := (^windows.IMAGE_NT_HEADERS64)(image + uintptr((^windows.IMAGE_DOS_HEADER)(image).e_lfanew))
	imports := ([^]Import_Descriptor)(image + uintptr(nt.OptionalHeader.ImportTable.VirtualAddress))
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
			}
		}
	}
}

@(private)
import_write :: proc "contextless" (slot: ^uintptr, value: uintptr) {
	old: u32
	windows.VirtualProtect(slot, size_of(uintptr), windows.PAGE_READWRITE, &old)
	slot^ = value
	windows.VirtualProtect(slot, size_of(uintptr), old, &old)
}

} // when POISON_MEMORY
