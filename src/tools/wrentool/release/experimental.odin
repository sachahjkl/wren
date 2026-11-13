package release

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:remote/api"
import "wb:tools/tooling"
import "wb:tools/wrentool/bench"
import "wb:tools/wrentool/builder"
import "wb:tools/wrentool/changelog"
import "wb:tools/wrentool/deps"
import toolbox "../../../../ext/gui_toolkit/src/toolbox"

// An experimental build of Wren, ready to hand out: a release build (the amber one) with a label, the development licence key accepted, a demonstration licence inside (wrentool build: WREN_EMBEDDED_LICENSE)
// unless -NoEmbed, notes made from what the next version brings (changelog.d), a zip, and the link of its upload to buzzheavier (anonymous: the link lives a few days) unless -NoUpload.
// -NoBuild packs what build/wren.exe is. -Vault dir keeps the notes, the link and the symbols zipped in that folder; by default nothing is kept.

EXPERIMENTAL_DIR :: "build/experimental"
UPLOAD_URL :: "https://w.buzzheavier.com"
LINK_URL :: "https://buzzheavier.com"
UPLOAD_LIMIT_SECONDS :: "1800"
LINK_LIMIT_SECONDS :: "60"
TITLE_MAX :: 150
CARD_SIZE :: [2]int{1000, 1100}
CARD_SCRIPT :: `(document.getElementById("lic") ? "card" : "no card") + "|" + document.title`
KNOWN_LIMITS :: `- The exe is not signed: Windows SmartScreen or an antivirus may warn on the first start ("More info", then "Run anyway"). Its SHA-256 is below.
- Windows 10 or 11, 64 bits. Nothing else to install.
- This build trusts the development key of the licences (public, worth nothing): the demonstration licence shows the card, a real licence will not be accepted by it. A release never accepts that key, and has no licence inside.
- It shares %APPDATA%\Wren with any other Wren: start it with ` + "`--profile <folder>`" + ` to keep it apart.
- With a fresh profile the content blocker compiles its lists at the first start: the first page can wait a few seconds (up to 20) before it loads.
- Experimental means what it says: it is the current state of the work, tested by the project's checks but not used for long. Crashes leave a report in %APPDATA%\Wren\crashes.`
SECTION_NAMES := []string{"Added", "Changed", "Deprecated", "Removed", "Fixed", "Security"}

// The card of about:wren, in a Wren of that exe and profile.
@(private)
licence_card :: proc(exe, profile: string, prefs: []string) -> (text: string, ok: bool) {
	w: bench.Wren
	if !bench.start(&w, {exe = exe, profile = profile, size = CARD_SIZE, prefs = prefs, url = "about:wren"}) { return "", false }
	defer bench.stop(&w)
	if api.wait_selector(&w.session, "body") != .None || api.wait_stable(&w.session) != .None { fmt.eprintln(api.last_failure().message); return "", false }
	said, e := api.eval(&w.session, CARD_SCRIPT)
	if e != .None { fmt.eprintln(api.last_failure().message); return "", false }
	return strings.clone(said), true
}

// An entry's title: its bold lead, else its text up to the first colon or full stop.
entry_title :: proc(e: string) -> string {
	t := e
	if strings.has_prefix(t, "**") {
		if end := strings.index(t[2:], "**"); end > 0 { t = t[2:2 + end] }
	} else {
		for sep in ([]string{": ", ". "}) { if i := strings.index(t, sep); i > 0 { t = t[:i] } }
	}
	t, _ = strings.remove_all(t, "`", context.temp_allocator)
	t, _ = strings.remove_all(t, "**", context.temp_allocator)
	t = strings.join(strings.fields(t, context.temp_allocator), " ", context.temp_allocator)
	t = strings.trim_right(t, ".:")
	if len(t) > TITLE_MAX { t = fmt.tprintf("%s...", t[:TITLE_MAX - 3]) }
	return t
}

run_experimental :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Label= -NoBuild -NoUpload -NoVerify -NoEmbed -Notes= -Vault=")
	if !ok { return EXIT_USAGE }
	label := tooling.flag(f, "-Label", fmt.tprintf("experimental-%s", today()))
	for c in transmute([]u8)label {
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-') { return fail("the label is letters, digits, '.', '_' and '-' only:", label) }
	}
	embed := !tooling.flag_has(f, "-NoEmbed")
	version := source_version()
	if version == "" { return fail("APP_VERSION not found") }
	name := fmt.tprintf("wren-%s-%s-windows-x64", version, label)
	stage := fmt.tprintf("%s/%s", EXPERIMENTAL_DIR, name)
	commit_text, _ := tooling.capture({"git", "rev-parse", "--short", "HEAD"}, allocator = context.temp_allocator)
	commit := strings.trim_space(commit_text)
	status, _ := tooling.capture({"git", "status", "--porcelain"}, allocator = context.temp_allocator)
	dirty := strings.trim_space(status) != ""

	// the demonstration licence, made with the development key: it goes inside the exe, and in the zip as a file
	_ = os.make_directory_all(EXPERIMENTAL_DIR)
	lic_file := fmt.tprintf("%s/WREN-DEMO.wrenlicense", EXPERIMENTAL_DIR)
	order := fmt.tprintf("WREN-DEMO-%s", strings.join(strings.split(today(), "-", context.temp_allocator), "", context.temp_allocator))
	lic_code := tooling.run({command = {"build/license" + tooling.EXE_SUFFIX, "issue", "-dev", "-name", "Demo Supporter", "-email", "demo@example.org", "-edition", "supporter", "-order", order, "-out", lic_file}})
	if lic_code != 0 && !os.exists(lic_file) { return fail("making the demonstration licence failed (wrentool license builds the tool)") }
	lic_data, _ := os.read_entire_file(lic_file, context.temp_allocator)
	key := ""
	for l in strings.split_lines(string(lic_data), context.temp_allocator) {
		line := strings.trim_space(l)
		if line != "" && !strings.has_prefix(line, "#") { key = fmt.tprintf("%s%s", key, line) }
	}

	if !tooling.flag_has(f, "-NoBuild") {
		o := builder.options_from_env(.Release)
		o.label, o.accept_dev_key = label, true
		if embed { o.embedded_license = key }
		fmt.printfln("wrentool build release (%s-%s)", version, label)
		if !builder.browser(o) { return fail("wrentool build release failed") }
		base.remove_tree(DIST)
		os.set_env("WREN_VERSION_LABEL", label)
		code := run_package({})
		os.unset_env("WREN_VERSION_LABEL")
		if code != 0 { return code }
	}
	exe := fmt.tprintf("%s/%s.exe", DIST, name)
	if !os.exists(exe) { return fail(exe, "is not there (a build with another label? run without -NoBuild)") }
	sha, _ := toolbox.sha256_file(exe)
	fp, _ := deps.build_id_of(exe)
	symbols_from := fmt.tprintf("%s/symbols/%s-%s.map", DIST, name, fp)
	if !os.exists(symbols_from) { return fail("the symbols of", name, "are not there:", symbols_from) }
	symbols := fmt.tprintf("%s/%s-%s.map", EXPERIMENTAL_DIR, name, fp)
	_ = os.copy_file(symbols, symbols_from)

	// the stage: the exe and the licence as a file, to register it again after removing it
	base.remove_tree(stage)
	_ = os.make_directory_all(fmt.tprintf("%s/demo-licence", stage))
	staged := fmt.tprintf("%s/%s.exe", stage, name)
	_ = os.copy_file(staged, exe)
	_ = os.copy_file(fmt.tprintf("%s/demo-licence/WREN-DEMO.wrenlicense", stage), lic_file)
	_ = os.write_entire_file(fmt.tprintf("%s/demo-licence/key.txt", stage), fmt.tprintf("%s\r\n", key))

	if !tooling.flag_has(f, "-NoVerify") {
		if !verify_experimental(staged, lic_file, version, label, embed) { return 1 }
	}

	notes := experimental_notes(f, version, label, name, commit, dirty, sha, embed)
	if notes == "" { return 1 }
	_ = os.write_entire_file(fmt.tprintf("%s/README.txt", stage), notes)
	_ = os.write_entire_file(fmt.tprintf("%s/SHA256.txt", stage), fmt.tprintf("%s  %s.exe\r\n", sha, name))

	zip := fmt.tprintf("%s/%s.zip", EXPERIMENTAL_DIR, name)
	_ = os.remove(zip)
	if tooling.run({command = {"tar", "-a", "-c", "-f", fmt.tprintf("../%s.zip", name), "."}, dir = stage}) != 0 { return fail("the zip cannot be made") }
	zip_sha, _ := toolbox.sha256_file(zip)

	link := ""
	if !tooling.flag_has(f, "-NoUpload") {
		fmt.println("uploading to buzzheavier")
		resp, code := tooling.capture({"curl", "-sS", "--fail", "--max-time", UPLOAD_LIMIT_SECONDS, "-T", zip, fmt.tprintf("%s/%s.zip", UPLOAD_URL, name)}, allocator = context.temp_allocator, limit = 0)   // (curl's --max-time bounds it)
		if code != 0 { return fail("the upload failed:", resp) }
		id := upload_id(resp)
		if id == "" { return fail("the upload answered something with no file id:", resp) }
		link = fmt.tprintf("%s/%s", LINK_URL, id)
		head, _ := tooling.capture({"curl", "-sSIL", "--max-time", LINK_LIMIT_SECONDS, link}, allocator = context.temp_allocator)
		if !strings.contains(head, " 200") { fmt.printfln("WARNING: the link does not answer 200 yet: %s", strings.split_lines(head, context.temp_allocator)[0]) }
	}

	if vault := tooling.flag(f, "-Vault"); vault != "" {
		stamp := time.now()
		clock: [time.MIN_HMS_LEN]u8
		dest := fmt.tprintf("%s/%s %s", vault, today(), strings.join(strings.split(time.to_string_hms(stamp, clock[:]), ":", context.temp_allocator), "", context.temp_allocator))
		_ = os.make_directory_all(dest)
		_ = os.write_entire_file(fmt.tprintf("%s/NOTES.txt", dest), notes)
		full_dest, _ := filepath.abs(fmt.tprintf("%s/symbols-%s.zip", dest, fp), context.temp_allocator)
		_ = tooling.run({command = {"tar", "-a", "-c", "-f", full_dest, filepath.base(symbols)}, dir = EXPERIMENTAL_DIR})
		_ = os.write_entire_file(fmt.tprintf("%s/LIEN.txt", dest), fmt.tprintf("%s\r\nbuild (fingerprint): %s\r\nzip sha256: %s\r\nexe sha256: %s\r\ncommit: %s\r\nlink: %s\r\n", name, fp, zip_sha, sha, commit, link))
		fmt.printfln("copy in %s", dest)
	}
	fmt.printfln("\nzip   : %s\nsha256: %s\nsymbols: %s (build %s: wrentool crash-symbolize <crash report> -Symbols <this file>)\nlink  : %s", zip, zip_sha, symbols, fp, link != "" ? link : "(not uploaded)")
	return 0
}

@(private)
upload_id :: proc(resp: string) -> string {
	v, err := json.parse_string(resp, allocator = context.temp_allocator)
	if err != nil { return "" }
	o := v.(json.Object) or_else nil
	if d, has := o["data"].(json.Object); has { if id, is_text := d["id"].(json.String); is_text { return id } }
	id, _ := o["id"].(json.String)
	return id
}

// The packed exe itself must be what it says: pre-registered, or at least accepting the key: a build that does not accept it fails here, not in the hands of whoever gets it.
@(private)
verify_experimental :: proc(exe, lic_file, version, label: string, embed: bool) -> bool {
	said, _ := tooling.capture({exe, "version"}, allocator = context.temp_allocator)
	if !strings.contains(said, fmt.tprintf("%s-%s", version, label)) { fmt.eprintfln("the packed exe does not say it is %s-%s: %s", version, label, said); return false }
	profile := fmt.tprintf("%s/wren-exp-check-%s", base.temp_dir(context.temp_allocator), base.unique_name(context.temp_allocator))
	_ = os.make_directory_all(profile)
	defer base.remove_tree(profile)
	if !embed {
		full, _ := filepath.abs(lic_file, context.temp_allocator)
		r, ok := licence_card(exe, profile, {fmt.tprintf("browser.license.path=%s", full)})
		if !ok || strings.contains(r, "no card") { fmt.eprintfln("the packed exe does not show the licence card when it is given the file (%s): it does not accept the development key", r); return false }
		fmt.printfln("the card shows when the licence file is opened (%s)", r)
		return true
	}
	// a profile that never held a licence: the card is there with no setting at all
	r, ok := licence_card(exe, profile, nil)
	if !ok || strings.contains(r, "no card") { fmt.eprintfln("the packed exe is not pre-registered: about:wren has no card on a new profile (%s)", r); return false }
	// the user removes the licence: it stays removed at the next start
	file := fmt.tprintf("%s/license.wrenlicense", profile)
	if !os.exists(file) { fmt.eprintfln("the licence was not put in the profile (%s)", file); return false }
	_ = os.remove(file)
	r, ok = licence_card(exe, profile, nil)
	if !ok || !strings.contains(r, "no card") { fmt.eprintfln("a removed licence came back at the next start (%s)", r); return false }
	fmt.println("the card shows on a new profile; removed, it stays removed at the next start")
	return true
}

@(private)
experimental_notes :: proc(f: tooling.Flags, version, label, name, commit: string, dirty: bool, sha: string, embed: bool) -> string {
	cwd, _ := os.get_working_directory(context.temp_allocator)
	changes, ok := changelog.fragments_body(cwd, context.temp_allocator)
	if !ok { fmt.eprintln("a fragment of changelog.d is malformed (wrentool changelog -Check)"); return "" }
	titles := make(map[string][dynamic]string, context.temp_allocator)
	section := ""
	for raw in strings.split_lines(changes, context.temp_allocator) {
		line := strings.trim_right(raw, "\r")
		if strings.has_prefix(line, "### ") { section = strings.trim_space(line[len("### "):]); continue }
		if section == "" || !strings.has_prefix(line, "- ") { continue }
		list := titles[section]
		append(&list, entry_title(line[len("- "):]))
		titles[section] = list
	}
	known := KNOWN_LIMITS
	if path := tooling.flag(f, "-Notes"); path != "" {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil { fmt.eprintfln("%s cannot be read", path); return "" }
		known = string(data)
	}
	b := strings.builder_make(context.temp_allocator)
	heading :: proc(b: ^strings.Builder, text: string, mark: string) {
		fmt.sbprintln(b, text)
		fmt.sbprintln(b, strings.repeat(mark, len(text), context.temp_allocator))
	}
	heading(&b, fmt.tprintf("Wren %s, %s", version, label), "=")
	fmt.sbprintfln(&b, "Built %s from commit %s%s\n", today(), commit, dirty ? " (with uncommitted changes)" : "")
	heading(&b, "To try it", "-")
	fmt.sbprintfln(&b, "1. Run %s.exe (nothing to install).", name)
	if embed {
		strings.write_string(&b, "2. Open about:wren in the address bar: this build is pre-registered, the licence of \"Demo Supporter\" is already there and its card shows.\n   \"Remove the licence\" takes it off for good (it does not come back at the next start); to put it back, or to try another one,\n   paste the one line of demo-licence\\key.txt in the box and press Register, or open demo-licence\\WREN-DEMO.wrenlicense with Wren.\n")
	} else {
		strings.write_string(&b, "2. Open about:wren in the address bar. To see the licence card, paste the one line of demo-licence\\key.txt in the box and press Register,\n   or open demo-licence\\WREN-DEMO.wrenlicense with Wren, or drop that file on its window. The licence is made out to \"Demo Supporter\".\n")
	}
	strings.write_string(&b, "3. The card follows the pointer; the sheen crosses it every few seconds.\n\n")
	heading(&b, "To know", "-")
	fmt.sbprintfln(&b, "%s\n", strings.trim_right_space(known))
	for s in SECTION_NAMES {
		list, has := titles[s]
		if !has || len(list) == 0 { continue }
		heading(&b, fmt.tprintf("%s since the last release (%d)", s, len(list)), "-")
		for t in list { fmt.sbprintfln(&b, "- %s", t) }
		fmt.sbprintln(&b)
	}
	heading(&b, "SHA-256", "-")
	fmt.sbprintfln(&b, "%s  %s.exe", sha, name)
	return strings.to_string(b)
}
