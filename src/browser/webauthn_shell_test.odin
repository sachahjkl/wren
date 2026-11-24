package browser

import "core:sync"
import "core:testing"
import "core:time"
import "toolkit:platform"
import "toolkit:ui"
import "wb:base"
import "wb:host"
import "wb:webauthn"

// Security-key prompts run on a worker thread where thread-local the_app is nil. webauthn_shell_init must wake the
// UI loop using a process-safe App pointer so two-passkey account selection opens without freezing; and
// vault_passkey_destroy must dismiss open prompts before joining and bound its wait by cancel_grace_ms.
// (One test: the prompt slots and pin_wake_set are process-global, so two parallel tests would share them.)
@(test)
webauthn_shell_wake_and_vault_passkey_destroy :: proc(t: ^testing.T) {
	app := test_app(t)
	webauthn_shell_init(app)
	defer webauthn_shell_destroy(app)

	// 1. Worker prompt wakes the UI loop even though thread-local the_app is nil on the worker thread.
	active_window(app).frames_requested = 0

	Job :: struct {
		token: webauthn.Cancel_Token,
		index: int,
		ok:    bool,
	}
	job: Job
	th := host.thread_start(proc(data: rawptr) {
		j := (^Job)(data)
		accounts := [?]webauthn.Choose_Account{
			{name = "first@example.com", display_name = "First"},
			{name = "second@example.com", display_name = "Second"},
		}
		j.index, j.ok = webauthn.choose_ask(&j.token, "vault.bitwarden.com", accounts[:])
	}, &job, name = "test-webauthn-wake")
	testing.expect(t, th != nil, "worker thread started")
	if th == nil { return }

	deadline := time.tick_add(time.tick_now(), 5 * time.Second)
	for active_window(app).frames_requested == 0 {
		left := int(time.duration_milliseconds(time.tick_diff(time.tick_now(), deadline)))
		if left <= 0 { break }
		host.loop_wait(&app.loop, left)
	}
	testing.expect(t, active_window(app).frames_requested > 0, "worker prompt wakes the UI loop and requests frames")

	q := webauthn.choose_question()
	defer webauthn.choose_question_destroy(&q)
	testing.expect(t, q.number != 0, "account choice prompt is open")
	testing.expect_value(t, q.rp_id, "vault.bitwarden.com")
	testing.expect_value(t, len(q.accounts), 2)
	webauthn.choose_answer(q.number, 1, true)

	host.thread_join(th)
	host.loop_drain(&app.loop)
	testing.expect(t, job.ok && job.index == 1, "selected passkey index returned to worker")

	// 2. Worker blocked in choose_ask: vault_passkey_destroy dismisses the prompt and joins cleanly.
	Gate :: struct {
		mu:    sync.Mutex,
		cond:  sync.Cond,
		ready: bool,
	}
	gate_set :: proc "contextless" (user: rawptr) {
		g := (^Gate)(user)
		sync.mutex_lock(&g.mu)
		g.ready = true
		sync.cond_broadcast(&g.cond)
		sync.mutex_unlock(&g.mu)
	}
	gate_wait :: proc(g: ^Gate) -> bool {
		sync.mutex_lock(&g.mu)
		defer sync.mutex_unlock(&g.mu)
		deadline := time.tick_add(time.tick_now(), 5 * time.Second)
		for !g.ready {
			left := time.tick_diff(time.tick_now(), deadline)
			if left <= 0 || !sync.cond_wait_with_timeout(&g.cond, &g.mu, left) { return false }
		}
		return true
	}

	app.page_settings.authn.cancel_grace_ms = 5000
	prompt_open := new(Gate)
	defer free(prompt_open)
	webauthn.pin_wake_set(gate_set, prompt_open)

	c1 := webauthn.ceremony_make(.Get)
	op1 := new(Vault_Passkey_Op, base.process_allocator())
	op1^ = {app = app, c = c1}
	app.vault.passkey_op = op1
	op1.thread = host.thread_start(proc(data: rawptr) {
		op := (^Vault_Passkey_Op)(data)
		accounts := [?]webauthn.Choose_Account{{name = "a@example.com"}, {name = "b@example.com"}}
		_, _ = webauthn.choose_ask(&op.c.cancel, "vault.bitwarden.com", accounts[:])
		sync.atomic_store(&op.done, true)
	}, op1, name = "test-vault-dismiss")
	testing.expect(t, gate_wait(prompt_open), "prompt opened")
	vault_passkey_destroy(app)
	testing.expect(t, app.vault.passkey_op == nil, "passkey_op cleared after prompt dismissal")

	// 3. Worker ignores cancel: vault_passkey_destroy returns after cancel_grace_ms instead of hanging.
	app.page_settings.authn.cancel_grace_ms = 30
	Stuck :: struct {
		entered: Gate,
		release: sync.Sema,
	}
	stuck := new(Stuck)
	defer free(stuck)

	c2 := webauthn.ceremony_make(.Get)
	op2 := new(Vault_Passkey_Op, base.process_allocator())
	op2^ = {app = app, c = c2}
	app.vault.passkey_op = op2
	// Keep the ceremony's cancel unused and wait on stuck.release to simulate an unresponsive authenticator.
	Stuck_Arg :: struct { op: ^Vault_Passkey_Op, s: ^Stuck }
	arg := new(Stuck_Arg)
	arg^ = {op2, stuck}
	op2.thread = host.thread_start(proc(data: rawptr) {
		a := (^Stuck_Arg)(data)
		sync.mutex_lock(&a.s.entered.mu)
		a.s.entered.ready = true
		sync.cond_broadcast(&a.s.entered.cond)
		sync.mutex_unlock(&a.s.entered.mu)
		sync.sema_wait(&a.s.release)
		sync.atomic_store(&a.op.done, true)
		free(a)
	}, arg, name = "test-vault-stuck")
	testing.expect(t, gate_wait(&stuck.entered), "stuck worker running")

	started := time.tick_now()
	vault_passkey_destroy(app)
	elapsed_ms := time.duration_milliseconds(time.tick_since(started))
	testing.expect(t, app.vault.passkey_op == nil, "passkey_op cleared after grace timeout")
	testing.expect(t, elapsed_ms < 2000, "vault_passkey_destroy returned within bounded grace")

	// Release and clean up the simulated stuck op so the test leaks zero memory.
	sync.sema_post(&stuck.release)
	host.thread_join(op2.thread)
	webauthn.ceremony_destroy(op2.c)
	free(op2, base.process_allocator())
}

// Closing the window bound to app.licence must retarget both state and owner to a surviving window, and clear them
// when the last window closes.
@(test)
licence_retarget_follows_surviving_window_and_clears_on_last :: proc(t: ^testing.T) {
	app := test_app(t)
	u1, u2 := new(ui.State), new(ui.State)
	p1, p2 := new(platform.Window), new(platform.Window)
	defer { free(u1); free(u2); free(p1); free(p2) }
	w1 := Browser_Window{id = 1, ui = u1, win = p1}
	w2 := Browser_Window{id = 2, ui = u2, win = p2}

	app.licence.state = u1
	app.licence.options.owner = p1

	// Closing an unrelated window changes nothing.
	licence_retarget(app, &w2, &w1)
	testing.expect(t, app.licence.state == u1 && app.licence.options.owner == p1, "unrelated window leaves licence intact")

	// Closing w1 moves both pointers to surviving heir w2.
	licence_retarget(app, &w1, &w2)
	testing.expect(t, app.licence.state == u2, "licence state retargeted to heir")
	testing.expect(t, app.licence.options.owner == p2, "licence owner retargeted to heir")

	// Closing the last window clears both pointers.
	licence_retarget(app, &w2, nil)
	testing.expect(t, app.licence.state == nil && app.licence.options.owner == nil, "licence pointers cleared on last window")
}

// Carry-path tab drags must reset on capture loss, window deactivation, Escape, or missing source window instead of
// wedging app.tab_drag.active permanently, and tab_detach must be a no-op on a single-tab window.
@(test)
tab_drag_cancels_on_capture_loss_deactivate_escape_and_single_detach_no_op :: proc(t: ^testing.T) {
	app := test_app(t)
	pw := platform.Window{active = true}
	w := Browser_Window{id = 11, win = &pw}
	defer delete(w.tabs)
	t1 := tab_new_bare(app, &w, url = "https://example.com/")

	app.windows = make([dynamic]^Browser_Window)
	append(&app.windows, &w)
	app.active = &w
	defer {
		app.active = nil
		delete(app.windows)
		app.windows = nil
	}

	// Single-tab detach is a no-op.
	testing.expect(t, tab_detach(app, t1) == nil, "tab_detach returns nil for a single-tab window")
	testing.expect_value(t, len(w.tabs), 1)

	arm :: proc(app: ^App, w: ^Browser_Window, tab: ^Tab) {
		app.tab_drag = {active = true, tab = tab.id, window = w.id, source = w.id}
	}

	// 1. Capture loss (Mouse_Release with lost = true).
	arm(app, &w, t1)
	tab_drag_events(app, []platform.Event{{kind = .Mouse_Release, button = .Left, lost = true}})
	testing.expect(t, !app.tab_drag.active, "capture loss resets tab_drag")

	// 2. Escape cancels drag.
	arm(app, &w, t1)
	tab_drag_events(app, []platform.Event{{kind = .Key_Press, key = .Escape}})
	testing.expect(t, !app.tab_drag.active, "Escape resets tab_drag")

	// 3. Window activation keeps drag; deactivation cancels it.
	arm(app, &w, t1)
	pw.active = true
	tab_drag_events(app, []platform.Event{{kind = .Activate}})
	testing.expect(t, app.tab_drag.active, "activation keeps tab_drag active")
	pw.active = false
	tab_drag_events(app, []platform.Event{{kind = .Activate}})
	testing.expect(t, !app.tab_drag.active, "deactivation resets tab_drag")
	pw.active = true

	// 4. Non-injected Mouse_Move without left button held cancels drag.
	arm(app, &w, t1)
	tab_drag_events(app, []platform.Event{{kind = .Mouse_Move, buttons = {}}})
	testing.expect(t, !app.tab_drag.active, "mouse move without left button resets tab_drag")

	// 5. Source window gone resets drag.
	app.tab_drag = {active = true, tab = t1.id, window = w.id, source = 999}
	tab_drag_events(app, nil)
	testing.expect(t, !app.tab_drag.active, "missing source window resets tab_drag")
}
