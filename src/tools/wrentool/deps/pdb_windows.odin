#+build windows
package deps

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"

// A program's PDB through DbgHelp: the function and the source line at an address.

@(private = "file") SYMOPT_UNDNAME_LOAD_LINES :: 0x2 | 0x10
@(private = "file") SYM_NAME_CHARS :: 512
@(private = "file") SESSION_HANDLE :: 0x57524558

@(private = "file")
Symbol_Info :: struct {
	size_of_struct, type_index: u32,
	reserved:                   [2]u64,
	index, size:                u32,
	mod_base:                   u64,
	flags:                      u32,
	value, address:             u64,
	register, scope, tag:       u32,
	name_len, max_name_len:     u32,
	name:                       [SYM_NAME_CHARS]u16,
}

@(private = "file")
Line_Info :: struct {
	size_of_struct: u32,
	key:            rawptr,
	line_number:    u32,
	file_name:      [^]u16,
	address:        u64,
}

foreign import dbghelp "system:DbgHelp.lib"
@(default_calling_convention = "system", private = "file")
foreign dbghelp {
	SymSetOptions :: proc(options: u32) -> u32 ---
	SymInitializeW :: proc(process: win.HANDLE, path: win.LPCWSTR, invade: win.BOOL) -> win.BOOL ---
	SymLoadModuleExW :: proc(process, file: win.HANDLE, image, module: win.LPCWSTR, base: u64, size: u32, data: rawptr, flags: u32) -> u64 ---
	SymFromAddrW :: proc(process: win.HANDLE, address: u64, displacement: ^u64, symbol: ^Symbol_Info) -> win.BOOL ---
	SymGetLineFromAddrW64 :: proc(process: win.HANDLE, address: u64, displacement: ^u32, line: ^Line_Info) -> win.BOOL ---
	SymCleanup :: proc(process: win.HANDLE) -> win.BOOL ---
}

Pdb_Session :: struct { handle: win.HANDLE }

pdb_open :: proc(exe: string, base: u64, size: u64) -> (s: Pdb_Session, why: string) {
	full := full_path(exe)
	s.handle = win.HANDLE(uintptr(SESSION_HANDLE))
	SymSetOptions(SYMOPT_UNDNAME_LOAD_LINES)
	if !SymInitializeW(s.handle, win.utf8_to_wstring(filepath.dir(full), context.temp_allocator), false) { return s, "SymInitialize failed" }
	if SymLoadModuleExW(s.handle, nil, win.utf8_to_wstring(full, context.temp_allocator), nil, base, u32(size), nil, 0) == 0 { return s, fmt.tprintf("DbgHelp cannot load %s", exe) }
	return s, ""
}

pdb_close :: proc(s: ^Pdb_Session) { SymCleanup(s.handle) }

// "name+0xoffset  file:line", or "" when no function holds it.
pdb_name :: proc(s: ^Pdb_Session, address: u64) -> string {
	sym: Symbol_Info
	sym.size_of_struct = u32(size_of(Symbol_Info) - SYM_NAME_CHARS * size_of(u16) + size_of(u16))
	sym.max_name_len = SYM_NAME_CHARS
	displacement: u64
	if !SymFromAddrW(s.handle, address, &displacement, &sym) { return "" }
	wide, _ := win.utf16_to_utf8(sym.name[:sym.name_len], context.temp_allocator)
	name, file := format_odin_symbol(wide)
	if file != "" { name = fmt.tprintf("%s  (%s)", name, file) }
	line := Line_Info{size_of_struct = size_of(Line_Info)}
	line_displacement: u32
	if !SymGetLineFromAddrW64(s.handle, address, &line_displacement, &line) { return fmt.tprintf("%s+0x%X", name, displacement) }
	where_, _ := win.wstring_to_utf8(win.wstring(line.file_name), -1, context.temp_allocator)
	return strings.clone(fmt.tprintf("%s+0x%X  %s:%d", name, displacement, where_, line.line_number), context.temp_allocator)
}
