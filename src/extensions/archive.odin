package extensions

// Packed extensions (docs/extensions.md, section 3.3): a .zip, or a .crx (CRX3: a header, then a zip). The package is
// unpacked once, at install, into <profile>/extensions/<id>/package/; from then on it is read as an unpacked one.
//
// Everything here runs off the interface thread (the shell's blocking pool). A hostile archive is the case to design
// for: every entry is checked before one byte is written (a path that leaves the package, an absolute path, a drive, a
// symbolic link, more files or bytes than the limits), and each entry inflates into a buffer of its declared size, so a
// stream that expands past it fails instead of filling the memory. Zip64, encryption and methods other than stored and
// deflate are refused: the browsers' own packers do not make them.
//
// The CRX3 signature is not checked (no store: section 1). Its public key gives the id, as in Chrome.

import "core:compress/deflate"
import "core:crypto/sha2"
import "core:encoding/endian"
import "core:hash"
import "core:os"
import "core:strings"
import "wb:base"

Archive_Error :: enum u8 { None, Unreadable, Not_Archive, Bad_Crx, Unsupported, Bad_Entry, Too_Many_Files, Too_Large, Corrupt, Write_Failed }

archive_error_text :: proc(e: Archive_Error) -> string {
	switch e {
	case .None:           return ""
	case .Unreadable:     return "the file cannot be read"
	case .Not_Archive:    return "the file is not a .zip or a .crx package"
	case .Bad_Crx:        return "the .crx header is not valid (CRX3 is expected)"
	case .Unsupported:    return "the package uses a zip feature Wren does not read (Zip64, encryption or an unknown compression)"
	case .Bad_Entry:      return "the package has an entry with a path outside the package, or a symbolic link"
	case .Too_Many_Files: return "the package has more files than extensions.package.max_files"
	case .Too_Large:      return "the package is larger than extensions.package.max_bytes"
	case .Corrupt:        return "the package is damaged (an entry does not inflate or its checksum is wrong)"
	case .Write_Failed:   return "the package could not be written into the profile"
	}
	return ""
}

// One file of a zip, as its central directory describes it.
Zip_Entry :: struct {
	name:       string,   // normalised (package_path_normalize); a slice of the archive, or of the temp allocator
	method:     u16,      // 0 stored, 8 deflate
	crc:        u32,
	packed:     int,      // compressed size
	size:       int,      // uncompressed size
	local:      int,      // offset of its local header
}

Archive :: struct {
	public_key: []byte,       // the CRX3 public key (nil: a plain zip); a slice of the file's bytes
	zip:        []byte,       // the zip part
	entries:    []Zip_Entry,  // temp allocator
}

@(private = "file") CRX_MAGIC :: "Cr24"
@(private = "file") ZIP_EOCD :: 0x06054b50
@(private = "file") ZIP_CENTRAL :: 0x02014b50
@(private = "file") ZIP_LOCAL :: 0x04034b50

@(private = "file")
le16 :: proc(b: []byte, at: int) -> (u16, bool) {
	if at < 0 || at + 2 > len(b) { return 0, false }
	return endian.get_u16(b[at:], .Little)
}

@(private = "file")
le32 :: proc(b: []byte, at: int) -> (u32, bool) {
	if at < 0 || at + 4 > len(b) { return 0, false }
	return endian.get_u32(b[at:], .Little)
}

////////////////////////////////
// CRX3 (a protobuf header: CrxFileHeader)

@(private = "file")
pb_varint :: proc(b: []byte, i: ^int) -> (u64, bool) {
	v: u64
	shift: uint
	for i^ < len(b) && shift < 64 {
		c := b[i^]
		i^ += 1
		v |= u64(c & 0x7F) << shift
		if c & 0x80 == 0 { return v, true }
		shift += 7
	}
	return 0, false
}

// The next field of a protobuf message: its number, and its bytes when it is length-delimited (wire type 2). Fields of
// other wire types are skipped over (data nil). False at the end or on a malformed message.
@(private = "file")
pb_next :: proc(b: []byte, i: ^int) -> (field: u64, data: []byte, ok: bool) {
	if i^ >= len(b) { return }
	tag, tok := pb_varint(b, i)
	if !tok { return }
	field = tag >> 3
	switch tag & 7 {
	case 0:
		if _, vok := pb_varint(b, i); !vok { return }
	case 1:
		if i^ + 8 > len(b) { return }
		i^ += 8
	case 5:
		if i^ + 4 > len(b) { return }
		i^ += 4
	case 2:
		n, nok := pb_varint(b, i)
		if !nok || n > u64(len(b) - i^) { return }
		data = b[i^:i^ + int(n)]
		i^ += int(n)
	case: return
	}
	return field, data, true
}

// The public key of a CRX3 header: the key whose hash is the header's crx_id (signed_header_data), else the first
// RSA key, else the first ECDSA key. nil when the header has none.
@(private = "file")
crx_public_key :: proc(header: []byte) -> []byte {
	crx_id: []byte
	keys := make([dynamic][]byte, 0, 4, context.temp_allocator)
	ecdsa := make([dynamic][]byte, 0, 2, context.temp_allocator)
	i := 0
	for {
		field, data, ok := pb_next(header, &i)
		if !ok { break }
		switch field {
		case 2, 3:   // sha256_with_rsa, sha256_with_ecdsa: AsymmetricKeyProof {1: public_key, 2: signature}
			j := 0
			for {
				f, d, fok := pb_next(data, &j)
				if !fok { break }
				if f != 1 || len(d) == 0 { continue }
				if field == 2 { append(&keys, d) } else { append(&ecdsa, d) }
			}
		case 10000:  // signed_header_data: SignedData {1: crx_id}
			j := 0
			for {
				f, d, fok := pb_next(data, &j)
				if !fok { break }
				if f == 1 { crx_id = d }
			}
		}
	}
	append(&keys, ..ecdsa[:])
	if len(crx_id) == 16 {
		for k in keys {
			c: sha2.Context_256
			sha2.init_256(&c)
			sha2.update(&c, k)
			digest: [sha2.DIGEST_SIZE_256]byte
			sha2.final(&c, digest[:])
			if string(digest[:16]) == string(crx_id) { return k }
		}
	}
	return len(keys) > 0 ? keys[0] : nil
}

////////////////////////////////
// Reading

// Opens the bytes of a .zip or a .crx: the zip's central directory is read and every entry checked against the limits.
// Nothing is inflated yet.
archive_open :: proc(data: []byte, s: ^Settings) -> (a: Archive, err: Archive_Error) {
	a.zip = data
	if len(data) >= 4 && string(data[:4]) == CRX_MAGIC {
		version, vok := le32(data, 4)
		hsize, hok := le32(data, 8)
		if !vok || !hok || version != 3 || int(hsize) > len(data) - 12 { return a, .Bad_Crx }
		a.public_key = crx_public_key(data[12:12 + int(hsize)])
		if a.public_key == nil { return a, .Bad_Crx }
		a.zip = data[12 + int(hsize):]
	}
	a.entries, err = zip_entries(a.zip, s)
	return
}

@(private = "file")
zip_entries :: proc(z: []byte, s: ^Settings) -> ([]Zip_Entry, Archive_Error) {
	// the end of central directory record: 22 bytes, then a comment of at most 65535
	eocd := -1
	for p := len(z) - 22; p >= 0 && p >= len(z) - 22 - 65535; p -= 1 {
		if sig, _ := le32(z, p); sig == ZIP_EOCD { eocd = p; break }
	}
	if eocd < 0 { return nil, .Not_Archive }
	count, _ := le16(z, eocd + 10)
	cd_size, _ := le32(z, eocd + 12)
	cd_at, _ := le32(z, eocd + 16)
	if count == 0xFFFF || cd_size == 0xFFFFFFFF || cd_at == 0xFFFFFFFF { return nil, .Unsupported }
	if int(count) > s.package_max_files { return nil, .Too_Many_Files }
	if int(cd_at) + int(cd_size) > len(z) { return nil, .Corrupt }
	out := make([dynamic]Zip_Entry, 0, int(count), context.temp_allocator)
	seen := make(map[string]bool, int(count), context.temp_allocator)
	total: i64
	at := int(cd_at)
	for _ in 0 ..< int(count) {
		sig, ok := le32(z, at)
		if !ok || sig != ZIP_CENTRAL { return nil, .Corrupt }
		flags, _ := le16(z, at + 8)
		method, _ := le16(z, at + 10)
		crc, _ := le32(z, at + 16)
		packed, _ := le32(z, at + 20)
		size, _ := le32(z, at + 24)
		name_len, _ := le16(z, at + 28)
		extra_len, _ := le16(z, at + 30)
		comment_len, _ := le16(z, at + 32)
		attrs, _ := le32(z, at + 38)
		local, _ := le32(z, at + 42)
		name_at := at + 46
		if name_at + int(name_len) > len(z) { return nil, .Corrupt }
		raw := string(z[name_at:name_at + int(name_len)])
		at = name_at + int(name_len) + int(extra_len) + int(comment_len)
		if flags & 1 != 0 { return nil, .Unsupported }   // encrypted
		if packed == 0xFFFFFFFF || size == 0xFFFFFFFF || local == 0xFFFFFFFF { return nil, .Unsupported }   // Zip64
		if strings.has_suffix(raw, "/") { continue }   // a folder: made with its files
		// the high half of the attributes is the Unix mode when a Unix tool made the archive: a symbolic link is refused
		if (attrs >> 16) & 0o170000 == 0o120000 { return nil, .Bad_Entry }
		if strings.has_prefix(raw, "/") { return nil, .Bad_Entry }   // absolute (normalise would take the slash off)
		name, nok := package_path_normalize(raw, context.temp_allocator)
		if !nok || name == "" { return nil, .Bad_Entry }
		if method != 0 && method != 8 { return nil, .Unsupported }
		if seen[name] { return nil, .Bad_Entry }   // the same file twice: which one wins is ambiguous
		seen[name] = true
		total += i64(size)
		if total > s.package_max_bytes { return nil, .Too_Large }
		append(&out, Zip_Entry{name = name, method = method, crc = crc, packed = int(packed), size = int(size), local = int(local)})
	}
	return out[:], .None
}

// The bytes of one entry (inflated, checked against its CRC-32). The caller frees them (allocator).
archive_read :: proc(a: ^Archive, e: Zip_Entry, allocator := context.allocator) -> ([]byte, Archive_Error) {
	z := a.zip
	sig, ok := le32(z, e.local)
	if !ok || sig != ZIP_LOCAL { return nil, .Corrupt }
	name_len, _ := le16(z, e.local + 26)
	extra_len, _ := le16(z, e.local + 28)
	from := e.local + 30 + int(name_len) + int(extra_len)
	if from + e.packed > len(z) { return nil, .Corrupt }
	src := z[from:from + e.packed]
	out: []byte
	switch {
	case e.size == 0:
		if e.packed > 2 { return nil, .Corrupt }   // (an empty file: nothing, or the 2 bytes of an empty deflate block)
		out = make([]byte, 0, allocator)
	case e.method == 0:
		if e.packed != e.size { return nil, .Corrupt }
		out = make([]byte, e.size, allocator)
		copy(out, src)
	case e.method == 8:
		buf := make([dynamic]byte, allocator)
		if derr := deflate.inflate_raw(&buf, src, e.size, e.size, allocator); derr != nil || len(buf) != e.size {
			delete(buf)
			return nil, .Corrupt
		}
		out = buf[:]
	case:
		return nil, .Unsupported
	}
	if hash.crc32(out) != e.crc {
		delete(out, allocator)
		return nil, .Corrupt
	}
	return out, .None
}

// The entry named `name` (false: none).
archive_find :: proc(a: ^Archive, name: string) -> (Zip_Entry, bool) {
	for e in a.entries { if e.name == name { return e, true } }
	return {}, false
}

// Writes every entry under `dest` (a folder made for it: what was there before goes first). A blocking call. Each
// entry's bytes are given back once written: the unpack holds one file at a time, not the whole package.
archive_unpack :: proc(a: ^Archive, dest: string) -> Archive_Error {
	_ = os.remove_all(dest)
	if os.make_directory_all(dest) != nil { return .Write_Failed }
	pa := base.process_allocator()
	for e in a.entries {
		data, err := archive_read(a, e, pa)
		if err != .None { return err }
		path := strings.concatenate({dest, "/", e.name}, context.temp_allocator)
		ok := true
		if i := strings.last_index_byte(path, '/'); i > len(dest) { ok = os.make_directory_all(path[:i]) == nil }
		if ok { ok = os.write_entire_file(path, data) == nil }
		delete(data, pa)
		if !ok { return .Write_Failed }
	}
	return .None
}

////////////////////////////////
// Install

// The id of a packed extension: the CRX3 key's, else the manifest's "key", else the hash of the archive's absolute path
// (as an unpacked extension's comes from its folder).
archive_id :: proc(a: ^Archive, abs_path: string, s: ^Settings, allocator := context.allocator) -> string {
	if a.public_key != nil { return id_from_bytes(a.public_key, allocator) }
	if e, ok := archive_find(a, "manifest.json"); ok && e.size <= s.manifest_max_bytes {
		if raw, err := archive_read(a, e, context.temp_allocator); err == .None {
			probe_problems := make([dynamic]Problem, 0, 4, context.temp_allocator)
			probe, _ := manifest_parse(string(raw), nil, s, &probe_problems, context.temp_allocator)
			if probe.key != "" {
				if kid, kok := id_from_key(probe.key, allocator); kok { return kid }
			}
		}
	}
	return id_from_path(abs_path, allocator)
}

// The folder a packed extension is unpacked into: <profile>/extensions/<id>/package, or a folder of the system's
// temporary folder when the profile is not kept (temp allocator).
archive_dest :: proc(profile_dir, id: string) -> string {
	if profile_dir != "" { return strings.concatenate({extension_profile_dir(profile_dir, id), "/package"}, context.temp_allocator) }
	tmp := os.temp_directory(context.temp_allocator) or_else "."
	return strings.concatenate({tmp, "/wren-extensions/", id, "/package"}, context.temp_allocator)
}

// Installs a .zip or .crx file (a blocking call): it is read, checked, unpacked, then loaded as image_load loads a
// folder. The result's path is the unpacked folder, its source the archive's kind.
archive_install :: proc(path: string, s: Settings, ui_language: string, profile_dir: string) -> (r: Load_Result) {
	pa := base.process_allocator()
	settings := s
	abs, aerr := os.get_absolute_path(path, context.temp_allocator)
	if aerr != nil { abs = path }
	abs, _ = strings.replace_all(abs, "\\", "/", context.temp_allocator)
	fi, serr := os.stat(abs, context.temp_allocator)
	if serr != nil { r.error = strings.clone(archive_error_text(.Unreadable), pa); return }
	if fi.size > settings.package_max_bytes { r.error = strings.clone(archive_error_text(.Too_Large), pa); return }
	data, rerr := os.read_entire_file(abs, pa)
	if rerr != nil { r.error = strings.clone(archive_error_text(.Unreadable), pa); return }
	defer delete(data, pa)
	a, err := archive_open(data, &settings)
	if err != .None { r.error = strings.clone(archive_error_text(err), pa); return }
	id := archive_id(&a, abs, &settings, context.temp_allocator)
	dest := archive_dest(profile_dir, id)
	if uerr := archive_unpack(&a, dest); uerr != .None { r.error = strings.clone(archive_error_text(uerr), pa); return }
	r = image_load(dest, s, ui_language, profile_dir, id)
	r.source = a.public_key != nil ? .Crx : .Zip
	return
}

// Whether a path names a packed extension (by its extension, as the system's file dialog filters it).
archive_path :: proc(path: string) -> bool {
	p := strings.trim_space(path)
	if len(p) < 4 { return false }
	ext := p[len(p) - 4:]
	return ascii_fold_equal(ext, ".zip") || ascii_fold_equal(ext, ".crx")
}
