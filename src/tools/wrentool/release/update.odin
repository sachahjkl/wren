// wrentool update: the signed manifest of a release (src/update, docs/updates.md).
//   update keygen -Private FILE                         make the update key pair; FILE is outside the repository
//   update pubkey [-Private FILE]                       the public key of the private one (the environment's UPDATE_SIGNING_KEY by default)
//   update manifest -Exe f -Version v [-Platform p] -Out f.json    the manifest of a program (its size and SHA-256), unsigned
//   update sign -Manifest f.json [-Private FILE]        writes f.json.sig
//   update verify -Manifest f.json -Sig f.json.sig [-Public KEY] [-Platform p] [-Current v]
// `wrentool package` makes and signs the Windows manifest itself when UPDATE_SIGNING_KEY is set (the release workflow's secret).
package release

import "core:crypto"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "wb:tools/tooling"
import "wb:update"

UPDATE_KEY_ENV :: "UPDATE_SIGNING_KEY"

UPDATE_USAGE :: `usage: update <command> [options]
  keygen -Private FILE                   make the update key pair (FILE: outside the repository; a path inside a git work tree is refused);
                                         prints the public key and the line to put in src/update/public_key.odin
  pubkey [-Private FILE]                 the public key of FILE, or of $UPDATE_SIGNING_KEY
  manifest -Exe f -Version v [-Platform windows-x64] -Out f.json
                                         the manifest of a program: its size and SHA-256
  sign -Manifest f.json [-Private FILE]  the signature of a manifest, written to f.json.sig (the key: FILE, or $UPDATE_SIGNING_KEY)
  verify -Manifest f.json -Sig f.sig [-Public KEY] [-Platform p] [-Current v]
                                         check a signed manifest (default key: the one built into Wren)
`

run_update :: proc(args: []string) -> int {
	if len(args) == 0 { fmt.eprint(UPDATE_USAGE); return EXIT_USAGE }
	cmd, rest := args[0], args[1:]
	switch cmd {
	case "keygen":   return update_keygen(rest)
	case "pubkey":   return update_pubkey(rest)
	case "manifest": return update_manifest(rest)
	case "sign":     return update_sign(rest)
	case "verify":   return update_verify(rest)
	}
	fmt.eprintfln("unknown command %q", cmd)
	fmt.eprint(UPDATE_USAGE)
	return EXIT_USAGE
}

////////////////////////////////
// The private key

// True when `path` is inside a git work tree (an ancestor holds .git): a signing key there could be committed.
@(private = "file")
update_inside_git_tree :: proc(path: string) -> bool {
	abs, abs_err := filepath.abs(path, context.temp_allocator)
	if abs_err != nil { return true }   // cannot tell where it is: do not risk it
	dir := os.dir(abs)
	for dir != "" {
		if os.exists(fmt.tprintf("%s/.git", dir)) { return true }
		parent := os.dir(dir)
		if parent == dir { break }
		dir = parent
	}
	return false
}

// The seed of a key file: the first line that is not a comment.
@(private = "file")
update_read_seed_file :: proc(path: string) -> (seed: [32]byte, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { fmt.eprintfln("cannot read the private key %s", path); return {}, false }
	for line in strings.split_lines(string(data), context.temp_allocator) {
		l := strings.trim_space(line)
		if l == "" || strings.has_prefix(l, "#") { continue }
		s, good := update.seed_decode(l)
		if !good { fmt.eprintfln("%s is not an update private key file", path); return {}, false }
		return s, true
	}
	fmt.eprintfln("%s holds no key", path)
	return {}, false
}

// -Private FILE, else the environment's UPDATE_SIGNING_KEY (the 43 characters of the seed).
@(private = "file")
update_seed_chosen :: proc(f: tooling.Flags) -> (seed: [32]byte, ok: bool) {
	if p := tooling.flag(f, "-Private", ""); p != "" { return update_read_seed_file(p) }
	text := env(UPDATE_KEY_ENV)
	if text == "" { fmt.eprintfln("no update key: pass -Private FILE or set %s", UPDATE_KEY_ENV); return {}, false }
	s, good := update.seed_decode(text)
	if !good { fmt.eprintfln("%s is not an update private key (32 bytes of base64url)", UPDATE_KEY_ENV); return {}, false }
	return s, true
}

@(private = "file")
update_keygen :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Private=")
	if !ok { return EXIT_USAGE }
	path := tooling.flag(f, "-Private", "")
	if path == "" { fmt.eprintln("keygen needs -Private FILE (outside the repository)"); return EXIT_USAGE }
	if update_inside_git_tree(path) { return fail("refusing to write a signing key inside a git work tree:", path) }
	if os.exists(path) { return fail(path, "exists already: a second key would orphan the releases signed with the first (delete it yourself if you mean it)") }
	seed: [32]byte
	crypto.rand_bytes(seed[:])
	text := update.seed_encode(seed[:], context.temp_allocator)
	pub, _ := update.public_key_of(seed[:], context.temp_allocator)
	body := fmt.tprintf("# Wren update signing key (Ed25519). SECRET: whoever has it can ship an update to every Wren.\n# Never commit it, never send it. Keep it in secrets/production.yaml (UPDATE_SIGNING_KEY) and in a password manager.\n%s\n", text)
	if err := os.write_entire_file(path, body); err != nil { return fail("cannot write", path) }
	fmt.printfln("private key written to %s", path)
	fmt.printfln("public key: %s", pub)
	fmt.printfln("\nPut this line in src/update/public_key.odin, then rebuild Wren:\n\nUPDATE_PUBLIC_KEY :: \"%s\"", pub)
	return 0
}

@(private = "file")
update_pubkey :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Private=")
	if !ok { return EXIT_USAGE }
	seed, got := update_seed_chosen(f)
	if !got { return 1 }
	pub, _ := update.public_key_of(seed[:], context.temp_allocator)
	fmt.println(pub)
	return 0
}

////////////////////////////////
// The manifest

@(private = "file")
update_today :: proc() -> string {
	dt, ok := time.time_to_datetime(time.now())
	if !ok { return "" }
	return fmt.tprintf("%04d-%02d-%02d", dt.year, dt.month, dt.day)
}

// The unsigned manifest of the file at `exe`, made for `version` and `platform`.
@(private = "file")
update_make_manifest :: proc(exe, version, platform: string) -> (m: update.Manifest, bytes: []byte, ok: bool) {
	if !update.version_valid(version) { fmt.eprintfln("%q is not an X.Y.Z version", version); return {}, nil, false }
	data, err := os.read_entire_file(exe, context.temp_allocator)
	if err != nil { fmt.eprintfln("cannot read %s", exe); return {}, nil, false }
	m = update.Manifest{
		version = version, platform = platform,
		file = update.expected_file_name(version, platform, context.temp_allocator),
		sha256 = update.sha256_hex(data, context.temp_allocator), size = i64(len(data)), published = update_today(),
	}
	return m, update.manifest_bytes(m, context.temp_allocator), true
}

@(private = "file")
update_manifest :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Exe= -Version= -Platform= -Out=")
	if !ok { return EXIT_USAGE }
	exe, version, out := tooling.flag(f, "-Exe", ""), tooling.flag(f, "-Version", ""), tooling.flag(f, "-Out", "")
	if exe == "" || version == "" || out == "" { fmt.eprint(UPDATE_USAGE); return EXIT_USAGE }
	m, bytes, good := update_make_manifest(exe, version, tooling.flag(f, "-Platform", update.PLATFORM_WINDOWS_X64))
	if !good { return 1 }
	// what a client will accept: size and name checked as it will check them
	if _, err := update.verify(bytes, "x", "x", m.platform, context.temp_allocator); err == .Too_Long { return fail("the manifest is too large") }
	if os.write_entire_file(out, bytes) != nil { return fail("cannot write", out) }
	fmt.printfln("%s: %s, %d bytes, sha256 %s", out, m.file, m.size, m.sha256)
	return 0
}

@(private = "file")
update_sign :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Manifest= -Private=")
	if !ok { return EXIT_USAGE }
	path := tooling.flag(f, "-Manifest", "")
	if path == "" { fmt.eprint(UPDATE_USAGE); return EXIT_USAGE }
	seed, got := update_seed_chosen(f)
	if !got { return 1 }
	manifest, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return fail("cannot read", path) }
	sig, signed := update.sign(seed[:], manifest, context.temp_allocator)
	if !signed { return fail("cannot sign with this key") }
	out := fmt.tprintf("%s.sig", path)
	if os.write_entire_file(out, fmt.tprintf("%s\n", sig)) != nil { return fail("cannot write", out) }
	fmt.printfln("signed %s -> %s", path, out)
	return 0
}

@(private = "file")
update_verify :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Manifest= -Sig= -Public= -Platform= -Current=")
	if !ok { return EXIT_USAGE }
	mpath, spath := tooling.flag(f, "-Manifest", ""), tooling.flag(f, "-Sig", "")
	if mpath == "" || spath == "" { fmt.eprint(UPDATE_USAGE); return EXIT_USAGE }
	manifest, e1 := os.read_entire_file(mpath, context.temp_allocator)
	sig, e2 := os.read_entire_file(spath, context.temp_allocator)
	if e1 != nil || e2 != nil { return fail("cannot read the manifest or its signature") }
	key := tooling.flag(f, "-Public", update.UPDATE_PUBLIC_KEY)
	m, err := update.verify(manifest, string(sig), key, tooling.flag(f, "-Platform", update.PLATFORM_WINDOWS_X64), context.temp_allocator)
	if err != .None { fmt.eprintfln("INVALID: %s", update.error_text(err)); return 1 }
	fmt.printfln("VALID: Wren %s for %s, %s, %d bytes, sha256 %s, published %s", m.version, m.platform, m.file, m.size, m.sha256, m.published)
	if cur := tooling.flag(f, "-Current", ""); cur != "" {
		if e := update.check_newer(m, cur); e != .None { fmt.printfln("but not an update for %s: %s", cur, update.error_text(e)); return 1 }
		fmt.printfln("an update for %s", cur)
	}
	return 0
}

////////////////////////////////
// What `wrentool package` does

// The signed manifest of a release's program, next to it in `dist`: update-<platform>.json and its .sig. Not made for a build that is
// not the release (a label, a development build: its file is not named as a release's). With `require` (the release workflow), a missing
// key, or one that is not the key built into Wren, is an error: a release no Wren can verify must never be published.
package_update_manifest :: proc(exe, version, platform, dist: string, require: bool) -> bool {
	if filepath.base(exe) != update.expected_file_name(version, platform, context.temp_allocator) {
		if require { fmt.eprintfln("update: %s is not named as a release's file (%s): no manifest", filepath.base(exe), update.expected_file_name(version, platform, context.temp_allocator)); return false }
		fmt.println("update: not a release build: no update manifest")
		return true
	}
	text := env(UPDATE_KEY_ENV)
	if text == "" {
		if require { fmt.eprintfln("update: %s is not set: a release without a signed manifest cannot be updated to", UPDATE_KEY_ENV); return false }
		fmt.printfln("update: %s is not set: no update manifest", UPDATE_KEY_ENV)
		return true
	}
	seed, good := update.seed_decode(text)
	if !good { fmt.eprintfln("update: %s is not an update private key", UPDATE_KEY_ENV); return false }
	m, bytes, made := update_make_manifest(exe, version, platform)
	if !made { return false }
	sig, signed := update.sign(seed[:], bytes, context.temp_allocator)
	if !signed { fmt.eprintln("update: cannot sign with this key"); return false }
	// the key built into Wren must verify it: otherwise no Wren accepts this release
	built_in := update.UPDATE_PUBLIC_KEY
	pub, _ := update.public_key_of(seed[:], context.temp_allocator)
	if built_in == "" {
		if require { fmt.eprintln("update: src/update/public_key.odin has no key: no Wren could verify this release"); return false }
		built_in = pub
	}
	if built_in != pub { fmt.eprintfln("update: the key that signs (%s) is not the one built into Wren (%s): no Wren would accept this release", pub, built_in); return false }
	if _, err := update.verify(bytes, sig, built_in, platform, context.temp_allocator); err != .None { fmt.eprintfln("update: the manifest made here does not verify: %s", update.error_text(err)); return false }
	json_path, sig_path := fmt.tprintf("%s/update-%s.json", dist, platform), fmt.tprintf("%s/update-%s.json.sig", dist, platform)
	if os.write_entire_file(json_path, bytes) != nil || os.write_entire_file(sig_path, fmt.tprintf("%s\n", sig)) != nil { fmt.eprintln("update: cannot write the manifest"); return false }
	fmt.printfln("update manifest  %s (Wren %s, %s, sha256 %s) signed -> %s", json_path, m.version, m.file, m.sha256, sig_path)
	return true
}
