# Media elements

How `<video>` and `<audio>` work in Wren, beyond the generated API reference ([`api/htmlmedia.md`](api/htmlmedia.md),
[`api/media.md`](api/media.md), [`api/mse.md`](api/mse.md)). Everything here is native: the state machine, the track
model, the WebVTT parser, the subtitle layer and the frame callbacks are Odin in `src/page` and `src/media`; no
JavaScript of the browser implements them.

## The player

A media element (`src/page/media_element.odin`) runs the HTML resource-selection and load algorithms over a
`media.Player` (`src/media`), which decodes on its own threads. Codecs: H.264 and HEVC and AAC through Media Foundation
(DXVA on the GPU when the system has it), AV1 and VP9 in software when the system has no decoder (see
[`portability.md`](portability.md)), Opus, Vorbis, FLAC, MP3, PCM. Containers: MP4 and WebM, progressive (a download) or
through Media Source Extensions.

## Audio, video and text tracks

`element.audioTracks`, `videoTracks` and `textTracks` (`src/page/media_tracks.odin`, `media_texttracks.odin`) expose
the tracks the container announced and the text tracks of `<track>` and `addTextTrack`. The lists are EventTargets
(`addtrack`, `removetrack`, `change`); `AudioTrack` / `VideoTrack` carry `id`, `kind`, `label`, `language` and the
`enabled` / `selected` flags. The chosen tracks start enabled. Changing which audio or video track is active is
recorded and passed to the player (`media.player_select_audio` / `player_select_video`); the progressive and MSE
players decode a single stream, so a mid-stream switch to another track of the same resource takes effect only where a
future multi-stream player can honour it — the state a script reads is always correct.

Turned off by `media.tracks.enabled` (the lists are then empty and tracks stay implicit).

## Text tracks, WebVTT and subtitles

A `<track kind srclang label default src>` loads its `src` as WebVTT, parsed natively (`src/media/webvtt.odin`): the
signature line, `NOTE` comments, `REGION` and `STYLE` blocks, and the cues — their identifier, the timing line with its
settings (`vertical`, `line`, `position`, `size`, `align`) and the payload with its inline markup (`<b> <i> <u>
<c.class> <v Name> <lang> <ruby>/<rt>` and internal timestamps). `TextTrack.mode` is `disabled` / `hidden` / `showing`;
`addTextTrack`, `addCue`, `removeCue`, `VTTCue` and `TextTrackCueList` are all supported. The `<track>` element fires
`load` / `error` and exposes `readyState`.

Which cues are active is tracked by the player's clock (no script polling): `cuechange` fires on a track and `enter` /
`exit` on a cue when the active set changes. The cues of **showing** tracks are drawn over the video by the shell
(`src/browser/video_shell.odin`), in a layer of the page over the picture: the `::cue` defaults (white text on a
translucent black box, near the bottom), honouring the cue's `align`. Turned off by `media.subtitles.enabled`;
`media.subtitles.max_lines` caps how many cue lines are drawn at once.

## requestVideoFrameCallback

`video.requestVideoFrameCallback(callback)` (`src/page/media_rvfc.odin`) runs `callback(now, metadata)` once, the next
time a new decoded picture is presented on screen — the same moment the `getVideoPlaybackQuality` counters advance, the
real presentation path, not a timer. The `VideoFrameCallbackMetadata` gives `presentationTime`, `expectedDisplayTime`,
`width`, `height`, `mediaTime`, `presentedFrames` and `processingDuration` (0, not measured); `captureTime`,
`receiveTime` and `rtpTimestamp` are never present (Wren is not a WebRTC endpoint). `cancelVideoFrameCallback(id)`
cancels. `media.video_frame_callbacks.max` caps how many may wait on one video.

## Managed Media Source

`ManagedMediaSource`, `ManagedSourceBuffer` and `BufferedChangeEvent` (`src/page/media_managed.odin`) are the managed
variant of MSE, where the user agent says when to stream. `ManagedMediaSource.streaming` is true while Wren wants data;
it fires `startstreaming` once less than `media.mse.managed.low_seconds` is buffered ahead of the playback position and
`endstreaming` once `media.mse.managed.high_seconds` is. A `ManagedSourceBuffer` fires `bufferedchange` with the ranges
added and removed whenever its buffered ranges change (an append or an eviction). Everything of plain MSE applies
([`api/mse.md`](api/mse.md)).

## The video fast path

A `<video>` is painted inside the page's paint pass, so a long script that holds the interface thread freezes the video
with the rest of the page (YouTube runs a ~85 ms task every few seconds). `browser.video.fast_path` keeps the video
moving: during a *chrome frame* (the browser's interface drawn while a page is busy, see
[`chrome-style.md`](chrome-style.md) and `src/browser/shell_frames.odin`), the video's newest decoded picture is drawn
over the page's last frame at the video's box, recomposing only the video — no script runs and the page is not laid out
again. It runs only for a video that fills its box opaquely with nothing drawn over it, so the overlay can never show a
pixel the normal path would not have; otherwise the picture is left frozen (a freeze beats a wrong frame).

Values: `auto` (on), `off` (the video freezes with the page), `verify` (a diagnostic that reports in the console when
the fast path is recomposing, for comparing against `off`). Implemented in `src/browser/video_fast_path.odin`.
