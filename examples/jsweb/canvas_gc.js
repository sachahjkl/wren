// Canvases JavaScript drops: their bitmaps must be freed (the tool collects, runs the shell's per-frame pruning and
// reads how many bytes of canvas the page still holds).

test("make canvases", () => {
  // 30 element canvases of 4 MB each, never attached, and 30 OffscreenCanvases; with contexts, so with bitmaps
  for (let i = 0; i < 30; i++) {
    const c = document.createElement("canvas");
    c.width = 1000; c.height = 1000;
    const g = c.getContext("2d");
    g.fillStyle = "#123"; g.fillRect(0, 0, 1000, 1000);
    g.createLinearGradient(0, 0, 1, 1);
    g.createPattern(c, "repeat");
    const o = new OffscreenCanvas(1000, 1000);
    o.getContext("2d").fillRect(0, 0, 10, 10);
    createImageBitmap(c);
  }
  ok(true, "canvases made");
});

test("one canvas is kept", () => {
  const keep = document.createElement("canvas");
  keep.width = 500; keep.height = 500;
  globalThis.keep = keep;
  keep.getContext("2d").fillRect(0, 0, 1, 1);
  ok(true, "kept");
});

__run();
