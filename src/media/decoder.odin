package media

// The decoder interfaces. A backend (Media Foundation on Windows) makes decoders for the tracks it supports; the player
// only talks to these procedures. Decoders are not thread-safe: one thread drives each (the player's decode threads).

Pixel_Format :: enum u8 {
	None,
	NV12,      // 8 bits, planes: Y, then interleaved UV (4:2:0)
	P010,      // 10 bits in the high bits of 16-bit words, same layout
	I420,      // 8 bits, three planes Y U V (4:2:0)
	I420_10,   // 10 bits in 16-bit words, three planes
}

// A decoded picture. Either on the GPU (`gpu`: a Direct3D 11 texture of the device the decoders were made on, which the
// renderer converts and draws without a copy through the CPU) or in memory (`planes`). release() gives everything
// back; the decoder's surface pool is exhausted when too many frames are kept.
Video_Frame :: struct {
	pts, duration: Time,
	format:   Pixel_Format,
	width, height: int,         // the visible picture (after cropping)
	crop:     [2]int,           // offset of the visible picture in the surface
	surface:  [2]int,           // size of the surface (planes) the picture is cut from
	color:    Color_Info,
	rotation: int,
	// GPU
	gpu_texture: rawptr,        // ID3D11Texture2D (borrowed: valid until release)
	gpu_index:   u32,           // array slice of the texture
	// CPU
	planes:   [3][]u8,
	strides:  [3]int,
	// ownership
	backend:  rawptr,
	release:  proc(f: ^Video_Frame),
	dropped:  bool,             // decoded for reference only (before the seek target)
}

frame_release :: proc(f: ^Video_Frame) {
	if f.release != nil { f.release(f) }
	f^ = {}
}

Pull_Result :: enum u8 {
	Frame,           // a picture came out
	Need_Input,      // feed more samples
	Format_Changed,  // a new output format (size): call again
	Error,
}

Video_Decoder :: struct {
	impl:     rawptr,
	hardware: bool,       // decodes on the GPU
	name:     string,
	// Gives a coded sample; false: refused because pictures are waiting (pull first).
	push:     proc(d: ^Video_Decoder, s: ^Sample) -> bool,
	pull:     proc(d: ^Video_Decoder, out: ^Video_Frame) -> Pull_Result,
	// Drops everything in flight (a seek); the next sample must be a keyframe.
	flush:    proc(d: ^Video_Decoder),
	// No more input for now: pictures still held come out through pull until Need_Input.
	drain:    proc(d: ^Video_Decoder),
	destroy:  proc(d: ^Video_Decoder),
}

// 32-bit float PCM, interleaved.
Audio_Block :: struct {
	pts:       Time,
	frames:    int,
	channels:  int,
	rate:      int,
	samples:   []f32,    // frames * channels, heap
}

audio_block_destroy :: proc(b: ^Audio_Block) {
	delete(b.samples)
	b^ = {}
}

Audio_Decoder :: struct {
	impl:    rawptr,
	name:    string,
	push:    proc(d: ^Audio_Decoder, s: ^Sample) -> bool,
	pull:    proc(d: ^Audio_Decoder, out: ^Audio_Block) -> Pull_Result,
	flush:   proc(d: ^Audio_Decoder),
	drain:   proc(d: ^Audio_Decoder),
	destroy: proc(d: ^Audio_Decoder),
}

// What the platform can do, asked before a source is accepted (isTypeSupported, canPlayType) and before a decoder is made.
Decoder_Support :: struct {
	supported: bool,
	hardware:  bool,
}
