package vault_pin

import "core:strings"
import "core:testing"
import update "toolkit:update"

SHA_A :: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
SHA_B :: "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

// The pin in the repository is one: a broken vault.version fails here, not in a user's hands.
@(test)
the_built_in_pin_is_a_pin :: proc(t: ^testing.T) {
	p, problem := built_in()
	testing.expect_value(t, problem, "")
	testing.expect(t, update.version_valid(p.version))
}

@(test)
a_pin_reads_back_what_it_writes :: proc(t: ^testing.T) {
	p: Pin
	p.version = "1.2.3"
	p.assets[0] = {platform = update.PLATFORM_WINDOWS_X64, size = 14_680_064, sha256 = SHA_A}
	p.assets[1] = {platform = update.PLATFORM_LINUX_X64, size = 13_107_200, sha256 = SHA_B}
	text := text_of(p, context.temp_allocator)
	q, problem := parse(text)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, q.version, "1.2.3")
	w, has_w := asset_of(q, update.PLATFORM_WINDOWS_X64)
	l, has_l := asset_of(q, update.PLATFORM_LINUX_X64)
	testing.expect(t, has_w && has_l)
	testing.expect_value(t, w.size, i64(14_680_064))
	testing.expect_value(t, l.sha256, SHA_B)
}

// A version with no platform is a pin (before the first release): nothing can be fetched for any system.
@(test)
a_pin_without_platforms_has_no_asset :: proc(t: ^testing.T) {
	p, problem := parse("# a comment\nversion 0.5.0\n")
	testing.expect_value(t, problem, "")
	_, has := asset_of(p, update.PLATFORM_LINUX_X64)
	testing.expect(t, !has)
	_, none := asset_of(p, "")
	testing.expect(t, !none)
}

@(test)
what_is_not_a_pin_is_refused :: proc(t: ^testing.T) {
	bad := []string{
		"",                                                     // no version
		"version 0.5",                                          // not X.Y.Z
		"version 0.5.0\nversion 0.6.0",                         // two versions
		"version 0.5.0\nmacos-arm64 2000000 " + SHA_A,          // no such platform
		"version 0.5.0\nlinux-x64 12 " + SHA_A,                 // too small to be a program
		"version 0.5.0\nlinux-x64 2000000 ABC",                 // not a SHA-256
		"version 0.5.0\nlinux-x64 2000000 " + SHA_A + "\nlinux-x64 2000000 " + SHA_B,   // twice
		"version 0.5.0\nsomething else",
	}
	for text in bad {
		_, problem := parse(text)
		testing.expectf(t, problem != "", "refused: %q", text)
	}
}

// The names a release publishes, and the manifest the toolkit's checks take.
@(test)
the_asset_names_are_the_toolkits :: proc(t: ^testing.T) {
	testing.expect_value(t, file_name("0.5.0", update.PLATFORM_WINDOWS_X64, context.temp_allocator), "wren-vault-0.5.0-windows-x64.exe")
	testing.expect_value(t, file_name("0.5.0", update.PLATFORM_LINUX_X64, context.temp_allocator), "wren-vault-0.5.0-linux-x64")
	testing.expect_value(t, release_folder("0.5.0", context.temp_allocator), "https://github.com/sachahjkl/wren-vault/releases/download/v0.5.0/")
	m := manifest_of("0.5.0", {platform = update.PLATFORM_LINUX_X64, size = 3, sha256 = SHA_A})
	defer update.manifest_destroy(&m)
	testing.expect(t, strings.has_suffix(m.file, "-linux-x64"))
	testing.expect_value(t, update.check_binary(m, []byte{1, 2}), update.Error.Size_Mismatch)
}
