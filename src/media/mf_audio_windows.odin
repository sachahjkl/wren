#+build windows
package media

// Audio decoding with a Media Foundation transform (AAC, Opus, MP3, FLAC: whichever the system has). The output is
// 32-bit float PCM.

import "base:runtime"
import "core:mem"

@(private)
MF_Audio :: struct {
	mft:      ^IMFTransform,
	track:    Track,
	float:    bool,         // the transform outputs 32-bit float (else 16-bit integer)
	channels: int,
	rate:     int,
	provides: bool,
	out_bytes: u32,
	next_pts: Time,
	have_pts: bool,
	discont:  bool,
	skip_ns:  Time,         // the pre-skip of Opus: dropped from the start of the stream
	skipped:  bool,
}

@(private)
audio_subtype :: proc(codec: Codec) -> (GUID, bool) {
	#partial switch codec {
	case .AAC: return MFAudioFormat_AAC, true
	case .Opus: return MFAudioFormat_Opus, true
	case .MP3: return MFAudioFormat_MP3, true
	case .FLAC: return MFAudioFormat_FLAC, true
	}
	return {}, false
}

mf_audio_supported :: proc(codec: Codec) -> Decoder_Support {
	sub, ok := audio_subtype(codec)
	if !ok || !mf_startup() { return {} }
	acts, n := enum_transforms(MFT_CATEGORY_AUDIO_DECODER, MFMediaType_Audio, sub)
	defer free_activates(acts, n)
	for i in 0 ..< int(n) {
		if is_async(acts[i]) { continue }
		return {supported = true}
	}
	return {}
}

mf_audio_create :: proc(track: Track) -> ^Audio_Decoder {
	if !mf_startup() { return nil }
	com_thread_init()
	sub, ok := audio_subtype(track.codec)
	if !ok { return nil }
	acts, n := enum_transforms(MFT_CATEGORY_AUDIO_DECODER, MFMediaType_Audio, sub)
	defer free_activates(acts, n)
	mft: ^IMFTransform
	for i in 0 ..< int(n) {
		if is_async(acts[i]) { continue }
		if hr_ok(acts[i]->ActivateObject(&IID_IMFTransform, (^rawptr)(&mft))) && mft != nil { break }
	}
	if mft == nil { return nil }
	a := new(MF_Audio, runtime.heap_allocator())
	a.mft = mft
	a.track = track_clone(track)
	a.channels = max(track.channels, 1)
	a.rate = max(track.sample_rate, 8000)
	a.discont = true
	a.skip_ns = track.codec_delay
	if !mf_audio_input_type(a, sub) || !mf_audio_output_type(a) {
		mf_audio_free(a)
		return nil
	}
	mft->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)
	mft->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)
	d := new(Audio_Decoder, runtime.heap_allocator())
	d.impl = a
	d.name = "Media Foundation"
	d.push = mf_audio_push
	d.pull = mf_audio_pull
	d.flush = mf_audio_flush
	d.drain = mf_audio_drain
	d.destroy = mf_audio_destroy
	return d
}

@(private)
mf_audio_input_type :: proc(a: ^MF_Audio, sub: GUID) -> bool {
	t: ^IMFMediaType
	if !hr_ok(MFCreateMediaType(&t)) { return false }
	defer com_release(t)
	major, subtype := MFMediaType_Audio, sub
	t->SetGUID(&MF_MT_MAJOR_TYPE, &major)
	t->SetGUID(&MF_MT_SUBTYPE, &subtype)
	t->SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, u32(a.channels))
	t->SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, u32(a.rate))
	t->SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, 16)
	#partial switch a.track.codec {
	case .AAC:
		t->SetUINT32(&MF_MT_AAC_PAYLOAD_TYPE, 0)   // raw access units
		t->SetUINT32(&MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION, 0x29)
		// HEAACWAVEINFO after its WAVEFORMATEX, then the AudioSpecificConfig
		ud := make([dynamic]u8, 0, 12 + len(a.track.config), context.temp_allocator)
		append(&ud, 0, 0, 0x29, 0, 0, 0, 0, 0, 0, 0, 0, 0)
		append(&ud, ..a.track.config)
		t->SetBlob(&MF_MT_USER_DATA, raw_data(ud), u32(len(ud)))
	case .Opus, .FLAC:
		if len(a.track.config) > 0 { t->SetBlob(&MF_MT_USER_DATA, raw_data(a.track.config), u32(len(a.track.config))) }
	}
	return hr_ok(a.mft->SetInputType(0, t, 0))
}

@(private)
mf_audio_output_type :: proc(a: ^MF_Audio) -> bool {
	best: ^IMFMediaType
	best_float := false
	for i: u32 = 0; ; i += 1 {
		t: ^IMFMediaType
		if !hr_ok(a.mft->GetOutputAvailableType(0, i, &t)) { break }
		sub: GUID
		t->GetGUID(&MF_MT_SUBTYPE, &sub)
		bits: u32
		t->GetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, &bits)
		is_float := sub == MFAudioFormat_Float && bits == 32
		is_pcm16 := sub == MFAudioFormat_PCM && bits == 16
		if is_float || (is_pcm16 && best == nil) {
			if best != nil { com_release(best) }
			best, best_float = t, is_float
			if is_float { break }
			continue
		}
		com_release(t)
	}
	if best == nil { return false }
	defer com_release(best)
	if !hr_ok(a.mft->SetOutputType(0, best, 0)) { return false }
	a.float = best_float
	return mf_audio_read_output(a)
}

@(private)
mf_audio_read_output :: proc(a: ^MF_Audio) -> bool {
	t: ^IMFMediaType
	if !hr_ok(a.mft->GetOutputCurrentType(0, &t)) || t == nil { return false }
	defer com_release(t)
	ch, rate: u32
	t->GetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, &ch)
	t->GetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate)
	if ch > 0 { a.channels = int(ch) }
	if rate > 0 { a.rate = int(rate) }
	info: MFT_OUTPUT_STREAM_INFO
	a.mft->GetOutputStreamInfo(0, &info)
	a.provides = info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES) != 0
	a.out_bytes = max(info.cbSize, 8192)
	return true
}

@(private)
mf_audio_push :: proc(d: ^Audio_Decoder, s: ^Sample) -> bool {
	a := (^MF_Audio)(d.impl)
	if len(s.data) == 0 { return true }
	buf: ^IMFMediaBuffer
	if !hr_ok(MFCreateMemoryBuffer(u32(len(s.data)), &buf)) { return true }
	defer com_release(buf)
	dst: [^]u8
	if !hr_ok(buf->Lock(&dst, nil, nil)) { return true }
	mem.copy(dst, raw_data(s.data), len(s.data))
	buf->Unlock()
	buf->SetCurrentLength(u32(len(s.data)))
	sample: ^IMFSample
	if !hr_ok(MFCreateSample(&sample)) { return true }
	defer com_release(sample)
	sample->AddBuffer(buf)
	sample->SetSampleTime(i64(s.pts) / 100)
	if s.duration > 0 { sample->SetSampleDuration(i64(s.duration) / 100) }
	if a.discont { sample->SetUINT32(&MFSampleExtension_Discontinuity, 1) }
	hr := a.mft->ProcessInput(0, sample, 0)
	if hr == MF_E_NOTACCEPTING { return false }
	if !a.have_pts { a.next_pts, a.have_pts = s.pts, true }
	a.discont = false
	return true
}

@(private)
mf_audio_pull :: proc(d: ^Audio_Decoder, out: ^Audio_Block) -> Pull_Result {
	a := (^MF_Audio)(d.impl)
	for {
		buffers := MFT_OUTPUT_DATA_BUFFER{}
		own: ^IMFSample
		if !a.provides {
			if !hr_ok(MFCreateSample(&own)) { return .Error }
			b: ^IMFMediaBuffer
			if !hr_ok(MFCreateMemoryBuffer(a.out_bytes, &b)) { com_release(own); return .Error }
			own->AddBuffer(b)
			com_release(b)
			buffers.pSample = own
		}
		status: u32
		hr := a.mft->ProcessOutput(0, 1, &buffers, &status)
		if hr == MF_E_TRANSFORM_NEED_MORE_INPUT { com_release(own); return .Need_Input }
		if hr == MF_E_TRANSFORM_STREAM_CHANGE {
			com_release(own)
			if !mf_audio_output_type(a) { return .Error }
			return .Format_Changed
		}
		if !hr_ok(hr) { com_release(own); return .Error }
		sample := buffers.pSample
		if sample == nil { com_release(own); return .Need_Input }
		got := mf_audio_block(a, sample, out)
		com_release(sample)
		if own != nil && own != sample { com_release(own) }
		if got { return .Frame }
		// an empty or entirely skipped block: ask again
	}
}

// One output sample as a float block. false: nothing to give (the Opus pre-skip swallowed it).
@(private)
mf_audio_block :: proc(a: ^MF_Audio, sample: ^IMFSample, out: ^Audio_Block) -> bool {
	buf: ^IMFMediaBuffer
	if !hr_ok(sample->ConvertToContiguousBuffer(&buf)) || buf == nil { return false }
	defer com_release(buf)
	p: [^]u8
	cur: u32
	if !hr_ok(buf->Lock(&p, nil, &cur)) { return false }
	defer buf->Unlock()
	bytes_per := a.float ? 4 : 2
	frames := int(cur) / (bytes_per * a.channels)
	if frames <= 0 { return false }
	t: i64
	have_t := hr_ok(sample->GetSampleTime(&t))
	pts := have_t ? Time(t * 100) : a.next_pts
	samples := make([]f32, frames * a.channels)
	if a.float {
		mem.copy(raw_data(samples), p, frames * a.channels * 4)
	} else {
		src := ([^]i16)(p)
		for i in 0 ..< frames * a.channels { samples[i] = f32(src[i]) / 32768 }
	}
	a.next_pts = pts + Time(i64(frames) * NS_PER_S / i64(a.rate))
	skip := 0
	if !a.skipped && a.skip_ns > 0 {
		skip = min(frames, int(i64(a.skip_ns) * i64(a.rate) / NS_PER_S))
		a.skipped = true
	}
	if skip >= frames { delete(samples); return false }
	if skip > 0 {
		trimmed := make([]f32, (frames - skip) * a.channels)
		copy(trimmed, samples[skip * a.channels:])
		delete(samples)
		samples = trimmed
		pts += Time(i64(skip) * NS_PER_S / i64(a.rate))
		frames -= skip
	}
	out^ = Audio_Block{pts = pts, frames = frames, channels = a.channels, rate = a.rate, samples = samples}
	return true
}

@(private)
mf_audio_flush :: proc(d: ^Audio_Decoder) {
	a := (^MF_Audio)(d.impl)
	a.mft->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0)
	a.discont = true
	a.have_pts = false
}

@(private)
mf_audio_drain :: proc(d: ^Audio_Decoder) {
	a := (^MF_Audio)(d.impl)
	a.mft->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0)
}

@(private)
mf_audio_free :: proc(a: ^MF_Audio) {
	if a.mft != nil {
		a.mft->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0)
		com_release(a.mft)
	}
	track_destroy(&a.track)
	free(a, runtime.heap_allocator())
}

@(private)
mf_audio_destroy :: proc(d: ^Audio_Decoder) {
	mf_audio_free((^MF_Audio)(d.impl))
	free(d, runtime.heap_allocator())
}
