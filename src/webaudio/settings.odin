// Package webaudio: the render graph of the Web Audio API, on the browser's side, with no JavaScript in it.
//
//   bus.odin         blocks of 128 frames, planar, and the specification's up-mix and down-mix rules
//   param.odin       AudioParam: the timeline of automation events, a-rate and k-rate
//   graph.odin       nodes and connections, the order of processing, one render quantum
//   nodes*.odin      what each node computes (sources, filters, panners, the compressor, the analyser...)
//   wave.odin        the band-limited tables of oscillators (PeriodicWave); fft.odin the FFT they and others use
//   render.odin      the threads: a running AudioContext writes to a media.Audio_Output, an offline one fills a buffer
//   decode.odin      decodeAudioData: containers and decoders of src/media, then the context's sample rate
//
// src/page/bindings_webaudio.odin wires a page to this; native/js/odin/web_audio.js is what a script sees. A graph is
// used by the page's thread and its render thread: everything goes through Graph.mu, held for at most a quantum.
package webaudio

import "wb:config"

// The size of a render quantum, in frames (the specification's default, the only one here).
RENDER_QUANTUM :: 128
// The most channels a bus or an AudioBuffer has, and the range of sample rates (Web Audio API, "createBuffer").
MAX_CHANNELS :: 32
MIN_SAMPLE_RATE :: 3000
MAX_SAMPLE_RATE :: 768000
// The audio output plays stereo (media.Audio_Output): what destination.maxChannelCount says for a running context.
OUTPUT_CHANNELS :: 2

Settings :: struct {
	enabled:          bool,   // the interfaces exist at all
	latency_ms:       f64,    // audio queued ahead of the device for latencyHint "interactive"
	default_rate:     f64,    // sampleRate of a context that does not ask for one
	max_buffer_bytes: int,    // the samples of one AudioBuffer or OfflineAudioContext
	max_contexts:     int,    // running AudioContexts of a page
}

WEBAUDIO_PREFS := [?]config.Def{
	{name = "webaudio.enabled", kind = .Bool, default = {b = true},
		description = "The Web Audio API (AudioContext and its nodes). Off: the interfaces do not exist, as in a browser without it."},
	{name = "webaudio.latency_ms", kind = .Float, default = {f = 30}, bounded = true, min = 5, max = 1000, unit = "ms",
		description = "Audio a running AudioContext keeps queued ahead of the device for latencyHint \"interactive\" (\"balanced\" is twice that, \"playback\" four times). Lower answers sooner and may crackle on a busy machine."},
	{name = "webaudio.sample_rate", kind = .Float, default = {f = 48000}, bounded = true, min = MIN_SAMPLE_RATE, max = MAX_SAMPLE_RATE, unit = "Hz",
		description = "The sample rate of an AudioContext that does not ask for one (the audio engine converts it to the device's)."},
	{name = "webaudio.max_buffer_mb", kind = .Int, default = {i = 1024}, bounded = true, min = 1, max = 1 << 20, unit = "MB",
		description = "Largest AudioBuffer or OfflineAudioContext rendering (all channels). Past it, creation fails with NotSupportedError."},
	{name = "webaudio.max_contexts", kind = .Int, default = {i = 64}, bounded = true, min = 1, max = 4096,
		description = "Most AudioContexts a page may have open at once (each running one has a thread and an audio stream). Past it, new AudioContext() fails with NotSupportedError."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, WEBAUDIO_PREFS[:]) }

settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	return Settings{
		enabled          = config.bool_of(p, "webaudio.enabled"),
		latency_ms       = config.float_of(p, "webaudio.latency_ms"),
		default_rate     = config.float_of(p, "webaudio.sample_rate"),
		max_buffer_bytes = int(config.int_of(p, "webaudio.max_buffer_mb")) << 20,
		max_contexts     = int(config.int_of(p, "webaudio.max_contexts")),
	}
}
