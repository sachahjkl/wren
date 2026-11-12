// Package vaulttool: `wrentool vault`, the Vault's helper from the command line (docs/bitwarden.md, phase 0).
//   wrentool vault test                                   cargo test of wren-vault
//   wrentool vault probe -Server http://127.0.0.1:8000 -Email a@b.c [-Totp 123456] [-Helper path]
// probe starts build/vault/wren-vault, logs in (the master password comes from WREN_VAULT_PASSWORD, never from a flag:
// a flag stays in the shell's history), syncs, prints the item count, and locks. It prints no value of the vault.
// The protocol is written here with core:encoding/json: this tool links none of the browser's packages.
package vaulttool

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "wb:tools/tooling"
import "wb:tools/wrentool/deps"

PASSWORD_ENV :: "WREN_VAULT_PASSWORD"
FRAME_MAX :: 1 << 20

run :: proc(args: []string) -> int {
	if len(args) == 0 { usage(); return 2 }
	switch args[0] {
	case "test":
		return deps.test_vault({profile = "release"}) ? 0 : 1
	case "probe":
		return probe(args[1:])
	}
	usage()
	return 2
}

usage :: proc() {
	fmt.eprintln("wrentool vault test")
	fmt.eprintfln("wrentool vault probe -Server <base URL> -Email <email> [-Totp <code>] [-Helper <path>]   (the password: %s)", PASSWORD_ENV)
}

@(private = "file")
Hello :: struct {
	id: u64, op: string, protocol: int, state_dir, identity_url, api_url: string, persist: bool, device_name, client_version: string,
}
@(private = "file")
Login :: struct { id: u64, op, email, password: string }
@(private = "file")
Login_Code :: struct { id: u64, op, email, totp: string }
@(private = "file")
Plain :: struct { id: u64, op: string }

@(private = "file")
Pipe_Ends :: struct { w, r: ^os.File }

probe :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Server= -Email= -Totp= -Helper=")
	if !ok { return 2 }
	server := strings.trim_right(tooling.flag(f, "-Server"), "/")
	email := tooling.flag(f, "-Email")
	password, _ := os.lookup_env(PASSWORD_ENV, context.temp_allocator)
	if server == "" || email == "" || password == "" { usage(); return 2 }
	helper := tooling.flag(f, "-Helper", deps.vault_program())
	if !os.exists(helper) { fmt.eprintfln("no helper at %s: run  wrentool build vault", helper); return 1 }

	in_r, in_w, e1 := os.pipe()
	out_r, out_w, e2 := os.pipe()
	if e1 != nil || e2 != nil { fmt.eprintln("cannot make the pipes"); return 1 }
	process, err := os.process_start({command = {helper}, stdin = in_r, stdout = out_w, stderr = os.stderr})
	_ = os.close(in_r)
	_ = os.close(out_w)
	if err != nil { fmt.eprintfln("cannot start %s", helper); return 1 }
	p := Pipe_Ends{w = in_w, r = out_r}
	defer {
		if p.w != nil { _ = os.close(p.w) }
		_ = os.close(p.r)
		_, _ = os.process_wait(process)
	}

	a, a_ok := ask(&p, Hello{id = 1, op = "hello", protocol = 1, state_dir = "", identity_url = fmt.tprintf("%s/identity", server),
		api_url = fmt.tprintf("%s/api", server), persist = false, device_name = "wrentool", client_version = "probe"})
	if !answered(a, a_ok, "hello") { return 1 }
	fmt.printfln("hello: helper %s, protocol %v", text(a, "helper_version"), a["protocol"])

	a, a_ok = ask(&p, Login{id = 2, op = "login", email = email, password = password})
	if !answered(a, a_ok, "login") { return 1 }
	if text(a, "result") == "need_two_factor" {
		code := tooling.flag(f, "-Totp")
		if code == "" { fmt.eprintln("login: the account asks for its authenticator code (-Totp)"); return 1 }
		a, a_ok = ask(&p, Login_Code{id = 3, op = "login", email = email, totp = code})
		if !answered(a, a_ok, "login (code)") { return 1 }
	}
	fmt.println("login: unlocked")

	a, a_ok = ask(&p, Plain{id = 4, op = "sync"})
	if !answered(a, a_ok, "sync") { return 1 }
	fmt.printfln("sync: %v items", a["items"])

	a, a_ok = ask(&p, Plain{id = 5, op = "lock"})
	_ = answered(a, a_ok, "lock")
	return 0
}

// One request and its answer (the helper answers in order).
@(private = "file")
ask :: proc(p: ^Pipe_Ends, request: $T) -> (json.Object, bool) {
	body, merr := json.marshal(request, allocator = context.temp_allocator)
	if merr != nil { return nil, false }
	n := u32(len(body))
	head := [4]u8{u8(n), u8(n >> 8), u8(n >> 16), u8(n >> 24)}
	if _, e := os.write(p.w, head[:]); e != nil { return nil, false }
	if _, e := os.write(p.w, body); e != nil { return nil, false }
	got: [4]u8
	if c, e := os.read_full(p.r, got[:]); e != nil || c != 4 { return nil, false }
	size := int(u32(got[0]) | u32(got[1]) << 8 | u32(got[2]) << 16 | u32(got[3]) << 24)
	if size < 1 || size > FRAME_MAX { return nil, false }
	answer := make([]u8, size, context.temp_allocator)
	if c, e := os.read_full(p.r, answer); e != nil || c != size { return nil, false }
	v, perr := json.parse(answer, .JSON, true, context.temp_allocator)
	if perr != .None { return nil, false }
	o, is_object := v.(json.Object)
	return o, is_object
}

@(private = "file")
answered :: proc(a: json.Object, ok: bool, what: string) -> bool {
	if !ok { fmt.eprintfln("%s: no answer (the helper stopped?)", what); return false }
	if okv, _ := a["ok"].(json.Boolean); !okv {
		fmt.eprintfln("%s: %s: %s", what, text(a, "error"), text(a, "message"))
		return false
	}
	return true
}

@(private = "file")
text :: proc(a: json.Object, key: string) -> string {
	s, _ := a[key].(json.String)
	return s
}
