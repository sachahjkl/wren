package embed

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import config "toolkit:config"
import "wb:base"
import "wb:dom"
import "wb:host"
import "wb:js"
import "wb:page"
import "wb:testenv"

@(test)
process_share_lifecycle :: proc(t: ^testing.T) {
	State :: struct {
		begins: int,
		ends:   int,
		fail:   bool,
	}
	on_begin :: proc(user: rawptr) -> bool {
		s := (^State)(user)
		s.begins += 1
		return !s.fail
	}
	on_end :: proc(user: rawptr) {
		s := (^State)(user)
		s.ends += 1
	}

	share: Process_Share
	st := State{fail = true}
	hooks := Process_Hooks{on_begin = on_begin, on_end = on_end, user = &st}

	testing.expect(t, !process_share_join(&share, hooks), "failed on_begin returns false")
	testing.expect_value(t, process_share_users(&share), 0)
	testing.expect_value(t, st.begins, 1)
	testing.expect_value(t, st.ends, 0)

	st.fail = false
	testing.expect(t, process_share_join(&share, hooks), "first join succeeds")
	testing.expect_value(t, process_share_users(&share), 1)
	testing.expect_value(t, st.begins, 2)

	testing.expect(t, process_share_join(&share, hooks), "second join reuses runtime")
	testing.expect_value(t, process_share_users(&share), 2)
	testing.expect_value(t, st.begins, 2)

	process_share_leave(&share, hooks)
	testing.expect_value(t, process_share_users(&share), 1)
	testing.expect_value(t, st.ends, 0)

	process_share_leave(&share, hooks)
	testing.expect_value(t, process_share_users(&share), 0)
	testing.expect_value(t, st.ends, 1)

	// Concurrent threads joining and leaving one Process_Share.
	Concurrent :: struct {
		share:  ^Process_Share,
		begins: int,
		ends:   int,
	}
	c_begin :: proc(user: rawptr) -> bool {
		c := (^Concurrent)(user)
		sync.atomic_add(&c.begins, 1)
		return true
	}
	c_end :: proc(user: rawptr) {
		c := (^Concurrent)(user)
		sync.atomic_add(&c.ends, 1)
	}
	conc := Concurrent{share = &share}
	workers: [4]^host.Thread
	for i in 0 ..< len(workers) {
		workers[i] = host.thread_start(proc(data: rawptr) {
			c := (^Concurrent)(data)
			h := Process_Hooks{on_begin = c_begin, on_end = c_end, user = c}
			for _ in 0 ..< 8 {
				if process_share_join(c.share, h) {
					process_share_leave(c.share, h)
				}
			}
		}, &conc)
	}
	for th in workers { host.thread_join(th) }
	testing.expect_value(t, process_share_users(&share), 0)
	testing.expect(t, sync.atomic_load(&conc.begins) >= 1, "at least one begin ran")
	testing.expect_value(t, sync.atomic_load(&conc.begins), sync.atomic_load(&conc.ends))
}

@(test)
world_lifecycle_and_js :: proc(t: ^testing.T) {
	// Wasm host calls and page internals allocate via base.process_allocator(); bind this test to it
	// so testenv.mem_check verifies zero process-wide leaks at the end.
	context.allocator = base.process_allocator()

	// 1. Network-only world via world_make / world_free with prefs and in-memory HTTP cache.
	{
		prefs := config.prefs_make()
		defer config.prefs_destroy(&prefs)
		register_prefs(&prefs)

		w := world_make({prefs = &prefs, network_only = true, http_cache = true, blocking_threads = 1})
		testing.expect(t, w != nil, "network-only world_make succeeds")
		if w != nil {
			testing.expect(t, .Loop in w.made && .Client in w.made && .Loader in w.made && .Http_Cache in w.made, "network stages active")
			testing.expect(t, .Runtime not_in w.made && .Pages_Bound not_in w.made, "page stages omitted in network_only mode")
			testing.expect(t, world_storage(w) == nil, "no storage in network_only mode")
			world_free(w)
		}
	}

	// 2. Full page world: load HTML, run inline script + js_run, verify DOM mutation and console output.
	{
		Log_Capture :: struct {
			lines: [dynamic]string,
		}
		on_console :: proc(user: rawptr, level: page.Log_Level, message: string) {
			cap := (^Log_Capture)(user)
			append(&cap.lines, strings.clone(message))
		}

		w := world_make({blocking_threads = 1})
		testing.expect(t, w != nil, "full page world_make succeeds")
		if w != nil {
			cap: Log_Capture
			p := page.page_create(&w.loop, &w.loader, &w.settings, w.process, "http://127.0.0.1:8765/embed.html", on_console, &cap)
			testing.expect(t, p != nil, "page_create succeeds")
			html := "<!doctype html><html><body><div id='out'>before</div><script>document.getElementById('out').textContent = 'after:' + (20 + 22); console.log('embed-ok');</script></body></html>"
			page.load_html(p, transmute([]byte)html)
			page.scripts_start(p)

			out_ids := dom.ids_all(p.doc, "out")
			testing.expect(t, len(out_ids) == 1, "found #out element")
			if len(out_ids) == 1 {
				testing.expect_value(t, dom.text_content(p.doc, out_ids[0], context.temp_allocator), "after:42")
			}
			testing.expect(t, len(cap.lines) > 0 && cap.lines[0] == "embed-ok", "console output captured")

			st := page.js_run(p, transmute([]byte)string("document.getElementById('out').textContent = 'ran'"), "eval.js")
			testing.expect_value(t, st, js.Eval_Status.Ok)
			if len(out_ids) == 1 {
				testing.expect_value(t, dom.text_content(p.doc, out_ids[0], context.temp_allocator), "ran")
			}

			page.page_close(p)
			for l in cap.lines { delete(l) }
			delete(cap.lines)
			world_free(w)
			testing.expect(t, page.the_pages == nil, "page.the_pages unbound after world_free")
		}
	}

	// 3. Upgrade network_only -> pages + lazy storage + reset/clear settings.
	{
		storage_dir := fmt.tprintf("build/embed_test_storage_%d", os.get_pid())
		testenv.remove_tree(storage_dir)
		defer testenv.remove_tree(storage_dir)

		w: World
		testing.expect(t, world_init(&w, {network_only = true, blocking_threads = 1}), "network_only world_init succeeds")
		testing.expect(t, world_enable_pages(&w, {configure_wasm = true, js_cache_bytes = 4 << 20}), "world_enable_pages succeeds")
		world_enable_storage(&w, storage_dir)
		testing.expect(t, world_has_storage(&w) && world_storage(&w) != nil, "storage enabled")

		p := page.page_create(&w.loop, &w.loader, &w.settings, w.process, "http://127.0.0.1:8765/storage.html", proc(user: rawptr, level: page.Log_Level, message: string) {})
		page.set_embedder(p, {storage = world_storage(&w), tab_key = "embed-test"})
		page.load_html(p, transmute([]byte)string("<!doctype html><html><body><div id='v'></div></body></html>"))
		page.js_run(p, transmute([]byte)string("localStorage.setItem('k', 'stored'); document.getElementById('v').textContent = localStorage.getItem('k');"), "storage.js")
		v_ids := dom.ids_all(p.doc, "v")
		testing.expect(t, len(v_ids) == 1, "found #v element")
		if len(v_ids) == 1 {
			testing.expect_value(t, dom.text_content(p.doc, v_ids[0], context.temp_allocator), "stored")
		}
		page.page_close(p)

		world_clear_settings(&w)
		world_reset_settings(&w)
		world_destroy(&w)
		testing.expect(t, w.made == {}, "all stages cleared after world_destroy")
	}

	// 4. Two Worlds sharing one Process_Share with custom Process_Hooks.
	{
		Hook_Counts :: struct { begins, ends: int }
		on_begin :: proc(user: rawptr) -> bool { (^Hook_Counts)(user).begins += 1; return true }
		on_end :: proc(user: rawptr) { (^Hook_Counts)(user).ends += 1 }

		share: Process_Share
		counts: Hook_Counts
		hooks := Process_Hooks{on_begin = on_begin, on_end = on_end, user = &counts}

		w1, w2: World
		testing.expect(t, world_init(&w1, {blocking_threads = 1, process_share = &share, process_hooks = hooks}), "w1 init")
		testing.expect_value(t, process_share_users(&share), 1)
		testing.expect_value(t, counts.begins, 1)

		testing.expect(t, world_init(&w2, {blocking_threads = 1, process_share = &share, process_hooks = hooks}), "w2 init")
		testing.expect_value(t, process_share_users(&share), 2)
		testing.expect_value(t, counts.begins, 1)

		world_destroy(&w1)
		testing.expect_value(t, process_share_users(&share), 1)
		testing.expect_value(t, counts.ends, 0)

		world_destroy(&w2)
		testing.expect_value(t, process_share_users(&share), 0)
		testing.expect_value(t, counts.ends, 1)
	}

	free_all(context.temp_allocator)
	testing.expect_value(t, testenv.mem_check("embed"), 0)
}
