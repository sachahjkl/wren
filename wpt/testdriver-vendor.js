// Wren's testdriver-vendor.js: served by tools/testserver (wpt.go) in place of WPT's own at
// /resources/testdriver-vendor.js, which testdriver.js pages load right after it. test_driver's input actions (click,
// send_keys, action_sequence, and bless, which clicks) go to the runner (src/tools/wpt, testdriver.odin) as one console
// message each, "WPTDRIVER " + JSON {sources: [WebDriver input sources: {type, actions: [...]}]}, with every element
// origin made viewport coordinates here (the in-view center of its first box, as WebDriver's). The runner performs them
// through the browser's input path (hit test, pointer and mouse events, focus, activation, keys, wheel events) and answers
// by calling __wrenTestdriverDone(error), error null when done, for the oldest request not answered (they are performed in
// order). The other actions (touch and pen pointers, actions in another window, cookies, permissions...) still fail at
// once, "not implemented by testdriver-vendor.js", instead of waiting for a person until the test's time is up.
(function () {
  "use strict";
  var internal = window.test_driver_internal;
  internal.in_automation = true;
  // the console the page started with: a test replacing console.log must not swallow a request
  var log = console.log.bind(console);
  // the requests not yet answered, oldest first (the answer is the same script for every request: the engine compiles
  // it once)
  var pending = [];
  Object.defineProperty(window, "__wrenTestdriverDone", {
    value: function (error) {
      var p = pending.shift();
      if (!p) { return; }
      if (error === null) { p.resolve(); } else { p.reject(new Error(error)); }
    }
  });
  function send(sources) {
    return new Promise(function (resolve, reject) {
      pending.push({ resolve: resolve, reject: reject });
      log("WPTDRIVER " + JSON.stringify({ sources: sources }));
    });
  }
  // WebDriver's in-view center point of an element's first box
  function center(element) {
    var r = element.getClientRects()[0] || element.getBoundingClientRect();
    var left = Math.max(0, Math.min(r.x, r.x + r.width));
    var right = Math.min(window.innerWidth, Math.max(r.x, r.x + r.width));
    var top = Math.max(0, Math.min(r.y, r.y + r.height));
    var bottom = Math.min(window.innerHeight, Math.max(r.y, r.y + r.height));
    return [Math.floor((left + right) / 2), Math.floor((top + bottom) / 2)];
  }
  internal.click = function (element, coords) {
    return send([{ type: "pointer", actions: [
      { type: "pointerMove", x: coords.x, y: coords.y },
      { type: "pointerDown", button: 0 },
      { type: "pointerUp", button: 0 }
    ] }]);
  };
  // WebDriver's Element Send Keys: the element takes the focus, then each code point is a key press
  internal.send_keys = function (element, keys) {
    if (element.ownerDocument.activeElement !== element && typeof element.focus === "function") { element.focus(); }
    var actions = [];
    for (var c of String(keys)) {
      actions.push({ type: "keyDown", value: c });
      actions.push({ type: "keyUp", value: c });
    }
    return send([{ type: "key", actions: actions }]);
  };
  internal.action_sequence = function (sources, context) {
    if (context && context !== window) { return Promise.reject(new Error("action_sequence in another context is not implemented by testdriver-vendor.js")); }
    var out = [];
    for (var s of sources) {
      // (the runner's pointer is a mouse: a finger or a pen would wait for touch events that never come)
      var kind = s.type === "pointer" && s.parameters && s.parameters.pointerType;
      if (kind && kind !== "mouse") { return Promise.reject(new Error(kind + " pointers are not implemented by testdriver-vendor.js")); }
      var copy = { type: s.type, actions: [] };
      for (var a of s.actions) {
        var b = Object.assign({}, a);
        if (a.origin && typeof a.origin === "object") {
          var c = center(a.origin);
          b.x = c[0] + (a.x || 0);
          b.y = c[1] + (a.y || 0);
          b.origin = "viewport";
        }
        copy.actions.push(b);
      }
      out.push(copy);
    }
    return send(out);
  };
})();
