package deps

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:tools/tooling"

// The symbols of a build: the linker's map (wrentool build links with /MAP), named by the build's fingerprint, and what reads them.
// A release has no PDB (-debug would change the program), so a crash report of a release names no function of Wren in the process. The map names every function (Odin writes "pkg::proc" and, for a
// private one, "pkg::[file.odin]::proc") with its address; the report gives the build's fingerprint and the module's base (src/tools/crashtrace), and this turns the frames' addresses into functions.
// The fingerprint is the PE header's link time stamp and image size, "%08X%X" (as a symbol server keys an executable): every link makes a new one, signing does not change it.
//   wrentool symbols -Publish build\wren.exe [-Store]     after each link: wren.map becomes wren-<fingerprint>.map; -Store (release builds) also copies it to build\symbols, which keeps the latest
//   wrentool symbols -Fingerprint <exe>
//   wrentool crash-symbolize <report .txt or .dmp> [-Symbols folder or .map] [-Exe exe with its PDB]     Linux: <report.txt> -Exe <executable>
//   wrentool symbolize -Exe <exe> <offset>...             the function and line at an offset of a module, with its PDB (the "Fault offset" of the event log)

SYMBOL_STORE :: "build/symbols"
SYMBOL_STORE_KEEP :: 20
// A map older than its exe by more than this is not this link's.
MAP_OLDER_SECONDS :: 300
PE_READ_BYTES :: 4096
PE_NT_OFFSET :: 0x3C
PE_STAMP_OFFSET :: 8
PE_SIZE_OF_IMAGE_OFFSET :: 24 + 56
PE_SIGNATURE :: 0x00004550
PE_DEFAULT_BASE :: u64(0x140000000)
FINGERPRINT_MIN :: 9
FINGERPRINT_MAX :: 16
MAP_SEARCH_DEPTH :: 2
MD_STREAM_MODULES :: 4
MD_STREAM_EXCEPTION :: 6
MD_MODULE_BYTES :: 108
MD_HEADER_BYTES :: 32
MD_DIR_ENTRY_BYTES :: 12

fingerprint_of :: proc(path: string) -> (fp: string, ok: bool) {
	f, err := os.open(path)
	if err != nil { return "", false }
	defer os.close(f)
	buf: [PE_READ_BYTES]u8
	n, _ := os.read(f, buf[:])
	if n < PE_NT_OFFSET + 4 || buf[0] != 'M' || buf[1] != 'Z' { return "", false }
	nt := int(u32_at(buf[:], PE_NT_OFFSET))
	if nt + PE_SIZE_OF_IMAGE_OFFSET + 4 > n || u32_at(buf[:], nt) != PE_SIGNATURE { return "", false }
	return fmt.tprintf("%08X%X", u32_at(buf[:], nt + PE_STAMP_OFFSET), u32_at(buf[:], nt + PE_SIZE_OF_IMAGE_OFFSET)), true
}

@(private) u32_at :: proc(b: []u8, at: int) -> u32 { return u32(b[at]) | u32(b[at + 1]) << 8 | u32(b[at + 2]) << 16 | u32(b[at + 3]) << 24 }
@(private) u64_at :: proc(b: []u8, at: int) -> u64 { return u64(u32_at(b, at)) | u64(u32_at(b, at + 4)) << 32 }

is_hex :: proc(s: string) -> bool {
	if s == "" { return false }
	for c in transmute([]u8)s { if base.hex_value(c) < 0 { return false } }
	return true
}

// <stem>-<fingerprint>.map.
@(private)
map_of_stem :: proc(name, stem: string) -> bool {
	if !strings.has_prefix(name, fmt.tprintf("%s-", stem)) || !strings.has_suffix(name, ".map") { return false }
	fp := name[len(stem) + 1:len(name) - len(".map")]
	return len(fp) >= FINGERPRINT_MIN && len(fp) <= FINGERPRINT_MAX && is_hex(fp)
}

// A link's map named by its fingerprint. Text: where it went.
publish_symbols :: proc(exe: string, store: bool) -> (named: string, ok: bool) {
	dir := filepath.dir(exe)
	stem := filepath.stem(exe)
	map_file := fmt.tprintf("%s/%s.map", dir, stem)
	if !os.exists(map_file) { fmt.eprintfln("error: %s is not there (wrentool build links with /MAP)", map_file); return "", false }
	fp, good := fingerprint_of(exe)
	if !good { fmt.eprintfln("error: %s is not a PE file", exe); return "", false }
	mt, _ := tooling.modified(map_file)
	et, _ := tooling.modified(exe)
	if et._nsec - mt._nsec > MAP_OLDER_SECONDS * 1_000_000_000 { fmt.eprintfln("error: %s is older than %s (not this link's)", map_file, exe); return "", false }
	named = fmt.tprintf("%s/%s-%s.map", dir, stem, fp)
	_ = os.remove(named)
	if os.rename(map_file, named) != nil { fmt.eprintfln("error: %s cannot be named", map_file); return "", false }
	entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
	base_name := filepath.base(named)
	for e in entries { if map_of_stem(e.name, stem) && e.name != base_name { _ = os.remove(e.fullpath) } }
	if store {
		_ = os.make_directory_all(SYMBOL_STORE)
		_ = os.copy_file(fmt.tprintf("%s/%s", SYMBOL_STORE, base_name), named)
		kept, _ := os.read_all_directory_by_path(SYMBOL_STORE, context.temp_allocator)
		slice.sort_by(kept, proc(a, b: os.File_Info) -> bool { return a.modification_time._nsec > b.modification_time._nsec })
		for e, i in kept { if i >= SYMBOL_STORE_KEEP && strings.has_suffix(e.name, ".map") { _ = os.remove(e.fullpath) } }
	}
	return named, true
}

run_symbols :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Publish= -Store -Fingerprint=")
	if !ok { return 2 }
	if tooling.flag_has(f, "-Fingerprint") {
		fp, good := fingerprint_of(tooling.flag(f, "-Fingerprint"))
		if !good { fmt.eprintln("not a PE file"); return 1 }
		fmt.println(fp)
		return 0
	}
	if !tooling.flag_has(f, "-Publish") { fmt.eprintln("wrentool symbols -Publish exe [-Store] | -Fingerprint exe"); return 2 }
	store := tooling.flag_has(f, "-Store")
	named, good := publish_symbols(tooling.flag(f, "-Publish"), store)
	if !good { return 1 }
	fmt.printfln("symbols: %s%s", named, store ? " (and in build/symbols)" : "")
	return 0
}

////////////////////////////////
// A linker's map

Map_Symbol :: struct { rva: u64, name: string }
Linker_Map :: struct {
	symbols: []Map_Symbol,   // by address
	stamp:   string,         // the link's time stamp, hex
	path:    string,
}

// "  0001:00000000       name       0000000140001000 f   obj"
read_linker_map :: proc(path: string, allocator := context.allocator) -> (m: Linker_Map, ok: bool) {
	context.allocator = allocator
	data, err := os.read_entire_file(path, allocator)
	if err != nil { return {}, false }
	load_base := PE_DEFAULT_BASE
	symbols := make([dynamic]Map_Symbol)
	PREFERRED :: "Preferred load address is "
	STAMP :: "Timestamp is "
	for line in strings.split_lines(string(data)) {
		l := strings.trim_space(line)
		if i := strings.index(l, PREFERRED); i >= 0 { v, _ := strconv.parse_u64(l[i + len(PREFERRED):], 16); load_base = v; continue }
		if strings.has_prefix(l, STAMP) {
			word := strings.fields(l[len(STAMP):])[0]
			m.stamp = fmt.aprintf("%*s", 8, strings.to_upper(word))
			m.stamp, _ = strings.replace_all(m.stamp, " ", "0")
			continue
		}
		parts := strings.fields(l)
		if len(parts) < 3 || len(parts[0]) != 13 || parts[0][4] != ':' || parts[0][:4] == "0000" { continue }
		if len(parts[2]) != 16 || !is_hex(parts[2]) {
			// (a name with spaces: the address is the first 16-digit word after it)
			at := -1
			for p, i in parts[2:] { if len(p) == 16 && is_hex(p) { at = i + 2; break } }
			if at < 0 { continue }
			parts[1] = strings.join(parts[1:at], " ")
			parts[2] = parts[at]
		}
		if !is_hex(parts[0][:4]) { continue }
		va, good := strconv.parse_u64(parts[2], 16)
		if !good || va < load_base { continue }
		append(&symbols, Map_Symbol{va - load_base, parts[1]})
	}
	slice.sort_by(symbols[:], proc(a, b: Map_Symbol) -> bool { return a.rva < b.rva })
	m.symbols = symbols[:]
	m.path = path
	return m, true
}

// "pkg::[file.odin]::proc" -> "pkg.proc" and its file; "pkg::proc" -> "pkg.proc".
format_odin_symbol :: proc(s: string) -> (name, file: string) {
	i := strings.index(s, "::")
	if i <= 0 { return s, "" }
	rest := s[i + 2:]
	if strings.has_prefix(rest, "[") {
		j := strings.index(rest, "]::")
		if j > 0 { return fmt.tprintf("%s.%s", s[:i], rest[j + 3:]), rest[1:j] }
	}
	return fmt.tprintf("%s.%s", s[:i], rest), ""
}

// The function that holds `rva`: "name+0xoffset  (file)", or "" before the first one.
resolve_map_address :: proc(m: Linker_Map, rva: u64) -> string {
	lo, hi := 0, len(m.symbols)
	for lo < hi {
		mid := (lo + hi) / 2
		if m.symbols[mid].rva <= rva { lo = mid + 1 } else { hi = mid }
	}
	if lo == 0 { return "" }
	s := m.symbols[lo - 1]
	name, file := format_odin_symbol(s.name)
	if file != "" { return fmt.tprintf("%s+0x%X  (%s)", name, rva - s.rva, file) }
	return fmt.tprintf("%s+0x%X", name, rva - s.rva)
}

// The map of a build: "*-<fp>.map" in the given folders (or the given file), then build and build/symbols.
find_build_symbols :: proc(fp: string, where_: []string) -> string {
	dirs := make([dynamic]string, context.temp_allocator)
	for w in where_ {
		if w == "" { continue }
		if os.is_file(w) { return w }
		if os.is_dir(w) { append(&dirs, w) }
	}
	append(&dirs, "build", SYMBOL_STORE)
	search :: proc(dir, suffix: string, depth: int) -> string {
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil { return "" }
		for e in entries { if e.type != .Directory && strings.has_suffix(e.name, suffix) { return e.fullpath } }
		if depth > 0 { for e in entries { if e.type == .Directory { if hit := search(e.fullpath, suffix, depth - 1); hit != "" { return hit } } } }
		return ""
	}
	suffix := fmt.tprintf("-%s.map", fp)
	for d in dirs { if hit := search(d, suffix, MAP_SEARCH_DEPTH); hit != "" { return hit } }
	return ""
}

////////////////////////////////
// A crash report

Crashed_Module :: struct { name, fingerprint: string, base, size: u64 }

Minidump :: struct {
	modules:       []Crashed_Module,
	has_exception: bool,
	thread, code:  u32,
	address:       u64,
}

// What a minidump says of the crash.
read_minidump :: proc(path: string) -> (d: Minidump, ok: bool) {
	b, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(b) < MD_HEADER_BYTES || string(b[:4]) != "MDMP" { return {}, false }
	count, dir := int(u32_at(b, 8)), int(u32_at(b, 12))
	modules := make([dynamic]Crashed_Module, context.temp_allocator)
	for k in 0 ..< count {
		e := dir + MD_DIR_ENTRY_BYTES * k
		kind, rva := u32_at(b, e), int(u32_at(b, e + 8))
		switch kind {
		case MD_STREAM_MODULES:
			for i in 0 ..< int(u32_at(b, rva)) {
				m := rva + 4 + MD_MODULE_BYTES * i
				size, stamp, name_rva := u32_at(b, m + 8), u32_at(b, m + 16), int(u32_at(b, m + 20))
				bytes := int(u32_at(b, name_rva))
				units := make([]u16, bytes / 2, context.temp_allocator)
				for j in 0 ..< bytes / 2 { units[j] = u16(b[name_rva + 4 + 2 * j]) | u16(b[name_rva + 5 + 2 * j]) << 8 }
				name := utf16_text(units)
				slash := strings.last_index_any(name, "\\/")
				append(&modules, Crashed_Module{name[slash + 1:], fmt.tprintf("%08X%X", stamp, size), u64_at(b, m), u64(size)})
			}
		case MD_STREAM_EXCEPTION:
			d.has_exception = true
			d.thread, d.code, d.address = u32_at(b, rva), u32_at(b, rva + 8), u64_at(b, rva + 8 + 16)
		}
	}
	d.modules = modules[:]
	return d, true
}

@(private)
utf16_text :: proc(units: []u16) -> string {
	out := strings.builder_make(context.temp_allocator)
	for u in units { strings.write_rune(&out, rune(u)) }
	return strings.to_string(out)
}

// "  build <exe> <fp>, base 0x..., size 0x..."
@(private)
module_line :: proc(line: string) -> (m: Crashed_Module, ok: bool) {
	l := strings.trim_left_space(line)
	if !strings.has_prefix(l, "build ") { return {}, false }
	p := strings.fields(l, context.temp_allocator)
	if len(p) < 7 || p[3] != "base" || p[5] != "size" { return {}, false }
	fp := strings.trim_suffix(p[2], ",")
	if len(fp) < FINGERPRINT_MIN || !is_hex(fp) { return {}, false }
	b, g1 := strconv.parse_u64(strings.trim_suffix(strings.trim_prefix(p[4], "0x"), ","), 16)
	s, g2 := strconv.parse_u64(strings.trim_suffix(strings.trim_prefix(p[6], "0x"), ","), 16)
	return {p[1], fp, b, s}, g1 && g2
}

// "  #NN 0xADDR what..." -> where the name begins.
@(private)
frame_line :: proc(line: string) -> (head: string, addr: u64, ok: bool) {
	l := strings.trim_left_space(line)
	if !strings.has_prefix(l, "#") { return }
	sp := strings.index_byte(l, ' ')
	if sp < 2 { return }
	for c in transmute([]u8)l[1:sp] { if c < '0' || c > '9' { return } }
	r := l[sp + 1:]
	if !strings.has_prefix(r, "0x") { return }
	end := strings.index_byte(r, ' ')
	if end < 0 { return }
	v, good := strconv.parse_u64(r[2:end], 16)
	if !good { return }
	return line[:len(line) - len(r) + end], v, true
}

// A report's text with its frames named: what `crash-symbolize` prints. false: it says why in `out`.
crash_symbolize :: proc(out: ^strings.Builder, report: string, symbols: []string, exe := "") -> bool {
	ext := filepath.ext(report)
	stem := report[:len(report) - len(ext)]
	txt := ext == ".dmp" ? fmt.tprintf("%s.txt", stem) : report
	dmp := ext == ".dmp" ? report : fmt.tprintf("%s.dmp", stem)
	if !os.exists(txt) { txt = "" }
	if fi, err := os.stat(dmp, context.temp_allocator); err != nil || fi.size == 0 { dmp = "" }
	module: Crashed_Module
	has_module := false
	lines := make([dynamic]string, context.temp_allocator)
	if txt != "" {
		data, _ := os.read_entire_file(txt, context.temp_allocator)
		for l in strings.split_lines(string(data), context.temp_allocator) {
			line := strings.trim_right(l, "\r")
			append(&lines, line)
			if !has_module { module, has_module = module_line(line) }
		}
	}
	dump: Minidump
	has_dump := false
	if dmp != "" { dump, has_dump = read_minidump(dmp) }
	if !has_module {
		if !has_dump { fmt.sbprintln(out, "error: the report has no 'build' line (a report from before) and no minidump beside it: nothing says where the program was loaded"); return false }
		for m in dump.modules { if strings.has_suffix(m.name, ".exe") { module = m; has_module = true; break } }
		if !has_module && len(dump.modules) > 0 { module = dump.modules[0] }
		fmt.sbprintln(out, "(the module's base and fingerprint come from the minidump)")
	}
	if len(lines) == 0 {
		if !has_dump || !dump.has_exception { fmt.sbprintln(out, "error: no stack in the report and no exception in the minidump"); return false }
		append(&lines, fmt.tprintf("*** crash: exception (0x%08X) at 0x%X, thread %d (from the minidump: the stack is in the .txt)", dump.code, dump.address, dump.thread))
		append(&lines, fmt.tprintf("  #00 0x%X ?", dump.address))
	}
	fmt.sbprintfln(out, "%s %s, base 0x%X, size 0x%X", module.name, module.fingerprint, module.base, module.size)

	names: Linker_Map
	pdb: Pdb_Session
	use_pdb := exe != ""
	if use_pdb {
		if fp, _ := fingerprint_of(exe); fp != module.fingerprint { fmt.sbprintfln(out, "warning: %s is build %s, the report's is %s: names may be wrong", exe, fp, module.fingerprint) }
		why: string
		pdb, why = pdb_open(exe, module.base, module.size)
		if why != "" { fmt.sbprintfln(out, "error: %s", why); return false }
		fmt.sbprintfln(out, "symbols: %s (PDB, DbgHelp)", exe)
	} else {
		look := make([dynamic]string, context.temp_allocator)
		append(&look, ..symbols)
		append(&look, filepath.dir(report))
		path := find_build_symbols(module.fingerprint, look[:])
		if path == "" {
			fmt.sbprintfln(out, "error: no map of build %s (a file '*-%s.map' in %s, build, build/symbols): give -Symbols <folder or .map>", module.fingerprint, module.fingerprint, strings.join(look[:], ", ", context.temp_allocator))
			return false
		}
		good: bool
		names, good = read_linker_map(path, context.temp_allocator)
		if !good { fmt.sbprintfln(out, "error: %s cannot be read", path); return false }
		fmt.sbprintfln(out, "symbols: %s", path)
		want := module.fingerprint[:8]
		if names.stamp != "" && names.stamp != want { fmt.sbprintfln(out, "warning: this map is of the link %s, the crashed build is %s: right only if both links come from the same sources and flags", names.stamp, want) }
	}
	defer if use_pdb { pdb_close(&pdb) }

	fmt.sbprintln(out)
	named := 0
	for l in lines {
		head, addr, is_frame := frame_line(l)
		if is_frame && addr >= module.base && addr < module.base + module.size {
			name := use_pdb ? pdb_name(&pdb, addr) : resolve_map_address(names, addr - module.base)
			if name != "" {
				named += 1
				fmt.sbprintfln(out, "%s %s  [%s+0x%X]", head, name, module.name, addr - module.base)
				continue
			}
		}
		fmt.sbprintln(out, l)
	}
	fmt.sbprintfln(out, "\n%d frames named", named)
	return true
}

run_crash_symbolize :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Symbols= -Exe=")
	if !ok || len(f.rest) != 1 { fmt.eprintln("wrentool crash-symbolize <report> [-Symbols folder or .map] [-Exe exe]"); return 2 }
	when ODIN_OS != .Windows { return linux_symbolize(f.rest[0], tooling.flag(f, "-Exe")) }
	out := strings.builder_make(context.temp_allocator)
	good := crash_symbolize(&out, f.rest[0], tooling.flag_list(f, "-Symbols"), tooling.flag(f, "-Exe"))
	fmt.print(strings.to_string(out))
	return good ? 0 : 1
}

run_symbolize :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Exe=")
	if !ok || !tooling.flag_has(f, "-Exe") || len(f.rest) == 0 { fmt.eprintln("wrentool symbolize -Exe <exe> <offset>..."); return 2 }
	pdb, why := pdb_open(tooling.flag(f, "-Exe"), PE_DEFAULT_BASE, 0)
	if why != "" { fmt.eprintln(why); return 1 }
	defer pdb_close(&pdb)
	for o in f.rest {
		v, good := strconv.parse_u64(strings.trim_prefix(o, "0x"), 16)
		if !good { fmt.eprintfln("%s is not an offset", o); return 2 }
		name := pdb_name(&pdb, PE_DEFAULT_BASE + v)
		fmt.printfln("%s  %s", o, name != "" ? name : "?")
	}
	return 0
}

// A Linux report: the "[<module>+0x<offset>]" of the build's own module through addr2line (binutils). The executable must be the one that crashed: its GNU build id against the report's "build" line.
linux_symbolize :: proc(report, exe: string) -> int {
	if exe == "" { fmt.eprintln("wrentool crash-symbolize <report.txt> -Exe <executable>"); return 2 }
	data, err := os.read_entire_file(report, context.temp_allocator)
	if err != nil { fmt.eprintfln("%s cannot be read", report); return 1 }
	lines := strings.split_lines(string(data), context.temp_allocator)
	want := ""
	for l in lines {
		if !strings.has_prefix(l, "  build ") { continue }
		p := strings.fields(l, context.temp_allocator)
		if len(p) >= 3 { want = strings.trim_suffix(p[2], ",") }
		break
	}
	notes, _ := tooling.capture({"readelf", "-n", exe}, allocator = context.temp_allocator)
	got := ""
	for l in strings.split_lines(notes, context.temp_allocator) {
		if i := strings.index(l, "Build ID: "); i >= 0 { got = strings.trim_space(l[i + len("Build ID: "):]) }
	}
	if want != "" && want != "(no" && want != got { fmt.eprintfln("the report is of build %s, %s is %s: give the executable that crashed", want, exe, got); return 1 }
	mark := fmt.tprintf("[%s+0x", filepath.base(exe))
	for l in lines {
		i := strings.index(l, mark)
		if !strings.has_prefix(l, "  #") || i < 0 { fmt.println(l); continue }
		rest := l[i + len(mark):]
		end := strings.index_byte(rest, ']')
		if end < 0 { fmt.println(l); continue }
		where_, _ := tooling.capture({"addr2line", "-f", "-C", "-i", "-e", exe, fmt.tprintf("0x%s", rest[:end])}, allocator = context.temp_allocator)
		joined, _ := strings.replace_all(strings.trim_space(where_), "\n", " ", context.temp_allocator)
		fmt.printfln("%s  %s", l, joined)
	}
	return 0
}
