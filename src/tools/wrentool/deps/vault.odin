package deps

import "core:fmt"
import "core:os"
import "wb:tools/tooling"

// The Vault's helper, wren-vault (docs/bitwarden.md): a separate GPL-3.0 program in its own repository, by default the
// folder beside this one (WREN_VAULT_SOURCE names another). No Wren code goes into it and the browser builds and runs
// without it: no build of the browser builds it.
//   wrentool build vault [-Profile release|quick]   -> build/vault/wren-vault
// Pinned: its Cargo.lock (--locked); the first build makes it once, to be committed in wren-vault.

VAULT_SOURCE_DEFAULT :: "../wren-vault"
VAULT_SOURCE_ENV :: "WREN_VAULT_SOURCE"
VAULT_OUT :: "build/vault"
VAULT_PROGRAM :: "wren-vault" + tooling.EXE_SUFFIX

vault_source :: proc() -> string {
	if s, _ := os.lookup_env(VAULT_SOURCE_ENV, context.temp_allocator); s != "" { return s }
	return VAULT_SOURCE_DEFAULT
}

// The helper as built: build/vault/wren-vault.
vault_program :: proc() -> string { return fmt.tprintf("%s/%s", VAULT_OUT, VAULT_PROGRAM) }

@(private)
vault_manifest :: proc(o: Options) -> (manifest: string, ok: bool) {
	src := vault_source()
	manifest = fmt.tprintf("%s/Cargo.toml", src)
	if !os.exists(manifest) {
		return "", fail(o, fmt.tprintf("no wren-vault source in %s (set %s to its folder)", src, VAULT_SOURCE_ENV))
	}
	if !os.exists(fmt.tprintf("%s/Cargo.lock", src)) {
		tooling.say(o.log, fmt.tprintfln("%s/Cargo.lock does not exist: it is made now (commit it in wren-vault)", src))
		if tooling.run({command = {"cargo", "generate-lockfile", "--manifest-path", manifest}, log = o.log}) != 0 {
			return "", fail(o, "cargo generate-lockfile failed")
		}
	}
	return manifest, true
}

build_vault :: proc(o: Options) -> bool {
	manifest, ok := vault_manifest(o)
	if !ok { return false }
	profile := o.profile == "quick" ? "quick" : "release"
	target := fmt.tprintf("%s/target", VAULT_OUT)
	_ = os.make_directory_all(VAULT_OUT)
	cmd := []string{"cargo", "build", "--locked", "--profile", profile, "--manifest-path", manifest, "--target-dir", target, "--bin", "wren-vault"}
	if tooling.run({command = cmd, env = msvc_environment(), log = o.log}) != 0 { return fail(o, "cargo build of wren-vault failed") }
	out := vault_program()
	if os.copy_file(out, fmt.tprintf("%s/%s/%s", target, profile, VAULT_PROGRAM)) != nil { return fail(o, "the helper cannot be copied") }
	tooling.say(o.log, fmt.tprintfln("built %s (%s)", out, profile))
	return true
}

// `cargo test` of the helper: its codec, its matching, its state file, its login against a mock server on loopback.
test_vault :: proc(o: Options) -> bool {
	manifest, ok := vault_manifest(o)
	if !ok { return false }
	target := fmt.tprintf("%s/target", VAULT_OUT)
	cmd := []string{"cargo", "test", "--locked", "--manifest-path", manifest, "--target-dir", target}
	if tooling.run({command = cmd, env = msvc_environment(), log = o.log}) != 0 { return fail(o, "the helper's tests failed") }
	return true
}
