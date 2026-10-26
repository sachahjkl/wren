// A dedicated worker that feeds a video to the page through Media Source Extensions (tools/workers_e2e.ps1): its
// MediaSource's handle goes to the page, which sets it as a video's srcObject; the worker appends clip_frag.mp4 and
// ends the stream, and says what it saw.
const log = [];
const ms = new MediaSource();
const once = (t, type) => new Promise((ok) => t.addEventListener(type, ok, {once: true}));
ms.addEventListener("sourceopen", async () => {
  log.push("sourceopen " + ms.readyState);
  const sb = ms.addSourceBuffer("video/mp4");
  log.push("buffers " + ms.sourceBuffers.length);
  const data = new Uint8Array(await (await fetch("/video/f/clip_frag.mp4")).arrayBuffer());
  const started = once(sb, "updatestart");
  sb.appendBuffer(data);
  log.push("updating " + sb.updating);
  await started;
  await once(sb, "updateend");
  log.push("updated " + sb.updating + " " + sb.buffered.length + " " + (sb.buffered.length ? sb.buffered.end(0).toFixed(1) : "-"));
  ms.endOfStream();
  log.push("ended " + ms.readyState);
  await once(ms, "sourceended");
  log.push("sourceended");
  postMessage({done: log.join(" | ")});
});
let url;
try { url = URL.createObjectURL(ms).slice(0, 5); } catch (e) { url = e.name; }   // (a URL the page cannot load: it fails there)
postMessage({handle: ms.handle, same: ms.handle === ms.handle, can: MediaSource.canConstructInDedicatedWorker, url}, [ms.handle]);
