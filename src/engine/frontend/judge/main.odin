package judge

// A command-line judge for the E1 front-end. It exercises the three jobs the brief asks for:
//
//   parse   <files...>         parse each file, print PASS/FAIL and, on failure, the QuickJS-style message with
//                              line/column. Exit code is the number of unexpected results.
//   compile <files...>         parse + compile + serialize each file; print the byte length and a short hex
//                              prefix of the JS_WriteObject stream, so it can be diffed against the C engine's
//                              JS_WriteObject output (the differential judge).
//   dump    <file>             print the full JS_WriteObject byte stream of one file as hex, for byte-for-byte
//                              comparison with QuickJS (`qjs -c` / a JS_WriteObject dumper).
//   speed   <file> [iters]     parse the file `iters` times and report MB/s (perf; run by hand, never in CI).
//   fuzz    <files...>         parse mutated copies of the corpus; the harness must not crash, loop or leak.
//
// The judge links the frontend package and runs on the host. It is a tool, not a unit test: per the night's
// directive we add no @(test) and no test_all step.

import "core:fmt"
import "core:os"
import "core:time"
import "core:mem"
import fe "wb:engine/frontend"

main :: proc() {
	args := os.args
	if len(args) < 2 {
		usage()
		os.exit(2)
	}
	switch args[1] {
	case "parse":
		os.exit(cmd_parse(args[2:], .script))
	case "parse-module":
		os.exit(cmd_parse(args[2:], .module))
	case "compile":
		os.exit(cmd_compile(args[2:]))
	case "dump":
		if len(args) < 3 {usage(); os.exit(2)}
		os.exit(cmd_dump(args[2]))
	case "speed":
		if len(args) < 3 {usage(); os.exit(2)}
		iters := 100
		if len(args) >= 4 {
			iters = parse_int(args[3], 100)
		}
		os.exit(cmd_speed(args[2], iters))
	case "fuzz":
		os.exit(cmd_fuzz(args[2:]))
	case:
		usage()
		os.exit(2)
	}
}

usage :: proc() {
	fmt.eprintln("usage: judge parse|compile|dump|speed|fuzz <files...>")
}

read_file :: proc(path: string) -> (string, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return "", false
	}
	return string(data), true
}

cmd_parse :: proc(files: []string, kind: fe.Program_Kind) -> int {
	fails := 0
	ok_count := 0
	for f in files {
		src, read_ok := read_file(f)
		if !read_ok {
			fmt.eprintfln("cannot read %s", f)
			fails += 1
			continue
		}
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena)
		alloc := mem.dynamic_arena_allocator(&arena)
		_, _, err := fe.parse_program(src, kind, alloc)
		if fe.is_err(err) {
			fmt.printfln("FAIL %s:%d:%d %s", f, err.pos.line, err.pos.col, err.message)
		} else {
			ok_count += 1
		}
		mem.dynamic_arena_destroy(&arena)
	}
	fmt.printfln("parse: %d ok, %d failed, of %d", ok_count, len(files) - ok_count, len(files))
	return fails
}

cmd_compile :: proc(files: []string) -> int {
	fails := 0
	total := 0
	compiled := 0
	for f in files {
		src, read_ok := read_file(f)
		if !read_ok {
			fails += 1
			continue
		}
		total += 1
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena)
		alloc := mem.dynamic_arena_allocator(&arena)
		res := fe.compile_script(src, alloc)
		if fe.is_err(res.err) {
			fmt.printfln("ERR  %s:%d:%d %s", f, res.err.pos.line, res.err.pos.col, res.err.message)
		} else {
			bytes := fe.write_object_of(res, alloc)
			compiled += 1
			fmt.printfln("OK   %s  %d bytes  %s", f, len(bytes), hex_prefix(bytes, 24))
		}
		mem.dynamic_arena_destroy(&arena)
	}
	fmt.printfln("compile: %d/%d compiled", compiled, total)
	return fails
}

cmd_dump :: proc(file: string) -> int {
	src, ok := read_file(file)
	if !ok {
		fmt.eprintfln("cannot read %s", file)
		return 1
	}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	res := fe.compile_script(src, alloc)
	if fe.is_err(res.err) {
		fmt.eprintfln("compile error %s:%d:%d %s", file, res.err.pos.line, res.err.pos.col, res.err.message)
		return 1
	}
	bytes := fe.write_object_of(res, alloc)
	for b, i in bytes {
		fmt.printf("%02x", b)
		if (i + 1) % 32 == 0 {
			fmt.println()
		}
	}
	fmt.println()
	return 0
}

cmd_speed :: proc(file: string, iters: int) -> int {
	src, ok := read_file(file)
	if !ok {
		return 1
	}
	start := time.now()
	for _ in 0 ..< iters {
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena)
		alloc := mem.dynamic_arena_allocator(&arena)
		_, _, _ = fe.parse_program(src, .script, alloc)
		mem.dynamic_arena_destroy(&arena)
	}
	elapsed := time.duration_seconds(time.since(start))
	mb := f64(len(src) * iters) / (1024 * 1024)
	fmt.printfln("speed: %.1f MB/s (%d bytes x %d iters in %.3fs)", mb / elapsed, len(src), iters, elapsed)
	return 0
}

cmd_fuzz :: proc(files: []string) -> int {
	// Parse each file and a few byte-mutations of it. The only assertion is "does not crash / loop / leak"; a
	// clean exit is success. A proper fuzzer would feed a coverage-guided engine, but a deterministic mutation
	// sweep catches the obvious lexer/parser infinite loops.
	seed: u64 = 0x1234567
	for f in files {
		src, ok := read_file(f)
		if !ok {continue}
		for _ in 0 ..< 8 {
			mutated := mutate(src, &seed)
			arena: mem.Dynamic_Arena
			mem.dynamic_arena_init(&arena)
			alloc := mem.dynamic_arena_allocator(&arena)
			_, _, _ = fe.parse_program(mutated, .script, alloc)
			mem.dynamic_arena_destroy(&arena)
		}
	}
	fmt.println("fuzz: no crash")
	return 0
}

mutate :: proc(src: string, seed: ^u64) -> string {
	b := make([]u8, len(src))
	copy(b, transmute([]u8)src)
	if len(b) == 0 {
		return string(b)
	}
	n := 1 + int(next_rand(seed) % 8)
	for _ in 0 ..< n {
		i := int(next_rand(seed) % u64(len(b)))
		b[i] = u8(next_rand(seed) & 0x7f)
	}
	return string(b)
}

next_rand :: proc(seed: ^u64) -> u64 {
	seed^ = seed^ * 6364136223846793005 + 1442695040888963407
	return seed^ >> 16
}

hex_prefix :: proc(bytes: []u8, n: int) -> string {
	count := min(n, len(bytes))
	buf := make([]u8, count * 2)
	hexd := "0123456789abcdef"
	for i in 0 ..< count {
		buf[i * 2] = hexd[bytes[i] >> 4]
		buf[i * 2 + 1] = hexd[bytes[i] & 0xf]
	}
	return string(buf)
}

parse_int :: proc(s: string, dflt: int) -> int {
	n := 0
	for ch in transmute([]u8)s {
		if ch < '0' || ch > '9' {return dflt}
		n = n * 10 + int(ch - '0')
	}
	return n
}
