package webauthn

// The PIN of a security key, asked of the person while a ceremony runs, the wait for the key's touch that follows, and
// the account to use when the key holds several of the site (Linux: libfido2 speaks to the key itself and
// needs the PIN from the browser; Windows draws its own dialog). One question at a time, in a slot of this package: the
// ceremony's thread asks (pin_ask) and waits; the interface reads the question (pin_question), shows its dialog and
// answers (pin_answer) with the question's number, so that an answer to a question already over is dropped. The PIN
// is a secret: the slot's copy is zeroed once the thread has taken it.

import "core:sync"
import "core:time"

PIN_MAX :: 63   // CTAP2: a PIN is at most 63 bytes of UTF-8

Pin_Question :: struct {
	number:  u64,      // 0: no question
	rp_id:   string,   // the site the key is asked for (the slot's own copy, valid while the question is open)
	retries: int,      // the PINs the key still takes before it blocks (-1: not known)
	wrong:   bool,     // the last PIN given was wrong
}

@(private = "file")
Pin_Slot :: struct {
	ask:      sync.Mutex,   // one ceremony asks at a time
	mu:       sync.Mutex,
	question: Pin_Question,
	rp:       [256]u8,
	answered: bool,
	given:    bool,
	pin:      [PIN_MAX]u8,
	pin_len:  int,
	next:     u64,
}

@(private = "file")
pin_slot: Pin_Slot

// Told when a question opens or closes, on the ceremony's thread: the interface wakes and reads pin_question. It must
// not block. Set by the shell before any ceremony runs (nil: no interface; a PIN is then never asked).
pin_wake: proc "contextless" ()

// The open question, or one with number 0. Called by the interface each frame it builds: a lock and a copy.
pin_question :: proc() -> Pin_Question {
	sync.mutex_lock(&pin_slot.mu)
	defer sync.mutex_unlock(&pin_slot.mu)
	if pin_slot.answered { return {} }
	return pin_slot.question
}

// The person's answer to the question `number`: a PIN (`given`), or a refusal. Dropped when that question is over.
pin_answer :: proc(number: u64, pin: string, given: bool) {
	sync.mutex_lock(&pin_slot.mu)
	defer sync.mutex_unlock(&pin_slot.mu)
	if number == 0 || pin_slot.question.number != number || pin_slot.answered { return }
	pin_slot.answered, pin_slot.given = true, given && len(pin) > 0 && len(pin) <= PIN_MAX
	if pin_slot.given {
		copy(pin_slot.pin[:], pin)
		pin_slot.pin_len = len(pin)
	}
}

// Asks the person for the key's PIN and waits for the answer, or for the ceremony's cancel. `out` receives the PIN
// (the caller zeroes it); ok is false when the person refused, the ceremony was cancelled, or no interface asks.
pin_ask :: proc(token: ^Cancel_Token, rp_id: string, retries: int, wrong: bool, out: ^[PIN_MAX + 1]u8) -> (n: int, ok: bool) {
	if pin_wake == nil { return 0, false }
	sync.mutex_lock(&pin_slot.ask)
	defer sync.mutex_unlock(&pin_slot.ask)
	sync.mutex_lock(&pin_slot.mu)
	pin_slot.next += 1
	rp := copy(pin_slot.rp[:], rp_id)
	pin_slot.question = {number = pin_slot.next, rp_id = string(pin_slot.rp[:rp]), retries = retries, wrong = wrong}
	pin_slot.answered, pin_slot.given, pin_slot.pin_len = false, false, 0
	sync.mutex_unlock(&pin_slot.mu)
	pin_wake()
	defer pin_wake()   // (the question is over: the dialog goes)
	// (a look at the answer and at the cancel every 50 ms: the person types for seconds, a cancel is seen at once)
	for {
		sync.mutex_lock(&pin_slot.mu)
		if pin_slot.answered {
			if pin_slot.given {
				n = pin_slot.pin_len
				copy(out[:], pin_slot.pin[:n])
				out[n] = 0
				ok = true
			}
			for &b in pin_slot.pin { b = 0 }
			pin_slot.pin_len = 0
			pin_slot.question = {}
			sync.mutex_unlock(&pin_slot.mu)
			return
		}
		sync.mutex_unlock(&pin_slot.mu)
		if c, _ := cancelled(token); c {
			sync.mutex_lock(&pin_slot.mu)
			pin_slot.question, pin_slot.answered = {}, true
			sync.mutex_unlock(&pin_slot.mu)
			return 0, false
		}
		time.sleep(50 * time.Millisecond)
	}
}

// The account to sign in with, when the key holds several passkeys of the site and the request named none (an empty
// allowCredentials list): the key gives one assertion per passkey, the person chooses one, as in Chrome. The same
// pattern as the PIN: the ceremony's thread asks (choose_ask) and waits, the interface reads (choose_question) and
// answers (choose_answer) with the question's number.
CHOOSE_MAX      :: 16    // the accounts shown (a key holds a few per site; more do not fit a dialog)
CHOOSE_NAME_MAX :: 128   // bytes of each name kept (cut on a UTF-8 boundary)

Choose_Account :: struct {
	name:         string,   // user.name (an email or a login)
	display_name: string,   // user.displayName
}

Choose_Question :: struct {
	number:   u64,                // 0: no question
	rp_id:    string,             // the slot's own copy, valid while the question is open
	accounts: []Choose_Account,   // the same (at most CHOOSE_MAX)
}

@(private = "file")
Choose_Slot :: struct {
	ask:      sync.Mutex,   // one ceremony asks at a time
	mu:       sync.Mutex,
	question: Choose_Question,
	rp:       [256]u8,
	// (the worker frees its assertion once it has the answer: the names live here, not in libfido2's memory)
	names:    [CHOOSE_MAX][CHOOSE_NAME_MAX]u8,
	displays: [CHOOSE_MAX][CHOOSE_NAME_MAX]u8,
	accounts: [CHOOSE_MAX]Choose_Account,
	answered: bool,
	chosen:   bool,
	index:    int,
	next:     u64,
}

@(private = "file")
choose_slot: Choose_Slot

// `s` cut to at most `max` bytes, never in the middle of a UTF-8 sequence (a cut name still draws).
@(private = "file")
utf8_cut :: proc(s: string, max: int) -> string {
	if len(s) <= max { return s }
	n := max
	for n > 0 && s[n] & 0xC0 == 0x80 { n -= 1 }
	return s[:n]
}

// The open question, or one with number 0. Called by the interface each frame it builds: a lock and a copy.
choose_question :: proc() -> Choose_Question {
	sync.mutex_lock(&choose_slot.mu)
	defer sync.mutex_unlock(&choose_slot.mu)
	if choose_slot.answered { return {} }
	return choose_slot.question
}

// The person's answer to the question `number`: the account at `index` (`chosen`), or a refusal. Dropped when that
// question is over or the index is not one of its accounts.
choose_answer :: proc(number: u64, index: int, chosen: bool) {
	sync.mutex_lock(&choose_slot.mu)
	defer sync.mutex_unlock(&choose_slot.mu)
	if number == 0 || choose_slot.question.number != number || choose_slot.answered { return }
	if chosen && (index < 0 || index >= len(choose_slot.question.accounts)) { return }
	choose_slot.answered, choose_slot.chosen, choose_slot.index = true, chosen, index
}

// Asks the person which account to use and waits for the answer, or for the ceremony's cancel. Only the first
// CHOOSE_MAX accounts are offered. ok is false when the person refused, the ceremony was cancelled, or no interface
// asks.
choose_ask :: proc(token: ^Cancel_Token, rp_id: string, accounts: []Choose_Account) -> (index: int, ok: bool) {
	if pin_wake == nil || len(accounts) == 0 { return 0, false }
	sync.mutex_lock(&choose_slot.ask)
	defer sync.mutex_unlock(&choose_slot.ask)
	sync.mutex_lock(&choose_slot.mu)
	choose_slot.next += 1
	rp := copy(choose_slot.rp[:], utf8_cut(rp_id, len(choose_slot.rp)))
	n := min(len(accounts), CHOOSE_MAX)
	for a, i in accounts[:n] {
		nl := copy(choose_slot.names[i][:], utf8_cut(a.name, CHOOSE_NAME_MAX))
		dl := copy(choose_slot.displays[i][:], utf8_cut(a.display_name, CHOOSE_NAME_MAX))
		choose_slot.accounts[i] = {name = string(choose_slot.names[i][:nl]), display_name = string(choose_slot.displays[i][:dl])}
	}
	choose_slot.question = {number = choose_slot.next, rp_id = string(choose_slot.rp[:rp]), accounts = choose_slot.accounts[:n]}
	choose_slot.answered, choose_slot.chosen, choose_slot.index = false, false, 0
	sync.mutex_unlock(&choose_slot.mu)
	pin_wake()
	defer pin_wake()   // (the question is over: the dialog goes)
	// (a look at the answer and at the cancel every 50 ms, as pin_ask)
	for {
		sync.mutex_lock(&choose_slot.mu)
		if choose_slot.answered {
			index, ok = choose_slot.index, choose_slot.chosen
			choose_slot.question = {}
			sync.mutex_unlock(&choose_slot.mu)
			return
		}
		sync.mutex_unlock(&choose_slot.mu)
		if c, _ := cancelled(token); c {
			sync.mutex_lock(&choose_slot.mu)
			choose_slot.question, choose_slot.answered = {}, true
			sync.mutex_unlock(&choose_slot.mu)
			return 0, false
		}
		time.sleep(50 * time.Millisecond)
	}
}

// The wait for the person's touch on the key (Linux: libfido2 waits in its call; Windows says it in its own dialog).
// The interface shows it, and its Cancel stops the ceremony.
Touch_Question :: struct {
	number: u64,      // 0: no wait
	rp_id:  string,   // the slot's own copy, valid while the wait is open
}

@(private = "file")
Touch_Slot :: struct {
	mu:       sync.Mutex,
	question: Touch_Question,
	rp:       [256]u8,
	platform: ^Platform,
	token:    ^Cancel_Token,
	next:     u64,
}

@(private = "file")
touch_slot: Touch_Slot

// The ceremony's thread is about to wait for the touch (before its blocking call to the key).
touch_begin :: proc(pl: ^Platform, token: ^Cancel_Token, rp_id: string) {
	sync.mutex_lock(&touch_slot.mu)
	touch_slot.next += 1
	n := copy(touch_slot.rp[:], rp_id)
	touch_slot.question = {number = touch_slot.next, rp_id = string(touch_slot.rp[:n])}
	touch_slot.platform, touch_slot.token = pl, token
	sync.mutex_unlock(&touch_slot.mu)
	if pin_wake != nil { pin_wake() }
}

// The key answered (or the wait was cancelled): the wait is over.
touch_end :: proc() {
	sync.mutex_lock(&touch_slot.mu)
	touch_slot.question, touch_slot.platform, touch_slot.token = {}, nil, nil
	sync.mutex_unlock(&touch_slot.mu)
	if pin_wake != nil { pin_wake() }
}

// The open wait, or one with number 0.
touch_question :: proc() -> Touch_Question {
	sync.mutex_lock(&touch_slot.mu)
	defer sync.mutex_unlock(&touch_slot.mu)
	return touch_slot.question
}

// The person gave up the wait `number`: its ceremony is cancelled (the key stops blinking, the caller gets
// NotAllowedError). Dropped when that wait is over.
touch_cancel :: proc(number: u64) {
	sync.mutex_lock(&touch_slot.mu)
	defer sync.mutex_unlock(&touch_slot.mu)
	if number == 0 || touch_slot.question.number != number || touch_slot.token == nil { return }
	cancel(touch_slot.platform, touch_slot.token, .Abort)
}
