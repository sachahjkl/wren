package vaulttool

// The release of wren-vault and Wren's pin, in process: the version written into Cargo.toml and Cargo.lock, the signed
// manifests of a release read back into a pin (and what is refused: another key, another version, a changed byte), the
// files the Linux package puts beside wren.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:base"
import vault_pin "wb:vault/pin"
import signing "toolkit:signing"
import update "toolkit:update"

TEST_TOML :: "[package]\nname = \"wren-vault\"\nversion = \"0.5.0\"\nedition = \"2024\"\n\n[dependencies]\nserde = { version = \"1.0.228\" }\n"
TEST_LOCK :: "version = 4\n\n[[package]]\nname = \"serde\"\nversion = \"1.0.228\"\n\n[[package]]\nname = \"wren-vault\"\nversion = \"0.5.0\"\ndependencies = [\n \"serde\",\n]\n"

@(test)
the_version_goes_into_cargo_toml_and_cargo_lock :: proc(t: ^testing.T) {
	toml, ok := cargo_version_set(TEST_TOML, "0.6.0", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, cargo_version(toml), "0.6.0")
	testing.expect(t, strings.contains(toml, "serde = { version = \"1.0.228\" }"), "a dependency's version is not the package's")
	lock, ok2 := lock_version_set(TEST_LOCK, "wren-vault", "0.6.0", context.temp_allocator)
	testing.expect(t, ok2)
	testing.expect(t, strings.contains(lock, "name = \"wren-vault\"\nversion = \"0.6.0\""))
	testing.expect(t, strings.contains(lock, "name = \"serde\"\nversion = \"1.0.228\""))
	_, none := cargo_version_set("[dependencies]\nversion = \"1\"\n", "0.6.0", context.temp_allocator)
	testing.expect(t, !none, "no [package]: nothing is written")
}

@(private = "file")
Release_Fixture :: struct {
	dir:     string,
	seed:    [32]byte,
	product: update.Product,
}

// A release folder with both programs (a program's first bytes, and the least size a manifest takes), and a product whose
// key is the test's.
@(private = "file")
release_fixture :: proc(name: string) -> (r: Release_Fixture) {
	r.dir = strings.concatenate({base.temp_dir(context.temp_allocator), "/vault-release-test-", name, "-", base.unique_name(context.temp_allocator)}, context.temp_allocator)
	_ = os.make_directory_all(r.dir)
	for i in 0 ..< 32 { r.seed[i] = u8(i * 7 + 1) }
	pub, _ := signing.public_key_of(r.seed[:], context.temp_allocator)
	r.product = vault_pin.PRODUCT
	r.product.public_key = pub
	for platform in update.PLATFORMS {
		data := make([]byte, update.MIN_BINARY + 17, context.temp_allocator)
		magic := platform == update.PLATFORM_WINDOWS_X64 ? "MZ" : "\x7fELF"
		copy(data, magic)
		data[len(data) - 1] = platform == update.PLATFORM_WINDOWS_X64 ? 1 : 2
		_ = os.write_entire_file(fmt.tprintf("%s/%s", r.dir, update.expected_file_name(r.product, "0.6.0", platform, context.temp_allocator)), data)
	}
	return
}

@(private = "file")
signed_of :: proc(dir: string) -> []Signed_Manifest {
	out := make([]Signed_Manifest, len(update.PLATFORMS), context.temp_allocator)
	for platform, i in update.PLATFORMS {
		name := update.manifest_name(platform, "", context.temp_allocator)
		m, _ := os.read_entire_file(fmt.tprintf("%s/%s", dir, name), context.temp_allocator)
		s, _ := os.read_entire_file(fmt.tprintf("%s/%s.sig", dir, name), context.temp_allocator)
		out[i] = {platform = platform, manifest = m, signature = string(s)}
	}
	return out
}

// What `vault sign` writes, `vault pin` reads into the pin; the pin then accepts exactly those programs.
@(test)
a_signed_release_becomes_the_pin :: proc(t: ^testing.T) {
	r := release_fixture("pin")
	defer base.remove_tree(r.dir)
	testing.expect_value(t, sign_release(r.product, r.seed, r.dir, "0.6.0", "2026-11-17"), "")
	sums, _ := os.read_entire_file(fmt.tprintf("%s/%s", r.dir, SUMS_FILE), context.temp_allocator)
	testing.expect_value(t, strings.count(string(sums), "\n"), len(update.PLATFORMS))
	p, problem := pin_of(r.product, "0.6.0", signed_of(r.dir), context.temp_allocator)
	testing.expect_value(t, problem, "")
	// (the pin's text reads back to the same, and the programs are what it pins)
	q, bad := vault_pin.parse(vault_pin.text_of(p, context.temp_allocator))
	testing.expect_value(t, bad, "")
	for platform in update.PLATFORMS {
		a, has := vault_pin.asset_of(q, platform)
		testing.expect(t, has)
		data, _ := os.read_entire_file(fmt.tprintf("%s/%s", r.dir, vault_pin.file_name("0.6.0", platform, context.temp_allocator)), context.temp_allocator)
		m := vault_pin.manifest_of(q.version, a, context.temp_allocator)
		testing.expect_value(t, update.check_binary(m, data), update.Error.None)
	}
}

@(test)
a_release_no_pin_could_check_is_not_signed :: proc(t: ^testing.T) {
	r := release_fixture("key")
	defer base.remove_tree(r.dir)
	other := r.product
	other.public_key = ""
	testing.expect(t, sign_release(other, r.seed, r.dir, "0.6.0", "") != "", "no key built in")
	other.public_key = vault_pin.PRODUCT.public_key != "" ? vault_pin.PRODUCT.public_key : "FFmnzv9bVZfK9x7LFk-R2M2m5SDs7YozvY46N17Hsws"
	testing.expect(t, sign_release(other, r.seed, r.dir, "0.6.0", "") != "", "another key than the one built in")
	_ = os.remove(fmt.tprintf("%s/%s", r.dir, update.expected_file_name(r.product, "0.6.0", update.PLATFORM_LINUX_X64, context.temp_allocator)))
	testing.expect(t, sign_release(r.product, r.seed, r.dir, "0.6.0", "") != "", "a platform's program is missing")
}

@(test)
a_pin_refuses_what_the_release_did_not_sign :: proc(t: ^testing.T) {
	r := release_fixture("refuse")
	defer base.remove_tree(r.dir)
	testing.expect_value(t, sign_release(r.product, r.seed, r.dir, "0.6.0", ""), "")
	signed := signed_of(r.dir)
	// another version than the one asked (a replay of an older release under a newer tag)
	_, p1 := pin_of(r.product, "0.7.0", signed, context.temp_allocator)
	testing.expect(t, p1 != "")
	// another key
	other := r.product
	other.public_key = "FFmnzv9bVZfK9x7LFk-R2M2m5SDs7YozvY46N17Hsws"
	_, p2 := pin_of(other, "0.6.0", signed, context.temp_allocator)
	testing.expect(t, p2 != "")
	// a changed byte of a manifest
	changed := make([]byte, len(signed[0].manifest), context.temp_allocator)
	copy(changed, signed[0].manifest)
	changed[len(changed) / 2] ~= 1
	tampered := make([]Signed_Manifest, len(signed), context.temp_allocator)
	copy(tampered, signed)
	tampered[0].manifest = changed
	_, p3 := pin_of(r.product, "0.6.0", tampered, context.temp_allocator)
	testing.expect(t, p3 != "")
	// a platform missing
	_, p4 := pin_of(r.product, "0.6.0", signed[:1], context.temp_allocator)
	testing.expect(t, p4 != "")
}

// The Linux package carries the program, its licence and the note of its source, beside wren.
@(test)
the_bundle_is_the_program_its_licence_and_its_source :: proc(t: ^testing.T) {
	files := bundle_files("build/vault/pinned/0.5.0", update.PLATFORM_LINUX_X64, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for f in files {
		append(&names, f.name)
		testing.expect(t, strings.has_prefix(f.from, "build/vault/pinned/0.5.0/"))
	}
	testing.expect_value(t, len(names), 3)
	testing.expect_value(t, names[0], "wren-vault")
	testing.expect_value(t, names[1], LICENSE_NAME)
	testing.expect_value(t, names[2], SOURCE_NAME)
	testing.expect_value(t, bundle_files("d", update.PLATFORM_WINDOWS_X64, context.temp_allocator)[0].name, "wren-vault.exe")
	note := source_note("0.5.0", context.temp_allocator)
	testing.expect(t, strings.contains(note, "https://github.com/sachahjkl/wren-vault/tree/v0.5.0"))
	testing.expect(t, strings.contains(note, "General Public License version 3"))
}
