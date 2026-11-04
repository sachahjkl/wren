package test_all

import "core:bytes"
import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:slice"
import "wb:tools/tooling"

// The default build links no external profiler (package trace: zero cost when off): build\wren.exe imports none of ETW's
// writing functions (the TraceLogging provider of the profile build) and holds none of the Tracy client (its TRACY_PORT).

PROFILED_PROGRAM :: "build/wren.exe"
ETW_IMPORTS :: [?]string{"EventRegister", "EventSetInformation", "EventWriteTransfer", "EventWrite"}
TRACY_MARK :: "TRACY_PORT"

// PE32+: where the headers say the import table is
@(private = "file") PE_OFFSET_AT :: 0x3c
@(private = "file") COFF_BYTES :: 24              // "PE\0\0" and the file header
@(private = "file") OPTIONAL_SIZE_AT :: 20         // in the file header, after the signature
@(private = "file") SECTIONS_COUNT_AT :: 6
@(private = "file") IMPORT_DIRECTORY_AT :: 120     // in the optional header of PE32+: the second data directory
@(private = "file") SECTION_BYTES :: 40
@(private = "file") IMPORT_DESCRIPTOR_BYTES :: 20
@(private = "file") ORDINAL_FLAG :: u64(1) << 63
@(private = "file") HINT_BYTES :: 2

// The names a PE32+ program imports by name, from every DLL; nil when it is not one.
pe_imported_names :: proc(image: []u8, allocator := context.allocator) -> []string {
	u16_at :: proc(b: []u8, at: int) -> u16 { v, _ := endian.get_u16(b[at:], .Little); return v }
	u32_at :: proc(b: []u8, at: int) -> u32 { v, _ := endian.get_u32(b[at:], .Little); return v }
	u64_at :: proc(b: []u8, at: int) -> u64 { v, _ := endian.get_u64(b[at:], .Little); return v }
	if len(image) < PE_OFFSET_AT + 4 { return nil }
	pe := int(u32_at(image, PE_OFFSET_AT))
	if pe + COFF_BYTES > len(image) || string(image[pe:pe + 4]) != "PE\x00\x00" { return nil }
	optional := pe + COFF_BYTES
	sections := optional + int(u16_at(image, pe + OPTIONAL_SIZE_AT))
	count := int(u16_at(image, pe + SECTIONS_COUNT_AT))
	// a relative address to its place in the file, through the section that holds it (-1: none)
	at :: proc(image: []u8, sections, count: int, rva: u32) -> int {
		for i in 0 ..< count {
			s := sections + i * SECTION_BYTES
			va, size, raw := u32_at(image, s + 12), u32_at(image, s + 16), u32_at(image, s + 20)
			if rva >= va && rva < va + size { return int(rva - va + raw) }
		}
		return -1
	}
	names := make([dynamic]string, allocator)
	d := at(image, sections, count, u32_at(image, optional + IMPORT_DIRECTORY_AT))
	for ; d >= 0 && d + IMPORT_DESCRIPTOR_BYTES <= len(image) && u32_at(image, d + 12) != 0; d += IMPORT_DESCRIPTOR_BYTES {
		lookup := u32_at(image, d)
		if lookup == 0 { lookup = u32_at(image, d + 16) }
		for th := at(image, sections, count, lookup); th >= 0 && th + 8 <= len(image); th += 8 {
			entry := u64_at(image, th)
			if entry == 0 { break }
			if entry & ORDINAL_FLAG != 0 { continue }
			n := at(image, sections, count, u32(entry)) + HINT_BYTES
			if n < HINT_BYTES { continue }
			end := bytes.index_byte(image[n:], 0)
			if end < 0 { break }
			append(&names, string(image[n:n + end]))
		}
	}
	return names[:]
}

task_profilers_absent :: proc(t: ^Task_Run) -> bool {
	image, err := os.read_entire_file(PROFILED_PROGRAM, context.allocator)
	if err != nil { tooling.say(t.log, fmt.tprintfln("%s cannot be read", PROFILED_PROGRAM)); return false }
	names := pe_imported_names(image)
	if len(names) == 0 { tooling.say(t.log, fmt.tprintfln("%s: no import table read", PROFILED_PROGRAM)); return false }
	good := true
	for e in ETW_IMPORTS {
		if slice.contains(names, e) { tooling.say(t.log, fmt.tprintfln("%s imports %s: the default build writes no ETW events (package trace, WREN_ETW)", PROFILED_PROGRAM, e)); good = false }
	}
	if bytes.contains(image, transmute([]u8)string(TRACY_MARK)) { tooling.say(t.log, fmt.tprintfln("%s holds the Tracy client (%s): the default build links none (WREN_TRACY)", PROFILED_PROGRAM, TRACY_MARK)); good = false }
	if good { tooling.say(t.log, fmt.tprintfln("%s: %d imports by name, none of ETW's writing, no Tracy client", PROFILED_PROGRAM, len(names))) }
	return good
}
