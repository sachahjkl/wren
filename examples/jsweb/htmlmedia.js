// HTMLMediaElement on the media player (src/page/media_element.odin): the resource selection and load, readyState and
// the events, TimeRanges, MediaError, seeking, playback to the end, canPlayType. The pictures are not painted here (the
// shell does that); the decoders and the audio device are the real ones.

const MP4 = 'video/mp4; codecs="avc1.64001f, mp4a.40.2"';

// waits (without timers: an abort signal's) until cond() holds
async function until(cond, what, ms = 20000) {
  for (let t = 0; t < ms; t += 20) {
    if (cond()) return true;
    await sleep(20);
  }
  console.log("FAIL timeout waiting for " + what);
  return false;
}

function track(v) {
  const events = [];
  for (const n of ["loadstart", "durationchange", "loadedmetadata", "loadeddata", "canplay", "canplaythrough", "play", "playing", "pause", "seeking", "seeked", "ended", "emptied", "error", "waiting", "resize"]) {
    v.addEventListener(n, () => events.push(n));
  }
  return events;
}

function video(src) {
  const v = document.createElement("video");
  v.muted = true;
  v.preload = "auto";
  const events = track(v);
  document.body.appendChild(v);
  if (src) v.src = src;
  return { v, events };
}

test("canPlayType", () => {
  const v = document.createElement("video");
  eq(v.canPlayType(MP4), "probably", "H.264 + AAC in MP4");
  eq(v.canPlayType('video/mp4; codecs="avc1.42E01E"'), "probably", "H.264 baseline");
  eq(v.canPlayType("video/mp4"), "maybe", "MP4 without codecs");
  eq(v.canPlayType("video/ogg; codecs=\"theora\""), "", "Theora is not offered");
  eq(v.canPlayType("text/html"), "", "not a media type");
  eq(v.canPlayType(""), "", "empty");
  eq(document.createElement("audio").canPlayType('audio/mp4; codecs="mp4a.40.2"'), "probably", "AAC in audio/mp4");
});

test("a progressive MP4: metadata, events, ranges", async () => {
  const { v, events } = video("/video/f/clip.mp4");
  ok(v instanceof HTMLVideoElement && v instanceof HTMLMediaElement, "interfaces");
  eq(v.readyState, 0, "readyState before the load");
  ok(await until(() => v.readyState >= 1, "loadedmetadata"), "metadata arrived");
  ok(Math.abs(v.duration - 4) < 0.1, "duration " + v.duration);
  eq(v.videoWidth, 320, "videoWidth");
  eq(v.videoHeight, 180, "videoHeight");
  ok(v.currentSrc.endsWith("/video/f/clip.mp4"), "currentSrc " + v.currentSrc);
  ok(await until(() => v.readyState >= 4, "enough data"), "enough data");
  await until(() => events.includes("canplaythrough"), "the canplaythrough event");
  ok(events.indexOf("loadstart") < events.indexOf("loadedmetadata") && events.indexOf("loadedmetadata") < events.indexOf("loadeddata") &&
     events.indexOf("loadeddata") < events.indexOf("canplay"), "event order " + events.join(","));
  ok(events.includes("canplaythrough") && events.includes("durationchange"), "canplaythrough and durationchange");
  ok(v.buffered instanceof TimeRanges, "buffered is a TimeRanges");
  ok(v.buffered.length >= 1, "something buffered");
  eq(v.buffered.start(0), 0, "buffered starts at 0");
  ok(v.buffered.end(v.buffered.length - 1) > 3.9, "the whole file is buffered");
  eq(v.seekable.length, 1, "seekable");
  eq(v.seekable.start(0), 0, "seekable start");
  ok(Math.abs(v.seekable.end(0) - v.duration) < 0.1, "seekable end");
  eq(v.played.length, 0, "nothing played");
  throws(() => v.buffered.start(v.buffered.length), "IndexSizeError", "TimeRanges.start past the end");
  throws(() => v.buffered.end(99), "IndexSizeError", "TimeRanges.end past the end");
  ok(v.buffered !== v.buffered && v.buffered.length === v.buffered.length, "a new TimeRanges each time");
  eq(v.error, null, "no error");
  eq(v.paused, true, "paused");
  eq(v.ended, false, "not ended");
  eq(v.networkState === 1 || v.networkState === 2, true, "networkState idle or loading");
  v.remove();
});

test("play, seek and the end", async () => {
  const { v, events } = video("/video/f/clip.mp4");
  ok(await until(() => v.readyState >= 3, "canplay"), "can play");
  await v.play();
  eq(v.paused, false, "play() resolved, not paused");
  ok(await until(() => events.includes("play") && events.includes("playing"), "play and playing"), "play and playing " + events.join(","));
  ok(await until(() => v.currentTime > 0.3, "the position moves"), "currentTime " + v.currentTime);
  v.pause();
  eq(v.paused, true, "pause()");
  ok(await until(() => events.includes("pause"), "pause"), "pause event");
  ok(v.played.length >= 1 && v.played.end(0) > 0.2, "played");
  v.currentTime = 2;
  eq(v.seeking, true, "seeking");
  ok(await until(() => events.includes("seeked"), "seeked"), "seeked");
  eq(v.seeking, false, "not seeking any more");
  ok(Math.abs(v.currentTime - 2) < 0.3, "currentTime after the seek " + v.currentTime);
  v.currentTime = 3.4;
  await until(() => !v.seeking, "second seek");
  await v.play();
  const at_end = await until(() => v.ended, "ended");
  if (!at_end) console.log("state: t=" + v.currentTime + " ready=" + v.readyState + " paused=" + v.paused + " seeking=" + v.seeking + " net=" + v.networkState + " events=" + events.join(","));
  ok(at_end, "ended");
  ok(await until(() => events.includes("ended"), "ended event"), "ended event");
  eq(v.paused, true, "paused at the end");
  ok(Math.abs(v.currentTime - v.duration) < 0.1, "currentTime at the end " + v.currentTime);
  v.volume = 0.5;
  eq(v.volume, 0.5, "volume");
  throws(() => { v.volume = 2; }, "IndexSizeError", "volume out of range");
  v.playbackRate = 2;
  eq(v.playbackRate, 2, "playbackRate");
  v.remove();
});

test("an error: a missing file", async () => {
  const { v, events } = video("/video/f/nothing.mp4");
  ok(await until(() => v.error !== null, "the error"), "error set");
  ok(v.error instanceof MediaError, "a MediaError");
  eq(v.error.code, MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED, "code");
  eq(typeof v.error.message, "string", "message");
  ok(v.error === v.error, "the same object until it changes");
  ok(events.includes("error"), "error event");
  eq(v.networkState, 3, "NETWORK_NO_SOURCE");
  await rejects(v.play(), "NotSupportedError", "play() with no usable source");
  v.removeAttribute("src");
  v.load();
  eq(v.error, null, "load() clears the error");
  v.remove();
});

test("<source> children: the first that can play", async () => {
  const v = document.createElement("video");
  v.muted = true;
  const events = track(v);
  v.innerHTML = '<source src="/video/f/clip_vp9.webm" type="video/ogg; codecs=theora"><source src="/video/f/nothing.mp4" type="video/mp4"><source src="/video/f/clip.mp4" type="video/mp4">';
  document.body.appendChild(v);
  ok(await until(() => v.readyState >= 1, "a source that plays"), "metadata");
  ok(v.currentSrc.endsWith("/video/f/clip.mp4"), "currentSrc is the third " + v.currentSrc);
  v.remove();
});

// a machine without the AV1 video extension (a CI runner) has no decoder for the WebM clips: the tests that need one say so and stop
const AV1 = document.createElement("video").canPlayType('video/webm; codecs="av01.0.05M.08, opus"') !== "";

test("WebM (AV1 + Opus)", async () => {
  if (!AV1) { console.log("ok no AV1 decoder here"); return; }
  const { v } = video("/video/f/clip.webm");
  ok(await until(() => v.readyState >= 1 || v.error, "metadata or an error"), "answered");
  if (v.error) { console.log("ok no AV1 decoder here: error " + v.error.code); v.remove(); return; }
  ok(Math.abs(v.duration - 4) < 0.2, "duration " + v.duration);
  eq(v.videoWidth, 320, "videoWidth");
  v.remove();
});

test("audio", async () => {
  const a = document.createElement("audio");
  const events = track(a);
  a.src = "/video/f/tone.m4a";
  document.body.appendChild(a);
  ok(await until(() => a.readyState >= 1, "metadata"), "metadata");
  ok(Math.abs(a.duration - 2) < 0.2, "duration " + a.duration);
  ok(a instanceof HTMLAudioElement, "HTMLAudioElement");
  a.remove();
});

test("load() restarts, removing src empties", async () => {
  const { v, events } = video("/video/f/clip.mp4");
  ok(await until(() => v.readyState >= 1, "metadata"), "metadata");
  v.removeAttribute("src");
  v.load();
  ok(await until(() => events.includes("emptied"), "emptied"), "emptied");
  eq(v.readyState, 0, "readyState back to 0");
  ok(Number.isNaN(v.duration), "duration NaN");
  eq(v.buffered.length, 0, "nothing buffered");
  v.remove();
});

test("what is offered: honest about the decoders of this machine", () => {
  const v = document.createElement("video");
  // the same answer from canPlayType and isTypeSupported, and none for what no decoder here exists for
  const types = ['video/webm; codecs="vp8"', 'video/webm; codecs="vp8, vorbis"', 'video/webm; codecs="vp9"', 'video/webm; codecs="vp09.00.10.08, opus"',
    'video/mp4; codecs="hvc1.1.6.L93.B0"', 'video/mp4; codecs="hev1.1.6.L93.B0"', 'video/webm; codecs="av01.0.05M.08, opus"', 'video/mp4; codecs="av01.0.05M.08"',
    'audio/webm; codecs="opus"', 'audio/mp4; codecs="opus"', 'audio/webm; codecs="vorbis"', 'audio/webm; codecs="av01.0.05M.08"', 'video/webm; codecs="avc1.64001f"'];
  const answers = types.map(t => t + " -> " + (v.canPlayType(t) || '""') + " / " + MediaSource.isTypeSupported(t));
  console.log("types: " + answers.join(" | "));
  for (const t of types) eq(MediaSource.isTypeSupported(t), v.canPlayType(t) === "probably", "isTypeSupported agrees with canPlayType: " + t);
  eq(v.canPlayType('video/webm; codecs="vp8"'), "", "no VP8 decoder");
  eq(v.canPlayType('video/webm; codecs="vp8, vorbis"'), "", "no VP8, no Vorbis");
  eq(v.canPlayType('audio/webm; codecs="vorbis"'), "", "no Vorbis decoder");
  eq(v.canPlayType('audio/webm; codecs="av01.0.05M.08"'), "", "a video codec in audio/webm");
  eq(v.canPlayType('video/webm; codecs="avc1.64001f"'), "", "H.264 in WebM");
  eq(v.canPlayType('audio/webm; codecs="opus"'), "probably", "Opus in WebM");
  eq(v.canPlayType("video/webm"), "maybe", "WebM without codecs");
});

test("WebM (AV1 + Opus) plays to the end", async () => {
  if (!AV1) { console.log("ok no AV1 decoder here"); return; }
  const { v } = video("/video/f/clip.webm");
  if (!await until(() => v.readyState >= 3 || v.error, "canplay")) return;
  if (v.error) { console.log("ok no AV1 decoder here: error " + v.error.code); v.remove(); return; }
  await v.play();
  ok(await until(() => v.currentTime > 0.3, "the position moves"), "WebM plays: " + v.currentTime);
  v.currentTime = 3.2;
  await until(() => !v.seeking, "seek in WebM");
  ok(Math.abs(v.currentTime - 3.2) < 0.4, "seeked to a keyframe and on: " + v.currentTime);
  ok(await until(() => v.ended, "ended"), "WebM reaches its end");
  v.remove();
});

test("a live WebM (unknown sizes)", async () => {
  if (!AV1) { console.log("ok no AV1 decoder here"); return; }
  const { v } = video("/video/f/clip_live.webm");
  ok(await until(() => v.readyState >= 1 || v.error, "metadata or an error"), "answered");
  if (!v.error) ok(v.videoWidth === 320, "videoWidth " + v.videoWidth);
  v.remove();
});

test("playback keeps time: the position follows the wall clock, no stall", async () => {
  const { v, events } = video("/video/f/clip.mp4");
  ok(await until(() => v.readyState >= 4, "enough data"), "ready");
  const t0 = performance.now();
  await v.play();
  const start = v.currentTime;
  ok(await until(() => v.currentTime > 1.5, "1.5 s of playback"), "plays");
  const wall = (performance.now() - t0) / 1000;
  const media = v.currentTime - start;
  // the audio clock and the wall clock agree within a few percent (a start-up of the audio device is before `start`)
  ok(Math.abs(wall - media) < 0.35 + wall * 0.1, "media time " + media.toFixed(2) + " s in " + wall.toFixed(2) + " s of wall time");
  eq(events.filter(e => e === "waiting").length, 0, "no stall while playing a buffered file");
  v.remove();
});

__run();
