// Media Source Extensions (src/page/media_source.odin): MediaSource, SourceBuffer, SourceBufferList, an object URL played
// by a media element, the append and remove operations and their events, timestamp offset, append window, sequence mode,
// end of stream, detaching.

const MP4 = 'video/mp4; codecs="avc1.64001f, mp4a.40.2"';

async function until(cond, what, ms = 20000) {
  for (let t = 0; t < ms; t += 20) {
    if (cond()) return true;
    await sleep(20);
  }
  console.log("FAIL timeout waiting for " + what);
  return false;
}

const once = (target, type) => new Promise(resolve => target.addEventListener(type, resolve, { once: true }));

let fragment;   // clip_frag.mp4: an initialization segment, then one fragment per second (H.264 + AAC, 4 s)
async function clip() {
  if (!fragment) fragment = new Uint8Array(await (await fetch("/video/f/clip_frag.mp4")).arrayBuffer());
  return fragment;
}

// A video playing a new MediaSource, once it is open
async function attach() {
  const v = document.createElement("video");
  v.muted = true;
  document.body.appendChild(v);
  const ms = new MediaSource();
  const url = URL.createObjectURL(ms);
  v.src = url;
  await once(ms, "sourceopen");
  return { v, ms, url };
}

async function append(sb, data) {
  const done = once(sb, "updateend");
  sb.appendBuffer(data);
  await done;
}

test("the API surface", () => {
  ok(typeof MediaSource === "function" && typeof SourceBuffer === "function" && typeof SourceBufferList === "function", "interfaces");
  eq(MediaSource.isTypeSupported(MP4), true, "isTypeSupported H.264 + AAC");
  eq(MediaSource.isTypeSupported("video/mp4"), true, "isTypeSupported MP4");
  eq(MediaSource.isTypeSupported('video/webm; codecs="av01.0.00M.08, opus"'), true, "isTypeSupported AV1 + Opus in WebM");
  eq(MediaSource.isTypeSupported('video/ogg; codecs="theora"'), false, "Theora");
  eq(MediaSource.isTypeSupported(""), false, "empty");
  eq(MediaSource.canConstructInDedicatedWorker, false, "canConstructInDedicatedWorker");
  const ms = new MediaSource();
  eq(ms.readyState, "closed", "closed before it is attached");
  ok(Number.isNaN(ms.duration), "duration NaN");
  eq(ms.sourceBuffers.length, 0, "no source buffers");
  ok(ms.sourceBuffers === ms.sourceBuffers && ms.activeSourceBuffers === ms.activeSourceBuffers, "the lists are the same objects");
  ok(ms instanceof EventTarget, "an EventTarget");
  throws(() => ms.addSourceBuffer(MP4), "InvalidStateError", "addSourceBuffer on a closed source");
  throws(() => ms.endOfStream(), "InvalidStateError", "endOfStream on a closed source");
  throws(() => { ms.duration = 5; }, "InvalidStateError", "duration on a closed source");
  throws(() => MediaSource(), "TypeError", "MediaSource() without new");
  const url = URL.createObjectURL(ms);
  ok(/^blob:/.test(url), "an object URL " + url);
  URL.revokeObjectURL(url);
  throws(() => URL.createObjectURL({}), "TypeError", "createObjectURL of a plain object");
});

test("attach, append, end of stream", async () => {
  const data = await clip();
  const { v, ms } = await attach();
  eq(ms.readyState, "open", "open once attached");
  throws(() => ms.addSourceBuffer("video/ogg; codecs=theora"), "NotSupportedError", "an unsupported type");
  throws(() => ms.addSourceBuffer(""), "TypeError", "an empty type");
  const sb = ms.addSourceBuffer(MP4);
  ok(sb instanceof SourceBuffer, "a SourceBuffer");
  eq(ms.sourceBuffers.length, 1, "one source buffer");
  ok(ms.sourceBuffers[0] === sb, "indexed getter");
  eq(ms.sourceBuffers[1], undefined, "past the end");
  eq(sb.mode, "segments", "mode");
  eq(sb.updating, false, "not updating");
  eq(sb.buffered.length, 0, "nothing buffered");
  eq(sb.timestampOffset, 0, "timestampOffset");
  eq(sb.appendWindowStart, 0, "appendWindowStart");
  eq(sb.appendWindowEnd, Infinity, "appendWindowEnd");

  const seen = [];
  for (const n of ["updatestart", "update", "updateend", "error", "abort"]) sb.addEventListener(n, () => seen.push(n));
  const added = [];
  ms.sourceBuffers.addEventListener("addsourcebuffer", () => added.push(1));
  sb.appendBuffer(data.subarray(0, 40000));
  eq(sb.updating, true, "updating right after appendBuffer");
  throws(() => sb.appendBuffer(data.subarray(0, 10)), "InvalidStateError", "appendBuffer while updating");
  throws(() => sb.remove(0, 1), "InvalidStateError", "remove while updating");
  throws(() => { sb.timestampOffset = 1; }, "InvalidStateError", "timestampOffset while updating");
  await once(sb, "updateend");
  eq(sb.updating, false, "not updating after updateend");
  eq(seen.join(","), "updatestart,update,updateend", "event order");
  await append(sb, data.subarray(40000));
  eq(added.length, 1, "addsourcebuffer fired once");
  ok(await until(() => v.readyState >= 1, "metadata"), "the element has its metadata");
  eq(v.videoWidth, 320, "videoWidth");
  eq(v.videoHeight, 180, "videoHeight");
  ok(sb.buffered.length >= 1 && sb.buffered.start(0) < 0.1, "buffered starts near 0: " + sb.buffered.start(0));
  ok(Math.abs(sb.buffered.end(sb.buffered.length - 1) - 4) < 0.1, "buffered ends near 4: " + sb.buffered.end(sb.buffered.length - 1));
  ok(sb.buffered !== sb.buffered, "a new TimeRanges each time");
  ok(Math.abs(v.buffered.end(0) - sb.buffered.end(0)) < 0.01, "the element's buffered is the source buffer's");
  eq(v.duration, Infinity, "the duration of a fragmented file is unknown until the end of the stream");

  ms.endOfStream();
  eq(ms.readyState, "ended", "ended");
  ok(Math.abs(ms.duration - 4) < 0.1, "duration is the end of what was buffered: " + ms.duration);
  ok(await until(() => v.duration === ms.duration, "durationchange"), "the element follows");
  throws(() => ms.endOfStream(), "InvalidStateError", "endOfStream on an ended source");
  ok(await until(() => v.readyState >= 4, "canplaythrough"), "enough data");
  eq(v.seekable.length, 1, "seekable");

  // playing it
  await v.play();
  ok(await until(() => v.currentTime > 0.3, "the position moves"), "currentTime " + v.currentTime);
  v.currentTime = 3.3;
  await until(() => !v.seeking, "the seek");
  ok(await until(() => v.ended, "ended"), "ended");
  v.remove();
});

test("remove, abort, an append makes the source open again", async () => {
  const data = await clip();
  const { v, ms } = await attach();
  const sb = ms.addSourceBuffer(MP4);
  await append(sb, data);
  ms.endOfStream();
  eq(ms.readyState, "ended", "ended");
  const reopened = once(ms, "sourceopen");
  sb.remove(1, 2);
  await reopened;
  eq(ms.readyState, "open", "remove() reopens an ended source");
  await once(sb, "updateend");
  const r = sb.buffered;
  ok(r.length === 2, "a hole where [1, 2) was: " + r.length + " ranges");
  if (r.length === 2) {
    ok(r.end(0) < 1.2 && r.start(1) > 1.8, "range edges " + r.end(0) + " " + r.start(1));
  }
  throws(() => sb.remove(-1, 1), "TypeError", "remove with a negative start");
  throws(() => sb.remove(2, 1), "TypeError", "remove with start after end");
  // an append that is aborted
  const seen = [];
  for (const n of ["update", "abort", "updateend"]) sb.addEventListener(n, () => seen.push(n));
  sb.appendBuffer(data);
  sb.abort();
  eq(sb.updating, false, "abort() stops the operation");
  await sleep(100);
  eq(seen.join(","), "abort,updateend", "abort then updateend, no update");
  sb.remove(0, Infinity);
  await once(sb, "updateend");
  eq(sb.buffered.length, 0, "everything removed");
  v.remove();
});

test("timestampOffset, append window, sequence mode", async () => {
  const data = await clip();
  {
    const { v, ms } = await attach();
    const sb = ms.addSourceBuffer(MP4);
    sb.timestampOffset = 10;
    eq(sb.timestampOffset, 10, "timestampOffset");
    await append(sb, data);
    ok(sb.buffered.length >= 1 && Math.abs(sb.buffered.start(0) - 10) < 0.1, "buffered starts at the offset: " + sb.buffered.start(0));
    ok(Math.abs(sb.buffered.end(sb.buffered.length - 1) - 14) < 0.1, "buffered ends at 14: " + sb.buffered.end(sb.buffered.length - 1));
    v.remove();
  }
  {
    const { v, ms } = await attach();
    const sb = ms.addSourceBuffer(MP4);
    throws(() => { sb.appendWindowEnd = 0; }, "TypeError", "appendWindowEnd must be above the start");
    throws(() => { sb.appendWindowStart = -1; }, "TypeError", "appendWindowStart must not be negative");
    sb.appendWindowEnd = 2;
    eq(sb.appendWindowEnd, 2, "appendWindowEnd");
    await append(sb, data);
    ok(sb.buffered.length >= 1 && sb.buffered.end(sb.buffered.length - 1) <= 2.01, "nothing past the window: " + sb.buffered.end(sb.buffered.length - 1));
    ok(sb.buffered.end(sb.buffered.length - 1) > 1.5, "most of the window is filled");
    v.remove();
  }
  {
    const { v, ms } = await attach();
    const sb = ms.addSourceBuffer(MP4);
    sb.mode = "sequence";
    eq(sb.mode, "sequence", "mode");
    await append(sb, data);
    await append(sb, data);
    const end = sb.buffered.end(sb.buffered.length - 1);
    ok(Math.abs(end - 8) < 0.15, "two appends end to end: " + end);
    ok(Math.abs(sb.timestampOffset - 4) < 0.15, "timestampOffset follows: " + sb.timestampOffset);
    v.remove();
  }
});

test("a quality switch: the initialization segment again", async () => {
  const data = await clip();
  const { v, ms } = await attach();
  const sb = ms.addSourceBuffer(MP4);
  await append(sb, data);
  // the same media again at the same place: what it overlaps is replaced, nothing doubles
  await append(sb, data);
  eq(sb.buffered.length, 1, "one range");
  ok(Math.abs(sb.buffered.end(0) - 4) < 0.1, "still 4 s: " + sb.buffered.end(0));
  ms.endOfStream();
  await v.play();
  ok(await until(() => v.currentTime > 0.3, "playback"), "plays after the second initialization segment");
  v.remove();
});

test("errors: garbage appended", async () => {
  const { v, ms } = await attach();
  const sb = ms.addSourceBuffer(MP4);
  const seen = [];
  for (const n of ["error", "updateend"]) sb.addEventListener(n, () => seen.push(n));
  const ended = once(ms, "sourceended");
  // a moov box whose content is not a movie
  sb.appendBuffer(new Uint8Array([0, 0, 0, 16, 0x6d, 0x6f, 0x6f, 0x76, 1, 2, 3, 4, 5, 6, 7, 8]));
  await once(sb, "updateend");
  eq(seen.join(","), "error,updateend", "error then updateend");
  await ended;
  eq(ms.readyState, "ended", "a decode error ends the stream");
  ok(await until(() => v.error !== null, "element error"), "the element has an error");
  eq(v.error.code, MediaError.MEDIA_ERR_DECODE, "MEDIA_ERR_DECODE");
  v.remove();
});

test("removeSourceBuffer, detaching, a revoked URL", async () => {
  const data = await clip();
  {
    const { v, ms } = await attach();
    const sb = ms.addSourceBuffer(MP4);
    const sb2 = ms.addSourceBuffer("audio/mp4; codecs=\"mp4a.40.2\"");
    eq(ms.sourceBuffers.length, 2, "two source buffers");
    ms.removeSourceBuffer(sb2);
    eq(ms.sourceBuffers.length, 1, "one left");
    throws(() => sb2.appendBuffer(new Uint8Array(8)), "InvalidStateError", "appending to a removed buffer");
    throws(() => sb2.buffered, "InvalidStateError", "buffered of a removed buffer");
    throws(() => ms.removeSourceBuffer(sb2), "NotFoundError", "removing it again");
    await append(sb, data);
    const closed = once(ms, "sourceclose");
    v.removeAttribute("src");
    v.load();
    await closed;
    eq(ms.readyState, "closed", "closed once the element lets go");
    eq(ms.sourceBuffers.length, 0, "the source buffers are removed");
    ok(Number.isNaN(ms.duration), "duration NaN again");
    throws(() => sb.appendBuffer(new Uint8Array(8)), "InvalidStateError", "appending after the detach");
    v.remove();
  }
  {
    // the source is dropped by the script while the element plays it
    const v = document.createElement("video");
    v.muted = true;
    document.body.appendChild(v);
    let sb;
    {
      const ms = new MediaSource();
      v.src = URL.createObjectURL(ms);
      await once(ms, "sourceopen");
      sb = ms.addSourceBuffer(MP4);
    }
    await append(sb, data);
    ok(await until(() => v.readyState >= 1, "metadata"), "the element plays a source nothing refers to");
    v.remove();
  }
  {
    const ms = new MediaSource();
    const url = URL.createObjectURL(ms);
    URL.revokeObjectURL(url);
    const v = document.createElement("video");
    document.body.appendChild(v);
    v.src = url;
    ok(await until(() => v.error !== null, "the error"), "a revoked URL does not play");
    eq(ms.readyState, "closed", "the source was not attached");
    v.remove();
  }
});

test("duration", async () => {
  const data = await clip();
  const { v, ms } = await attach();
  const sb = ms.addSourceBuffer(MP4);
  await append(sb, data);
  throws(() => { ms.duration = -1; }, "TypeError", "a negative duration");
  throws(() => { ms.duration = NaN; }, "TypeError", "a NaN duration");
  ms.duration = 2;
  eq(ms.duration, 2, "duration set");
  ok(await until(() => v.duration === 2, "durationchange"), "the element follows");
  ok(sb.buffered.end(sb.buffered.length - 1) <= 2.2, "what lay past it is removed: " + sb.buffered.end(sb.buffered.length - 1));
  ms.setLiveSeekableRange(0, 1);
  eq(v.seekable.end(0), 1, "live seekable range");
  ms.clearLiveSeekableRange();
  v.remove();
});

__run();
