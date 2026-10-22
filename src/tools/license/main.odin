package licensetool

import "core:crypto"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "wb:license"

// tools\license.ps1: makes the key pair that signs Wren licences and issues licences. Offline: nothing here uses the
// network. See docs/licence.md.
//
//   keygen [-private FILE] [-force]
//   pubkey [-private FILE | -dev]
//   issue  -name N -email E -edition supporter|patron -order ID [-date YYYY-MM-DD] [-private FILE | -dev] [-out FILE]
//   verify (FILE | -text KEY) [-public KEY]

USAGE :: `usage: license <command> [options]
  keygen [-private FILE] [-force]     make the signing key pair; FILE defaults to %USERPROFILE%\.wren-license\private.key
                                      (outside the repository: a path inside a git work tree is refused)
  pubkey [-private FILE | -dev]       print the public key and the line to put in src/license/public_key.odin
  issue  -name N -email E -edition supporter|patron -order ID [-date YYYY-MM-DD] [-private FILE | -dev] [-out FILE]
                                      sign a licence; prints the key and writes <out> (default
                                      %USERPROFILE%\.wren-license\issued\<order>.wrenlicense)
  verify FILE | -text KEY [-public KEY | -dev]
                                      check a licence (default: the key built into Wren)
  -dev uses the development pair of the tests (src/license/dev_keys.odin), never the production one.
`

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 { fmt.eprint(USAGE); os.exit(2) }
	cmd, rest := args[0], args[1:]
	ok: bool
	switch cmd {
	case "keygen": ok = keygen(rest)
	case "pubkey": ok = pubkey(rest)
	case "issue":  ok = issue(rest)
	case "verify": ok = verify(rest)
	case:
		fmt.eprintfln("unknown command %q", cmd)
		fmt.eprint(USAGE)
		os.exit(2)
	}
	os.exit(ok ? 0 : 1)
}

////////////////////////////////
// Options

Options :: struct {
	values: map[string]string,   // -name value
	flags:  map[string]bool,     // -force
	free:   [dynamic]string,
}

// Options that take no value.
FLAGS :: [?]string{"force", "dev"}

parse_options :: proc(args: []string) -> (o: Options, ok: bool) {
	o.values = make(map[string]string, context.temp_allocator)
	o.flags = make(map[string]bool, context.temp_allocator)
	o.free = make([dynamic]string, context.temp_allocator)
	i := 0
	for i < len(args) {
		a := args[i]
		i += 1
		if !strings.has_prefix(a, "-") || a == "-" { append(&o.free, a); continue }
		name := strings.trim_left(a, "-")
		is_flag := false
		for f in FLAGS { if f == name { is_flag = true } }
		if is_flag { o.flags[name] = true; continue }
		if i >= len(args) { fmt.eprintfln("option -%s needs a value", name); return o, false }
		o.values[name] = args[i]
		i += 1
	}
	return o, true
}

////////////////////////////////
// The private key file

join :: proc(parts: ..string) -> string { return strings.join(parts, "\\", context.temp_allocator) }

home :: proc() -> string {
	h := os.get_env("USERPROFILE", context.temp_allocator)
	if h == "" { h = os.get_env("HOME", context.temp_allocator) }
	return h
}

default_private_path :: proc() -> string {
	return join(home(), ".wren-license", "private.key")
}

// True when `path` is inside a git work tree (an ancestor holds .git): a signing key there could be committed.
inside_git_tree :: proc(path: string) -> bool {
	abs, abs_err := filepath.abs(path, context.temp_allocator)
	if abs_err != nil { return true }   // cannot tell where it is: do not risk it
	dir := os.dir(abs)
	for dir != "" {
		if os.exists(join(dir, ".git")) { return true }
		parent := os.dir(dir)
		if parent == dir { break }
		dir = parent
	}
	return false
}

read_seed :: proc(path: string) -> (seed: [32]byte, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { fmt.eprintfln("cannot read the private key %s: run `keygen` first, or pass -private", path); return {}, false }
	text := license.normalize(string(data), context.temp_allocator)
	b, ok_b := license.public_key_decode(text)   // (same shape: 32 bytes of base64url)
	if !ok_b { fmt.eprintfln("%s is not a Wren private key file", path); return {}, false }
	return b, true
}

// The seed named by -dev / -private / the default path.
chosen_seed :: proc(o: Options) -> (seed: [32]byte, ok: bool) {
	if o.flags["dev"] { return license.DEV_SEED, true }
	return read_seed(o.values["private"] or_else default_private_path())
}

////////////////////////////////
// Commands

keygen :: proc(args: []string) -> bool {
	o, ok := parse_options(args)
	if !ok { return false }
	path := o.values["private"] or_else default_private_path()
	if inside_git_tree(path) {
		fmt.eprintfln("refused: %s is inside a git work tree, where the private key could be committed. Pick a folder outside the repository.", path)
		return false
	}
	if os.exists(path) && !o.flags["force"] {
		fmt.eprintfln("%s exists already: a new key would make every licence issued so far invalid. Use -force to replace it (keep a copy first).", path)
		return false
	}
	seed: [32]byte
	crypto.rand_bytes(seed[:])
	if dir := os.dir(path); dir != "" { _ = os.make_directory_all(dir) }
	text := fmt.tprintf("# Wren licence signing key (Ed25519). SECRET: whoever has it can issue licences.\n# Never commit it, never send it. Keep a backup outside this computer.\n%s\n",
		license.public_key_encode(seed[:], context.temp_allocator))
	if err := os.write_entire_file(path, transmute([]byte)text); err != nil { fmt.eprintfln("cannot write %s: %v", path, err); return false }
	pub, _ := license.public_key_of(seed[:], context.temp_allocator)
	fmt.printfln("Private key written to %s", path)
	fmt.printfln("Public key: %s", pub)
	fmt.printfln("\nPut this line in src/license/public_key.odin, then rebuild Wren:\n\nPRODUCTION_PUBLIC_KEY :: \"%s\"", pub)
	return true
}

pubkey :: proc(args: []string) -> bool {
	o, ok := parse_options(args)
	if !ok { return false }
	seed := chosen_seed(o) or_return
	pub, _ := license.public_key_of(seed[:], context.temp_allocator)
	fmt.printfln("%s", pub)
	if !o.flags["dev"] { fmt.printfln("\nPRODUCTION_PUBLIC_KEY :: \"%s\"", pub) }
	return true
}

issue :: proc(args: []string) -> bool {
	o, ok := parse_options(args)
	if !ok { return false }
	l := license.License{
		edition = o.values["edition"] or_else "supporter",
		name = strings.trim_space(o.values["name"] or_else ""),
		email = strings.trim_space(o.values["email"] or_else ""),
		order = strings.trim_space(o.values["order"] or_else ""),
		date = o.values["date"] or_else "",
	}
	if l.name == "" || l.order == "" { fmt.eprintln("issue needs -name and -order (and -email, -edition supporter|patron)"); return false }
	if l.edition != "supporter" && l.edition != "patron" { fmt.eprintfln("-edition is supporter or patron, not %q", l.edition); return false }
	if l.date == "" {
		y, mo, d := time.date(time.now())
		l.date = fmt.tprintf("%04d-%02d-%02d", y, int(mo), d)
	}
	for f in ([]string{l.name, l.email, l.order, l.date}) {
		if len(f) > license.MAX_FIELD { fmt.eprintfln("a field is longer than %d bytes", license.MAX_FIELD); return false }
	}
	seed := chosen_seed(o) or_return
	text, signed := license.sign(seed[:], l, context.temp_allocator)
	if !signed { fmt.eprintln("signing failed"); return false }
	// never hand out something this very tool would refuse
	pub, _ := license.public_key_of(seed[:], context.temp_allocator)
	back, err := license.verify(text, pub, context.temp_allocator)
	if err != .None || back.name != l.name || back.order != l.order { fmt.eprintfln("the licence does not verify (%v)", err); return false }

	path, has_out := o.values["out"]
	if !has_out { path = join(home(), ".wren-license", "issued", fmt.tprintf("%s.wrenlicense", safe_name(l.order))) }
	if dir := os.dir(path); dir != "" { _ = os.make_directory_all(dir) }
	file := fmt.tprintf("# Wren licence (%s) for %s\n# Order %s, %s. Open this file with Wren, or paste the key in about:wren.\n%s\n", license.edition_title(l.edition), l.name, l.order, l.date, wrap(text, 76))
	if werr := os.write_entire_file(path, transmute([]byte)file); werr != nil { fmt.eprintfln("cannot write %s: %v", path, werr); return false }
	fmt.printfln("Licence of %s (%s), order %s, %s", l.name, license.edition_title(l.edition), l.order, l.date)
	fmt.printfln("File: %s\n\nKey (to paste in about:wren):\n%s", path, text)
	return true
}

verify :: proc(args: []string) -> bool {
	o, ok := parse_options(args)
	if !ok { return false }
	text, has_text := o.values["text"]
	if !has_text {
		if len(o.free) != 1 { fmt.eprintln("verify needs a file or -text KEY"); return false }
		data, err := os.read_entire_file(o.free[0], context.temp_allocator)
		if err != nil { fmt.eprintfln("cannot read %s", o.free[0]); return false }
		text = string(data)
	}
	public: string
	switch {
	case o.flags["dev"]:      seed := license.DEV_SEED; public, _ = license.public_key_of(seed[:], context.temp_allocator)
	case "public" in o.values: public = o.values["public"]
	case:                      public = license.PRODUCTION_PUBLIC_KEY
	}
	l, err := license.verify(text, public, context.temp_allocator)
	if err != .None { fmt.printfln("INVALID: %s", license.error_text(err)); return false }
	fmt.printfln("VALID: %s licence of %s <%s>, order %s, %s", license.edition_title(l.edition), l.name, l.email, l.order, l.date)
	return true
}

// The order number as a file name.
safe_name :: proc(s: string) -> string {
	b := transmute([]byte)strings.clone(s, context.temp_allocator)
	for &c in b { if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_') { c = '_' } }
	return len(b) > 0 ? string(b) : "licence"
}

wrap :: proc(s: string, width: int) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += width {
		if i > 0 { strings.write_byte(&sb, '\n') }
		strings.write_string(&sb, s[i:min(i + width, len(s))])
	}
	return strings.to_string(sb)
}
