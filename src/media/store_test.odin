package media

import "base:runtime"
import "core:testing"

// A frame through the same overlap pass a SourceBuffer uses before it appends.
@(private = "file")
frame :: proc(s: ^Track_Store, pts_ms, dur_ms: i64, key: bool) {
	data := make([]u8, 10, runtime.heap_allocator())
	flags: Sample_Flags
	if key { flags += {.Keyframe} }
	t := Time(pts_ms) * 1_000_000
	d := Time(dur_ms) * 1_000_000
	store_replace_overlap(s, t, t, t + max(d, 1), key)
	store_append(s, Sample{dts = t, pts = t, duration = d, flags = flags, data = data})
}

@(private = "file")
gop :: proc(s: ^Track_Store, start_ms: i64, frames: int) {
	for i in 0 ..< frames { frame(s, start_ms + i64(i) * 100, 100, i == 0) }
}

@(test)
store_sequential_appends_do_not_replace :: proc(t: ^testing.T) {
	s := store_create()
	defer store_destroy(s)
	gop(s, 0, 5)
	gop(s, 500, 5)
	testing.expect_value(t, len(s.frames), 10)
	r := store_ranges(s, 0, context.temp_allocator)
	testing.expect_value(t, len(r), 1)
	testing.expect_value(t, r[0].end, Time(1_000_000_000))
}

@(test)
store_overlapping_group_replaces_what_it_covers :: proc(t: ^testing.T) {
	s := store_create()
	defer store_destroy(s)
	gop(s, 0, 5)
	gop(s, 500, 5)
	gop(s, 1000, 5)
	// a group appended again at 500 ms: the old one at [500, 1000) goes, the one after it stays
	gop(s, 500, 5)
	testing.expect_value(t, len(s.frames), 15)
	r := store_ranges(s, 0, context.temp_allocator)
	testing.expect_value(t, len(r), 1)
	testing.expect_value(t, r[0].start, Time(0))
	testing.expect_value(t, r[0].end, Time(1_500_000_000))
}

@(test)
store_max_end_follows_removals :: proc(t: ^testing.T) {
	s := store_create()
	defer store_destroy(s)
	gop(s, 0, 5)
	gop(s, 500, 5)
	testing.expect_value(t, s.max_end, Time(1_000_000_000))
	store_remove(s, 500_000_000, 1_000_000_000)
	testing.expect_value(t, s.max_end, Time(500_000_000))
	store_clear(s)
	testing.expect_value(t, s.max_end, Time(0))
}
