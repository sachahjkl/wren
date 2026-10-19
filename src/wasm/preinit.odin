package wasm

// Pre-initialization of a module (what Wizer does for Wasmtime): run its initialization once, then write a new module
// whose memory 0 and mutable globals start in the state that initialization left. Instantiating the result skips the
// work entirely: a JavaScript realm whose engine, intrinsics and bindings were set up at build time starts with a
// copy of that memory instead of running the engine's start-up code.
//
//   1. The module is instrumented: every defined mutable global gets an export (the C API only reaches exported ones).
//   2. It is instantiated (imports resolved like any module's: what is missing traps) and the `init` exports are
//      called in order. They may use WASI (clocks, random) but nothing that depends on a document.
//   3. The output is the original module with: memory 0's initial size set to its current size; each mutable
//      global's initializer replaced by its value; every active segment of memory 0 replaced by an empty passive one
//      (segment indices used by memory.init / data.drop stay valid) and the memory's non-zero bytes appended as new
//      active segments; the start function and the `init` exports (and `drop_exports`) removed so nothing runs twice.
//
// Limits (checked): one memory, defined by the module (not imported); mutable globals of numeric types only. Tables are
// not snapshotted: initialization code must not grow or set them (C code does not).

import "core:fmt"
import "core:strings"

@(private) PREINIT_GLOBAL_EXPORT :: "__wren_preinit_g"

// Snapshot runs separated by fewer zero bytes than this are merged (a segment costs a few bytes of header).
@(private) PREINIT_MERGE_GAP :: 32

@(private)
Section :: struct {
	id:         u8,
	start, end: int,   // the whole section, header included
	body:       int,   // start of its contents
}

@(private)
Pre_Global :: struct {
	kind:    u8,       // valtype byte
	type_at: int,      // where its type starts in the image
	mutable: bool,
	init:    [2]int,   // the init expression in the image (end opcode included)
}

Preinit_Stats :: struct {
	memory_bytes:   int,   // size of memory 0 after initialization
	data_bytes:     int,   // bytes stored in the new data segments
	segments:       int,
	globals:        int,   // mutable globals captured
}

@(private)
sections_of :: proc(image: []byte, allocator := context.temp_allocator) -> (out: [dynamic]Section, err: string) {
	out = make([dynamic]Section, allocator)
	magic := WASM_MAGIC
	if len(image) < 8 || string(image[:8]) != string(magic[:]) { return out, "not a WebAssembly module" }
	r := Reader{b = image, pos = 8}
	for r.pos < len(image) {
		start := r.pos
		id := rd_byte(&r)
		size := int(rd_leb(&r, 32))
		if r.bad || r.pos + size > len(image) { return out, "malformed module: truncated section" }
		append(&out, Section{id = id, start = start, end = r.pos + size, body = r.pos})
		r.pos += size
	}
	return out, ""
}

// Skips a constant expression (through its `end`).
@(private)
skip_const_expr :: proc(r: ^Reader) {
	for !r.bad {
		op := rd_byte(r)
		switch op {
		case 0x0b: return                               // end
		case 0x41: rd_leb(r, 32)                        // i32.const (signed: the reader only skips)
		case 0x42: rd_leb(r, 64)                        // i64.const
		case 0x43: r.pos += 4                           // f32.const
		case 0x44: r.pos += 8                           // f64.const
		case 0x23: rd_leb(r, 32)                        // global.get
		case 0xd0: rd_reftype_heap(r)                   // ref.null ht
		case 0xd2: rd_leb(r, 32)                        // ref.func
		case 0x6a, 0x6b, 0x6c, 0x7c, 0x7d, 0x7e:        // extended-const add / sub / mul
		case 0xfd:                                      // v128.const
			if rd_leb(r, 32) != 12 { r.bad = true; return }
			r.pos += 16
		case: r.bad = true; return
		}
		if r.pos > len(r.b) { r.bad = true }
	}
}

@(private)
rd_reftype_heap :: proc(r: ^Reader) { rd_leb(r, 33) }

@(private)
put_sleb :: proc(b: ^[dynamic]byte, v: i64) {
	v := v
	for {
		c := u8(v & 0x7f)
		v >>= 7
		done := (v == 0 && c & 0x40 == 0) || (v == -1 && c & 0x40 != 0)
		if done { append(b, c); return }
		append(b, c | 0x80)
	}
}

@(private)
put_section :: proc(out: ^[dynamic]byte, id: u8, body: []byte) {
	append(out, id)
	put_leb(out, u64(len(body)))
	append(out, ..body)
}

@(private)
put_name :: proc(b: ^[dynamic]byte, s: string) {
	put_leb(b, u64(len(s)))
	append(b, ..transmute([]byte)s)
}

// Runs `init` (exports, in order) on a fresh instance of `image` and returns the pre-initialized module. `drop_exports`
// names exports to remove as well (e.g. "_initialize", which a WASI reactor exposes for its constructors).
preinitialize :: proc(image: []byte, init: []string, drop_exports: []string = nil, opt: Options = {}, allocator := context.allocator) -> (out: []byte, stats: Preinit_Stats, err: string) {
	secs, serr := sections_of(image)
	if serr != "" { return nil, stats, serr }

	imported_globals := 0
	globals := make([dynamic]Pre_Global, context.temp_allocator)
	memories := 0
	memory64 := false
	export_sec := -1
	for s, si in secs {
		r := Reader{b = image[:s.end], pos = s.body}
		switch s.id {
		case 2:
			n := int(rd_leb(&r, 32))
			for _ in 0 ..< n {
				if r.bad { break }
				rd_name(&r); rd_name(&r)
				switch rd_byte(&r) {
				case 0: rd_leb(&r, 32)
				case 1: rd_reftype(&r); rd_limits(&r)
				case 2: return nil, stats, "pre-initialization needs a module that defines its memory (this one imports it)"
				case 3:
					t := rd_byte(&r)
					if t == 0x63 || t == 0x64 { rd_leb(&r, 33) }
					if rd_byte(&r) != 0 { return nil, stats, "pre-initialization: imported mutable globals are not supported" }
					imported_globals += 1
				case 4: rd_byte(&r); rd_leb(&r, 32)
				case: r.bad = true
				}
			}
		case 5:
			n := int(rd_leb(&r, 32))
			memories += n
			if n > 0 { memory64 = rd_limits(&r) & 0x04 != 0 }
		case 6:
			n := int(rd_leb(&r, 32))
			for _ in 0 ..< n {
				if r.bad { break }
				g: Pre_Global
				g.type_at = r.pos
				g.kind = rd_byte(&r)
				if g.kind == 0x63 || g.kind == 0x64 { rd_leb(&r, 33) }
				g.mutable = rd_byte(&r) == 1
				g.init[0] = r.pos
				skip_const_expr(&r)
				g.init[1] = r.pos
				append(&globals, g)
			}
		case 7: export_sec = si
		}
		if r.bad { return nil, stats, fmt.tprintf("malformed module: section %d cannot be read", s.id) }
	}
	if memories != 1 { return nil, stats, fmt.tprintf("pre-initialization needs exactly one memory (the module has %d)", memories) }
	for g in globals {
		if g.mutable && (g.kind < 0x7c || g.kind > 0x7f) { return nil, stats, "pre-initialization: a mutable global is not a number (v128 or reference)" }
	}

	// 1. instrument: export every mutable global
	extra := make([dynamic]byte, context.temp_allocator)
	nextra: u64
	for g, i in globals {
		if !g.mutable { continue }
		put_name(&extra, fmt.tprintf("%s%d", PREINIT_GLOBAL_EXPORT, i))
		append(&extra, 3)
		put_leb(&extra, u64(imported_globals + i))
		nextra += 1
	}
	instrumented := make([dynamic]byte, context.temp_allocator)
	{
		count: u64
		old_entries: []byte
		insert_at := len(image)
		if export_sec >= 0 {
			s := secs[export_sec]
			r := Reader{b = image[:s.end], pos = s.body}
			count = rd_leb(&r, 32)
			old_entries = image[r.pos:s.end]
			insert_at = s.start
		} else {
			for s in secs { if s.id != 0 && section_rank(s.id) > section_rank(7) { insert_at = s.start; break } }
		}
		body := make([dynamic]byte, context.temp_allocator)
		put_leb(&body, count + nextra)
		append(&body, ..old_entries)
		append(&body, ..extra[:])
		append(&instrumented, ..image[:insert_at])
		put_section(&instrumented, 7, body[:])
		skip_to := export_sec >= 0 ? secs[export_sec].end : insert_at
		append(&instrumented, ..image[skip_to:])
	}

	// 2. run the initialization
	o := opt
	if o.max_pages == 0 { o = options_default(); o.max_call_ms = -1 }
	inst, ierr := instance_create(instrumented[:], nil, nil, o, "preinit")
	if inst == nil { return nil, stats, ierr }
	defer destroy(inst)
	for name in init {
		cname := strings.clone_to_cstring(name, context.temp_allocator)
		res := call_raw(inst, cname)
		if res != .Ok { return nil, stats, fmt.tprintf("pre-initialization: %s failed (%v): %s", name, res, inst.last_error) }
	}
	if !inst.wt.has_memory { return nil, stats, "pre-initialization: memory 0 is not reachable" }
	mem := wasmtime_memory_data(inst.wt.ctx, &inst.wt.memory)
	mem_size := int(wasmtime_memory_data_size(inst.wt.ctx, &inst.wt.memory))
	stats.memory_bytes = mem_size

	values := make([]wt_val, len(globals), context.temp_allocator)
	for g, i in globals {
		if !g.mutable { continue }
		name := fmt.tprintf("%s%d", PREINIT_GLOBAL_EXPORT, i)
		ext: wt_extern
		if !wasmtime_instance_export_get(inst.wt.ctx, &inst.wt.instance, raw_data(name), len(name), &ext) || ext.kind != WT_EXTERN_GLOBAL {
			return nil, stats, fmt.tprintf("pre-initialization: global %d cannot be read", i)
		}
		wasmtime_global_get(inst.wt.ctx, rawptr(&ext.of.raw), &values[i])
		stats.globals += 1
	}

	// 3. write the result
	drop := make([dynamic]string, context.temp_allocator)
	append(&drop, ..init)
	append(&drop, ..drop_exports)
	is_dropped :: proc(drop: []string, name: string) -> bool {
		for d in drop { if d == name { return true } }
		return false
	}

	// the memory's non-zero runs
	Run :: struct { off, end: int }
	runs := make([dynamic]Run, context.temp_allocator)
	{
		i := 0
		for i < mem_size {
			for i < mem_size && mem[i] == 0 { i += 1 }
			if i >= mem_size { break }
			start := i
			last := i
			for i < mem_size {
				if mem[i] != 0 { last = i; i += 1; continue }
				if i - last > PREINIT_MERGE_GAP { break }
				i += 1
			}
			append(&runs, Run{start, last + 1})
		}
	}

	res := make([dynamic]byte, 0, len(image) + mem_size / 2, allocator)
	append(&res, ..image[:8])
	old_data_count := -1
	for s in secs {
		r := Reader{b = image[:s.end], pos = s.body}
		switch s.id {
		case 5:
			body := make([dynamic]byte, context.temp_allocator)
			n := rd_leb(&r, 32)
			put_leb(&body, n)
			flags := rd_byte(&r)
			bits: uint = flags & 0x04 != 0 ? 64 : 32
			rd_leb(&r, bits)   // old minimum
			append(&body, flags)
			put_leb(&body, u64(mem_size / 65536))
			append(&body, ..image[r.pos:s.end])   // maximum (and page size), unchanged
			put_section(&res, 5, body[:])
		case 6:
			body := make([dynamic]byte, context.temp_allocator)
			put_leb(&body, u64(len(globals)))
			for g, i in globals {
				if !g.mutable {
					append(&body, ..image[g.type_at:g.init[1]])   // type, mutability and initializer as they were
					continue
				}
				append(&body, g.kind)
				append(&body, 1)
				v := values[i]
				switch g.kind {
				case 0x7f: append(&body, 0x41); put_sleb(&body, i64(v.of.i32))
				case 0x7e: append(&body, 0x42); put_sleb(&body, v.of.i64)
				case 0x7d: append(&body, 0x43); bits := transmute([4]u8)v.of.f32; append(&body, ..bits[:])
				case 0x7c: append(&body, 0x44); bits := transmute([8]u8)v.of.f64; append(&body, ..bits[:])
				}
				append(&body, 0x0b)
			}
			put_section(&res, 6, body[:])
		case 7:
			body := make([dynamic]byte, context.temp_allocator)
			entries := make([dynamic]byte, context.temp_allocator)
			n := int(rd_leb(&r, 32))
			kept: u64
			for _ in 0 ..< n {
				at := r.pos
				name := rd_name(&r)
				rd_byte(&r)
				rd_leb(&r, 32)
				if is_dropped(drop[:], name) { continue }
				append(&entries, ..image[at:r.pos])
				kept += 1
			}
			put_leb(&body, kept)
			append(&body, ..entries[:])
			put_section(&res, 7, body[:])
		case 8:
			// the start function ran already
		case 12:
			old_data_count = int(rd_leb(&r, 32))
			body := make([dynamic]byte, context.temp_allocator)
			put_leb(&body, u64(old_data_count + len(runs)))
			put_section(&res, 12, body[:])
		case 11:
			body := make([dynamic]byte, context.temp_allocator)
			n := int(rd_leb(&r, 32))
			put_leb(&body, u64(n + len(runs)))
			for _ in 0 ..< n {
				flag := rd_leb(&r, 32)
				switch flag {
				case 0:   // active, memory 0: now empty and passive
					skip_const_expr(&r)
					sz := int(rd_leb(&r, 32)); r.pos += sz
					append(&body, 1); put_leb(&body, 0)
				case 1:   // passive: unchanged
					sz := int(rd_leb(&r, 32))
					append(&body, 1)
					put_leb(&body, u64(sz))
					append(&body, ..image[r.pos:r.pos + sz])
					r.pos += sz
				case 2:   // active with an explicit memory index
					if rd_leb(&r, 32) != 0 { return nil, stats, "pre-initialization: a data segment targets another memory" }
					skip_const_expr(&r)
					sz := int(rd_leb(&r, 32)); r.pos += sz
					append(&body, 1); put_leb(&body, 0)
				case:
					return nil, stats, "malformed module: unknown data segment kind"
				}
				if r.bad { return nil, stats, "malformed module: data section" }
			}
			for run in runs {
				append(&body, 0)
				append(&body, memory64 ? 0x42 : 0x41)
				put_sleb(&body, i64(run.off))
				append(&body, 0x0b)
				put_leb(&body, u64(run.end - run.off))
				append(&body, ..mem[run.off:run.end])
				stats.data_bytes += run.end - run.off
			}
			stats.segments = len(runs)
			put_section(&res, 11, body[:])
		case:
			append(&res, ..image[s.start:s.end])
		}
		if r.bad { return nil, stats, fmt.tprintf("malformed module: section %d", s.id) }
	}
	has_data := false
	for s in secs { if s.id == 11 { has_data = true } }
	if !has_data && len(runs) > 0 {
		// no data section at all: add one (and the data count, required before the code when bulk memory is used)
		body := make([dynamic]byte, context.temp_allocator)
		put_leb(&body, u64(len(runs)))
		for run in runs {
			append(&body, 0)
			append(&body, memory64 ? 0x42 : 0x41)
			put_sleb(&body, i64(run.off))
			append(&body, 0x0b)
			put_leb(&body, u64(run.end - run.off))
			append(&body, ..mem[run.off:run.end])
			stats.data_bytes += run.end - run.off
		}
		stats.segments = len(runs)
		put_section(&res, 11, body[:])
	}
	return res[:], stats, ""
}
