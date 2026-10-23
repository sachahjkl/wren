package media

// The coded frames of one track, in decode order, with the time ranges they cover. It is what a SourceBuffer holds for each
// of its tracks and what a progressive download fills: the container parsers write into it (on the interface thread), the
// player's decode threads read from it, so every operation takes the mutex; the bytes of a frame are shared (reference
// counted) so that a reader keeps its frame after the store removed it.

import "wb:base"
import "core:slice"
import "core:sync"

Blob :: struct {
	rc:   i32,
	data: []u8,
}

blob_new :: proc(data: []u8) -> ^Blob {
	b := new(Blob, base.process_allocator())
	b.rc, b.data = 1, data
	return b
}

blob_ref :: proc(b: ^Blob) { if b != nil { sync.atomic_add(&b.rc, 1) } }

blob_unref :: proc(b: ^Blob) {
	if b == nil { return }
	if sync.atomic_sub(&b.rc, 1) == 1 {
		delete(b.data, base.process_allocator())
		free(b, base.process_allocator())
	}
}

Coded :: struct {
	dts, pts, dur: Time,
	flags:   Sample_Flags,
	config:  u32,
	blob:    ^Blob,
	discard_end: Time,
}

// A frame as a reader sees it: `data` stays valid until coded_release.
coded_sample :: proc(c: Coded) -> Sample {
	return Sample{dts = c.dts, pts = c.pts, duration = c.dur, flags = c.flags, config = c.config, data = c.blob.data, discard_end = c.discard_end}
}

coded_release :: proc(c: ^Coded) {
	blob_unref(c.blob)
	c.blob = nil
}

Range :: struct { start, end: Time }

@(private)
Config_Entry :: struct { id: u32, track: Track }

Track_Store :: struct {
	mu:       sync.Mutex,
	configs:  [dynamic]Config_Entry,
	frames:   [dynamic]Coded,   // by dts
	bytes:    int,
	version:  u64,              // changes with every write
	last_dur: Time,             // the duration of the last frame appended (frames without one take it)
	max_end:  Time,             // the greatest end of a frame in presentation time (0 when empty)
}

store_create :: proc() -> ^Track_Store { return new(Track_Store, base.process_allocator()) }

store_destroy :: proc(s: ^Track_Store) {
	if s == nil { return }
	for &c in s.frames { coded_release(&c) }
	delete(s.frames)
	for &e in s.configs { track_destroy(&e.track) }
	delete(s.configs)
	free(s, base.process_allocator())
}

// A description of the track for the frames that carry `config` (an initialization segment, or a file's header).
store_set_config :: proc(s: ^Track_Store, id: u32, t: Track) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	for &e in s.configs {
		if e.id == id { track_destroy(&e.track); e.track = track_clone(t); return }
	}
	append(&s.configs, Config_Entry{id, track_clone(t)})
	s.version += 1
}

// The track description of a frame's config (a copy that the caller keeps), and whether it exists.
store_track :: proc(s: ^Track_Store, config: u32) -> (Track, bool) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	for e in s.configs { if e.id == config { return track_clone(e.track), true } }
	if len(s.configs) > 0 { return track_clone(s.configs[len(s.configs) - 1].track), true }
	return {}, false
}

// The newest track description, if any.
store_latest_track :: proc(s: ^Track_Store) -> (Track, bool) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if len(s.configs) == 0 { return {}, false }
	return track_clone(s.configs[len(s.configs) - 1].track), true
}

// Takes a coded frame (its data passes to the store). Frames normally arrive in decode order; one that does not is put
// where its decode time says, replacing a frame at the same time.
store_append :: proc(s: ^Track_Store, smp: Sample) {
	c := Coded{dts = smp.dts, pts = smp.pts, dur = smp.duration, flags = smp.flags, config = smp.config, blob = blob_new(smp.data), discard_end = smp.discard_end}
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	s.version += 1
	n := len(s.frames)
	// a frame without a duration takes the gap to the next one (or the last known duration)
	if n > 0 && s.frames[n - 1].dur <= 0 && c.dts > s.frames[n - 1].dts {
		s.frames[n - 1].dur = c.dts - s.frames[n - 1].dts
		s.max_end = max(s.max_end, s.frames[n - 1].pts + s.frames[n - 1].dur)
	}
	if c.dur <= 0 { c.dur = s.last_dur }
	if c.dur > 0 { s.last_dur = c.dur }
	if n == 0 || c.dts > s.frames[n - 1].dts {
		append(&s.frames, c)
	} else {
		i, found := slice.binary_search_by(s.frames[:], c, proc(a, b: Coded) -> slice.Ordering {
			return a.dts < b.dts ? .Less : (a.dts > b.dts ? .Greater : .Equal)
		})
		if found {
			s.bytes -= len(s.frames[i].blob.data)
			coded_release(&s.frames[i])
			s.frames[i] = c
		} else {
			inject_at(&s.frames, i, c)
		}
	}
	s.bytes += len(c.blob.data)
	s.max_end = max(s.max_end, c.pts + c.dur)
}

// Before a frame is appended: what it replaces goes (the coded frame processing of Media Source Extensions: frames
// presented in [pts, end) and what depends on them, up to the next keyframe). Only an append that can overlap pays for
// the scan: one that arrives out of decode order, or a keyframe starting before the end of what is stored.
store_replace_overlap :: proc(s: ^Track_Store, pts, dts, end: Time, keyframe: bool) -> int {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	n := len(s.frames)
	if n == 0 { return 0 }
	if !(dts <= s.frames[n - 1].dts || (keyframe && pts < s.max_end)) { return 0 }
	return store_remove_locked(s, pts, end)
}

// The first frame whose decode time is `dts` or later. The frame is the caller's: coded_release it.
store_get_from :: proc(s: ^Track_Store, dts: Time) -> (c: Coded, ok: bool) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	i, _ := slice.binary_search_by(s.frames[:], dts, proc(a: Coded, t: Time) -> slice.Ordering {
		return a.dts < t ? .Less : (a.dts > t ? .Greater : .Equal)
	})
	if i >= len(s.frames) { return {}, false }
	c = s.frames[i]
	blob_ref(c.blob)
	return c, true
}

// The decode time of the keyframe a decoder must start at to show presentation time `t`: the last keyframe whose
// presentation time is not after it (the first keyframe when there is none before). false: no keyframe at all.
store_keyframe_for :: proc(s: ^Track_Store, t: Time) -> (dts: Time, ok: bool) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	best := -1
	for i in 0 ..< len(s.frames) {
		f := &s.frames[i]
		if .Keyframe not_in f.flags { continue }
		if f.pts <= t { best = i } else if best >= 0 { break } else { best = i; break }
	}
	if best < 0 { return 0, false }
	return s.frames[best].dts, true
}

// Whether the frames are all keyframes (audio: every frame can start a decode).
store_is_all_key :: proc(s: ^Track_Store) -> bool {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	return len(s.frames) > 0 && .Keyframe in s.frames[0].flags && .Keyframe in s.frames[len(s.frames) / 2].flags
}

// The presentation time ranges the frames cover. Frames closer than `tolerance` count as touching.
store_ranges :: proc(s: ^Track_Store, tolerance: Time, allocator := context.allocator) -> []Range {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	// frames by presentation time (decode order differs with B-frames): collect the intervals and merge
	n := len(s.frames)
	if n == 0 { return nil }
	iv := make([]Range, n, context.temp_allocator)
	for f, i in s.frames { iv[i] = Range{max(f.pts, 0), f.pts + max(f.dur, 0)} }
	slice.sort_by(iv, proc(a, b: Range) -> bool { return a.start < b.start })
	out := make([dynamic]Range, 0, 4, allocator)
	cur := iv[0]
	for r in iv[1:] {
		if r.start <= cur.end + tolerance {
			cur.end = max(cur.end, r.end)
		} else {
			append(&out, cur)
			cur = r
		}
	}
	append(&out, cur)
	return out[:]
}

// Removes the frames presented in [start, end), and the frames after them up to the next keyframe (they cannot be
// decoded without what was removed). Returns the bytes freed.
store_remove :: proc(s: ^Track_Store, start, end: Time) -> int {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	return store_remove_locked(s, start, end)
}

@(private)
store_recompute_end :: proc(s: ^Track_Store) {
	s.max_end = 0
	for f in s.frames { s.max_end = max(s.max_end, f.pts + f.dur) }
}

@(private)
store_remove_locked :: proc(s: ^Track_Store, start, end: Time) -> int {
	freed := 0
	w := 0
	cut := false
	for i in 0 ..< len(s.frames) {
		f := s.frames[i]
		in_range := f.pts >= start && f.pts < end
		if in_range { cut = true } else if cut && .Keyframe in f.flags { cut = false }
		if in_range || cut {
			freed += len(f.blob.data)
			c := f
			coded_release(&c)
			continue
		}
		s.frames[w] = f
		w += 1
	}
	resize(&s.frames, w)
	s.bytes -= freed
	if freed > 0 { s.version += 1; store_recompute_end(s) }
	return freed
}

// Removes from the front whole groups of frames (each starting at a keyframe) that end before `t`, until at most
// `keep_bytes` remain or nothing more may go. Returns the bytes freed.
store_evict_before :: proc(s: ^Track_Store, t: Time, keep_bytes: int) -> int {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	// the last keyframe whose presentation time is before t: everything decoded before it can go
	limit := 0
	for i in 0 ..< len(s.frames) {
		f := &s.frames[i]
		if .Keyframe in f.flags {
			if f.pts + f.dur > t || f.pts > t { break }
			limit = i
		}
	}
	if limit == 0 { return 0 }
	freed := 0
	cut := 0
	for cut < limit && s.bytes - freed > keep_bytes {
		// to the next keyframe
		nxt := cut + 1
		for nxt < limit && (.Keyframe not_in s.frames[nxt].flags) { nxt += 1 }
		for k in cut ..< nxt { freed += len(s.frames[k].blob.data) }
		cut = nxt
	}
	if cut == 0 { return 0 }
	for k in 0 ..< cut { coded_release(&s.frames[k]) }
	remove_range(&s.frames, 0, cut)
	s.bytes -= freed
	s.version += 1
	store_recompute_end(s)
	return freed
}

store_clear :: proc(s: ^Track_Store) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	for &c in s.frames { coded_release(&c) }
	clear(&s.frames)
	s.bytes = 0
	s.max_end = 0
	s.version += 1
}

store_bytes :: proc(s: ^Track_Store) -> int {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	return s.bytes
}

store_version :: proc(s: ^Track_Store) -> u64 {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	return s.version
}

// The end of the last frame in presentation time (0 when empty), and the start of the first.
store_extent :: proc(s: ^Track_Store) -> (start, end: Time, ok: bool) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if len(s.frames) == 0 { return 0, 0, false }
	start, end = max(s.frames[0].pts, 0), 0
	for f in s.frames {
		start = min(start, max(f.pts, 0))
		end = max(end, f.pts + max(f.dur, 0))
	}
	return start, end, true
}

// The greatest presentation time at which a frame starts.
store_highest_pts :: proc(s: ^Track_Store) -> (pts: Time, ok: bool) {
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	for f in s.frames { if !ok || f.pts > pts { pts, ok = f.pts, true } }
	return
}

// The sum of presentation time covered contiguously from `t` forward (how far playback can go from t without a gap).
store_buffered_ahead :: proc(s: ^Track_Store, t: Time, tolerance: Time) -> Time {
	r := store_ranges(s, tolerance, context.temp_allocator)
	for x in r { if t >= x.start - tolerance && t < x.end { return x.end - t } }
	return 0
}
