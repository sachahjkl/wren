package wasm

// The machine code of the program's own image, made at build time and shipped inside the program. Without it a profile's
// first script compiles the whole engine with Cranelift (docs/performance.md, round 37), after every install and every
// update. It comes from the same file as the program, so it needs no MAC as the disk cache's files do (module_cache.odin);
// what it needs is to fit:
//
//   * the image's digest (uncompressed and, when embedded compressed, packed) and the configuration's fingerprint in its
//     header: the code of another image never runs, and a changed wasm.wasmtime.* preference passes it by;
//   * the module's memory/table export names and poll word in its header, so normal startup uses the machine code without
//     scanning or decompressing the fallback Wasm image;
//   * Wasmtime's own check of the rest: its version, the settings it compiles for, the CPU features the code uses.
//
// A blob that does not fit is passed by, counted (Cache_Stats.shipped_refused), and the module takes the disk cache's path:
// nothing else depends on it. The embedded fallback Wasm image is stored compressed (WRENWZ01, zlib via core:compress/deflate)
// and is only inflated when a fallback compile is actually needed.

import "core:compress/deflate"
import "core:fmt"
import "core:mem"
import "core:sync"

@(private) SHIPPED_MAGIC :: "WRENCD02"
@(private) PACKED_MAGIC :: "WRENWZ01"
@(private) SHIPPED_NAME_MAX :: 64
@(private) SHIPPED_FLAG_POLLED   :: u8(1 << 0)
@(private) SHIPPED_FLAG_MEMORY64 :: u8(1 << 1)
@(private) PACKED_CODEC_ZLIB     :: u8(1)
// Hard bound on decompressed fallback Wasm size so a corrupt header never allocates unbounded memory.
@(private) PACKED_MAX_BYTES :: 64 << 20

// Metadata carried by Shipped_Header and Packed_Header so startup and disk-cache hits need neither analyze_image nor decompression.
@(private)
Shipped_Meta :: struct {
	memory_export: string,
	table_export:  string,
	memory64:      bool,
	has_poll:      bool,
	poll_word:     u32,
}

// What a shipped-code blob starts with. The serialized Wasmtime machine code follows.
@(private)
Shipped_Header :: struct #packed {
	magic:         [len(SHIPPED_MAGIC)]u8,
	image:         Digest,                  // SHA-256 of the uncompressed Wasm image
	packed:        Digest,                  // SHA-256 of the compressed WRENWZ01 container (zero when none)
	fingerprint:   Digest,                  // SHA-256 of the configuration: config_text
	poll_word:     u32le,                   // address of wren.poll word (when SHIPPED_FLAG_POLLED is set)
	flags:         u8,                      // SHIPPED_FLAG_*
	mem_len:       u8,                      // length of memory_export (<= SHIPPED_NAME_MAX)
	table_len:     u8,                      // length of table_export (<= SHIPPED_NAME_MAX)
	_:             u8,
	memory_export: [SHIPPED_NAME_MAX]u8,
	table_export:  [SHIPPED_NAME_MAX]u8,
}

// What a compressed embedded Wasm image starts with (build/js/wren_js.wasmz). The zlib payload follows.
@(private)
Packed_Header :: struct #packed {
	magic:         [len(PACKED_MAGIC)]u8,
	raw_size:      u32le,                   // exact byte length of the uncompressed Wasm binary
	raw_digest:    Digest,                  // SHA-256 of the uncompressed Wasm binary
	poll_word:     u32le,                   // address of wren.poll word (when SHIPPED_FLAG_POLLED is set)
	flags:         u8,                      // SHIPPED_FLAG_*
	codec:         u8,                      // PACKED_CODEC_ZLIB
	mem_len:       u8,                      // length of memory_export (<= SHIPPED_NAME_MAX)
	table_len:     u8,                      // length of table_export (<= SHIPPED_NAME_MAX)
	memory_export: [SHIPPED_NAME_MAX]u8,
	table_export:  [SHIPPED_NAME_MAX]u8,
}

when ODIN_OS == .Windows {
	@(private) SHIPPED_TARGET :: "x86_64-pc-windows-msvc"
} else when ODIN_ARCH == .arm64 {
	@(private) SHIPPED_TARGET :: "aarch64-unknown-linux-gnu"
} else {
	@(private) SHIPPED_TARGET :: "x86_64-unknown-linux-gnu"
}

// The blob of this program, when it has one.
@(private)
shipped_code: []byte

// `blob` (shipped_make) is what a module looks at from now on: before the runtime's first module. It stays the caller's.
shipped_set :: proc(blob: []byte) { shipped_code = blob }

// Whether `image` starts with the WRENWZ01 compressed-image container magic.
is_packed_image :: proc(image: []byte) -> bool {
	return len(image) >= len(PACKED_MAGIC) && string(image[:len(PACKED_MAGIC)]) == PACKED_MAGIC
}

// Parses a WRENWZ01 header without allocating or decompressing. Export name slices borrow from `image`.
@(private)
packed_header_parse :: proc(image: []byte) -> (h: Packed_Header, meta: Shipped_Meta, ok: bool) {
	if len(image) <= size_of(Packed_Header) || string(image[:len(PACKED_MAGIC)]) != PACKED_MAGIC { return }
	mem.copy(&h, raw_data(image), size_of(h))
	if h.codec != PACKED_CODEC_ZLIB || h.raw_size == 0 || int(h.raw_size) > PACKED_MAX_BYTES { return }
	if int(h.mem_len) > SHIPPED_NAME_MAX || int(h.table_len) > SHIPPED_NAME_MAX { return }
	meta = Shipped_Meta{
		memory_export = string(image[offset_of(Packed_Header, memory_export):][:h.mem_len]),
		table_export  = string(image[offset_of(Packed_Header, table_export):][:h.table_len]),
		memory64      = (h.flags & SHIPPED_FLAG_MEMORY64) != 0,
		has_poll      = (h.flags & SHIPPED_FLAG_POLLED) != 0,
		poll_word     = u32(h.poll_word),
	}
	return h, meta, true
}

// Parses a Shipped_Header without allocating. Export name slices borrow from `blob`.
@(private)
shipped_header_parse :: proc(blob: []byte) -> (h: Shipped_Header, meta: Shipped_Meta, ok: bool) {
	if len(blob) <= size_of(Shipped_Header) || string(blob[:len(SHIPPED_MAGIC)]) != SHIPPED_MAGIC { return }
	mem.copy(&h, raw_data(blob), size_of(h))
	if int(h.mem_len) > SHIPPED_NAME_MAX || int(h.table_len) > SHIPPED_NAME_MAX { return }
	meta = Shipped_Meta{
		memory_export = string(blob[offset_of(Shipped_Header, memory_export):][:h.mem_len]),
		table_export  = string(blob[offset_of(Shipped_Header, table_export):][:h.table_len]),
		memory64      = (h.flags & SHIPPED_FLAG_MEMORY64) != 0,
		has_poll      = (h.flags & SHIPPED_FLAG_POLLED) != 0,
		poll_word     = u32(h.poll_word),
	}
	return h, meta, true
}

// Compresses an uncompressed WebAssembly image into a WRENWZ01 container with its metadata header.
pack_image :: proc(image: []byte, fast := false, allocator := context.allocator) -> (packed: []byte, err: string) {
	info, aerr := analyze_image(image)
	if aerr != "" { return nil, aerr }
	if len(info.memory_export) > SHIPPED_NAME_MAX || len(info.table_export) > SHIPPED_NAME_MAX {
		return nil, "memory or table export name exceeds header limit"
	}
	if len(image) == 0 || len(image) > PACKED_MAX_BYTES {
		return nil, "image size out of range for packing"
	}
	word, has_poll := poll_word_of(image)
	h: Packed_Header
	copy(h.magic[:], PACKED_MAGIC)
	h.raw_size = u32le(len(image))
	h.raw_digest, _ = sha256(image)
	h.poll_word = u32le(word)
	if has_poll { h.flags |= SHIPPED_FLAG_POLLED }
	if info.memory64 { h.flags |= SHIPPED_FLAG_MEMORY64 }
	h.codec = PACKED_CODEC_ZLIB
	h.mem_len = u8(len(info.memory_export))
	h.table_len = u8(len(info.table_export))
	copy(h.memory_export[:], info.memory_export)
	copy(h.table_export[:], info.table_export)

	level := fast ? deflate.Deflate_Level.Default : deflate.Deflate_Level.Best
	compressed := make([dynamic]u8, allocator)
	defer delete(compressed)
	if derr := deflate.deflate_zlib(&compressed, image, level, allocator); derr != nil {
		return nil, fmt.tprintf("deflate failed: %v", derr)
	}
	packed = make([]byte, size_of(h) + len(compressed), allocator)
	mem.copy(raw_data(packed), &h, size_of(h))
	copy(packed[size_of(h):], compressed[:])
	return packed, ""
}

// Decompresses a WRENWZ01 container (fallback compile path only). Verifies exact size and SHA-256.
// Caller owns the returned slice (`delete(raw, allocator)`).
unpack_image :: proc(packed: []byte, allocator := context.allocator) -> (raw: []byte, err: string) {
	h, _, ok := packed_header_parse(packed)
	if !ok { return nil, "malformed compressed Wasm image" }
	payload := packed[size_of(Packed_Header):]
	out := make([dynamic]u8, allocator)
	if ierr := deflate.inflate_zlib(&out, payload, expected_output_size = int(h.raw_size), max_output_size = int(h.raw_size), allocator = allocator); ierr != nil {
		delete(out)
		return nil, "compressed Wasm image failed to decompress"
	}
	if len(out) != int(h.raw_size) {
		delete(out)
		return nil, "compressed Wasm image size mismatch"
	}
	got, _ := sha256(out[:])
	if got != h.raw_digest {
		delete(out)
		return nil, "compressed Wasm image digest mismatch"
	}
	return out[:], ""
}

// The module of `image` from the shipped code, or nil: there is none, it is another image's or another configuration's,
// or Wasmtime refuses it. Also returns the module's export/poll metadata from the header.
@(private)
shipped_load :: proc(image: Digest, polled: bool) -> (m: wt_module, meta: Shipped_Meta) {
	blob := shipped_code
	if len(blob) == 0 { return nil, {} }
	h, parsed_meta, ok := shipped_header_parse(blob)
	if !ok { return shipped_refuse(), {} }
	fingerprint := polled ? wt.polled_fingerprint : wt.fingerprint
	zero: Digest
	matched := h.image == image || (h.packed != zero && h.packed == image)
	if !matched { return nil, {} }   // (no refusal: any other module of this runtime, a page's, a compiled function's)
	if h.fingerprint != fingerprint { return shipped_refuse(), {} }
	code := blob[size_of(Shipped_Header):]
	if e := wasmtime_module_deserialize(polled ? wt.polled_engine : wt.engine, raw_data(code), len(code), &m); e != nil {
		wasmtime_error_delete(e)
		return shipped_refuse(), {}
	}
	shipped_pages_drop(code)
	return m, parsed_meta
}

@(private = "file")
shipped_refuse :: proc() -> wt_module {
	sync.mutex_lock(&cache.lock)
	defer sync.mutex_unlock(&cache.lock)
	cache.stats.shipped_refused += 1
	return nil
}

// The blob of `image` for an engine of the runtime's configuration (`polled`: the one without epoch checks), for the
// target's baseline CPU, which any x86-64 runs: the features of a newer one gave the engine nothing (docs/performance.md, round 37). `features`: those
// too; `native`: this machine's instead. `packed_digest`: SHA-256 of the matching WRENWZ01 file when embedded compressed. After runtime_init.
shipped_make :: proc(image: []byte, polled: bool, features: []string = nil, native := false, packed_digest: Digest = {}, allocator := context.allocator) -> (blob: []byte, err: string) {
	info, aerr := analyze_image(image)
	if aerr != "" { return nil, aerr }
	if len(info.memory_export) > SHIPPED_NAME_MAX || len(info.table_export) > SHIPPED_NAME_MAX {
		return nil, "memory or table export name exceeds shipped header limit"
	}
	engine := wt_engine_new(wt.rs, !polled, native ? "" : SHIPPED_TARGET, features)
	if engine == nil { return nil, "the engine could not start" }
	defer wasm_engine_delete(engine)
	patched, copied := patch_image(image, info)
	defer if copied { delete(patched) }
	module: wt_module
	if e := wasmtime_module_new(engine, raw_data(patched), len(patched), &module); e != nil {
		text := fmt.tprintf("compile failed: %s", wt_error_text(e, context.temp_allocator))
		wasmtime_error_delete(e)
		return nil, text
	}
	defer wasmtime_module_delete(module)
	v: wt_byte_vec
	if e := wasmtime_module_serialize(module, &v); e != nil {
		wasmtime_error_delete(e)
		return nil, "the module cannot be serialized"
	}
	defer wasm_byte_vec_delete(&v)

	word, has_poll := poll_word_of(image)
	h: Shipped_Header
	copy(h.magic[:], SHIPPED_MAGIC)
	h.image, _ = sha256(image)
	h.packed = packed_digest
	h.fingerprint = polled ? wt.polled_fingerprint : wt.fingerprint
	h.poll_word = u32le(word)
	if has_poll { h.flags |= SHIPPED_FLAG_POLLED }
	if info.memory64 { h.flags |= SHIPPED_FLAG_MEMORY64 }
	h.mem_len = u8(len(info.memory_export))
	h.table_len = u8(len(info.table_export))
	copy(h.memory_export[:], info.memory_export)
	copy(h.table_export[:], info.table_export)
	blob = make([]byte, size_of(h) + int(v.size), allocator)
	mem.copy(raw_data(blob), &h, size_of(h))
	code_src := v.data[:v.size]
	if !has_name_section(image) {
		if stripped, ok := strip_cwasm_symtab(code_src, context.temp_allocator); ok {
			delete(blob, allocator)
			blob = make([]byte, size_of(h) + len(stripped), allocator)
			mem.copy(raw_data(blob), &h, size_of(h))
			code_src = stripped
		}
	}
	copy(blob[size_of(h):], code_src)
	return blob, ""
}

// Removes trailing .symtab and .strtab sections from a Wasmtime serialized ELF64 (.cwasm) while keeping all preceding
// sections (including page-aligned .text and .rodata.wasm) at their exact offsets. Wasmtime does not read .symtab/.strtab
// during deserialization or trap backtraces; they hold only synthetic profiler symbols (~0.83 MiB for the JS engine).
// Returns (nil, false) untouched if the ELF layout does not match the expected structure.
@(private)
strip_cwasm_symtab :: proc(elf: []byte, allocator := context.allocator) -> (out: []byte, ok: bool) {
	ELF64_HDR_SIZE  :: 64
	ELF64_SHDR_SIZE :: 64
	SHT_SYMTAB      :: u32(2)
	SHT_STRTAB      :: u32(3)
	if len(elf) < ELF64_HDR_SIZE { return nil, false }
	// ELF64 little-endian magic: \x7fELF, class=2 (64-bit), data=1 (LE)
	if elf[0] != 0x7f || elf[1] != 'E' || elf[2] != 'L' || elf[3] != 'F' || elf[4] != 2 || elf[5] != 1 { return nil, false }
	rd_u16 :: proc(b: []byte, off: int) -> u16 { return u16(b[off]) | u16(b[off + 1]) << 8 }
	rd_u32 :: proc(b: []byte, off: int) -> u32 { return u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24 }
	rd_u64 :: proc(b: []byte, off: int) -> u64 { return u64(rd_u32(b, off)) | u64(rd_u32(b, off + 4)) << 32 }
	wr_u16 :: proc(b: []byte, off: int, v: u16) { b[off] = u8(v); b[off + 1] = u8(v >> 8) }
	wr_u64 :: proc(b: []byte, off: int, v: u64) { for i in 0 ..< 8 { b[off + i] = u8(v >> uint(i * 8)) } }

	shoff := rd_u64(elf, 40)
	phnum := rd_u16(elf, 56)
	shentsize := int(rd_u16(elf, 58))
	shnum := int(rd_u16(elf, 60))
	shstrndx := int(rd_u16(elf, 62))
	if phnum != 0 || shentsize != ELF64_SHDR_SIZE || shnum < 4 || shstrndx <= 0 || shstrndx >= shnum { return nil, false }
	sh_table_bytes := u64(shnum) * ELF64_SHDR_SIZE
	if shoff > u64(len(elf)) || sh_table_bytes > u64(len(elf)) - shoff { return nil, false }

	shstr_hdr := int(shoff) + shstrndx * ELF64_SHDR_SIZE
	shstr_off := rd_u64(elf, shstr_hdr + 24)
	shstr_sz := rd_u64(elf, shstr_hdr + 32)
	if shstr_off > u64(len(elf)) || shstr_sz > u64(len(elf)) - shstr_off { return nil, false }
	shstr := elf[shstr_off:shstr_off + shstr_sz]

	sec_name :: proc(shstr: []byte, name_off: u32) -> string {
		if int(name_off) >= len(shstr) { return "" }
		end := int(name_off)
		for end < len(shstr) && shstr[end] != 0 { end += 1 }
		return string(shstr[name_off:end])
	}

	drop_min_off := u64(len(elf))
	kept_max_end := u64(ELF64_HDR_SIZE)
	dropped := 0
	kept := make([dynamic]int, 0, shnum, context.temp_allocator)
	for i in 0 ..< shnum {
		h := int(shoff) + i * ELF64_SHDR_SIZE
		sh_type := rd_u32(elf, h + 4)
		sh_offset := rd_u64(elf, h + 24)
		sh_size := rd_u64(elf, h + 32)
		sh_link := int(rd_u32(elf, h + 40))
		name := sec_name(shstr, rd_u32(elf, h))
		if (sh_type == SHT_SYMTAB && name == ".symtab") || (sh_type == SHT_STRTAB && name == ".strtab") {
			if sh_offset < drop_min_off { drop_min_off = sh_offset }
			dropped += 1
			continue
		}
		// Any kept section that links to another section could have its index invalidated if we drop sections.
		if sh_link != 0 { return nil, false }
		if i != shstrndx && i != 0 {
			if sh_offset > u64(len(elf)) || sh_size > u64(len(elf)) - sh_offset { return nil, false }
			if sh_offset + sh_size > kept_max_end { kept_max_end = sh_offset + sh_size }
		}
		append(&kept, i)
	}
	if dropped == 0 || drop_min_off < kept_max_end || drop_min_off > u64(len(elf)) { return nil, false }

	new_shstr_off := drop_min_off
	new_shoff := (new_shstr_off + shstr_sz + 7) &~ u64(7)
	total := new_shoff + u64(len(kept)) * ELF64_SHDR_SIZE
	if total >= u64(len(elf)) { return nil, false }

	out = make([]byte, int(total), allocator)
	copy(out[:drop_min_off], elf[:drop_min_off])
	copy(out[new_shstr_off:new_shstr_off + shstr_sz], shstr)
	new_shstrndx := 0
	for old_i, new_i in kept {
		src_h := int(shoff) + old_i * ELF64_SHDR_SIZE
		dst_h := int(new_shoff) + new_i * ELF64_SHDR_SIZE
		copy(out[dst_h:dst_h + ELF64_SHDR_SIZE], elf[src_h:src_h + ELF64_SHDR_SIZE])
		if old_i == shstrndx {
			new_shstrndx = new_i
			wr_u64(out, dst_h + 24, new_shstr_off)
		}
	}
	wr_u64(out, 40, new_shoff)
	wr_u16(out, 60, u16(len(kept)))
	wr_u16(out, 62, u16(new_shstrndx))
	return out, true
}
