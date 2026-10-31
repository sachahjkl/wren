// Web Audio and media.autoplay.policy (here the default, allow-muted): a context waits for a click or a key press. The page
// closes with a context running: its thread and its graph go with it (the tool's leak check, in the test build).
"use strict";

test("a context waits for a gesture", async () => {
  const c = new AudioContext();
  await sleep(100);
  eq(c.state, "suspended", "no gesture: suspended");
  eq(c.currentTime, 0, "no gesture: the clock stands still");
  let resumed = false;
  const p = c.resume().then(() => { resumed = true; });
  await sleep(100);
  eq(resumed, false, "no gesture: resume() waits");
  const o = c.createOscillator();
  const a = c.createAnalyser();
  o.connect(a).connect(c.destination);
  o.start();
  await signal("gesture");
  await p;
  eq(c.state, "running", "after a gesture: running");
  await sleep(100);
  ok(c.currentTime > 0, "after a gesture: the clock runs");
  const wave = new Float32Array(a.fftSize);
  a.getFloatTimeDomainData(wave);
  ok(Math.max(...wave) > 0.5, "the oscillator is heard by the analyser");
  const after = new AudioContext();
  await sleep(100);
  eq(after.state, "running", "made after a gesture: it starts by itself");
  await after.close();

  // Nodes the page has let go of leave the graph: one-shot sounds by the thousand leave nothing behind.
  const buffer = c.createBuffer(1, 64, c.sampleRate);
  for (let i = 0; i < 2000; i++) {
    const s = c.createBufferSource();
    const g = c.createGain();
    s.buffer = buffer;
    s.connect(g).connect(c.destination);
    s.start();
  }
  await sleep(100);        // (they end, their `ended` comes)
  await signal("collect");
  await sleep(100);        // (the render thread sees the nodes are free)
  await signal("count");
  // (and c is left running: the page closes with it)
});

__run();
