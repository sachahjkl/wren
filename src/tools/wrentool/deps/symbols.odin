package deps

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "wb:tools/tooling"
import toolbox "../../../../ext/gui_toolkit/src/toolbox"

// The symbols of a build, through the toolkit's crash tools (gt:crash writes the reports; toolbox names their frames).
// A release has no PDB, so a crash report of a release names no function of Wren. Windows: the link's map (toolbox.CRASH_LINKER_FLAGS)
// is named by the build (toolbox.crash_publish_symbols: <stem>-<build>.map). Linux: the executable with its GNU build id is the symbols.
// Wren keeps the maps of its release builds in build/symbols too, which CI keeps as an artifact.
//   wrentool symbols -Publish build\wren.exe [-Store]     after each link: wren.map becomes wren-<build>.map; -Store also copies it to build\symbols
//   wrentool symbols -Build <exe>                         the build id a report names
//   wrentool crash-symbolize <report.txt> -Symbols <.map or executable>

SYMBOL_STORE :: "build/symbols"
SYMBOL_STORE_KEEP :: 20

// A link's map named by its build. Text: where it went.
publish_symbols :: proc(exe: string, store: bool) -> (named: string, ok: bool) {
	why: string
	named, why = toolbox.crash_publish_symbols(exe)
	if why != "" { fmt.eprintfln("error: %s", why); return "", false }
	if store && strings.has_suffix(named, ".map") {
		_ = os.make_directory_all(SYMBOL_STORE)
		base_name := named[strings.last_index_any(named, "/\\") + 1:]
		_ = os.copy_file(fmt.tprintf("%s/%s", SYMBOL_STORE, base_name), named)
		// (the store keeps the newest: older releases' maps live in CI's artifacts)
		kept, _ := os.read_all_directory_by_path(SYMBOL_STORE, context.temp_allocator)
		slice.sort_by(kept, proc(a, b: os.File_Info) -> bool { return a.modification_time._nsec > b.modification_time._nsec })
		for e, i in kept { if i >= SYMBOL_STORE_KEEP && strings.has_suffix(e.name, ".map") { _ = os.remove(e.fullpath) } }
	}
	return named, true
}

// The build id of an executable, as a crash report names it ("" when it has none).
build_id_of :: proc(exe: string) -> (id: string, ok: bool) { return toolbox.crash_build_id(exe) }

run_symbols :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Publish= -Store -Build=")
	if !ok { return 2 }
	if tooling.flag_has(f, "-Build") {
		id, good := build_id_of(tooling.flag(f, "-Build"))
		if !good { fmt.eprintln("no build id"); return 1 }
		fmt.println(id)
		return 0
	}
	if !tooling.flag_has(f, "-Publish") { fmt.eprintln("wrentool symbols -Publish exe [-Store] | -Build exe"); return 2 }
	store := tooling.flag_has(f, "-Store")
	named, good := publish_symbols(tooling.flag(f, "-Publish"), store)
	if !good { return 1 }
	fmt.printfln("symbols: %s%s", named, store ? " (and in build/symbols)" : "")
	return 0
}

run_crash_symbolize :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Symbols=")
	if !ok || len(f.rest) != 1 || !tooling.flag_has(f, "-Symbols") {
		fmt.eprintln("wrentool crash-symbolize <report.txt> -Symbols <.map (Windows) or the executable (Linux)>")
		return 2
	}
	text, why := toolbox.crash_symbolize(f.rest[0], tooling.flag(f, "-Symbols"), context.temp_allocator)
	if why != "" { fmt.eprintln(why); return 1 }
	fmt.print(text)
	return 0
}

// The base a PE executable prefers: what the event log's "Fault offset" is relative to.
@(private = "file") PE_DEFAULT_BASE :: u64(0x140000000)

// The function and line at offsets of a module, from its PDB (a -debug build's: the "Fault offset" of the event log).
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
