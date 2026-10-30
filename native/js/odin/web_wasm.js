// The objects of the WebAssembly JavaScript API (https://webassembly.github.io/spec/js-api/) over the natives of
// web_wasm.odin, run at the start of a realm when javascript.webassembly.enabled is on. What it uses of the realm is
// taken here, before a script of the page can replace it.
(function (native, global) {
  "use strict";
  const { create, defineProperty, keys, setPrototypeOf } = Object;
  const { apply, construct } = Reflect;
  const P = Promise, E = Error, TE = TypeError;
  const weakGet = WeakMap.prototype.get, weakSet = WeakMap.prototype.set;
  const toStringTag = Symbol.toStringTag;

  // WebIDL's operations and constructors: enumerable operations, constructors that are not
  const operations = (target, fns) => {
    for (const k of keys(fns)) defineProperty(target, k, { value: fns[k], writable: true, enumerable: true, configurable: true });
  };
  const hidden = (target, k, value) => defineProperty(target, k, { value, writable: true, enumerable: false, configurable: true });
  const tag = (target, name) => defineProperty(target, toStringTag, { value: name, configurable: true });

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

  // a Module's compiled code in the browser: an object of web_wasm.odin, which releases it when collected
  const handles = new WeakMap();
  const handleOf = (m, what) => {
    const h = apply(weakGet, handles, [m]);
    if (h === undefined) throw new TE(what + ": Argument 0 must be a WebAssembly.Module");
    return h;
  };
  const compiled = (bytes, what, promised) => {
    const h = native.compile(bytes, promised);
    if (typeof h === "string") throw new CompileError(what + ": " + h);
    return h;
  };

  class Module {
    constructor(bytes) { apply(weakSet, handles, [this, compiled(bytes, "WebAssembly.Module()", false)]); }
  }
  operations(Module, {
    imports(module) { return native.imports(handleOf(module, "WebAssembly.Module.imports()")); },
    exports(module) { return native.exports(handleOf(module, "WebAssembly.Module.exports()")); },
    customSections(module, name) {
      const h = handleOf(module, "WebAssembly.Module.customSections()");
      if (name === undefined) throw new TE("WebAssembly.Module.customSections(): Argument 1 is required");
      return native.customSections(h, name);
    },
  });
  tag(Module.prototype, "WebAssembly.Module");

  const WebAssembly = {};
  tag(WebAssembly, "WebAssembly");
  operations(WebAssembly, {
    validate: native.validate,
    compile(bytes) {
      return new P(resolve => {
        const m = create(Module.prototype);
        apply(weakSet, handles, [m, compiled(bytes, "WebAssembly.compile()", true)]);
        resolve(m);
      });
    },
  });
  hidden(WebAssembly, "Module", Module);
  hidden(WebAssembly, "CompileError", CompileError);
  hidden(WebAssembly, "LinkError", LinkError);
  hidden(WebAssembly, "RuntimeError", RuntimeError);
  hidden(global, "WebAssembly", WebAssembly);
})
