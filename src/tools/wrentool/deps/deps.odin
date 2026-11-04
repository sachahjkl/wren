// Package deps: what a build of Wren needs before the compiler runs. Each does nothing when its output is up to date (a stamp says what it was made from), so wrentool build (package builder) and build.sh call it every time.
//   wrentool deps [-Profile quick|release] [-Force]     all of them, for this system
//   wrentool fetch wasmtime|wgpu|openh264|emoji|tracy [-Force] [-Unicode] [-Dest dir]
//   wrentool build lexbor|native|tracy [-Force] [-Profile quick|release] [-Features a,b]
// The pins (version, SHA-256) are the constants of fetch.odin, native.odin and tracy.odin. A failing step says what to read.
package deps

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "wb:base"
import "wb:tools/tooling"

TEMP_DIR :: "build/tmp"
LOG_DIR :: "build/logs"
PROFILE_DEFAULT :: "release"

Step :: proc(o: Options) -> bool

Options :: struct {
	force:    bool,
	unicode:  bool,
	dest:     string,
	profile:  string,
	features: string,   // Linux: of the Rust library
	tracy:    bool,     // the Tracy client too (a build with WREN_TRACY=1)
	log:      string,   // where what the compilers say goes ("": here)
}

@(private)
options_of :: proc(args: []string) -> (o: Options, ok: bool) {
	f := tooling.parse_flags(args, "-Force -Unicode -Dest= -Profile= -Features=") or_return
	return {force = tooling.flag_has(f, "-Force"), unicode = tooling.flag_has(f, "-Unicode"), dest = tooling.flag(f, "-Dest"),
	        profile = tooling.flag(f, "-Profile", PROFILE_DEFAULT), features = tooling.flag(f, "-Features")}, true
}

// All of them for this system, quietly: what the tools say is in build/logs, and a failure says which file.
run_all :: proc(args: []string) -> int {
	o, ok := options_of(args)
	if !ok { return 1 }
	return all(o) ? 0 : 1
}

all :: proc(options: Options) -> bool {
	o := options
	_ = os.make_directory_all(LOG_DIR)
	Named :: struct { name: string, step: Step }
	steps := make([dynamic]Named, context.temp_allocator)
	when ODIN_OS == .Windows {
		append(&steps, Named{"wasmtime", fetch_wasmtime}, Named{"lexbor", build_lexbor}, Named{"native", build_native}, Named{"emoji", fetch_emoji})
	} else {
		append(&steps, Named{"wasmtime", fetch_wasmtime}, Named{"wgpu", fetch_wgpu}, Named{"lexbor", build_lexbor}, Named{"native", build_native})
	}
	if o.tracy { append(&steps, Named{"tracy", build_tracy}) }
	for s in steps {
		o.log = fmt.tprintf("%s/deps_%s.log", LOG_DIR, s.name)
		_ = os.remove(o.log)
		if !s.step(o) {
			fmt.eprintfln("%s failed: read %s, or run  wrentool %s", s.name, o.log, s.name == "wasmtime" || s.name == "wgpu" || s.name == "emoji" ? fmt.tprintf("fetch %s", s.name) : fmt.tprintf("build %s", s.name))
			return false
		}
	}
	return true
}

run_fetch :: proc(args: []string) -> int {
	if len(args) == 0 { fmt.eprintln("wrentool fetch wasmtime|wgpu|openh264|emoji|tracy"); return 2 }
	o, ok := options_of(args[1:])
	if !ok { return 2 }
	done: bool
	switch args[0] {
	case "wasmtime": done = fetch_wasmtime(o)
	case "wgpu":     done = fetch_wgpu(o)
	case "openh264": done = fetch_openh264(o)
	case "emoji":    done = fetch_emoji(o)
	case "tracy":    done = fetch_tracy(o)
	case: fmt.eprintfln("nothing to fetch called %s", args[0]); return 2
	}
	return done ? 0 : 1
}

run_build :: proc(args: []string) -> int {
	if len(args) == 0 { fmt.eprintln("wrentool build lexbor|native|tracy"); return 2 }
	o, ok := options_of(args[1:])
	if !ok { return 2 }
	done: bool
	switch args[0] {
	case "lexbor": done = build_lexbor(o)
	case "native": done = build_native(o)
	case "tracy":  done = build_tracy(o)
	case: fmt.eprintfln("nothing to build called %s", args[0]); return 2
	}
	return done ? 0 : 1
}

////////////////////////////////
// What the steps share

@(private)
fail :: proc(o: Options, text: string) -> bool {
	tooling.say(o.log, fmt.tprintln(text))
	if o.log != "" { fmt.eprintln(text) }
	return false
}

// A file's first line, trimmed ("" when there is none).
read_stamp :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	return err == nil ? strings.trim_space(string(data)) : ""
}

write_stamp :: proc(path, text: string) -> bool { return os.write_entire_file(path, text) == nil }

// Every file under `dir`, sorted.
files_under :: proc(dir: string, into: ^[dynamic]string) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	for e in entries {
		if e.type == .Directory { files_under(e.fullpath, into) } else { append(into, e.fullpath) }
	}
	slice.sort(into[:])
}

// The digest of a text and the contents of some files, in this order.
stamp_of :: proc(tag: string, files: []string) -> string {
	all := strings.builder_make(context.temp_allocator)
	strings.write_string(&all, tag)
	for f in files {
		data, err := os.read_entire_file(f, context.temp_allocator)
		if err == nil { strings.write_bytes(&all, data) }
	}
	return tooling.sha256_of(all.buf[:], context.temp_allocator)
}

// A fresh folder of its own for one step's work, gone with its `base.remove_tree`.
work_folder :: proc(name: string) -> string {
	dir := fmt.tprintf("%s/%s", TEMP_DIR, name)
	base.remove_tree(dir)
	_ = os.make_directory_all(dir)
	return dir
}

// The full path of what a program in `dir` is given: its current folder is another one.
full_path :: proc(path: string) -> string {
	full, _ := filepath.abs(path, context.temp_allocator)
	return full
}

// One of the zip files or tar balls of the pins, unpacked into `dest`.
unpack :: proc(o: Options, file, dest: string) -> bool {
	_ = os.make_directory_all(dest)
	return tooling.run({command = {"tar", "-xf", file, "-C", dest}, log = o.log}) == 0
}
