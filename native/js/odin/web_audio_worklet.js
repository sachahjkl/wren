// AudioWorkletGlobalScope (Web Audio API, "The AudioWorklet Interface"): what the realm of an AudioWorklet is, run once when
// its thread starts (web_audio.odin, wj_worklet_boot). The realm is a JavaScript worker of the context's document with the
// scope of a worklet: what is not exposed to worklets is taken off its global, and its prototype is this interface's. The
// page talks to it by the worker's messages (web_audio.js is the other end), the render thread by requests, one per quantum
// (src/webaudio/worklet.odin): the samples are copied in and out of Float32Arrays kept per processor.
(function (native, global, rate) {
  "use strict";
  const { apply, ownKeys, deleteProperty, defineProperty, setPrototypeOf, construct, getPrototypeOf } = Reflect;
  const TE = TypeError, F32 = Float32Array, I32 = Int32Array, S = String, N = Number, MapC = Map, SetC = Set, freeze = Object.freeze;
  const post = global.postMessage, closeScope = global.close, listen = global.addEventListener, DOMEx = global.DOMException;
  const consoleOf = global.console, isFiniteN = N.isFinite, fround = Math.fround, ArrayFrom = Array.from;
  const objectToString = Object.prototype.toString, stringify = S;

  // The numbers of src/webaudio/worklet.odin
  const KEEP_ALIVE = 0, INACTIVE = 1, FAILED = 2, NOT_READY = 3;
  const QUANTUM = 128, LAYOUT_HEADER = 4, LAYOUT_START = 64;
  const PARAM_MAX = 3.4028234663852886e38;

  const say = message => { try { apply(post, global, [message]); } catch (e) { consoleOf.error(e); } };

  // ---- what a script sees ----
  let frame = 0;
  let portOfScope = null;
  const processorClasses = new MapC();
  // What makes `new AudioWorkletProcessor()` work: one port, for the one object being made.
  let pendingPort = null;

  class WorkletGlobalScope {
    constructor() { throw new TE("Illegal constructor: WorkletGlobalScope"); }
  }
  class AudioWorkletGlobalScope extends WorkletGlobalScope {
    constructor() { throw new TE("Illegal constructor: AudioWorkletGlobalScope"); }
    get currentFrame() { return frame; }
    get currentTime() { return frame / rate; }
    get sampleRate() { return rate; }
    get renderQuantumSize() { return QUANTUM; }
    get port() { return portOfScope; }
    registerProcessor(name, processorCtor) {
      if (arguments.length < 2) throw new TE("registerProcessor: 2 arguments required.");
      const n = S(name);
      if (n === "") throw new DOMEx("registerProcessor: the name is empty.", "NotSupportedError");
      if (processorClasses.has(n)) throw new DOMEx(`registerProcessor: '${n}' is registered already.`, "NotSupportedError");
      if (!isConstructor(processorCtor)) throw new TE("registerProcessor: the second argument is not a constructor.");
      const proto = processorCtor.prototype;
      if (proto === null || (typeof proto !== "object" && typeof proto !== "function")) throw new TE("registerProcessor: its prototype is not an object.");
      const descriptors = paramDescriptors(processorCtor.parameterDescriptors);
      processorClasses.set(n, processorCtor);
      say({ t: "registered", name: n, descriptors });
    }
  }
  const isConstructor = f => {
    if (typeof f !== "function") return false;
    try { construct(Object, [], f); return true; } catch { return false; }
  };
  const inRange = (v, what) => {
    const x = N(v);
    if (!isFiniteN(x)) throw new TE(`parameterDescriptors: ${what} is not a finite number.`);
    return fround(x);
  };
  // sequence<AudioParamDescriptor>
  const paramDescriptors = value => {
    if (value === undefined) return [];
    if (value === null || (typeof value !== "object" && typeof value !== "function") || value[Symbol.iterator] === undefined) throw new TE("parameterDescriptors: not a sequence.");
    const list = [], names = new SetC();
    for (const d of value) {
      if (d === null || (typeof d !== "object" && typeof d !== "function")) throw new TE("parameterDescriptors: a descriptor is not an object.");
      if (d.name === undefined) throw new TE("parameterDescriptors: a descriptor has no name.");
      const name = S(d.name);
      const defaultValue = d.defaultValue === undefined ? 0 : inRange(d.defaultValue, "defaultValue");
      const minValue = d.minValue === undefined ? -PARAM_MAX : inRange(d.minValue, "minValue");
      const maxValue = d.maxValue === undefined ? PARAM_MAX : inRange(d.maxValue, "maxValue");
      const automationRate = d.automationRate === undefined ? "a-rate" : S(d.automationRate);
      if (automationRate !== "a-rate" && automationRate !== "k-rate") throw new TE(`parameterDescriptors: '${automationRate}' is not an automation rate.`);
      if (names.has(name)) throw new DOMEx(`parameterDescriptors: '${name}' is there twice.`, "NotSupportedError");
      names.add(name);
      if (defaultValue < minValue || defaultValue > maxValue) throw new DOMEx(`parameterDescriptors: the default value of '${name}' is out of its range.`, "InvalidStateError");
      list.push({ name, defaultValue, minValue, maxValue, automationRate });
    }
    return list;
  };

  class AudioWorkletProcessor {
    #port;
    constructor() {
      if (pendingPort === null) throw new TE("AudioWorkletProcessor: it is only made by an AudioWorkletNode.");
      this.#port = pendingPort;
      pendingPort = null;
    }
    get port() { return this.#port; }
  }

  // ---- the processors ----
  // By the number the page gave them: {object, inputs, outputs, parameters, args, names, ...}.
  const processors = new MapC();

  const errorInfo = e => {
    const info = { message: "", filename: "", lineno: 0, colno: 0 };
    try {
      info.message = e !== null && typeof e === "object" && "message" in e ? `${e.name}: ${e.message}` : stringify(e);
      const stack = e !== null && typeof e === "object" ? e.stack : undefined;
      if (typeof stack === "string") {
        // (the engine's stack: "    at f (url:line:column)")
        const m = /\(?((?:[a-z][a-z0-9+.-]*:)[^\s()]*):(\d+):(\d+)\)?/i.exec(stack);
        if (m) { info.filename = m[1]; info.lineno = N(m[2]); info.colno = N(m[3]); }
      }
    } catch { /* a getter threw: the message stays what it could be */ }
    return info;
  };

  // processorOptions came through a structured clone with what no worklet has an interface for (the specification's clone
  // fails there, DataCloneError, and the node's processorerror says so).
  const UNEXPOSED = new SetC(["[object Blob]", "[object File]", "[object FileList]", "[object ImageBitmap]", "[object ImageData]", "[object DOMRect]", "[object DOMRectReadOnly]",
    "[object DOMPoint]", "[object DOMPointReadOnly]", "[object DOMMatrix]", "[object DOMMatrixReadOnly]", "[object DOMQuad]", "[object CryptoKey]"]);
  const unexposed = (v, seen) => {
    if (v === null || typeof v !== "object" || seen.has(v)) return;
    seen.add(v);
    if (UNEXPOSED.has(apply(objectToString, v, []))) throw new DOMEx("processorOptions: an object of an interface this scope does not have.", "DataCloneError");
    if (v instanceof MapC) { for (const [a, b] of v) { unexposed(a, seen); unexposed(b, seen); } }
    else if (v instanceof SetC) { for (const a of v) unexposed(a, seen); }
    else { for (const k of ownKeys(v)) { if (typeof k === "string") unexposed(v[k], seen); } }
  };

  // The object of a new node: the constructor gets its own port through pendingPort, whatever it does with it.
  const create = m => {
    const entry = {
      object: null, names: m.names, inputs: null, outputs: null, args: [null, null, null], parameters: null,
      inputCounts: [], outputCounts: [], paramLengths: [], inputArrays: [], outputArrays: [],
      paramValues: m.names.map(() => [null, null]),
    };
    const ctor = processorClasses.get(m.name);
    frame = m.frame;
    pendingPort = m.port;
    try {
      unexposed(m.options, new SetC());
      const o = construct(ctor, [m.options]);
      if (o === null || (typeof o !== "object" && typeof o !== "function")) throw new TE("The processor's constructor did not give an object.");
      entry.object = o;
    } catch (e) {
      consoleOf.error(e);
      say({ t: "processorerror", processor: m.processor, ...errorInfo(e) });
      entry.object = null;   // (its quantum says it failed: the node stops asking)
    } finally {
      pendingPort = null;
    }
    processors.set(m.processor, entry);
  };

  // Channels as arrays of their own. The arrays stay from one quantum to the next while their number does not change and
  // the script has not transferred their buffers.
  const channelsChanged = (arrays, counts, at, n) => {
    if (counts.length !== n) return true;
    for (let i = 0; i < n; i++) {
      const list = arrays[i], c = counts[i];
      if (c !== layout[at + i]) return true;
      for (let k = 0; k < c; k++) if (list[k].length !== QUANTUM) return true;
    }
    return false;
  };
  const rebuildChannels = (arrays, counts, at, n) => {
    counts.length = n;
    const outer = new Array(n);
    for (let i = 0; i < n; i++) {
      const c = layout[at + i], list = arrays[i] ?? (arrays[i] = []);
      counts[i] = c;
      list.length = c;
      for (let k = 0; k < c; k++) if (!(list[k]?.length === QUANTUM)) list[k] = new F32(QUANTUM);
      outer[i] = freeze(list.slice());
    }
    arrays.length = n;
    return freeze(outer);
  };

  let layout = new I32(LAYOUT_START);

  const run = () => {
    const entry = processors.get(layout[0]);
    if (entry === undefined) return NOT_READY;
    if (entry.object === null) return FAILED;
    const nIn = layout[1], nOut = layout[2], nParam = layout[3];
    const inAt = LAYOUT_HEADER, paramAt = inAt + nIn, outAt = paramAt + nParam;
    if (entry.inputs === null || channelsChanged(entry.inputArrays, entry.inputCounts, inAt, nIn)) {
      entry.inputs = rebuildChannels(entry.inputArrays, entry.inputCounts, inAt, nIn);
      entry.args[0] = entry.inputs;
    }
    if (entry.outputs === null || channelsChanged(entry.outputArrays, entry.outputCounts, outAt, nOut)) {
      entry.outputs = rebuildChannels(entry.outputArrays, entry.outputCounts, outAt, nOut);
      entry.args[1] = entry.outputs;
    }
    let at = 0;
    for (let i = 0; i < nIn; i++) {
      const list = entry.inputArrays[i];
      for (let c = 0; c < list.length; c++) { native.read(at, list[c]); at += QUANTUM; }
    }
    let changed = entry.parameters === null;
    for (let i = 0; i < nParam; i++) {
      const length = layout[paramAt + i], slot = length === 1 ? 0 : 1;
      let values = entry.paramValues[i][slot];
      if (values === null || values.length !== length) { values = entry.paramValues[i][slot] = new F32(length); changed = true; }
      if (entry.paramLengths[i] !== length) { entry.paramLengths[i] = length; changed = true; }
      native.read(at, values);
      at += length;
    }
    if (changed) {
      const p = { __proto__: null };
      for (let i = 0; i < nParam; i++) p[entry.names[i]] = entry.paramValues[i][entry.paramLengths[i] === 1 ? 0 : 1];
      setPrototypeOf(p, Object.prototype);
      entry.parameters = freeze(p);
      entry.args[2] = entry.parameters;
    }
    for (let i = 0; i < nOut; i++) {
      const list = entry.outputArrays[i];
      for (let c = 0; c < list.length; c++) list[c].fill(0);
    }
    let status;
    try {
      const process = entry.object.process;
      if (typeof process !== "function") throw new TE("The processor has no process method.");
      status = apply(process, entry.object, entry.args) ? KEEP_ALIVE : INACTIVE;
    } catch (e) {
      consoleOf.error(e);
      say({ t: "processorerror", processor: layout[0], ...errorInfo(e) });
      processors.delete(layout[0]);
      return FAILED;
    }
    for (let i = 0; i < nOut; i++) {
      const list = entry.outputArrays[i];
      for (let c = 0; c < list.length; c++) {
        // (an array whose buffer was transferred gives silence)
        if (list[c].length === QUANTUM) native.write(at, list[c]);
        else native.write(at, silence);
        at += QUANTUM;
      }
    }
    return status;
  };
  const silence = new F32(QUANTUM);

  const quantum = () => {
    for (;;) {
      const gone = native.dropped();
      if (gone < 0) break;
      processors.delete(gone);
    }
    let n = native.layout(layout);
    if (n === 0) return;
    if (n > layout.length) {
      layout = new I32(n);
      n = native.layout(layout);
    }
    frame = native.frame();
    native.finish(run());
    frame += QUANTUM;
  };

  // ---- what the page says ----
  const addModule = async m => {
    frame = m.frame;
    try {
      await import(m.url);
      say({ t: "module", id: m.id, ok: true });
    } catch (e) {
      say({ t: "module", id: m.id, ok: false, name: e?.name, message: S(e?.message ?? e), fetch: isFetchFailure(e) });
    }
  };
  // (what the module loader throws when a module could not be fetched: Worklet's addModule() says AbortError for it)
  const isFetchFailure = e => e instanceof TE && /fetch|load|import/i.test(S(e.message));

  apply(listen, global, ["message", e => {
    const m = e.data;
    switch (m.t) {
      case "port": portOfScope = m.port; break;
      case "module": addModule(m); break;
      case "create": create(m); break;
      case "close": apply(closeScope, global, []); break;
    }
  }]);

  // ---- the scope of a worklet: what stays of a worker's ----
  const KEEP = new SetC(["console", "WebAssembly", "DOMException", "Event", "EventTarget", "MessagePort", "MessageEvent", "MessageChannel",
    "AbortController", "AbortSignal", "TextDecoder", "TextEncoder", "TextDecoderStream", "TextEncoderStream",
    "ReadableStream", "ReadableStreamDefaultReader", "ReadableStreamBYOBReader", "ReadableStreamDefaultController", "ReadableByteStreamController", "ReadableStreamBYOBRequest",
    "WritableStream", "WritableStreamDefaultWriter", "WritableStreamDefaultController", "TransformStream", "TransformStreamDefaultController",
    "ByteLengthQueuingStrategy", "CountQueuingStrategy", "CompressionStream", "DecompressionStream",
    "SharedArrayBuffer", "Atomics", "WeakRef", "FinalizationRegistry",
    "globalThis", "Infinity", "NaN", "undefined", "eval", "isFinite", "isNaN", "parseFloat", "parseInt",
    "decodeURI", "decodeURIComponent", "encodeURI", "encodeURIComponent", "escape", "unescape"]);
  // What ECMAScript has on the global (constructors and namespaces): a capital letter, and not what a worker adds.
  const isEcmaScriptName = name => typeof name === "string" && ES_NAMES.has(name);
  const ES_NAMES = new SetC(["AggregateError", "Array", "ArrayBuffer", "AsyncDisposableStack", "BigInt", "BigInt64Array", "BigUint64Array", "Boolean", "DataView", "Date", "DisposableStack",
    "Error", "EvalError", "Float16Array", "Float32Array", "Float64Array", "Function", "Int16Array", "Int32Array", "Int8Array", "Intl", "Iterator", "JSON", "Map", "Math", "Number", "Object",
    "Promise", "Proxy", "RangeError", "ReferenceError", "Reflect", "RegExp", "Set", "String", "SuppressedError", "Symbol", "SyntaxError", "TypeError", "URIError",
    "Uint16Array", "Uint32Array", "Uint8Array", "Uint8ClampedArray", "WeakMap", "WeakSet"]);
  for (const key of ownKeys(global)) {
    if (typeof key === "string" && !KEEP.has(key) && !isEcmaScriptName(key)) deleteProperty(global, key);
  }
  setPrototypeOf(global, AudioWorkletGlobalScope.prototype);
  const hidden = (name, value) => defineProperty(global, name, { value, writable: true, enumerable: false, configurable: true });
  hidden("WorkletGlobalScope", WorkletGlobalScope);
  hidden("AudioWorkletGlobalScope", AudioWorkletGlobalScope);
  hidden("AudioWorkletProcessor", AudioWorkletProcessor);
  defineProperty(global, "registerProcessor", { value: AudioWorkletGlobalScope.prototype.registerProcessor, writable: true, enumerable: true, configurable: true });
  defineProperty(AudioWorkletGlobalScope.prototype, Symbol.toStringTag, { value: "AudioWorkletGlobalScope", configurable: true });
  defineProperty(AudioWorkletProcessor.prototype, Symbol.toStringTag, { value: "AudioWorkletProcessor", configurable: true });

  return { __proto__: null, quantum };
})
