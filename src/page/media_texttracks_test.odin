package page

import "base:runtime"
import "core:testing"
import "wb:base"
import "wb:fetch"
import "wb:host"

// A script that makes a cue, adds it to a track and forgets it: the collector lets go of the wrapper, which owned the object, and the track went on listing freed memory
// (npr.org on pages of their own: TextTrackCueList.item read the block). The track holds it from then on; taking it out of the track frees it.
@(test)
a_cue_lives_on_in_its_track_when_its_script_forgets_it :: proc(t: ^testing.T) {
	test_pages(t)
	context.allocator = runtime.heap_allocator()   // (the tree builder's Lexbor callbacks use the process heap)
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	loader := fetch.Loader{loop = &loop}
	settings := settings_default()
	defer settings_destroy(&settings)
	scope := base.scope_make("test")
	defer base.scope_close(scope)
	p := page_create(&loop, &loader, &settings, scope, "http://example.test/cues.html")

	tt := new(Text_Track_Object)
	tt.page = p
	tt.cues = make([dynamic]^Text_Cue_Object)
	tt.self = object_create(p, &text_track_vt, tt, 0)
	c := Call{page = p, caller = p}
	h, made := VTTCue_create(&c, 1, 2, "words")
	testing.expect_value(t, made, Api_Error.None)
	cue := lookup_TextTrackCue(&c, h)
	testing.expect_value(t, TextTrack_addCue(&c, {tt.self, tt}, {h, cue}), Api_Error.None)

	testing.expect_value(t, Object_release(&c, {handle = h}), Api_Error.None)
	testing.expect(t, lookup_TextTrackCue(&c, h) == cue, "the track still has it")
	list := Text_Cue_List_Object{page = p, track = tt}
	got, found := TextTrackCueList_item(&c, {0, &list}, 0)
	testing.expect_value(t, found, Api_Error.None)
	testing.expect_value(t, got, h)

	testing.expect_value(t, TextTrack_removeCue(&c, {tt.self, tt}, {h, cue}), Api_Error.None)
	testing.expect(t, lookup_TextTrackCue(&c, h) == nil, "out of the track, nothing holds it")

	// a cue in no track goes with its wrapper
	loose, _ := VTTCue_create(&c, 1, 2, "words")
	testing.expect_value(t, Object_release(&c, {handle = loose}), Api_Error.None)
	testing.expect(t, lookup_TextTrackCue(&c, loose) == nil, "nothing holds a cue in no track")
}
