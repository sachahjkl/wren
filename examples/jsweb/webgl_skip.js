// A script that cannot run without a WebGL context says so, and the program checks that of the machine (src/tools/e2e/web_jsweb.odin: what it asks of this one is a skip that is not true).
"use strict";

test("there is a context", () => {
  ok(document.createElement("canvas").getContext("webgl") !== null, "a context");
});

const noContext = webglContextError();
if (noContext === null) __run(); else __skipAll("webgl-adapter", noContext);
