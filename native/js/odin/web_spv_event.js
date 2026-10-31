// SecurityPolicyViolationEvent (Content Security Policy 3), for the scripts that make one or test for it: evaluated by web_fontface.odin the
// first time a script reads the name.
(function (global) {
  "use strict";
  const S = String, N = Number, E = global.Event, states = new WeakMap();
  const REQUIRED = ["documentURI", "violatedDirective", "effectiveDirective", "originalPolicy", "disposition", "blockedURI", "statusCode"];
  class SecurityPolicyViolationEvent extends E {
    constructor(type, init) {
      if (arguments.length < 1) throw new TypeError("Failed to construct 'SecurityPolicyViolationEvent': 1 argument required");
      super(type, init);
      const i = init === undefined || init === null ? {} : init;
      states.set(this, {
        documentURI: S(i.documentURI ?? ""), referrer: S(i.referrer ?? ""), blockedURI: S(i.blockedURI ?? ""),
        effectiveDirective: S(i.effectiveDirective ?? i.violatedDirective ?? ""), violatedDirective: S(i.violatedDirective ?? i.effectiveDirective ?? ""),
        originalPolicy: S(i.originalPolicy ?? ""), sourceFile: S(i.sourceFile ?? ""), sample: S(i.sample ?? ""),
        disposition: S(i.disposition ?? "enforce"), statusCode: N(i.statusCode ?? 0), lineNumber: N(i.lineNumber ?? 0), columnNumber: N(i.columnNumber ?? 0),
      });
    }
  }
  for (const k of [...REQUIRED, "referrer", "sourceFile", "sample", "lineNumber", "columnNumber"]) {
    Object.defineProperty(SecurityPolicyViolationEvent.prototype, k, {
      get() {
        const s = states.get(this);
        if (s === undefined) throw new TypeError("Illegal invocation");
        return s[k];
      },
      enumerable: true, configurable: true,
    });
  }
  Object.defineProperty(SecurityPolicyViolationEvent.prototype, Symbol.toStringTag, { value: "SecurityPolicyViolationEvent", configurable: true });
  return SecurityPolicyViolationEvent;
})
