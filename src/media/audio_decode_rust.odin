#+build !windows
package media

// Audio decoding by native/media (src/audio.rs): Symphonia for AAC-LC, MP3, FLAC, Vorbis and PCM, libopus for Opus,
// behind the Audio_Decoder interface. The decoder of a system without one of its own (Linux), the counterpart of
// mf_audio_windows.odin. Decoded blocks (interleaved 32-bit float) live in the Rust decoder until the next pull or
// until the decoder is destroyed, so the Odin side copies them into an Audio_Block it owns.

import "wb:base"

foreign import wren_native_media { "../../build/native-" + ODIN_OS_STRING + "/libwren_native.a", "system:opus", "system:asound", "system:dl", "system:pthread", "system:m" }

@(private)
Rust_Audio_Block :: struct {
	pts:      i64,
	frames:   u32,
	channels: u32,
	rate:     u32,
	samples:  [^]f32,
}

@(private, default_calling_convention = "c")
foreign wren_native_media {
	wm_audio_open      :: proc(codec: u32, config: [^]u8, config_len: uint, rate, channels, pre_skip: u32, out: ^rawptr) -> i32 ---
	wm_audio_send      :: proc(d: rawptr, data: [^]u8, len: uint, pts: i64) -> i32 ---
	wm_audio_get       :: proc(d: rawptr, blk: ^Rust_Audio_Block) -> i32 ---
	wm_audio_taken     :: proc(d: rawptr) ---
	wm_audio_flush     :: proc(d: rawptr) ---
	wm_audio_close     :: proc(d: rawptr) ---
	wm_audio_supported :: proc(codec: u32) -> i32 ---
}

@(private)
Rust_Audio :: struct {
	ctx:   rawptr,
	track: Track,
	block: Audio_Block,   // the last block copied out of Rust (its memory is reused across pulls)
	have:  bool,          // a block is in `block`, not yet taken by pull's caller
}

rust_audio_supported :: proc(codec: Codec) -> Decoder_Support {
	return {supported = wm_audio_supported(u32(codec)) != 0}
}

rust_audio_create :: proc(track: Track) -> ^Audio_Decoder {
	pre_skip: u32
	if track.codec == .Opus {
		// codec_delay is the pre-skip as a Time (ticks at 48 kHz turned to ns by mp4.odin); back to 48 kHz samples.
		pre_skip = u32(i64(track.codec_delay) * 48000 / NS_PER_S)
	}
	ctx: rawptr
	cfg := raw_data(track.config)
	if wm_audio_open(u32(track.codec), cfg, uint(len(track.config)), u32(track.sample_rate), u32(track.channels), pre_skip, &ctx) != 0 || ctx == nil {
		return nil
	}
	a := new(Rust_Audio, base.process_allocator())
	a.ctx = ctx
	a.track = track_clone(track)
	d := new(Audio_Decoder, base.process_allocator())
	d.impl = a
	d.name = "Symphonia/libopus"
	d.push = rust_audio_push
	d.pull = rust_audio_pull
	d.flush = rust_audio_flush
	d.drain = rust_audio_drain
	d.destroy = rust_audio_destroy
	return d
}

@(private)
rust_audio_push :: proc(d: ^Audio_Decoder, s: ^Sample) -> bool {
	a := (^Rust_Audio)(d.impl)
	if len(s.data) == 0 { return true }
	r := wm_audio_send(a.ctx, raw_data(s.data), uint(len(s.data)), i64(s.pts))
	return r != 1   // 1: refused (pull first); an error drops the sample, playback recovers at the next one
}

@(private)
rust_audio_pull :: proc(d: ^Audio_Decoder, out: ^Audio_Block) -> Pull_Result {
	a := (^Rust_Audio)(d.impl)
	// Hand back a block already copied (push produced one that pull has not emitted yet).
	if a.have {
		out^ = a.block
		a.block = {}
		a.have = false
		wm_audio_taken(a.ctx)
		return .Frame
	}
	blk: Rust_Audio_Block
	switch wm_audio_get(a.ctx, &blk) {
	case 0:
	case 1: return .Need_Input
	case:   return .Error
	}
	n := int(blk.frames) * int(blk.channels)
	if n == 0 {
		wm_audio_taken(a.ctx)
		return .Need_Input
	}
	samples := make([]f32, n, base.process_allocator())
	copy(samples, blk.samples[:n])
	out^ = Audio_Block{
		pts = Time(blk.pts),
		frames = int(blk.frames),
		channels = int(blk.channels),
		rate = int(blk.rate),
		samples = samples,
	}
	wm_audio_taken(a.ctx)
	return .Frame
}

@(private)
rust_audio_flush :: proc(d: ^Audio_Decoder) {
	a := (^Rust_Audio)(d.impl)
	if a.have { audio_block_destroy(&a.block); a.have = false }
	wm_audio_flush(a.ctx)
}

// No more input: Symphonia and libopus are packet decoders with no tail to drain (a block comes out per frame).
@(private)
rust_audio_drain :: proc(d: ^Audio_Decoder) {}

@(private)
rust_audio_destroy :: proc(d: ^Audio_Decoder) {
	a := (^Rust_Audio)(d.impl)
	if a.have { audio_block_destroy(&a.block) }
	wm_audio_close(a.ctx)
	track_destroy(&a.track)
	free(a, base.process_allocator())
	free(d, base.process_allocator())
}
