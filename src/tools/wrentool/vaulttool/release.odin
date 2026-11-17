package vaulttool

// The releases of wren-vault and the pin of Wren (src/md/features/vault-helper-delivery.md):
//   wrentool vault prepare <version>                    wren-vault's CHANGELOG assembled, the version in Cargo.toml and Cargo.lock
//                                                       (the checkout of WREN_VAULT_SOURCE, ../wren-vault by default)
//   wrentool vault check-release <version>              that checkout is ready for the tag v<version> (wren-vault's release workflow)
//   wrentool vault sign -Dir d -Version v [-Private f]  the signed manifests and SHA256SUMS.txt of the programs in d
//                                                       (the key: f, else $UPDATE_SIGNING_KEY; it must be the one built in)
//   wrentool vault pin <version> [-Folder url]          vault.version from that release's signed manifests
//   wrentool vault fetch [-Platform p] [-Out d]         the pinned program, its licence and its source note, checked against the pin

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "wb:tools/tooling"
import "wb:tools/wrentool/changelog"
import "wb:tools/wrentool/deps"
import vault_pin "wb:vault/pin"
import signing "toolkit:signing"
import toolbox "toolkit:toolbox"
import update "toolkit:update"

REPOSITORY_URL :: "https://github.com/" + vault_pin.REPOSITORY
KEY_ENV :: "UPDATE_SIGNING_KEY"
SUMS_FILE :: "SHA256SUMS.txt"
PINNED_DIR :: "build/vault/pinned"
LICENSE_NAME :: "wren-vault-LICENSE.txt"
SOURCE_NAME :: "wren-vault-SOURCE.txt"

////////////////////////////////
// prepare, check-release

// The version of [package] in a Cargo.toml set to `version`; ok false when the file has no such line.
cargo_version_set :: proc(text, version: string, allocator := context.allocator) -> (out: string, ok: bool) {
	start, end, found := cargo_version_span(text)
	if !found { return "", false }
	return strings.concatenate({text[:start], version, text[end:]}, allocator), true
}

// The version of [package] in a Cargo.toml.
cargo_version :: proc(text: string) -> string {
	start, end, found := cargo_version_span(text)
	return found ? text[start:end] : ""
}

@(private = "file")
cargo_version_span :: proc(text: string) -> (start, end: int, ok: bool) {
	at := strings.index(text, "[package]")
	if at < 0 { return }
	section := text[at:]
	// (the section ends at the next table)
	if next := strings.index(section[1:], "\n["); next >= 0 { section = section[:next + 1] }
	KEY :: "\nversion = \""
	i := strings.index(section, KEY)
	if i < 0 { return }
	start = at + i + len(KEY)
	close := strings.index_byte(text[start:], '"')
	if close <= 0 { return }
	return start, start + close, true
}

// The entry of the package `name` in a Cargo.lock set to `version`.
lock_version_set :: proc(text, name, version: string, allocator := context.allocator) -> (out: string, ok: bool) {
	head := fmt.tprintf("[[package]]\nname = \"%s\"\nversion = \"", name)
	at := strings.index(text, head)
	if at < 0 { return "", false }
	start := at + len(head)
	close := strings.index_byte(text[start:], '"')
	if close <= 0 { return "", false }
	return strings.concatenate({text[:start], version, text[start + close:]}, allocator), true
}

@(private = "file")
prepare :: proc(args: []string) -> int {
	if len(args) != 1 || !update.version_valid(args[0]) { fmt.eprintln("wrentool vault prepare <X.Y.Z>"); return 2 }
	version := args[0]
	src := deps.vault_source()
	toml_path, lock_path := fmt.tprintf("%s/Cargo.toml", src), fmt.tprintf("%s/Cargo.lock", src)
	toml, e1 := os.read_entire_file(toml_path, context.temp_allocator)
	lock, e2 := os.read_entire_file(lock_path, context.temp_allocator)
	if e1 != nil || e2 != nil { fmt.eprintfln("no wren-vault checkout in %s (Cargo.toml, Cargo.lock; set %s)", src, deps.VAULT_SOURCE_ENV); return 1 }
	new_toml, ok1 := cargo_version_set(string(toml), version, context.temp_allocator)
	new_lock, ok2 := lock_version_set(string(lock), vault_pin.PRODUCT.name, version, context.temp_allocator)
	if !ok1 || !ok2 { fmt.eprintln("the version of wren-vault is not found in Cargo.toml or Cargo.lock"); return 1 }
	out := strings.builder_make(context.temp_allocator)
	code := changelog.execute({"-Assemble", "-Version", version, "-Root", src, "-Repo", REPOSITORY_URL}, &out)
	fmt.print(strings.to_string(out))
	if code != 0 { return code }
	if os.write_entire_file(toml_path, new_toml) != nil || os.write_entire_file(lock_path, new_lock) != nil { fmt.eprintln("cannot write Cargo.toml or Cargo.lock"); return 1 }
	fmt.printfln("%s, %s: version %s", toml_path, lock_path, version)
	fmt.printfln("\nnext, in %s:\n  git commit -am \"Release %s\"\n  git tag -a v%s -m \"wren-vault %s\"\n  git push origin HEAD v%s\nthe release workflow builds, signs and publishes it; then, here: wrentool vault pin %s", src, version, version, version, version, version)
	return 0
}

@(private = "file")
check_release :: proc(args: []string) -> int {
	if len(args) != 1 || !update.version_valid(strings.trim_prefix(args[0], "v")) { fmt.eprintln("wrentool vault check-release <X.Y.Z>"); return 2 }
	version := strings.trim_prefix(args[0], "v")
	src := deps.vault_source()
	toml, err := os.read_entire_file(fmt.tprintf("%s/Cargo.toml", src), context.temp_allocator)
	if err != nil { fmt.eprintfln("no Cargo.toml in %s", src); return 1 }
	if got := cargo_version(string(toml)); got != version { fmt.eprintfln("Cargo.toml says version %s, not %s (wrentool vault prepare %s)", got, version, version); return 1 }
	return changelog.check_release(src, version, REPOSITORY_URL) ? 0 : 1
}

////////////////////////////////
// sign

// The manifests of a release's programs in `dir`: for each platform, update-<platform>.json and its .sig, verified with
// `product`'s public key (which must be the seed's), and SHA256SUMS.txt. "" when all is written, else why not.
sign_release :: proc(product: update.Product, seed: [32]byte, dir, version, published: string) -> (problem: string) {
	seed := seed
	if !update.version_valid(version) { return fmt.tprintf("%q is not an X.Y.Z version", version) }
	pub, _ := signing.public_key_of(seed[:], context.temp_allocator)
	if product.public_key == "" { return "no public key is built in (src/vault/pin/pin.odin): wrentool update keygen -Product wren-vault" }
	if pub != product.public_key { return fmt.tprintf("the key that signs (%s) is not the one built in (%s): no pin could check this release", pub, product.public_key) }
	sums := strings.builder_make(context.temp_allocator)
	for platform in update.PLATFORMS {
		name := update.expected_file_name(product, version, platform, context.temp_allocator)
		data, err := os.read_entire_file(fmt.tprintf("%s/%s", dir, name), context.temp_allocator)
		if err != nil { return fmt.tprintf("%s/%s is missing", dir, name) }
		if !update.is_program(data, platform) { return fmt.tprintf("%s is not a program of %s", name, platform) }
		m := update.manifest_of(product, data, {version = version, platform = platform, published = published}, context.temp_allocator)
		bytes := update.manifest_bytes(product, m, context.temp_allocator)
		sig, signed := update.sign(product, seed[:], bytes, context.temp_allocator)
		if !signed { return "cannot sign with this key" }
		if _, e := update.verify(product, bytes, sig, {platform = platform}, context.temp_allocator); e != .None { return fmt.tprintf("the manifest of %s does not verify: %s", platform, update.error_text(e)) }
		path := fmt.tprintf("%s/%s", dir, update.manifest_name(platform, "", context.temp_allocator))
		if os.write_entire_file(path, bytes) != nil || os.write_entire_file(fmt.tprintf("%s.sig", path), fmt.tprintf("%s\n", sig)) != nil { return fmt.tprintf("cannot write %s", path) }
		fmt.sbprintfln(&sums, "%s  %s", m.sha256, name)
		fmt.printfln("%s: %s, %d bytes, sha256 %s, signed", path, name, m.size, m.sha256)
	}
	if os.write_entire_file(fmt.tprintf("%s/%s", dir, SUMS_FILE), strings.to_string(sums)) != nil { return fmt.tprintf("cannot write %s", SUMS_FILE) }
	return ""
}

// The private key: the first line of FILE that is not a comment, else $UPDATE_SIGNING_KEY.
@(private = "file")
seed_chosen :: proc(file: string) -> (seed: [32]byte, ok: bool) {
	text := ""
	if file != "" {
		data, err := os.read_entire_file(file, context.temp_allocator)
		if err != nil { fmt.eprintfln("cannot read %s", file); return }
		for line in strings.split_lines(string(data), context.temp_allocator) {
			l := strings.trim_space(line)
			if l != "" && l[0] != '#' { text = l; break }
		}
	} else {
		text = strings.trim_space(os.get_env(KEY_ENV, context.temp_allocator))
	}
	if text == "" { fmt.eprintfln("no key: pass -Private FILE or set %s", KEY_ENV); return }
	seed, ok = signing.key_decode(text)
	if !ok { fmt.eprintln("the key is not an Ed25519 seed (32 bytes of base64url)") }
	return
}

@(private = "file")
today :: proc() -> string {
	y, m, d := time.date(time.now())
	return fmt.tprintf("%04d-%02d-%02d", y, int(m), d)
}

@(private = "file")
sign :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Dir= -Version= -Private=")
	if !ok { return 2 }
	dir, version := tooling.flag(f, "-Dir"), tooling.flag(f, "-Version")
	if dir == "" || version == "" { fmt.eprintln("wrentool vault sign -Dir d -Version X.Y.Z [-Private FILE]"); return 2 }
	seed, got := seed_chosen(tooling.flag(f, "-Private"))
	if !got { return 1 }
	if problem := sign_release(vault_pin.PRODUCT, seed, dir, version, today()); problem != "" { fmt.eprintfln("vault sign: %s", problem); return 1 }
	return 0
}

////////////////////////////////
// pin

// A downloaded manifest and its signature.
Signed_Manifest :: struct {
	platform:  string,
	manifest:  []byte,
	signature: string,
}

// The pin of `version` from its release's signed manifests, one per platform: each signed by `product`'s key, for its
// platform, of that version and named as its program. Its strings are in `allocator`.
pin_of :: proc(product: update.Product, version: string, signed: []Signed_Manifest, allocator := context.allocator) -> (p: vault_pin.Pin, problem: string) {
	if !update.version_valid(version) { return {}, fmt.tprintf("%q is not an X.Y.Z version", version) }
	if len(signed) != len(update.PLATFORMS) { return {}, "a manifest is missing" }
	p.version = strings.clone(version, allocator)
	for s, i in signed {
		m, err := update.verify(product, s.manifest, s.signature, {platform = s.platform}, context.temp_allocator)
		if err != .None { return {}, fmt.tprintf("%s: %s", s.platform, update.error_text(err)) }
		if m.version != version { return {}, fmt.tprintf("%s: the manifest is of version %s, not %s", s.platform, m.version, version) }
		if m.file != update.expected_file_name(product, version, s.platform, context.temp_allocator) { return {}, fmt.tprintf("%s: the manifest names %s", s.platform, m.file) }
		p.assets[i] = {platform = strings.clone(s.platform, allocator), size = m.size, sha256 = strings.clone(m.sha256, allocator)}
	}
	return p, ""
}

@(private = "file")
pin :: proc(args: []string) -> int {
	if len(args) < 1 || !update.version_valid(args[0]) { fmt.eprintln("wrentool vault pin <X.Y.Z> [-Folder url]"); return 2 }
	version := args[0]
	f, ok := tooling.parse_flags(args[1:], "-Folder=")
	if !ok { return 2 }
	folder := tooling.flag(f, "-Folder", vault_pin.release_folder(version, context.temp_allocator))
	tmp := fmt.tprintf("build/vault/pin-%s", version)
	_ = os.make_directory_all(tmp)
	signed := make([dynamic]Signed_Manifest, context.temp_allocator)
	for platform in update.PLATFORMS {
		name := update.manifest_name(platform, "", context.temp_allocator)
		paths := [2]string{fmt.tprintf("%s/%s", tmp, name), fmt.tprintf("%s/%s.sig", tmp, name)}
		for path, i in paths {
			url := fmt.tprintf("%s%s%s", folder, name, i == 1 ? ".sig" : "")
			if !curl(url, path) { fmt.eprintfln("cannot download %s", url); return 1 }
		}
		manifest, _ := os.read_entire_file(paths[0], context.temp_allocator)
		sig, _ := os.read_entire_file(paths[1], context.temp_allocator)
		append(&signed, Signed_Manifest{platform = platform, manifest = manifest, signature = string(sig)})
	}
	p, problem := pin_of(vault_pin.PRODUCT, version, signed[:], context.temp_allocator)
	if problem != "" { fmt.eprintfln("vault pin: %s", problem); return 1 }
	if os.write_entire_file(vault_pin.FILE_NAME, vault_pin.text_of(p, context.temp_allocator)) != nil { fmt.eprintfln("cannot write %s", vault_pin.FILE_NAME); return 1 }
	fmt.printf("%s:\n%s\ncommit it with the change that needs this helper\n", vault_pin.FILE_NAME, vault_pin.text_of(p, context.temp_allocator))
	return 0
}

@(private = "file")
curl :: proc(url, path: string) -> bool {
	return tooling.run({command = {"curl", "-fsSL", "--retry", toolbox.DOWNLOAD_RETRIES, "--retry-delay", toolbox.DOWNLOAD_RETRY_DELAY_S, "--retry-all-errors", "-o", path, url}}) == 0
}

////////////////////////////////
// fetch, and what the Linux package carries

// A file of the bundle: where it is, and its name beside wren.
Bundle_File :: struct { from, name: string }

// The files the package puts beside the browser, in `dir` (what fetch wrote): the program, its licence, its source note.
bundle_files :: proc(dir, platform: string, allocator := context.allocator) -> []Bundle_File {
	program := platform == update.PLATFORM_WINDOWS_X64 ? "wren-vault.exe" : "wren-vault"
	files := make([]Bundle_File, 3, allocator)
	files[0] = {fmt.aprintf("%s/%s", dir, program, allocator = allocator), program}
	files[1] = {fmt.aprintf("%s/%s", dir, LICENSE_NAME, allocator = allocator), LICENSE_NAME}
	files[2] = {fmt.aprintf("%s/%s", dir, SOURCE_NAME, allocator = allocator), SOURCE_NAME}
	return files
}

// What the source note says: the program is a separate one, its licence, where its source is.
source_note :: proc(version: string, allocator := context.allocator) -> string {
	return fmt.aprintf(`wren-vault %[0]s, the helper of Wren's Vault

wren-vault is a separate program, under the GNU General Public License version 3 only (wren-vault-LICENSE.txt).
Wren starts it and talks to it through a pipe; it contains no code of Wren, and Wren contains none of it.

Its complete source, the one this program was built from, is the tag v%[0]s of %[1]s:
  %[2]s
It is built with: cargo build --release --locked (its README says more).
`, version, REPOSITORY_URL, vault_pin.source_url(version, context.temp_allocator), allocator = allocator)
}

// The pin of the checkout (vault.version), and its program of `platform`. `problem`: why there is none.
@(private = "file")
pin_read :: proc(platform: string) -> (p: vault_pin.Pin, a: vault_pin.Asset, problem: string) {
	text, err := os.read_entire_file(vault_pin.FILE_NAME, context.temp_allocator)
	if err != nil { return {}, {}, fmt.tprintf("%s is missing", vault_pin.FILE_NAME) }
	bad: string
	p, bad = vault_pin.parse(string(text))
	if bad != "" { return {}, {}, fmt.tprintf("%s: %s", vault_pin.FILE_NAME, bad) }
	pinned: bool
	a, pinned = vault_pin.asset_of(p, platform)
	if !pinned { return {}, {}, fmt.tprintf("%s pins no program for %s: wrentool vault pin <version> after its release", vault_pin.FILE_NAME, platform) }
	return p, a, ""
}

// "" when the checkout's pin names a program for `platform` (what a release of Wren needs), else why not.
pin_names :: proc(platform: string) -> (problem: string) {
	_, _, problem = pin_read(platform)
	return
}

// The pinned program of `platform`, its licence and its source note, in `dir` (build/vault/pinned/<version> by default).
// The program is kept when it is the pinned one, else downloaded and checked. "" when all is there, else why not.
fetch_pinned :: proc(platform: string, dir := "") -> (out: string, problem: string) {
	p, a, why := pin_read(platform)
	if why != "" { return "", why }
	out = dir != "" ? dir : fmt.tprintf("%s/%s", PINNED_DIR, p.version)
	files := bundle_files(out, platform, context.temp_allocator)
	url := fmt.tprintf("%s%s", vault_pin.release_folder(p.version, context.temp_allocator), vault_pin.file_name(p.version, platform, context.temp_allocator))
	if !tooling.download_pinned(url, files[0].from, a.sha256) { return "", "the pinned helper could not be fetched" }
	when ODIN_OS != .Windows { _ = tooling.run({command = {"chmod", "+x", files[0].from}}) }
	if !os.exists(files[1].from) {
		licence := fmt.tprintf("https://raw.githubusercontent.com/%s/v%s/LICENSE", vault_pin.REPOSITORY, p.version)
		if !curl(licence, files[1].from) { _ = os.remove(files[1].from); return "", fmt.tprintf("cannot download %s", licence) }
	}
	if os.write_entire_file(files[2].from, source_note(p.version, context.temp_allocator)) != nil { return "", "cannot write the source note" }
	return out, ""
}

@(private = "file")
fetch :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Platform= -Out=")
	if !ok { return 2 }
	platform := tooling.flag(f, "-Platform", update.PLATFORM)
	out, problem := fetch_pinned(platform, tooling.flag(f, "-Out"))
	if problem != "" { fmt.eprintfln("vault fetch: %s", problem); return 1 }
	for b in bundle_files(out, platform, context.temp_allocator) { fmt.println(filepath.clean(b.from, context.temp_allocator)) }
	return 0
}

run_release :: proc(command: string, args: []string) -> (code: int, known: bool) {
	switch command {
	case "prepare":       return prepare(args), true
	case "check-release": return check_release(args), true
	case "sign":          return sign(args), true
	case "pin":           return pin(args), true
	case "fetch":         return fetch(args), true
	}
	return 0, false
}
