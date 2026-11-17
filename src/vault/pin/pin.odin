// Package vault_pin: the release of wren-vault that this Wren runs (src/md/features/vault-helper-delivery.md). The file
// `vault.version` at the root of the repository names it: its version, and for each platform the size and the SHA-256
// of its program. `wrentool vault pin` writes it from the signed manifests of the release; the browser embeds it and
// runs or downloads only those bytes. Pure: no disk, no network (the browser and wrentool both import it).
package vault_pin

import "core:fmt"
import "core:strconv"
import "core:strings"
import update "toolkit:update"

REPOSITORY :: "sachahjkl/wren-vault"
FILE_NAME :: "vault.version"

// wren-vault to the toolkit's update package: its manifests, its file names, the key that signs its releases. Not
// Wren's update key: a stolen helper key must not ship a Wren. (wrentool update keygen -Product wren-vault)
PRODUCT :: update.Product{
	name         = "wren-vault",
	sign_context = "wren-vault-update-v1\n",
	public_key   = "FEMny7FINHJ-BMCTtOZDzI6Rk8MLXlA8q4DrxgufXio",
}

// The pin built into this Wren.
PIN_TEXT :: #load("../../../vault.version", string)

// One platform's program of the pinned release.
Asset :: struct {
	platform: string,   // update.PLATFORM_WINDOWS_X64, update.PLATFORM_LINUX_X64
	size:     i64,
	sha256:   string,   // 64 lowercase hex digits
}

Pin :: struct {
	version: string,
	assets:  [len(update.PLATFORMS)]Asset,   // the platforms pinned; platform "" for the others
}

// Reads a pin: `#` comments, a line `version X.Y.Z`, and one line `<platform> <size> <sha256>` per platform. The
// strings are slices of `text`. `problem`: why it is not a pin ("" when it is).
parse :: proc(text: string) -> (p: Pin, problem: string) {
	rest := text
	n := 0
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' { continue }
		words := strings.fields(l, context.temp_allocator)
		switch {
		case len(words) == 2 && words[0] == "version":
			if p.version != "" { return {}, "two version lines" }
			if !update.version_valid(words[1]) { return {}, fmt.tprintf("%q is not an X.Y.Z version", words[1]) }
			p.version = words[1]
		case len(words) == 3:
			if platform_index(words[0]) < 0 { return {}, fmt.tprintf("%q is not a platform", words[0]) }
			if _, has := asset_of(p, words[0]); has { return {}, fmt.tprintf("two lines for %s", words[0]) }
			size, ok := strconv.parse_i64_of_base(words[1], 10)
			if !ok || size < update.MIN_BINARY || size > update.MAX_BINARY { return {}, fmt.tprintf("%s: %q is not the size of a program", words[0], words[1]) }
			if !update.hex_digest_ok(words[2]) { return {}, fmt.tprintf("%s: %q is not a SHA-256", words[0], words[2]) }
			p.assets[n] = {platform = words[0], size = size, sha256 = words[2]}
			n += 1
		case:
			return {}, fmt.tprintf("%q is not a line of a pin", l)
		}
	}
	if p.version == "" { return {}, "no version line" }
	return p, ""
}

// The pin's text, as `wrentool vault pin` writes it.
text_of :: proc(p: Pin, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintln(&b, "# wren-vault, the Vault's helper, that this Wren runs and ships (src/md/features/vault-helper-delivery.md).")
	fmt.sbprintln(&b, "# Written by `wrentool vault pin <version>` from the signed manifests of the release: do not edit by hand.")
	fmt.sbprintfln(&b, "version %s", p.version)
	for a in p.assets {
		if a.platform != "" { fmt.sbprintfln(&b, "%s %d %s", a.platform, a.size, a.sha256) }
	}
	return strings.to_string(b)
}

@(private)
platform_index :: proc(platform: string) -> int {
	for name, i in update.PLATFORMS { if name == platform { return i } }
	return -1
}

// The program of `platform` in the pin, if it is pinned.
asset_of :: proc(p: Pin, platform: string) -> (a: Asset, ok: bool) {
	for x in p.assets { if x.platform != "" && x.platform == platform { return x, true } }
	return {}, false
}

// The pin built into this Wren (its strings are constants). `problem` when the file is not a pin: wrentool's tests
// see it first.
built_in :: proc() -> (p: Pin, problem: string) { return parse(PIN_TEXT) }

// The folder of the release's files, "/" at the end.
release_folder :: proc(version: string, allocator := context.allocator) -> string {
	return fmt.aprintf("https://github.com/%s/releases/download/v%s/", REPOSITORY, version, allocator = allocator)
}

// Where the source of that release is (the tag).
source_url :: proc(version: string, allocator := context.allocator) -> string {
	return fmt.aprintf("https://github.com/%s/tree/v%s", REPOSITORY, version, allocator = allocator)
}

// The release asset of a platform's program: `wren-vault-<version>-<platform>[.exe]`.
file_name :: proc(version, platform: string, allocator := context.allocator) -> string {
	return update.expected_file_name(PRODUCT, version, platform, allocator)
}

// What the toolkit's checks take (update.check_binary, update.place): the pinned program as a manifest, its strings in
// `allocator` (update.manifest_destroy).
manifest_of :: proc(version: string, a: Asset, allocator := context.allocator) -> update.Manifest {
	return {version = strings.clone(version, allocator), platform = strings.clone(a.platform, allocator), file = file_name(version, a.platform, allocator),
		sha256 = strings.clone(a.sha256, allocator), size = a.size}
}
