var ws = new WebSocket("ws://" + location.host + "/ws/echo", "chat");
ws.binaryType = "arraybuffer";
ws.onopen = function () {
  ws.send("hello socket");
  ws.send(JSON.stringify({ kind: "ping", n: 1 }));
  ws.send(new Uint8Array([1, 2, 3, 250, 251, 252]));
  var n = 0;
  var iv = setInterval(function () { n++; ws.send("tick " + n); if (n >= 5) { clearInterval(iv); setTimeout(function () { ws.close(1000, "done"); }, 300); } }, 250);
};
ws.onmessage = function (e) { console.log("ws message", typeof e.data === "string" ? e.data : "binary " + e.data.byteLength); };
var es = new EventSource("/sse/basic");
es.onmessage = function (e) { console.log("sse", e.data); };
es.addEventListener("tick", function (e) { console.log("sse tick", e.data); });
var w = new Worker("dtw.js");
w.onmessage = function (e) { console.log("worker says", e.data); };
fetch("/status/200").then(function (r) { return r.text(); });
fetch("/echo-headers").then(function (r) { return r.json ? r.text() : 0; });
fetch("/", { cache: "no-store" });