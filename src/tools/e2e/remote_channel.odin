#+build windows
package e2e_scenarios

// The channel itself, in another process, over wb:remote/api: off at no cost when it is not asked for, its protocol as a client that speaks it badly writes it, vanishing clients and
// oversized messages, who may connect, a second Wren and a taken name, closing with a client connected, what `wren ctl run` does in one call.

import "core:fmt"
import "core:os"
import "core:strings"
import win "core:sys/windows"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:e2e"
import "wb:remote"
import "wb:remote/api"

foreign import advapi32 "system:Advapi32.lib"
@(default_calling_convention = "system", private = "file")
foreign advapi32 {
	GetKernelObjectSecurity :: proc(h: win.HANDLE, info: win.DWORD, sd: rawptr, size: win.DWORD, need: ^win.DWORD) -> win.BOOL ---
	GetSecurityDescriptorDacl :: proc(sd: rawptr, present: ^win.BOOL, acl: ^rawptr, defaulted: ^win.BOOL) -> win.BOOL ---
	GetAclInformation :: proc(acl: rawptr, info: rawptr, size: win.DWORD, class: i32) -> win.BOOL ---
	GetAce :: proc(acl: rawptr, index: win.DWORD, ace: ^rawptr) -> win.BOOL ---
	OpenProcessToken :: proc(process: win.HANDLE, access: win.DWORD, token: ^win.HANDLE) -> win.BOOL ---
	GetTokenInformation :: proc(token: win.HANDLE, class: i32, info: rawptr, size: win.DWORD, need: ^win.DWORD) -> win.BOOL ---
	EqualSid :: proc(a, b: rawptr) -> win.BOOL ---
}

@(private = "file") FIXTURE :: "/site/remote/fixture.htm"
@(private = "file") BOX_W :: 200   // its #box
@(private = "file") BOX_H :: 100
@(private = "file") HTTP_OK :: 200
// The window of `wren ctl run`.
@(private = "file") RUN_W :: 1000
@(private = "file") RUN_H :: 700
// Quiet: a second, using less than this of the processors (a Wren with no channel to ask, watched from outside).
@(private = "file") QUIET_WINDOW :: 1 * time.Second
@(private = "file") QUIET_CPU_MS :: 25.0
// What an idle Wren costs once settled (-Perf only: it depends on the machine; that it draws no frame is checked everywhere, frames_at_rest.odin): nothing of its own, what is left
// is a driver's thread that ticks on its own. The clock of a process's time goes by 15.6 ms; twice that over the period.
@(private = "file") IDLE_MEASURE :: 3 * time.Second
@(private = "file") IDLE_CPU_MS :: 31.3
@(private = "file") IDLE_FRAMES :: 0
// What settling takes: the status bar's numbers after the last frame, and it stops the wait when no frame has come for this long.
@(private = "file") IDLE_SETTLED :: 2 * time.Second
// More than browser.remote.max_message_bytes, by default 8 MiB.
@(private = "file") GIANT_REQUEST_BYTES :: 9 << 20
// Clients that connect and go at once: the first such ended the accept thread for good, once.
@(private = "file") CONNECT_AND_GO :: 5000
@(private = "file") WAIT_NEVER_ANSWERED :: `{"id":9,"method":"Wren.wait","params":{"for":"selector","selector":"#never","timeout":20000}}`
@(private = "file") LINE_PX :: "browser.scroll.key_line_px"
@(private = "file") SHORT_WAIT :: 300 * time.Millisecond
// `wren ctl`'s exit code when no Wren answers.
@(private = "file") EXIT_NO_SERVER :: 3
// GetKernelObjectSecurity: the access list; GetTokenInformation: TokenUser; GetAclInformation: AclSizeInformation.
@(private = "file") DACL_SECURITY_INFORMATION :: 4
@(private = "file") TOKEN_USER_CLASS :: 1
@(private = "file") ACL_SIZE_CLASS :: 2
@(private = "file") TOKEN_QUERY :: 8
// The header of an ACE, then its mask: the SID follows.
@(private = "file") ACE_SID_OFFSET :: 8

// The channel of a process that is not ours to name: a line of the protocol and its answer.
@(private = "file")
exchange :: proc(t: ^testing.T, c: ^api.Conn, line: string, loc := #caller_location) -> string {
	testing.expect_value(t, api.write_line(c, line, api.CALL_WAIT_MS), api.Error.None, loc = loc)
	answer, e := api.read_line(c, time.tick_add(time.tick_now(), api.CALL_WAIT_MS * time.Millisecond))
	testing.expect_value(t, e, api.Error.None, loc = loc)
	return answer
}

// A Wren without --remote listens on nothing and writes no remote.json; idle, it costs nothing.
@(test)
without_the_flag_there_is_no_channel_and_no_cost :: proc(t: ^testing.T) {
	profile := e2e.temp_profile(t)
	plain := e2e.program(t, {e2e.wren_exe(), "--profile", profile, "--pref", "blocker.update.enabled=false", "--pref", "blocker.welcome_toast=false", "--no-single-instance", "--headless", "about:blank"})
	// it has settled (nothing to ask it): its time on the processors moves by little in a second
	last := api.process_cpu_ms(&plain.process)
	for {
		time.sleep(QUIET_WINDOW)
		now := api.process_cpu_ms(&plain.process)
		if now - last < QUIET_CPU_MS { break }
		last = now
	}
	testing.expect(t, !os.exists(fmt.tprintf("%s/remote.json", profile)), "no remote.json without --remote")
	r := e2e.run(t, {e2e.wren_exe(), "ctl", "ping", "--profile", profile, "--timeout", "300"})
	testing.expectf(t, r.code == EXIT_NO_SERVER, "ctl finds no server: %d, %s", r.code, r.err)

	if base.perf_skip("idle Wren: CPU time and frames drawn") { return }
	p := e2e.launch(t, {hidden = true})
	api.wait_quiet(p.s)
	// settled: no frame for a while, whatever a first second still had to do
	before, _ := api.stats(p.s)
	for settled := time.tick_now(); time.tick_since(settled) < IDLE_SETTLED; {
		time.sleep(SHORT_WAIT)
		st, _ := api.stats(p.s)
		if st.frames_drawn != before.frames_drawn { before, settled = st, time.tick_now() }
	}
	before, _ = api.stats(p.s)
	plain0, driven0 := api.process_cpu_ms(&plain.process), api.process_cpu_ms(&p.wren.process)
	time.sleep(IDLE_MEASURE)
	plain1, driven1 := api.process_cpu_ms(&plain.process), api.process_cpu_ms(&p.wren.process)
	after, _ := api.stats(p.s)
	testing.expectf(t, plain1 - plain0 < IDLE_CPU_MS, "idle without the channel: %.0f ms of CPU", plain1 - plain0)
	testing.expectf(t, driven1 - driven0 < IDLE_CPU_MS, "idle with the channel: %.0f ms of CPU", driven1 - driven0)
	testing.expectf(t, after.frames_drawn - before.frames_drawn <= IDLE_FRAMES, "idle with the channel: %d frames", after.frames_drawn - before.frames_drawn)
}

// What a client reads: the protocol's answers, the errors of calls; the numbers of the process.
@(test)
what_a_client_reads_over_the_channel :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	profile := e2e.temp_profile(t)
	p := e2e.launch(t, {profile = profile})
	s := p.s
	testing.expect(t, os.exists(fmt.tprintf("%s/remote.json", profile)), "remote.json is written in the profile")
	who, _ := api.ping(s)
	testing.expect_value(t, who.pid, p.wren.pid)
	api.navigate(s, e2e.url(server, FIXTURE))

	c: api.Conn
	testing.expect(t, api.connect(&c, p.wren.name, api.START_WAIT_MS))
	defer api.disconnect(&c)
	testing.expect(t, strings.has_prefix(exchange(t, &c, `{"id":"a","method":"Remote.ping"}`), `{"id":"a","result":{`), "the answer keeps a string id")
	testing.expect(t, strings.contains(exchange(t, &c, `{"id":2,"method":"No.such"}`), `"code":-32601`), "an unknown method is -32601")
	testing.expect(t, strings.contains(exchange(t, &c, "not json"), `"code":-32700`), "bad JSON is -32700")

	stop := s.on_failure
	s.on_failure = nil
	_, thrown := api.eval(s, `throw new Error("boom")`)
	testing.expectf(t, thrown == .Script && strings.contains(api.last_failure().message, "boom"), "a script's exception, with its message: %v, %q", thrown, api.last_failure().message)
	missing := api.wait_selector(s, "#nothing-here", deadline = SHORT_WAIT)
	testing.expect_value(t, missing, api.Error.Timeout)
	s.on_failure = stop

	box, _ := api.box_model(s, "#box")
	testing.expectf(t, box.box.w == BOX_W && box.box.h == BOX_H && box.visible, "the box of an element: %v", box)
	found, _ := api.query_all(s, "#box", 1)
	testing.expectf(t, found.count == 1 && len(found.nodes) == 1 && found.nodes[0].has_box && found.nodes[0].box.w == BOX_W && strings.has_prefix(found.nodes[0].outer_html, "<div"), "what a query finds: %v", found)
	style, _ := api.computed_style(s, "#box", {"width"})
	testing.expect_value(t, api.style_of(style, "width"), "200px")
	list, _ := api.commands(s)
	has_new_tab := false
	for command in list { if command.name == "tab.new" { has_new_tab = command.enabled && command.category != "" } }
	testing.expect(t, has_new_tab, "the commands of the registry are listed, with what they are")
	net, _ := api.network(s)
	has_page := false
	for q in net.requests { if strings.contains(q.url, "fixture.htm") { has_page = q.status == HTTP_OK && q.has_ms && q.destination == "document" } }
	testing.expect(t, has_page, "the network log has the document")
	prefs, _ := api.pref_list(s, "browser.scroll.key_line_px")
	testing.expectf(t, len(prefs) == 1 && prefs[0].source != "" && prefs[0].default_text != "", "a preference and all that is known of it: %v", prefs)

	st, _ := api.stats(s)
	testing.expectf(t, st.pid == who.pid && st.cpu_time_ms > 0 && st.threads > 1 && st.handles > 0 && st.uptime_ms > 0 && st.working_set_bytes > 0, "the numbers of the process: %v", st)
	testing.expect_value(t, api.wait_quiet(s), api.Error.None)

	// what a process is doing, read from outside and named with its PDB: what `quit` prints for a Wren that does not end
	stacks, read := api.process_stacks(who.pid)
	testing.expectf(t, read && strings.contains(stacks, fmt.tprintf("process %d, running", who.pid)) && strings.contains(stacks, "browser::"), "the stacks name the frames of the browser: %q", stacks)
	testing.expect_value(t, e2e.quit(p), 0)
	testing.expect(t, !os.exists(fmt.tprintf("%s/remote.json", profile)), "remote.json goes with the channel")
}

// A client that vanishes in the middle of a wait: its wait goes with it.
@(test)
a_client_that_vanishes_takes_its_wait_along :: proc(t: ^testing.T) {
	p := e2e.launch(t)
	c: api.Conn
	testing.expect(t, api.connect(&c, p.wren.name, api.START_WAIT_MS))
	testing.expect_value(t, api.write_line(&c, WAIT_NEVER_ANSWERED, api.CALL_WAIT_MS), api.Error.None)
	api.wait_until(p.s, proc(s: ^api.Session) -> bool { st, _ := api.stats(s); return st.pending_ops >= 1 }, "the wait to be registered")
	api.disconnect(&c)
	api.wait_until(p.s, proc(s: ^api.Session) -> bool { st, _ := api.stats(s); return st.pending_ops == 0 }, "the wait of the client that went to be dropped")
	testing.expect_value(t, e2e.quit(p), 0)
}

// Too large a line: refused, the connection ends, the server goes on. What the client gets is the error, or the end of the pipe when the server has closed while it wrote.
@(test)
an_oversized_message_ends_its_connection_only :: proc(t: ^testing.T) {
	p := e2e.launch(t)
	c: api.Conn
	testing.expect(t, api.connect(&c, p.wren.name, api.START_WAIT_MS))
	defer api.disconnect(&c)
	giant := strings.repeat("A", GIANT_REQUEST_BYTES, context.temp_allocator)
	wrote := api.write_line(&c, giant, api.CALL_WAIT_MS)
	reply, read := api.read_line(&c, time.tick_add(time.tick_now(), api.CALL_WAIT_MS * time.Millisecond))
	testing.expectf(t, strings.contains(reply, "max_message_bytes") || wrote == .Closed || read == .Closed, "it is refused: %v, %v, %q", wrote, read, reply)
	if read == .None { _, read = api.read_line(&c, time.tick_add(time.tick_now(), api.CALL_WAIT_MS * time.Millisecond)) }
	testing.expect_value(t, read, api.Error.Closed)
	who, _ := api.ping(p.s)
	testing.expect_value(t, who.pid, p.wren.pid)
	testing.expect_value(t, e2e.quit(p), 0)
}

// Clients that connect and go at once (a security query, a probe): ConnectNamedPipe then fails with ERROR_NO_DATA, which once ended the accept thread for good: the pipe vanished while
// the process lived. And who may connect: this user only.
@(test)
the_pipe_survives_clients_that_go_at_once_and_is_this_users_only :: proc(t: ^testing.T) {
	p := e2e.launch(t)
	connected := 0
	for i in 0 ..< CONNECT_AND_GO {
		c: api.Conn
		// (the first waits for the instance the server makes after the one the session holds: under load its accept thread may not have run within all the others)
		if api.connect(&c, p.wren.name, i == 0 ? api.START_WAIT_MS : 0) { connected += 1; api.disconnect(&c) }
		free_all(context.temp_allocator)
	}
	testing.expect(t, connected > 0, "they connected")
	// (a new connection on the session's name: the one it holds was there before them)
	fresh := api.Session{name = p.wren.name, connect_wait_ms = api.START_WAIT_MS}
	who, e := api.ping(&fresh)
	testing.expectf(t, e == .None && who.pid == p.wren.pid, "the server answers a new client after them: %v", e)
	api.close_session(&fresh)
	testing.expect(t, only_this_user_is_let_in(t, p.wren.name), "the pipe lets in this user only")
	testing.expect_value(t, e2e.quit(p), 0)
}

@(private = "file")
only_this_user_is_let_in :: proc(t: ^testing.T, name: string) -> bool {
	path := win.utf8_to_wstring(remote.pipe_path(name), context.temp_allocator)
	h: win.HANDLE
	// (the server makes the next instance of its pipe a moment after it ended a connection: it may not exist for an instant)
	Open :: struct { path: win.LPCWSTR, h: ^win.HANDLE }
	e2e.wait_for(t, Open{path, &h}, proc(o: Open) -> bool {
		o.h^ = win.CreateFileW(o.path, win.READ_CONTROL, 0, nil, win.OPEN_EXISTING, 0, nil)
		return o.h^ != win.INVALID_HANDLE_VALUE
	}, "the pipe to take a client again")
	defer win.CloseHandle(h)
	descriptor: [8192]byte
	need: win.DWORD
	if !GetKernelObjectSecurity(h, DACL_SECURITY_INFORMATION, &descriptor, size_of(descriptor), &need) { return false }
	present, defaulted: win.BOOL
	acl: rawptr
	if !GetSecurityDescriptorDacl(&descriptor, &present, &acl, &defaulted) || !present { return false }
	Acl_Size :: struct { count, used, free: win.DWORD }
	size: Acl_Size
	if !GetAclInformation(acl, &size, size_of(size), ACL_SIZE_CLASS) || size.count == 0 { return false }
	token: win.HANDLE
	if !OpenProcessToken(win.GetCurrentProcess(), TOKEN_QUERY, &token) { return false }
	defer win.CloseHandle(token)
	user: [256]byte
	if !GetTokenInformation(token, TOKEN_USER_CLASS, &user, size_of(user), &need) { return false }
	me := (^rawptr)(&user)^
	for i in 0 ..< size.count {
		ace: rawptr
		if !GetAce(acl, i, &ace) { return false }
		if !EqualSid(rawptr(uintptr(ace) + ACE_SID_OFFSET), me) { return false }
	}
	return true
}

// A value given with --pref: set is refused, an override changes that layer, a reset puts the value of the start back.
@(test)
a_preference_of_the_command_line_decides_for_the_run :: proc(t: ^testing.T) {
	p := e2e.launch(t, {prefs = {fmt.tprintf("%s=33", LINE_PX)}})
	s := p.s
	got, _ := api.pref_get(s, LINE_PX)
	testing.expect_value(t, got, "33")
	stop := s.on_failure
	s.on_failure = nil
	_, refused := api.pref_set(s, LINE_PX, "44")
	testing.expectf(t, refused != .None && strings.contains(api.last_failure().message, "command line"), "set is refused: %v, %q", refused, api.last_failure().message)
	s.on_failure = stop
	got, _ = api.pref_set(s, LINE_PX, "44", override = true)
	testing.expect_value(t, got, "44")
	api.reset(s)
	got, _ = api.pref_get(s, LINE_PX)
	testing.expect_value(t, got, "33")
	api.pref_set(s, LINE_PX, "55", override = true)
	api.pref_reset(s, LINE_PX)
	got, _ = api.pref_get(s, LINE_PX)
	testing.expect_value(t, got, "33")
	testing.expect_value(t, e2e.quit(p), 0)
}

// Two instances answer separately; a name taken by another Wren is reported, and the first goes on under it.
@(test)
two_wrens_have_their_own_names_and_a_taken_name_is_an_error :: proc(t: ^testing.T) {
	first := e2e.launch(t)
	second := e2e.launch(t)
	a, _ := api.ping(first.s)
	b, _ := api.ping(second.s)
	testing.expect(t, a.pid != b.pid, "two instances answer separately")
	e2e.quit(second)

	third := e2e.launch_begin(t, {name = first.wren.name, start = {stderr = {pipe = true}, stdout = {pipe = true}}})
	Look :: struct { p: ^api.Process, text: ^strings.Builder }
	said := strings.builder_make(context.temp_allocator)
	e2e.wait_for(t, Look{&third.wren.process, &said}, proc(l: Look) -> bool {
		_, err := api.process_output(l.p)
		strings.write_string(l.text, err)
		return strings.contains(strings.to_string(l.text^), "taken")
	}, "the error of a name taken")
	again, _ := api.ping(first.s)
	testing.expect_value(t, again.pid, a.pid)
	e2e.kill(third)
	testing.expect_value(t, e2e.quit(first), 0)
}

// Closing with a client connected: the exit code it was told, and the pipe gone.
@(test)
quit_with_a_client_connected :: proc(t: ^testing.T) {
	profile := e2e.temp_profile(t)
	p := e2e.launch(t, {profile = profile})
	name := strings.clone(p.wren.name, context.temp_allocator)
	c: api.Conn
	testing.expect(t, api.connect(&c, name, api.START_WAIT_MS))
	defer api.disconnect(&c)
	EXIT_CODE :: 7   // (one nothing else ends with)
	testing.expect_value(t, e2e.quit(p, EXIT_CODE), EXIT_CODE)
	testing.expect(t, !os.exists(fmt.tprintf("%s/remote.json", profile)), "remote.json is gone")
	gone: api.Conn
	if api.connect(&gone, name, 0) { api.disconnect(&gone); testing.fail_now(t, "the pipe is gone after quit") }
}

// The one-call form of the command line: start, load, wait, script, capture, close. (The command line itself: what applications run.)
@(test)
wren_ctl_run_does_it_all_in_one_call :: proc(t: ^testing.T) {
	url := e2e.url(e2e.test_server(t), FIXTURE)
	out := fmt.tprintf("%s/run.png", e2e.temp_folder(t))
	r := e2e.run(t, {e2e.wren_exe(), "ctl", "run", "--headless", "--pref", "blocker.update.enabled=false", fmt.tprintf("--size=%dx%d", RUN_W, RUN_H), "--wait", "idle", "--shot", out, "--eval", "document.title", url})
	testing.expectf(t, r.code == 0 && strings.contains(r.out, "Remote fixture"), "loads, evaluates: %d, %q, %q", r.code, r.out, r.err)
	picture, read := api.load_image(out)
	testing.expectf(t, read && picture.width == RUN_W && picture.height == RUN_H, "captures, at the size asked for: %dx%d", picture.width, picture.height)
	red := 0
	for y in 0 ..< picture.height { for x in 0 ..< picture.width { if near(e2e.pixel(picture, x, y), {255, 0, 0, 255}) { red += 1 } } }
	testing.expectf(t, red > 0, "the page's red box is in the picture")
}
