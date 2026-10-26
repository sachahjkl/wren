// A worker that starts workers of its own (tools/workers_e2e.ps1): messages go down and up a chain, a child's error,
// buffers and ports travel between a worker and its child, a child ends with its parent.
let child = null;
const blobWorker = (src) => new Worker(URL.createObjectURL(new Blob([src], {type: "text/javascript"})));
onmessage = (e) => {
  const d = e.data;
  if (d.op === "chain") {
    // {op, depth}: a chain of `depth` workers; the deepest answers, each one on the way adds its name
    if (d.depth <= 1) { postMessage("bottom " + self.name); return; }
    child = new Worker("nested.js", {name: "level" + (d.depth - 1)});
    child.onmessage = (m) => postMessage(m.data + " < " + self.name);
    child.onerror = (m) => { m.preventDefault(); postMessage("error at " + self.name); };
    child.postMessage({op: "chain", depth: d.depth - 1});
  } else if (d.op === "throw") {
    const w = blobWorker("throw new Error('boom')");
    w.onerror = (ev) => { ev.preventDefault(); postMessage("child error " + ev.message.includes("boom")); };
  } else if (d.op === "transfer") {
    const w = blobWorker("onmessage = (e) => { e.data.p.postMessage(e.data.b.byteLength); const b = e.data.b; postMessage(b, [b]); };");
    const ch = new MessageChannel();
    const buf = new ArrayBuffer(8);
    let said = "none";
    ch.port1.onmessage = (m) => { said = m.data; };
    w.onmessage = (m) => setTimeout(() => postMessage("back " + m.data.byteLength + " detached " + (buf.byteLength === 0) + " port " + said), 200);
    w.postMessage({b: buf, p: ch.port2}, [buf, ch.port2]);
  } else if (d.op === "keep") {
    // a child that ticks: the page stops hearing it once this worker is terminated
    child = blobWorker("setInterval(() => postMessage('tick'), 20)");
    child.onmessage = () => postMessage("tick");
  } else if (d.op === "cross") {
    // a child of another origin than this worker's: an error event, not an exception
    try {
      const w = new Worker("http://localhost:1/x.js");
      w.onerror = () => postMessage("error event");
    } catch (x) { postMessage("threw " + x.name); }
  } else if (d.op === "types") {
    postMessage([typeof Worker, typeof SharedWorker].join(" "));
  }
};
