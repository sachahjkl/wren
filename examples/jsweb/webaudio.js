// Web Audio (native/js/odin/web_audio.js, src/webaudio, src/page/bindings_webaudio.odin): the objects and their rules, known
// results through OfflineAudioContext, a running context seen through an AnalyserNode (no sound: WREN_AUDIO_OUTPUT=null).
"use strict";

const near = (got, want, tolerance, what) => ok(Math.abs(got - want) <= tolerance, what + " (got " + got + ", want " + want + ")");
const RATE = 48000;

test("the interfaces", () => {
  for (const name of ["AudioContext", "OfflineAudioContext", "BaseAudioContext", "AudioNode", "AudioParam", "AudioBuffer", "GainNode", "OscillatorNode",
    "AudioBufferSourceNode", "BiquadFilterNode", "DelayNode", "StereoPannerNode", "ChannelSplitterNode", "ChannelMergerNode", "DynamicsCompressorNode",
    "WaveShaperNode", "AnalyserNode", "ConvolverNode", "PannerNode", "ConstantSourceNode", "PeriodicWave", "AudioDestinationNode", "AudioListener", "ScriptProcessorNode"]) {
    eq(typeof globalThis[name], "function", name + " exists");
  }
  throws(() => new AudioNode(), "TypeError", "AudioNode has no constructor");
  throws(() => new AudioParam(), "TypeError", "AudioParam has no constructor");
  throws(() => new BaseAudioContext(), "TypeError", "BaseAudioContext has no constructor");
  eq(Object.getPrototypeOf(GainNode), AudioNode, "GainNode extends AudioNode");
  eq(Object.getPrototypeOf(AudioNode), EventTarget, "AudioNode extends EventTarget");
  eq(Object.getPrototypeOf(AudioContext), BaseAudioContext, "AudioContext extends BaseAudioContext");
  eq(Object.getPrototypeOf(OscillatorNode), AudioScheduledSourceNode, "OscillatorNode is a scheduled source");
  eq(typeof AudioWorkletNode, "undefined", "no AudioWorklet");
});

test("AudioBuffer", () => {
  const b = new AudioBuffer({ numberOfChannels: 2, length: 100, sampleRate: RATE });
  eq(b.numberOfChannels, 2, "channels");
  eq(b.length, 100, "length");
  eq(b.sampleRate, RATE, "rate");
  near(b.duration, 100 / RATE, 1e-12, "duration");
  const d = b.getChannelData(1);
  ok(d instanceof Float32Array, "getChannelData is a Float32Array");
  eq(d.length, 100, "of the buffer's length");
  eq(b.getChannelData(1), d, "the same array");
  d[3] = 0.5;
  const out = new Float32Array(10);
  b.copyFromChannel(out, 1, 2);
  eq(out[1], 0.5, "copyFromChannel sees the array");
  b.copyToChannel(new Float32Array([0.25]), 0, 7);
  eq(b.getChannelData(0)[7], 0.25, "copyToChannel writes it");
  throws(() => b.getChannelData(2), "IndexSizeError", "no channel 2");
  throws(() => new AudioBuffer({ length: 0, sampleRate: RATE }), "NotSupportedError", "no empty buffer");
  throws(() => new AudioBuffer({ length: 1, sampleRate: 1 }), "NotSupportedError", "sample rate range");
  throws(() => new AudioBuffer({ length: 1, sampleRate: RATE, numberOfChannels: 33 }), "NotSupportedError", "33 channels");
});

test("nodes and connections", () => {
  const c = new OfflineAudioContext(2, 128, RATE);
  eq(c.state, "suspended", "offline before it starts");
  eq(c.length, 128, "length");
  eq(c.destination.maxChannelCount, 2, "maxChannelCount");
  const g = c.createGain();
  eq(g.gain.value, 1, "gain");
  eq(g.gain.defaultValue, 1, "default");
  eq(g.numberOfInputs, 1, "inputs");
  eq(g.numberOfOutputs, 1, "outputs");
  eq(g.channelCount, 2, "channelCount");
  eq(g.channelCountMode, "max", "mode");
  eq(g.channelInterpretation, "speakers", "interpretation");
  eq(g.context, c, "context");
  eq(g.connect(c.destination), c.destination, "connect returns its destination");
  throws(() => g.connect(c.destination, 1), "IndexSizeError", "no output 1");
  throws(() => g.connect(c.destination, 0, 1), "IndexSizeError", "no input 1");
  throws(() => g.connect({}), "TypeError", "not a node");
  const other = new OfflineAudioContext(1, 1, RATE);
  throws(() => g.connect(other.destination), "InvalidAccessError", "another context");
  g.disconnect(c.destination);
  throws(() => g.disconnect(c.destination), "InvalidAccessError", "not connected any more");
  g.gain.value = 0.25;
  eq(g.gain.value, 0.25, "the value set");
  throws(() => { g.gain.value = NaN; }, "TypeError", "a float is finite");
  throws(() => { g.channelCount = 0; }, "NotSupportedError", "no channels");
  g.channelCountMode = "nonsense";
  eq(g.channelCountMode, "max", "a wrong enumeration value is ignored");
  const s = c.createChannelSplitter(3);
  eq(s.numberOfOutputs, 3, "splitter outputs");
  eq(s.channelCount, 3, "splitter channels");
  eq(s.channelInterpretation, "discrete", "splitter interpretation");
  throws(() => { s.channelCount = 2; }, "InvalidStateError", "splitter channels stay");
  eq(c.createChannelMerger(4).numberOfInputs, 4, "merger inputs");
  throws(() => c.createDelay(200), "NotSupportedError", "delay limit");
  throws(() => c.createScriptProcessor(100), "IndexSizeError", "script processor size");
  const o = c.createOscillator();
  eq(o.type, "sine", "oscillator type");
  eq(o.frequency.value, 440, "oscillator frequency");
  o.type = "square";
  eq(o.type, "square", "type changed");
  throws(() => { o.type = "custom"; }, "InvalidStateError", "custom needs a wave");
  throws(() => o.stop(), "InvalidStateError", "stop before start");
  o.start();
  throws(() => o.start(), "InvalidStateError", "start twice");
  throws(() => c.createBufferSource().start(-1), "RangeError", "negative time");
  const a = c.createAnalyser();
  eq(a.fftSize, 2048, "fftSize");
  eq(a.frequencyBinCount, 1024, "bins");
  throws(() => { a.fftSize = 100; }, "IndexSizeError", "fftSize power of 2");
  throws(() => { a.minDecibels = 0; }, "IndexSizeError", "min below max");
  const w = c.createPeriodicWave(new Float32Array([0, 1]), new Float32Array([0, 0]));
  ok(w instanceof PeriodicWave, "createPeriodicWave");
  throws(() => c.createPeriodicWave(new Float32Array(2), new Float32Array(3)), "IndexSizeError", "same lengths");
  eq(c.listener.positionX.value, 0, "listener");
  eq(c.listener.forwardZ.value, -1, "listener forward");
  eq(String(c), "[object OfflineAudioContext]", "class string");
  eq(Object.keys(GainNode.prototype).join(), "gain", "attributes are enumerable");
});

test("a sine through a gain ramp, offline", async () => {
  const c = new OfflineAudioContext(1, 4800, RATE);
  const o = c.createOscillator();
  o.frequency.value = 1000;
  const g = c.createGain();
  g.gain.setValueAtTime(0, 0);
  g.gain.linearRampToValueAtTime(1, 0.1);
  o.connect(g).connect(c.destination);
  o.start();
  let completed = null;
  c.oncomplete = e => { completed = e; };
  const seen = [];
  c.onstatechange = () => seen.push(c.state);
  const r = await c.startRendering();
  eq(r.length, 4800, "rendered length");
  const d = r.getChannelData(0);
  let bad = 0;
  for (let i = 0; i < 4800; i++) {
    const want = Math.sin(2 * Math.PI * 1000 * i / RATE) * (i / 4800);
    if (Math.abs(d[i] - want) > 1e-4) bad++;
  }
  eq(bad, 0, "samples: a sine times a ramp");
  await 0;
  eq(c.state, "closed", "closed when it is over");
  ok(completed && completed.renderedBuffer === r, "complete event with the buffer");
  ok(seen.includes("running") && seen.includes("closed"), "statechange events " + seen.join());
  await rejects(c.startRendering(), "InvalidStateError", "rendering once");
});

test("a buffer: what start() acquires, loops, ended", async () => {
  const c = new OfflineAudioContext(1, 512, RATE);
  const b = c.createBuffer(1, 100, RATE);
  const data = b.getChannelData(0);
  data.fill(0.5);
  const s = c.createBufferSource();
  s.buffer = b;
  data.fill(0.25);        // (before start: still counts)
  s.connect(c.destination);
  let ended = false;
  s.onended = () => { ended = true; };
  s.start(0);
  data.fill(1);           // (after start: too late)
  const r = await c.startRendering();
  const d = r.getChannelData(0);
  eq(d[50], 0.25, "the content when it started");
  eq(d[200], 0, "over after its length");
  await sleep(50);
  ok(ended, "ended fired");
  throws(() => { s.buffer = b; }, "InvalidStateError", "only one buffer");
});

test("biquad: getFrequencyResponse and filtering", async () => {
  const c = new OfflineAudioContext(1, 4096, RATE);
  const f = c.createBiquadFilter();
  f.type = "lowpass";
  f.frequency.value = 1000;
  f.Q.value = 0;
  const hz = new Float32Array([10, 1000, 20000, -1]);
  const mag = new Float32Array(4), phase = new Float32Array(4);
  f.getFrequencyResponse(hz, mag, phase);
  near(mag[0], 1, 1e-3, "passes low frequencies");
  near(mag[1], 1, 1e-3, "at the cutoff, Q 0 dB");
  ok(mag[2] < 0.01, "stops high ones");
  ok(Number.isNaN(mag[3]), "outside: NaN");
  throws(() => f.getFrequencyResponse(hz, new Float32Array(1), phase), "InvalidAccessError", "lengths");
  const o = c.createOscillator();
  o.frequency.value = 12000;
  o.connect(f).connect(c.destination);
  o.start();
  const d = (await c.startRendering()).getChannelData(0);
  let peak = 0;
  for (let i = 2048; i < 4096; i++) peak = Math.max(peak, Math.abs(d[i]));
  ok(peak < 0.02, "a high note is filtered out: " + peak);
});

test("delay, panner, merger", async () => {
  const c = new OfflineAudioContext(2, 1024, RATE);
  const k = c.createConstantSource();
  const d = c.createDelay(0.1);
  d.delayTime.value = 256 / RATE;
  const m = c.createChannelMerger(2);
  k.connect(d).connect(m, 0, 1);
  m.connect(c.destination);
  k.start();
  const r = await c.startRendering();
  eq(r.getChannelData(0)[800], 0, "merger: left input is empty");
  eq(r.getChannelData(1)[100], 0, "delay: nothing yet");
  near(r.getChannelData(1)[800], 1, 1e-5, "delay: after 256 frames");
  const c2 = new OfflineAudioContext(2, 128, RATE);
  const k2 = c2.createConstantSource();
  const p = new StereoPannerNode(c2, { pan: 1 });
  k2.connect(p).connect(c2.destination);
  k2.start();
  const r2 = await c2.startRendering();
  near(r2.getChannelData(0)[64], 0, 1e-5, "pan 1: left");
  near(r2.getChannelData(1)[64], 1, 1e-5, "pan 1: right");
});

test("OfflineAudioContext.suspend", async () => {
  const c = new OfflineAudioContext(1, 1024, RATE);
  const g = new GainNode(c, { gain: 0 });
  const k = c.createConstantSource();
  k.connect(g).connect(c.destination);
  k.start();
  const t = 512 / RATE;
  c.suspend(t).then(() => {
    eq(c.state, "suspended", "suspended at its time");
    near(c.currentTime, t, 1e-9, "at the time asked for");
    g.gain.value = 1;
    c.resume();
  });
  const d = (await c.startRendering()).getChannelData(0);
  eq(d[100], 0, "before the change");
  eq(d[800], 1, "after the change");
  await rejects(c.suspend(100), "InvalidStateError", "outside the rendering");
});

// A short WAV file: mono 16 bits at 24 kHz, a sine at 480 Hz.
const wav = () => {
  const frames = 2400, b = new ArrayBuffer(44 + frames * 2), v = new DataView(b);
  const put = (at, s) => { for (let i = 0; i < s.length; i++) v.setUint8(at + i, s.charCodeAt(i)); };
  put(0, "RIFF"); v.setUint32(4, 36 + frames * 2, true); put(8, "WAVEfmt "); v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
  v.setUint32(24, 24000, true); v.setUint32(28, 48000, true); v.setUint16(32, 2, true); v.setUint16(34, 16, true); put(36, "data"); v.setUint32(40, frames * 2, true);
  for (let i = 0; i < frames; i++) v.setInt16(44 + i * 2, Math.round(16384 * Math.sin(2 * Math.PI * 480 * i / 24000)), true);
  return b;
};

test("decodeAudioData", async () => {
  const c = new OfflineAudioContext(1, 128, RATE);
  const data = wav();
  const p = c.decodeAudioData(data);
  eq(data.byteLength, 0, "the array is detached");
  const b = await p;
  eq(b.sampleRate, RATE, "at the context's rate");
  eq(b.length, 4800, "its length at that rate");
  const d = b.getChannelData(0);
  let bad = 0;
  for (let i = 200; i < 4600; i++) if (Math.abs(d[i] - 0.5 * Math.sin(2 * Math.PI * 480 * i / RATE)) > 2e-3) bad++;
  eq(bad, 0, "the sine, converted");
  let called = null;
  const b2 = await c.decodeAudioData(wav(), x => { called = x; });
  eq(called, b2, "the callback and the promise have the same buffer");
  let failed = null;
  await rejects(c.decodeAudioData(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 9]).buffer, null, e => { failed = e; }), "EncodingError", "not audio");
  eq(failed && failed.name, "EncodingError", "the error callback");
  await rejects(c.decodeAudioData(data), "DataCloneError", "a detached array");
  await rejects(c.decodeAudioData(new Uint8Array(4)), "TypeError", "not an ArrayBuffer");
  // the decoded buffer plays without its samples ever coming to this realm
  const c2 = new OfflineAudioContext(1, 4800, RATE);
  const s = c2.createBufferSource();
  s.buffer = await c.decodeAudioData(wav());
  s.connect(c2.destination);
  s.start();
  const r = (await c2.startRendering()).getChannelData(0);
  near(r[500], 0.5 * Math.sin(2 * Math.PI * 480 * 500 / RATE), 2e-3, "played");
});

test("a running AudioContext, heard by an analyser", async () => {
  const c = new AudioContext();
  ok(c.sampleRate >= 3000, "a sample rate");
  eq(c.state, "suspended", "suspended at first");
  await c.resume();          // (the tool's policy allows it)
  eq(c.state, "running", "resume() brings it to running");
  const a = c.createAnalyser();
  a.smoothingTimeConstant = 0;
  const o = c.createOscillator();
  o.frequency.value = 3000;
  o.connect(a).connect(c.destination);
  o.start();
  const t0 = c.currentTime;
  await sleep(300);
  const t1 = c.currentTime;
  ok(t1 > t0 + 0.1, "the clock runs: " + t0 + " -> " + t1);
  const freq = new Float32Array(a.frequencyBinCount);
  a.getFloatFrequencyData(freq);
  let best = 0;
  for (let i = 0; i < freq.length; i++) if (freq[i] > freq[best]) best = i;
  eq(best, Math.round(3000 / (c.sampleRate / a.fftSize)), "the note, in the analyser");
  const wave = new Float32Array(a.fftSize);
  a.getFloatTimeDomainData(wave);
  let peak = 0;
  for (const v of wave) peak = Math.max(peak, Math.abs(v));
  near(peak, 1, 0.05, "the wave, in the analyser");
  const seen = [];
  c.addEventListener("statechange", () => seen.push(c.state));
  await c.suspend();
  eq(c.state, "suspended", "suspend");
  const t2 = c.currentTime;
  await sleep(50);
  eq(c.currentTime, t2, "suspended: the clock stands still");
  await c.resume();
  eq(c.state, "running", "resume");
  let ended = false;
  o.onended = () => { ended = true; };
  o.stop();
  await sleep(100);
  ok(ended, "ended after stop");
  await c.close();
  eq(c.state, "closed", "close");
  await sleep(10);
  ok(seen.join().endsWith("closed"), "statechange " + seen.join());
  await rejects(c.resume(), "InvalidStateError", "closed");
  await rejects(c.close(), "InvalidStateError", "closed twice");
});

test("ScriptProcessorNode", async () => {
  const c = new AudioContext();
  await c.resume();
  const k = c.createConstantSource();
  const sp = c.createScriptProcessor(256, 1, 1);
  const a = c.createAnalyser();
  let blocks = 0, seen = 0, size = 0;
  sp.onaudioprocess = e => {
    blocks++;
    size = e.inputBuffer.length;
    seen = e.inputBuffer.getChannelData(0)[10];
    e.outputBuffer.getChannelData(0).fill(0.5);
  };
  k.connect(sp).connect(a).connect(c.destination);
  k.start();
  await sleep(200);
  ok(blocks > 2, "blocks: " + blocks);
  eq(size, 256, "block size");
  eq(seen, 1, "the input");
  const wave = new Float32Array(a.fftSize);
  a.getFloatTimeDomainData(wave);
  near(Math.max(...wave), 0.5, 1e-6, "the page's answer plays");
  await c.close();
});
__run();
