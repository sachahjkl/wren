package blockerpages

// What a hooked API costs per call (`blockerpages -hooks`): the test server's hookbench.html, without the blocker, with the native hooks, with their JavaScript versions.

import "core:fmt"
import "core:os"
import "wb:base"
import "wb:blocker"
import "wb:config"
import "wb:dom"
import "wb:testserver"
import "wb:tools/headless"

@(private = "file") PROFILE :: "build/blockerpages_hooks_profile"
@(private = "file") TAB :: 1
@(private = "file") CONF :: "version\t1\n[lists]\n[sites]\n[rules]\n[my-filters]\n"
// (each rule hooks what hookbench.html calls: a text that no callback has, a property nothing has, the constant it reads)
@(private = "file") RULES :: "127.0.0.1##+js(nostif, NEVERMATCH-bench)\n127.0.0.1##+js(jp, neverKey)\n127.0.0.1##+js(set-constant, benchConst, 7)\n"
@(private = "file") LOG_ID :: "log"
@(private = "file") LOAD_LIMIT_MS :: 120_000.0
@(private = "file") Mode :: struct { name: string, blocker, native: bool }
@(private = "file") MODES := [?]Mode{{"no blocker", false, false}, {"native hooks", true, true}, {"JavaScript versions", true, false}}

hooks_cost :: proc() -> bool {
	server, why := testserver.start()
	if server == 0 { fmt.eprintln(why); return false }
	e: headless.Env
	if !headless.init(&e) { fmt.eprintln("the stack does not start"); return false }
	defer headless.destroy(&e)
	_ = os.remove_all(PROFILE)
	_ = os.make_directory_all(PROFILE + "/blocker")
	_ = os.write_entire_file(PROFILE + "/blocker/blocker.conf", transmute([]byte)string(CONF + RULES))
	defer os.remove_all(PROFILE)
	prefs := config.prefs_make()
	defer config.prefs_destroy(&prefs)
	blocker.register_prefs(&prefs)
	config.set_from_string(&prefs, "blocker.update.enabled", "false", .User)
	b: blocker.Blocker
	blocker.start(&b, &e.loop, &e.client, &e.loader, &prefs, PROFILE)
	defer blocker.shutdown(&b, &e.loader)
	blocker.tab_register(&b, TAB, e.process)
	url := fmt.tprintf("http://127.0.0.1:%d/site/blocker/hookbench.html", server)
	for mode in MODES {
		config.set_from_string(&prefs, "blocker.enabled", mode.blocker ? "true" : "false", .User)
		config.set_from_string(&prefs, "blocker.hooks.native", mode.native ? "true" : "false", .User)
		d := headless.open(&e, url)
		defer headless.close(d)
		if !headless.pump(d, LOAD_LIMIT_MS, headless.loaded) || d.failed != "" { fmt.eprintfln("%s: %s", url, d.failed != "" ? d.failed : "does not load"); return false }
		log := base.NIL_HANDLE
		for h in dom.ids_all(d.page.doc, LOG_ID) { log = h }
		fmt.printfln("%s: %s", mode.name, dom.text_content(d.page.doc, log))
	}
	return true
}
