#+build !windows
package media

// The audio output by cpal (native/media src/aout.rs): the default device, stereo float at the media's rate, a ring the
// player writes into and a device thread that pulls from it and counts audible frames. The counterpart of
// wasapi_windows.odin. On a machine with no device (a server, a CI runner), wm_aout_open fails and backend_linux.odin
// falls back to the null output.

import "wb:base"

foreign import wren_native_media { "../../build/native-" + ODIN_OS_STRING + "/libwren_native.a", "system:opus", "system:asound", "system:dl", "system:pthread", "system:m" }

@(private, default_calling_convention = "c")
foreign wren_native_media {
	wm_aout_open     :: proc(rate: u32, out: ^rawptr) -> i32 ---
	wm_aout_write    :: proc(o: rawptr, samples: [^]f32, len: uint) -> i32 ---
	wm_aout_room     :: proc(o: rawptr) -> i32 ---
	wm_aout_queued   :: proc(o: rawptr) -> i32 ---
	wm_aout_position :: proc(o: rawptr, frames, at: ^i64) ---
	wm_aout_start    :: proc(o: rawptr) ---
	wm_aout_stop     :: proc(o: rawptr) ---
	wm_aout_flush    :: proc(o: rawptr) ---
	wm_aout_set_gain :: proc(o: rawptr, gain: f32) ---
	wm_aout_failed   :: proc(o: rawptr) -> i32 ---
	wm_aout_close    :: proc(o: rawptr) ---
}

@(private)
Cpal_Audio :: struct {
	out: Audio_Output,
	ctx: rawptr,
}

cpal_audio_open :: proc(rate: int) -> ^Audio_Output {
	ctx: rawptr
	if wm_aout_open(u32(rate), &ctx) != 0 || ctx == nil { return nil }
	c := new(Cpal_Audio, base.process_allocator())
	c.ctx = ctx
	o := &c.out
	o.impl, o.rate = c, rate
	o.write, o.room, o.queued, o.position = cpal_write, cpal_room, cpal_queued, cpal_position
	o.start, o.stop, o.flush, o.set_gain, o.failed, o.destroy = cpal_start, cpal_stop, cpal_flush, cpal_set_gain, cpal_failed, cpal_destroy
	return o
}

@(private)
cpal_write :: proc(o: ^Audio_Output, samples: []f32) -> int {
	c := (^Cpal_Audio)(o.impl)
	if len(samples) == 0 { return 0 }
	return int(wm_aout_write(c.ctx, raw_data(samples), uint(len(samples))))
}

@(private)
cpal_room :: proc(o: ^Audio_Output) -> int { return int(wm_aout_room((^Cpal_Audio)(o.impl).ctx)) }

@(private)
cpal_queued :: proc(o: ^Audio_Output) -> int { return int(wm_aout_queued((^Cpal_Audio)(o.impl).ctx)) }

@(private)
cpal_position :: proc(o: ^Audio_Output) -> (frames: i64, at: i64) {
	wm_aout_position((^Cpal_Audio)(o.impl).ctx, &frames, &at)
	return
}

@(private)
cpal_start :: proc(o: ^Audio_Output) { wm_aout_start((^Cpal_Audio)(o.impl).ctx) }

@(private)
cpal_stop :: proc(o: ^Audio_Output) { wm_aout_stop((^Cpal_Audio)(o.impl).ctx) }

@(private)
cpal_flush :: proc(o: ^Audio_Output) { wm_aout_flush((^Cpal_Audio)(o.impl).ctx) }

@(private)
cpal_set_gain :: proc(o: ^Audio_Output, gain: f32) { wm_aout_set_gain((^Cpal_Audio)(o.impl).ctx, gain) }

@(private)
cpal_failed :: proc(o: ^Audio_Output) -> bool { return wm_aout_failed((^Cpal_Audio)(o.impl).ctx) != 0 }

@(private)
cpal_destroy :: proc(o: ^Audio_Output) {
	c := (^Cpal_Audio)(o.impl)
	wm_aout_close(c.ctx)
	free(c, base.process_allocator())
}
