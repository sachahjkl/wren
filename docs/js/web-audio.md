# Web Audio

`AudioContext`, `OfflineAudioContext`, their nodes and `decodeAudioData`. What a script sees is JavaScript
(`native/js/odin/web_audio.js`, evaluated the first time a realm of a window reads one of the interfaces: a page that never asks
pays nothing). The graph, its threads and every computation are the browser's: `src/webaudio`, a package with no JavaScript in
it and its own unit tests. `src/page/bindings_webaudio.odin` and `api/webaudio.widl` are between the two.

## The render graph

A node is a number of a graph; a graph is a host object of the page. The page's thread and the render thread share the graph
under one lock, which the render thread holds for one quantum (128 frames) at a time.

- **A running `AudioContext`** has one thread and one `media.Audio_Output` (`backend_audio_output`: WASAPI on Windows, cpal on
  Linux, the null output with `WREN_AUDIO_OUTPUT=null` or no device). The thread keeps the output's queue at the latency asked
  for, a quantum at a time: the device's clock paces the rendering, and so `currentTime`. Suspending ends the thread and closes
  the stream.
- **An `OfflineAudioContext`** has a thread until its rendering is over, as fast as it goes. `suspend(t)` stops it at a quantum
  (rounded up) until `resume()`.
- **The order of processing** is recomputed when connections change: every node runs, a source with nowhere to go still ends and
  an analyser still listens. A cycle goes through a `DelayNode` (read at its turn, written at the end of the quantum: at least a
  quantum of delay), or is muted.
- **A node leaves its graph** when its JavaScript object has been collected and nothing can come out of it: no input, no source at
  work, a delay's or convolver's tail over. Thousands of one-shot sounds leave nothing behind. (A cycle whose objects are all gone
  stays until the context closes.)

A page leaving or a tab closing destroys its graphs with its objects: the thread is joined there. The render thread gives the
page's thread ids, never pointers (`Web_Audio_Token`).

## Buffers: what a Float32Array is, and what the render sees

Each realm's memory is a Wasm instance, which the render thread does not read. An `AudioBuffer` has its samples in one of two places:

- `getChannelData` gives a real `Float32Array` of the realm, made on first asking;
- the browser has an immutable-while-shared block (`Pcm`), which graphs hold references to.

`start()` (and `buffer =` after it, and a convolver's `buffer =`) is the specification's "acquire the content": the arrays' samples
go to the browser, only when they differ from what is there, and a block that a graph is playing is copied first. From then on the
script's arrays are its own, and `getChannelData` makes new ones: what is written to the old ones is not heard. An array transferred
away makes the buffer play nothing. A buffer from `decodeAudioData` or a rendering stays in the browser until a script reads it, so
a game's decoded sounds cost the realm nothing.

## Autoplay

`media.autoplay.policy`: `allow-all` starts a context at once; `allow-muted` and `block` leave it `suspended` until the page has had
a click or a key press (the same sticky activation as media elements), at which point every context that wants to run starts, with
or without another `resume()`. Its pending `resume()` promises settle then.

The tab's mute silences the contexts' outputs without the page knowing, and a context that gives sound shows the tab's speaker.

## decodeAudioData

A blocking thread of the page's pool decodes the whole file, then converts it to the context's rate (a windowed sinc). MP4 and WebM go
through the demuxers of `src/media`; WAV (PCM, float, A-law, mu-law), MP3, ADTS AAC, FLAC and Ogg (Opus, Vorbis) are cut into packets in
`src/webaudio/decode.odin`, and the packets go to the decoders of `src/media`: Media Foundation on Windows, Symphonia and libopus on
Linux. Vorbis has no decoder on Windows. The argument is detached at the call, as specified.

## What each node does

| Interface | |
|---|---|
| `AudioParam` | every automation method, a-rate and k-rate; events inside a value curve throw `NotSupportedError`; connections add to the value |
| `AudioBufferSourceNode` | loop, playbackRate, detune, offset, duration, sub-sample start, negative rates; linear interpolation |
| `OscillatorNode` | sine computed, the others and `PeriodicWave` from band-limited tables (three per octave); silent at Nyquist and above |
| `GainNode`, `ConstantSourceNode`, `DelayNode`, `StereoPannerNode`, `ChannelSplitterNode`, `ChannelMergerNode` | as specified |
| `BiquadFilterNode`, `IIRFilterNode` | direct form I in doubles; `getFrequencyResponse` |
| `PannerNode` | equal-power, distance and cone models; `panningModel = "HRTF"` is accepted and pans the same way |
| `DynamicsCompressorNode` | the knee and ratio of the specification, a 6 ms look-ahead, an attack and release envelope (not Chromium's adaptive release) |
| `WaveShaperNode` | the curve at the context's rate: `oversample` is kept and does nothing |
| `AnalyserNode` | all four reads, smoothing, Blackman window |
| `ConvolverNode` | uniform partitioned convolution with no latency, 1, 2 and 4 channels. A very long impulse response (over about 10 s) may be more than a quantum's time |
| `ScriptProcessorNode` | blocks to the page and back through rings, two blocks of delay; an offline rendering waits for the page's answer |
| `MediaElementAudioSourceNode` | the player sends what it plays to the node, with the element's volume, and the speakers get silence. The media clock goes on |

## What there is not

- **`AudioWorklet`** (`AudioWorkletNode`): absent, so that a page can test for it. It needs a realm on a render thread of its own, or a
  Wasm instance answering in time; `ScriptProcessorNode` is the old way that works today.
- **`MediaStreamAudioSourceNode`, `MediaStreamAudioDestinationNode`, `createMediaStreamTrackSource`**: Wren has no `MediaStream`.
- **HRTF** panning; **`setSinkId`** (`sinkId` reads `""`, the default device); **`playbackStats`**, `AudioRenderCapacity`.
- **Other render quantum sizes**: `renderSizeHint` is ignored, `renderQuantumSize` is 128.
- **Incremental offline rendering** (`startRendering(chunk)`, `close()`, a context with no length), a recent addition.

## Preferences

`webaudio.enabled`, `webaudio.latency_ms` (`latencyHint` "interactive"; "balanced" is twice that, "playback" four times),
`webaudio.sample_rate`, `webaudio.max_buffer_mb`, `webaudio.max_contexts`.

## Tests

`odin test src/webaudio` (known values: a sine's samples, ramps, a biquad against the cookbook's formulas, convolution, WAV decoding, the
thread on the null output); `examples/jsweb/webaudio.js` and `webaudio_autoplay.js` (`jswebtest`); `tools\wpt.ps1 -Only /webaudio`;
`examples/site/webaudio.html` for a person, or a driven Wren reading its `AnalyserNode`.
