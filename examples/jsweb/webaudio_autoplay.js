// Web Audio and media.autoplay.policy (here the default, allow-muted): a context waits for a click or a key press. The page
// closes with a context running: its thread and its graph go with it (the tool's leak check, in the test build).
"use strict";

// A real duration: nothing says a context will not start, or a resume() end. What had to happen on its own has had this long.
const NOTHING_HAPPENS_MS = 100;
// (of the 2000 one-shot sounds below)
const MAX_LIVE_NODES = 400;

test("a context waits for a gesture", async () => {
  const c = new AudioContext();
  await sleep(NOTHING_HAPPENS_MS);
  eq(c.state, "suspended", "no gesture: suspended");
  eq(c.currentTime, 0, "no gesture: the clock stands still");
  let resumed = false;
  const p = c.resume().then(() => { resumed = true; });
  await sleep(NOTHING_HAPPENS_MS);
  eq(resumed, false, "no gesture: resume() waits");
  const o = c.createOscillator();
  const a = c.createAnalyser();
  o.connect(a).connect(c.destination);
  o.start();
  await signal("gesture");
  await p;
  eq(c.state, "running", "after a gesture: running");
  await until(() => c.currentTime > 0, "after a gesture, the clock");
  const wave = new Float32Array(a.fftSize);
  await until(() => { a.getFloatTimeDomainData(wave); return Math.max(...wave) > 0.5; }, "the oscillator, in the analyser");
  const after = new AudioContext();
  await until(() => after.state === "running", "a context made after a gesture, running by itself");
  await after.close();

  // Nodes the page has let go of leave the graph: one-shot sounds by the thousand leave nothing behind.
  const buffer = c.createBuffer(1, 64, c.sampleRate);
  let ended = 0;
  for (let i = 0; i < 2000; i++) {
    const s = c.createBufferSource();
    const g = c.createGain();
    s.buffer = buffer;
    s.onended = () => { ended++; };
    s.connect(g).connect(c.destination);
    s.start();
  }
  // (they end, their `ended` comes, what the page held is collected, the render thread sees the nodes are free)
  let live = 0, said = -1;
  await until(async () => {
    await signal("collect");
    live = await signal("count");
    // (what a failure has to say, among the last lines of the section: which of those steps stopped)
    if (live !== said) { said = live; console.log(live + " nodes in the graph, " + ended + " ended, context " + c.state + " at " + c.currentTime + " s"); }
    return live < MAX_LIVE_NODES;
  }, "the sounds gone from the graph");
  ok(live < MAX_LIVE_NODES, live + " nodes are still in the graph");
  // (and c is left running: the page closes with it)
});

__run();
