package license

import "base:runtime"
import "core:crypto/ed25519"
import "core:encoding/base64"
import "core:encoding/json"
import "core:strings"

// Wren's support licence: a signed statement that someone supports the development. It unlocks nothing; the browser
// only reads it to say who the supporter is (about:wren). It is checked with no network access: an Ed25519 signature
// made offline (src/tools/license, tools\license.ps1) over the payload, verified against the public key built into
// the program (public_key.odin).
//
// Text form (what is pasted, or kept in a .wrenlicense file; white space and lines starting with '#' are ignored):
//
//     WREN1.<payload>.<signature>
//
// payload: base64url, no padding, of the JSON {"product":"wren","edition":"supporter","name":..,"email":..,"date":..,"order":..}.
// signature: base64url, no padding, of the Ed25519 signature over SIGN_CONTEXT followed by the payload's bytes exactly
// as they are in the text (so there is nothing to canonicalize, and a key signed for another use cannot pass for one).

PRODUCT      :: "wren"
VERSION_TAG  :: "WREN1"
SIGN_CONTEXT :: "wren-license-v1\n"
FILE_EXTENSION :: ".wrenlicense"

// Longest key text taken, and longest value of a field: a licence is a few hundred bytes.
MAX_TEXT  :: 8192
MAX_FIELD :: 256

Edition :: enum u8 { Unknown, Supporter, Patron }

License :: struct {
	product: string,
	edition: string,   // "supporter", "patron" (a newer edition a build does not know is still read: edition_of says Unknown)
	name:    string,
	email:   string,
	date:    string,   // the day it was issued, "2026-10-22"
	order:   string,   // the order number
}

Error :: enum u8 {
	None,
	Empty,
	Too_Long,
	Bad_Format,        // not WREN1.<payload>.<signature>
	Bad_Encoding,      // not base64url
	Bad_Payload,       // not the JSON of a licence
	Wrong_Product,     // signed for another program
	Bad_Signature,     // altered, or signed with another key
	No_Public_Key,     // this build has no key to check licences with
	Bad_Public_Key,
}

error_text :: proc(e: Error) -> string {
	switch e {
	case .None:          return ""
	case .Empty:         return "The licence is empty."
	case .Too_Long:      return "That is too long to be a licence key."
	case .Bad_Format:    return "That is not a Wren licence key (it should look like WREN1.…)."
	case .Bad_Encoding:  return "The licence key is damaged: it is not valid base64url text."
	case .Bad_Payload:   return "The licence key is damaged: its content is not a licence."
	case .Wrong_Product: return "This licence is for another product."
	case .Bad_Signature: return "The signature does not match: the key was altered or was not issued by Froment Software."
	case .No_Public_Key: return "This build of Wren has no licence key to check it with."
	case .Bad_Public_Key: return "The public key for licences is not valid."
	}
	return ""
}

edition_of :: proc(l: License) -> Edition {
	switch l.edition {
	case "supporter": return .Supporter
	case "patron":    return .Patron
	}
	return .Unknown
}

edition_title :: proc(e: string) -> string {
	switch e {
	case "supporter": return "Supporter"
	case "patron":    return "Patron"
	}
	return e
}

license_destroy :: proc(l: ^License) {
	delete(l.product); delete(l.edition); delete(l.name); delete(l.email); delete(l.date); delete(l.order)
	l^ = {}
}

// The text with its white space removed and the '#' comment lines dropped (a key wrapped in an e-mail or a file).
// Surrounding quotes, as a copied value may have, are removed too.
normalize :: proc(text: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if strings.has_prefix(l, "#") { continue }
		for c in transmute([]byte)l {
			if c != ' ' && c != '\t' && c != '"' && c != '\'' { strings.write_byte(&sb, c) }
		}
	}
	return strings.to_string(sb)
}

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

public_key_encode :: proc(key: []byte, allocator := context.allocator) -> string {
	return base64.encode(key, base64.ENC_URL_TABLE, allocator, {.No_Padding})
}

// Reads and checks a licence against `public_key` (base64url text of the 32 bytes). On success the fields are owned by
// `allocator` (license_destroy). Nothing but a signature made with the matching private key passes.
verify :: proc(text, public_key: string, allocator := context.allocator) -> (lic: License, err: Error) {
	t := normalize(text, context.temp_allocator)
	switch {
	case len(text) > MAX_TEXT: return {}, .Too_Long
	case t == "":              return {}, .Empty
	}
	parts := strings.split(t, ".", context.temp_allocator)
	if len(parts) != 3 || parts[0] != VERSION_TAG || parts[1] == "" || parts[2] == "" { return {}, .Bad_Format }

	payload, e1 := b64_decode(parts[1])
	sig, e2 := b64_decode(parts[2])
	if e1 != nil || e2 != nil { return {}, .Bad_Encoding }

	if public_key == "" { return {}, .No_Public_Key }
	pk_bytes, pk_ok := public_key_decode(public_key)
	if !pk_ok { return {}, .Bad_Public_Key }
	pk: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&pk, pk_bytes[:]) { return {}, .Bad_Public_Key }
	msg := signed_bytes(payload, context.temp_allocator)
	if len(sig) != ed25519.SIGNATURE_SIZE || !ed25519.verify(&pk, msg, sig) { return {}, .Bad_Signature }

	// signed by us: its content is read only now
	l, ok := payload_read(payload, allocator)
	if !ok { return {}, .Bad_Payload }
	if l.product != PRODUCT { license_destroy(&l); return {}, .Wrong_Product }
	return l, .None
}

// SIGN_CONTEXT then the payload: what the signature covers.
signed_bytes :: proc(payload: []byte, allocator := context.temp_allocator) -> []byte {
	out := make([]byte, len(SIGN_CONTEXT) + len(payload), allocator)
	copy(out, SIGN_CONTEXT)
	copy(out[len(SIGN_CONTEXT):], payload)
	return out
}

@(private)
payload_read :: proc(payload: []byte, allocator: runtime.Allocator) -> (l: License, ok: bool) {
	v, err := json.parse(payload, allocator = context.temp_allocator)
	if err != .None { return {}, false }
	obj, is_obj := v.(json.Object)
	if !is_obj { return {}, false }
	field :: proc(o: json.Object, name: string, allocator: runtime.Allocator) -> (s: string, ok: bool) {
		x, has := o[name]
		if !has { return "", true }   // (an absent field is empty; "product" is checked by the caller)
		str, is_str := x.(json.String)
		if !is_str || len(str) > MAX_FIELD { return "", false }
		return strings.clone(str, allocator), true
	}
	good: bool
	l.product, good = field(obj, "product", allocator); if !good { license_destroy(&l); return {}, false }
	l.edition, good = field(obj, "edition", allocator); if !good { license_destroy(&l); return {}, false }
	l.name, good = field(obj, "name", allocator);       if !good { license_destroy(&l); return {}, false }
	l.email, good = field(obj, "email", allocator);     if !good { license_destroy(&l); return {}, false }
	l.date, good = field(obj, "date", allocator);       if !good { license_destroy(&l); return {}, false }
	l.order, good = field(obj, "order", allocator);     if !good { license_destroy(&l); return {}, false }
	return l, true
}

// The licence text for `lic`, signed with the private key `seed` (32 bytes). For the issuing tool and the tests.
sign :: proc(seed: []byte, lic: License, allocator := context.allocator) -> (text: string, ok: bool) {
	l := lic
	l.product = PRODUCT
	payload, merr := json.marshal(l, {}, context.temp_allocator)
	if merr != nil { return "", false }
	return sign_payload(seed, payload, allocator)
}

// A licence text for any payload (the tests make damaged and foreign ones with it).
sign_payload :: proc(seed: []byte, payload: []byte, allocator := context.allocator) -> (text: string, ok: bool) {
	priv: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&priv, seed) { return "", false }
	defer ed25519.private_key_clear(&priv)
	sig: [ed25519.SIGNATURE_SIZE]byte
	ed25519.sign(&priv, signed_bytes(payload), sig[:])
	enc := base64.ENC_URL_TABLE
	p := base64.encode(payload, enc, context.temp_allocator, {.No_Padding})
	s := base64.encode(sig[:], enc, context.temp_allocator, {.No_Padding})
	return strings.concatenate({VERSION_TAG, ".", p, ".", s}, allocator), true
}

// The public key (base64url) of a private key.
public_key_of :: proc(seed: []byte, allocator := context.allocator) -> (key: string, ok: bool) {
	priv: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&priv, seed) { return "", false }
	defer ed25519.private_key_clear(&priv)
	pub: [ed25519.PUBLIC_KEY_SIZE]byte
	ed25519.private_key_public_bytes(&priv, pub[:])
	return public_key_encode(pub[:], allocator), true
}
