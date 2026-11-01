package e2e_scenarios

// The channel on the browser's check build (build.bat check: every allocation tracked): a session that touches every part of it, then a normal exit, must end with nothing allocated.
// (The scenarios about pages run the same way in build\e2e_test_check.exe: what is checked here is what only the channel holds.)

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:e2e"
import "wb:remote/api"

// A session of this build takes minutes under load.
@(private = "file") SESSION_LIMIT :: 10 * time.Minute
@(private = "file") SUBSCRIBE :: `{"id":1,"method":"Remote.subscribe"}`
@(private = "file") WAIT_NEVER :: `{"id":9,"method":"Wren.wait","params":{"for":"selector","selector":"#never","timeout":20000}}`
@(private = "file") CLEAN_REPORT :: " 0 leaked block(s), 0 byte(s); 0 bad free(s)"
@(private = "file") REPORT_FILE :: "memtrack.txt"
@(private = "file") SHORT_WAIT :: 200 * time.Millisecond
@(private = "file") DRAG_FROM := api.Point{10, 300}
@(private = "file") DRAG_TO := api.Point{200, 320}
@(private = "file") NOTCHES_UP :: -3
@(private = "file") SMALLER_WINDOW := [2]int{700, 500}

@(test)
a_driven_session_on_the_check_build_leaves_nothing_allocated :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, SESSION_LIMIT)
	server := e2e.test_server(t)
	dir := e2e.temp_folder(t)
	profile := e2e.temp_profile(t)
	p := e2e.launch(t, {exe = e2e.build_path("wren_check", ".exe"), profile = profile, start = {env = {"WREN_MEMTRACK_FAIL=1"}}})
	testing.set_fail_timeout(t, SESSION_LIMIT)
	s := p.s

	listener: api.Conn
	testing.expect(t, api.connect(&listener, p.wren.name, api.START_WAIT_MS))
	testing.expect_value(t, api.write_line(&listener, SUBSCRIBE, api.CALL_WAIT_MS), api.Error.None)

	api.navigate(s, e2e.url(server, "/site/remote/fixture.htm"))
	api.eval(s, "[1,2,3].map(x => x * 2)")
	stop := s.on_failure
	s.on_failure = nil
	_, thrown := api.eval(s, `throw new Error("x")`)
	testing.expect_value(t, thrown, api.Error.Script)
	missing := api.wait_selector(s, "#never", deadline = SHORT_WAIT)
	testing.expect_value(t, missing, api.Error.Timeout)
	s.on_failure = stop
	api.eval(s, `new Promise(r => setTimeout(() => r("later"), 50))`, await = true)
	api.click(s, "#go")
	api.click(s, "#far")
	api.click(s, "#name")
	api.type_text(s, "abc")
	api.key(s, "Ctrl+A Backspace")
	api.drag(s, DRAG_FROM, DRAG_TO)
	api.scroll(s, NOTCHES_UP)
	api.wait_idle(s)
	api.wait_stable(s)
	api.wait_quiet(s)
	api.wait_js(s, "window.clicks > 0")
	api.screenshot(s, fmt.tprintf("%s/a.png", dir))
	api.screenshot(s, fmt.tprintf("%s/b.png", dir), {target = .Selector, selector = "#box", scale = 0.5})
	api.screenshot(s, fmt.tprintf("%s/c.png", dir), {target = .Page})
	api.snapshot(s, fmt.tprintf("%s/snap", dir))
	api.record_start(s)
	api.click_at(s, DRAG_TO)
	recording, count, _ := api.record_stop(s)
	testing.expect(t, count > 0, "the recording has the click")
	parsed, _ := json.parse(transmute([]byte)recording, json.Specification.JSON, true, context.temp_allocator)
	events, _ := json.marshal(parsed.(json.Object)["events"], {}, context.temp_allocator)
	api.replay(s, string(events))
	api.outer_html(s, "#box")
	api.computed_style(s, "#box", {"width"})
	api.query_all(s, "div")
	api.new_tab(s, "about:blank")
	api.open_devtools(s, "elements")
	api.console(s)
	api.network(s)
	api.stats(s)
	api.commands(s)
	api.pref_set(s, "browser.scroll.key_line_px", "45")
	api.set_window(s, {size = SMALLER_WINDOW})

	// a client that vanishes in the middle of a wait
	testing.expect_value(t, api.write_line(&listener, WAIT_NEVER, api.CALL_WAIT_MS), api.Error.None)
	api.wait_until(s, proc(s: ^api.Session) -> bool { st, _ := api.stats(s); return st.pending_ops >= 1 }, "the wait to be registered")
	api.disconnect(&listener)
	api.reset(s)

	reset_puts_back_all_it_names(t, p, server)
	checkpoints_restore_what_they_saved(t, p, server)

	testing.expect_value(t, e2e.quit(p), 0)
	report := e2e.read_text(fmt.tprintf("%s/%s", profile, REPORT_FILE))
	testing.expectf(t, strings.contains(report, CLEAN_REPORT), "the tracker reports nothing left: %s", report)
}
