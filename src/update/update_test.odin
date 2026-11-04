package update

import "core:crypto/ed25519"
import "core:encoding/base64"
import "core:strings"
import "core:testing"

// A key pair of the tests (public on purpose: it signs nothing real).
TEST_SEED := [32]byte{'w', 'r', 'e', 'n', '-', 'u', 'p', 'd', 'a', 't', 'e', '-', 't', 'e', 's', 't', '-', 's', 'e', 'e', 'd', '-', '0', '0', '0', '0', '0', '0', '0', '0', '0', '1'}
OTHER_SEED := [32]byte{'w', 'r', 'e', 'n', '-', 'o', 't', 'h', 'e', 'r', '-', 'u', 'p', 'd', 'a', 't', 'e', '-', 'k', 'e', 'y', '-', '0', '0', '0', '0', '0', '0', '0', '0', '0', '2'}

@(private = "file")
test_file :: proc(n: int) -> []byte {
	data := make([]byte, n, context.temp_allocator)
	for i in 0 ..< n { data[i] = byte(i * 31 + i / 7) }
	return data
}

@(private = "file")
test_manifest :: proc(version: string, data: []byte) -> Manifest {
	return {
		version = version, platform = PLATFORM_WINDOWS_X64,
		file = expected_file_name(version, PLATFORM_WINDOWS_X64, context.temp_allocator),
		sha256 = sha256_hex(data, context.temp_allocator), size = i64(len(data)), published = "2026-11-05",
	}
}

@(private = "file")
test_public :: proc(seed: []byte = nil) -> string {
	s := seed
	if s == nil { s = TEST_SEED[:] }
	key, _ := public_key_of(s, context.temp_allocator)
	return key
}

// The manifest's bytes and the signature of `seed`.
@(private = "file")
signed :: proc(m: Manifest, seed: []byte = nil) -> (manifest: []byte, sig: string) {
	s := seed
	if s == nil { s = TEST_SEED[:] }
	manifest = manifest_bytes(m, context.temp_allocator)
	sig, _ = sign(s, manifest, context.temp_allocator)
	return
}

@(test)
a_signed_manifest_is_read :: proc(t: ^testing.T) {
	data := test_file(MIN_BINARY)
	manifest, sig := signed(test_manifest("0.6.29", data))
	m, err := verify(manifest, sig, test_public(), PLATFORM_WINDOWS_X64, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, m.version, "0.6.29")
	testing.expect_value(t, m.file, "wren-0.6.29-windows-x64.exe")
	testing.expect_value(t, m.size, i64(MIN_BINARY))
	testing.expect_value(t, m.sha256, sha256_hex(data, context.temp_allocator))
	testing.expect_value(t, check_newer(m, "0.6.28"), Error.None)
}

@(test)
another_key_is_refused :: proc(t: ^testing.T) {
	manifest, sig := signed(test_manifest("0.6.29", test_file(MIN_BINARY)), OTHER_SEED[:])
	_, err := verify(manifest, sig, test_public(), PLATFORM_WINDOWS_X64, context.temp_allocator)
	testing.expect_value(t, err, Error.Bad_Signature)
}

@(test)
an_altered_manifest_is_refused :: proc(t: ^testing.T) {
	manifest, sig := signed(test_manifest("0.6.29", test_file(MIN_BINARY)))
	// one digit of the version changes: still a valid manifest, no longer a signed one
	text, _ := strings.replace(string(manifest), "0.6.29", "0.6.30", 1, context.temp_allocator)
	altered := transmute([]byte)text
	_, err := verify(altered, sig, test_public(), PLATFORM_WINDOWS_X64, context.temp_allocator)
	testing.expect_value(t, err, Error.Bad_Signature)
	// and the hash: an attacker who swaps the file must change it
	text2, _ := strings.replace(string(manifest), `"sha256":"`, `"sha256":"0`, 1, context.temp_allocator)
	_, err2 := verify(transmute([]byte)text2, sig, test_public(), PLATFORM_WINDOWS_X64, context.temp_allocator)
	testing.expect(t, err2 == .Bad_Signature, "a changed checksum does not verify")
}

@(test)
a_damaged_signature_is_refused :: proc(t: ^testing.T) {
	manifest, sig := signed(test_manifest("0.6.29", test_file(MIN_BINARY)))
	b := transmute([]byte)strings.clone(sig, context.temp_allocator)
	b[10] = b[10] == 'A' ? 'B' : 'A'
	_, err := verify(manifest, string(b), test_public(), PLATFORM_WINDOWS_X64, context.temp_allocator)
	testing.expect_value(t, err, Error.Bad_Signature)

	_, e2 := verify(manifest, "", test_public(), PLATFORM_WINDOWS_X64, context.temp_allocator)
	testing.expect_value(t, e2, Error.Bad_Encoding)
	_, e3 := verify(manifest, "not base64!!", test_public(), PLATFORM_WINDOWS_X64, context.temp_allocator)
	testing.expect_value(t, e3, Error.Bad_Encoding)
	// 64 bytes are expected
	short := base64.encode(make([]byte, 32, context.temp_allocator), base64.ENC_URL_TABLE, context.temp_allocator, {.No_Padding})
	_, e4 := verify(manifest, short, test_public(), PLATFORM_WINDOWS_X64, context.temp_allocator)
	testing.expect_value(t, e4, Error.Bad_Encoding)
}

@(test)
the_signature_is_for_updates_only :: proc(t: ^testing.T) {
	// the same bytes signed with another context (a licence's, or none): refused
	manifest := manifest_bytes(test_manifest("0.6.29", test_file(MIN_BINARY)), context.temp_allocator)
	for context_text in ([]string{"wren-license-v1\n", ""}) {
		priv: ed25519.Private_Key
		testing.expect(t, ed25519.private_key_set_bytes(&priv, TEST_SEED[:]), "key")
		msg := make([]byte, len(context_text) + len(manifest), context.temp_allocator)
		copy(msg, context_text)
		copy(msg[len(context_text):], manifest)
		raw: [ed25519.SIGNATURE_SIZE]byte
		ed25519.sign(&priv, msg, raw[:])
		sig := base64.encode(raw[:], base64.ENC_URL_TABLE, context.temp_allocator, {.No_Padding})
		_, err := verify(manifest, sig, test_public(), PLATFORM_WINDOWS_X64, context.temp_allocator)
		testing.expectf(t, err == .Bad_Signature, "context %q must not verify, got %v", context_text, err)
	}
}

@(test)
keys_are_checked :: proc(t: ^testing.T) {
	manifest, sig := signed(test_manifest("0.6.29", test_file(MIN_BINARY)))
	_, e1 := verify(manifest, sig, "", PLATFORM_WINDOWS_X64, context.temp_allocator)
	testing.expect_value(t, e1, Error.No_Public_Key)
	_, e2 := verify(manifest, sig, "not a key", PLATFORM_WINDOWS_X64, context.temp_allocator)
	testing.expect_value(t, e2, Error.Bad_Public_Key)
	_, e3 := verify(manifest, sig, "AAAA", PLATFORM_WINDOWS_X64, context.temp_allocator)
	testing.expect_value(t, e3, Error.Bad_Public_Key)
	testing.expect(t, UPDATE_PUBLIC_KEY == "" || UPDATE_PUBLIC_KEY != test_public(), "the production key is not the test key")
	if UPDATE_PUBLIC_KEY != "" {
		_, ok := public_key_decode(UPDATE_PUBLIC_KEY)
		testing.expect(t, ok, "UPDATE_PUBLIC_KEY is 32 bytes of base64url")
	}
}

@(test)
only_a_newer_version_is_an_update :: proc(t: ^testing.T) {
	m := test_manifest("0.6.29", test_file(16))
	testing.expect_value(t, check_newer(m, "0.6.28"), Error.None)
	testing.expect_value(t, check_newer(m, "0.5.99"), Error.None)
	testing.expect_value(t, check_newer(m, "0.6.29"), Error.Not_Newer)   // the same: nothing to do
	testing.expect_value(t, check_newer(m, "0.6.30"), Error.Not_Newer)   // an older one offered as an update: a downgrade
	testing.expect_value(t, check_newer(m, "0.7.0"), Error.Not_Newer)
	testing.expect_value(t, check_newer(m, "1.0.0"), Error.Not_Newer)
	// numbers, not text: 0.6.9 is older than 0.6.10
	m2 := test_manifest("0.6.10", test_file(16))
	testing.expect_value(t, check_newer(m2, "0.6.9"), Error.None)
	// a development build (anything but X.Y.Z) is updated by hand
	testing.expect_value(t, check_newer(m, "0.6.28-dev"), Error.Bad_Version)
	testing.expect_value(t, check_newer(m, ""), Error.Bad_Version)
}

@(test)
a_release_is_checked_in_one_call :: proc(t: ^testing.T) {
	data := test_file(MIN_BINARY)
	manifest, sig := signed(test_manifest("0.6.29", data))
	pub := test_public()

	m, err := check_release(manifest, sig, pub, PLATFORM_WINDOWS_X64, "0.6.28", "0.6.29", context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, m.version, "0.6.29")

	// a release that claims no version (the caller has none): the manifest's own is used
	_, e0 := check_release(manifest, sig, pub, PLATFORM_WINDOWS_X64, "0.6.28", "", context.temp_allocator)
	testing.expect_value(t, e0, Error.None)

	// the signed manifest of 0.6.29 carried by the release of 0.6.31: a replay of an older one
	_, e1 := check_release(manifest, sig, pub, PLATFORM_WINDOWS_X64, "0.6.28", "0.6.31", context.temp_allocator)
	testing.expect_value(t, e1, Error.Version_Mismatch)

	// already up to date, or ahead
	_, e2 := check_release(manifest, sig, pub, PLATFORM_WINDOWS_X64, "0.6.29", "0.6.29", context.temp_allocator)
	testing.expect_value(t, e2, Error.Not_Newer)
	_, e3 := check_release(manifest, sig, pub, PLATFORM_WINDOWS_X64, "0.7.0", "0.6.29", context.temp_allocator)
	testing.expect_value(t, e3, Error.Not_Newer)

	// the signature comes first: another key says so before anything else is looked at
	_, e4 := check_release(manifest, sig, test_public(OTHER_SEED[:]), PLATFORM_WINDOWS_X64, "0.6.28", "0.6.29", context.temp_allocator)
	testing.expect_value(t, e4, Error.Bad_Signature)
}

@(test)
versions_are_strict :: proc(t: ^testing.T) {
	for good in ([]string{"0.0.0", "0.6.28", "10.20.30", "999999.0.1"}) { testing.expectf(t, version_valid(good), "%q is a version", good) }
	for bad in ([]string{"", "1", "1.2", "1.2.3.4", "v1.2.3", "1.2.3-rc1", "1.2.3+x", "1..3", "1.2.-3", "1.2.3 ", " 1.2.3", "1.2.x", "1234567.0.0", "1.2.3\n"}) {
		testing.expectf(t, !version_valid(bad), "%q is not a version", bad)
	}
	order, ok := version_compare("0.6.28", "0.6.9")
	testing.expect(t, ok && order == 1, "0.6.28 > 0.6.9")
	order, ok = version_compare("1.0.0", "0.99.99")
	testing.expect(t, ok && order == 1, "1.0.0 > 0.99.99")
	_, ok = version_compare("1.0.0", "1.0")
	testing.expect(t, !ok, "an incomplete version does not compare")
}

@(test)
platform_product_and_schema_are_checked :: proc(t: ^testing.T) {
	data := test_file(MIN_BINARY)
	good := test_manifest("0.6.29", data)

	manifest, sig := signed(good)
	_, e1 := verify(manifest, sig, test_public(), "linux-x64", context.temp_allocator)
	testing.expect_value(t, e1, Error.Wrong_Platform)

	other := good
	other.platform = "linux-x64"
	other.file = expected_file_name("0.6.29", "linux-x64", context.temp_allocator)
	m2, s2 := signed(other)
	_, e2 := verify(m2, s2, test_public(), PLATFORM_WINDOWS_X64, context.temp_allocator)
	testing.expect_value(t, e2, Error.Wrong_Platform)

	// a signed manifest of another product or schema (made with the same key, as a leak would allow)
	for pair in ([][2]string{{`"product":"wren"`, `"product":"other"`}, {`"schema":1`, `"schema":2`}}) {
		text, _ := strings.replace(string(manifest), pair[0], pair[1], 1, context.temp_allocator)
		altered := transmute([]byte)text
		resigned, _ := sign(TEST_SEED[:], altered, context.temp_allocator)
		_, err := verify(altered, resigned, test_public(), PLATFORM_WINDOWS_X64, context.temp_allocator)
		testing.expectf(t, err == .Wrong_Product || err == .Wrong_Schema, "%q: got %v", pair[1], err)
	}
}

@(test)
a_signed_manifest_cannot_name_another_file :: proc(t: ^testing.T) {
	data := test_file(MIN_BINARY)
	for name in ([]string{
		"..\\evil.exe", "../evil.exe", "C:\\Windows\\evil.exe", "wren-0.6.29-windows-x64.exe.bat", "evil.exe", "",
		"wren-0.6.28-windows-x64.exe", "wren-0.6.29-windows-x64.exe\x00.txt", "wren-0.6.29-windows-x64.EXE", "https://evil.example/wren.exe",
	}) {
		m := test_manifest("0.6.29", data)
		m.file = name
		manifest, sig := signed(m)
		_, err := verify(manifest, sig, test_public(), PLATFORM_WINDOWS_X64, context.temp_allocator)
		testing.expectf(t, err == .Bad_File_Name || err == .Bad_Manifest, "%q must be refused, got %v", name, err)
	}
}

@(test)
checksums_and_sizes_are_checked :: proc(t: ^testing.T) {
	data := test_file(MIN_BINARY)
	sixty_four := strings.repeat("a", 64, context.temp_allocator)
	for hash in ([]string{
		"", "abc", strings.repeat("g", 64, context.temp_allocator), strings.repeat("A", 64, context.temp_allocator),
		strings.repeat("a", 63, context.temp_allocator), strings.repeat("a", 65, context.temp_allocator),
		strings.concatenate({sixty_four, " "}, context.temp_allocator),
	}) {
		m := test_manifest("0.6.29", data)
		m.sha256 = hash
		manifest, sig := signed(m)
		_, err := verify(manifest, sig, test_public(), PLATFORM_WINDOWS_X64, context.temp_allocator)
		testing.expectf(t, err == .Bad_Hash, "%q must be refused, got %v", hash, err)
	}
	for size in ([]i64{0, -1, MIN_BINARY - 1, MAX_BINARY + 1, 1 << 40}) {
		m := test_manifest("0.6.29", data)
		m.size = size
		manifest, sig := signed(m)
		_, err := verify(manifest, sig, test_public(), PLATFORM_WINDOWS_X64, context.temp_allocator)
		testing.expectf(t, err == .Bad_Size, "size %d must be refused, got %v", size, err)
	}
	// the bounds themselves are fine
	for size in ([]i64{MIN_BINARY, MAX_BINARY}) {
		m := test_manifest("0.6.29", data)
		m.size = size
		manifest, sig := signed(m)
		_, err := verify(manifest, sig, test_public(), PLATFORM_WINDOWS_X64, context.temp_allocator)
		testing.expectf(t, err == .None, "size %d is allowed, got %v", size, err)
	}
}

@(test)
a_manifest_of_the_wrong_length_is_refused :: proc(t: ^testing.T) {
	_, sig := signed(test_manifest("0.6.29", test_file(MIN_BINARY)))
	_, e1 := verify(nil, sig, test_public(), PLATFORM_WINDOWS_X64, context.temp_allocator)
	testing.expect_value(t, e1, Error.Too_Long)
	big := make([]byte, MAX_MANIFEST + 1, context.temp_allocator)
	_, e2 := verify(big, sig, test_public(), PLATFORM_WINDOWS_X64, context.temp_allocator)
	testing.expect_value(t, e2, Error.Too_Long)
	// not JSON, but signed: refused as a manifest, never read as anything
	junk := transmute([]byte)string("this is not json")
	js, _ := sign(TEST_SEED[:], junk, context.temp_allocator)
	_, e3 := verify(junk, js, test_public(), PLATFORM_WINDOWS_X64, context.temp_allocator)
	testing.expect_value(t, e3, Error.Bad_Manifest)
}

@(test)
the_downloaded_file_is_checked_against_the_manifest :: proc(t: ^testing.T) {
	data := test_file(MIN_BINARY)
	m := test_manifest("0.6.29", data)
	testing.expect_value(t, check_binary(m, data), Error.None)

	// one byte changed, same length: the hash catches it
	tampered := make([]byte, len(data), context.temp_allocator)
	copy(tampered, data)
	tampered[len(tampered) / 2] ~= 0x01
	testing.expect_value(t, check_binary(m, tampered), Error.Hash_Mismatch)

	// truncated, or longer: the length catches it before the hash is computed
	testing.expect_value(t, check_binary(m, data[:len(data) - 1]), Error.Size_Mismatch)
	longer := make([]byte, len(data) + 1, context.temp_allocator)
	copy(longer, data)
	testing.expect_value(t, check_binary(m, longer), Error.Size_Mismatch)
	testing.expect_value(t, check_binary(m, nil), Error.Size_Mismatch)
}

@(test)
sha256_is_the_standard_one :: proc(t: ^testing.T) {
	// "abc" (FIPS 180-2) and the empty message
	testing.expect_value(t, sha256_hex(transmute([]byte)string("abc"), context.temp_allocator), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	testing.expect_value(t, sha256_hex(nil, context.temp_allocator), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}

@(test)
a_manifest_made_here_is_the_manifest_read_back :: proc(t: ^testing.T) {
	data := test_file(MIN_BINARY)
	m := test_manifest("12.34.56", data)
	manifest, sig := signed(m)
	read, err := verify(manifest, sig, test_public(), PLATFORM_WINDOWS_X64, context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, read.version, m.version)
	testing.expect_value(t, read.published, m.published)
	// the layout is fixed: the same manifest, the same bytes, so the same signature
	again, sig2 := signed(m)
	testing.expect(t, string(manifest) == string(again), "the manifest's bytes are stable")
	testing.expect_value(t, sig, sig2)   // (Ed25519 is deterministic)
}
