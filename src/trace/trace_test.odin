package trace

// The zones' pairing on every path (an early return, an end of a zone not open, recursion, past the depth), the bytes of
// TraceLogging's metadata, the provider's GUID against the SDK's example and the files WPR and WPA read, the enable state.

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"

@(private = "file") WPRP :: #load("../../tools/wren.wprp", string)
@(private = "file") REGIONS :: #load("../../tools/wren_regions.xml", string)
// The example of TraceLoggingProvider.h's documentation: "MyCompany.MyComponent" is {ce5fa4ea-ab00-5402-8b76-9f76ac858fb5}.
@(private = "file") SDK_EXAMPLE_NAME :: "MyCompany.MyComponent"
@(private = "file") SDK_EXAMPLE_GUID :: "ce5fa4ea-ab00-5402-8b76-9f76ac858fb5"
@(private = "file") RANDOM_SEED :: 20261104
@(private = "file") RANDOM_STEPS :: 20_000
@(private = "file") RANDOM_SITES :: 6

// The zones a stack recorded, as begins and ends in order: what Tracy and ETW would receive.
@(private = "file")
Recorder :: struct {
	z:     Zone_Stack,
	open:  [dynamic]^Site,   // what was emitted and not ended, in order
	pairs: int,
	wrong: int,              // an end that is not of the most recent zone emitted
}

@(private = "file")
rec_begin :: proc(r: ^Recorder, s: ^Site) {
	if stack_push(&r.z, s) >= 0 { append(&r.open, s) }
}

@(private = "file")
rec_close :: proc(r: ^Recorder, from: int) {
	for r.z.n > from {
		r.z.n -= 1
		s := r.z.open[r.z.n].site
		if len(r.open) == 0 || pop(&r.open) != s { r.wrong += 1 }
		r.pairs += 1
	}
}

@(private = "file")
rec_end :: proc(r: ^Recorder, s: ^Site) { rec_close(r, stack_closing(&r.z, s)) }

@(private = "file")
rec_end_all :: proc(r: ^Recorder) { r.z.dropped = 0; rec_close(r, 0) }

@(test)
zones_pair_on_every_path :: proc(t: ^testing.T) {
	frame_site, loop, input, call := Site{name = "Frame"}, Site{name = "Loop"}, Site{name = "Input"}, Site{name = "call"}
	r: Recorder
	defer delete(r.open)

	// a frame that returns early leaves Frame and Loop open: the next frame's end_all closes both, innermost first
	rec_begin(&r, &frame_site)
	rec_begin(&r, &loop)
	rec_end_all(&r)
	testing.expect_value(t, r.pairs, 2)
	testing.expect_value(t, len(r.open), 0)

	// an end closes what was begun after its zone; an end of a zone not open closes nothing
	rec_begin(&r, &frame_site)
	rec_begin(&r, &loop)
	rec_begin(&r, &input)
	rec_end(&r, &loop)
	testing.expect_value(t, r.z.n, 1)
	rec_end(&r, &input)
	testing.expect_value(t, r.z.n, 1)

	// recursion: the end is the most recent zone of its site's
	rec_begin(&r, &call)
	rec_begin(&r, &call)
	rec_end(&r, &call)
	testing.expect_value(t, r.z.n, 2)
	rec_end(&r, &call)
	rec_end(&r, &frame_site)
	testing.expect_value(t, r.z.n, 0)

	// past the depth: not recorded, and their ends close nothing recorded
	for _ in 0 ..< ZONE_DEPTH + 3 { rec_begin(&r, &call) }
	testing.expect_value(t, r.z.n, ZONE_DEPTH)
	for _ in 0 ..< 3 { rec_end(&r, &call) }
	testing.expect_value(t, r.z.n, ZONE_DEPTH)
	for _ in 0 ..< ZONE_DEPTH { rec_end(&r, &call) }
	testing.expect_value(t, r.z.n, 0)
	testing.expect_value(t, r.wrong, 0)

	// any sequence at all: every zone emitted ends once, the most recent first
	sites: [RANDOM_SITES]Site
	for &s, i in sites { s.name = strings.clone_to_cstring(fmt.tprintf("site%d", i), context.temp_allocator) }
	gen := rand.create(RANDOM_SEED)
	context.random_generator = rand.default_random_generator(&gen)
	begun := 0
	for _ in 0 ..< RANDOM_STEPS {
		s := &sites[rand.int_max(RANDOM_SITES)]
		switch rand.int_max(10) {
		case 0:       rec_end_all(&r)
		case 1 ..= 5: if r.z.n < ZONE_DEPTH { begun += 1 }; rec_begin(&r, s)
		case:         rec_end(&r, s)
		}
	}
	rec_end_all(&r)
	testing.expect_value(t, r.wrong, 0)
	testing.expect_value(t, len(r.open), 0)
	testing.expectf(t, r.pairs >= begun, "every zone begun ended: %d pairs, %d begun", r.pairs, begun)
}

@(test)
tracelogging_metadata_bytes :: proc(t: ^testing.T) {
	buf: [ETW_EVENT_BYTES]u8
	n := event_metadata(buf[:], "Frame", nil)
	testing.expect_value(t, n, 9)
	testing.expect(t, string(buf[:n]) == "\x09\x00\x00Frame\x00", "size, no tags, the name nul-terminated")

	fields := [1]Field{{name = "Name", in_type = IN_ANSISTRING, out_type = OUT_UTF8}}
	n = event_metadata(buf[:], "Mark", fields[:])
	testing.expect_value(t, n, 15)
	testing.expect(t, string(buf[:n]) == "\x0f\x00\x00Mark\x00Name\x00\x82\x23", "a field: its name, its in type chained to its out type")

	plain := [1]Field{{name = "n", in_type = IN_ANSISTRING}}
	n = event_metadata(buf[:], "E", plain[:])
	testing.expect(t, string(buf[:n]) == "\x08\x00\x00E\x00n\x00\x02", "a field without an out type: its in type alone")

	testing.expect_value(t, event_metadata(buf[:], strings.repeat("x", ETW_EVENT_BYTES, context.temp_allocator), nil), 0)

	traits: [ETW_TRAITS_BYTES]u8
	n = provider_traits(traits[:], PROVIDER_NAME)
	testing.expect(t, string(traits[:n]) == "\x0f\x00Wren.Browser\x00", "the provider's traits: size and name")
}

@(private = "file")
guid_text :: proc(g: [16]u8) -> string {
	return fmt.tprintf("%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x", u32(g[0]) | u32(g[1]) << 8 | u32(g[2]) << 16 | u32(g[3]) << 24,
		u16(g[4]) | u16(g[5]) << 8, u16(g[6]) | u16(g[7]) << 8, g[8], g[9], g[10], g[11], g[12], g[13], g[14], g[15])
}

@(test)
provider_guid_is_the_name_hash :: proc(t: ^testing.T) {
	testing.expect_value(t, guid_text(provider_guid_of(SDK_EXAMPLE_NAME)), SDK_EXAMPLE_GUID)
	testing.expect_value(t, guid_text(provider_guid_of("mycompany.MyComponent")), SDK_EXAMPLE_GUID)   // (the hash upper-cases the name)
	ours := guid_text(provider_guid_of(PROVIDER_NAME))
	testing.expectf(t, strings.contains(WPRP, ours), "tools/wren.wprp names the provider by its GUID %s", ours)
	testing.expectf(t, strings.count(REGIONS, ours) > 0, "tools/wren_regions.xml's events are the provider's (%s)", ours)
}

@(test)
enable_state_follows_the_sessions :: proc(t: ^testing.T) {
	s: Enable_State
	testing.expect(t, !enable_allows(&s, LEVEL_VERBOSE, KEYWORD_ZONES), "no session: nothing")
	enable_update(&s, 1, LEVEL_VERBOSE, KEYWORD_ZONES | KEYWORD_FRAMES, 0)
	testing.expect(t, enable_allows(&s, LEVEL_VERBOSE, KEYWORD_ZONES) && enable_allows(&s, LEVEL_VERBOSE, KEYWORD_FRAMES), "the keywords asked for")
	testing.expect(t, !enable_allows(&s, LEVEL_VERBOSE, KEYWORD_MARKS), "not the others")
	enable_update(&s, 1, LEVEL_VERBOSE - 1, 0, 0)
	testing.expect(t, !enable_allows(&s, LEVEL_VERBOSE, KEYWORD_ZONES), "a verbose event above the level asked")
	enable_update(&s, 1, 0, 0, 0)
	testing.expect(t, enable_allows(&s, LEVEL_VERBOSE, KEYWORD_MARKS), "level 0 and no keyword: everything")
	enable_update(&s, 2, 0, 0, 0)
	testing.expect(t, enable_allows(&s, LEVEL_VERBOSE, KEYWORD_MARKS), "a request for state changes nothing")
	enable_update(&s, 0, 0, 0, 0)
	testing.expect(t, !enable_allows(&s, LEVEL_VERBOSE, KEYWORD_MARKS), "the session stopped")
}
