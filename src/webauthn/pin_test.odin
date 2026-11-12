package webauthn

import "core:encoding/hex"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private = "file")
Pin_Job :: struct {
	token: Cancel_Token,
	buf:   [PIN_MAX + 1]u8,
	n:     int,
	ok:    bool,
}


@(private = "file")
pin_job_run :: proc(data: rawptr) {
	j := (^Pin_Job)(data)
	j.n, j.ok = pin_ask(&j.token, "example.com", 7, false, &j.buf)
}

@(private = "file")
Choose_Job :: struct {
	token: Cancel_Token,
	index: int,
	ok:    bool,
}

@(private = "file")
choose_job_run :: proc(data: rawptr) {
	j := (^Choose_Job)(data)
	// (the second display name is longer than the slot keeps: it is cut to 128 bytes at most)
	long: [200]u8
	for &b in long { b = 'x' }
	long[127] = 0xC3; long[128] = 0xA9   // an "é" across the cut: it is dropped whole, never split
	accounts := [?]Choose_Account{
		{name = "ada@example.com", display_name = "Ada"},
		{name = "bob@example.com", display_name = string(long[:])},
	}
	j.index, j.ok = choose_ask(&j.token, "example.com", accounts[:])
}

@(private = "file")
pin_opened: sync.Sema
@(private = "file")
choose_opened: sync.Sema

// The ceremony's thread waits for the interface: the question it reads is the asked one, its answer comes back, an
// answer to an older question is dropped, and the slot keeps no PIN; then a cancelled ceremony stops waiting; then the
// wait for the touch; then the account to use, the same way. (One test: the slots and the wake are the package's, two tests at once would share them.)
@(test)
pin_question_answer_and_cancel :: proc(t: ^testing.T) {
	// (the wake is the interface's signal: the test waits on it, bounded, not on a time)
	pin_wake = proc "contextless" () { sync.sema_post(&pin_opened) }
	defer pin_wake = nil
	j: Pin_Job
	th := thread.create_and_start_with_data(&j, pin_job_run)
	testing.expect(t, sync.sema_wait_with_timeout(&pin_opened, PIN_TEST_DEADLINE), "the question opens")
	q := pin_question()
	testing.expect_value(t, q.rp_id, "example.com")
	testing.expect_value(t, q.retries, 7)
	pin_answer(q.number - 1, "0000", true)   // (an older question's answer: dropped)
	pin_answer(q.number, "1234", true)
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, j.ok, "the PIN came back")
	testing.expect_value(t, string(j.buf[:j.n]), "1234")
	testing.expect_value(t, pin_question().number, 0)
	testing.expect(t, sync.sema_wait_with_timeout(&pin_opened, PIN_TEST_DEADLINE), "the interface is woken when the question closes")

	k: Pin_Job
	k.token.cancelled = true
	pin_job_run(&k)
	testing.expect(t, !k.ok, "no PIN when the ceremony was cancelled")
	testing.expect_value(t, pin_question().number, 0)

	// the wait for the touch: the interface sees it, its Cancel cancels that ceremony, a Cancel of an older wait does not
	token: Cancel_Token
	touch_begin(nil, &token, "example.com")
	w := touch_question()
	testing.expect_value(t, w.rp_id, "example.com")
	touch_cancel(w.number - 1)
	c, _ := cancelled(&token)
	testing.expect(t, !c, "an older wait's Cancel does nothing")
	touch_cancel(w.number)
	c, _ = cancelled(&token)
	testing.expect(t, c, "the Cancel cancels the ceremony")
	touch_end()
	testing.expect_value(t, touch_question().number, 0)

	// the account to use: the interface sees the accounts, an older question's answer and an index out of the list
	// are dropped, the chosen index comes back; then a cancelled ceremony stops waiting
	// (a wake of its own: the cancelled PIN and the touch above left posts on pin_opened)
	pin_wake = proc "contextless" () { sync.sema_post(&choose_opened) }
	cj: Choose_Job
	th = thread.create_and_start_with_data(&cj, choose_job_run)
	testing.expect(t, sync.sema_wait_with_timeout(&choose_opened, PIN_TEST_DEADLINE), "the account question opens")
	cq := choose_question()
	testing.expect_value(t, cq.rp_id, "example.com")
	testing.expect_value(t, len(cq.accounts), 2)
	if len(cq.accounts) == 2 {
		testing.expect_value(t, cq.accounts[0].name, "ada@example.com")
		testing.expect_value(t, cq.accounts[0].display_name, "Ada")
		testing.expect_value(t, len(cq.accounts[1].display_name), 127)   // (the "é" across byte 128 is not split)
	}
	choose_answer(cq.number - 1, 0, true)   // (an older question's answer: dropped)
	choose_answer(cq.number, 5, true)       // (no such account: dropped)
	testing.expect_value(t, choose_question().number, cq.number)
	choose_answer(cq.number, 1, true)
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, cj.ok, "an account was chosen")
	testing.expect_value(t, cj.index, 1)
	testing.expect_value(t, choose_question().number, 0)
	testing.expect(t, sync.sema_wait_with_timeout(&choose_opened, PIN_TEST_DEADLINE), "the interface is woken when the account question closes")

	ck: Choose_Job
	ck.token.cancelled = true
	choose_job_run(&ck)
	testing.expect(t, !ck.ok, "no account when the ceremony was cancelled")
	testing.expect_value(t, choose_question().number, 0)
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
