// The Web Audio API (https://webaudio.github.io/web-audio-api/) over the natives of web_audio.odin, run the first time a
// script of a window reads one of its interfaces: the objects, the conversions and rules of WebIDL, the errors. The graph,
// its thread and every computation are in the browser (src/webaudio). What it uses of the realm is taken here, so what the
// page replaces later does not reach it.
(function (native, global) {
  "use strict";
  const { apply, defineProperty, getOwnPropertyDescriptor, ownKeys } = Reflect;
  const P = Promise, TE = TypeError, RE = RangeError, N = Number, S = String, F32 = Float32Array, U8 = Uint8Array;
  const AB = ArrayBuffer, ArrayIsArray = Array.isArray, isFiniteN = N.isFinite, floor = Math.floor, log2 = Math.log2;
  const ET = global.EventTarget, Ev = global.Event;
  const addListener = ET.prototype.addEventListener, dispatch = ET.prototype.dispatchEvent;
  const MapC = Map, SetC = Set, isView = AB.isView;
  const abTransfer = AB.prototype.transfer;
  const abDetached = getOwnPropertyDescriptor(AB.prototype, "detached")?.get;
  const microtask = global.queueMicrotask;
  const objectToString = Object.prototype.toString, F64 = Float64Array;

  const dom = (name, message) => native.dom(name, message);
  const TOKEN = {};
  const illegal = name => { throw new TE(`Illegal constructor: ${name}`); };

  // The numbers of src/webaudio/graph.odin
  const K = { Destination: 0, Listener: 1, BufferSource: 2, Oscillator: 3, Gain: 4, Constant: 5, Biquad: 6, Delay: 7, StereoPanner: 8, Panner: 9,
    Splitter: 10, Merger: 11, Compressor: 12, WaveShaper: 13, Analyser: 14, Convolver: 15, Script: 16, Element: 17, IIR: 18, Worklet: 19 };
  const F = { ChannelCount: 0, ChannelMode: 1, ChannelInterp: 2, Loop: 3, LoopStart: 4, LoopEnd: 5, OscillatorType: 6, FilterType: 7, Oversample: 8,
    FftSize: 9, MinDb: 10, MaxDb: 11, Smoothing: 12, Normalize: 13, PanningModel: 14, DistanceModel: 15, RefDistance: 16, MaxDistance: 17, Rolloff: 18,
    ConeInner: 19, ConeOuter: 20, ConeOuterGain: 21, Reduction: 22 };
  const STATE_NAMES = ["suspended", "running", "closed"];
  const EV_STATE = 1, EV_ENDED = 2, EV_SCRIPT = 3, EV_OFFLINE_SUSPENDED = 4, EV_WORKLET_ERROR = 5, EV_WORKLET_INACTIVE = 6, EV_WORKLET_STALLED = 7;
  const QUANTUM = 128, MAX_CHANNELS = 32, MIN_RATE = 3000, MAX_RATE = 768000;
  const FLOAT_MAX = 3.4028234663852886e38, DETUNE_MAX = 153600, BIQUAD_GAIN_MAX = 1541.273681640625;
  const FFT_MIN = 32, FFT_MAX = 32768, DELAY_MAX_LIMIT = 180, DELAY_DEFAULT = 1, IIR_MAX = 20;
  const SPLIT_DEFAULT = 6;
  const SCRIPT_MIN = 256, SCRIPT_MAX = 16384, SCRIPT_DEFAULT = 1024;

  const CHANNEL_MODES = ["max", "clamped-max", "explicit"], INTERPS = ["speakers", "discrete"];
  const OSC_TYPES = ["sine", "square", "sawtooth", "triangle", "custom"];
  const FILTER_TYPES = ["lowpass", "highpass", "bandpass", "lowshelf", "highshelf", "peaking", "notch", "allpass"];
  const OVERSAMPLES = ["none", "2x", "4x"];
  const PANNING = ["equalpower", "HRTF"], DISTANCE = ["linear", "inverse", "exponential"];
  const RATES = ["a-rate", "k-rate"];
  const LATENCY_FACTOR = { interactive: 1, balanced: 2, playback: 4 };

  // ---- WebIDL ----
  const float = (v, what) => {
    const x = N(v);
    if (!isFiniteN(x)) throw new TE(`${what}: the value is not a finite number.`);
    return x;
  };
  const fround = Math.fround;
  const toFloat32 = (v, what) => {
    const x = fround(float(v, what));
    if (!isFiniteN(x)) throw new TE(`${what}: the value is out of the range of a float.`);
    return x;
  };
  const uint32 = v => {
    const x = N(v);
    if (!isFiniteN(x)) return 0;
    return (x < 0 ? Math.ceil(x) : floor(x)) % 4294967296 + (x < 0 && floor(-x) % 4294967296 ? 4294967296 : 0);
  };
  const dict = (v, what) => {
    if (v === undefined || v === null) return {};
    if (typeof v !== "object" && typeof v !== "function") throw new TE(`${what}: the options are not an object.`);
    return v;
  };
  const inEnum = (v, list, what) => {
    const x = S(v);
    if (!list.includes(x)) throw new TE(`${what}: '${x}' is not a valid value.`);
    return x;
  };
  const floats = (v, what) => {
    if (v instanceof F32) return v;
    if (v === null || (typeof v !== "object" && typeof v !== "function")) throw new TE(`${what}: not a sequence.`);
    const out = [];
    if (isView(v) || ArrayIsArray(v) || v[Symbol.iterator] !== undefined) {
      for (const x of v) out.push(toFloat32(x, what));
    } else {
      throw new TE(`${what}: not a sequence.`);
    }
    return new F32(out);
  };
  const needF32 = (v, what) => {
    if (!(v instanceof F32)) throw new TE(`${what} is not a Float32Array.`);
    return v;
  };
  const notShared = (v, what) => {
    if (apply(objectToString, v.buffer, []) === "[object SharedArrayBuffer]") throw new TE(`${what} is over a SharedArrayBuffer.`);
    return v;
  };
  const finiteAll = (a, what) => {
    for (let i = 0; i < a.length; i++) if (!isFiniteN(a[i])) throw new TE(`${what}: a value is not finite.`);
    return a;
  };
  const doubles = (v, what) => {
    if (v === null || (typeof v !== "object" && typeof v !== "function") || v[Symbol.iterator] === undefined) throw new TE(`${what}: not a sequence.`);
    const out = [];
    for (const x of v) out.push(float(x, what));
    return new F64(out);
  };

  // A rate of a context or of a buffer
  const checkRate = (r, name) => {
    if (!(r >= MIN_RATE && r <= MAX_RATE)) throw dom("NotSupportedError", `${name}: the sample rate ${r} is outside the range [${MIN_RATE}, ${MAX_RATE}].`);
  };

  // onxxx attributes over a state with `handlers`
  const handlerAttr = (proto, type, stateOf) => {
    defineProperty(proto, "on" + type, {
      configurable: true,
      enumerable: true,
      get() { const s = stateOf(this); return s.handlers?.[type] ?? null; },
      set(v) {
        const s = stateOf(this);
        const isCallable = typeof v === "function" || (typeof v === "object" && v !== null);
        if (!s.handlers) s.handlers = { __proto__: null };
        if (!(type in s.handlers)) {
          const self = this;
          apply(addListener, this, [type, function (e) {
            const f = s.handlers[type];
            if (typeof f === "function") apply(f, self, [e]);
            else if (f !== null && typeof f === "object" && typeof f.handleEvent === "function") apply(f.handleEvent, f, [e]);
          }]);
        }
        s.handlers[type] = isCallable ? v : null;
      },
    });
  };

  // The contexts the browser can still talk to, by the number it knows them by.
  const contexts = new MapC();
  let nextContext = 1;

  // (set in static blocks, of classes that use each other)
  let ctxState, isContext, makeWorklet, makeParamMap;

  // ---- AudioParam ----
  let makeParam;
  class AudioParam {
    #s;
    static {
      makeParam = (ctx, node, index, value, min, max, rate, fixed) => {
        const p = new AudioParam(TOKEN);
        p.#s = { ctx, node, index, value, min, max, rate, fixed };
        return p;
      };
    }
    constructor() { if (arguments[0] !== TOKEN) illegal("AudioParam"); }
    get value() { const s = this.#s; return native.paramGet(s.ctx.graph, s.node, s.index); }
    set value(v) {
      const s = this.#s;
      const x = toFloat32(v, "AudioParam.value");
      if (!native.paramSet(s.ctx.graph, s.node, s.index, x)) throw dom("NotSupportedError", "AudioParam.value: the time is inside a value curve.");
    }
    get automationRate() { return this.#s.rate; }
    set automationRate(v) {
      const s = this.#s;
      const x = S(v);
      if (!RATES.includes(x)) return;
      if (s.fixed && x !== s.rate) throw dom("InvalidStateError", "This AudioParam's automationRate cannot be changed.");
      s.rate = x;
      native.paramRate(s.ctx.graph, s.node, s.index, x === "a-rate");
    }
    get defaultValue() { return this.#s.value; }
    get minValue() { return this.#s.min; }
    get maxValue() { return this.#s.max; }
    #event(kind, time, value, extra, curve, what) {
      const s = this.#s;
      const t = Math.max(time, native.time(s.ctx.graph));
      if (!native.paramEvent(s.ctx.graph, s.node, s.index, kind, t, value, extra, curve)) throw dom("NotSupportedError", `${what}: the time overlaps a value curve.`);
      return this;
    }
    setValueAtTime(value, startTime) {
      if (arguments.length < 2) throw new TE("setValueAtTime: 2 arguments required.");
      const v = toFloat32(value, "setValueAtTime"), t = float(startTime, "setValueAtTime");
      if (t < 0) throw new RE("setValueAtTime: the time is negative.");
      return this.#event(0, t, v, 0, undefined, "setValueAtTime");
    }
    linearRampToValueAtTime(value, endTime) {
      if (arguments.length < 2) throw new TE("linearRampToValueAtTime: 2 arguments required.");
      const v = toFloat32(value, "linearRampToValueAtTime"), t = float(endTime, "linearRampToValueAtTime");
      if (t < 0) throw new RE("linearRampToValueAtTime: the time is negative.");
      return this.#event(1, t, v, 0, undefined, "linearRampToValueAtTime");
    }
    exponentialRampToValueAtTime(value, endTime) {
      if (arguments.length < 2) throw new TE("exponentialRampToValueAtTime: 2 arguments required.");
      const v = toFloat32(value, "exponentialRampToValueAtTime"), t = float(endTime, "exponentialRampToValueAtTime");
      if (v === 0) throw new RE("exponentialRampToValueAtTime: the value is zero.");   // (as a float: 1e-100 is one)
      if (t < 0) throw new RE("exponentialRampToValueAtTime: the time is negative.");
      return this.#event(2, t, v, 0, undefined, "exponentialRampToValueAtTime");
    }
    setTargetAtTime(target, startTime, timeConstant) {
      if (arguments.length < 3) throw new TE("setTargetAtTime: 3 arguments required.");
      const v = toFloat32(target, "setTargetAtTime"), t = float(startTime, "setTargetAtTime"), c = toFloat32(timeConstant, "setTargetAtTime");
      if (t < 0) throw new RE("setTargetAtTime: the time is negative.");
      if (c < 0) throw new RE("setTargetAtTime: the time constant is negative.");
      return this.#event(3, t, v, c, undefined, "setTargetAtTime");
    }
    setValueCurveAtTime(values, startTime, duration) {
      if (arguments.length < 3) throw new TE("setValueCurveAtTime: 3 arguments required.");
      const c = floats(values, "setValueCurveAtTime");
      for (let i = 0; i < c.length; i++) if (!isFiniteN(c[i])) throw new TE("setValueCurveAtTime: a value of the curve is not finite.");
      const t = float(startTime, "setValueCurveAtTime"), d = float(duration, "setValueCurveAtTime");
      if (t < 0) throw new RE("setValueCurveAtTime: the time is negative.");
      if (d <= 0) throw new RE("setValueCurveAtTime: the duration is not positive.");
      if (c.length < 2) throw dom("InvalidStateError", "setValueCurveAtTime: a curve has at least two values.");
      return this.#event(4, t, c[0], d, c, "setValueCurveAtTime");
    }
    cancelScheduledValues(cancelTime) {
      if (arguments.length < 1) throw new TE("cancelScheduledValues: 1 argument required.");
      const s = this.#s, t = float(cancelTime, "cancelScheduledValues");
      if (t < 0) throw new RE("cancelScheduledValues: the time is negative.");
      native.paramCancel(s.ctx.graph, s.node, s.index, Math.max(t, native.time(s.ctx.graph)), false);
      return this;
    }
    cancelAndHoldAtTime(cancelTime) {
      if (arguments.length < 1) throw new TE("cancelAndHoldAtTime: 1 argument required.");
      const s = this.#s, t = float(cancelTime, "cancelAndHoldAtTime");
      if (t < 0) throw new RE("cancelAndHoldAtTime: the time is negative.");
      native.paramCancel(s.ctx.graph, s.node, s.index, Math.max(t, native.time(s.ctx.graph)), true);
      return this;
    }
    static paramTarget(p) { return p.#s; }
  }
  const paramTarget = AudioParam.paramTarget;
  delete AudioParam.paramTarget;

  // ---- AudioBuffer ----
  let bufferOfHost, bufferHost;
  class AudioBuffer {
    #s;
    static {
      // A buffer whose samples are in the browser (decodeAudioData, a rendering)
      bufferOfHost = host => {
        const b = new AudioBuffer(TOKEN, { numberOfChannels: native.pcmInfo(host, 0), length: native.pcmInfo(host, 1), sampleRate: native.pcmInfo(host, 2) });
        b.#s.host = host;
        return b;
      };
      // The samples as they are now, in the browser. `acquire` ("acquire the content"): what a node plays from then on;
      // the arrays given out are the script's alone, and getChannelData makes new ones. An array that was transferred
      // away: nothing can be acquired (null).
      bufferHost = (b, acquire) => {
        const s = b.#s;
        for (let c = 0; c < s.channels; c++) if (s.arrays[c] && s.arrays[c].length !== s.length) return null;
        if (!s.host) s.host = native.pcmCreate(s.channels, s.length, s.rate);
        if (s.host === null) throw dom("NotSupportedError", "The AudioBuffer is too large.");
        for (let c = 0; c < s.channels; c++) {
          if (s.arrays[c]) native.pcmWrite(s.host, c, 0, s.arrays[c]);
          if (acquire) s.arrays[c] = undefined;
        }
        return s.host;
      };
    }
    constructor(options) {
      if (arguments.length < 1) throw new TE("AudioBuffer: 1 argument required.");
      const internal = arguments[0] === TOKEN;
      const o = internal ? arguments[1] : dict(options, "AudioBuffer");
      if (o.length === undefined) throw new TE("AudioBuffer: length is required.");
      if (o.sampleRate === undefined) throw new TE("AudioBuffer: sampleRate is required.");
      const channels = o.numberOfChannels === undefined ? 1 : uint32(o.numberOfChannels);
      const length = uint32(o.length), rate = float(o.sampleRate, "AudioBuffer.sampleRate");
      checkBuffer(channels, length, rate, "AudioBuffer");
      this.#s = { channels, length, rate, arrays: new Array(channels), host: null };
    }
    get sampleRate() { return this.#s.rate; }
    get length() { return this.#s.length; }
    get duration() { const s = this.#s; return s.length / s.rate; }
    get numberOfChannels() { return this.#s.channels; }
    #array(c) {
      const s = this.#s;
      if (!s.arrays[c]) {
        const a = new F32(s.length);
        if (s.host) native.pcmRead(s.host, c, 0, a);
        s.arrays[c] = a;
      }
      return s.arrays[c];
    }
    getChannelData(channel) {
      if (arguments.length < 1) throw new TE("getChannelData: 1 argument required.");
      const c = uint32(channel), s = this.#s;
      if (c >= s.channels) throw dom("IndexSizeError", `getChannelData: there is no channel ${c}.`);
      return this.#array(c);
    }
    copyFromChannel(destination, channelNumber, bufferOffset = 0) {
      if (arguments.length < 2) throw new TE("copyFromChannel: 2 arguments required.");
      notShared(needF32(destination, "copyFromChannel: destination"), "copyFromChannel: destination");
      const c = uint32(channelNumber), at = uint32(bufferOffset), s = this.#s;
      if (c >= s.channels) throw dom("IndexSizeError", `copyFromChannel: there is no channel ${c}.`);
      if (at >= s.length) return;
      const n = Math.min(destination.length, s.length - at);
      if (n <= 0) return;
      if (s.arrays[c]) {
        destination.set(s.arrays[c].subarray(at, at + n));
      } else if (s.host) {
        native.pcmRead(s.host, c, at, destination.subarray(0, n));
      } else {
        destination.fill(0, 0, n);
      }
    }
    copyToChannel(source, channelNumber, bufferOffset = 0) {
      if (arguments.length < 2) throw new TE("copyToChannel: 2 arguments required.");
      notShared(needF32(source, "copyToChannel: source"), "copyToChannel: source");
      const c = uint32(channelNumber), at = uint32(bufferOffset), s = this.#s;
      if (c >= s.channels) throw dom("IndexSizeError", `copyToChannel: there is no channel ${c}.`);
      if (at >= s.length) return;
      const n = Math.min(source.length, s.length - at);
      if (n > 0) this.#array(c).set(source.subarray(0, n), at);
    }
  }
  const checkBuffer = (channels, length, rate, name) => {
    if (channels < 1 || channels > MAX_CHANNELS) throw dom("NotSupportedError", `${name}: ${channels} channels is not between 1 and ${MAX_CHANNELS}.`);
    if (length < 1) throw dom("NotSupportedError", `${name}: the length is not positive.`);
    checkRate(rate, name);
    if (channels * length * 4 > native.maxBuffer()) throw dom("NotSupportedError", `${name}: too large (webaudio.max_buffer_mb).`);
  };

  // ---- AudioNode ----
  let nodeState, nodeCtx;
  class AudioNode extends ET {
    #s;
    static {
      nodeState = o => o.#s;
      nodeCtx = n => n.#s.ctx;
    }
    constructor() {
      if (arguments[0] !== TOKEN) illegal("AudioNode");
      super();
      const [, ctxObject, kind, inputs, outputs, a, b, mode, count, interp] = arguments;
      const ctx = ctxState(ctxObject);
      // (an AudioWorkletNode's node is made with what only it has: its `a` is the id)
      let id = kind === K.Destination ? 0 : kind === K.Listener ? 1 : kind === K.Worklet ? a : native.nodeCreate(ctx.graph, kind, a ?? 0, b ?? 0);
      if (id < 0) throw dom("NotSupportedError", "The node could not be made.");
      this.#s = {
        ctxObject, ctx, id, kind, inputs, outputs,
        mode: mode ?? "max", count: count ?? 2, interp: interp ?? "speakers",
        ref: kind === K.Destination || kind === K.Listener ? null : native.nodeRef(ctx.graph, id),
        handlers: null,
      };
    }
    get context() { return this.#s.ctxObject; }
    get numberOfInputs() { return this.#s.inputs; }
    get numberOfOutputs() { return this.#s.outputs; }
    get channelCount() { return this.#s.count; }
    set channelCount(v) {
      const s = this.#s, n = uint32(v);
      channelCountRule(s, n);
      s.count = n;
      native.nodeSet(s.ctx.graph, s.id, F.ChannelCount, n);
    }
    get channelCountMode() { return this.#s.mode; }
    set channelCountMode(v) {
      const s = this.#s, x = S(v);
      if (!CHANNEL_MODES.includes(x)) return;
      channelModeRule(s, x);
      s.mode = x;
      native.nodeSet(s.ctx.graph, s.id, F.ChannelMode, CHANNEL_MODES.indexOf(x));
    }
    get channelInterpretation() { return this.#s.interp; }
    set channelInterpretation(v) {
      const s = this.#s, x = S(v);
      if (!INTERPS.includes(x)) return;
      if (s.kind === K.Splitter && x !== "discrete") throw dom("InvalidStateError", "A ChannelSplitterNode's channelInterpretation stays discrete.");
      s.interp = x;
      native.nodeSet(s.ctx.graph, s.id, F.ChannelInterp, INTERPS.indexOf(x));
    }
    connect(destination, output = 0, input = 0) {
      if (arguments.length < 1) throw new TE("connect: 1 argument required.");
      const s = this.#s;
      const out = uint32(output);
      if (destination instanceof AudioParam) {
        const t = paramTarget(destination);
        if (out >= s.outputs) throw dom("IndexSizeError", `connect: there is no output ${out}.`);
        if (t.ctx !== s.ctx) throw dom("InvalidAccessError", "connect: the AudioParam is of another context.");
        native.connect(s.ctx.graph, s.id, out, t.node, t.index, true);
        return undefined;
      }
      if (!(destination instanceof AudioNode)) throw new TE("connect: the destination is neither an AudioNode nor an AudioParam.");
      const d = destination.#s;
      const inp = uint32(input);
      if (out >= s.outputs) throw dom("IndexSizeError", `connect: there is no output ${out}.`);
      if (inp >= d.inputs) throw dom("IndexSizeError", `connect: there is no input ${inp}.`);
      if (d.ctx !== s.ctx) throw dom("InvalidAccessError", "connect: the destination is of another context.");
      native.connect(s.ctx.graph, s.id, out, d.id, inp, false);
      return destination;
    }
    disconnect() {
      const [a, b, c] = arguments;
      const s = this.#s;
      const argc = arguments.length;
      if (argc === 0 || a === undefined && argc === 1) {
        native.disconnect(s.ctx.graph, s.id, -1, -1, -1, false);
        return;
      }
      if (typeof a === "number" || !(a instanceof AudioNode || a instanceof AudioParam)) {
        if (typeof a === "object" && a !== null) throw new TE("disconnect: the argument is neither an AudioNode nor an AudioParam.");
        const out = uint32(a);
        if (out >= s.outputs) throw dom("IndexSizeError", `disconnect: there is no output ${out}.`);
        native.disconnect(s.ctx.graph, s.id, out, -1, -1, false);
        return;
      }
      const out = argc >= 2 && b !== undefined ? uint32(b) : -1;
      if (out >= s.outputs) throw dom("IndexSizeError", `disconnect: there is no output ${out}.`);
      if (a instanceof AudioParam) {
        const t = paramTarget(a);
        if (native.disconnect(s.ctx.graph, s.id, out, t.node, t.index, true) === 0) throw dom("InvalidAccessError", "disconnect: not connected to this AudioParam.");
        return;
      }
      const d = a.#s;
      const inp = argc >= 3 && c !== undefined ? uint32(c) : -1;
      if (inp >= d.inputs) throw dom("IndexSizeError", `disconnect: there is no input ${inp}.`);
      if (native.disconnect(s.ctx.graph, s.id, out, d.id, inp, false) === 0) throw dom("InvalidAccessError", "disconnect: not connected to this node.");
    }
  }

  const channelCountRule = (s, n) => {
    const name = "channelCount";
    switch (s.kind) {
      case K.Destination:
        if (n < 1) throw dom("NotSupportedError", `${name}: at least 1.`);
        if (n > s.maxChannels) throw dom("IndexSizeError", `${name}: ${n} is more than ${s.maxChannels}.`);
        if (s.ctx.offline && n !== s.count) throw dom("InvalidStateError", `${name}: the destination of an OfflineAudioContext keeps its channels.`);
        return;
      case K.Merger:
        if (n !== 1) throw dom("InvalidStateError", `${name}: a ChannelMergerNode has 1.`);
        return;
      case K.Splitter:
        if (n !== s.outputs) throw dom("InvalidStateError", `${name}: a ChannelSplitterNode has ${s.outputs}.`);
        return;
      case K.StereoPanner: case K.Panner: case K.Compressor: case K.Convolver:
        if (n < 1 || n > 2) throw dom("NotSupportedError", `${name}: this node has 1 or 2.`);
        return;
      case K.Script:
        if (n !== s.count) throw dom("NotSupportedError", `${name}: a ScriptProcessorNode's cannot change.`);
        return;
    }
    if (n < 1 || n > MAX_CHANNELS) throw dom("NotSupportedError", `${name}: ${n} is not between 1 and ${MAX_CHANNELS}.`);
  };
  const channelModeRule = (s, x) => {
    switch (s.kind) {
      case K.Destination:
        if (s.ctx.offline && x !== "explicit") throw dom("InvalidStateError", "channelCountMode: the destination of an OfflineAudioContext stays explicit.");
        return;
      case K.Merger:
        if (x !== "explicit") throw dom("InvalidStateError", "channelCountMode: a ChannelMergerNode stays explicit.");
        return;
      case K.Splitter:
        if (x !== "explicit") throw dom("InvalidStateError", "channelCountMode: a ChannelSplitterNode stays explicit.");
        return;
      case K.StereoPanner: case K.Panner: case K.Compressor: case K.Convolver:
        if (x === "max") throw dom("NotSupportedError", "channelCountMode: this node cannot be max.");
        return;
      case K.Script:
        if (x !== "explicit") throw dom("NotSupportedError", "channelCountMode: a ScriptProcessorNode stays explicit.");
        return;
    }
  };

  // AudioNodeOptions, the node being made
  const applyNodeOptions = (node, o) => {
    if (o.channelCount !== undefined) node.channelCount = uint32(o.channelCount);
    if (o.channelCountMode !== undefined) {
      const x = inEnum(o.channelCountMode, CHANNEL_MODES, "channelCountMode");
      node.channelCountMode = x;
    }
    if (o.channelInterpretation !== undefined) {
      const x = inEnum(o.channelInterpretation, INTERPS, "channelInterpretation");
      node.channelInterpretation = x;
    }
  };
  // The first argument of a node's constructor
  const contextArg = (c, name) => {
    if (!isContext(c)) throw new TE(`${name}: the first argument is not a BaseAudioContext.`);
    return c;
  };
  const param = (node, index, value, min, max, rate = "a-rate", fixed = false) => {
    const s = nodeState(node);
    return makeParam(s.ctx, s.id, index, value, min, max, rate, fixed);
  };
  const of = (o, kind) => {
    const s = nodeState(o);
    if (s.kind !== kind) throw new TE("Illegal invocation");
    return s;
  };

  // ---- AudioDestinationNode ----
  let makeDestination;
  class AudioDestinationNode extends AudioNode {
    constructor() {
      if (arguments[0] !== TOKEN) illegal("AudioDestinationNode");
      const ctx = arguments[1], channels = arguments[2], max = arguments[3], offline = arguments[4];
      super(TOKEN, ctx, K.Destination, 1, 1, 0, 0, "explicit", channels, "speakers");
      nodeState(this).maxChannels = max;
    }
    get maxChannelCount() { return of(this, K.Destination).maxChannels; }
    static {
      makeDestination = (ctx, channels, max, offline) => new AudioDestinationNode(TOKEN, ctx, channels, max, offline);
    }
  }

  // ---- AudioListener ----
  let makeListener;
  class AudioListener {
    #p;
    static { makeListener = ctx => { const l = new AudioListener(TOKEN); l.#init(ctx); return l; }; }
    constructor() { if (arguments[0] !== TOKEN) illegal("AudioListener"); }
    #init(ctx) {
      const v = [0, 0, 0, 0, 0, -1, 0, 1, 0];
      this.#p = v.map((d, i) => makeParam(ctx, K.Listener, i, d, -FLOAT_MAX, FLOAT_MAX, "a-rate", false));
    }
    get positionX() { return this.#p[0]; }
    get positionY() { return this.#p[1]; }
    get positionZ() { return this.#p[2]; }
    get forwardX() { return this.#p[3]; }
    get forwardY() { return this.#p[4]; }
    get forwardZ() { return this.#p[5]; }
    get upX() { return this.#p[6]; }
    get upY() { return this.#p[7]; }
    get upZ() { return this.#p[8]; }
    setPosition(x, y, z) {
      if (arguments.length < 3) throw new TE("setPosition: 3 arguments required.");
      const v = [toFloat32(x, "setPosition"), toFloat32(y, "setPosition"), toFloat32(z, "setPosition")];
      for (let i = 0; i < 3; i++) this.#p[i].value = v[i];
    }
    setOrientation(x, y, z, xUp, yUp, zUp) {
      if (arguments.length < 6) throw new TE("setOrientation: 6 arguments required.");
      const v = [x, y, z, xUp, yUp, zUp].map(a => toFloat32(a, "setOrientation"));
      for (let i = 0; i < 6; i++) this.#p[3 + i].value = v[i];
    }
  }

  // ---- AudioScheduledSourceNode ----
  class AudioScheduledSourceNode extends AudioNode {
    constructor() {
      if (arguments[0] !== TOKEN) illegal("AudioScheduledSourceNode");
      super(TOKEN, arguments[1], arguments[2], 0, 1);
    }
    start(when = 0) {
      const s = nodeState(this);
      const t = float(when, "start");
      if (s.started) throw dom("InvalidStateError", "start: it was started already.");
      if (t < 0) throw new RE("start: the time is negative.");
      s.started = true;
      s.ctx.active.set(s.id, this);
      native.start(s.ctx.graph, s.id, t, 0, -1);
    }
    stop(when = 0) {
      const s = nodeState(this);
      const t = float(when, "stop");
      if (!s.started) throw dom("InvalidStateError", "stop: it was not started.");
      if (t < 0) throw new RE("stop: the time is negative.");
      native.stop(s.ctx.graph, s.id, t);
    }
  }
  handlerAttr(AudioScheduledSourceNode.prototype, "ended", nodeState);

  // ---- AudioBufferSourceNode ----
  class AudioBufferSourceNode extends AudioScheduledSourceNode {
    #buffer = null;
    #loop = false;
    #loopStart = 0;
    #loopEnd = 0;
    #playbackRate;
    #detune;
    constructor(context, options = undefined) {
      if (arguments.length < 1) throw new TE("AudioBufferSourceNode: 1 argument required.");
      contextArg(context, "AudioBufferSourceNode");
      const o = dict(options, "AudioBufferSourceNode");
      super(TOKEN, context, K.BufferSource);
      this.#playbackRate = param(this, 0, 1, -FLOAT_MAX, FLOAT_MAX, "k-rate", true);
      this.#detune = param(this, 1, 0, -FLOAT_MAX, FLOAT_MAX, "k-rate", true);
      if (o.buffer !== undefined && o.buffer !== null) this.buffer = o.buffer;
      if (o.detune !== undefined) this.#detune.value = toFloat32(o.detune, "AudioBufferSourceNode.detune");
      if (o.loop !== undefined) this.loop = !!o.loop;
      if (o.loopEnd !== undefined) this.loopEnd = float(o.loopEnd, "loopEnd");
      if (o.loopStart !== undefined) this.loopStart = float(o.loopStart, "loopStart");
      if (o.playbackRate !== undefined) this.#playbackRate.value = toFloat32(o.playbackRate, "AudioBufferSourceNode.playbackRate");
      applyNodeOptions(this, o);
    }
    get buffer() { return this.#buffer; }
    set buffer(v) {
      if (v !== null && !(v instanceof AudioBuffer)) throw new TE("buffer: not an AudioBuffer.");
      const s = nodeState(this);
      if (v !== null && s.hadBuffer) throw dom("InvalidStateError", "buffer: it was set already.");
      this.#buffer = v;
      if (v !== null) s.hadBuffer = true;
      // (started already: this is when the content is acquired; else at start())
      native.setBuffer(s.ctx.graph, s.id, v !== null ? bufferHost(v, !!s.started) : null);
    }
    get playbackRate() { return this.#playbackRate; }
    get detune() { return this.#detune; }
    get loop() { return this.#loop; }
    set loop(v) { const s = nodeState(this); this.#loop = !!v; native.nodeSet(s.ctx.graph, s.id, F.Loop, this.#loop ? 1 : 0); }
    get loopStart() { return this.#loopStart; }
    set loopStart(v) {
      const s = nodeState(this), x = float(v, "loopStart");
      this.#loopStart = x;
      native.nodeSet(s.ctx.graph, s.id, F.LoopStart, x);
    }
    get loopEnd() { return this.#loopEnd; }
    set loopEnd(v) {
      const s = nodeState(this), x = float(v, "loopEnd");
      this.#loopEnd = x;
      native.nodeSet(s.ctx.graph, s.id, F.LoopEnd, x);
    }
    start(when = 0, offset = 0, duration = undefined) {
      const s = nodeState(this);
      const t = float(when, "start"), off = float(offset, "start");
      const d = duration === undefined ? -1 : float(duration, "start");
      if (s.started) throw dom("InvalidStateError", "start: it was started already.");
      if (t < 0 || off < 0 || (duration !== undefined && d < 0)) throw new RE("start: a negative time.");
      s.started = true;
      s.ctx.active.set(s.id, this);
      if (this.#buffer) native.setBuffer(s.ctx.graph, s.id, bufferHost(this.#buffer, true));   // (the content is acquired)
      native.start(s.ctx.graph, s.id, t, off, d);
    }
  }

  // ---- PeriodicWave ----
  class PeriodicWave {
    #s;
    constructor(context, options = undefined) {
      if (arguments.length < 1) throw new TE("PeriodicWave: 1 argument required.");
      contextArg(context, "PeriodicWave");
      const o = dict(options, "PeriodicWave");
      let real = o.real === undefined ? null : finiteAll(floats(o.real, "PeriodicWave.real"), "PeriodicWave.real");
      let imag = o.imag === undefined ? null : finiteAll(floats(o.imag, "PeriodicWave.imag"), "PeriodicWave.imag");
      if (real && imag && real.length !== imag.length) throw dom("IndexSizeError", "PeriodicWave: real and imag have different lengths.");
      const n = real ? real.length : imag ? imag.length : 2;
      if (n < 2) throw dom("IndexSizeError", "PeriodicWave: fewer than 2 coefficients.");
      if (!real && !imag) { real = new F32(2); imag = new F32([0, 1]); }
      if (!real) real = new F32(n);
      if (!imag) imag = new F32(n);
      this.#s = { real: new F32(real), imag: new F32(imag), normalize: !o.disableNormalization };
    }
    static waveState(w) { return w.#s; }
  }
  const waveState = PeriodicWave.waveState;
  delete PeriodicWave.waveState;

  // ---- OscillatorNode ----
  class OscillatorNode extends AudioScheduledSourceNode {
    #type = "sine";
    #frequency;
    #detune;
    constructor(context, options = undefined) {
      if (arguments.length < 1) throw new TE("OscillatorNode: 1 argument required.");
      contextArg(context, "OscillatorNode");
      const o = dict(options, "OscillatorNode");
      super(TOKEN, context, K.Oscillator);
      const nyquist = context.sampleRate / 2;
      this.#frequency = param(this, 0, 440, -nyquist, nyquist);
      this.#detune = param(this, 1, 0, -DETUNE_MAX, DETUNE_MAX);
      if (o.detune !== undefined) this.#detune.value = toFloat32(o.detune, "OscillatorNode.detune");
      if (o.frequency !== undefined) this.#frequency.value = toFloat32(o.frequency, "OscillatorNode.frequency");
      if (o.periodicWave !== undefined) {
        if (!(o.periodicWave instanceof PeriodicWave)) throw new TE("OscillatorNode: periodicWave is not a PeriodicWave.");
        this.setPeriodicWave(o.periodicWave);
      }
      if (o.type !== undefined) {
        const t = inEnum(o.type, OSC_TYPES, "OscillatorNode.type");
        if (t === "custom") {
          if (o.periodicWave === undefined || o.periodicWave === null) throw dom("InvalidStateError", "OscillatorNode: type custom needs a periodicWave.");
        } else if (o.periodicWave === undefined || o.periodicWave === null) {
          this.type = t;
        }
      }
      applyNodeOptions(this, o);
    }
    get type() { of(this, K.Oscillator); return this.#type; }
    set type(v) {
      const s = of(this, K.Oscillator), x = S(v);
      if (!OSC_TYPES.includes(x)) return;
      if (x === "custom") throw dom("InvalidStateError", "type: custom comes with setPeriodicWave.");
      this.#type = x;
      native.nodeSet(s.ctx.graph, s.id, F.OscillatorType, OSC_TYPES.indexOf(x));
    }
    get frequency() { return this.#frequency; }
    get detune() { return this.#detune; }
    setPeriodicWave(periodicWave) {
      if (!(periodicWave instanceof PeriodicWave)) throw new TE("setPeriodicWave: not a PeriodicWave.");
      const s = of(this, K.Oscillator), w = waveState(periodicWave);
      native.setWave(s.ctx.graph, s.id, w.real, w.imag, w.normalize);
      this.#type = "custom";
    }
  }

  // ---- ConstantSourceNode ----
  class ConstantSourceNode extends AudioScheduledSourceNode {
    #offset;
    constructor(context, options = undefined) {
      if (arguments.length < 1) throw new TE("ConstantSourceNode: 1 argument required.");
      contextArg(context, "ConstantSourceNode");
      const o = dict(options, "ConstantSourceNode");
      super(TOKEN, context, K.Constant);
      this.#offset = param(this, 0, 1, -FLOAT_MAX, FLOAT_MAX);
      if (o.offset !== undefined) this.#offset.value = toFloat32(o.offset, "ConstantSourceNode.offset");
    }
    get offset() { return this.#offset; }
  }

  // ---- GainNode ----
  class GainNode extends AudioNode {
    #gain;
    constructor(context, options = undefined) {
      if (arguments.length < 1) throw new TE("GainNode: 1 argument required.");
      contextArg(context, "GainNode");
      const o = dict(options, "GainNode");
      super(TOKEN, context, K.Gain, 1, 1);
      this.#gain = param(this, 0, 1, -FLOAT_MAX, FLOAT_MAX);
      if (o.gain !== undefined) this.#gain.value = toFloat32(o.gain, "GainNode.gain");
      applyNodeOptions(this, o);
    }
    get gain() { return this.#gain; }
  }

  // ---- BiquadFilterNode ----
  class BiquadFilterNode extends AudioNode {
    #type = "lowpass";
    #p;
    constructor(context, options = undefined) {
      if (arguments.length < 1) throw new TE("BiquadFilterNode: 1 argument required.");
      contextArg(context, "BiquadFilterNode");
      const o = dict(options, "BiquadFilterNode");
      super(TOKEN, context, K.Biquad, 1, 1);
      const nyquist = context.sampleRate / 2;
      this.#p = [param(this, 0, 350, 0, nyquist), param(this, 1, 0, -DETUNE_MAX, DETUNE_MAX), param(this, 2, 1, -FLOAT_MAX, FLOAT_MAX), param(this, 3, 0, -FLOAT_MAX, BIQUAD_GAIN_MAX)];
      if (o.type !== undefined) this.type = inEnum(o.type, FILTER_TYPES, "BiquadFilterNode.type");
      if (o.Q !== undefined) this.#p[2].value = toFloat32(o.Q, "BiquadFilterNode.Q");
      if (o.detune !== undefined) this.#p[1].value = toFloat32(o.detune, "BiquadFilterNode.detune");
      if (o.frequency !== undefined) this.#p[0].value = toFloat32(o.frequency, "BiquadFilterNode.frequency");
      if (o.gain !== undefined) this.#p[3].value = toFloat32(o.gain, "BiquadFilterNode.gain");
      applyNodeOptions(this, o);
    }
    get type() { return this.#type; }
    set type(v) {
      const s = nodeState(this), x = S(v);
      if (!FILTER_TYPES.includes(x)) return;
      this.#type = x;
      native.nodeSet(s.ctx.graph, s.id, F.FilterType, FILTER_TYPES.indexOf(x));
    }
    get frequency() { return this.#p[0]; }
    get detune() { return this.#p[1]; }
    get Q() { return this.#p[2]; }
    get gain() { return this.#p[3]; }
    getFrequencyResponse(frequencyHz, magResponse, phaseResponse) {
      if (arguments.length < 3) throw new TE("getFrequencyResponse: 3 arguments required.");
      needF32(frequencyHz, "getFrequencyResponse: frequencyHz");
      needF32(magResponse, "getFrequencyResponse: magResponse");
      needF32(phaseResponse, "getFrequencyResponse: phaseResponse");
      if (magResponse.length !== frequencyHz.length || phaseResponse.length !== frequencyHz.length) throw dom("InvalidAccessError", "getFrequencyResponse: the arrays are of different lengths.");
      const s = nodeState(this);
      if (frequencyHz.length > 0) native.biquadResponse(s.ctx.graph, s.id, frequencyHz, magResponse, phaseResponse);
    }
  }

  // ---- IIRFilterNode ----
  class IIRFilterNode extends AudioNode {
    constructor(context, options) {
      if (arguments.length < 2) throw new TE("IIRFilterNode: 2 arguments required.");
      contextArg(context, "IIRFilterNode");
      const o = dict(options, "IIRFilterNode");
      if (o.feedforward === undefined || o.feedback === undefined) throw new TE("IIRFilterNode: feedforward and feedback are required.");
      const ff = doubles(o.feedforward, "feedforward"), fb = doubles(o.feedback, "feedback");
      if (ff.length < 1 || ff.length > IIR_MAX) throw dom("NotSupportedError", `IIRFilterNode: feedforward has ${ff.length} values.`);
      if (fb.length < 1 || fb.length > IIR_MAX) throw dom("NotSupportedError", `IIRFilterNode: feedback has ${fb.length} values.`);
      if (ff.every(v => v === 0)) throw dom("InvalidStateError", "IIRFilterNode: feedforward is all zeros.");
      if (fb[0] === 0) throw dom("InvalidStateError", "IIRFilterNode: feedback[0] is zero.");
      super(TOKEN, context, K.IIR, 1, 1);
      const s = nodeState(this);
      native.setIir(s.ctx.graph, s.id, ff, fb);
      applyNodeOptions(this, o);
    }
    getFrequencyResponse(frequencyHz, magResponse, phaseResponse) {
      if (arguments.length < 3) throw new TE("getFrequencyResponse: 3 arguments required.");
      needF32(frequencyHz, "getFrequencyResponse: frequencyHz");
      needF32(magResponse, "getFrequencyResponse: magResponse");
      needF32(phaseResponse, "getFrequencyResponse: phaseResponse");
      if (magResponse.length !== frequencyHz.length || phaseResponse.length !== frequencyHz.length) throw dom("InvalidAccessError", "getFrequencyResponse: the arrays are of different lengths.");
      const s = of(this, K.IIR);
      if (frequencyHz.length > 0) native.iirResponse(s.ctx.graph, s.id, frequencyHz, magResponse, phaseResponse);
    }
  }

  // ---- DelayNode ----
  class DelayNode extends AudioNode {
    #delayTime;
    constructor(context, options = undefined) {
      if (arguments.length < 1) throw new TE("DelayNode: 1 argument required.");
      contextArg(context, "DelayNode");
      const o = dict(options, "DelayNode");
      const max = o.maxDelayTime === undefined ? DELAY_DEFAULT : float(o.maxDelayTime, "maxDelayTime");
      if (!(max > 0 && max < DELAY_MAX_LIMIT)) throw dom("NotSupportedError", `DelayNode: maxDelayTime ${max} is outside (0, ${DELAY_MAX_LIMIT}).`);
      super(TOKEN, context, K.Delay, 1, 1, max);
      this.#delayTime = param(this, 0, 0, 0, max);
      if (o.delayTime !== undefined) this.#delayTime.value = toFloat32(o.delayTime, "DelayNode.delayTime");
      applyNodeOptions(this, o);
    }
    get delayTime() { return this.#delayTime; }
  }

  // ---- StereoPannerNode ----
  class StereoPannerNode extends AudioNode {
    #pan;
    constructor(context, options = undefined) {
      if (arguments.length < 1) throw new TE("StereoPannerNode: 1 argument required.");
      contextArg(context, "StereoPannerNode");
      const o = dict(options, "StereoPannerNode");
      super(TOKEN, context, K.StereoPanner, 1, 1, 0, 0, "clamped-max");
      this.#pan = param(this, 0, 0, -1, 1);
      if (o.pan !== undefined) this.#pan.value = toFloat32(o.pan, "StereoPannerNode.pan");
      applyNodeOptions(this, o);
    }
    get pan() { return this.#pan; }
  }

  // ---- PannerNode ----
  const ATTR = (self, field, v, s) => { native.nodeSet(s.ctx.graph, s.id, field, v); };
  class PannerNode extends AudioNode {
    #p;
    #a = { panningModel: "equalpower", distanceModel: "inverse", refDistance: 1, maxDistance: 10000, rolloffFactor: 1, coneInnerAngle: 360, coneOuterAngle: 360, coneOuterGain: 0 };
    constructor(context, options = undefined) {
      if (arguments.length < 1) throw new TE("PannerNode: 1 argument required.");
      contextArg(context, "PannerNode");
      const o = dict(options, "PannerNode");
      super(TOKEN, context, K.Panner, 1, 1, 0, 0, "clamped-max");
      const d = [0, 0, 0, 1, 0, 0];
      this.#p = d.map((v, i) => param(this, i, v, -FLOAT_MAX, FLOAT_MAX));
      for (const name of ["panningModel", "distanceModel", "refDistance", "maxDistance", "rolloffFactor", "coneInnerAngle", "coneOuterAngle", "coneOuterGain"]) {
        if (o[name] === undefined) continue;
        if (name === "panningModel") this[name] = inEnum(o[name], PANNING, "panningModel");
        else if (name === "distanceModel") this[name] = inEnum(o[name], DISTANCE, "distanceModel");
        else this[name] = o[name];
      }
      const names = ["positionX", "positionY", "positionZ", "orientationX", "orientationY", "orientationZ"];
      for (let i = 0; i < 6; i++) if (o[names[i]] !== undefined) this.#p[i].value = toFloat32(o[names[i]], "PannerNode." + names[i]);
      applyNodeOptions(this, o);
    }
    get positionX() { return this.#p[0]; }
    get positionY() { return this.#p[1]; }
    get positionZ() { return this.#p[2]; }
    get orientationX() { return this.#p[3]; }
    get orientationY() { return this.#p[4]; }
    get orientationZ() { return this.#p[5]; }
    get panningModel() { return this.#a.panningModel; }
    set panningModel(v) { const x = S(v); if (PANNING.includes(x)) this.#a.panningModel = x; }
    get distanceModel() { return this.#a.distanceModel; }
    set distanceModel(v) {
      const x = S(v);
      if (!DISTANCE.includes(x)) return;
      this.#a.distanceModel = x;
      ATTR(this, F.DistanceModel, DISTANCE.indexOf(x), nodeState(this));
    }
    get refDistance() { return this.#a.refDistance; }
    set refDistance(v) {
      const x = float(v, "refDistance");
      if (x < 0) throw new RE("refDistance: it is negative.");
      this.#a.refDistance = x;
      ATTR(this, F.RefDistance, x, nodeState(this));
    }
    get maxDistance() { return this.#a.maxDistance; }
    set maxDistance(v) {
      const x = float(v, "maxDistance");
      if (x <= 0) throw new RE("maxDistance: it is not positive.");
      this.#a.maxDistance = x;
      ATTR(this, F.MaxDistance, x, nodeState(this));
    }
    get rolloffFactor() { return this.#a.rolloffFactor; }
    set rolloffFactor(v) {
      const x = float(v, "rolloffFactor");
      if (x < 0) throw new RE("rolloffFactor: it is negative.");
      this.#a.rolloffFactor = x;
      ATTR(this, F.Rolloff, x, nodeState(this));
    }
    get coneInnerAngle() { return this.#a.coneInnerAngle; }
    set coneInnerAngle(v) { const x = float(v, "coneInnerAngle"); this.#a.coneInnerAngle = x; ATTR(this, F.ConeInner, x, nodeState(this)); }
    get coneOuterAngle() { return this.#a.coneOuterAngle; }
    set coneOuterAngle(v) { const x = float(v, "coneOuterAngle"); this.#a.coneOuterAngle = x; ATTR(this, F.ConeOuter, x, nodeState(this)); }
    get coneOuterGain() { return this.#a.coneOuterGain; }
    set coneOuterGain(v) {
      const x = float(v, "coneOuterGain");
      if (x < 0 || x > 1) throw dom("InvalidStateError", "coneOuterGain: it is outside [0, 1].");
      this.#a.coneOuterGain = x;
      ATTR(this, F.ConeOuterGain, x, nodeState(this));
    }
    setPosition(x, y, z) {
      if (arguments.length < 3) throw new TE("setPosition: 3 arguments required.");
      const v = [toFloat32(x, "setPosition"), toFloat32(y, "setPosition"), toFloat32(z, "setPosition")];
      for (let i = 0; i < 3; i++) this.#p[i].value = v[i];
    }
    setOrientation(x, y, z) {
      if (arguments.length < 3) throw new TE("setOrientation: 3 arguments required.");
      const v = [toFloat32(x, "setOrientation"), toFloat32(y, "setOrientation"), toFloat32(z, "setOrientation")];
      for (let i = 0; i < 3; i++) this.#p[3 + i].value = v[i];
    }
  }

  // ---- ChannelSplitterNode, ChannelMergerNode ----
  class ChannelSplitterNode extends AudioNode {
    constructor(context, options = undefined) {
      if (arguments.length < 1) throw new TE("ChannelSplitterNode: 1 argument required.");
      contextArg(context, "ChannelSplitterNode");
      const o = dict(options, "ChannelSplitterNode");
      const n = o.numberOfOutputs === undefined ? SPLIT_DEFAULT : uint32(o.numberOfOutputs);
      if (n < 1 || n > MAX_CHANNELS) throw dom("IndexSizeError", `ChannelSplitterNode: ${n} outputs is not between 1 and ${MAX_CHANNELS}.`);
      super(TOKEN, context, K.Splitter, 1, n, n, 0, "explicit", n, "discrete");
      applyNodeOptions(this, o);
    }
  }
  class ChannelMergerNode extends AudioNode {
    constructor(context, options = undefined) {
      if (arguments.length < 1) throw new TE("ChannelMergerNode: 1 argument required.");
      contextArg(context, "ChannelMergerNode");
      const o = dict(options, "ChannelMergerNode");
      const n = o.numberOfInputs === undefined ? SPLIT_DEFAULT : uint32(o.numberOfInputs);
      if (n < 1 || n > MAX_CHANNELS) throw dom("IndexSizeError", `ChannelMergerNode: ${n} inputs is not between 1 and ${MAX_CHANNELS}.`);
      super(TOKEN, context, K.Merger, n, 1, n, 0, "explicit", 1, "speakers");
      applyNodeOptions(this, o);
    }
  }

  // ---- DynamicsCompressorNode ----
  class DynamicsCompressorNode extends AudioNode {
    #p;
    constructor(context, options = undefined) {
      if (arguments.length < 1) throw new TE("DynamicsCompressorNode: 1 argument required.");
      contextArg(context, "DynamicsCompressorNode");
      const o = dict(options, "DynamicsCompressorNode");
      super(TOKEN, context, K.Compressor, 1, 1, 0, 0, "clamped-max");
      this.#p = [param(this, 0, -24, -100, 0, "k-rate", true), param(this, 1, 30, 0, 40, "k-rate", true), param(this, 2, 12, 1, 20, "k-rate", true), param(this, 3, 0.003, 0, 1, "k-rate", true), param(this, 4, 0.25, 0, 1, "k-rate", true)];
      const names = ["threshold", "knee", "ratio", "attack", "release"];
      for (let i = 0; i < 5; i++) if (o[names[i]] !== undefined) this.#p[i].value = toFloat32(o[names[i]], "DynamicsCompressorNode." + names[i]);
      applyNodeOptions(this, o);
    }
    get threshold() { return this.#p[0]; }
    get knee() { return this.#p[1]; }
    get ratio() { return this.#p[2]; }
    get attack() { return this.#p[3]; }
    get release() { return this.#p[4]; }
    get reduction() { const s = nodeState(this); return native.nodeGet(s.ctx.graph, s.id, F.Reduction); }
  }

  // ---- WaveShaperNode ----
  class WaveShaperNode extends AudioNode {
    #curve = null;
    #oversample = "none";
    #set = false;
    constructor(context, options = undefined) {
      if (arguments.length < 1) throw new TE("WaveShaperNode: 1 argument required.");
      contextArg(context, "WaveShaperNode");
      const o = dict(options, "WaveShaperNode");
      super(TOKEN, context, K.WaveShaper, 1, 1);
      if (o.curve !== undefined && o.curve !== null) {
        const c = floats(o.curve, "WaveShaperNode.curve");
        this.curve = c;
      }
      if (o.oversample !== undefined) this.oversample = inEnum(o.oversample, OVERSAMPLES, "WaveShaperNode.oversample");
      applyNodeOptions(this, o);
    }
    get curve() { return this.#curve; }
    set curve(v) {
      const s = nodeState(this);
      if (v === null || v === undefined) {
        this.#curve = null;
        native.setCurve(s.ctx.graph, s.id, null);
        return;
      }
      needF32(v, "curve");
      if (this.#set) throw dom("InvalidStateError", "curve: it was set already.");
      if (v.length < 2) throw dom("InvalidStateError", "curve: fewer than 2 values.");
      this.#set = true;
      this.#curve = new F32(v);
      native.setCurve(s.ctx.graph, s.id, this.#curve);
    }
    get oversample() { return this.#oversample; }
    set oversample(v) {
      const x = S(v), s = nodeState(this);
      if (!OVERSAMPLES.includes(x)) return;
      this.#oversample = x;
      native.nodeSet(s.ctx.graph, s.id, F.Oversample, OVERSAMPLES.indexOf(x));
    }
  }

  // ---- AnalyserNode ----
  class AnalyserNode extends AudioNode {
    #fft = 2048;
    #min = -100;
    #max = -30;
    #smoothing = 0.8;
    constructor(context, options = undefined) {
      if (arguments.length < 1) throw new TE("AnalyserNode: 1 argument required.");
      contextArg(context, "AnalyserNode");
      const o = dict(options, "AnalyserNode");
      super(TOKEN, context, K.Analyser, 1, 1);
      if (o.fftSize !== undefined) this.fftSize = uint32(o.fftSize);
      const min = o.minDecibels === undefined ? -100 : float(o.minDecibels, "minDecibels");
      const max = o.maxDecibels === undefined ? -30 : float(o.maxDecibels, "maxDecibels");
      if (min >= max) throw dom("IndexSizeError", "AnalyserNode: minDecibels is not below maxDecibels.");
      this.#min = min;
      this.#max = max;
      const s = nodeState(this);
      native.nodeSet(s.ctx.graph, s.id, F.MinDb, min);
      native.nodeSet(s.ctx.graph, s.id, F.MaxDb, max);
      if (o.smoothingTimeConstant !== undefined) this.smoothingTimeConstant = float(o.smoothingTimeConstant, "smoothingTimeConstant");
      applyNodeOptions(this, o);
    }
    get fftSize() { return this.#fft; }
    set fftSize(v) {
      const n = uint32(v), s = nodeState(this);
      if (n < FFT_MIN || n > FFT_MAX || (n & (n - 1)) !== 0) throw dom("IndexSizeError", `fftSize: ${n} is not a power of 2 between ${FFT_MIN} and ${FFT_MAX}.`);
      this.#fft = n;
      native.nodeSet(s.ctx.graph, s.id, F.FftSize, n);
    }
    get frequencyBinCount() { return this.#fft / 2; }
    get minDecibels() { return this.#min; }
    set minDecibels(v) {
      const x = float(v, "minDecibels"), s = nodeState(this);
      if (x >= this.#max) throw dom("IndexSizeError", "minDecibels: it is not below maxDecibels.");
      this.#min = x;
      native.nodeSet(s.ctx.graph, s.id, F.MinDb, x);
    }
    get maxDecibels() { return this.#max; }
    set maxDecibels(v) {
      const x = float(v, "maxDecibels"), s = nodeState(this);
      if (x <= this.#min) throw dom("IndexSizeError", "maxDecibels: it is not above minDecibels.");
      this.#max = x;
      native.nodeSet(s.ctx.graph, s.id, F.MaxDb, x);
    }
    get smoothingTimeConstant() { return this.#smoothing; }
    set smoothingTimeConstant(v) {
      const x = float(v, "smoothingTimeConstant"), s = nodeState(this);
      if (x < 0 || x > 1) throw dom("IndexSizeError", "smoothingTimeConstant: it is outside [0, 1].");
      this.#smoothing = x;
      native.nodeSet(s.ctx.graph, s.id, F.Smoothing, x);
    }
    #read(what, array, type, name) {
      if (!(array instanceof type)) throw new TE(`${name}: the array is not a ${type.name}.`);
      if (array.length === 0) return;
      const s = nodeState(this);
      native.analyserRead(s.ctx.graph, s.id, what, array);
    }
    getFloatFrequencyData(array) { if (arguments.length < 1) throw new TE("getFloatFrequencyData: 1 argument required."); this.#read(0, array, F32, "getFloatFrequencyData"); }
    getByteFrequencyData(array) { if (arguments.length < 1) throw new TE("getByteFrequencyData: 1 argument required."); this.#read(1, array, U8, "getByteFrequencyData"); }
    getFloatTimeDomainData(array) { if (arguments.length < 1) throw new TE("getFloatTimeDomainData: 1 argument required."); this.#read(2, array, F32, "getFloatTimeDomainData"); }
    getByteTimeDomainData(array) { if (arguments.length < 1) throw new TE("getByteTimeDomainData: 1 argument required."); this.#read(3, array, U8, "getByteTimeDomainData"); }
  }

  // ---- ConvolverNode ----
  class ConvolverNode extends AudioNode {
    #buffer = null;
    #normalize = true;
    constructor(context, options = undefined) {
      if (arguments.length < 1) throw new TE("ConvolverNode: 1 argument required.");
      contextArg(context, "ConvolverNode");
      const o = dict(options, "ConvolverNode");
      super(TOKEN, context, K.Convolver, 1, 1, 0, 0, "clamped-max");
      this.#normalize = !o.disableNormalization;
      if (o.buffer !== undefined && o.buffer !== null) this.buffer = o.buffer;
      applyNodeOptions(this, o);
    }
    get buffer() { return this.#buffer; }
    set buffer(v) {
      const s = nodeState(this);
      if (v === null || v === undefined) {
        this.#buffer = null;
        native.setConvolver(s.ctx.graph, s.id, null, this.#normalize);
        return;
      }
      if (!(v instanceof AudioBuffer)) throw new TE("buffer: not an AudioBuffer.");
      const n = v.numberOfChannels;
      if (n !== 1 && n !== 2 && n !== 4) throw dom("NotSupportedError", `buffer: ${n} channels (1, 2 or 4).`);
      if (v.sampleRate !== s.ctx.rate) throw dom("NotSupportedError", "buffer: its sample rate is not the context's.");
      this.#buffer = v;
      native.setConvolver(s.ctx.graph, s.id, bufferHost(v, true), this.#normalize);
    }
    get normalize() { return this.#normalize; }
    set normalize(v) { this.#normalize = !!v; }
  }

  // ---- ScriptProcessorNode and its event ----
  class AudioProcessingEvent extends Ev {
    #e;
    constructor(type, init) {
      if (arguments.length < 2) throw new TE("AudioProcessingEvent: 2 arguments required.");
      const o = dict(init, "AudioProcessingEvent");
      if (o.playbackTime === undefined || o.inputBuffer === undefined || o.outputBuffer === undefined) throw new TE("AudioProcessingEvent: playbackTime, inputBuffer and outputBuffer are required.");
      const t = float(o.playbackTime, "playbackTime");
      if (!(o.inputBuffer instanceof AudioBuffer) || !(o.outputBuffer instanceof AudioBuffer)) throw new TE("AudioProcessingEvent: the buffers are not AudioBuffers.");
      super(type, o);
      this.#e = { playbackTime: t, inputBuffer: o.inputBuffer, outputBuffer: o.outputBuffer };
    }
    get playbackTime() { return this.#e.playbackTime; }
    get inputBuffer() { return this.#e.inputBuffer; }
    get outputBuffer() { return this.#e.outputBuffer; }
  }
  class ScriptProcessorNode extends AudioNode {
    constructor() {
      if (arguments[0] !== TOKEN) illegal("ScriptProcessorNode");
      const [, context, size, inCh, outCh] = arguments;
      super(TOKEN, context, K.Script, 1, 1, size, inCh << 8 | outCh, "explicit", Math.max(inCh, 1));
      const s = nodeState(this);
      s.size = size;
      s.inCh = inCh;
      s.outCh = outCh;
      s.inData = new F32(size * inCh);
      s.outData = new F32(size * outCh);
      s.ctx.scripts.set(s.id, this);
    }
    get bufferSize() { return of(this, K.Script).size; }
  }
  handlerAttr(ScriptProcessorNode.prototype, "audioprocess", nodeState);
  const scriptBlock = (ctx, node) => {
    const s = nodeState(node);
    native.scriptPull(ctx.graph, s.id, s.inData);
    const input = new AudioBuffer({ numberOfChannels: Math.max(s.inCh, 1), length: s.size, sampleRate: ctx.rate });
    const output = new AudioBuffer({ numberOfChannels: Math.max(s.outCh, 1), length: s.size, sampleRate: ctx.rate });
    for (let c = 0; c < s.inCh; c++) input.getChannelData(c).set(s.inData.subarray(c * s.size, (c + 1) * s.size));
    const e = new AudioProcessingEvent("audioprocess", { playbackTime: native.time(ctx.graph) + s.size / ctx.rate, inputBuffer: input, outputBuffer: output });
    apply(dispatch, node, [e]);
    for (let c = 0; c < s.outCh; c++) s.outData.set(output.getChannelData(c), c * s.size);
    native.scriptPush(ctx.graph, s.id, s.outData);
  };

  // ---- MediaElementAudioSourceNode ----
  class MediaElementAudioSourceNode extends AudioNode {
    #element;
    constructor(context, options = undefined) {
      if (arguments.length < 2) throw new TE("MediaElementAudioSourceNode: 2 arguments required.");
      if (!(context instanceof AudioContext)) throw new TE("MediaElementAudioSourceNode: the first argument is not an AudioContext.");
      const o = dict(options, "MediaElementAudioSourceNode");
      if (!(o.mediaElement instanceof global.HTMLMediaElement)) throw new TE("MediaElementAudioSourceNode: mediaElement is not an HTMLMediaElement.");
      if (captured.has(o.mediaElement)) throw dom("InvalidStateError", "This media element is connected to a MediaElementAudioSourceNode already.");
      super(TOKEN, context, K.Element, 0, 1);
      captured.add(o.mediaElement);
      this.#element = o.mediaElement;
      const s = nodeState(this);
      native.captureElement(s.ctx.graph, s.id, o.mediaElement);
      s.ctx.scripts.set(s.id, this);    // (it lasts as long as the context: it has no other way to be found again)
    }
    get mediaElement() { return this.#element; }
  }
  const captured = new WeakSet();

  // ---- AudioWorklet ----
  // The realm is a worker of this document with a worklet's scope (web_audio_worklet.js), started by the first addModule. Its
  // Worker object stays alive while it runs and its listeners with it, so they hold this state, not the context: a context a
  // page has let go of is collected, which stops the realm (bindings_webaudio.odin).
  const NativeWorker = global.Worker, MC = global.MessageChannel, Url = global.URL, ErrorEv = global.ErrorEvent, doc = global.document;
  const workerPost = NativeWorker?.prototype.postMessage;
  const WeakRefC = WeakRef;
  const WORKLET_MAX_PORTS = 256, WORKLET_MAX_PARAMS = 1024;   // (src/webaudio/worklet.odin)

  const workletEvent = (node, info) => {
    const s = nodeState(node);
    s.ctx.scripts.delete(s.id);   // (it gives nothing any more: the page may let it go)
    if (s.errored) return;
    s.errored = true;
    apply(dispatch, node, [new ErrorEv("processorerror", { message: info?.message ?? "The AudioWorklet's realm has stopped.", filename: info?.filename ?? "", lineno: info?.lineno ?? 0, colno: info?.colno ?? 0 })]);
  };

  const workletState = port2 => ({
    worker: null, port2, stopped: false,
    names: new MapC(),     // what registerProcessor said: name -> parameter descriptors
    modules: new MapC(),   // addModule() in progress
    nextModule: 1, nextProcessor: 1,
    nodes: new MapC(),     // id in the graph -> {processor, ref (weak)}: what the realm's news is about
  });

  const workletMessage = (ws, m) => {
    switch (m.t) {
      case "registered":
        ws.names.set(m.name, m.descriptors);
        break;
      case "module": {
        const pending = ws.modules.get(m.id);
        ws.modules.delete(m.id);
        if (!pending) break;
        if (m.ok) pending.resolve();
        else if (m.fetch) pending.reject(dom("AbortError", `addModule: the module could not be loaded: ${m.message}`));
        else pending.reject(m.name === "SyntaxError" ? new SyntaxError(m.message) : dom("AbortError", `addModule: the module failed: ${m.message}`));
        break;
      }
      case "processorerror":
        for (const entry of ws.nodes.values()) {
          if (entry.processor !== m.processor) continue;
          const node = entry.ref.deref();
          if (node !== undefined) workletEvent(node, m);
          break;
        }
        break;
    }
  };

  const workletRealm = s => {
    const ws = s.worklet;
    if (ws.worker !== null) return true;
    if (ws.stopped) return false;
    const worker = native.workletStart(s.graph);
    if (worker === null) return false;
    ws.worker = worker;
    apply(addListener, worker, ["message", e => workletMessage(ws, e.data)]);
    // (an uncaught exception of the realm stays there: the document's onerror is not told, the console is)
    apply(addListener, worker, ["error", e => {
      e.preventDefault();
      global.console.error(`[AudioWorklet] ${e.message}`);
      for (const pending of ws.modules.values()) pending.reject(dom("AbortError", "addModule: the AudioWorklet's realm has failed."));
      ws.modules.clear();
    }]);
    apply(workerPost, worker, [{ t: "port", port: ws.port2 }, [ws.port2]]);
    ws.port2 = null;
    return true;
  };

  class Worklet {
    constructor() { if (arguments[0] !== TOKEN) illegal("Worklet"); }
  }
  class AudioWorklet extends Worklet {
    #s;
    #port;
    static {
      makeWorklet = s => {
        const a = new AudioWorklet(TOKEN);
        const channel = new MC();
        a.#s = s;
        a.#port = channel.port1;
        s.worklet = workletState(channel.port2);
        return a;
      };
    }
    constructor() { if (arguments[0] !== TOKEN) illegal("AudioWorklet"); super(TOKEN); }
    get port() { return this.#port; }
    addModule(moduleURL, options = undefined) {
      return new P((resolve, reject) => {
        const s = this.#s;
        if (arguments.length < 1) throw new TE("addModule: 1 argument required.");
        let target;
        const text = S(moduleURL);
        const o = dict(options, "addModule");
        if (o.credentials !== undefined) inEnum(o.credentials, ["omit", "same-origin", "include"], "addModule");
        try { target = new Url(text, doc.baseURI).href; } catch { reject(dom("SyntaxError", `addModule: '${text}' is not a valid URL.`)); return; }
        if (s.state === "closed" && !s.offline) { reject(dom("InvalidStateError", "addModule: the context is closed.")); return; }
        if (!workletRealm(s)) { reject(dom("AbortError", "addModule: the AudioWorklet could not start (workers are disabled, or too many run).")); return; }
        const ws = s.worklet, id = ws.nextModule++;
        ws.modules.set(id, { resolve, reject });
        apply(workerPost, ws.worker, [{ t: "module", id, url: target, frame: Math.floor(native.time(s.graph) * s.rate) }]);
      });
    }
  }

  class AudioParamMap {
    #map;
    static {
      makeParamMap = map => {
        const m = new AudioParamMap(TOKEN);
        m.#map = map;
        return m;
      };
    }
    constructor() { if (arguments[0] !== TOKEN) illegal("AudioParamMap"); }
    get size() { return this.#map.size; }
    get(name) { return this.#map.get(S(name)); }
    has(name) { return this.#map.has(S(name)); }
    keys() { return this.#map.keys(); }
    values() { return this.#map.values(); }
    entries() { return this.#map.entries(); }
    forEach(callback, thisArg = undefined) {
      if (typeof callback !== "function") throw new TE("forEach: the callback is not a function.");
      for (const [key, value] of this.#map) apply(callback, thisArg, [value, key, this]);
    }
  }
  defineProperty(AudioParamMap.prototype, Symbol.iterator, { value: AudioParamMap.prototype.entries, writable: true, enumerable: false, configurable: true });

  class AudioWorkletNode extends AudioNode {
    #port;
    #parameters;
    constructor(context, name, options = undefined) {
      if (arguments.length < 2) throw new TE("AudioWorkletNode: 2 arguments required.");
      contextArg(context, "AudioWorkletNode");
      const nodeName = S(name);
      const o = dict(options, "AudioWorkletNode");
      const inputs = o.numberOfInputs === undefined ? 1 : uint32(o.numberOfInputs);
      const outputs = o.numberOfOutputs === undefined ? 1 : uint32(o.numberOfOutputs);
      let outputChannels;
      if (o.outputChannelCount !== undefined) {
        if (o.outputChannelCount === null || typeof o.outputChannelCount !== "object" || o.outputChannelCount[Symbol.iterator] === undefined) throw new TE("AudioWorkletNode: outputChannelCount is not a sequence.");
        outputChannels = [];
        for (const c of o.outputChannelCount) outputChannels.push(uint32(c));
      }
      let parameterData;
      if (o.parameterData !== undefined) {
        const d = o.parameterData;
        if (d === null || (typeof d !== "object" && typeof d !== "function")) throw new TE("AudioWorkletNode: parameterData is not a record.");
        parameterData = { __proto__: null };
        for (const k of ownKeys(d)) {
          if (typeof k !== "string") continue;
          const desc = getOwnPropertyDescriptor(d, k);
          if (desc?.enumerable) parameterData[k] = float(d[k], "AudioWorkletNode.parameterData");
        }
      }
      if (o.processorOptions !== undefined && o.processorOptions !== null && typeof o.processorOptions !== "object" && typeof o.processorOptions !== "function") throw new TE("AudioWorkletNode: processorOptions is not an object.");
      const channelCount = o.channelCount === undefined ? undefined : uint32(o.channelCount);
      const channelMode = o.channelCountMode === undefined ? undefined : inEnum(o.channelCountMode, CHANNEL_MODES, "channelCountMode");
      const channelInterp = o.channelInterpretation === undefined ? undefined : inEnum(o.channelInterpretation, INTERPS, "channelInterpretation");
      if (inputs === 0 && outputs === 0) throw dom("NotSupportedError", "AudioWorkletNode: it has neither inputs nor outputs.");
      if (inputs > WORKLET_MAX_PORTS || outputs > WORKLET_MAX_PORTS) throw dom("NotSupportedError", "AudioWorkletNode: too many inputs or outputs.");
      if (outputChannels !== undefined) {
        if (outputChannels.length !== outputs) throw dom("IndexSizeError", "AudioWorkletNode: outputChannelCount does not have one count per output.");
        for (const c of outputChannels) if (c < 1 || c > MAX_CHANNELS) throw dom("NotSupportedError", `AudioWorkletNode: ${c} channels is not between 1 and ${MAX_CHANNELS}.`);
      }
      if (channelCount !== undefined && (channelCount < 1 || channelCount > MAX_CHANNELS)) throw dom("NotSupportedError", `channelCount: ${channelCount} is not between 1 and ${MAX_CHANNELS}.`);
      const cs = ctxState(context);
      if (cs.worklet === undefined) { apply(getWorklet, context, []); }
      const ws = cs.worklet;
      const descriptors = ws.names.get(nodeName);
      if (descriptors === undefined) throw dom("InvalidStateError", `AudioWorkletNode: no processor is registered as '${nodeName}'.`);
      if (descriptors.length > WORKLET_MAX_PARAMS) throw dom("NotSupportedError", "AudioWorkletNode: too many parameters.");
      if (ws.worker === null || ws.stopped) throw dom("InvalidStateError", "AudioWorkletNode: the AudioWorklet's realm has stopped.");
      // the realm first: what cannot be serialized fails here, with nothing made
      const channel = new MC();
      const processor = ws.nextProcessor++;
      const nodeOptions = { numberOfInputs: inputs, numberOfOutputs: outputs };
      if (channelCount !== undefined) nodeOptions.channelCount = channelCount;
      if (channelMode !== undefined) nodeOptions.channelCountMode = channelMode;
      if (channelInterp !== undefined) nodeOptions.channelInterpretation = channelInterp;
      if (outputChannels !== undefined) nodeOptions.outputChannelCount = outputChannels;
      if (parameterData !== undefined) nodeOptions.parameterData = { ...parameterData };
      if (o.processorOptions !== undefined) nodeOptions.processorOptions = o.processorOptions;
      apply(workerPost, ws.worker, [{
        t: "create", processor, name: nodeName, names: descriptors.map(d => d.name), options: nodeOptions, port: channel.port2,
        frame: Math.floor(native.time(cs.graph) * cs.rate),   // (a suspended context's frame, as currentTime * sampleRate reads)
      }, [channel.port2]]);
      const id = native.workletNode(cs.graph, inputs, outputs, descriptors.length, processor, new Int32Array(outputChannels ?? []));
      if (id < 0) throw dom("NotSupportedError", "AudioWorkletNode: the node could not be made.");
      super(TOKEN, context, K.Worklet, inputs, outputs, id);
      const s = nodeState(this);
      this.#port = channel.port1;
      const params = new MapC();
      descriptors.forEach((d, i) => {
        native.workletParam(cs.graph, id, i, d.defaultValue, d.minValue, d.maxValue, d.automationRate === "a-rate");
        const p = makeParam(cs, id, i, d.defaultValue, d.minValue, d.maxValue, d.automationRate);
        if (parameterData !== undefined && d.name in parameterData) p.value = parameterData[d.name];
        params.set(d.name, p);
      });
      this.#parameters = makeParamMap(params);
      if (channelCount !== undefined) this.channelCount = channelCount;
      if (channelMode !== undefined) this.channelCountMode = channelMode;
      if (channelInterp !== undefined) this.channelInterpretation = channelInterp;
      s.processor = processor;
      // (alive while its processor is at work: the page may hold nothing of it and still hear it)
      cs.scripts.set(id, this);
      ws.nodes.set(id, { processor, ref: new WeakRefC(this) });
    }
    get parameters() { return this.#parameters; }
    get port() { return this.#port; }
  }
  handlerAttr(AudioWorkletNode.prototype, "processorerror", nodeState);

  // ---- BaseAudioContext ----
  class BaseAudioContext extends ET {
    #s;
    static {
      ctxState = c => c.#s;
      isContext = c => typeof c === "object" && c !== null && #s in c;
    }
    constructor() {
      if (arguments[0] !== TOKEN) illegal("BaseAudioContext");
      super();
      const [, rate, channels, maxChannels, frames, latency] = arguments;
      const user = nextContext++;
      const graph = native.create(rate, channels, frames, latency, user);
      if (graph === null) throw dom("NotSupportedError", "Too many AudioContexts (webaudio.max_contexts).");
      const offline = frames > 0;
      const s = this.#s = {
        self: this, user, graph, rate, offline, state: "suspended",
        active: new MapC(), scripts: new MapC(), pendingResume: [], pendingSuspend: [], pendingClose: [],
        handlers: null, rendering: null, frames, suspends: new MapC(),
      };
      // (the browser can talk to it from now on; an offline one only once it renders: until then the collector may have it)
      if (!offline) contexts.set(user, s);
      s.destination = makeDestination(this, channels, maxChannels, offline);
      s.listener = makeListener(s);
    }
    get destination() { return this.#s.destination; }
    get sampleRate() { return this.#s.rate; }
    get currentTime() { return native.time(this.#s.graph); }
    get listener() { return this.#s.listener; }
    get state() { return this.#s.state; }
    get renderQuantumSize() { this.#s; return QUANTUM; }
    get audioWorklet() {
      const s = this.#s;
      return s.audioWorklet ?? (s.audioWorklet = makeWorklet(s));
    }
    createIIRFilter(feedforward, feedback) {
      if (arguments.length < 2) throw new TE("createIIRFilter: 2 arguments required.");
      return new IIRFilterNode(this, { feedforward, feedback });
    }
    createAnalyser() { return new AnalyserNode(this); }
    createBiquadFilter() { return new BiquadFilterNode(this); }
    createBuffer(numberOfChannels, length, sampleRate) {
      if (arguments.length < 3) throw new TE("createBuffer: 3 arguments required.");
      return new AudioBuffer({ numberOfChannels: uint32(numberOfChannels), length: uint32(length), sampleRate: float(sampleRate, "createBuffer") });
    }
    createBufferSource() { return new AudioBufferSourceNode(this); }
    createChannelMerger(numberOfInputs = SPLIT_DEFAULT) {
      return new ChannelMergerNode(this, { numberOfInputs: uint32(numberOfInputs) });
    }
    createChannelSplitter(numberOfOutputs = SPLIT_DEFAULT) {
      return new ChannelSplitterNode(this, { numberOfOutputs: uint32(numberOfOutputs) });
    }
    createConstantSource() { return new ConstantSourceNode(this); }
    createConvolver() { return new ConvolverNode(this); }
    createDelay(maxDelayTime = DELAY_DEFAULT) { return new DelayNode(this, { maxDelayTime: float(maxDelayTime, "createDelay") }); }
    createDynamicsCompressor() { return new DynamicsCompressorNode(this); }
    createGain() { return new GainNode(this); }
    createOscillator() { return new OscillatorNode(this); }
    createPanner() { return new PannerNode(this); }
    createPeriodicWave(real, imag, constraints = undefined) {
      if (arguments.length < 2) throw new TE("createPeriodicWave: 2 arguments required.");
      const c = dict(constraints, "createPeriodicWave");
      return new PeriodicWave(this, { real: floats(real, "createPeriodicWave"), imag: floats(imag, "createPeriodicWave"), disableNormalization: !!c.disableNormalization });
    }
    createScriptProcessor(bufferSize = 0, numberOfInputChannels = 2, numberOfOutputChannels = 2) {
      let size = uint32(bufferSize);
      const inCh = uint32(numberOfInputChannels), outCh = uint32(numberOfOutputChannels);
      if (size === 0) size = SCRIPT_DEFAULT;
      if (size < SCRIPT_MIN || size > SCRIPT_MAX || (size & (size - 1)) !== 0) throw dom("IndexSizeError", `createScriptProcessor: the buffer size ${size} is not a power of 2 between ${SCRIPT_MIN} and ${SCRIPT_MAX}.`);
      if (inCh > MAX_CHANNELS || outCh > MAX_CHANNELS || (inCh === 0 && outCh === 0)) throw dom("IndexSizeError", "createScriptProcessor: the numbers of channels are not valid.");
      return new ScriptProcessorNode(TOKEN, this, size, inCh, outCh);
    }
    createStereoPanner() { return new StereoPannerNode(this); }
    createWaveShaper() { return new WaveShaperNode(this); }
    decodeAudioData(audioData, successCallback = undefined, errorCallback = undefined) {
      return new P((resolve, reject) => {
        const s = this.#s;
        if (arguments.length < 1 || !(audioData instanceof AB)) throw new TE("decodeAudioData: the first argument is not an ArrayBuffer.");
        const ok = successCallback === undefined || successCallback === null ? null : successCallback;
        const bad = errorCallback === undefined || errorCallback === null ? null : errorCallback;
        if (ok !== null && typeof ok !== "function") throw new TE("decodeAudioData: successCallback is not a function.");
        if (bad !== null && typeof bad !== "function") throw new TE("decodeAudioData: errorCallback is not a function.");
        if (abDetached && apply(abDetached, audioData, [])) {
          const e = dom("DataCloneError", "decodeAudioData: the ArrayBuffer is detached.");
          if (bad) microtask(() => apply(bad, undefined, [e]));
          reject(e);
          return;
        }
        // (the browser copies what it needs before this returns; the array is the browser's from now on: it is detached)
        const started = native.decode(audioData, s.rate);
        if (abTransfer) apply(abTransfer, audioData, []);
        started.then(host => {
          const b = bufferOfHost(host);
          if (ok) { try { apply(ok, undefined, [b]); } catch (e) { reportError(e); } }
          resolve(b);
        }, e => {
          if (bad) { try { apply(bad, undefined, [e]); } catch (x) { reportError(x); } }
          reject(e);
        });
      });
    }
  }
  const reportError = e => { if (global.reportError) global.reportError(e); };
  handlerAttr(BaseAudioContext.prototype, "statechange", c => ctxState(c));
  const getWorklet = getOwnPropertyDescriptor(BaseAudioContext.prototype, "audioWorklet").get;

  // What the render thread has to say
  const settleAll = (list, how, v) => {
    const l = list.splice(0);
    for (const p of l) p[how](v);
  };
  // The state changes, what waited for it is settled, and its event comes after those promises' reactions.
  const setState = (s, name, settle) => {
    const changed = s.state !== name;
    s.state = name;
    if (settle) settle();
    if (changed) microtask(() => apply(dispatch, s.self, [new Ev("statechange")]));
  };
  const stateEvent = (s, value) => {
    const name = STATE_NAMES[value];
    if (s.offline) {
      if (value === 2) {
        // the rendering is over
        const host = native.takeResult(s.graph);
        const r = s.rendering;
        s.rendering = null;
        contexts.delete(s.user);
        s.active.clear();
        s.scripts.clear();
        if (!r) { setState(s, "closed"); return; }
        if (host === null) {
          setState(s, "closed", () => r.reject(dom("InvalidStateError", "The rendering could not be kept.")));
          return;
        }
        const buffer = bufferOfHost(host);
        setState(s, "closed", () => r.resolve(buffer));
        microtask(() => apply(dispatch, s.self, [new OfflineAudioCompletionEvent("complete", { renderedBuffer: buffer })]));
        return;
      }
      setState(s, name);
      return;
    }
    if (value === 1) {

      setState(s, name, () => settleAll(s.pendingResume, "resolve", undefined));
    } else if (value === 0) {
      setState(s, name, () => settleAll(s.pendingSuspend, "resolve", undefined));
    } else {
      contexts.delete(s.user);
      s.active.clear();
      s.scripts.clear();
      if (s.worklet) {
        s.worklet.stopped = true;
        native.workletStop(s.graph);
      }
      setState(s, name, () => {
        settleAll(s.pendingClose, "resolve", undefined);
        settleAll(s.pendingResume, "reject", dom("InvalidStateError", "The context was closed."));
        settleAll(s.pendingSuspend, "reject", dom("InvalidStateError", "The context was closed."));
      });
    }
  };
  const notify = (user, kind, node, value) => {
    const s = contexts.get(user);
    if (s === undefined) return;
    switch (kind) {
      case EV_STATE:
        stateEvent(s, value);
        break;
      case EV_ENDED: {
        const n = s.active.get(node);
        if (n !== undefined) {
          s.active.delete(node);
          apply(dispatch, n, [new Ev("ended")]);
        }
        break;
      }
      case EV_SCRIPT: {
        const n = s.scripts.get(node);
        if (n !== undefined) scriptBlock(s, n);
        break;
      }
      case EV_OFFLINE_SUSPENDED: {
        const frame = value * QUANTUM;
        const p = s.suspends.get(frame);
        s.suspends.delete(frame);
        setState(s, "suspended", () => { if (p) p.resolve(); });
        break;
      }
      case EV_WORKLET_ERROR: {
        const n = s.worklet?.nodes.get(node)?.ref.deref();
        if (n !== undefined) workletEvent(n, null);
        break;
      }
      case EV_WORKLET_INACTIVE:
        s.scripts.delete(node);
        break;
      case EV_WORKLET_STALLED:
        if (s.worklet) {
          s.worklet.stopped = true;
          native.workletStop(s.graph);
        }
        break;
    }
  };

  // ---- AudioContext ----
  class AudioContext extends BaseAudioContext {
    constructor(contextOptions = undefined) {
      const o = dict(contextOptions, "AudioContext");
      if (!native.fullyActive()) throw dom("InvalidStateError", "AudioContext: the document is not fully active.");
      let rate = native.defaultRate();
      if (o.sampleRate !== undefined) {
        rate = float(o.sampleRate, "AudioContext.sampleRate");
        checkRate(rate, "AudioContext");
      }
      let latency = 0;
      const hint = o.latencyHint;
      if (hint !== undefined) {
        if (typeof hint === "string" || hint instanceof S) {
          const f = LATENCY_FACTOR[S(hint)];
          if (f === undefined) throw new TE(`AudioContext: '${hint}' is not a latency category.`);
          latency = f === 1 ? 0 : -f;
        } else {
          latency = float(hint, "AudioContext.latencyHint");
          if (latency < 0) throw new TE("AudioContext: the latency is negative.");
        }
      }
      super(TOKEN, rate, 2, 2, 0, latency);
      // "allowed to start": the browser decides (media.autoplay.policy), now or at the first click
      native.resume(ctxState(this).graph);
    }
    get sinkId() { ctxState(this); return ""; }
    get baseLatency() { return QUANTUM / ctxState(this).rate; }
    get outputLatency() { const s = ctxState(this); return s.state === "closed" ? 0 : native.queued(s.graph); }
    getOutputTimestamp() {
      const s = ctxState(this);
      const t = Math.max(native.time(s.graph) - native.queued(s.graph), 0);
      return { contextTime: t, performanceTime: global.performance.now() };
    }
    resume() {
      return new P((resolve, reject) => {
        const s = ctxState(this);
        if (s.state === "closed") { reject(dom("InvalidStateError", "resume: the context is closed.")); return; }
        if (s.state === "running" && s.pendingSuspend.length === 0) { resolve(); return; }
        s.pendingResume.push({ resolve, reject });
        native.resume(s.graph);
      });
    }
    suspend() {
      return new P((resolve, reject) => {
        const s = ctxState(this);
        if (s.state === "closed") { reject(dom("InvalidStateError", "suspend: the context is closed.")); return; }
        if (native.suspend(s.graph)) {
          s.pendingSuspend.push({ resolve, reject });
        } else {
          resolve();
        }
      });
    }
    close() {
      return new P((resolve, reject) => {
        const s = ctxState(this);
        if (s.state === "closed" || s.closing) { reject(dom("InvalidStateError", "close: the context is closed.")); return; }
        s.closing = true;
        s.pendingClose.push({ resolve, reject });
        native.close(s.graph);
      });
    }
    createMediaElementSource(mediaElement) {
      if (arguments.length < 1) throw new TE("createMediaElementSource: 1 argument required.");
      return new MediaElementAudioSourceNode(this, { mediaElement });
    }
  }

  // ---- OfflineAudioContext ----
  class OfflineAudioCompletionEvent extends Ev {
    #b;
    constructor(type, init) {
      if (arguments.length < 2) throw new TE("OfflineAudioCompletionEvent: 2 arguments required.");
      const o = dict(init, "OfflineAudioCompletionEvent");
      if (!(o.renderedBuffer instanceof AudioBuffer)) throw new TE("OfflineAudioCompletionEvent: renderedBuffer is not an AudioBuffer.");
      super(type, o);
      this.#b = o.renderedBuffer;
    }
    get renderedBuffer() { return this.#b; }
  }
  class OfflineAudioContext extends BaseAudioContext {
    #length;
    #started = false;
    constructor(contextOptions, length = undefined, sampleRate = undefined) {
      let channels, frames, rate;
      if (arguments.length >= 3) {
        channels = uint32(contextOptions);
        frames = uint32(length);
        rate = float(sampleRate, "OfflineAudioContext");
      } else if (arguments.length === 1 && typeof contextOptions === "object" && contextOptions !== null) {
        const o = contextOptions;
        if (o.length === undefined) throw new TE("OfflineAudioContext: length is required.");
        if (o.sampleRate === undefined) throw new TE("OfflineAudioContext: sampleRate is required.");
        channels = o.numberOfChannels === undefined ? 1 : uint32(o.numberOfChannels);
        frames = uint32(o.length);
        rate = float(o.sampleRate, "OfflineAudioContext");
      } else {
        throw new TE("OfflineAudioContext: the arguments are not valid.");
      }
      if (channels < 1 || channels > MAX_CHANNELS) throw dom("NotSupportedError", `OfflineAudioContext: ${channels} channels is not between 1 and ${MAX_CHANNELS}.`);
      if (frames < 1) throw dom("NotSupportedError", "OfflineAudioContext: the length is not positive.");
      checkRate(rate, "OfflineAudioContext");
      if (channels * frames * 4 > native.maxBuffer()) throw dom("NotSupportedError", "OfflineAudioContext: too large (webaudio.max_buffer_mb).");
      super(TOKEN, rate, channels, channels, frames, 0);
      this.#length = frames;
    }
    get length() { return this.#length; }
    startRendering() {
      return new P((resolve, reject) => {
        const s = ctxState(this);
        if (this.#started) { reject(dom("InvalidStateError", "startRendering: it was started already.")); return; }
        this.#started = true;
        s.rendering = { resolve, reject };
        contexts.set(s.user, s);
        if (!native.render(s.graph, this.#length)) reject(dom("InvalidStateError", "The rendering could not start."));
      });
    }
    resume() {
      return new P((resolve, reject) => {
        const s = ctxState(this);
        if (s.state === "closed") { reject(dom("InvalidStateError", "resume: the rendering is over.")); return; }
        if (!this.#started) { reject(dom("InvalidStateError", "resume: the rendering has not started.")); return; }
        if (s.state === "suspended") native.offlineResume(s.graph);
        resolve();
      });
    }
    suspend(suspendTime) {
      return new P((resolve, reject) => {
        const s = ctxState(this);
        if (arguments.length < 1) throw new TE("suspend: 1 argument required.");
        const t = float(suspendTime, "suspend");
        if (t < 0 || t >= this.#length / s.rate) { reject(dom("InvalidStateError", "suspend: the time is outside the rendering.")); return; }
        const frame = Math.ceil(t * s.rate / QUANTUM) * QUANTUM;
        if (s.state === "closed" || s.suspends.has(frame) || !native.offlineSuspend(s.graph, frame)) {
          reject(dom("InvalidStateError", "suspend: there is one at this time already, or it has passed."));
          return;
        }
        s.suspends.set(frame, { resolve, reject });
      });
    }
  }
  handlerAttr(OfflineAudioContext.prototype, "complete", c => ctxState(c));

  // ---- as Web IDL has them ----
  const classes = {
    BaseAudioContext, AudioContext, OfflineAudioContext, AudioBuffer, AudioNode, AudioParam, AudioScheduledSourceNode, AudioDestinationNode,
    AudioListener, AudioBufferSourceNode, OscillatorNode, PeriodicWave, GainNode, ConstantSourceNode, BiquadFilterNode, DelayNode,
    StereoPannerNode, PannerNode, ChannelSplitterNode, ChannelMergerNode, DynamicsCompressorNode, WaveShaperNode, AnalyserNode, ConvolverNode,
    ScriptProcessorNode, AudioProcessingEvent, OfflineAudioCompletionEvent, MediaElementAudioSourceNode, IIRFilterNode,
    Worklet, AudioWorklet, AudioWorkletNode, AudioParamMap,
  };
  // [SecureContext]: elsewhere there is no worklet at all, what a script tests for
  if (!global.isSecureContext) {
    delete classes.Worklet;
    delete classes.AudioWorklet;
    delete classes.AudioWorkletNode;
    delete classes.AudioParamMap;
    delete BaseAudioContext.prototype.audioWorklet;
  }
  for (const name of ownKeys(classes)) {
    const proto = classes[name].prototype;
    for (const key of ownKeys(proto)) {
      if (key === "constructor") continue;
      const d = getOwnPropertyDescriptor(proto, key);
      if (d && !d.enumerable) { d.enumerable = true; defineProperty(proto, key, d); }
    }
    defineProperty(proto, Symbol.toStringTag, { value: name, configurable: true });
  }
  return { __proto__: null, notify, ...classes };
})
