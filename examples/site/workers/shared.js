// The shared worker of tools\workers_e2e.ps1: counts its connections, answers on each port, tells every port when a
// new one connects, and closes itself when asked.
let count = 0;
const ports = [];
self.onconnect = (e) => {
  const port = e.ports[0];
  count++;
  for (const p of ports) p.postMessage("joined " + count);
  ports.push(port);
  port.onmessage = (m) => {
    if (m.data === "who") port.postMessage(self.name + " " + count + " " + (e.source === port) + " " + (typeof SharedWorkerGlobalScope) + " " + (typeof DedicatedWorkerGlobalScope) + " " + (typeof FetchEvent));
    else if (m.data === "close") { port.postMessage("closing"); self.close(); }
    else port.postMessage("echo " + m.data);
  };
};
