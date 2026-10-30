// The objects of the WebAssembly JavaScript API (https://webassembly.github.io/spec/js-api/) over the natives of
// web_wasm.odin, run the first time a script of the realm reads `WebAssembly` (javascript.webassembly.enabled). What it
// uses of the realm is taken here, so what the page replaces later does not reach it.
(function (native, global) {
  "use strict";
  const { create, defineProperty, freeze, getOwnPropertyDescriptor, getOwnPropertyNames, keys, setPrototypeOf } = Object;
  const { apply, construct } = Reflect;
  const P = Promise, E = Error, TE = TypeError, RE = RangeError, N = Number, ArrayFrom = Array.from;
  const WM = WeakMap, M = Map;
  const weakGet = WM.prototype.get, weakSet = WM.prototype.set, mapGet = M.prototype.get, mapSet = M.prototype.set;
  const promiseThen = P.prototype.then, isWellFormed = String.prototype.isWellFormed;
  const toStringTag = Symbol.toStringTag;
  const isFinite_ = isFinite, trunc = Math.trunc, fround = Math.fround, stringOf = String, BI = BigInt, BigIntAsIntN = BigInt.asIntN;
  const isObject = v => (typeof v === "object" && v !== null) || typeof v === "function";
  const isCallable = v => typeof v === "function";
  const then = (p, f, r) => apply(promiseThen, p, [f, r]);
  const later = f => then(new P(resolve => resolve()), f);

  // WebIDL's operations and constructors: enumerable operations, constructors that are not
  const operations = (target, fns) => {
    for (const k of keys(fns)) defineProperty(target, k, { value: fns[k], writable: true, enumerable: true, configurable: true });
  };
  const hidden = (target, k, value) => defineProperty(target, k, { value, writable: true, enumerable: false, configurable: true });
  const tag = (target, name) => defineProperty(target, toStringTag, { value: name, configurable: true });
  // A class as a WebIDL interface: its operations and attributes are enumerable, unlike a class's own.
  const interfaceOf = C => {
    const proto = C.prototype;
    for (const k of getOwnPropertyNames(proto)) {
      if (k === "constructor") continue;
      const d = getOwnPropertyDescriptor(proto, k);
      d.enumerable = true;
      defineProperty(proto, k, d);
    }
    tag(proto, "WebAssembly." + C.name);
  };

  // [EnforceRange] unsigned long
  const enforceU32 = (v, what) => {
    const n = N(v);
    if (!isFinite_(n)) throw new TE(what + " must be convertible to a valid number");
    const t = trunc(n);
    if (t < 0 || t > 0xFFFFFFFF) throw new TE(what + " must be non-negative and no more than 4294967295");
    return t;
  };

  // CompileError, LinkError, RuntimeError: NativeErrors (callable without new, Error objects)
  const nativeError = name => {
    const C = { [name]: function (message) { return construct(E, arguments, new.target || C); } }[name];
    setPrototypeOf(C, E);
    const proto = create(E.prototype);
    hidden(proto, "constructor", C);
    hidden(proto, "name", name);
    hidden(proto, "message", "");
    defineProperty(C, "prototype", { value: proto, writable: false, enumerable: false, configurable: false });
    return C;
  };
  const CompileError = nativeError("CompileError");
  const LinkError = nativeError("LinkError");
  const RuntimeError = nativeError("RuntimeError");

  // The state of each object, by the object: a Module's handle in the browser (web_wasm.odin releases it when collected),
  // a Memory's, Table's or Global's number. An object of the store is one object per number: an exported memory is the
  // one the page gave, whichever way it came.
  const privates = new WM();
  const stateOf = o => apply(weakGet, privates, [o]);
  const setState = (o, s) => { apply(weakSet, privates, [o, s]); return o; };
  const thisState = (o, C, what) => {
    const s = stateOf(o);
    if (s === undefined || s.kind !== C) throw new TE(what + ": Receiver is not a WebAssembly." + C.name);
    return s;
  };
  const argState = (o, C, what) => {
    const s = stateOf(o);
    if (s === undefined || s.kind !== C) throw new TE(what + ": Argument 0 must be a WebAssembly." + C.name);
    return s;
  };

  const moduleOf = (target, h, what) => {
    if (typeof h === "string") throw new CompileError(what + ": " + h);
    return setState(target, { kind: Module, handle: h });
  };

  class Module {
    constructor(bytes) { moduleOf(this, native.compile(bytes), "WebAssembly.Module()"); }
  }
  operations(Module, {
    imports(module) { return native.imports(argState(module, Module, "WebAssembly.Module.imports()").handle); },
    exports(module) { return native.exports(argState(module, Module, "WebAssembly.Module.exports()").handle); },
    customSections(module, name) {
      const h = argState(module, Module, "WebAssembly.Module.customSections()").handle;
      if (name === undefined) throw new TE("WebAssembly.Module.customSections(): Argument 1 is required");
      const s = stringOf(name);
      return apply(isWellFormed, s, []) ? native.customSections(h, s) : [];   // (a lone surrogate names no section)
    },
  });
  interfaceOf(Module);

  // ---- Memory ----

  const memories = [];
  const memoryObject = id => memories[id] || (memories[id] = setState(create(Memory.prototype), { kind: Memory, id, buffer: null, pages: -1 }));

  class Memory {
    constructor(descriptor) {
      if (!isObject(descriptor)) throw new TE("WebAssembly.Memory(): Argument 0 must be a memory descriptor");
      const first = descriptor.initial;
      if (first === undefined) throw new TE("WebAssembly.Memory(): Property 'initial' is required");
      const initial = enforceU32(first, "WebAssembly.Memory(): Property 'initial'");
      const m = descriptor.maximum;
      const maximum = m === undefined ? -1 : enforceU32(m, "WebAssembly.Memory(): Property 'maximum'");
      if (initial > 65536) throw new RE("WebAssembly.Memory(): Property 'initial': value " + initial + " is above the upper bound");
      if (maximum > 65536) throw new RE("WebAssembly.Memory(): Property 'maximum': value " + maximum + " is above the upper bound");
      if (maximum >= 0 && maximum < initial) throw new RE("WebAssembly.Memory(): Property 'maximum': value " + maximum + " is below the lower bound " + initial);
      if (descriptor.shared) throw new TE("WebAssembly.Memory(): shared memories are not supported");
      const id = native.memoryCreate(initial, maximum);
      memories[id] = setState(this, { kind: Memory, id, buffer: null, pages: -1 });
    }
    grow(delta) {
      const s = thisState(this, Memory, "WebAssembly.Memory.grow()");
      const d = enforceU32(delta, "WebAssembly.Memory.grow(): Argument 0");
      const prev = native.memoryGrow(s.id, d);
      refresh(s);
      return prev;
    }
    get buffer() {
      const s = thisState(this, Memory, "WebAssembly.Memory.buffer");
      if (s.buffer === null || native.memoryPages(s.id) !== s.pages) refresh(s);   // (the module may have grown it)
      return s.buffer;
    }
  }
  // the buffer as it is now; the previous one is detached
  const refresh = s => {
    if (s.buffer !== null) native.memoryDetach(s.buffer);
    s.pages = native.memoryPages(s.id);
    s.buffer = native.memoryBuffer(s.id);
  };
  interfaceOf(Memory);

  // ---- Table ----

  const tables = [];
  const tableObject = id => tables[id] || (tables[id] = setState(create(Table.prototype), { kind: Table, id, letter: native.tableElement(id) }));
  // What an element is when no value is given (a value given as undefined is one: not a funcref).
  const tableDefault = (letter, args, i) => (args.length > i ? args[i] : letter === "r" ? null : undefined);
  const referenceLetter = (v, what) => {
    const e = stringOf(v);
    if (e === "anyfunc" || e === "funcref") return "r";
    if (e === "externref") return "e";
    throw new TE(what + ": Descriptor property 'element' must be a WebAssembly reference type");
  };

  class Table {
    constructor(descriptor, init = undefined) {
      if (!isObject(descriptor)) throw new TE("WebAssembly.Table(): Argument 0 must be a table descriptor");
      const letter = referenceLetter(descriptor.element, "WebAssembly.Table()");
      const first = descriptor.initial;
      if (first === undefined) throw new TE("WebAssembly.Table(): Property 'initial' is required");
      const initial = enforceU32(first, "WebAssembly.Table(): Property 'initial'");
      const m = descriptor.maximum;
      const maximum = m === undefined ? -1 : enforceU32(m, "WebAssembly.Table(): Property 'maximum'");
      if (maximum >= 0 && maximum < initial) throw new RE("WebAssembly.Table(): Property 'maximum': value " + maximum + " is below the lower bound " + initial);
      if (initial > 10000000) throw new RE("WebAssembly.Table(): Property 'initial': value " + initial + " is above the upper bound");
      const id = native.tableCreate(letter, initial, maximum, tableDefault(letter, arguments, 1));
      tables[id] = setState(this, { kind: Table, id, letter });
    }
    get length() { return native.tableLength(thisState(this, Table, "WebAssembly.Table.length").id); }
    get(index) {
      const s = thisState(this, Table, "WebAssembly.Table.get()");
      return native.tableGet(s.id, enforceU32(index, "WebAssembly.Table.get(): Argument 0"));
    }
    set(index, value = undefined) {
      const s = thisState(this, Table, "WebAssembly.Table.set()");
      const i = enforceU32(index, "WebAssembly.Table.set(): Argument 0");
      native.tableSet(s.id, i, tableDefault(s.letter, arguments, 1));
    }
    grow(delta, init = undefined) {
      const s = thisState(this, Table, "WebAssembly.Table.grow()");
      const d = enforceU32(delta, "WebAssembly.Table.grow(): Argument 0");
      return native.tableGrow(s.id, d, tableDefault(s.letter, arguments, 1));
    }
  }
  interfaceOf(Table);

  // ---- Global ----

  const globals = [];
  const globalObject = id => globals[id] || (globals[id] = setState(create(Global.prototype), { kind: Global, id }));
  const VALUE_LETTERS = { __proto__: null, i32: "i", i64: "I", f32: "f", f64: "F", v128: "V", externref: "e", anyfunc: "r", funcref: "r" };

  class Global {
    constructor(descriptor, value = undefined) {
      if (!isObject(descriptor)) throw new TE("WebAssembly.Global(): Argument 0 must be a global descriptor");
      const mutable = !!descriptor.mutable;
      const letter = VALUE_LETTERS[stringOf(descriptor.value)];
      if (letter === undefined) throw new TE("WebAssembly.Global(): Descriptor property 'value' must be a WebAssembly type");
      if (letter === "V") throw new TE("WebAssembly.Global(): Can't get the value of s128 WebAssembly.Global");
      let v = value;
      if (v === undefined && letter === "I") v = 0n;
      if (v === undefined && letter !== "e" && letter !== "r") v = 0;
      const id = native.globalCreate(letter, mutable, v);
      globals[id] = setState(this, { kind: Global, id });
    }
    get value() { return native.globalGet(thisState(this, Global, "get WebAssembly.Global.value").id); }
    set value(v) {
      native.globalSet(thisState(this, Global, "set WebAssembly.Global.value").id, v);
    }
    valueOf() { return native.globalGet(thisState(this, Global, "WebAssembly.Global.valueOf()").id); }
  }
  interfaceOf(Global);

  // ---- functions and references ----

  const functions = [], functionIds = new WM();
  const funcWrap = (id, name) => {
    let f = functions[id];
    if (f === undefined) {
      f = native.funcWrap(id, name === undefined ? stringOf(id) : stringOf(name));
      functions[id] = f;
      apply(weakSet, functionIds, [f, id]);
    }
    return f;
  };
  const funcId = f => (isObject(f) ? apply(weakGet, functionIds, [f]) : undefined);

  // An externref's number, one per value: the values stay until the page closes (the store's references are not traced).
  const externIds = new M(), externValues = [undefined];
  const externId = v => {
    let id = apply(mapGet, externIds, [v]);
    if (id === undefined) {
      id = externValues.length;
      externValues[id] = v;
      apply(mapSet, externIds, [v, id]);
    }
    return id;
  };

  // ---- Tag and Exception ----

  const tags = [];
  const tagObject = id => tags[id] || (tags[id] = setState(create(Tag.prototype), { kind: Tag, id, letters: native.tagSig(id) }));

  class Tag {
    constructor(descriptor) {
      if (!isObject(descriptor)) throw new TE("WebAssembly.Tag(): Argument 0 must be a tag type");
      const parameters = descriptor.parameters;
      if (!isObject(parameters)) throw new TE("WebAssembly.Tag(): Argument 0 must be a tag type with 'parameters'");
      let letters = "";
      for (const p of ArrayFrom(parameters)) {
        const letter = VALUE_LETTERS[stringOf(p)];
        if (letter === undefined) throw new TE("WebAssembly.Tag(): Argument 0 parameter type at index #" + letters.length + " must be a value type");
        letters += letter;
      }
      const id = native.tagCreate(letters);
      tags[id] = setState(this, { kind: Tag, id, letters });
    }
  }
  interfaceOf(Tag);

  // ToWebAssemblyValue of what is kept in an Exception, so getArg reads what the module would.
  const payloadValue = (letter, v) => {
    switch (letter) {
      case "i": return v | 0;
      case "I": return BigIntAsIntN(64, typeof v === "bigint" ? v : BI(v));
      case "f": return fround(v);
      case "F": return +v;
      case "r":
        if (v !== null && funcId(v) === undefined) throw new TE("WebAssembly.Exception(): a function reference must be null or an exported WebAssembly function");
        return v;
      case "e": return v;
    }
    throw new TE("WebAssembly.Exception(): type incompatibility when transforming from/to JS");
  };

  class Exception {
    constructor(tag, payload, options = undefined) {
      const t = stateOf(tag);
      if (t === undefined || t.kind !== Tag) throw new TE("WebAssembly.Exception(): Argument 0 must be a WebAssembly tag");
      if (!isObject(payload)) throw new TE("WebAssembly.Exception(): Argument 1 must be iterable");
      const list = ArrayFrom(payload);
      if (list.length !== t.letters.length) throw new TE("WebAssembly.Exception(): Number of exception values does not match signature length");
      const values = [];
      for (let i = 0; i < list.length; i++) values[i] = payloadValue(t.letters[i], list[i]);
      setState(this, { kind: Exception, tag, values, stack: isObject(options) && options.traceStack ? new E().stack : undefined });
    }
    get stack() { return thisState(this, Exception, "WebAssembly.Exception.stack").stack; }
    is(tag) {
      const s = thisState(this, Exception, "WebAssembly.Exception.is()");
      const t = stateOf(tag);
      if (t === undefined || t.kind !== Tag) throw new TE("WebAssembly.Exception.is(): Argument 0 must be a WebAssembly tag");
      return s.tag === tag;
    }
    getArg(tag, index) {
      const s = thisState(this, Exception, "WebAssembly.Exception.getArg()");
      const t = stateOf(tag);
      if (t === undefined || t.kind !== Tag) throw new TE("WebAssembly.Exception.getArg(): Argument 0 must be a WebAssembly tag");
      const i = enforceU32(index, "WebAssembly.Exception.getArg(): Index");
      if (s.tag !== tag) throw new TE("WebAssembly.Exception.getArg(): First argument does not match the exception tag");
      if (i >= s.values.length) throw new RE("WebAssembly.Exception.getArg(): Index must be convertible to a valid number");
      return s.values[i];
    }
  }
  interfaceOf(Exception);

  const exceptionMake = (tagId, values) => setState(create(Exception.prototype), { kind: Exception, tag: tagObject(tagId), values });
  const exceptionInfo = e => {
    const s = stateOf(e);
    if (s === undefined || s.kind !== Exception) return undefined;
    return [stateOf(s.tag).id, s.values];
  };

  native.setup({ LinkError, RuntimeError, funcId, funcWrap, externId, externValue: id => externValues[id], toList: v => ArrayFrom(v), exceptionMake, exceptionInfo });

  // ---- Instance ----

  const VALUE_TYPE_OK = {
    __proto__: null,
    i: v => typeof v === "number",
    f: v => typeof v === "number",
    F: v => typeof v === "number",
    I: v => typeof v === "bigint",
    e: () => true,
    r: v => v === null || funcId(v) !== undefined,
  };

  // The number of what the import object has for `im` (ReadTheImports of the specification).
  const resolveImport = (imports, im, i, what) => {
    const where = what + ': Import #' + i + ' "' + im.module + '"';
    const space = imports[im.module];
    if (!isObject(space)) throw new TE(where + ": module is not an object or function");
    const v = space[im.name];
    const at = where + ' "' + im.name + '"';
    switch (im.kind) {
      case "function": {
        if (!isCallable(v)) throw new LinkError(at + ": function import requires a callable");
        const id = funcId(v);
        return id !== undefined ? id : native.importFunc(v, im.sig);
      }
      case "global": {
        const s = stateOf(v);
        if (s !== undefined && s.kind === Global) return s.id;
        if (im.mutable) throw new LinkError(at + ": imported mutable global must be a WebAssembly.Global object");
        const ok = VALUE_TYPE_OK[im.value];
        if (ok === undefined || !ok(v)) throw new LinkError(at + ": global import must be a number, valid Wasm reference, or WebAssembly.Global object");
        return native.globalCreate(im.value, false, v);
      }
      case "memory": {
        const s = stateOf(v);
        if (s === undefined || s.kind !== Memory) throw new LinkError(at + ": memory import must be a WebAssembly.Memory object");
        return s.id;
      }
      case "table": {
        const s = stateOf(v);
        if (s === undefined || s.kind !== Table) throw new LinkError(at + ": table import requires a WebAssembly.Table");
        return s.id;
      }
      case "tag": {
        const s = stateOf(v);
        if (s === undefined || s.kind !== Tag) throw new LinkError(at + ": tag import requires a WebAssembly.Tag");
        return s.id;
      }
    }
    throw new LinkError(at + ": this kind of import is not supported");
  };

  // ReadTheImports: synchronous even when the instance comes later.
  const readImports = (module, imports, what) => {
    const wanted = native.linkInfo(stateOf(module).handle);
    if (wanted.length > 0 && !isObject(imports)) throw new TE(what + ": Imports argument must be present and must be an object");
    const ids = [];
    for (let i = 0; i < wanted.length; i++) ids[i] = resolveImport(imports, wanted[i], i, what);
    return ids;
  };

  const instantiateInto = (target, module, ids) => {
    const ms = stateOf(module);
    const id = native.instanceCreate(ms.handle, ids);
    const exports = create(null);
    const list = native.instanceExports(id, ms.handle);
    for (let i = 0; i < list.length; i++) {
      const e = list[i];
      let v;
      switch (e.kind) {
        case "function": v = funcWrap(e.id, e.index); break;
        case "memory": v = memoryObject(e.id); break;
        case "table": v = tableObject(e.id); break;
        case "global": v = globalObject(e.id); break;
        case "tag": v = tagObject(e.id); break;
      }
      defineProperty(exports, e.name, { value: v, writable: false, enumerable: true, configurable: false });
    }
    freeze(exports);
    return setState(target, { kind: Instance, exports });
  };

  const checkImports = (imports, what) => {
    if (imports !== undefined && !isObject(imports)) throw new TE(what + ": Argument 1 must be an object");
  };

  class Instance {
    constructor(module, imports = undefined) {
      argState(module, Module, "WebAssembly.Instance()");
      checkImports(imports, "WebAssembly.Instance()");
      instantiateInto(this, module, readImports(module, imports, "WebAssembly.Instance()"));
    }
    get exports() { return thisState(this, Instance, "WebAssembly.Instance.exports").exports; }
  }
  interfaceOf(Instance);

  // ---- the namespace ----

  const rejected = e => new P((_, reject) => reject(e));
  const compileBytes = (bytes, what) => native.compileAsync(bytes, h => moduleOf(create(Module.prototype), h, what));
  const instanceFrom = (module, imports, what) => instantiateInto(create(Instance.prototype), module, readImports(module, imports, what));

  // Streaming sources: a Response (or a promise of one) of type application/wasm.
  const bytesOfResponse = (source, what) => then(new P(resolve => resolve(source)), r => {
    const Resp = global.Response;
    if (Resp === undefined || !(r instanceof Resp)) throw new TE(what + ": Argument 0 must be a Response or a Promise resolving to one");
    if (!r.ok) throw new TE(what + ": HTTP status code is not ok");
    const type = r.headers.get("Content-Type");
    if (type === null || stringOf(type).toLowerCase().split(";")[0].trim() !== "application/wasm") {
      throw new TE(what + ": Response has unsupported MIME type '" + type + "' expected 'application/wasm'");
    }
    return r.arrayBuffer();
  });

  const WebAssembly = {};
  tag(WebAssembly, "WebAssembly");
  operations(WebAssembly, {
    validate: native.validate,
    compile(bytes) {
      try {
        return compileBytes(bytes, "WebAssembly.compile()");
      } catch (e) {
        return rejected(e);
      }
    },
    instantiate(source, imports = undefined) {
      const what = "WebAssembly.instantiate()";
      try {
        checkImports(imports, what);
        const s = stateOf(source);
        if (s !== undefined && s.kind === Module) {
          const ids = readImports(source, imports, what);
          return later(() => instantiateInto(create(Instance.prototype), source, ids));
        }
        return then(compileBytes(source, what), module => ({ module, instance: instanceFrom(module, imports, what) }));
      } catch (e) {
        return rejected(e);
      }
    },
    compileStreaming(source) {
      const what = "WebAssembly.compileStreaming()";
      return then(bytesOfResponse(source, what), bytes => compileBytes(bytes, what));
    },
    instantiateStreaming(source, imports = undefined) {
      const what = "WebAssembly.instantiateStreaming()";
      try {
        checkImports(imports, what);
      } catch (e) {
        return rejected(e);
      }
      return then(then(bytesOfResponse(source, what), bytes => compileBytes(bytes, what)), module => ({ module, instance: instanceFrom(module, imports, what) }));
    },
  });
  for (const [name, C] of [["Module", Module], ["Instance", Instance], ["Memory", Memory], ["Table", Table], ["Global", Global],
    ["Tag", Tag], ["Exception", Exception], ["CompileError", CompileError], ["LinkError", LinkError], ["RuntimeError", RuntimeError]]) {
    hidden(WebAssembly, name, C);
  }
  // the tag of JavaScript's own exceptions, made on first use: a realm that never asks makes no store
  let jsTag;
  const jsTagGetter = getOwnPropertyDescriptor({ get JSTag() { return jsTag || (jsTag = new Tag({ parameters: ["externref"] })); } }, "JSTag").get;
  defineProperty(WebAssembly, "JSTag", { get: jsTagGetter, enumerable: true, configurable: true });
  return WebAssembly;
})
