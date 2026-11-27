# Media player lifetime

How a `media.Player` (`src/media/player.odin`) and its `Track_Store`s (`src/media/store.odin`) end, and why the owner
never waits for the player's threads.

## The problem

A player decodes on its own threads: a video thread and an audio thread. Each thread calls a decoder of the system
(Media Foundation on Windows, VA-API on Linux) or a built-in one. A system decoder can hang. On a Windows CI runner,
Microsoft's H.264 decoder (`msmpeg2vdec.dll`) did not return from `ProcessOutput`.

`player_destroy` joined the threads with no bound. The owner calls it on the interface thread: a tab that closes
(`tab_free` → `page_cleanup` → `media_destroy` → `media_teardown`), a new load, a source buffer that goes. So the hang
of a decoder froze the interface until the shutdown watchdog ended the process 10 s later. A user who closes a tab
with a video can hit the same freeze.

The interface thread never waits for something it does not control. So `player_destroy` does not join.

## The design

### The player is reference counted

- The owner holds one reference. Each thread that `player_create` starts holds one reference.
- `player_destroy` sets `quit`, wakes the threads, cuts the callbacks (see below), drops the owner's reference and
  returns at once.
- Each thread drops its reference when its procedure ends, after it destroyed its decoder.
- The last reference to go frees what the player owns: the audio output (stop, destroy), the queue of pictures, the
  current picture, the player, then its references to the stores.
- The threads start with `self_cleanup`: `core:thread` frees its `Thread` when the procedure ends. The player keeps no
  `^thread.Thread`, because that pointer can be freed at any time.
- The threads run with `base.process_context()`, not with the context of the caller. A thread can outlive the caller
  (a test, a page), so it must not allocate from the caller's allocator. The queue of pictures takes
  `base.process_allocator()` explicitly for the same reason.

If a decoder never returns, its thread and the player stay allocated until the process ends. That is the accepted
cost: a leak of one player is better than a frozen browser.

### The stores are reference counted

A `Track_Store` is shared by its owner (a media element, a `SourceBuffer`, the developer tools' player) and a player.
The owner releases its store right after `player_destroy`, while the player's threads can still read it.

- `store_create` gives one reference to the owner. `store_release` drops a reference; the last one frees the store.
- `player_create` takes one reference to each store it gets (`store_retain`). The player releases them when it is
  freed.
- Every access of the player's threads to a store goes through a `store_*` procedure that takes the store's mutex.
  The threads never read the fields directly. So a store that the owner changes (an append, a removal, a clear)
  while a thread reads it stays consistent, and only the free needs the reference count.
- The arrays of a store take `base.process_allocator()` at `store_create`, because the last release can run on a
  player thread.

### The callbacks are cut under a lock

The player calls two procedures of its owner from its threads:

- `notify(user)`: something changed, look at the state. In a page, `user` is the `Media_Element`.
- `capture(capture_user, samples, rate)`: the audio for a `MediaElementAudioSourceNode`.

The owner frees what `user` and `capture_user` point to right after `player_destroy`. So after `player_destroy`
returns, no thread may call either procedure.

- `poke` calls `notify` under `notify_mu`, a lock that only guards `notify` and `user`. It cannot use `p.mu`:
  `player_tick` calls `poke` while it holds `p.mu`, and `p.mu` is not recursive. The lock order is `p.mu`, then
  `notify_mu`. Nothing takes `p.mu` while it holds `notify_mu`.
- `player_destroy` sets `notify` to nil under `notify_mu`. A call in progress finishes before that, and no call starts
  after it.
- `capture` is already called under `p.mu` (`audio_push`). `player_destroy` sets `capture` to nil under `p.mu`, in the
  same section that sets `quit`.

Both callbacks are short and do not block: `media_player_notify` does a compare-and-swap and a `host.post` (a mutex
around an append, a semaphore post); `capture_sink` copies the samples into the node's ring under the graph's lock.
So `player_destroy` waits at most for one short call, never for a decoder.

### Live players and players_settle

A process-wide count of live players goes up in `player_create` and down when the last reference frees a player.
`players_settle(bound) -> bool` waits on a condition until the count is 0 or the bound passes.

- `page.process_shutdown` calls it with a bound of 2 s, before the Wasm engine and the other process-wide parts go.
  In the browser this runs after the windows are gone. If the bound passes, it logs one line and the process goes
  on: a hung decoder never holds the browser's exit. The shutdown watchdog (10 s) is longer than the bound.
- The end-to-end harness (`src/e2e`) calls it before `base.mem_report` when all memory is tracked
  (`WREN_TRACK_MEMORY`). Without it, a player that ends a moment after its page is counted as a leak.
- The unit tests of `src/page` do not call it: their trackers count only the context's allocator, and a player and its
  threads allocate only from the process allocator.

## Refused

- **A join with a bound, then a forced end of the thread.** A thread cannot be ended safely: it can hold a lock (the
  heap's, or one inside the decoder), and the process then deadlocks later. `TerminateThread` documents this.
- **A reaper thread that joins the players' threads.** It gives the same result as `self_cleanup` with one more thread,
  one more queue and one more shutdown step.
- **Detached threads with a player that the owner still frees.** The threads read the player and the stores after
  `player_destroy`. Without a reference they read freed memory.

## The test

`src/media/player_lifetime_test.odin` gives a player a decoder whose `pull` blocks until the test releases it. The test
checks that `player_destroy` returns at once while the decoder is still blocked, that `notify` is not called after it,
and that the player and its store are freed when the decoder returns. The decoder's wait has its own bound, so the
test fails instead of hanging if `player_destroy` joins again. The player gets the decoder through
`player_create_with`, a package-private form of `player_create` that takes the procedure that makes the video decoder:
a per-player seam, so the other tests of the package that run at the same time keep the real decoders.
