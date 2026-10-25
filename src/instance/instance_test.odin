package instance

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "wb:base"

@(test)
instance_key_follows_channel_and_profile :: proc(t: ^testing.T) {
	a := profile_key("release", `C:\Users\me\AppData\Roaming\Wren`)
	testing.expect(t, strings.has_prefix(a, "Wren.release."), "channel in the key")
	testing.expect_value(t, len(a), len("Wren.release.") + 16)
	for c in a { testing.expectf(t, (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.', "%q is fine in a kernel object name", c) }
	testing.expect(t, profile_key("dev", `C:\Users\me\AppData\Roaming\Wren`) != a, "another channel, another key")
	testing.expect(t, profile_key("release", `C:\Users\me\AppData\Roaming\Wren2`) != a, "another profile, another key")
	when ODIN_OS == .Windows {
		testing.expect_value(t, profile_key("release", `c:/users/ME/appdata/roaming/wren/`), a)   // case, slash direction, trailing separator
	}
	testing.expect_value(t, profile_key("release", `C:\Users\me\AppData\Roaming\Wren`), a)   // (and always the same)
}

@(test)
instance_message_round_trip :: proc(t: ^testing.T) {
	m := Message{exe = `C:\Program Files\Wren\wren.exe`, setup = true, addresses = {"https://example.org/a?b=c&d", "file:///C:/x/a%20b.html", "about:config"}}
	back, ok := decode(encode(m))
	testing.expect(t, ok, "decoded")
	testing.expect_value(t, back.exe, m.exe)
	testing.expect_value(t, back.setup, true)
	testing.expect_value(t, len(back.addresses), 3)
	testing.expect(t, len(back.addresses) == 3 && back.addresses[1] == "file:///C:/x/a%20b.html", "addresses in order")

	back, ok = decode(encode(Message{exe = "x"}))
	testing.expect(t, ok && !back.setup && len(back.addresses) == 0, "an empty message (just bring the window forward)")

	// what cannot be an address is dropped, not turned into two
	back, ok = decode(encode(Message{exe = "x", addresses = {"a\nb", "", "good"}}))
	testing.expect(t, ok && len(back.addresses) == 1 && back.addresses[0] == "good", "line breaks and empties are dropped")
}

@(test)
instance_garbage_is_refused :: proc(t: ^testing.T) {
	for g in ([]string{"", "v2\nexe=x\n", "v1\n", "v1\nexe=x\nwhat=ever\n", "hello", "v1\naddr=a\n"}) {
		_, ok := decode(transmute([]byte)g)
		testing.expectf(t, !ok, "%q is not a message", g)
	}
}

@(test)
instance_same_exe :: proc(t: ^testing.T) {
	testing.expect(t, same_exe(`C:\a\wren.exe`, `C:\a\wren.exe`), "same")
	testing.expect(t, !same_exe(`C:\a\wren.exe`, `C:\b\wren.exe`), "another folder")
	testing.expect(t, !same_exe("", ""), "nothing is not a program")
	when ODIN_OS == .Windows { testing.expect(t, same_exe(`C:\A\Wren.exe`, `c:/a/wren.exe`), "case and slashes") }
}

////////////////////////////////
// The real exchange, in one process: a thread is the owner (it pumps its window), the test thread is the second start.

@(private = "file")
Owner_Thread :: struct {
	key, exe:  string,
	ready:     sync.Sema,
	stop:      bool,
	closing:   bool,          // refuse messages from now on (as the owner does when it ends), keep pumping
	pump:      bool,          // false: do not pump (a busy owner)
	delay_ms:  int,           // the window comes this long after the mutex (an owner that is starting)
	got:       [dynamic]string,
	mu:        sync.Mutex,
	started:   bool,
}

@(private = "file")
owner_handler :: proc(user: rawptr, m: Message) {
	d := (^Owner_Thread)(user)
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	// (the heap, not the thread's allocator: the test thread reads and frees this, and the tracking one is its own)
	text := fmt.aprintf("setup=%v:%s", m.setup, strings.join(m.addresses, "|", context.temp_allocator), allocator = runtime.heap_allocator())
	append(&d.got, text)
}

@(private = "file")
owner_main :: proc(th: ^thread.Thread) {
	d := (^Owner_Thread)(th.data)
	outcome, owner := acquire(d.key, d.exe, {}, 0)
	d.started = outcome == .First
	sync.sema_post(&d.ready)
	if d.delay_ms > 0 { time.sleep(time.Duration(d.delay_ms) * time.Millisecond) }
	if d.started { owner_start(&owner, owner_handler, d) }
	for !d.stop {
		if d.closing { owner.closing = true }
		if d.pump { pump_messages() } else { time.sleep(20 * time.Millisecond) }
		time.sleep(2 * time.Millisecond)
	}
	if d.started { owner_stop(&owner) }
}

@(private = "file")
owner_begin :: proc(key, exe: string, pump := true, delay_ms := 0) -> (^Owner_Thread, ^thread.Thread) {
	d := new(Owner_Thread, runtime.heap_allocator())
	d.got.allocator = runtime.heap_allocator()
	d.key, d.exe, d.pump, d.delay_ms = key, exe, pump, delay_ms
	th := thread.create(owner_main)
	th.data = d
	thread.start(th)
	sync.sema_wait(&d.ready)
	return d, th
}

@(private = "file")
owner_end :: proc(d: ^Owner_Thread, th: ^thread.Thread) {
	d.stop = true
	thread.join(th)
	thread.destroy(th)
	for g in d.got { delete(g, runtime.heap_allocator()) }
	delete(d.got)
	free(d, runtime.heap_allocator())
}

@(test)
instance_second_start_hands_over_and_ends :: proc(t: ^testing.T) {
	key := profile_key("test", fmt.tprintf("C:\\wren_instance_test\\%s", base.unique_name(context.temp_allocator)))
	d, th := owner_begin(key, `C:\a\wren.exe`)
	defer owner_end(d, th)
	testing.expect(t, d.started, "the first start owns the profile")

	outcome, _ := acquire(key, `C:\a\wren.exe`, Message{exe = `C:\a\wren.exe`, addresses = {"https://example.org/", "file:///C:/x.html"}}, 3000)
	testing.expect_value(t, outcome, Outcome.Forwarded)
	outcome, _ = acquire(key, `C:\a\wren.exe`, Message{exe = `C:\a\wren.exe`, setup = true}, 3000)   // nothing to open: just the window, and Setup
	testing.expect_value(t, outcome, Outcome.Forwarded)
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	testing.expect_value(t, len(d.got), 2)
	testing.expect(t, len(d.got) == 2 && d.got[0] == "setup=false:https://example.org/|file:///C:/x.html", "the addresses arrived in order")
	testing.expect(t, len(d.got) == 2 && d.got[1] == "setup=true:", "and the request for Setup")
}

@(test)
instance_another_executable_is_not_taken :: proc(t: ^testing.T) {
	key := profile_key("test", fmt.tprintf("C:\\wren_instance_test\\%s", base.unique_name(context.temp_allocator)))
	d, th := owner_begin(key, `C:\installed\wren.exe`)
	defer owner_end(d, th)
	outcome, _ := acquire(key, `C:\download\wren.exe`, Message{exe = `C:\download\wren.exe`, addresses = {"about:config"}}, 3000)
	testing.expect_value(t, outcome, Outcome.Other_Copy)
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	testing.expect_value(t, len(d.got), 0)
}

@(test)
instance_profiles_are_independent :: proc(t: ^testing.T) {
	id := base.unique_name(context.temp_allocator)
	k1 := profile_key("test", fmt.tprintf("C:\\wren_instance_test\\a%s", id))
	k2 := profile_key("test", fmt.tprintf("C:\\wren_instance_test\\b%s", id))
	d, th := owner_begin(k1, `C:\a\wren.exe`)
	defer owner_end(d, th)
	outcome, owner := acquire(k2, `C:\a\wren.exe`, Message{exe = `C:\a\wren.exe`}, 500)
	testing.expect_value(t, outcome, Outcome.First)   // another profile: nothing to hand over to
	owner_stop(&owner)
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	testing.expect_value(t, len(d.got), 0)
}

@(test)
instance_a_silent_owner_does_not_hold_the_second_start :: proc(t: ^testing.T) {
	key := profile_key("test", fmt.tprintf("C:\\wren_instance_test\\%s", base.unique_name(context.temp_allocator)))
	d, th := owner_begin(key, `C:\a\wren.exe`, pump = false)   // has the window, never answers
	defer owner_end(d, th)
	// (on the CI the second start got First once, which means the owner had not taken the profile: say so, instead of a misleading outcome)
	if !testing.expect(t, d.started, "the owner thread took the profile before the second start is tried") { return }
	t0 := time.tick_now()
	outcome, _ := acquire(key, `C:\a\wren.exe`, Message{exe = `C:\a\wren.exe`, addresses = {"about:config"}}, 700)
	testing.expect_value(t, outcome, Outcome.Unresponsive)
	testing.expect(t, time.duration_milliseconds(time.tick_since(t0)) < 3000, "it gave up after about the timeout")
}

@(test)
instance_a_closing_owner_is_waited_for :: proc(t: ^testing.T) {
	key := profile_key("test", fmt.tprintf("C:\\wren_instance_test\\%s", base.unique_name(context.temp_allocator)))
	d, th := owner_begin(key, `C:\a\wren.exe`)
	d.closing = true   // it refuses from now on
	time.sleep(50 * time.Millisecond)
	// the owner goes away a moment later; the second start, which was refused meanwhile, becomes the owner
	closer := thread.create_and_start_with_poly_data2(d, th, proc(d: ^Owner_Thread, th: ^thread.Thread) {
		time.sleep(400 * time.Millisecond)
		owner_end(d, th)
	})
	outcome, owner := acquire(key, `C:\a\wren.exe`, Message{exe = `C:\a\wren.exe`, addresses = {"about:config"}}, 5000)
	testing.expect_value(t, outcome, Outcome.First)
	owner_stop(&owner)
	thread.join(closer)
	thread.destroy(closer)
}

@(test)
instance_a_start_that_finds_no_window_yet_waits_for_it :: proc(t: ^testing.T) {
	key := profile_key("test", fmt.tprintf("C:\\wren_instance_test\\%s", base.unique_name(context.temp_allocator)))
	// the owner holds the mutex (it is starting) and makes its window 400 ms later
	d, th := owner_begin(key, `C:\a\wren.exe`, delay_ms = 400)
	defer owner_end(d, th)
	outcome, _ := acquire(key, `C:\a\wren.exe`, Message{exe = `C:\a\wren.exe`, addresses = {"https://example.org/"}}, 5000)
	testing.expect_value(t, outcome, Outcome.Forwarded)
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	testing.expect_value(t, len(d.got), 1)
}