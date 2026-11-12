package extensions

import "core:compress/deflate"
import "core:encoding/endian"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:base"

// A zip made in memory: each entry stored, or deflated (`deflated`), with an optional Unix mode (`mode`: 0 none).
@(private = "file")
Test_Entry :: struct {
	name:     string,
	data:     string,
	deflated: bool,
	mode:     u32,
}

@(private = "file")
put16 :: proc(b: ^[dynamic]byte, v: u16) {
	x: [2]byte
	endian.put_u16(x[:], .Little, v)
	append(b, ..x[:])
}

@(private = "file")
put32 :: proc(b: ^[dynamic]byte, v: u32) {
	x: [4]byte
	endian.put_u32(x[:], .Little, v)
	append(b, ..x[:])
}

@(private = "file")
zip_make :: proc(entries: []Test_Entry) -> []byte {
	out := make([dynamic]byte, 0, 1024, context.temp_allocator)
	central := make([dynamic]byte, 0, 512, context.temp_allocator)
	for e in entries {
		raw := transmute([]byte)e.data
		body := raw
		method := u16(0)
		if e.deflated {
			packed := make([dynamic]byte, context.temp_allocator)
			_ = deflate.deflate_raw_to_dynamic(&packed, raw, allocator = context.temp_allocator)
			body, method = packed[:], 8
		}
		crc := hash.crc32(raw)
		local := u32(len(out))
		put32(&out, 0x04034b50); put16(&out, 20); put16(&out, 0); put16(&out, method); put16(&out, 0); put16(&out, 0)
		put32(&out, crc); put32(&out, u32(len(body))); put32(&out, u32(len(raw))); put16(&out, u16(len(e.name))); put16(&out, 0)
		append(&out, ..transmute([]byte)e.name)
		append(&out, ..body)
		put32(&central, 0x02014b50); put16(&central, 0x031E); put16(&central, 20); put16(&central, 0); put16(&central, method)
		put16(&central, 0); put16(&central, 0); put32(&central, crc); put32(&central, u32(len(body))); put32(&central, u32(len(raw)))
		put16(&central, u16(len(e.name))); put16(&central, 0); put16(&central, 0); put16(&central, 0); put16(&central, 0)
		put32(&central, e.mode << 16); put32(&central, local)
		append(&central, ..transmute([]byte)e.name)
	}
	cd_at := u32(len(out))
	append(&out, ..central[:])
	put32(&out, 0x06054b50); put16(&out, 0); put16(&out, 0); put16(&out, u16(len(entries))); put16(&out, u16(len(entries)))
	put32(&out, u32(len(central))); put32(&out, cd_at); put16(&out, 0)
	return out[:]
}

@(private = "file")
pb_put_varint :: proc(b: ^[dynamic]byte, v: u64) {
	x := v
	for x >= 0x80 { append(b, byte(x & 0x7F) | 0x80); x >>= 7 }
	append(b, byte(x))
}

@(private = "file")
pb_put_bytes :: proc(b: ^[dynamic]byte, field: u64, data: []byte) {
	pb_put_varint(b, field << 3 | 2)
	pb_put_varint(b, u64(len(data)))
	append(b, ..data)
}

// A CRX3 file: its header names `key` as an RSA public key (and its crx_id), then the zip.
@(private = "file")
crx_make :: proc(key: []byte, zip: []byte) -> []byte {
	proof := make([dynamic]byte, context.temp_allocator)
	pb_put_bytes(&proof, 1, key)
	pb_put_bytes(&proof, 2, transmute([]byte)string("signature"))
	header := make([dynamic]byte, context.temp_allocator)
	pb_put_bytes(&header, 2, proof[:])
	out := make([dynamic]byte, context.temp_allocator)
	append(&out, ..transmute([]byte)string("Cr24"))
	put32(&out, 3)
	put32(&out, u32(len(header)))
	append(&out, ..header[:])
	append(&out, ..zip)
	return out[:]
}

@(private = "file")
MANIFEST_MIN :: `{"manifest_version": 3, "name": "Packed", "version": "1.0"}`

@(test)
test_archive_zip_read :: proc(t: ^testing.T) {
	s := settings_default()
	z := zip_make({
		{name = "manifest.json", data = MANIFEST_MIN},
		{name = "dir/", data = ""},
		{name = "dir/big.js", data = strings.repeat("console.log(1);\n", 200, context.temp_allocator), deflated = true},
		{name = "empty.txt", data = ""},
	})
	a, err := archive_open(z, &s)
	testing.expect_value(t, err, Archive_Error.None)
	testing.expect_value(t, len(a.entries), 3)   // (the folder entry is not a file)
	testing.expect(t, a.public_key == nil)
	e, ok := archive_find(&a, "dir/big.js")
	testing.expect(t, ok && e.method == 8)
	data, rerr := archive_read(&a, e, context.temp_allocator)
	testing.expect_value(t, rerr, Archive_Error.None)
	testing.expect_value(t, len(data), 16 * 200)
	m, _ := archive_find(&a, "manifest.json")
	md, _ := archive_read(&a, m, context.temp_allocator)
	testing.expect_value(t, string(md), MANIFEST_MIN)
	em, _ := archive_find(&a, "empty.txt")
	ed, eerr := archive_read(&a, em, context.temp_allocator)
	testing.expect(t, eerr == .None && len(ed) == 0)
	// a zip without a key: the id comes from the archive's path
	testing.expect_value(t, archive_id(&a, "/x/p.zip", &s, context.temp_allocator), id_from_path("/x/p.zip", context.temp_allocator))
}

@(test)
test_archive_hostile_entries :: proc(t: ^testing.T) {
	s := settings_default()
	cases := []struct { name: string, entry: Test_Entry, want: Archive_Error }{
		{"a parent path", {name = "../evil.js", data = "x"}, .Bad_Entry},
		{"a deeper parent path", {name = "a/../../evil.js", data = "x"}, .Bad_Entry},
		{"an absolute path", {name = "/etc/evil", data = "x"}, .Bad_Entry},
		{"a drive", {name = "C:/evil", data = "x"}, .Bad_Entry},
		{"a backslash", {name = "a\\..\\..\\evil", data = "x"}, .Bad_Entry},
		{"a symbolic link", {name = "link", data = "/etc/passwd", mode = 0o120777}, .Bad_Entry},
	}
	for c in cases {
		_, err := archive_open(zip_make({{name = "manifest.json", data = MANIFEST_MIN}, c.entry}), &s)
		testing.expectf(t, err == c.want, "%s: %v, expected %v", c.name, err, c.want)
	}
	// the same file twice
	_, dup := archive_open(zip_make({{name = "a.js", data = "1"}, {name = "./a.js", data = "2"}}), &s)
	testing.expect_value(t, dup, Archive_Error.Bad_Entry)
	// limits: files, then bytes (declared sizes are counted before anything inflates)
	small := s
	small.package_max_files = 1
	_, many := archive_open(zip_make({{name = "a", data = "1"}, {name = "b", data = "2"}}), &small)
	testing.expect_value(t, many, Archive_Error.Too_Many_Files)
	small = s
	small.package_max_bytes = 10
	_, big := archive_open(zip_make({{name = "a", data = "0123456789abc"}}), &small)
	testing.expect_value(t, big, Archive_Error.Too_Large)
	// not an archive, a cut one, a changed byte
	_, junk := archive_open(transmute([]byte)string("hello, this is not a zip file at all"), &s)
	testing.expect_value(t, junk, Archive_Error.Not_Archive)
	z := zip_make({{name = "a.js", data = "abcdef"}})
	_, cut := archive_open(z[:len(z) - 30], &s)
	testing.expect(t, cut != .None)
	bad := make([]byte, len(z), context.temp_allocator)
	copy(bad, z)
	bad[30 + 4] ~= 0xFF   // a byte of the stored data (after the 30-byte local header and the 4-byte name)
	a, oerr := archive_open(bad, &s)
	testing.expect_value(t, oerr, Archive_Error.None)
	_, rerr := archive_read(&a, a.entries[0], context.temp_allocator)
	testing.expect_value(t, rerr, Archive_Error.Corrupt)
}

@(test)
test_archive_crx3 :: proc(t: ^testing.T) {
	s := settings_default()
	key := transmute([]byte)string("a DER public key, as bytes")
	z := zip_make({{name = "manifest.json", data = MANIFEST_MIN}})
	a, err := archive_open(crx_make(key, z), &s)
	testing.expect_value(t, err, Archive_Error.None)
	testing.expect_value(t, string(a.public_key), string(key))
	testing.expect_value(t, len(a.entries), 1)
	testing.expect_value(t, archive_id(&a, "/x/p.crx", &s, context.temp_allocator), id_from_bytes(key, context.temp_allocator))
	// CRX2, a header longer than the file, a header with no key
	v2 := crx_make(key, z)
	v2[4] = 2
	_, e2 := archive_open(v2, &s)
	testing.expect_value(t, e2, Archive_Error.Bad_Crx)
	long := crx_make(key, z)
	long[8], long[9], long[10], long[11] = 0xFF, 0xFF, 0xFF, 0x7F
	_, el := archive_open(long, &s)
	testing.expect_value(t, el, Archive_Error.Bad_Crx)
	_, ek := archive_open(crx_make(nil, z), &s)
	testing.expect_value(t, ek, Archive_Error.Bad_Crx)
}

@(test)
test_archive_install :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/wren_ext_test_archive_%d", os.temp_directory(context.temp_allocator) or_else ".", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer { _ = os.remove_all(root) }
	key := transmute([]byte)string("another DER public key")
	file := strings.concatenate({root, "/ext.crx"}, context.temp_allocator)
	_ = os.write_entire_file(file, crx_make(key, zip_make({
		{name = "manifest.json", data = MANIFEST_MIN},
		{name = "js/bg.js", data = "self.x = 1;", deflated = true},
	})))
	profile := strings.concatenate({root, "/profile"}, context.temp_allocator)
	r := archive_install(file, settings_default(), "en-US", profile)
	defer load_result_destroy(&r)
	testing.expectf(t, r.error == "", "the install failed: %s", r.error)
	testing.expect_value(t, r.source, Source_Kind.Crx)
	id := id_from_bytes(key, context.temp_allocator)
	testing.expect(t, r.image != nil && r.image.id == id)
	testing.expect(t, r.image != nil && image_has_file(r.image, "js/bg.js"))
	// unpacked into the profile; loading that folder again with the id it got keeps it (the browser's next start)
	dest := archive_dest(profile, id)
	testing.expect(t, os.is_dir(dest))
	again := image_load(dest, settings_default(), "en-US", profile, id)
	defer load_result_destroy(&again)
	testing.expect(t, again.image != nil && again.image.id == id)
}

////////////////////////////////
// state.txt and idle

@(test)
test_state_listeners :: proc(t: ^testing.T) {
	text := state_serialize({"runtime.onMessage", "alarms.onAlarm", "idle.onStateChanged"})
	testing.expect_value(t, text, "1\tlisteners\talarms.onAlarm idle.onStateChanged runtime.onMessage\n")
	got := state_parse(text)
	testing.expect_value(t, len(got), 3)
	testing.expect_value(t, got[0], "alarms.onAlarm")
	// another version, junk names, an empty list
	testing.expect_value(t, len(state_parse("2\tlisteners\ta.b\n")), 0)
	testing.expect_value(t, len(state_parse("1\tlisteners\tnodot a.b\n")), 1)
	testing.expect_value(t, len(state_parse(state_serialize(nil))), 0)
}

// The stored listeners are the last run script's: a browser start keeps them, a reload (a new script) drops them.
@(test)
test_state_survives_a_start_not_a_reload :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/wren_ext_test_state_%d", os.temp_directory(context.temp_allocator) or_else ".", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer { _ = os.remove_all(root) }
	_ = os.write_entire_file(strings.concatenate({root, "/manifest.json"}, context.temp_allocator), transmute([]byte)string(MANIFEST_MIN))
	reg: Registry
	registry_init(&reg, settings_default(), "", "en-US")
	defer registry_destroy(&reg)

	r := image_load(root, settings_default(), "en-US", "")
	defer load_result_destroy(&r)
	if !testing.expect(t, r.image != nil && r.image.ok) { return }
	id := strings.clone(r.image.id, context.temp_allocator)
	r.state_text = strings.clone("1\tlisteners\truntime.onMessage alarms.onAlarm\n", base.process_allocator())
	registry_add_listed(&reg, List_Entry{id = id, path = root, enabled = true})   // (the browser's start: the list first)
	e := registry_adopt(&reg, &r, false)
	if !testing.expect(t, e != nil) { return }
	testing.expect(t, e.listeners_known && len(e.listeners) == 2)

	r2 := image_load(root, settings_default(), "en-US", "")
	defer load_result_destroy(&r2)
	r2.state_text = strings.clone("1\tlisteners\truntime.onMessage\n", base.process_allocator())
	e2 := registry_adopt(&reg, &r2, false)   // a reload
	testing.expect(t, e2 == e && !e.listeners_known && len(e.listeners) == 0)
}

@(test)
test_idle_state :: proc(t: ^testing.T) {
	testing.expect_value(t, idle_state_of(0, 0, false), Idle_State.Active)
	testing.expect_value(t, idle_state_of(59.9, 0, false), Idle_State.Active)
	testing.expect_value(t, idle_state_of(60, 0, false), Idle_State.Idle)            // the default interval: 60 s
	testing.expect_value(t, idle_state_of(15, 5, false), Idle_State.Idle)            // an interval below 15 s is raised to 15
	testing.expect_value(t, idle_state_of(14, 5, false), Idle_State.Active)
	testing.expect_value(t, idle_state_of(100, 600, false), Idle_State.Active)
	testing.expect_value(t, idle_state_of(0, 0, true), Idle_State.Locked)
}
