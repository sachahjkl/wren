package media

import "core:sync"
import "core:testing"
import "core:time"
import "wb:base"

// The video thread reaches the decoder's pull (a thread start and one push: far under this).
@(private = "file") REACH_BOUND :: 10 * time.Second
// player_destroy returns. It joined the threads before: it waited for the decoder, as the interface thread did on a CI
// runner when Media Foundation's H.264 decoder did not return.
@(private = "file") DESTROY_BOUND :: time.Second
// The decoder stops waiting for the test on its own. Above DESTROY_BOUND: a player_destroy that joins again fails the
// test instead of hanging it.
@(private = "file") DECODER_HOLD :: 5 * time.Second
// Every player of the process is freed. Long: the other tests of the package can run their players meanwhile.
@(private = "file") SETTLE_BOUND :: 30 * time.Second

// A decoder whose first pull blocks until the test releases it (a system decoder that does not answer).
@(private = "file")
Blocking_Decoder :: struct {
	dec:       Video_Decoder,
	mu:        sync.Mutex,
	cv:        sync.Cond,
	pulled, inside, released, gave_up, destroyed: bool,
	// notify: every call, and the calls that started after player_destroy returned
	notified, late: i32,
	owner_gone: bool,
}

@(private = "file")
blocking_pull :: proc(d: ^Video_Decoder, out: ^Video_Frame) -> Pull_Result {
	b := (^Blocking_Decoder)(d.impl)
	sync.mutex_lock(&b.mu)
	defer sync.mutex_unlock(&b.mu)
	if b.pulled { return .Need_Input }
	b.pulled, b.inside = true, true
	sync.cond_broadcast(&b.cv)
	start := time.tick_now()
	for !b.released {
		left := DECODER_HOLD - time.tick_since(start)
		if left <= 0 { b.gave_up = true; break }
		sync.cond_wait_with_timeout(&b.cv, &b.mu, left)
	}
	// a picture: the thread then pokes its owner, which must not hear it any more
	out^ = Video_Frame{format = .I420, width = 16, height = 16}
	return .Frame
}

@(private = "file")
blocking_make :: proc(user: rawptr, t: Track, prefer_gpu: bool) -> ^Video_Decoder {
	b := (^Blocking_Decoder)(user)
	b.dec = Video_Decoder{
		impl = b,
		name = "blocking",
		push = proc(d: ^Video_Decoder, s: ^Sample) -> bool { return true },
		pull = blocking_pull,
		flush = proc(d: ^Video_Decoder) {},
		drain = proc(d: ^Video_Decoder) {},
		destroy = proc(d: ^Video_Decoder) {
			b := (^Blocking_Decoder)(d.impl)
			sync.mutex_lock(&b.mu)
			b.destroyed = true
			sync.mutex_unlock(&b.mu)
		},
	}
	return &b.dec
}

@(private = "file")
blocking_notify :: proc(user: rawptr) {
	b := (^Blocking_Decoder)(user)
	sync.atomic_add(&b.notified, 1)
	if sync.atomic_load(&b.owner_gone) { sync.atomic_add(&b.late, 1) }
}

// Waits on the decoder's condition for `done`, at most `bound`.
@(private = "file")
blocking_wait :: proc(b: ^Blocking_Decoder, done: ^bool, bound: time.Duration) -> bool {
	sync.mutex_lock(&b.mu)
	defer sync.mutex_unlock(&b.mu)
	start := time.tick_now()
	for !done^ {
		left := bound - time.tick_since(start)
		if left <= 0 { return false }
		sync.cond_wait_with_timeout(&b.cv, &b.mu, left)
	}
	return true
}

// A decoder that does not answer does not hold the owner: player_destroy returns at once, the owner hears nothing after
// it, and the player and its store are freed when the decoder returns at last.
@(test)
player_destroy_does_not_wait_for_a_decoder_that_hangs :: proc(t: ^testing.T) {
	b: Blocking_Decoder
	store := store_create()
	store_set_config(store, 1, Track{kind = .Video, codec = .H264, width = 16, height = 16})
	store_append(store, Sample{dts = 0, pts = 0, duration = 40_000_000, flags = {.Keyframe}, config = 1, data = make([]u8, 4, base.process_allocator())})
	store_retain(store)   // (the test's own: it sees when the player let its reference go)

	p := player_create_with(store, nil, PLAYER_SETTINGS_DEFAULT, blocking_notify, &b, {make = blocking_make, user = &b})
	reached := blocking_wait(&b, &b.inside, REACH_BOUND)
	testing.expect(t, reached, "the video thread reaches the decoder's pull")
	if !reached {
		// (the decoder must not block what follows: the thread may reach it later)
		sync.mutex_lock(&b.mu); b.released = true; sync.cond_broadcast(&b.cv); sync.mutex_unlock(&b.mu)
	}

	start := time.tick_now()
	player_destroy(p)
	took := time.tick_since(start)
	sync.atomic_store(&b.owner_gone, true)
	store_release(store)   // (the owner's, at once, as media_teardown does)
	testing.expectf(t, took < DESTROY_BOUND, "player_destroy returns while the decoder hangs: it took %v", took)
	sync.mutex_lock(&b.mu)
	testing.expect(t, !b.gave_up, "the decoder was still blocked when player_destroy returned")
	b.released = true
	sync.cond_broadcast(&b.cv)
	sync.mutex_unlock(&b.mu)

	// the thread ends: the decoder goes, then the player's reference to the store, then the player's place in the live count
	// (players_settle wakes when that count reaches 0: the condition, no poll)
	testing.expect(t, players_settle(SETTLE_BOUND), "every player is freed")
	testing.expectf(t, sync.atomic_load(&store.refs) == 1, "the player let its store go: %d references left", sync.atomic_load(&store.refs))
	if sync.atomic_load(&store.refs) == 1 {
		testing.expect(t, b.destroyed, "the decoder is destroyed")
		testing.expect_value(t, sync.atomic_load(&b.late), 0)   // the picture the decoder gave after the end was not told
		store_release(store)
	}
}
