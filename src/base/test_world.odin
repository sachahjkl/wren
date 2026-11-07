package base

import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// The world a measure gives a page (`wrentool replay`): a seeded random and a clock that does not depend on how fast the machine ran, so that two loads of the
// same bytes do the same work. WREN_TEST_WORLD=<seed>,<unix ms>, or `test_world_set` in a test; a release never reads it, and without it nothing here is reached.
// What it reaches is what a page can read: Date, performance.now and timeOrigin, a frame's time, Math.random, crypto's random; and what compares dates with
// what a recording served: the cookies and the HTTP cache (`wall_now`). The page's timers and the loop keep real time: a page's clock is not the browser's.
TEST_WORLD_ENV :: "WREN_TEST_WORLD"

// How far the page's clock moves at each read. A clock that stood still would never end `while (Date.now() < end)`, and one that crawls never lets a script that
// yields after so many ms of work yield: at 0.1 ms a read, cnn.com read 1 000 times in a load of 4 s and saw 0.1 s go by. At 2 ms the pages of round 51
// (docs/performance.md) see about the time a load takes, without it depending on how fast the machine ran.
TEST_WORLD_TICK_MS :: 2.0
@(private = "file") SPLITMIX_GAMMA :: u64(0x9E3779B97F4A7C15)
@(private = "file") SPLITMIX_MIX_1 :: u64(0xBF58476D1CE4E5B9)
@(private = "file") SPLITMIX_MIX_2 :: u64(0x94D049BB133111EB)
@(private = "file") NS_PER_MS :: 1_000_000

Test_World :: struct {
	on:       bool,
	seed:     u64,
	start_ms: f64,        // what the clock says at the first read: a recording's own date
	started:  time.Tick,
}

// (written before the first page exists, then only read)
test_world: Test_World

// Each thread has its own reads: a worker's scripts move neither the window's clock nor its random numbers, whichever runs first.
@(private = "file", thread_local) world_reads: u64
@(private = "file", thread_local) world_draws: u64

test_world_set :: proc(seed: u64, start_ms: f64) {
	test_world = {on = true, seed = seed, start_ms = start_ms, started = time.tick_now()}
	world_reads, world_draws = 0, 0
}

test_world_clear :: proc() { test_world = {} }

// From main, before anything of a page.
test_world_from_env :: proc() {
	when #config(WREN_CHANNEL, "dev") != "release" {
		text := os.get_env(TEST_WORLD_ENV, context.temp_allocator)
		if seed, start, ok := test_world_parse(text); ok { test_world_set(seed, start) }
	}
}

test_world_parse :: proc(text: string) -> (seed: u64, start_ms: f64, ok: bool) {
	comma := strings.index_byte(text, ',')
	if comma < 0 { return }
	seed = strconv.parse_u64(text[:comma], 10) or_return
	start_ms = strconv.parse_f64(text[comma + 1:]) or_return
	return seed, start_ms, true
}

// A read of the page's clock (ms since the epoch).
test_world_now_ms :: proc "contextless" () -> f64 {
	world_reads += 1
	return test_world.start_ms + f64(world_reads) * TEST_WORLD_TICK_MS
}

// The next bytes of the thread's seeded stream (SplitMix64).
test_world_random :: proc "contextless" (out: []byte) {
	for i := 0; i < len(out); i += 8 {
		world_draws += 1
		z := test_world.seed + world_draws * SPLITMIX_GAMMA
		z = (z ~ (z >> 30)) * SPLITMIX_MIX_1
		z = (z ~ (z >> 27)) * SPLITMIX_MIX_2
		z ~= z >> 31
		for j in i ..< min(i + 8, len(out)) { out[j] = u8(z >> uint(8 * (j - i))) }
	}
}

// The date for what compares with dates a site sent (a cookie's expiry, an answer's freshness): a recording's date plus the real time since the start, so
// that what was fresh when it was recorded stays so however long ago that was. The system's clock without a test world.
wall_now :: proc() -> time.Time {
	if !test_world.on { return time.now() }
	return time.unix(0, i64(test_world.start_ms) * NS_PER_MS + i64(time.tick_since(test_world.started)))
}
