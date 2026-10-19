// Package webfont: turns the bytes of a downloaded font into an sfnt (TrueType / OpenType) file a font engine can load.
// TrueType and OpenType files are checked and copied; WOFF 1.0 files (W3C WOFF File Format 1.0) are unpacked: every
// table is inflated (zlib, with the output bounded by the caller's limit) and the sfnt table directory is rebuilt. WOFF2
// files are decoded by the built-in native library (native\media\src\woff2.rs: Brotli, then the glyf / loca / hmtx
// transforms reversed, every size checked against the same limit). A collection (.ttc, or a WOFF2 of one) gives its
// first face, as other browsers do, rebuilt as a standalone sfnt.
package webfont

import "base:runtime"
import "core:bytes"
import "core:compress"
import "core:compress/zlib"
import "core:slice"

foreign import wren_media {
	"../../build/media/wren_media.lib",
	"system:ws2_32.lib",
	"system:advapi32.lib",
	"system:userenv.lib",
	"system:ntdll.lib",
	"system:kernel32.lib",
	"system:bcrypt.lib",
	"system:msvcrt.lib",
	"system:ucrt.lib",
	"system:vcruntime.lib",
}

@(private)
Wm_Bytes_Proc :: #type proc "c" (user: rawptr, len: uint) -> [^]u8

@(private)
Wm_Byte_Sink :: struct {
	user:  rawptr,
	alloc: Wm_Bytes_Proc,
}

@(private, default_calling_convention = "c")
foreign wren_media {
	wm_woff2_decode :: proc(data: [^]u8, len: uint, max_bytes: u64, sink: ^Wm_Byte_Sink) -> i32 ---
}

Format :: enum u8 { Unknown, Truetype, Opentype, Collection, Woff, Woff2, Eot }

Error :: enum u8 {
	None,
	Too_Small,
	Unknown_Format,
	Unsupported_Woff2,
	Unsupported_Collection,   // .ttc: one file, several faces; not chosen from here
	Unsupported_Eot,
	Malformed,
	Too_Large,                // the file or what it expands to is over the limit
	Decompression_Failed,
}

@(private)
be16 :: #force_inline proc(b: []byte, at: int) -> u32 { return u32(b[at]) << 8 | u32(b[at + 1]) }
@(private)
be32 :: #force_inline proc(b: []byte, at: int) -> u32 { return u32(b[at]) << 24 | u32(b[at + 1]) << 16 | u32(b[at + 2]) << 8 | u32(b[at + 3]) }
@(private)
put16 :: #force_inline proc(b: []byte, at: int, v: u32) { b[at], b[at + 1] = u8(v >> 8), u8(v) }
@(private)
put32 :: #force_inline proc(b: []byte, at: int, v: u32) { b[at], b[at + 1], b[at + 2], b[at + 3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v) }

TAG_TRUE :: 0x74727565   // 'true' (Apple TrueType)
TAG_OTTO :: 0x4F54544F   // 'OTTO' (CFF outlines)
TAG_TTCF :: 0x74746366   // 'ttcf'
TAG_WOFF :: 0x774F4646   // 'wOFF'
TAG_WOF2 :: 0x774F4632   // 'wOF2'

// The container format, from the first bytes.
sniff :: proc(data: []byte) -> Format {
	if len(data) < 4 { return .Unknown }
	switch be32(data, 0) {
	case 0x00010000, TAG_TRUE: return .Truetype
	case TAG_OTTO: return .Opentype
	case TAG_TTCF: return .Collection
	case TAG_WOFF: return .Woff
	case TAG_WOF2: return .Woff2
	}
	if len(data) >= 36 && data[34] == 0x4C && data[35] == 0x50 { return .Eot }   // 'LP' magic of embedded OpenType
	return .Unknown
}

// An sfnt file (allocated with `allocator`) from a font file of any supported format; nil and an error otherwise.
decode :: proc(data: []byte, max_bytes: int, allocator := context.allocator) -> (sfnt: []byte, format: Format, err: Error) {
	format = sniff(data)
	if len(data) > max_bytes { return nil, format, .Too_Large }
	switch format {
	case .Truetype, .Opentype:
		if e := validate_sfnt(data); e != .None { return nil, format, e }
		out := make([]byte, len(data), allocator)
		copy(out, data)
		return out, format, .None
	case .Woff:
		sfnt, err = unwoff(data, max_bytes, allocator)
		return
	case .Woff2:
		sfnt, err = unwoff2(data, max_bytes, allocator)
		return
	case .Collection:
		sfnt, err = collection_face(data, 0, allocator)
		return
	case .Eot: return nil, format, .Unsupported_Eot
	case .Unknown:
	}
	if len(data) < 12 { return nil, format, .Too_Small }
	return nil, format, .Unknown_Format
}

Table :: struct {
	tag:      u32,
	checksum: u32,
	offset:   u32,
	length:   u32,
}

// The table directory of an sfnt, every table inside the file.
read_tables :: proc(data: []byte, allocator := context.temp_allocator) -> ([]Table, Error) {
	if len(data) < 12 { return nil, .Too_Small }
	n := int(be16(data, 4))
	if n == 0 || n > 4096 { return nil, .Malformed }
	if 12 + 16 * n > len(data) { return nil, .Malformed }
	out := make([]Table, n, allocator)
	for i in 0 ..< n {
		at := 12 + 16 * i
		t := Table{tag = be32(data, at), checksum = be32(data, at + 4), offset = be32(data, at + 8), length = be32(data, at + 12)}
		if u64(t.offset) + u64(t.length) > u64(len(data)) { return nil, .Malformed }
		out[i] = t
	}
	return out, .None
}

// The structure a font engine relies on: a table directory whose tables lie inside the file, and the tables every
// font needs (cmap, head, hhea, hmtx, maxp, name; glyf+loca or CFF/CFF2).
validate_sfnt :: proc(data: []byte) -> Error {
	tables, err := read_tables(data)
	if err != .None { return err }
	has :: proc(ts: []Table, tag: string) -> bool {
		t := u32(tag[0]) << 24 | u32(tag[1]) << 16 | u32(tag[2]) << 8 | u32(tag[3])
		for x in ts { if x.tag == t { return true } }
		return false
	}
	for req in ([?]string{"cmap", "head", "hhea", "hmtx", "maxp"}) { if !has(tables, req) { return .Malformed } }
	if !(has(tables, "glyf") && has(tables, "loca")) && !has(tables, "CFF ") && !has(tables, "CFF2") { return .Malformed }
	return .None
}

////////////////////////////////
// WOFF 1.0

@(private)
WOFF_HEADER :: 44
@(private)
WOFF_ENTRY :: 20

@(private)
align4 :: #force_inline proc(n: int) -> int { return (n + 3) &~ 3 }

@(private)
unwoff :: proc(data: []byte, max_bytes: int, allocator: runtime.Allocator) -> ([]byte, Error) {
	if len(data) < WOFF_HEADER { return nil, .Too_Small }
	flavor := be32(data, 4)
	length := int(be32(data, 8))
	n := int(be16(data, 12))
	if length != len(data) || n == 0 || n > 4096 || be16(data, 14) != 0 { return nil, .Malformed }
	if WOFF_HEADER + WOFF_ENTRY * n > len(data) { return nil, .Malformed }
	Entry :: struct { tag, offset, comp, orig, checksum: u32 }
	entries := make([]Entry, n, context.temp_allocator)
	total := 12 + 16 * n
	for i in 0 ..< n {
		at := WOFF_HEADER + WOFF_ENTRY * i
		e := Entry{tag = be32(data, at), offset = be32(data, at + 4), comp = be32(data, at + 8), orig = be32(data, at + 12), checksum = be32(data, at + 16)}
		if u64(e.offset) + u64(e.comp) > u64(len(data)) || e.comp > e.orig { return nil, .Malformed }
		total += align4(int(e.orig))
		if total > max_bytes { return nil, .Too_Large }
		entries[i] = e
	}
	slice.sort_by(entries, proc(a, b: Entry) -> bool { return a.tag < b.tag })
	for i in 1 ..< n { if entries[i].tag == entries[i - 1].tag { return nil, .Malformed } }

	out := make([]byte, total, allocator)
	put32(out, 0, flavor)
	put16(out, 4, u32(n))
	sel := 0
	for (1 << uint(sel + 1)) <= n { sel += 1 }
	search := (1 << uint(sel)) * 16
	put16(out, 6, u32(search))
	put16(out, 8, u32(sel))
	put16(out, 10, u32(n * 16 - search))
	pos := 12 + 16 * n
	for e, i in entries {
		rec := 12 + 16 * i
		put32(out, rec, e.tag)
		put32(out, rec + 4, e.checksum)
		put32(out, rec + 8, u32(pos))
		put32(out, rec + 12, e.orig)
		src := data[e.offset:][:e.comp]
		dst := out[pos:][:e.orig]
		if e.comp == e.orig {
			copy(dst, src)
		} else if ok := inflate_into(src, dst); !ok {
			delete(out, allocator)
			return nil, .Decompression_Failed
		}
		pos += align4(int(e.orig))
	}
	if e := validate_sfnt(out); e != .None {
		delete(out, allocator)
		return nil, e
	}
	return out, .None
}

////////////////////////////////
// WOFF2

@(private)
unwoff2 :: proc(data: []byte, max_bytes: int, allocator: runtime.Allocator) -> ([]byte, Error) {
	State :: struct {
		out:       []byte,
		allocator: runtime.Allocator,
		ctx:       runtime.Context,
		max:       int,
	}
	st := State{allocator = allocator, ctx = context, max = max_bytes}
	give :: proc "c" (user: rawptr, n: uint) -> [^]u8 {
		s := (^State)(user)
		context = s.ctx
		if n == 0 || n > uint(s.max) || s.out != nil { return nil }
		buf, err := make([]byte, int(n), s.allocator)
		if err != nil { return nil }
		s.out = buf
		return raw_data(buf)
	}
	sink := Wm_Byte_Sink{user = &st, alloc = give}
	rc := wm_woff2_decode(raw_data(data), uint(len(data)), u64(max(max_bytes, 0)), &sink)
	if rc != 0 {
		if st.out != nil { delete(st.out, allocator) }
		switch rc {
		case 3: return nil, .Unsupported_Woff2      // a transform the format does not define
		case 9: return nil, .Too_Large
		case 10: return nil, .Malformed
		}
		return nil, .Decompression_Failed
	}
	out := st.out
	if sniff(out) == .Collection {
		face, err := collection_face(out, 0, allocator)
		delete(out, allocator)
		return face, err
	}
	if e := validate_sfnt(out); e != .None {
		delete(out, allocator)
		return nil, e
	}
	return out, .None
}

////////////////////////////////
// Collections

// Face `index` of a TrueType Collection, as a standalone sfnt (its tables copied after a new directory).
collection_face :: proc(ttc: []byte, index: int, allocator := context.allocator) -> ([]byte, Error) {
	if len(ttc) < 12 || be32(ttc, 0) != TAG_TTCF { return nil, .Malformed }
	n := int(be32(ttc, 8))
	if n == 0 || n > 65536 || 12 + 4 * n > len(ttc) { return nil, .Malformed }
	if index < 0 || index >= n { return nil, .Malformed }
	off := int(be32(ttc, 12 + 4 * index))
	if off + 12 > len(ttc) { return nil, .Malformed }
	count := int(be16(ttc, off + 4))
	if count == 0 || count > 4096 || off + 12 + 16 * count > len(ttc) { return nil, .Malformed }
	total := 12 + 16 * count
	for i in 0 ..< count {
		rec := off + 12 + 16 * i
		t_off, t_len := u64(be32(ttc, rec + 8)), u64(be32(ttc, rec + 12))
		if t_off + t_len > u64(len(ttc)) { return nil, .Malformed }
		total += align4(int(t_len))
	}
	out := make([]byte, total, allocator)
	copy(out[:12], ttc[off:off + 12])
	pos := 12 + 16 * count
	for i in 0 ..< count {
		rec := off + 12 + 16 * i
		dst := 12 + 16 * i
		copy(out[dst:dst + 16], ttc[rec:rec + 16])
		t_off, t_len := int(be32(ttc, rec + 8)), int(be32(ttc, rec + 12))
		put32(out, dst + 8, u32(pos))
		copy(out[pos:pos + t_len], ttc[t_off:t_off + t_len])
		pos += align4(t_len)
	}
	if e := validate_sfnt(out); e != .None {
		delete(out, allocator)
		return nil, e
	}
	return out, .None
}

// Inflates a zlib stream that must expand to exactly len(dst) bytes. The decompressor's memory is bounded: a stream
// that would expand past that (a "zip bomb") fails instead of exhausting memory.
@(private)
inflate_into :: proc(src, dst: []byte) -> bool {
	// the decompressor starts with an output buffer of at least COMPRESS_OUTPUT_ALLOCATE_MIN and may double it once
	budget := Budget{parent = context.allocator, left = max(len(dst), compress.COMPRESS_OUTPUT_ALLOCATE_MIN) * 3 + 256 * 1024}
	context.allocator = budget_allocator(&budget)
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	if err := zlib.inflate(src, &buf, false, len(dst)); err != nil { return false }
	out := bytes.buffer_to_bytes(&buf)
	if len(out) != len(dst) { return false }
	copy(dst, out)
	return true
}

@(private)
Budget :: struct {
	parent: runtime.Allocator,
	left:   int,
}

@(private)
budget_allocator :: proc(b: ^Budget) -> runtime.Allocator {
	return runtime.Allocator{procedure = budget_proc, data = b}
}

@(private)
budget_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	b := (^Budget)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if size > b.left { return nil, .Out_Of_Memory }
		b.left -= size
	case .Resize, .Resize_Non_Zeroed:
		grow := size - old_size
		if grow > b.left { return nil, .Out_Of_Memory }
		b.left -= max(grow, 0)
	}
	return b.parent.procedure(b.parent.data, mode, size, alignment, old_memory, old_size, loc)
}

