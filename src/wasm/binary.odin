package wasm

// Just enough of the binary format to find table 0 and memory 0 of a module and make sure they are exported.
// The Wasmtime C API reaches them only through exports, and the host needs both (memory 0 for the
// pointers of host functions, table 0 for call_indirect). A module that does not export them gets an export section
// entry added under a name of our own before compilation: nothing else of the module changes.

import "core:fmt"
import "core:strings"

Image_Info :: struct {
	has_memory:    bool,
	has_table:     bool,
	memory64:      bool,     // memory 0 is 64-bit (its addresses are i64)
	memory_export: string,   // name under which memory 0 is exported (in the image, or ours to add); "" = no memory
	table_export:  string,
	add_memory:    bool,     // the name is ours: the export must be added
	add_table:     bool,
	export_start:  int,      // the export section (header included) when the module has one, else -1
	export_end:    int,
	export_count:  u32,
	insert_at:     int,      // where a new export section goes when there is none
}

@(private) WASM_MAGIC :: [8]u8{0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00}
@(private) OUR_MEMORY_EXPORT :: "__wren_memory0"
@(private) OUR_TABLE_EXPORT :: "__wren_table0"

@(private)
Reader :: struct {
	b:   []byte,
	pos: int,
	bad: bool,
}

@(private)
rd_byte :: proc(r: ^Reader) -> u8 {
	if r.pos >= len(r.b) { r.bad = true; return 0 }
	r.pos += 1
	return r.b[r.pos - 1]
}

@(private)
rd_leb :: proc(r: ^Reader, max_bits: uint = 64) -> u64 {
	v: u64
	shift: uint
	for {
		c := rd_byte(r)
		if r.bad { return 0 }
		v |= u64(c & 0x7f) << shift
		shift += 7
		if c & 0x80 == 0 { break }
		if shift >= max_bits + 7 { r.bad = true; return 0 }
	}
	return v
}

@(private)
rd_name :: proc(r: ^Reader) -> string {
	n := int(rd_leb(r, 32))
	if r.bad || n < 0 || r.pos + n > len(r.b) { r.bad = true; return "" }
	s := string(r.b[r.pos:r.pos + n])
	r.pos += n
	return s
}

@(private)
rd_limits :: proc(r: ^Reader) -> (flags: u8) {
	flags = rd_byte(r)
	wide := flags & 0x04 != 0
	bits: uint = wide ? 64 : 32
	rd_leb(r, bits)
	if flags & 0x01 != 0 { rd_leb(r, bits) }
	if flags & 0x08 != 0 { rd_leb(r, 32) }   // custom page size (log2)
	return
}

@(private)
rd_reftype :: proc(r: ^Reader) {
	t := rd_byte(r)
	if t == 0x63 || t == 0x64 { rd_leb(r, 33) }   // (ref null? heaptype)
}

// Section order of the binary format (custom sections excepted): an inserted export section goes before the first
// section that must follow it.
@(private)
section_rank :: proc(id: u8) -> int {
	switch id {
	case 1: return 1    // type
	case 2: return 2    // import
	case 3: return 3    // function
	case 4: return 4    // table
	case 5: return 5    // memory
	case 13: return 6   // tag
	case 6: return 7    // global
	case 7: return 8    // export
	case 8: return 9    // start
	case 9: return 10   // element
	case 12: return 11  // data count
	case 10: return 12  // code
	case 11: return 13  // data
	}
	return 0
}

analyze_image :: proc(image: []byte) -> (info: Image_Info, err: string) {
	info.export_start, info.export_end, info.insert_at = -1, -1, len(image)
	magic := WASM_MAGIC
	if len(image) < 8 || string(image[:8]) != string(magic[:]) {
		return info, "not a WebAssembly module (bad magic or version)"
	}
	r := Reader{b = image, pos = 8}
	tables, memories := 0, 0
	mem_name, table_name: string
	inserted := false
	exports := make([dynamic]string, context.temp_allocator)
	for r.pos < len(image) {
		start := r.pos
		id := rd_byte(&r)
		size := int(rd_leb(&r, 32))
		if r.bad || r.pos + size > len(image) { return info, "malformed module: truncated section" }
		body := Reader{b = image[r.pos:r.pos + size]}
		end := r.pos + size
		if !inserted && id != 0 && section_rank(id) > section_rank(7) { info.insert_at = start; inserted = true }
		switch id {
		case 2:
			n := int(rd_leb(&body, 32))
			for _ in 0 ..< n {
				if body.bad { break }
				rd_name(&body)
				rd_name(&body)
				kind := rd_byte(&body)
				switch kind {
				case 0: rd_leb(&body, 32)
				case 1: rd_reftype(&body); rd_limits(&body); tables += 1
				case 2:
					if rd_limits(&body) & 0x04 != 0 && memories == 0 { info.memory64 = true }
					memories += 1
				case 3: rd_byte(&body); if body.pos < len(body.b) && (body.b[body.pos - 1] == 0x63 || body.b[body.pos - 1] == 0x64) { rd_leb(&body, 33) }; rd_byte(&body)
				case 4: rd_byte(&body); rd_leb(&body, 32)
				case: body.bad = true
				}
			}
		case 4: tables += int(rd_leb(&body, 32))
		case 5:
			n := int(rd_leb(&body, 32))
			if n > 0 && memories == 0 && rd_limits(&body) & 0x04 != 0 { info.memory64 = true }
			memories += n
		case 7:
			info.export_start, info.export_end = start, end
			n := rd_leb(&body, 32)
			info.export_count = u32(n)
			for _ in 0 ..< n {
				if body.bad { break }
				name := rd_name(&body)
				kind := rd_byte(&body)
				index := rd_leb(&body, 32)
				append(&exports, name)
				if kind == 1 && index == 0 && table_name == "" { table_name = name }
				if kind == 2 && index == 0 && mem_name == "" { mem_name = name }
			}
		}
		if body.bad { return info, fmt.tprintf("malformed module: section %d cannot be read", id) }
		r.pos = end
	}
	info.has_memory = memories > 0
	info.has_table = tables > 0
	unique :: proc(base: string, taken: []string) -> string {
		name := base
		for k := 1; ; k += 1 {
			clash := false
			for t in taken { if t == name { clash = true; break } }
			if !clash { return name }
			name = fmt.tprintf("%s_%d", base, k)
		}
	}
	if info.has_memory {
		if mem_name != "" { info.memory_export = mem_name } else { info.memory_export = unique(OUR_MEMORY_EXPORT, exports[:]); info.add_memory = true }
	}
	if info.has_table {
		if table_name != "" { info.table_export = table_name } else { info.table_export = unique(OUR_TABLE_EXPORT, exports[:]); info.add_table = true }
	}
	return info, ""
}

@(private)
put_leb :: proc(b: ^[dynamic]byte, v: u64) {
	v := v
	for {
		c := u8(v & 0x7f)
		v >>= 7
		if v != 0 { append(b, c | 0x80) } else { append(b, c); break }
	}
}

// The image with the maximum size of its defined tables removed (a copy; `image` itself when none has one): the table
// can then grow at run time (wasm.attach_function), as with wasm-ld --growable-table, which zig's linker lacks.
unbound_tables :: proc(image: []byte, allocator := context.allocator) -> (out: []byte, err: string) {
	magic := WASM_MAGIC
	if len(image) < 8 || string(image[:8]) != string(magic[:]) { return nil, "not a WebAssembly module" }
	r := Reader{b = image, pos = 8}
	for r.pos < len(image) {
		start := r.pos
		id := rd_byte(&r)
		size := int(rd_leb(&r, 32))
		if r.bad || r.pos + size > len(image) { return nil, "malformed module: truncated section" }
		end := r.pos + size
		if id != 4 { r.pos = end; continue }
		body := Reader{b = image[r.pos:end]}
		n := rd_leb(&body, 32)
		nb := make([dynamic]byte, context.temp_allocator)
		put_leb(&nb, n)
		changed := false
		for _ in 0 ..< n {
			// table type: [0x40 0x00] reftype limits [init expr] (the 0x40 form carries an initializer)
			t0 := body.pos
			has_init := body.pos + 1 < len(body.b) && body.b[body.pos] == 0x40 && body.b[body.pos + 1] == 0x00
			if has_init { body.pos += 2 }
			rd_reftype(&body)
			append(&nb, ..body.b[t0:body.pos])
			flags := rd_byte(&body)
			wide := flags & 0x04 != 0
			bits: uint = wide ? 64 : 32
			mn := rd_leb(&body, bits)
			if flags & 0x01 != 0 { rd_leb(&body, bits); changed = true }
			append(&nb, flags &~ 0x01)
			put_leb(&nb, mn)
			if has_init { return nil, "tables with an initializer expression are not handled" }
			if body.bad { return nil, "malformed module: table section" }
		}
		if !changed { return image, "" }
		b := strings.builder_make(0, len(image), allocator)
		strings.write_bytes(&b, image[:start])
		sec := make([dynamic]byte, context.temp_allocator)
		append(&sec, 4)
		put_leb(&sec, u64(len(nb)))
		append(&sec, ..nb[:])
		strings.write_bytes(&b, sec[:])
		strings.write_bytes(&b, image[end:])
		return b.buf[:], ""
	}
	return image, ""
}

// The image with the exports `info` asks for added (a copy), or `image` itself when nothing is missing.
patch_image :: proc(image: []byte, info: Image_Info, allocator := context.allocator) -> (out: []byte, copied: bool) {
	if !info.add_memory && !info.add_table { return image, false }
	entries := make([dynamic]byte, context.temp_allocator)
	extra: u64
	add :: proc(b: ^[dynamic]byte, name: string, kind: u8) {
		put_leb(b, u64(len(name)))
		append(b, ..transmute([]byte)name)
		append(b, kind)
		append(b, 0)   // index 0
	}
	if info.add_memory { add(&entries, info.memory_export, 2); extra += 1 }
	if info.add_table { add(&entries, info.table_export, 1); extra += 1 }

	body := make([dynamic]byte, context.temp_allocator)
	put_leb(&body, u64(info.export_count) + extra)
	before, after: int
	if info.export_start >= 0 {
		// keep the original entries: skip the section header and the old count
		r := Reader{b = image, pos = info.export_start + 1}
		rd_leb(&r, 32)
		rd_leb(&r, 32)
		append(&body, ..image[r.pos:info.export_end])
		before, after = info.export_start, info.export_end
	} else {
		before, after = info.insert_at, info.insert_at
	}
	append(&body, ..entries[:])
	section := make([dynamic]byte, context.temp_allocator)
	append(&section, 7)
	put_leb(&section, u64(len(body)))
	append(&section, ..body[:])

	b := strings.builder_make(0, len(image) + len(section), allocator)
	strings.write_bytes(&b, image[:before])
	strings.write_bytes(&b, section[:])
	strings.write_bytes(&b, image[after:])
	return b.buf[:], true
}
