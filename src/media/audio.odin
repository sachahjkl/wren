package media

// The audio output: float PCM, interleaved stereo, played at the rate it was opened with. The player writes decoded audio
// into it (a ring buffer behind the device's thread) and reads where playback is: that position, in frames of audible
// audio (silence the device played while the ring was empty does not count), is what the media clock follows.

Audio_Output :: struct {
	impl:    rawptr,
	rate:    int,
	// Queues interleaved stereo frames (2 floats each); returns how many frames were taken (the ring may be full).
	write:   proc(o: ^Audio_Output, samples: []f32) -> int,
	// Frames the ring can take now, and frames queued (in the ring and the device) that were not played yet.
	room:    proc(o: ^Audio_Output) -> int,
	queued:  proc(o: ^Audio_Output) -> int,
	// Audible frames played since the last flush, and the monotonic time (mono_ns) that count is true at.
	position: proc(o: ^Audio_Output) -> (frames: i64, at: i64),
	start:   proc(o: ^Audio_Output),
	stop:    proc(o: ^Audio_Output),
	// Drops everything queued and the position (a seek, a new stream): the output must be stopped.
	flush:   proc(o: ^Audio_Output),
	// Linear gain, 0 for muted; changes are ramped over a few milliseconds (no click).
	set_gain: proc(o: ^Audio_Output, gain: f32),
	// The device went away (unplugged, format changed): the output is dead, make another.
	failed:  proc(o: ^Audio_Output) -> bool,
	destroy: proc(o: ^Audio_Output),
}

// Mixes interleaved `channels`-channel float audio down (or up) to stereo; the usual coefficients (-3 dB for the center and
// the surrounds, the low-frequency channel dropped). `out` gets frames * 2 floats.
downmix_to_stereo :: proc(in_samples: []f32, channels, frames: int, out: []f32) {
	switch channels {
	case 1:
		for i in 0 ..< frames { out[i * 2], out[i * 2 + 1] = in_samples[i], in_samples[i] }
	case 2:
		copy(out[:frames * 2], in_samples[:frames * 2])
	case:
		// 3 L R C, 4 FL FR BL BR, 5 FL FR C BL BR, 6 (5.1) FL FR C LFE BL BR, 7.1 FL FR C LFE BL BR SL SR
		for i in 0 ..< frames {
			f := in_samples[i * channels:][:channels]
			l, r := f[0], f[1]
			switch channels {
			case 3:
				l += f[2] * 0.7071; r += f[2] * 0.7071
			case 4:
				l += f[2] * 0.7071; r += f[3] * 0.7071
			case 5:
				l += f[2] * 0.7071 + f[3] * 0.7071; r += f[2] * 0.7071 + f[4] * 0.7071
			case 6:
				l += f[2] * 0.7071 + f[4] * 0.7071; r += f[2] * 0.7071 + f[5] * 0.7071
			case:
				if channels >= 8 {
					l += f[2] * 0.7071 + f[4] * 0.7071 + f[6] * 0.7071; r += f[2] * 0.7071 + f[5] * 0.7071 + f[7] * 0.7071
				} else {
					l += f[2] * 0.7071; r += f[2] * 0.7071
				}
			}
			extras: f32 = channels <= 4 ? 1 : (channels <= 6 ? 2 : 3)
			norm := 1 / (1 + 0.7071 * extras)   // (what the added channels cannot make louder than full scale)
			out[i * 2], out[i * 2 + 1] = l * norm, r * norm
		}
	}
}
