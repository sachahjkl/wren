#+build linux
package test_all

import "core:fmt"
import "core:strings"

// What is portable already (docs/portability.md): odin check for Linux of every package that is, then the unit tests of those that have tests, with the flags of the Windows steps (-vet, the memory
// check; RLIMIT_STACK instead of /STACK). Needs build/wasmtime-linux (wrentool fetch wasmtime), build/lexbor-linux (wrentool build lexbor) and build/native-linux (wrentool build native -Features text,a11y).
// Packages move from "not yet" to these lists as they are ported; tests that measure time stay out.

// The tests of src/browser run on Linux (the package as a whole does not pass there yet).
BROWSER_LINUX_TESTS :: "-define:ODIN_TEST_NAMES=browser.the_lettering_of_the_card_is_raised_on_every_system,browser.settings_pages_name_registered_preferences,browser.every_definition_is_valid,browser.tree_adopt_places_children_after_the_subtree,browser.tree_forget_and_detach_lift_the_children,browser.tree_repair_keeps_only_what_the_order_says,browser.tree_rows_fold_except_toward_the_current_tab,browser.tree_survives_the_session"

linux_table :: proc(cfg: ^Config) -> []Step {
	t: [dynamic]Step
	// (js/image is out until the JS engine's wasm can be built on Linux. idb is checked but its tests are out: two of them, a failed request and a failed write, fail on the GitHub runner and pass in WSL; not understood yet)
	CHECK := []string{"base", "host", "config", "css", "http", "i18n", "xml", "adblock", "canvas2d", "license", "dom", "url", "html", "cookies", "csp", "forms", "style", "layout", "webfont", "wasm", "js", "idb", "httpcache", "images",
		"webauthn", "desktop", "update", "remote", "tools/testenv", "net", "fetch", "media", "page", "blocker", "remote/api", "remote/client", "tools/crashtrace", "tools/wpt/reftest", "tools/wpt", "tools/test_all", "tools/endurance", "browser", "e2e", "tools/e2e"}
	UNITS := []string{"base", "host", "css", "http", "xml", "adblock", "canvas2d", "dom", "url", "html", "cookies", "csp", "forms", "style", "layout", "webfont", "js", "httpcache", "webauthn", "desktop", "update", "net", "fetch", "media", "blocker", "page", "tools/crashtrace", "tools/wpt/reftest"}
	ONE_AT_A_TIME := []string{"wasm", "remote", "remote/api", "remote/client"}   // (one channel per process, as on Windows)
	POISONED := []string{"base", "style", "layout"}
	// browser is the first package that imports toolkit:render: its check needs libwgpu_native.a beside Odin's wgpu vendor package, which a bare WSL checkout may not have.
	wgpu := linux_has_wgpu_library()
	js_stub := linux_prepare_stubs()
	for p in CHECK {
		needs_wgpu := p == "browser" || p == "e2e" || p == "tools/e2e"
		if needs_wgpu && !wgpu { fmt.printfln("check skip src/%s (needs libwgpu_native.a for toolkit:render)", p); continue }
		append(&t, Step{name = fmt.aprintf("check: src/%s", p), actions = slice_of(Command{argv = strs("odin", "check", fmt.aprintf("src/%s", p), "-target:linux_amd64", "-no-entry-point", "-vet", WB, TOOLKIT), pkg = fmt.aprintf("src/%s", p)})})
	}
	linux_unit :: proc(t: ^[dynamic]Step, p: string, flags: []string) {
		name, _ := strings.replace_all(p, "/", "_")
		argv := join({"odin", "test", fmt.aprintf("src/%s", p), "-vet", WB, TOOLKIT, MEM_CHECK}, flags, {out_flag(fmt.aprintf("build/linux/%s_test", name))})
		append(t, Step{name = fmt.aprintf("unit tests: %s", p), actions = slice_of(Command{argv = argv, pkg = fmt.aprintf("src/%s", p), rule = .Says_Successful})})
	}
	for p in UNITS {
		if js_stub && (p == "page" || p == "blocker") { fmt.printfln("test skip  src/%s (needs the JS engine's wasm)", p); continue }
		linux_unit(&t, p, nil)
	}
	for p in ONE_AT_A_TIME { linux_unit(&t, p, {ONE_THREAD}) }
	// freed memory poisoned (src/base/poison_linux.odin: free and realloc of the whole program)
	for p in POISONED {
		argv := join({"odin", "test", fmt.aprintf("src/%s", p), "-vet", WB, TOOLKIT, MEM_CHECK, POISON}, {out_flag(fmt.aprintf("build/linux/%s_poison_test", p))})
		append(&t, Step{name = fmt.aprintf("unit tests on poisoned memory: %s", p), actions = slice_of(Command{argv = argv, pkg = fmt.aprintf("src/%s", p), rule = .Says_Successful})})
	}
	// browser: the tests of its own that hold on Linux, with the text backend Wren has there (build/native-linux built with -Features text,a11y)
	if wgpu { linux_unit(&t, "browser", {BROWSER_LINUX_TESTS, "-define:FONT_BACKEND=native", "-define:FONT_NATIVE_LINK=false"}) }
	return t[:]
}
