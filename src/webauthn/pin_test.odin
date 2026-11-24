package webauthn

import "core:encoding/hex"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
Pin_Job :: struct {
	token: Cancel_Token,
	rp_id: string,
	buf:   [PIN_MAX + 1]u8,
	n:     int,
	ok:    bool,
}

@(private = "file")
pin_job_run :: proc(data: rawptr) {
	j := (^Pin_Job)(data)
	rp := j.rp_id != "" ? j.rp_id : "example.com"
	j.n, j.ok = pin_ask(&j.token, rp, 7, false, &j.buf)
}

@(private = "file")
Choose_Job :: struct {
	token:    Cancel_Token,
	rp_id:    string,
	accounts: []Choose_Account,
	index:    int,
	ok:       bool,
}

@(private = "file")
choose_job_run :: proc(data: rawptr) {
	j := (^Choose_Job)(data)
	rp := j.rp_id != "" ? j.rp_id : "example.com"
	if len(j.accounts) > 0 {
		j.index, j.ok = choose_ask(&j.token, rp, j.accounts)
		return
	}
	// (the second display name is longer than the slot keeps: it is cut to 128 bytes at most)
	long: [200]u8
	for &b in long { b = 'x' }
	long[127] = 0xC3; long[128] = 0xA9   // an "é" across the cut: it is dropped whole, never split
	accounts := [?]Choose_Account{
		{name = "ada@example.com", display_name = "Ada"},
		{name = "bob@example.com", display_name = string(long[:])},
	}
	j.index, j.ok = choose_ask(&j.token, rp, accounts[:])
}

// The ceremony's thread waits for the interface: the question it reads is the asked one, its answer comes back, an
// answer to an older question is dropped, and the slot keeps no PIN; then a cancelled ceremony stops waiting; then the
// wait for the touch; then the account to use, the same way; then snapshot isolation after slot reuse; then wake user
// pointer delivery and prompt dismissal. (One test: the slots and the wake are the package's, two tests at once would
// share them.)
@(test)
pin_question_answer_and_cancel :: proc(t: ^testing.T) {
	// (the wake is the interface's signal: the test waits on it, bounded, not on a time)
	opened := new(sync.Sema)
	defer free(opened)
	pin_wake_set(proc "contextless" (user: rawptr) { sync.sema_post((^sync.Sema)(user)) }, opened)
	defer pin_wake_set(nil, nil)

	j: Pin_Job
	th := thread.create_and_start_with_data(&j, pin_job_run)
	testing.expect(t, sync.sema_wait_with_timeout(opened, PIN_TEST_DEADLINE), "the question opens")
	q := pin_question()
	defer pin_question_destroy(&q)
	testing.expect_value(t, q.rp_id, "example.com")
	testing.expect_value(t, q.retries, 7)
	pin_answer(q.number - 1, "0000", true)   // (an older question's answer: dropped)
	pin_answer(q.number, "1234", true)
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, j.ok, "the PIN came back")
	testing.expect_value(t, string(j.buf[:j.n]), "1234")
	testing.expect_value(t, pin_question().number, 0)
	testing.expect(t, sync.sema_wait_with_timeout(opened, PIN_TEST_DEADLINE), "the interface is woken when the question closes")

	// A second PIN question with a different RP ID must not overwrite the owned snapshot of the first question.
	Wake_Gate :: struct {
		mu:    sync.Mutex,
		cond:  sync.Cond,
		count: int,
	}
	gate_signal :: proc "contextless" (user: rawptr) {
		g := (^Wake_Gate)(user)
		sync.mutex_lock(&g.mu)
		g.count += 1
		sync.cond_broadcast(&g.cond)
		sync.mutex_unlock(&g.mu)
	}
	gate_wait :: proc(g: ^Wake_Gate, want: int) -> bool {
		sync.mutex_lock(&g.mu)
		defer sync.mutex_unlock(&g.mu)
		deadline := time.tick_add(time.tick_now(), PIN_TEST_DEADLINE)
		for g.count < want {
			left := time.tick_diff(time.tick_now(), deadline)
			if left <= 0 || !sync.cond_wait_with_timeout(&g.cond, &g.mu, left) { return false }
		}
		return true
	}

	gate := new(Wake_Gate)
	defer free(gate)
	pin_wake_set(gate_signal, gate)

	j2 := Pin_Job{rp_id = "second.example"}
	th = thread.create_and_start_with_data(&j2, pin_job_run)
	testing.expect(t, gate_wait(gate, 1), "the second PIN question opens")
	q2 := pin_question()
	defer pin_question_destroy(&q2)
	testing.expect_value(t, q.rp_id, "example.com")
	testing.expect_value(t, q2.rp_id, "second.example")
	pin_dismiss()
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, !j2.ok, "pin_dismiss refuses an open PIN question")
	testing.expect(t, gate_wait(gate, 2), "wake fires when dismissed PIN closes")

	k: Pin_Job
	k.token.cancelled = true
	pin_job_run(&k)
	testing.expect(t, !k.ok, "no PIN when the ceremony was cancelled")
	testing.expect_value(t, pin_question().number, 0)

	// the wait for the touch: the interface sees it, its Cancel cancels that ceremony, a Cancel of an older wait does not
	// (heap-allocated so the compiler sees no stack address stored in the package's touch slot)
	token := new(Cancel_Token)
	defer free(token)
	touch_begin(nil, token, "example.com")
	w := touch_question()
	defer touch_question_destroy(&w)
	testing.expect_value(t, w.rp_id, "example.com")
	touch_cancel(w.number - 1)
	c, _ := cancelled(token)
	testing.expect(t, !c, "an older wait's Cancel does nothing")
	touch_cancel(w.number)
	c, _ = cancelled(token)
	testing.expect(t, c, "the Cancel cancels the ceremony")
	touch_end()
	testing.expect_value(t, touch_question().number, 0)
	// Reuse the touch slot with a different RP ID and verify the earlier owned snapshot is unchanged.
	touch_begin(nil, token, "other.example")
	w2 := touch_question()
	defer touch_question_destroy(&w2)
	testing.expect_value(t, w.rp_id, "example.com")
	testing.expect_value(t, w2.rp_id, "other.example")
	touch_end()

	// the account to use: the interface sees the accounts, an older question's answer and an index out of the list
	// are dropped, the chosen index comes back; then a cancelled ceremony stops waiting
	choose_opened := new(sync.Sema)
	defer free(choose_opened)
	pin_wake_set(proc "contextless" (user: rawptr) { sync.sema_post((^sync.Sema)(user)) }, choose_opened)
	cj: Choose_Job
	th = thread.create_and_start_with_data(&cj, choose_job_run)
	testing.expect(t, sync.sema_wait_with_timeout(choose_opened, PIN_TEST_DEADLINE), "the account question opens")
	cq := choose_question()
	defer choose_question_destroy(&cq)
	testing.expect_value(t, cq.rp_id, "example.com")
	testing.expect_value(t, len(cq.accounts), 2)
	if len(cq.accounts) == 2 {
		testing.expect_value(t, cq.accounts[0].name, "ada@example.com")
		testing.expect_value(t, cq.accounts[0].display_name, "Ada")
		testing.expect_value(t, len(cq.accounts[1].display_name), 127)   // (the "é" across byte 128 is not split)
	}
	choose_answer(cq.number - 1, 0, true)   // (an older question's answer: dropped)
	choose_answer(cq.number, 5, true)       // (no such account: dropped)
	cq_again := choose_question()
	testing.expect_value(t, cq_again.number, cq.number)
	choose_question_destroy(&cq_again)
	choose_answer(cq.number, 1, true)
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, cj.ok, "an account was chosen")
	testing.expect_value(t, cj.index, 1)
	testing.expect_value(t, choose_question().number, 0)
	testing.expect(t, sync.sema_wait_with_timeout(choose_opened, PIN_TEST_DEADLINE), "the interface is woken when the account question closes")

	// Start a second choose question with different data; verify the earlier cq snapshot stays intact and pin_dismiss unblocks it.
	gate2 := new(Wake_Gate)
	defer free(gate2)
	pin_wake_set(gate_signal, gate2)
	alt_accounts := [?]Choose_Account{{name = "zoe@other.test", display_name = "Zoe"}}
	cj2 := Choose_Job{rp_id = "other.test", accounts = alt_accounts[:]}
	th = thread.create_and_start_with_data(&cj2, choose_job_run)
	testing.expect(t, gate_wait(gate2, 1), "second account question opens")
	cq2 := choose_question()
	defer choose_question_destroy(&cq2)
	testing.expect_value(t, cq.rp_id, "example.com")
	testing.expect_value(t, cq.accounts[0].name, "ada@example.com")
	testing.expect_value(t, cq2.rp_id, "other.test")
	testing.expect_value(t, cq2.accounts[0].name, "zoe@other.test")
	pin_dismiss()
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, !cj2.ok, "pin_dismiss refuses an open account question")
	testing.expect(t, gate_wait(gate2, 2), "wake fires when dismissed account question closes")

	ck: Choose_Job
	ck.token.cancelled = true
	choose_job_run(&ck)
	testing.expect(t, !ck.ok, "no account when the ceremony was cancelled")
	testing.expect_value(t, choose_question().number, 0)

	// Clearing pin_wake_set disables prompts cleanly.
	pin_wake_set(nil, nil)
	no_ui: Pin_Job
	pin_job_run(&no_ui)
	testing.expect(t, !no_ui.ok, "pin_ask refuses when no wake callback is registered")
}

when ODIN_OS == .Linux {
	// Preparing a Linux libfido2 cancel token allocates Fido2_Op and registers cleanup so ceremony_destroy frees it
	// without leaking memory.
	@(test)
	fido2_cancel_token_cleanup_frees_op :: proc(t: ^testing.T) {
		c := ceremony_make(.Get)
		testing.expect(t, c != nil, "ceremony allocated")
		if c == nil { return }
		fido2_prepare_cancel(nil, &c.cancel)
		testing.expect(t, c.cancel.has_platform, "prepare_cancel populates platform slot")
		testing.expect(t, c.cancel.cleanup != nil, "prepare_cancel registers cleanup")
		fido2_cancel(nil, &c.cancel)   // safe with nil dev
		ceremony_destroy(c)
	}
}

@(private = "file")
PIN_TEST_DEADLINE :: 10 * time.Second

// PRF inputs become hmac-secret salts: SHA-256("WebAuthn PRF" || 0x00 || input) (WebAuthn §10.1.4).
@(test)
prf_salt_vectors :: proc(t: ^testing.T) {
	salt: [64]u8
	n := prf_salt({first = transmute([]u8)string("abc")}, &salt)
	testing.expect_value(t, n, 32)
	want, _ := hex.decode(transmute([]u8)string("425507dfa7404b2fc3743ff9673c78e7b3c2f9d298b533ae2d8277203f73f4b7"), context.temp_allocator)
	testing.expect_value(t, string(salt[:32]), string(want))
	n = prf_salt({first = transmute([]u8)string("abc"), second = nil, has_second = true}, &salt)
	testing.expect_value(t, n, 64)
	empty, _ := hex.decode(transmute([]u8)string("6a7e64b2aa34c92736143a062fa149aff1bd8bb3f7ee6f346885481f9414a3d3"), context.temp_allocator)
	testing.expect_value(t, string(salt[32:]), string(empty))
}
