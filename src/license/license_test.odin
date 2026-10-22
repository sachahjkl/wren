package license

import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
sample :: proc() -> License {
	return {edition = "supporter", name = "Jeanne Dupont", email = "jeanne@example.org", date = "2026-10-22", order = "WREN-0001"}
}

@(private = "file")
dev_key :: proc() -> string {
	s := DEV_SEED
	k, _ := public_key_of(s[:], context.temp_allocator)
	return k
}

@(private = "file")
dev_text :: proc(l: License) -> string {
	s := DEV_SEED
	t, ok := sign(s[:], l, context.temp_allocator)
	assert(ok)
	return t
}

@(test)
valid_licence_verifies :: proc(t: ^testing.T) {
	text := dev_text(sample())
	testing.expect(t, strings.has_prefix(text, "WREN1."))
	lic, err := verify(text, dev_key())
	defer license_destroy(&lic)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, lic.product, "wren")
	testing.expect_value(t, lic.edition, "supporter")
	testing.expect_value(t, lic.name, "Jeanne Dupont")
	testing.expect_value(t, lic.email, "jeanne@example.org")
	testing.expect_value(t, lic.date, "2026-10-22")
	testing.expect_value(t, lic.order, "WREN-0001")
	testing.expect_value(t, edition_of(lic), Edition.Supporter)
}

@(test)
non_ascii_names_survive :: proc(t: ^testing.T) {
	l := sample()
	l.name = "Zoé \"Zaza\" Müller \\ 日本"
	lic, err := verify(dev_text(l), dev_key())
	defer license_destroy(&lic)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, lic.name, l.name)
}

@(test)
patron_and_unknown_editions :: proc(t: ^testing.T) {
	l := sample()
	l.edition = "patron"
	lic, err := verify(dev_text(l), dev_key())
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, edition_of(lic), Edition.Patron)
	license_destroy(&lic)
	// an edition this build does not know is read all the same (an older build keeps working with newer licences)
	l.edition = "founder"
	lic, err = verify(dev_text(l), dev_key())
	defer license_destroy(&lic)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, edition_of(lic), Edition.Unknown)
	testing.expect_value(t, edition_title(lic.edition), "founder")
}

@(test)
altered_payload_is_refused :: proc(t: ^testing.T) {
	text := dev_text(sample())
	parts := strings.split(text, ".", context.temp_allocator)
	other := dev_text({edition = "patron", name = "Jeanne Dupont", email = "jeanne@example.org", date = "2026-10-22", order = "WREN-0001"})
	oparts := strings.split(other, ".", context.temp_allocator)
	// the payload of one licence with the signature of another
	forged := strings.join({parts[0], oparts[1], parts[2]}, ".", context.temp_allocator)
	_, err := verify(forged, dev_key())
	testing.expect_value(t, err, Error.Bad_Signature)
	// one character of the payload changed
	b := transmute([]byte)strings.clone(text, context.temp_allocator)
	i := len("WREN1.") + 10
	b[i] = b[i] == 'A' ? 'B' : 'A'
	_, err = verify(string(b), dev_key())
	testing.expect(t, err == .Bad_Signature || err == .Bad_Payload || err == .Bad_Encoding, "a changed payload never passes")
	// one character of the signature changed
	b = transmute([]byte)strings.clone(text, context.temp_allocator)
	b[len(b) - 5] = b[len(b) - 5] == 'A' ? 'B' : 'A'
	_, err = verify(string(b), dev_key())
	testing.expect_value(t, err, Error.Bad_Signature)
}

@(test)
other_key_is_refused :: proc(t: ^testing.T) {
	s := OTHER_DEV_SEED
	text, ok := sign(s[:], sample(), context.temp_allocator)
	testing.expect(t, ok)
	_, err := verify(text, dev_key())
	testing.expect_value(t, err, Error.Bad_Signature)
	other_pub, _ := public_key_of(s[:], context.temp_allocator)
	lic, err2 := verify(text, other_pub)
	defer license_destroy(&lic)
	testing.expect_value(t, err2, Error.None)
}

@(test)
foreign_product_is_refused :: proc(t: ^testing.T) {
	s := DEV_SEED
	text, _ := sign_payload(s[:], transmute([]byte)string(`{"product":"other","edition":"supporter","name":"x"}`), context.temp_allocator)
	_, err := verify(text, dev_key())
	testing.expect_value(t, err, Error.Wrong_Product)
	// no product at all
	text, _ = sign_payload(s[:], transmute([]byte)string(`{"edition":"supporter","name":"x"}`), context.temp_allocator)
	_, err = verify(text, dev_key())
	testing.expect_value(t, err, Error.Wrong_Product)
}

@(test)
signature_covers_a_context :: proc(t: ^testing.T) {
	// a plain Ed25519 signature of the payload (no SIGN_CONTEXT) is not a licence
	text := dev_text(sample())
	parts := strings.split(text, ".", context.temp_allocator)
	payload := parts[1]
	// sign "payload" text bytes directly: build with a payload whose signature was made over other bytes
	s := DEV_SEED
	other, _ := sign_payload(s[:], transmute([]byte)string(`{"product":"wren","name":"a"}`), context.temp_allocator)
	oparts := strings.split(other, ".", context.temp_allocator)
	mixed := strings.join({"WREN1", payload, oparts[2]}, ".", context.temp_allocator)
	_, err := verify(mixed, dev_key())
	testing.expect_value(t, err, Error.Bad_Signature)
}

@(test)
extra_fields_are_ignored :: proc(t: ^testing.T) {
	s := DEV_SEED
	text, _ := sign_payload(s[:], transmute([]byte)string(`{"product":"wren","edition":"supporter","name":"N","future":{"a":[1,2]},"order":"7"}`), context.temp_allocator)
	lic, err := verify(text, dev_key())
	defer license_destroy(&lic)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, lic.name, "N")
	testing.expect_value(t, lic.email, "")
	testing.expect_value(t, lic.order, "7")
}

@(test)
signed_but_not_a_licence :: proc(t: ^testing.T) {
	s := DEV_SEED
	for p in ([]string{`not json`, `[1,2]`, `"x"`, `{"product":"wren","name":12}`, `{"product":"wren","name":"` + `xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"` + `}`}) {
		text, _ := sign_payload(s[:], transmute([]byte)p, context.temp_allocator)
		_, err := verify(text, dev_key())
		testing.expect_value(t, err, Error.Bad_Payload)
	}
}

@(test)
text_forms :: proc(t: ^testing.T) {
	text := dev_text(sample())
	// wrapped, indented, commented, quoted: all the same licence
	wrapped := strings.builder_make(context.temp_allocator)
	strings.write_string(&wrapped, "# Wren licence of Jeanne Dupont\r\n# order WREN-0001\r\n")
	for i := 0; i < len(text); i += 60 {
		strings.write_string(&wrapped, "   ")
		strings.write_string(&wrapped, text[i:min(i + 60, len(text))])
		strings.write_string(&wrapped, "\r\n")
	}
	lic, err := verify(strings.to_string(wrapped), dev_key())
	testing.expect_value(t, err, Error.None)
	license_destroy(&lic)
	lic, err = verify(strings.concatenate({"\"", text, "\"\n"}, context.temp_allocator), dev_key())
	testing.expect_value(t, err, Error.None)
	license_destroy(&lic)

	_, err = verify("", dev_key())
	testing.expect_value(t, err, Error.Empty)
	_, err = verify("  \n# only a comment\n", dev_key())
	testing.expect_value(t, err, Error.Empty)
	_, err = verify("hello", dev_key())
	testing.expect_value(t, err, Error.Bad_Format)
	_, err = verify("WREN2.aaaa.bbbb", dev_key())
	testing.expect_value(t, err, Error.Bad_Format)
	_, err = verify("WREN1.aaaa", dev_key())
	testing.expect_value(t, err, Error.Bad_Format)
	_, err = verify("WREN1.aaaa.bbbb.cccc", dev_key())
	testing.expect_value(t, err, Error.Bad_Format)
	_, err = verify("WREN1..bbbb", dev_key())
	testing.expect_value(t, err, Error.Bad_Format)
	_, err = verify("WREN1.a!a.bbbb", dev_key())
	testing.expect_value(t, err, Error.Bad_Encoding)
	_, err = verify("WREN1.aaaa.bbbb", dev_key())
	testing.expect_value(t, err, Error.Bad_Signature)   // (valid base64url of a wrong length of signature)
	_, err = verify(strings.repeat("A", MAX_TEXT + 1, context.temp_allocator), dev_key())
	testing.expect_value(t, err, Error.Too_Long)
}

@(test)
public_key_problems :: proc(t: ^testing.T) {
	text := dev_text(sample())
	_, err := verify(text, "")
	testing.expect_value(t, err, Error.No_Public_Key)
	_, err = verify(text, "not a key!")
	testing.expect_value(t, err, Error.Bad_Public_Key)
	_, err = verify(text, "AAAA")
	testing.expect_value(t, err, Error.Bad_Public_Key)
	// the production key is empty until Sacha makes it, and never the development one
	testing.expect(t, PRODUCTION_PUBLIC_KEY == "" || PRODUCTION_PUBLIC_KEY != dev_key(), "the production key is not the development key")
	if PRODUCTION_PUBLIC_KEY != "" {
		_, ok := public_key_decode(PRODUCTION_PUBLIC_KEY)
		testing.expect(t, ok, "the production public key is 32 bytes of base64url")
	}
}

@(test)
private_keys_cannot_be_committed :: proc(t: ^testing.T) {
	// run from the repository root, as the suite does
	data, err := os.read_entire_file(".gitignore", context.temp_allocator)
	testing.expect_value(t, err, nil)
	for pattern in ([]string{"private.key", ".wren-license/", "*.wrenlicense"}) {
		testing.expectf(t, strings.contains(string(data), pattern), ".gitignore must keep %q out of the repository", pattern)
	}
}
