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
	case "prof":
		if len(args) < 3 {usage(); os.exit(2)}
		os.exit(cmd_prof(args[2], len(args) >= 4 ? parse_int(args[3], 200) : 200))
	case "fuzz":
		os.exit(cmd_fuzz(args[2:]))
	case "batch":
		if len(args) < 4 {usage(); os.exit(2)}
		start := len(args) >= 5 ? parse_int(args[4], 0) : 0
		count := len(args) >= 6 ? parse_int(args[5], max(int)) : max(int)
		os.exit(cmd_batch(args[2], args[3], start, count))
	case "diff-batch":
		if len(args) < 5 {usage(); os.exit(2)}
		os.exit(cmd_diff_batch(args[2], args[3], args[4]))
	case "emit", "emit-module":
		if len(args) < 4 {usage(); os.exit(2)}
		os.exit(cmd_emit(args[2], args[3], args[1] == "emit-module"))
	case "decode":
		if len(args) < 3 {usage(); os.exit(2)}
		os.exit(cmd_decode(args[2]))
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
		err := fe.compile_program(src, kind, alloc).err
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

// cmd_emit compiles one file and writes the raw JS_WriteObject bytes, for `decode` and byte diffs.
cmd_emit :: proc(file, out: string, module: bool) -> int {
	src, ok := read_file(file)
	if !ok {
		fmt.eprintfln("cannot read %s", file)
		return 1
	}
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	alloc := mem.dynamic_arena_allocator(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	res := fe.compile_program(src, module ? .module : .script, alloc)
	if fe.is_err(res.err) {
		fmt.eprintfln("compile error %s:%d:%d %s", file, res.err.pos.line, res.err.pos.col, res.err.message)
		return 1
	}
	bytes := fe.write_object_of(res, alloc)
	_ = os.write_entire_file(out, bytes)
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
		_ = fe.compile_program(src, .script, alloc)
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
			_ = fe.compile_program(mutated, .script, alloc)
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

// cmd_batch compiles every file in a manifest ("<mode>\t<path>" per line, mode s|m), writing each success to
// outdir/<idx>.bin and printing "<idx>\t<status>\t<len>" so the oracle and our output share the same indexing.
cmd_batch :: proc(manifest, outdir: string, start := 0, count := max(int)) -> int {
	data, err := os.read_entire_file_from_path(manifest, context.allocator)
	if err != nil {
		fmt.eprintfln("cannot read manifest %s", manifest)
		return 2
	}
	text := string(data)
	idx := 0
	for line in split_lines(text) {
		if idx < start {idx += 1; continue}
		if idx - start >= count {break}
		if len(line) < 3 {idx += 1; continue}
		module := line[0] == 'm'
		path := line[2:]
		src, read_ok := read_file(path)
		if !read_ok {
			fmt.printfln("%d\tmiss\t0", idx)
			idx += 1
			continue
		}
		arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&arena)
		alloc := mem.dynamic_arena_allocator(&arena)
		res := fe.compile_program(src, module ? .module : .script, alloc)
		if fe.is_err(res.err) {
			fmt.printfln("%d\terr\t0", idx)
		} else {
			bytes := fe.write_object_of(res, alloc)
			ofile := fmt.tprintf("%s\\%d.bin", outdir, idx)
			_ = os.write_entire_file(ofile, bytes)
			fmt.printfln("%d\tok\t%d", idx, len(bytes))
		}
		mem.dynamic_arena_destroy(&arena)
		idx += 1
	}
	return 0
}

// cmd_diff_batch compares our bytecode files against the oracle's for every manifest entry, classifying each as
// identical / length-mismatch / content-diff, and tallies by the top test262 folder. It prints a per-folder
// summary and the first divergences by first-diff offset, to drive the fix-by-frequency loop.
cmd_diff_batch :: proc(manifest, refdir, oursdir: string) -> int {
	data, err := os.read_entire_file_from_path(manifest, context.allocator)
	if err != nil {
		fmt.eprintfln("cannot read manifest %s", manifest)
		return 2
	}
	lines := split_lines(string(data))

	Folder_Stat :: struct {
		total, both_ok, identical, our_err, ref_err, len_diff, content_diff: int,
	}
	folders := make(map[string]Folder_Stat)
	diffs := make([dynamic]string)

	idx := -1
	for line in lines {
		idx += 1
		if len(line) < 3 {continue}
		path := line[2:]
		folder := top_folder(path)
		fs := folders[folder]
		fs.total += 1

		ref, ref_ok := os.read_entire_file_from_path(fmt.tprintf("%s\\%d.bin", refdir, idx), context.allocator)
		ours, ours_ok := read_bin(fmt.tprintf("%s\\%d.bin", oursdir, idx))

		// The oracle writes a .bin only on success; our batch likewise. Missing = compile error on that side.
		ref_compiled := ref_ok == nil
		ours_compiled := ours_ok
		if !ref_compiled && !ours_compiled {
			// both failed to compile: a parse-verdict agreement, not a bytecode case.
			folders[folder] = fs
			continue
		}
		if ref_compiled && !ours_compiled {
			fs.our_err += 1
			folders[folder] = fs
			continue
		}
		if !ref_compiled && ours_compiled {
			fs.ref_err += 1
			folders[folder] = fs
			continue
		}
		fs.both_ok += 1
		if bytes_equal(ref, ours) {
			fs.identical += 1
		} else if len(ref) != len(ours) {
			fs.len_diff += 1
			off := first_diff(ref, ours)
			if len(diffs) < 4000 {
				append(&diffs, fmt.aprintf("LEN  %s ref=%d ours=%d @%d", path, len(ref), len(ours), off))
			}
		} else {
			fs.content_diff += 1
			off := first_diff(ref, ours)
			if len(diffs) < 4000 {
				append(&diffs, fmt.aprintf("CNT  %s len=%d @%d ref=%02x ours=%02x", path, len(ref), off, ref[off], ours[off]))
			}
		}
		folders[folder] = fs
	}

	// print per-folder summary
	fmt.println("folder                            total  both  ident  ourErr refErr lenDiff cntDiff")
	grand := Folder_Stat{}
	for name, fs in folders {
		fmt.printfln("%-32s %6d %5d %6d %6d %6d %7d %7d", name, fs.total, fs.both_ok, fs.identical, fs.our_err, fs.ref_err, fs.len_diff, fs.content_diff)
		grand.total += fs.total; grand.both_ok += fs.both_ok; grand.identical += fs.identical
		grand.our_err += fs.our_err; grand.ref_err += fs.ref_err; grand.len_diff += fs.len_diff; grand.content_diff += fs.content_diff
	}
	fmt.printfln("%-32s %6d %5d %6d %6d %6d %7d %7d", "TOTAL", grand.total, grand.both_ok, grand.identical, grand.our_err, grand.ref_err, grand.len_diff, grand.content_diff)
	if grand.both_ok > 0 {
		fmt.printfln("bytecode identical: %.2f%% of %d both-compiled", 100.0 * f64(grand.identical) / f64(grand.both_ok), grand.both_ok)
	}
	// print a sample of divergences
	fmt.println("--- first divergences (sample) ---")
	for d, i in diffs {
		if i >= 60 {break}
		fmt.println(d)
	}
	return 0
}

// --- container decoder (for field-by-field comparison with the oracle) --------------------------------------

Dec :: struct {
	buf: []u8,
	pos: int,
}

dec_u8 :: proc(d: ^Dec) -> u8 { v := d.buf[d.pos]; d.pos += 1; return v }
dec_u16 :: proc(d: ^Dec) -> u16 { v := u16(d.buf[d.pos]) | u16(d.buf[d.pos+1])<<8; d.pos += 2; return v }
dec_u32 :: proc(d: ^Dec) -> u32 { v := u32(d.buf[d.pos])|u32(d.buf[d.pos+1])<<8|u32(d.buf[d.pos+2])<<16|u32(d.buf[d.pos+3])<<24; d.pos += 4; return v }
dec_leb :: proc(d: ^Dec) -> u32 {
	v: u32 = 0; shift: uint = 0
	for {
		b := d.buf[d.pos]; d.pos += 1
		v |= u32(b & 0x7f) << shift
		if b < 0x80 {break}
		shift += 7
	}
	return v
}

indent :: proc(depth: int) -> string {
	spaces := "                                        "
	n := min(depth * 2, len(spaces))
	return spaces[:n]
}

atom_names: [dynamic]string

atom_label :: proc(serial: u32) -> string {
	// serial is the bc_put_atom value: tagged int (bit0=1) or (idx<<1). Resolve to a readable name.
	if (serial & 1) != 0 {
		return fmt.tprintf("int:%d", serial >> 1)
	}
	idx := serial >> 1
	// predefined atoms are < JS_ATOM_END and written inline by value; runtime atoms are table indices.
	if idx < u32(fe.JS_ATOM_END) {
		if idx >= 1 && int(idx) <= len(fe.PREDEFINED_ATOMS) {
			return fmt.tprintf("%q", fe.PREDEFINED_ATOMS[idx-1])
		}
		return fmt.tprintf("pre:%d", idx)
	}
	ti := int(idx) - int(fe.JS_ATOM_END)
	if ti >= 0 && ti < len(atom_names) {
		return fmt.tprintf("%q", atom_names[ti])
	}
	return fmt.tprintf("rt:%d", idx)
}

// atom_label_raw resolves an in-bytecode atom operand, which JS_WriteFunctionBytecode stores as the raw
// serialized index (unshifted), unlike header atoms written by bc_put_atom (shifted <<1 | taggedbit).
atom_label_raw :: proc(idx: u32) -> string {
	if idx < u32(fe.JS_ATOM_END) {
		if idx >= 1 && int(idx) <= len(fe.PREDEFINED_ATOMS) {
			return fmt.tprintf("%q", fe.PREDEFINED_ATOMS[idx-1])
		}
		return fmt.tprintf("pre:%d", idx)
	}
	ti := int(idx) - int(fe.JS_ATOM_END)
	if ti >= 0 && ti < len(atom_names) {
		return fmt.tprintf("%q", atom_names[ti])
	}
	return fmt.tprintf("rt:%d", idx)
}

cmd_decode :: proc(path: string) -> int {
	buf, ok := read_bin(path)
	if !ok {fmt.eprintfln("cannot read %s", path); return 1}
	d := Dec{buf = buf}
	ver := dec_u8(&d)
	csum := dec_u32(&d)
	fmt.printfln("version=%d checksum=%08x total=%d", ver, csum, len(buf))
	natoms := dec_leb(&d)
	fmt.printfln("atom_count=%d", natoms)
	atom_names = make([dynamic]string)
	for i in 0 ..< natoms {
		t := dec_u8(&d)
		h := dec_leb(&d)
		wide := (h & 1) != 0
		slen := int(h >> 1)
		s := ""
		if !wide {
			s = string(d.buf[d.pos:d.pos+slen])
			d.pos += slen
		} else {
			d.pos += slen * 2
			s = "<wide>"
		}
		append(&atom_names, s)
		fmt.printfln("  atom[%d] (serial %d) type=%d %q", i, u32(fe.JS_ATOM_END)+i, t, s)
	}
	if d.buf[d.pos] == 13 {
		// module record: name, requested modules, exports, star exports, imports, has_tla, then the function
		dec_u8(&d)
		fmt.printfln("MODULE name=%s", atom_label(dec_leb(&d)))
		nreq := dec_leb(&d)
		for _ in 0 ..< nreq {fmt.printfln("  req %s", atom_label(dec_leb(&d)))}
		nexp := dec_leb(&d)
		for _ in 0 ..< nexp {
			t := dec_u8(&d)
			if t == 0 {
				vi := dec_leb(&d)
				fmt.printfln("  export local var_idx=%d as %s", vi, atom_label(dec_leb(&d)))
			} else {
				ri := dec_leb(&d)
				ln := atom_label(dec_leb(&d))
				fmt.printfln("  export indirect req=%d %s as %s", ri, ln, atom_label(dec_leb(&d)))
			}
		}
		nstar := dec_leb(&d)
		for _ in 0 ..< nstar {fmt.printfln("  star req=%d", dec_leb(&d))}
		nimp := dec_leb(&d)
		for _ in 0 ..< nimp {
			vi := dec_leb(&d)
			nm := atom_label(dec_leb(&d))
			fmt.printfln("  import var_idx=%d %s req=%d", vi, nm, dec_leb(&d))
		}
		fmt.printfln("  has_tla=%d", dec_u8(&d))
	}
	decode_function(&d, 0)
	fmt.printfln("decoded up to %d of %d", d.pos, len(buf))
	return 0
}

decode_function :: proc(d: ^Dec, depth: int) {
	ind := indent(depth)
	tag := dec_u8(d)
	fmt.printfln("%sTAG=%d (function)", ind, tag)
	flags := dec_u16(d)
	strict := dec_u8(d)
	fmt.printfln("%sflags=%04x strict=%d", ind, flags, strict)
	fname := dec_leb(d)
	fmt.printfln("%sfunc_name=%s", ind, atom_label(fname))
	arg_count := dec_leb(d)
	var_count := dec_leb(d)
	defined := dec_leb(d)
	stack := dec_leb(d)
	var_ref := dec_leb(d)
	closure := dec_leb(d)
	cpool := dec_leb(d)
	bclen := dec_leb(d)
	fmt.printfln("%sarg=%d var=%d defined=%d stack=%d var_ref=%d closure=%d cpool=%d bc_len=%d", ind, arg_count, var_count, defined, stack, var_ref, closure, cpool, bclen)
	nvardefs := dec_leb(d)
	fmt.printfln("%svardefs=%d", ind, nvardefs)
	for i in 0 ..< nvardefs {
		nm := dec_leb(d)
		lvl := dec_leb(d)
		nxt := dec_leb(d)
		vf := dec_u8(d)
		captured := (vf >> 6) & 1
		if captured != 0 {dec_leb(d)}
		fmt.printfln("%s  var[%d] name=%s lvl=%d next=%d flags=%02x", ind, i, atom_label(nm), lvl, nxt, vf)
	}
	for i in 0 ..< closure {
		nm := dec_leb(d)
		vi := dec_leb(d)
		cf := dec_leb(d)
		fmt.printfln("%s  closure[%d] name=%s idx=%d flags=%d", ind, i, atom_label(nm), vi, cf)
	}
	for i in 0 ..< cpool {
		fmt.printfln("%s  cpool[%d]:", ind, i)
		decode_const(d, depth + 2)
	}
	// bytecode
	fmt.printfln("%sbytecode:", ind)
	disasm(d, int(bclen), depth + 1)
	// debug
	dbg_filename := dec_leb(d)
	line := dec_leb(d)
	col := dec_leb(d)
	pc2line := dec_leb(d)
	pc_hex := hex_prefix(d.buf[d.pos:d.pos + int(pc2line)], int(pc2line))
	d.pos += int(pc2line)
	srclen := dec_leb(d)
	d.pos += int(srclen)
	fmt.printfln("%sdebug filename=%d line=%d col=%d pc2line_len=%d src_len=%d", ind, dbg_filename, line, col, pc2line, srclen)
	fmt.printfln("%spc2line %s", ind, pc_hex)
}

decode_const :: proc(d: ^Dec, depth: int) {
	ind := indent(depth)
	tag := d.buf[d.pos]
	if tag == 12 { // function
		decode_function(d, depth)
		return
	}
	dec_u8(d)
	switch tag {
	case 5: // int32 sleb
		v := dec_leb(d)
		fmt.printfln("%sINT32 zz=%d", ind, v)
	case 6: // float64
		d.pos += 8
		fmt.printfln("%sFLOAT64", ind)
	case 7: // string
		h := dec_leb(d)
		slen := int(h >> 1)
		d.pos += (h & 1) != 0 ? slen*2 : slen
		fmt.printfln("%sSTRING len=%d", ind, slen)
	case 10: // bigint
		blen := dec_leb(d)
		d.pos += int(blen)
		fmt.printfln("%sBIGINT bytes=%d", ind, blen)
	case 1:
		fmt.printfln("%sNULL", ind)
	case 2:
		fmt.printfln("%sUNDEFINED", ind)
	case 11: // template object: elements then raw (itself a template object) then undefined
		n := dec_leb(d)
		fmt.printfln("%sTEMPLATE n=%d", ind, n)
		for _ in 0 ..< n {decode_const(d, depth + 1)}
		decode_const(d, depth + 1)
	case:
		fmt.printfln("%sTAG=%d (unhandled in decoder)", ind, tag)
	}
}

disasm :: proc(d: ^Dec, bclen: int, depth: int) {
	ind := indent(depth)
	end := d.pos + bclen
	for d.pos < end {
		op := fe.Opcode(d.buf[d.pos])
		info := fe.op_info[op]
		opc := d.pos
		operand := ""
		sz := int(info.size)
		#partial switch info.fmt {
		case .atom, .atom_u8, .atom_u16, .atom_label_u8, .atom_label_u16:
			a := u32(d.buf[opc+1])|u32(d.buf[opc+2])<<8|u32(d.buf[opc+3])<<16|u32(d.buf[opc+4])<<24
			operand = fmt.tprintf("%s", atom_label_raw(a))
		case .u16, .npop, .npop_u16:
			operand = fmt.tprintf("u16=%d", u16(d.buf[opc+1])|u16(d.buf[opc+2])<<8)
		case .u8, .loc8, .const8:
			operand = fmt.tprintf("u8=%d", d.buf[opc+1])
		case .i32, .u32, .label:
			operand = fmt.tprintf("i32=%d", i32(u32(d.buf[opc+1])|u32(d.buf[opc+2])<<8|u32(d.buf[opc+3])<<16|u32(d.buf[opc+4])<<24))
		}
		fmt.printfln("%s%4d: %s %s", ind, opc, op, operand)
		d.pos += sz
	}
}

read_bin :: proc(path: string) -> ([]u8, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {return nil, false}
	return data, true
}

bytes_equal :: proc(a, b: []u8) -> bool {
	if len(a) != len(b) {return false}
	for i in 0 ..< len(a) {
		if a[i] != b[i] {return false}
	}
	return true
}

first_diff :: proc(a, b: []u8) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] != b[i] {return i}
	}
	return n
}

split_lines :: proc(s: string) -> []string {
	out := make([dynamic]string)
	start := 0
	for i in 0 ..< len(s) {
		if s[i] == '\n' {
			end := i
			if end > start && s[end-1] == '\r' {end -= 1}
			append(&out, s[start:end])
			start = i + 1
		}
	}
	if start < len(s) {append(&out, s[start:])}
	return out[:]
}

top_folder :: proc(path: string) -> string {
	// returns the test262 subpath under test/ up to two components, e.g. "language/expressions".
	marker := "test262"
	i := index_of(path, marker)
	if i < 0 {return "other"}
	rest := path[i + len(marker):]
	// skip separators and a leading "test/"
	rest = trim_seps(rest)
	if starts_with(rest, "test") {rest = trim_seps(rest[4:])}
	// take first two path components
	comps := 0
	for j in 0 ..< len(rest) {
		if rest[j] == '\\' || rest[j] == '/' {
			comps += 1
			if comps == 2 {return rest[:j]}
		}
	}
	return rest
}

index_of :: proc(s, sub: string) -> int {
	if len(sub) == 0 {return 0}
	for i in 0 ..= len(s) - len(sub) {
		if s[i:i+len(sub)] == sub {return i}
	}
	return -1
}

trim_seps :: proc(s: string) -> string {
	i := 0
	for i < len(s) && (s[i] == '\\' || s[i] == '/') {i += 1}
	return s[i:]
}

starts_with :: proc(s, p: string) -> bool {
	return len(s) >= len(p) && s[:len(p)] == p
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
