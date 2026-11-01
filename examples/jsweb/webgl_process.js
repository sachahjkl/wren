// The GPU process seen from a page: it dies while the page draws, it hangs, and the page and its contexts carry on (src/tools/webtests/jsweb.odin
// kills it and asks it to hang: test hooks a browser has not; the channel itself is tested in native/webgl/src/ipc_tests.rs).
"use strict";

// A real duration: far above the deadline of a question (WEBGL_TEST_HANG_MS, jsweb.odin), on the slowest machine. It says the question does not wait for ever.
const HUNG_ANSWER_WITHIN_MS = 60000;

const context = () => {
  const c = document.createElement("canvas");
  c.width = c.height = 8;
  const gl = c.getContext("webgl", { antialias: false });
  const state = { c, gl, lost: 0, restored: 0 };
  c.addEventListener("webglcontextlost", e => { state.lost++; e.preventDefault(); });
  c.addEventListener("webglcontextrestored", () => { state.restored++; });
  return state;
};

const green = gl => {
  gl.clearColor(0, 1, 0, 1);
  gl.clear(gl.COLOR_BUFFER_BIT);
  const p = new Uint8Array(4);
  gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, p);
  return p.join();
};

const info = () => signal("gpu_info");

// Something of the page's other than WebGL: it still runs.
const pageWorks = () => {
  const d = document.createElement("div");
  d.textContent = "x";
  document.body.appendChild(d);
  const ok = document.body.lastChild.textContent === "x";
  d.remove();
  return ok;
};

test("one process, started by the first context", async () => {
  const before = await info();
  const a = context(), b = context();
  const now = await info();
  ok(now.pid !== 0, "there is a process");
  ok(now.starts <= before.starts + 1, "one start for two contexts");
  eq(green(a.gl), "0,255,0,255", "a context draws");
  eq(green(b.gl), "0,255,0,255", "another too");
});

test("killed while the page draws: every context lost, restored by a new process", async () => {
  const a = context(), b = context();
  eq(green(a.gl), "0,255,0,255", "draws");
  const first = await info();
  // draws on its way when it goes
  for (let i = 0; i < 100; i++) { a.gl.clear(a.gl.COLOR_BUFFER_BIT); a.gl.flush(); }
  await signal("gpu_kill");
  for (let i = 0; i < 100; i++) { a.gl.clear(a.gl.COLOR_BUFFER_BIT); a.gl.flush(); }
  await until(() => a.lost === 1 && b.lost === 1, "the lost events");
  eq(a.gl.getError(), a.gl.CONTEXT_LOST_WEBGL, "getError says so");
  ok(pageWorks(), "the page goes on");
  await until(() => a.restored === 1 && b.restored === 1, "the restored events");
  eq(a.gl.isContextLost(), false, "a is back");
  eq(b.gl.isContextLost(), false, "b is back");
  eq(green(a.gl), "0,255,0,255", "a draws in the new process");
  eq(green(b.gl), "0,255,0,255", "b too");
  const now = await info();
  ok(now.pid !== first.pid, "another process");
  // (at least one: the watcher, on the short limits of this test, may also find a loaded machine's new process late)
  ok(now.starts >= first.starts + 1, "a new start");
  // a program made anew, what a page does after restored
  const s = a.gl.createShader(a.gl.VERTEX_SHADER);
  a.gl.shaderSource(s, "attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }");
  a.gl.compileShader(s);
  eq(a.gl.getShaderParameter(s, a.gl.COMPILE_STATUS), true, "a shader compiles after it");
  const n = document.createElement("canvas").getContext("webgl");
  ok(n !== null, "a new context too");
});

test("a page that does not ask for its context back does not get it", async () => {
  const c = document.createElement("canvas");
  const gl = c.getContext("webgl");
  let lost = 0, restored = 0;
  c.addEventListener("webglcontextlost", () => { lost++; });
  c.addEventListener("webglcontextrestored", () => { restored++; });
  green(gl);
  const asks = context();   // (when this one has its context back, the other would have)
  await signal("gpu_kill");
  await until(() => lost === 1, "the lost event");
  await until(() => asks.restored === 1, "the context of the one that asks");
  eq(restored, 0, "no restored event");
  eq(gl.isContextLost(), true, "still lost");
});

test("hung: the question is let go at its deadline, the process killed, the page goes on", async () => {
  const a = context(), b = context();
  eq(green(a.gl), "0,255,0,255", "draws");
  const first = await info();
  await signal("gpu_hang");
  const t = performance.now();
  const e = a.gl.getError();
  const took = performance.now() - t;
  eq(e, a.gl.CONTEXT_LOST_WEBGL, "the question's answer");
  ok(took < HUNG_ANSWER_WITHIN_MS, "within its deadline: " + Math.round(took) + " ms");
  ok(pageWorks(), "the page goes on");
  await until(() => b.lost === 1, "the other context's lost event");
  await until(() => a.restored === 1 && b.restored === 1, "the restored events");
  eq(green(a.gl), "0,255,0,255", "draws in the new process");
  const now = await info();
  ok(now.pid !== first.pid && now.pid !== 0, "the hung process is gone");
});

// A worker's context goes through the same: it hears of the end of the process too, on its own loop.
test("a worker's context is lost and restored with the others", async () => {
  const source = `
    const c = new OffscreenCanvas(8, 8);
    const gl = c.getContext("webgl", { antialias: false });
    let lost = 0, restored = 0;
    c.addEventListener("webglcontextlost", e => { lost++; e.preventDefault(); postMessage("lost"); });
    c.addEventListener("webglcontextrestored", () => {
      restored++;
      gl.clearColor(0, 1, 0, 1);
      gl.clear(gl.COLOR_BUFFER_BIT);
      const p = new Uint8Array(4);
      gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, p);
      postMessage("restored " + p.join());
    });
    gl.clear(gl.COLOR_BUFFER_BIT);
    postMessage("ready " + gl.getError());
  `;
  const said = [];
  const w = new Worker("data:text/javascript," + encodeURIComponent(source));
  w.onmessage = e => said.push(e.data);
  w.onerror = e => said.push("error " + e.message);
  await until(() => said.length > 0, "the worker");
  eq(said[0], "ready 0", "it has a context");
  await signal("gpu_kill");
  await until(() => said.length >= 3, "lost and restored");
  eq(said[1], "lost", "the lost event in the worker");
  eq(said[2], "restored 0,255,0,255", "the restored event, and it draws");
  w.terminate();
});

// (a machine with no adapter has no process to look at; the program checks that this one has none, and says why otherwise)
const noContext = webglContextError();
if (noContext === null) __run(); else __skipAll("webgl-adapter", noContext);
