package e2e_scenarios

// Storage partitioning (storage.partitioned), against the test server: http://127.0.0.1 (site A) embeds the third party http://localhost (T,
// examples/site/partition/t.html), which is also opened as a tab of its own. T's cookies, localStorage, sessionStorage, Cache API, BroadcastChannel
// and service worker registrations under A differ from its first-party ones, and are the same under another origin of site A (the partition is per
// top-level site); its requests say Sec-Fetch-Storage-Access; a click in T inside A asks for storage access (document.requestStorageAccess(): the
// prompt answered by browser.dialogs.test_answer) and T then uses its first-party data there. (Two different sites embedding the same third party
// need a third host name: the keys of that case are checked by src/page/storage_partition_test.odin.)

import "core:fmt"
import "core:testing"
import "wb:e2e"

@(private = "file") PARTITION_SIZE :: [2]int{1000, 700}
@(private = "file") THIRD_PARTY :: "http://localhost:%d/site/partition/t.html"
@(private = "file") TOP_PAGE :: "http://127.0.0.1:%d/site/partition/top.html?t=%s"
// The port of a second origin of the same site (tools/testserver/ports.go).
@(private = "file") SECOND_ORIGIN_OFFSET :: 2
// A point in the frame: its button fills it.
@(private = "file") IN_THE_FRAME :: e2e.Point{200, 100}

// What the embedded third party answers (its frame has loaded by then).
@(private = "file") ask :: proc(m: string) -> string { return fmt.tprintf("loaded.then(() => ask(%s))", m) }
// What the page of the third party answers as a tab of its own.
@(private = "file") run :: proc(m: string) -> string { return fmt.tprintf("run(%s)", m) }

@(private = "file")
open_tab :: proc(s: ^e2e.Session, address: string) -> int {
	s.tab = e2e.new_tab(s, address)
	e2e.wait_load(s)
	return s.tab
}

@(test)
storage_is_partitioned_by_top_level_site :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	third := fmt.tprintf(THIRD_PARTY, server.base)
	s := e2e.start(t, {size = PARTITION_SIZE, url = third})

	// T as a tab of its own: its first-party data
	tab_t := e2e.targets(s).tabs[0].id
	s.tab = tab_t
	e2e.expect_eval(s, run(`{op: "write", v: "first"}`), "written", "the third party writes its first-party data")

	tab_a := open_tab(s, fmt.tprintf(TOP_PAGE, server.base, third))
	e2e.expect_eval(s, ask(`{op: "read"}`), "none|none|none|none", "embedded in site A, it sees none of its first-party data (localStorage, sessionStorage, cookie, Cache API)")
	e2e.eval(s, ask(`{op: "write", v: "a"}`), await = true)
	e2e.expect_eval(s, ask(`{op: "read"}`), "a|a|a|a", "two partitions: under A")
	s.tab = tab_t
	e2e.expect_eval(s, run(`{op: "read"}`), "first|first|first|first", "two partitions: first-party")

	tab_a2 := open_tab(s, fmt.tprintf(TOP_PAGE, server.base + SECOND_ORIGIN_OFFSET, third))
	e2e.expect_eval(s, ask(`{op: "read"}`), "a|none|a|a", "under another origin of site A it finds the same partition (sessionStorage is per tab)")
	s.tab = tab_a
	e2e.expect_eval(s, ask(`{op: "hdr"}`), "none v=a", "a credentialed request of the embedded third party: Sec-Fetch-Storage-Access none and its partition's cookie")
	s.tab = tab_t
	e2e.expect_eval(s, run(`{op: "hdr"}`), "- v=first", "first-party: no Sec-Fetch-Storage-Access, its own cookie")

	// the first-party tab posts before the copy in the partition: had it been heard, it would come first
	s.tab = tab_a
	e2e.expect_eval(s, ask(`{op: "listen"}`), "listening", "BroadcastChannel: the third party under A listens")
	s.tab = tab_t
	e2e.eval(s, run(`{op: "post", v: "from-first"}`), await = true)
	s.tab = tab_a2
	e2e.eval(s, ask(`{op: "post", v: "from-a2"}`), await = true)
	s.tab = tab_a
	e2e.expect_eval(s, `(async () => { for (;;) { const g = await ask({op: "got"}); if (g !== "nothing") return g; await new Promise((ok) => setTimeout(ok)); } })()`, "from-a2", "BroadcastChannel: the third party under A hears its copy in the same partition, not its first-party tab")

	e2e.expect_eval(s, ask(`{op: "sw"}`), "1", "a service worker registered by the third party under A is its partition's")
	s.tab = tab_t
	e2e.expect_eval(s, run(`{op: "swcount"}`), "0", "... not first-party")
	s.tab = tab_a2
	e2e.expect_eval(s, ask(`{op: "swcount"}`), "1", "... and found under another origin of site A")

	s.tab = tab_a
	e2e.expect_eval(s, ask(`{op: "request"}`), "refused NotAllowedError", "requestStorageAccess() without a click in the frame: NotAllowedError")
	e2e.expect_eval(s, ask(`{op: "has"}`), "false", "hasStorageAccess() is false in a partition")
	e2e.pref_set(s, "browser.dialogs.test_answer", "allow")
	e2e.activate_tab(s, tab_a)
	e2e.click_at(s, IN_THE_FRAME)
	e2e.wait_js(s, "said.length > 0")
	e2e.expect_eval(s, `said.join(",")`, "granted", "a click in the frame, then requestStorageAccess(): granted (the prompt allowed)")
	e2e.pref_set(s, "browser.dialogs.test_answer", "")
	e2e.expect_eval(s, ask(`{op: "has"}`), "true", "with storage access, hasStorageAccess() is true")
	e2e.expect_eval(s, ask(`{op: "read"}`), "first|none|first|first", "with storage access the third party under A uses its first-party data (sessionStorage stays the tab's)")
	e2e.expect_eval(s, ask(`{op: "hdr"}`), "active v=first", "its requests say Sec-Fetch-Storage-Access: active and carry its first-party cookie")
	s.tab = tab_a2
	e2e.expect_eval(s, ask(`{op: "hdr"}`), "inactive v=a", "another document of the pair: inactive until it asks")
	e2e.expect_eval(s, ask(`{op: "request"}`), "granted", "... then granted without a gesture")
}
