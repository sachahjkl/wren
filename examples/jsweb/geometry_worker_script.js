// The worker of geometry.js: the geometry interfaces exist in workers; a transform list is refused (Window only).
onmessage = () => {
  const r = [typeof DOMMatrix, new DOMMatrix([1, 0, 0, 1, 2, 3]).translate(1, 1).e, new DOMPoint(1, 2).y, new DOMQuad().p1.w];
  try { new DOMMatrix("scale(2)"); r.push("no error"); } catch (x) { r.push(x.name); }
  postMessage(r.join());
};
