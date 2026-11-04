// Package update: the signed manifest of a release, and what a program does with it before it installs anything.
//
// A release publishes, for each platform, a manifest (a small JSON file) and its detached signature:
//
//   update-windows-x64.json       {"schema":1,"product":"wren","version":"0.6.29","platform":"windows-x64",
//                                  "file":"wren-0.6.29-windows-x64.exe","size":69877760,"sha256":"<64 hex>","published":"2026-11-05"}
//   update-windows-x64.json.sig   base64url (no padding) of the Ed25519 signature of SIGN_CONTEXT + the manifest's bytes
//
// The signature is made with the update key (wrentool update sign), a pair of its own: the public half is built into every
// Wren (public_key.odin), the private half is in the release workflow's secrets and in secrets/production.yaml. It is not the
// key that signs licences. A program that updates itself:
//
//   1. verify(manifest, signature, UPDATE_PUBLIC_KEY, its platform): the signature, then the content (read only once signed)
//   2. check_newer(manifest, its version): never the same version, never an older one (a downgrade replays an old, signed,
//      vulnerable release: the version is in what is signed, and it must grow)
//   3. downloads `m.file`, then check_binary(m, bytes): the length, then the SHA-256, both from the signed manifest
//   4. only then writes anything over the program (the caller's job: nothing here touches a file)
//
// Anything else is refused with an Error and nothing is installed. The manifest names its file by the one name a release gives
// it (expected_file_name), so a signed manifest cannot point the program at another path.
package update

import "base:runtime"
import "core:crypto/ed25519"
import "core:crypto/sha2"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

SIGN_CONTEXT :: "wren-update-v1\n"   // what a signature covers before the manifest: an update signature is no licence signature and no other message
SCHEMA :: 1
PRODUCT :: "wren"
PLATFORM_WINDOWS_X64 :: "windows-x64"

MAX_MANIFEST :: 16 * 1024            // bytes of a manifest: a real one is about 300
MAX_SIGNATURE_TEXT :: 256            // an Ed25519 signature is 86 characters of base64url
MIN_BINARY :: 1 << 20                // a program of less than 1 MiB is not Wren (and a manifest cannot ask for an empty file)
MAX_BINARY :: 256 << 20              // 256 MiB: network.max_response_bytes' default, and ten times the size of Wren

Manifest :: struct {
	version:   string,   // X.Y.Z: digits only (a pre-release is never offered)
	platform:  string,   // windows-x64
	file:      string,   // the name of the release asset, exactly expected_file_name(version, platform)
	sha256:    string,   // 64 lowercase hex digits of the file
	published: string,   // a date, for people
	size:      i64,      // bytes of the file
}

Error :: enum {
	None,
	Too_Long,            // the manifest is empty or larger than MAX_MANIFEST
	Bad_Encoding,        // the signature is not base64url of 64 bytes
	No_Public_Key,
	Bad_Public_Key,
	Bad_Signature,       // not signed by the update key, or the manifest was changed
	Bad_Manifest,        // signed, but not a manifest this program understands
	Wrong_Schema,
	Wrong_Product,
	Wrong_Platform,
	Bad_Version,
	Not_Newer,           // the same version, or an older one
	Version_Mismatch,    // a signed manifest, but of another version than the release that carried it
	Bad_File_Name,
	Bad_Hash,
	Bad_Size,
	Size_Mismatch,       // the file's length is not the signed one
	Hash_Mismatch,       // the file's SHA-256 is not the signed one
}

error_text :: proc(e: Error) -> string {
	switch e {
	case .None:           return "no error"
	case .Too_Long:       return "the update manifest is empty or too large"
	case .Bad_Encoding:   return "the update signature is not well formed"
	case .No_Public_Key:  return "this build has no update key: it cannot check an update"
	case .Bad_Public_Key: return "the update key built into this build is not valid"
	case .Bad_Signature:  return "the update is not signed by Froment Software (or was altered): refused"
	case .Bad_Manifest:   return "the update manifest is not understood"
	case .Wrong_Schema:   return "the update manifest is of another format"
	case .Wrong_Product:  return "the update manifest is not for Wren"
	case .Wrong_Platform: return "the update is for another platform"
	case .Bad_Version:    return "the update names an invalid version"
	case .Not_Newer:      return "the update is not newer than the installed version"
	case .Version_Mismatch: return "the signed manifest is for another version than the release that carried it"
	case .Bad_File_Name:  return "the update names an unexpected file"
	case .Bad_Hash:       return "the update manifest carries an invalid checksum"
	case .Bad_Size:       return "the update manifest carries an invalid size"
	case .Size_Mismatch:  return "the downloaded file is not the size that was signed: refused"
	case .Hash_Mismatch:  return "the downloaded file does not match its signed checksum: refused"
	}
	return "unknown error"
}

manifest_destroy :: proc(m: ^Manifest, allocator := context.allocator) {
	delete(m.version, allocator); delete(m.platform, allocator); delete(m.file, allocator)
	delete(m.sha256, allocator); delete(m.published, allocator)
	m^ = {}
}

////////////////////////////////
// Names and versions

// The name of the release asset of `version` on `platform`: the one a manifest may name.
expected_file_name :: proc(version, platform: string, allocator := context.allocator) -> string {
	return fmt.aprintf("wren-%s-%s.exe", version, platform, allocator = allocator)
}

// X.Y.Z, three numbers of digits only (at most six each, no sign, no suffix). Never a pre-release or a build label.
version_parts :: proc(v: string) -> (parts: [3]int, ok: bool) {
	fields := strings.split(v, ".", context.temp_allocator)
	if len(fields) != 3 { return {}, false }
	for f, i in fields {
		if len(f) == 0 || len(f) > 6 { return {}, false }
		n := 0
		for c in transmute([]u8)f {
			if c < '0' || c > '9' { return {}, false }
			n = n * 10 + int(c - '0')
		}
		parts[i] = n
	}
	return parts, true
}

version_valid :: proc(v: string) -> bool { _, ok := version_parts(v); return ok }

// -1, 0 or 1; false when either is not X.Y.Z.
version_compare :: proc(a, b: string) -> (order: int, ok: bool) {
	pa, oka := version_parts(a)
	pb, okb := version_parts(b)
	if !oka || !okb { return 0, false }
	for i in 0 ..< 3 {
		if pa[i] < pb[i] { return -1, true }
		if pa[i] > pb[i] { return 1, true }
	}
	return 0, true
}

////////////////////////////////
// Keys and signatures

@(private)
b64_decode :: proc(s: string) -> ([]byte, base64.Error) {
	return base64.decode(s, base64.DEC_URL_TABLE, allocator = context.temp_allocator, options = {.Strict, .No_Padding})
}

public_key_decode :: proc(text: string) -> (key: [ed25519.PUBLIC_KEY_SIZE]byte, ok: bool) {
	b, err := b64_decode(strings.trim_space(text))
	if err != nil || len(b) != ed25519.PUBLIC_KEY_SIZE { return {}, false }
	copy(key[:], b)
	return key, true
}

// The seed of a private key written as base64url (32 bytes).
seed_decode :: proc(text: string) -> (seed: [32]byte, ok: bool) {
	b, err := b64_decode(strings.trim_space(text))
	if err != nil || len(b) != 32 { return {}, false }
	copy(seed[:], b)
	return seed, true
}

seed_encode :: proc(seed: []byte, allocator := context.allocator) -> string {
	return base64.encode(seed, base64.ENC_URL_TABLE, allocator, {.No_Padding})
}

// The public key (base64url) of a private key.
public_key_of :: proc(seed: []byte, allocator := context.allocator) -> (key: string, ok: bool) {
	priv: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&priv, seed) { return "", false }
	defer ed25519.private_key_clear(&priv)
	pub: [ed25519.PUBLIC_KEY_SIZE]byte
	ed25519.private_key_public_bytes(&priv, pub[:])
	return base64.encode(pub[:], base64.ENC_URL_TABLE, allocator, {.No_Padding}), true
}

// SIGN_CONTEXT then the manifest: what the signature covers.
signed_bytes :: proc(manifest: []byte, allocator := context.temp_allocator) -> []byte {
	out := make([]byte, len(SIGN_CONTEXT) + len(manifest), allocator)
	copy(out, SIGN_CONTEXT)
	copy(out[len(SIGN_CONTEXT):], manifest)
	return out
}

// The detached signature (base64url, no padding) of `manifest` made with the private key `seed`. For the release tool and the tests.
sign :: proc(seed: []byte, manifest: []byte, allocator := context.allocator) -> (signature: string, ok: bool) {
	priv: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&priv, seed) { return "", false }
	defer ed25519.private_key_clear(&priv)
	sig: [ed25519.SIGNATURE_SIZE]byte
	ed25519.sign(&priv, signed_bytes(manifest), sig[:])
	return base64.encode(sig[:], base64.ENC_URL_TABLE, allocator, {.No_Padding}), true
}

////////////////////////////////
// The manifest

// The bytes of a manifest (a fixed layout: the signature covers exactly these bytes, and a verifier reads whatever they say).
manifest_bytes :: proc(m: Manifest, allocator := context.allocator) -> []byte {
	text := fmt.aprintf(
		`{{"schema":%d,"product":"%s","version":"%s","platform":"%s","file":"%s","size":%d,"sha256":"%s","published":"%s"}}` + "\n",
		SCHEMA, PRODUCT, m.version, m.platform, m.file, m.size, m.sha256, m.published, allocator = context.temp_allocator,
	)
	return transmute([]byte)strings.clone(text, allocator)
}

// A manifest checked for what it says, once it is known to be signed or by a caller that made it. Never trust it before the signature.
@(private)
manifest_read :: proc(data: []byte, platform: string, allocator: runtime.Allocator) -> (m: Manifest, err: Error) {
	// a manifest is text: no NUL or other control character anywhere in it, whatever a string's parser would make of one (a file name
	// cut short at a NUL is a different name)
	for c in data {
		if (c < ' ' && c != '\n' && c != '\r' && c != '\t') || c == 0x7f { return {}, .Bad_Manifest }
	}
	v, perr := json.parse(data, parse_integers = true, allocator = context.temp_allocator)   // (without it every number is a float: a size is an integer)
	if perr != .None { return {}, .Bad_Manifest }
	obj, is_obj := v.(json.Object)
	if !is_obj { return {}, .Bad_Manifest }

	schema, has_schema := obj["schema"].(json.Integer)
	if !has_schema || schema != SCHEMA { return {}, .Wrong_Schema }
	product, has_product := obj["product"].(json.String)
	if !has_product || string(product) != PRODUCT { return {}, .Wrong_Product }
	plat, has_plat := obj["platform"].(json.String)
	if !has_plat || string(plat) != platform { return {}, .Wrong_Platform }
	version, has_version := obj["version"].(json.String)
	if !has_version || !version_valid(string(version)) { return {}, .Bad_Version }
	file, has_file := obj["file"].(json.String)
	if !has_file || string(file) != expected_file_name(string(version), platform, context.temp_allocator) { return {}, .Bad_File_Name }
	sha, has_sha := obj["sha256"].(json.String)
	if !has_sha || !hex_digest_ok(string(sha)) { return {}, .Bad_Hash }
	size, has_size := obj["size"].(json.Integer)
	if !has_size || size < MIN_BINARY || size > MAX_BINARY { return {}, .Bad_Size }
	published, _ := obj["published"].(json.String)
	if len(published) > 32 { return {}, .Bad_Manifest }
	for c in transmute([]u8)string(published) { if c < ' ' || c == 0x7f { return {}, .Bad_Manifest } }

	m.version = strings.clone(string(version), allocator)
	m.platform = strings.clone(string(plat), allocator)
	m.file = strings.clone(string(file), allocator)
	m.sha256 = strings.clone(string(sha), allocator)
	m.published = strings.clone(string(published), allocator)
	m.size = i64(size)
	return m, .None
}

// 64 lowercase hex digits.
hex_digest_ok :: proc(s: string) -> bool {
	if len(s) != 64 { return false }
	for c in transmute([]u8)s {
		switch c {
		case '0' ..= '9', 'a' ..= 'f':
		case: return false
		}
	}
	return true
}

// Reads and checks a manifest against `public_key` (base64url of the 32 bytes) for `platform`. On success the fields are owned by
// `allocator` (manifest_destroy). Nothing but a manifest signed with the matching private key is read at all.
verify :: proc(manifest: []byte, signature, public_key, platform: string, allocator := context.allocator) -> (m: Manifest, err: Error) {
	if len(manifest) == 0 || len(manifest) > MAX_MANIFEST { return {}, .Too_Long }
	sig_text := strings.trim_space(signature)
	if sig_text == "" || len(sig_text) > MAX_SIGNATURE_TEXT { return {}, .Bad_Encoding }
	sig, serr := b64_decode(sig_text)
	if serr != nil || len(sig) != ed25519.SIGNATURE_SIZE { return {}, .Bad_Encoding }

	if public_key == "" { return {}, .No_Public_Key }
	pk_bytes, pk_ok := public_key_decode(public_key)
	if !pk_ok { return {}, .Bad_Public_Key }
	pk: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&pk, pk_bytes[:]) { return {}, .Bad_Public_Key }
	if !ed25519.verify(&pk, signed_bytes(manifest, context.temp_allocator), sig) { return {}, .Bad_Signature }

	// signed by us: its content is read only now
	return manifest_read(manifest, platform, allocator)
}

// What a program does with the manifest and the signature it downloaded for a release: the signature and the content (verify),
// that it is the version the release announced (a signed manifest of an old version put under a new release is a replay), and
// that it is newer than `current`. `announced` is the version of the release's tag ("" when none is claimed).
check_release :: proc(manifest: []byte, signature, public_key, platform, current, announced: string, allocator := context.allocator) -> (m: Manifest, err: Error) {
	m, err = verify(manifest, signature, public_key, platform, allocator)
	if err != .None { return {}, err }
	if announced != "" && m.version != announced { manifest_destroy(&m, allocator); return {}, .Version_Mismatch }
	if e := check_newer(m, current); e != .None { manifest_destroy(&m, allocator); return {}, e }
	return m, .None
}

// Whether `m` is an update for a program of version `current` (X.Y.Z): strictly newer. An installed version that is not X.Y.Z
// (a development build) is refused too: such a build is updated by hand.
check_newer :: proc(m: Manifest, current: string) -> Error {
	order, ok := version_compare(m.version, current)
	if !ok { return .Bad_Version }
	if order <= 0 { return .Not_Newer }
	return .None
}

////////////////////////////////
// The file

sha256_hex :: proc(data: []byte, allocator := context.allocator) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	digest: [sha2.DIGEST_SIZE_256]byte
	sha2.final(&ctx, digest[:])
	HEX := "0123456789abcdef"
	out := make([]byte, 64, allocator)
	for b, i in digest {
		out[i * 2] = HEX[b >> 4]
		out[i * 2 + 1] = HEX[b & 0xf]
	}
	return string(out)
}

// The downloaded bytes against the signed manifest: the length first, then the SHA-256. Both must match.
check_binary :: proc(m: Manifest, data: []byte) -> Error {
	if i64(len(data)) != m.size { return .Size_Mismatch }
	if sha256_hex(data, context.temp_allocator) != m.sha256 { return .Hash_Mismatch }
	return .None
}
